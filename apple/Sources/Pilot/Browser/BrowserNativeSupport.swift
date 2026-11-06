import AppKit
import Observation

/// Coalesces model invalidations onto the next main-actor turn and owns the
/// observation lifetime independently of a view's attachment to a window.
@MainActor
final class BrowserNativeObservation {
    private var update: (() -> Void)?
    private var generation = 0
    private var scheduled = false

    func start(_ update: @escaping () -> Void) {
        stop()
        self.update = update
        observe()
    }

    func stop() {
        generation += 1
        update = nil
        scheduled = false
    }

    private func observe() {
        guard let update else { return }
        let generation = generation
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation, !self.scheduled else { return }
                self.scheduled = true
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.scheduled = false
                    self.observe()
                }
            }
        }
    }
}

@MainActor
final class BrowserNativeButton: NSButton {
    var actionHandler: () -> Void

    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        actionHandler = action
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        self.action = #selector(performAction)
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            imagePosition = .imageOnly
            toolTip = title
        }
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    @objc private func performAction() { actionHandler() }
}

@MainActor
final class BrowserNativeMenuItem: NSMenuItem {
    private let actionHandler: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        actionHandler = action
        super.init(title: title, action: #selector(performAction), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    @objc private func performAction() { actionHandler() }
}

@MainActor
enum BrowserNativeUI {
    static func label(_ text: String, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        return field
    }

    static func pin(_ child: NSView, to parent: NSView, inset: CGFloat = 0) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
        ])
    }

    static func present(_ alert: NSAlert, for view: NSView, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window, completionHandler: completion)
    }
}
