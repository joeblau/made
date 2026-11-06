import AppKit
import Observation

@MainActor
enum NativeSettingsUI {
    static func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor, selectable: Bool = false) -> CockpitLabel {
        let field = CockpitUI.label(text, size: size, weight: weight, color: color)
        field.isSelectable = selectable
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    static func column(_ views: [NSView] = [], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    static func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    static func fillWidth(_ child: NSView, in stack: NSStackView) {
        stack.addArrangedSubview(child)
        child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
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

    static func scrolling(_ stack: NSStackView, inset: CGFloat = 24) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let document = NativeSettingsFlippedView()
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -inset),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: inset),
            document.bottomAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: inset)
        ])
        return scroll
    }

    static func section(_ title: String, _ views: [NSView]) -> NSView {
        let contents = column([label(title, size: 14, weight: .semibold)] + views, spacing: 10)
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.cornerRadius = 10
        box.contentViewMargins = NSSize(width: 14, height: 14)
        box.contentView = contents
        contents.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalTo: contents.widthAnchor, constant: 28),
            box.heightAnchor.constraint(equalTo: contents.heightAnchor, constant: 28)
        ])
        for item in views where !(item is NSButton) {
            item.widthAnchor.constraint(equalTo: contents.widthAnchor).isActive = true
        }
        return box
    }

    static func error(_ message: String, in window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Cockpit"
        alert.informativeText = message
        alert.addButton(withTitle: "Dismiss")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    static func clear(_ stack: NSStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }
}

final class NativeSettingsFlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class NativeSettingsButton: NSButton {
    private let handler: (NativeSettingsButton) -> Void

    init(_ title: String, action: @escaping () -> Void) {
        handler = { _ in action() }
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        self.action = #selector(invoke)
        configureTypography()
    }

    init(checkbox title: String, checked: Bool, action: @escaping (Bool) -> Void) {
        handler = { action($0.state == .on) }
        super.init(frame: .zero)
        self.title = title
        setButtonType(.switch)
        state = checked ? .on : .off
        target = self
        self.action = #selector(invoke)
        configureTypography()
    }

    required init?(coder: NSCoder) { nil }
    @objc private func invoke() { handler(self) }

    private func configureTypography() {
        refreshFont()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshFont), name: .cockpitUIZoomDidChange, object: nil)
    }

    @objc private func refreshFont() {
        font = CockpitTypography.font(size: NSFont.systemFontSize)
        invalidateIntrinsicContentSize()
    }
}

/// Keeps editable values and the field editor intact when the user's text size changes.
@MainActor
final class NativeSettingsTextField: NSTextField {
    private let baseFontSize: CGFloat
    private let monospaced: Bool

    init(_ value: String = "", size: CGFloat = NSFont.systemFontSize, monospaced: Bool = false) {
        baseFontSize = size
        self.monospaced = monospaced
        super.init(frame: .zero)
        stringValue = value
        refreshFont()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshFont), name: .cockpitUIZoomDidChange, object: nil)
    }

    required init?(coder: NSCoder) { nil }
    @objc private func refreshFont() {
        font = CockpitTypography.font(size: baseFontSize, monospaced: monospaced)
        currentEditor()?.font = font
        invalidateIntrinsicContentSize()
    }
}

@MainActor
final class NativeSettingsTextView: NSTextView {
    convenience init() { self.init(frame: .zero, textContainer: nil) }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        refreshFont()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshFont), name: .cockpitUIZoomDidChange, object: nil)
    }

    required init?(coder: NSCoder) { nil }
    @objc private func refreshFont() {
        font = CockpitTypography.font(size: 11, monospaced: true)
    }
}

/// Observation is scoped to a visible controller. A queued callback from an
/// earlier presentation cannot restart observation after that controller hides.
@MainActor
final class NativeSettingsObservation {
    private var generation = 0
    private var update: (() -> Void)?

    func start(_ update: @escaping () -> Void) {
        generation += 1
        self.update = update
        track(generation)
    }

    func stop() {
        generation += 1
        update = nil
    }

    private func track(_ expected: Int) {
        guard expected == generation, let update else { return }
        withObservationTracking(update) { [weak self] in
            Task { @MainActor [weak self] in
                self?.track(expected)
            }
        }
    }
}

/// One native form sheet. Validation returns an inline error and leaves the
/// values editable; successful submission and cancellation each finish once.
@MainActor
final class NativeSettingsFormController: NSViewController {
    struct Field {
        var title: String
        var value = ""
        var placeholder = ""
    }

    private let heading: String
    private let detail: String
    private let fields: [Field]
    private let confirmTitle: String
    private let submit: ([String]) -> String?
    private var textFields: [NSTextField] = []
    private let errorLabel = NativeSettingsUI.label("", color: .systemRed)
    private var finished = false

    init(title: String, detail: String = "", fields: [Field], confirmTitle: String,
         submit: @escaping ([String]) -> String?) {
        heading = title
        self.detail = detail
        self.fields = fields
        self.confirmTitle = confirmTitle
        self.submit = submit
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let content = NativeSettingsUI.column(spacing: 12)
        content.addArrangedSubview(NativeSettingsUI.label(heading, size: 20, weight: .semibold))
        if !detail.isEmpty { NativeSettingsUI.fillWidth(NativeSettingsUI.label(detail, color: .secondaryLabelColor), in: content) }
        for field in fields {
            content.addArrangedSubview(NativeSettingsUI.label(field.title, weight: .medium))
            let input = NativeSettingsTextField(field.value)
            input.placeholderString = field.placeholder
            input.setAccessibilityLabel(field.title)
            NativeSettingsUI.fillWidth(input, in: content)
            textFields.append(input)
        }
        NativeSettingsUI.fillWidth(errorLabel, in: content)
        let cancel = NativeSettingsButton("Cancel") { [weak self] in self?.finish() }
        cancel.keyEquivalent = "\u{1b}"
        let confirm = NativeSettingsButton(confirmTitle) { [weak self] in self?.confirm() }
        confirm.keyEquivalent = "\r"
        NativeSettingsUI.fillWidth(NativeSettingsUI.row([NativeSettingsUI.spacer(), cancel, confirm]), in: content)
        view = NSView()
        NativeSettingsUI.pin(content, to: view, inset: 24)
        view.widthAnchor.constraint(equalToConstant: 480).isActive = true
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let first = textFields.first { view.window?.makeFirstResponder(first) }
    }

    private func confirm() {
        guard !finished else { return }
        if let error = submit(textFields.map(\.stringValue)) { errorLabel.stringValue = error } else { finish() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        dismiss(self)
    }
}
