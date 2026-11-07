import AppKit

/// TextKit 1 measurement matching the approval input view's layout exactly.
@MainActor
private enum ApprovalInputMeasure {
    static let storage = NSTextStorage()
    static let layout = NSLayoutManager()
    static let container: NSTextContainer = {
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        return container
    }()

    private static var cache: [String: CGFloat] = [:]

    /// Cached by text, width, and font: the docked card is measured on every
    /// pane layout and its input can be 64 K characters.
    static func height(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let key = "\(text.hashValue)#\(text.utf16.count)#\(width)#\(font.fontName)#\(font.pointSize)"
        if let cached = cache[key] { return cached }
        let value = measure(text, font: font, width: width)
        if cache.count > 64 { cache.removeAll(keepingCapacity: true) }
        cache[key] = value
        return value
    }

    private static func measure(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let box = container
        box.size = NSSize(width: max(1, width), height: .greatestFiniteMagnitude)
        storage.setAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        layout.ensureLayout(for: box)
        return ceil(layout.usedRect(for: box).height)
    }
}

/// A pending permission request, docked above the composer (head of the
/// queue). Names the requesting agent (`approval.agentName`: root, child
/// title, or "untracked subagent"); shows the title, verb, and the full
/// `verb.exactInput` in a scrollable monospaced view with secrets masked and a
/// reveal affordance. One button per agent option in the agent's order with
/// names verbatim; never default/primary on allow_always or mode-changing
/// (exit-plan-*) options; plus "Cancel Request". Buttons wrap vertically when
/// narrow. Never takes first responder automatically; Return activates the
/// first option only when the card has explicit focus.
final class ApprovalCardView: NSView {
    static let accessibilityIdentifierValue = "agent-chat.approval"
    static let padding: CGFloat = 12
    static let maximumInputHeight: CGFloat = 120
    static let inputInset = NSSize(width: 6, height: 4)
    static let buttonSpacing: CGFloat = 8
    static let maximumInputCharacters = 64 * 1_024
    static let cancelTitle = "Cancel Request"
    static let revealTitle = "Reveal secrets"
    static let hideTitle = "Hide secrets"
    static var headerFont: NSFont { AgentChatText.font(12) }
    static var titleFont: NSFont { AgentChatText.font(13, .semibold) }
    static var inputFont: NSFont { AgentChatText.font(12, monospaced: true) }
    static var buttonFont: NSFont { AgentChatText.font(13) }

    /// Everything the card shows, already redacted.
    struct Content: Equatable {
        struct Option: Equatable {
            var id: String
            var name: String
            var isDefault: Bool
        }

        var header: String
        var title: String
        var verbLine: String?
        var glyph: AgentToolVerb.Glyph
        var maskedInput: String
        /// Raw input for "Reveal secrets"; nil when nothing was masked or no
        /// unredacted input was supplied.
        var revealedInput: String?
        var options: [Option]

        var defaultOptionID: String? { options.first { $0.isDefault }?.id }
    }

