import AppKit

@MainActor
final class AgentChatComposerTextView: NSTextView {
    var onPasteMedia: ((NSPasteboard) -> Bool)?
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Bool)?
    var onFocus: (() -> Void)?
    /// Shift-Tab: moves focus to the transcript.
    var onBacktab: (() -> Bool)?
    /// Cmd-. stops the running turn.
    var onStop: (() -> Bool)?
    var placeholder = "Message" { didSet { if oldValue != placeholder { needsDisplay = true } } }

    convenience init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        container.widthTracksTextView = true
        container.heightTracksTextView = false
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        AgentChatMediaPasteboard.types + super.readablePasteboardTypes.filter { !AgentChatMediaPasteboard.types.contains($0) }
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        AgentChatMediaPasteboard.types + super.acceptableDragTypes.filter { !AgentChatMediaPasteboard.types.contains($0) }
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        registerForDraggedTypes(AgentChatMediaPasteboard.types)
    }

    required init?(coder: NSCoder) { nil }

    override func paste(_ sender: Any?) {
        if onPasteMedia?(NSPasteboard.general) == true { return }
        super.paste(sender)
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if onPasteMedia?(pboard) == true { return true }
        return super.readSelection(from: pboard, type: type)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        AgentChatMediaPasteboard.canRead(sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        AgentChatMediaPasteboard.canRead(sender.draggingPasteboard) || super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if onPasteMedia?(sender.draggingPasteboard) == true { return true }
        return super.performDragOperation(sender)
    }

    override func becomeFirstResponder() -> Bool {
        onFocus?()
        return super.becomeFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        // An input method owns Return while composing marked text.
        if !hasMarkedText(), event.keyCode == 36 || event.keyCode == 76 {
            if event.modifierFlags.intersection([.option, .shift]).isEmpty {
                onSubmit?()
            } else {
                insertNewline(nil)
            }
            return
        }
        if !hasMarkedText(), event.keyCode == 53, onCancel?() == true { return }
        if !hasMarkedText(), AgentChatTimelineKey(event) == .stop, onStop?() == true { return }
        super.keyDown(with: event)
    }

    override func insertBacktab(_ sender: Any?) {
        if onBacktab?() == true { return }
        super.insertBacktab(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width + 4, y: textContainerInset.height), withAttributes: [
            .font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.placeholderTextColor,
        ])
    }
}

/// One quiet surface for the draft and its actions; the conversation remains
/// on the pane background above it.
@MainActor
final class AgentChatComposerCard: NSView {
    var onPasteMedia: ((NSPasteboard) -> Bool)?
    private var receivingDrop = false { didSet { needsDisplay = true } }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityIdentifier("agent-chat.composer-card")
        registerForDraggedTypes(AgentChatMediaPasteboard.types)
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        receivingDrop = AgentChatMediaPasteboard.canRead(sender.draggingPasteboard)
        return receivingDrop ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { receivingDrop = false }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { receivingDrop }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        receivingDrop = false
        return onPasteMedia?(sender.draggingPasteboard) ?? false
    }

    override func draw(_ dirtyRect: NSRect) {
        CockpitCardStyle.fillColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 24, yRadius: 24).fill()
        if receivingDrop {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 24, yRadius: 24).fill()
        }
    }
}

/// Keeps native button focus, keyboard activation and accessibility while
/// drawing the compact circular send action used inside the composer. While
/// a turn runs, a non-empty draft is sent as a steer or queued instead.
@MainActor
final class AgentChatSendButton: NSButton {
    enum Mode: Equatable { case send, steer, queue }

    private(set) var mode = Mode.send

    // Standard push-button alignment adds vertical bezel overhang. This
    // custom circular surface needs its visible bounds to match its layout.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        imagePosition = .imageOnly
        focusRingType = .exterior
        setButtonType(.momentaryPushIn)
        update(mode: .send, enabled: false)
    }

    required init?(coder: NSCoder) { nil }

    func update(mode: Mode, enabled: Bool) {
        self.mode = mode
        let (symbol, label, tip) = switch mode {
        case .send: ("arrow.up", "Send message", "Send (Return); Option-Return inserts a newline")
        case .steer: ("arrow.turn.down.right", "Steer current run", "Send to the running turn (Return)")
        case .queue: ("text.badge.plus", "Queue for next turn", "Queue for after this turn (Return)")
        }
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        isEnabled = enabled
        contentTintColor = enabled ? .white : .tertiaryLabelColor
        setAccessibilityLabel(label)
        toolTip = tip
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor = isEnabled ? .controlAccentColor : .labelColor.withAlphaComponent(0.07)
        (isHighlighted ? fill.withAlphaComponent(0.65) : fill).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        super.draw(dirtyRect)
    }
}

/// The persistent Stop control (Cmd-.), visible while a turn or background
/// agents run. Background agents alone can't be stopped from the client.
@MainActor
final class AgentChatStopButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        imagePosition = .imageOnly
        focusRingType = .exterior
        setButtonType(.momentaryPushIn)
        image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        setAccessibilityIdentifier("agent-chat.stop")
        setAccessibilityLabel("Stop")
        update(turnRunning: false)
    }

    required init?(coder: NSCoder) { nil }

    func update(turnRunning: Bool) {
        isEnabled = turnRunning
        contentTintColor = turnRunning ? .labelColor : .tertiaryLabelColor
        toolTip = turnRunning ? "Stop the running turn (Cmd-.)"
            : "Background agents keep running; Stop cancels only a running turn."
        setAccessibilityHelp(toolTip)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill = NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.18 : 0.1)
        fill.setFill()
        NSBezierPath(ovalIn: bounds).fill()
        super.draw(dirtyRect)
    }
}

/// "Steering current run" or "Queued for next turn" (removable), shown in the
/// composer because the placeholder's contrast is too low to carry the state.
@MainActor
final class AgentChatComposerChip: NSView {
    let label = NSTextField(labelWithString: "")
    let removeButton = NSButton()
    var onRemove: () -> Void = {}

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityIdentifier("agent-chat.composer-chip")
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        removeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove queued message")
        removeButton.isBordered = false
        removeButton.imagePosition = .imageOnly
        removeButton.target = self
        removeButton.action = #selector(remove)
        removeButton.setAccessibilityIdentifier("agent-chat.composer-chip.remove")
        let stack = NSStackView(views: [label, removeButton])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// `detail` (redacted) is the tooltip, e.g. the queued text.
    func update(text: String, detail: String?, removable: Bool) {
        label.stringValue = text
        label.font = CockpitTypography.font(size: 11, weight: .medium)
        label.textColor = AgentChatPalette.color(.live)
        label.toolTip = detail
        removeButton.isHidden = !removable
        setAccessibilityLabel(text)
        setAccessibilityHelp(detail)
    }

    @objc private func remove() { onRemove() }
}
