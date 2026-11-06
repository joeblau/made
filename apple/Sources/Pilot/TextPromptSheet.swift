import AppKit

@MainActor
final class ShellActionButton: NSButton {
    var perform: () -> Void
    private var zoomObservation: CockpitObservation?

    init(_ title: String, symbol: String? = nil, perform: @escaping () -> Void) {
        self.perform = perform
        super.init(frame: .zero)
        self.title = title
        font = CockpitTypography.font(size: 13)
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
        imagePosition = symbol == nil ? .noImage : .imageLeading
        bezelStyle = .rounded
        target = self
        action = #selector(invoke)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { nil }
    @objc private func invoke() { perform() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            if zoomObservation == nil { zoomObservation = CockpitObservation(owner: self) { $0.font = CockpitTypography.font(size: 13) } }
            zoomObservation?.start()
        } else { zoomObservation?.stop() }
    }
}

@MainActor
final class ShellMenuItem: NSMenuItem, NSMenuItemValidation {
    var perform: () -> Void
    var enabledWhen: (() -> Bool)?

    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command,
         enabledWhen: (() -> Bool)? = nil, perform: @escaping () -> Void) {
        self.perform = perform
        self.enabledWhen = enabledWhen
        super.init(title: title, action: #selector(invoke), keyEquivalent: key)
        target = self
        keyEquivalentModifierMask = modifiers
    }

    required init(coder: NSCoder) { fatalError("Use the action initializer") }
    @objc private func invoke() { perform() }
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool { enabledWhen?() ?? true }
}

@MainActor
func shellStack(_ views: [NSView], orientation: NSUserInterfaceLayoutOrientation = .vertical,
                spacing: CGFloat = 8) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = orientation
    stack.spacing = spacing
    stack.alignment = orientation == .vertical ? .leading : .centerY
    return stack
}

@MainActor
func shellLabel(_ string: String, secondary: Bool = false) -> NSTextField {
    let field = NSTextField(labelWithString: string)
    field.font = CockpitTypography.font(size: 13)
    field.textColor = secondary ? .secondaryLabelColor : .labelColor
    field.lineBreakMode = .byTruncatingTail
    return field
}

@MainActor
func shellPin(_ child: NSView, to parent: NSView, inset: CGFloat = 0) {
    parent.addSubview(child)
    child.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
        child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
        child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
        child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
    ])
}

/// A sheet's completion is scoped to its parent window and delivered once.
@MainActor
enum TextPromptSheet {
    static func present(on window: NSWindow?, title: String, label: String, value: String,
                        confirmTitle: String = "Save", completion: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = label
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        field.setAccessibilityLabel(label)
        alert.accessoryView = field
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { completion(value) }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
            alert.window.makeFirstResponder(field)
        } else {
            finish(alert.runModal())
        }
    }
}