    let surface = AgentChatSurfaceView(fill: .card, border: .cardBorder, cornerRadius: 10)
    let headerLabel = AgentChatText.makeLabel()
    let glyph = NSImageView()
    let titleLabel = AgentChatText.makeLabel(wrapping: true, selectable: true)
    let verbLabel = AgentChatText.makeLabel()
    let inputSurface = AgentChatSurfaceView(fill: .thread, border: .cardBorder, cornerRadius: 6)
    let inputScroll = NSScrollView()
    let inputText: NSTextView
    let revealButton = AgentChatClosureButton.link(revealTitle)
    private(set) var optionButtons: [AgentChatClosureButton] = []
    let cancelButton = AgentChatClosureButton(title: cancelTitle)
    private(set) var content: Content?
    private(set) var isRevealed = false
    private var requestID: JSONValue?
    /// The request the user focused the card for. Return answers only that
    /// request, so a new head of queue arriving while the card has focus is
    /// never approved by a keystroke meant for the previous one.
    private var armedRequestID: JSONValue?
    private var onChoose: (String) -> Void = { _ in }
    private var onCancelRequest: () -> Void = {}

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        inputText = NSTextView(frame: .zero, textContainer: container)
        super.init(frame: .zero)
        setAccessibilityIdentifier(Self.accessibilityIdentifierValue)
        setAccessibilityRole(.group)
        inputText.isEditable = false
        inputText.isSelectable = true
        inputText.isRichText = false
        inputText.drawsBackground = false
        inputText.textContainerInset = Self.inputInset
        inputText.isVerticallyResizable = true
        inputText.isHorizontallyResizable = false
        inputText.autoresizingMask = [.width]
        inputText.setAccessibilityLabel("Requested input")
        inputScroll.drawsBackground = false
        inputScroll.hasVerticalScroller = true
        inputScroll.autohidesScrollers = true
        inputScroll.scrollerStyle = .overlay
        inputScroll.borderType = .noBorder
        inputScroll.documentView = inputText
        glyph.imageScaling = .scaleProportionallyUpOrDown
        cancelButton.font = Self.buttonFont
        cancelButton.setAccessibilityIdentifier("agent-chat.approval.cancel")
        cancelButton.onPress = { [weak self] in self?.onCancelRequest() }
        revealButton.onPress = { [weak self] in self?.toggleReveal() }
        for view in [surface, headerLabel, glyph, titleLabel, verbLabel, inputSurface, inputScroll, revealButton, cancelButton] as [NSView] {
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    // MARK: Pure presentation

    /// Options that must never be the default/primary (Return) action.
    static func isNeverDefault(_ option: ACPPermissionRequest.Option) -> Bool {
        if option.kind == .allowAlways { return true }
        let id = option.id.lowercased()
        return id.hasPrefix("exit-plan") || id.hasPrefix("exit_plan") || id.hasPrefix("exitplan")
    }

    /// Makes control, format (bidi overrides, zero-width), and line/paragraph
    /// separator characters visible as `\u{XXXX}` so the reviewed input reads
    /// exactly as it will run. Newlines and tabs are kept.
    static func escapedForReview(_ text: String) -> String {
        var output = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control where scalar != "\n" && scalar != "\t", .format, .lineSeparator, .paragraphSeparator:
                output.append(contentsOf: "\\u{\(String(scalar.value, radix: 16, uppercase: true))}".unicodeScalars)
            default:
                output.append(scalar)
            }
        }
        return String(output)
    }

    private struct ContentKey: Equatable {
        var approval: AgentChatItem.Approval
        var verb: AgentToolVerb
        var moreCount: Int
        var unredactedInput: String?
    }

    private static var lastContent: (key: ContentKey, content: Content)?

    /// Cached for the last inputs: redacting a 64 K input on every pane
    /// layout would be heavy main-thread work.
    static func content(approval: AgentChatItem.Approval, verb: AgentToolVerb, moreCount: Int, unredactedInput: String?) -> Content {
        let key = ContentKey(approval: approval, verb: verb, moreCount: moreCount, unredactedInput: unredactedInput)
        if let lastContent, lastContent.key == key { return lastContent.content }
        let content = makeContent(approval: approval, verb: verb, moreCount: moreCount, unredactedInput: unredactedInput)
        lastContent = (key, content)
        return content
    }

    private static func makeContent(approval: AgentChatItem.Approval, verb: AgentToolVerb, moreCount: Int,
                                    unredactedInput: String?) -> Content {
        var header = redactInline(String(approval.agentName.prefix(256))) + " is asking for permission"
        if moreCount > 0 { header += " · \(moreCount) more" }
        let title = redactInline(String(approval.title.prefix(512)))
        let verbText = redactInline(verb.live)
        let raw = String((unredactedInput ?? verb.exactInput ?? approval.subject ?? approval.title).prefix(maximumInputCharacters))
        let source = escapedForReview(raw)
        let masked = redactOutput(source, maximumLines: nil)
        // A mode-changing request (switch_mode, e.g. exiting plan mode) gets no
        // default at all, whatever its options are called.
        let modeChange = approval.kind == .switchMode
        let options = approval.options.prefix(16).enumerated().map { index, option in
            Content.Option(id: option.id, name: redactInline(String(option.name.prefix(256))),
                           isDefault: index == 0 && !modeChange && !isNeverDefault(option))
        }
        return Content(
            header: header, title: title,
            verbLine: verbText.isEmpty || verbText == title ? nil : verbText,
            glyph: verb.glyph,
            maskedInput: masked.text,
            revealedInput: masked.redacted && unredactedInput != nil ? source : nil,
            options: options
        )
    }

    static func buttonSize(_ title: String) -> NSSize {
        let button = AgentChatClosureButton(title: title)
        button.font = buttonFont
        return button.cellSize
    }

    struct Frames {
        var header: NSRect
        var glyph: NSRect
        var title: NSRect
        var verb: NSRect?
        var input: NSRect
        var reveal: NSRect?
        /// Agent options in order, then Cancel Request.
        var buttons: [NSRect]
        var buttonsVertical: Bool
        var height: CGFloat
    }

    static func frames(content: Content, width: CGFloat) -> Frames {
        let contentWidth = max(1, width - padding * 2)
        var y = padding
        let headerLine = AgentChatText.lineHeight(headerFont)
        let header = NSRect(x: padding, y: y, width: contentWidth, height: headerLine)
        y += headerLine + 4
        let titleWidth = max(1, contentWidth - 20)
        let titleHeight = max(14, AgentChatText.height(content.title, font: titleFont, width: titleWidth, maximumLines: 3))
        let lineTop = y
        let title = NSRect(x: padding + 20, y: y, width: titleWidth, height: titleHeight)
        let glyph = NSRect(x: padding, y: lineTop + (min(titleHeight, AgentChatText.lineHeight(titleFont)) - 14) / 2, width: 14, height: 14)
        y += titleHeight
        var verb: NSRect?
        if content.verbLine != nil {
            y += 2
            verb = NSRect(x: padding + 20, y: y, width: titleWidth, height: headerLine)
            y += headerLine
        }
        y += 8
        let textWidth = contentWidth - inputInset.width * 2
        let measured = max(ApprovalInputMeasure.height(content.maskedInput, font: inputFont, width: textWidth),
                           content.revealedInput.map { ApprovalInputMeasure.height($0, font: inputFont, width: textWidth) } ?? 0)
        let inputHeight = min(maximumInputHeight, max(AgentChatText.lineHeight(inputFont), measured) + inputInset.height * 2)
        let input = NSRect(x: padding, y: y, width: contentWidth, height: inputHeight)
        y += inputHeight
        var reveal: NSRect?
        if content.revealedInput != nil {
            y += 4
            let size = AgentChatClosureButton.linkSize(revealTitle)
            reveal = NSRect(x: padding + contentWidth - size.width, y: y, width: size.width, height: size.height)
            y += size.height
        }
        y += 10
        let sizes = (content.options.map(\.name) + [cancelTitle]).map(buttonSize)
        let total = sizes.reduce(0) { $0 + $1.width } + buttonSpacing * CGFloat(max(0, sizes.count - 1))
        let vertical = total > contentWidth
        var buttons: [NSRect] = []
        if vertical {
            for size in sizes {
                buttons.append(NSRect(x: padding, y: y, width: contentWidth, height: size.height))
                y += size.height + buttonSpacing
            }
            y -= sizes.isEmpty ? 0 : buttonSpacing
        } else {
            var x = padding
            let rowHeight = sizes.map(\.height).max() ?? 0
            for size in sizes {
                buttons.append(NSRect(x: x, y: y + (rowHeight - size.height) / 2, width: size.width, height: size.height))
                x += size.width + buttonSpacing
            }
            y += rowHeight
        }
        return Frames(header: header, glyph: glyph, title: title, verb: verb, input: input, reveal: reveal,
                      buttons: buttons, buttonsVertical: vertical, height: y + padding)
    }

    /// `unredactedInput` (extension, defaulted) is the raw command/arguments;
    /// when given and it contains secrets, the card offers "Reveal secrets".
    static func height(approval: AgentChatItem.Approval, verb: AgentToolVerb, width: CGFloat, moreCount: Int = 0,
                       unredactedInput: String? = nil) -> CGFloat {
        frames(content: content(approval: approval, verb: verb, moreCount: moreCount, unredactedInput: unredactedInput), width: width).height
    }

    // MARK: Configuration

    /// `moreCount` requests wait behind this one ("N more"). `onChoose`
    /// receives the option ID.
    func configure(
        approval: AgentChatItem.Approval,
        verb: AgentToolVerb,
        moreCount: Int,
        onChoose: @escaping (String) -> Void,
        onCancelRequest: @escaping () -> Void,
        unredactedInput: String? = nil
    ) {
        let isNewRequest = requestID != approval.requestID
        requestID = approval.requestID
        self.onChoose = onChoose
        self.onCancelRequest = onCancelRequest
        let content = Self.content(approval: approval, verb: verb, moreCount: moreCount, unredactedInput: unredactedInput)
        if isNewRequest || content.revealedInput == nil { isRevealed = false }
        if isNewRequest { armedRequestID = nil }
        self.content = content
        AgentChatText.apply(headerLabel, text: content.header, font: Self.headerFont, color: .textMuted)
        glyph.image = AgentChatGlyphs.image(for: content.glyph)
        glyph.contentTintColor = AgentChatPalette.color(.textMuted)
        AgentChatText.apply(titleLabel, text: content.title, font: Self.titleFont, color: .textPrimary, maximumLines: 3)
        AgentChatText.apply(verbLabel, text: content.verbLine ?? "", font: Self.headerFont, color: .textMuted)
        verbLabel.isHidden = content.verbLine == nil
        updateInputText()
        revealButton.isHidden = content.revealedInput == nil
        while optionButtons.count > content.options.count { optionButtons.removeLast().removeFromSuperview() }
        while optionButtons.count < content.options.count {
            let button = AgentChatClosureButton(title: "")
            button.font = Self.buttonFont
            button.setAccessibilityIdentifier("agent-chat.approval.option")
            addSubview(button)
            optionButtons.append(button)
        }
        for (button, option) in zip(optionButtons, content.options) {
            button.title = option.name
            button.toolTip = option.name
            button.bezelColor = option.isDefault ? AgentChatPalette.color(.live) : nil
            button.keyEquivalent = ""
            let id = option.id
            button.onPress = { [weak self] in self?.onChoose(id) }
        }
        cancelButton.keyEquivalent = ""
        let label = content.header + ": " + content.title
        setAccessibilityLabel(label)
        setAccessibilityHelp(content.defaultOptionID == nil ? nil
            : "Focus this request, then press Return to choose \(content.options[0].name)")
        if isNewRequest, window != nil {
            NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
                .announcement: "Permission requested: " + content.title,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        }
        needsLayout = true
    }

    private func updateInputText() {
        guard let content else { return }
        let text = isRevealed ? content.revealedInput ?? content.maskedInput : content.maskedInput
        if inputText.string != text {
            inputText.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
                .font: Self.inputFont, .foregroundColor: AgentChatPalette.color(.textPrimary),
            ]))
        }
        // Revealed secrets are for reading only: an unredacted copy belongs to
        // the Inspector's concealed-pasteboard action.
        inputText.isSelectable = !isRevealed
        if isRevealed { inputText.setSelectedRange(NSRange(location: 0, length: 0)) }
        revealButton.setLinkStyle(isRevealed ? Self.hideTitle : Self.revealTitle)
    }

    func toggleReveal() {
        guard content?.revealedInput != nil else { return }
        isRevealed.toggle()
        updateInputText()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let content else { return }
        let frames = Self.frames(content: content, width: bounds.width)
        surface.frame = bounds
        headerLabel.frame = frames.header
        glyph.frame = frames.glyph
        titleLabel.frame = frames.title
        verbLabel.frame = frames.verb ?? .zero
        inputSurface.frame = frames.input
        inputScroll.frame = frames.input.insetBy(dx: 1, dy: 1)
        inputText.minSize = NSSize(width: 0, height: inputScroll.contentSize.height)
        inputText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        inputText.setFrameSize(NSSize(width: inputScroll.contentSize.width, height: inputText.frame.height))
        inputText.sizeToFit()
        revealButton.frame = frames.reveal ?? .zero
        let buttons = optionButtons + [cancelButton]
        for (button, frame) in zip(buttons, frames.buttons) { button.frame = frame }
    }

    // MARK: Focus

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    /// The user focuses the card explicitly by clicking it (never automatically).
    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder === self {
            armedRequestID = requestID
        } else {
            window?.makeFirstResponder(self)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { armedRequestID = requestID }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { armedRequestID = nil }
        return resigned
    }

    /// Whether Return would answer the current request now.
    var isArmedForReturn: Bool {
        armedRequestID != nil && armedRequestID == requestID && content?.defaultOptionID != nil
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, isArmedForReturn, let id = content?.defaultOptionID {
            onChoose(id)
            return
        }
        super.keyDown(with: event)
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }
}

