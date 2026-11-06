import AppKit
import Observation

@MainActor
class RRBackgroundView: NSView {
    var fillColor: NSColor = .windowBackgroundColor
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        fillColor.setFill()
        bounds.intersection(dirtyRect).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
final class RRDocumentView: NSView {
    override var isFlipped: Bool { true }
}

typealias RRButton = CockpitActionButton

extension CockpitActionButton {
    convenience init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.init(title: title, systemImage: symbol, action: action)
    }
    var perform: () -> Void {
        get { onAction }
        set { onAction = newValue }
    }
}

@MainActor
final class RRMenuItem: NSMenuItem {
    private var perform: () -> Void

    init(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        perform = action
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    @objc private func invoke() { perform() }
}

/// One cancellable Observation registration per visible native controller.
/// Invalidations are delivered after the model mutation has completed.
@MainActor
final class RRObservation {
    private var generation = 0
    private var tracking: (() -> Void)?
    private var changed: (() -> Void)?

    func start(tracking: @escaping () -> Void, changed: @escaping () -> Void) {
        stop()
        self.tracking = tracking
        self.changed = changed
        arm(generation)
    }

    func stop() {
        generation += 1
        tracking = nil
        changed = nil
    }

    private func arm(_ token: Int) {
        guard token == generation, let tracking else { return }
        withObservationTracking(tracking) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, token == self.generation else { return }
                self.changed?()
                self.arm(token)
            }
        }
    }
}

@MainActor
final class RRZoomObservation {
    private var token: NSObjectProtocol?
    init(update: @escaping @MainActor () -> Void) {
        update()
        token = NotificationCenter.default.addObserver(forName: .cockpitUIZoomDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { update() }
        }
    }
    isolated deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}

@MainActor
enum RRUI {
    static var zoom: CGFloat { CGFloat(CockpitUIZoomController.shared.factor) }

    static func zoomControls(in view: NSView) {
        if let control = view as? NSControl, !(control is CockpitLabel), !(control is CockpitActionButton) {
            control.font = CockpitTypography.font(size: 13)
        }
        for child in view.subviews { zoomControls(in: child) }
    }

    static func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor) -> NSTextField {
        let field = CockpitUI.label(text, size: size, weight: weight, color: color)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    static func stack(_ views: [NSView] = [], axis: NSUserInterfaceLayoutOrientation = .vertical,
                      spacing: CGFloat = 8) -> NSStackView {
        let result = NSStackView(views: views)
        result.orientation = axis
        result.alignment = axis == .vertical ? .leading : .centerY
        result.spacing = spacing
        return result
    }

    static func pin(_ child: NSView, to parent: NSView, inset: CGFloat = 0) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
        ])
    }

    static func clear(_ stack: NSStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    static func fillWidth(_ stack: NSStackView) {
        stack.alignment = .leading
        for child in stack.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                         constant: -stack.edgeInsets.left - stack.edgeInsets.right).isActive = true
        }
    }

    static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    static func sheet(_ content: NSView, width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView()
        window.contentView = container
        pin(content, to: container, inset: 20)
        return window
    }

    static func dismiss(_ window: NSWindow) {
        window.sheetParent?.endSheet(window)
    }
}
