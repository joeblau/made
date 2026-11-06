import AppKit

@MainActor
final class AgentChatComposerTextView: NSTextView {
    var onPasteMedia: ((NSPasteboard) -> Bool)?
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Bool)?
    var onFocus: (() -> Void)?
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
        super.keyDown(with: event)
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
/// drawing the compact circular send/stop action used inside the composer.
@MainActor
final class AgentChatSendButton: NSButton {
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
        update(prompting: false, enabled: false)
    }

    required init?(coder: NSCoder) { nil }

    func update(prompting: Bool, enabled: Bool) {
        image = NSImage(systemSymbolName: prompting ? "stop.fill" : "arrow.up", accessibilityDescription: nil)
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        isEnabled = enabled
        contentTintColor = enabled ? .white : .tertiaryLabelColor
        setAccessibilityLabel(prompting ? "Stop response" : "Send message")
        toolTip = prompting ? "Stop (Esc)" : "Send (Return); Option-Return inserts a newline"
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor = isEnabled ? .controlAccentColor : .labelColor.withAlphaComponent(0.07)
        (isHighlighted ? fill.withAlphaComponent(0.65) : fill).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        super.draw(dirtyRect)
    }
}