/// A decided approval in the timeline: "Approved · <option name>",
/// "Rejected · <name>", "Cancelled", "Withdrawn by agent", or "Stopped".
final class ApprovalRecordView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("agent-chat.approval-record")
    static let sideInset: CGFloat = 8

    let dot = AgentStatusDotView()
    let statusLabel = AgentChatText.makeLabel()
    let titleLabel = AgentChatText.makeLabel()
    private var item: AgentChatItem?

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        setAccessibilityIdentifier(Self.reuseIdentifier.rawValue)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        addSubview(dot)
        addSubview(statusLabel)
        addSubview(titleLabel)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    static var font: NSFont { AgentChatText.font(12, .medium) }

    /// Status text, its color, and the dot for a decision (names redacted).
    static func status(_ decision: AgentChatItem.Approval.Decision)
        -> (text: String, color: AgentChatPalette.Token, dot: AgentStatusDotView.Status) {
        switch decision {
        case .pending: ("Waiting for approval", .live, .running)
        case .chose(_, let name, let allows):
            allows ? ("Approved · " + redactInline(String(name.prefix(256))), .success, .done)
                : ("Rejected · " + redactInline(String(name.prefix(256))), .failure, .failed)
        case .cancelledByUser, .autoCancelled: ("Cancelled", .textMuted, .stopped)
        case .withdrawnByAgent: ("Withdrawn by agent", .textMuted, .stopped)
        case .agentStopped: ("Stopped", .textMuted, .stopped)
        }
    }

    /// `item.content` is `.approval`.
    func configure(item: AgentChatItem, actions: AgentChatRowActions) {
        self.item = item
        guard case .approval(let approval) = item.content else { return }
        let status = Self.status(approval.decision)
        dot.configure(status: status.dot)
        AgentChatText.apply(statusLabel, text: status.text, font: Self.font, color: status.color)
        let title = redactInline(String(approval.title.prefix(512)))
        AgentChatText.apply(titleLabel, text: " · " + title, font: AgentChatText.font(12), color: .textMuted)
        titleLabel.toolTip = title
        setAccessibilityLabel("Permission: \(status.text), \(title)")
        needsLayout = true
    }

    static func height(item: AgentChatItem, width: CGFloat) -> CGFloat {
        max(22, AgentChatText.lineHeight(font) + 8)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        agentChatRemoveAnimations()
    }

    override func layout() {
        super.layout()
        let line = AgentChatText.lineHeight(Self.font)
        let size = AgentStatusDotView.size
        dot.frame = NSRect(x: Self.sideInset + 3, y: (bounds.height - size) / 2, width: size, height: size)
        let x = Self.sideInset + 20
        let y = (bounds.height - line) / 2
        let available = max(0, bounds.width - x - Self.sideInset)
        let statusWidth = min(available, AgentChatText.width(statusLabel.stringValue, font: Self.font))
        statusLabel.frame = NSRect(x: x, y: y, width: statusWidth, height: line)
        titleLabel.frame = NSRect(x: x + statusWidth, y: y, width: max(0, available - statusWidth), height: line)
    }
}
