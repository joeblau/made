import AppKit

// MARK: - Prose rendering

extension NSAttributedString.Key {
    /// Index of the fenced code block a range belongs to (prose cells draw a
    /// bordered surface behind each block).
    static let agentChatCodeBlock = NSAttributedString.Key("agentChatCodeBlock")
}

extension Notification.Name {
    /// A prose message over the off-main threshold finished redacting; the
    /// `object` is the item key. Its cached height and cell are stale.
    static let agentProseDidRender = Notification.Name("agentProseDidRender")
}

/// Agent prose Markdown: fenced code blocks (keeping the fence language) and
/// inline Markdown. An unterminated fence (mid-stream) renders as code so text
/// doesn't jump when it closes. Only http, https, and mailto links survive.
@MainActor
enum AgentProseRenderer {
    enum Segment: Equatable {
        case prose(String)
        case code(language: String?, text: String)
    }

    struct Rendered {
        var text: NSAttributedString
        /// Redacted source of the whole message (what "Copy" writes).
        var copyText: String
        /// Redacted code of each block, by block index (per-block "Copy").
        var blocks: [String]
        /// Identifies this rendering: its measured height is cached by it,
        /// so a rendering reused across revisions is measured once.
        var generation = 0
    }

    static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto"]
    static let bodySize: CGFloat = 15
    static let codeSize: CGFloat = 13
    static let blockInset: CGFloat = 10
    static let blockPadding: CGFloat = 6

    /// One rendering per item key (the newest revision), least recently
    /// used evicted first, bounded by count and by characters.
    private static var cache = AgentRecencyCache<(key: String, rendered: Rendered)>(capacity: 4_096, maximumCost: 8 * 1_024 * 1_024)
    private static var nextGeneration = 0
    /// Off-main renders: the newest finished rendering per item key (shown
    /// while a newer revision redacts), the newest revision still wanted, and
    /// the keys with a redaction in flight.
    private static var latest: [String: Rendered] = [:]
    private static var wanted: [String: (cacheKey: String, raw: String)] = [:]
    private static var inFlight: Set<String> = []

    /// Rendering for an assistant item, cached by (key, revision, zoom).
    /// Text over `AgentRedactionPolicy.offMainThresholdBytes` is redacted off
    /// the main actor (§2.4): until it lands, the previous redacted rendering
    /// of the same message (or a placeholder) is returned, never raw text, and
    /// `.agentProseDidRender` is posted when the new rendering is cached.
    static func rendered(for item: AgentChatItem) -> Rendered {
        guard case .assistant(let raw) = item.content else { return Rendered(text: NSAttributedString(), copyText: "", blocks: []) }
        let key = "\(item.key)#\(item.revision)#\(CockpitUIZoomController.shared.factor)#\(raw.utf16.count)"
        if let cached = cache[item.key], cached.key == key { return cached.rendered }
        guard raw.utf8.count > AgentRedactionPolicy.offMainThresholdBytes else {
            let result = render(raw)
            store(result, itemKey: item.key, cacheKey: key)
            return result
        }
        wanted[item.key] = (key, raw)
        redactInBackground(item.key)
        return latest[item.key] ?? Rendered(text: proseText("Redacting…", spacedAfterCode: false), copyText: "", blocks: [])
    }

    private static func store(_ result: Rendered, itemKey: String, cacheKey: String) {
        cache.set((cacheKey, result), for: itemKey, cost: result.text.length)
    }

    /// One redaction per message at a time; revisions that arrive meanwhile
    /// collapse into a single rerun of the newest text.
    private static func redactInBackground(_ itemKey: String) {
        guard !inFlight.contains(itemKey), let job = wanted.removeValue(forKey: itemKey) else { return }
        inFlight.insert(itemKey)
        Task { @MainActor in
            let raw = job.raw
            let source = await Task.detached(priority: .userInitiated) { redactProse(raw) }.value
            inFlight.remove(itemKey)
            let result = build(source)
            store(result, itemKey: itemKey, cacheKey: job.cacheKey)
            if latest.count > 64 { latest.removeAll(keepingCapacity: true) }
            latest[itemKey] = result
            NotificationCenter.default.post(name: .agentProseDidRender, object: itemKey)
            redactInBackground(itemKey)
        }
    }

    static func segments(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var prose: [Substring] = []
        var code: [Substring] = []
        var language: String?
        var inCode = false
        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { segments.append(.prose(joined)) }
            prose.removeAll()
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    segments.append(.code(language: language, text: code.joined(separator: "\n")))
                    code.removeAll()
                    language = nil
                } else {
                    flushProse()
                    let info = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    let word = info.split(separator: " ").first.map(String.init) ?? ""
                    language = word.isEmpty ? nil : String(word.prefix(32))
                }
                inCode.toggle()
            } else if inCode {
                code.append(line)
            } else {
                prose.append(line)
            }
        }
        if inCode {
            segments.append(.code(language: language, text: code.joined(separator: "\n")))
        } else {
            flushProse()
        }
        return segments
    }

    /// Redacts `raw` (prose policy: known-secret shapes only, layout kept),
    /// then renders it.
    static func render(_ raw: String) -> Rendered {
        build(redactProse(raw))
    }

    /// Renders already-redacted Markdown.
    private static func build(_ source: String) -> Rendered {
        let output = NSMutableAttributedString()
        var blocks: [String] = []
        var previousWasCode = false
        for segment in segments(source) {
            switch segment {
            case .prose(let prose):
                if output.length > 0 { output.append(NSAttributedString(string: "\n", attributes: lastAttributes(output))) }
                output.append(proseText(prose, spacedAfterCode: previousWasCode))
                previousWasCode = false
            case .code(let language, let code):
                if output.length > 0 {
                    output.append(NSAttributedString(string: "\n", attributes: lastAttributes(output)))
                    if previousWasCode {
                        output.append(NSAttributedString(string: "\n", attributes: [.font: AgentChatText.font(4)]))
                    }
                }
                output.append(codeBlock(code, language: language, index: blocks.count))
                blocks.append(code)
                previousWasCode = true
            }
        }
        nextGeneration += 1
        return Rendered(text: output, copyText: source, blocks: blocks, generation: nextGeneration)
    }

    private static func lastAttributes(_ string: NSAttributedString) -> [NSAttributedString.Key: Any] {
        guard string.length > 0 else { return [:] }
        return string.attributes(at: string.length - 1, effectiveRange: nil)
    }

    private static func paragraph(spacing: CGFloat = 8, before: CGFloat = 0, indent: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacing = spacing
        style.paragraphSpacingBefore = before
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        style.tailIndent = -indent
        return style
    }

    private static func proseText(_ prose: String, spacedAfterCode: Bool) -> NSAttributedString {
        let parsed = (try? AttributedString(
            markdown: prose,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        )) ?? AttributedString(prose)
        let output = NSMutableAttributedString()
        let base = AgentChatText.font(bodySize)
        for run in parsed.runs {
            let characters = String(parsed[run.range].characters)
            var font = base
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: AgentChatPalette.color(.textPrimary)]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    font = AgentChatText.font(bodySize - 1, monospaced: true)
                    attributes[.backgroundColor] = AgentChatPalette.color(.card)
                }
                if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            attributes[.font] = font
            if let link = run.link, let scheme = link.scheme?.lowercased(), allowedLinkSchemes.contains(scheme) {
                attributes[.link] = link
                attributes[.foregroundColor] = AgentChatPalette.color(.live)
                attributes[.toolTip] = redactInline(link.absoluteString)
            }
            output.append(NSAttributedString(string: characters, attributes: attributes))
        }
        output.addAttribute(.paragraphStyle, value: paragraph(before: spacedAfterCode ? 8 : 0),
                            range: NSRange(location: 0, length: output.length))
        return output
    }

    private static func codeBlock(_ code: String, language: String?, index: Int) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let isDiff = ["diff", "patch"].contains(language?.lowercased() ?? "")
        output.append(NSAttributedString(string: (language ?? "code") + "\n", attributes: [
            .font: AgentChatText.font(12, .medium),
            .foregroundColor: AgentChatPalette.color(.textMuted),
            .paragraphStyle: paragraph(spacing: 2, before: blockPadding, indent: blockInset),
            .agentChatCodeBlock: index,
        ]))
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        for (offset, line) in lines.enumerated() {
            let isLast = offset == lines.count - 1
            var color = AgentChatPalette.Token.textPrimary
            if isDiff {
                if line.hasPrefix("+"), !line.hasPrefix("+++") {
                    color = .success
                } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                    color = .failure
                } else if line.hasPrefix("@@") || line.hasPrefix("+++") || line.hasPrefix("---") {
                    color = .textMuted
                }
            }
            let text = String(line) + (isLast ? "" : "\n")
            output.append(NSAttributedString(string: text.isEmpty ? " " : text, attributes: [
                .font: AgentChatText.font(codeSize, monospaced: true),
                .foregroundColor: AgentChatPalette.color(color),
                .paragraphStyle: paragraph(spacing: isLast ? blockPadding : 0, indent: blockInset),
                .agentChatCodeBlock: index,
            ]))
        }
        return output
    }
}

/// TextKit 1 measurement matching `ProseTextView`'s layout exactly. The row
/// is as tall as the whole message: the transcript is the only scroll area,
/// so a message never scrolls inside its row. (The cell lays out the full
/// text for display anyway, so measuring it all costs one more pass of the
/// same work; renderings over the off-main threshold are coalesced.)
@MainActor
enum ProseMeasure {
    struct Entry {
        var generation: Int
        var width: CGFloat
        var zoom: Double
        var height: CGFloat
    }

    static let storage = NSTextStorage()
    static let layout = NSLayoutManager()
    static let container: NSTextContainer = {
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        return container
    }()
    /// The newest measurement per item key.
    static var heights = AgentRecencyCache<Entry>(capacity: 8_192)
    /// Layout passes run (tests).
    private(set) static var measureCount = 0

    static func height(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        measureCount += 1
        let box = container
        box.size = NSSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude)
        storage.setAttributedString(text)
        layout.ensureLayout(for: box)
        let height = ceil(layout.usedRect(for: box).height)
        // Release the measured copy; long messages shouldn't stay resident twice.
        storage.setAttributedString(NSAttributedString())
        return height
    }
}

/// A bounded map keyed by string that evicts its least recently used
/// quarter (or, past `maximumCost`, down to three quarters of it) instead of
/// clearing everything, so one pass over many rows doesn't empty it.
struct AgentRecencyCache<Value> {
    let capacity: Int
    let maximumCost: Int
    private var entries: [String: (stamp: UInt64, cost: Int, value: Value)] = [:]
    private var clock: UInt64 = 0
    private(set) var totalCost = 0

    init(capacity: Int, maximumCost: Int = .max) {
        self.capacity = max(4, capacity)
        self.maximumCost = maximumCost
    }

    var count: Int { entries.count }

    subscript(key: String) -> Value? {
        mutating get {
            guard entries[key] != nil else { return nil }
            clock += 1
            entries[key]?.stamp = clock
            return entries[key]?.value
        }
    }

    mutating func set(_ value: Value, for key: String, cost: Int = 0) {
        clock += 1
        totalCost += cost - (entries[key]?.cost ?? 0)
        entries[key] = (clock, cost, value)
        guard entries.count > capacity || totalCost > maximumCost else { return }
        let costTarget = maximumCost == .max ? .max : maximumCost - maximumCost / 4
        var evictCount = entries.count > capacity ? capacity / 4 : 0
        for (oldKey, entry) in entries.sorted(by: { $0.value.stamp < $1.value.stamp }) where oldKey != key {
            guard evictCount > 0 || totalCost > costTarget else { break }
            entries[oldKey] = nil
            totalCost -= entry.cost
            evictCount -= 1
        }
    }
}

/// Selectable prose text that draws a bordered surface behind code blocks
/// and hosts their hover "Copy" buttons.
@MainActor
final class ProseTextView: NSTextView {
    var onMouseDown: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
    }

    /// Bordered rects of each code block, by block index, in view coordinates.
    func blockRects() -> [Int: NSRect] {
        guard let storage = textStorage, let layout = layoutManager, let container = textContainer, storage.length > 0 else { return [:] }
        var rects: [Int: NSRect] = [:]
        let origin = textContainerOrigin
        storage.enumerateAttribute(.agentChatCodeBlock, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let index = value as? Int else { return }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var union = NSRect.null
            layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, _, _ in union = union.union(fragment) }
            guard !union.isNull else { return }
            let rect = NSRect(x: origin.x, y: union.minY + origin.y, width: container.size.width, height: union.height)
            rects[index] = rects[index].map { $0.union(rect) } ?? rect
        }
        return rects
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        for block in blockRects().values where block.intersects(rect) {
            let path = NSBezierPath(roundedRect: block.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            AgentChatPalette.color(.card).setFill()
            path.fill()
            AgentChatPalette.color(.cardBorder).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

// MARK: - Prose cell

/// Agent prose: no bubble, selectable text at its full height (no inner
/// scroll view: wheel and trackpad scrolling over a message move the
/// transcript, the conversation's only scroll area), hover-only "Copy" for
/// the whole message, bordered code blocks with per-block hover copy, colored
/// ```diff fences, and only http/https/mailto links.
final class ProseCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("agent-chat.prose")
    static let leadingInset = AgentChatTimelineLayout.rowInset
    /// Right gutter holding the hover "Copy" button.
    static let copyGutter: CGFloat = 34
    static let verticalInset: CGFloat = 4
    static let textInset: CGFloat = 4

    let textView: ProseTextView
    let copyButton = AgentChatClosureButton.link("Copy", color: .textMuted)
    private var blockButtons: [Int: AgentChatClosureButton] = [:]
    private var rendered = AgentProseRenderer.Rendered(text: NSAttributedString(), copyText: "", blocks: [])
    private var actions = AgentChatRowActions()
    private var itemKey: String?
    private var hovering = false
    private var hoveredBlock: Int?

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        textView = ProseTextView(frame: .zero, textContainer: container)
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        setAccessibilityIdentifier(Self.reuseIdentifier.rawValue)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: Self.textInset)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.setAccessibilityLabel("Agent message")
        copyButton.toolTip = "Copy message"
        copyButton.setAccessibilityLabel("Copy message")
        copyButton.isHidden = true
        copyButton.onPress = { [weak self] in
            guard let self else { return }
            actions.copyText(rendered.copyText)
        }
        // The text view grows with streamed text before the table notes the
        // new row height; clip it to the row instead of over the next one.
        clipsToBounds = true
        addSubview(textView)
        addSubview(copyButton)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// `item.content` is `.assistant`. The row shows the whole message; the
    /// transcript table keeps itself pinned to the end while streaming.
    func configure(item: AgentChatItem, isStreaming: Bool, actions: AgentChatRowActions) {
        self.actions = actions
        let next = AgentProseRenderer.rendered(for: item)
        let selection = itemKey == item.key ? textView.selectedRanges : []
        itemKey = item.key
        rendered = next
        if let storage = textView.textStorage, !storage.isEqual(to: next.text) {
            if next.text.length >= storage.length,
               next.text.attributedSubstring(from: NSRange(location: 0, length: storage.length)).isEqual(to: storage) {
                // Preserve TextKit's layout for unchanged paragraphs while
                // streaming. Closing Markdown syntax can restyle earlier runs;
                // then the full replacement below is necessary.
                storage.append(next.text.attributedSubstring(from: NSRange(location: storage.length, length: next.text.length - storage.length)))
            } else {
                storage.setAttributedString(next.text)
            }
            let valid = selection.filter { NSMaxRange($0.rangeValue) <= next.text.length }
            if !valid.isEmpty { textView.selectedRanges = valid }
        }
        textView.setAccessibilityValue(isStreaming ? "Streaming" : nil)
        syncBlockButtons()
        copyButton.isHidden = !hovering || next.copyText.isEmpty
        needsLayout = true
    }

    static func textWidth(for width: CGFloat) -> CGFloat {
        max(1, width - leadingInset - copyGutter)
    }

    /// The full laid-out text height (no cap), measured per rendering, not
    /// per revision: a long message reusing its previous rendering while a
    /// newer one redacts is not laid out again.
    static func height(item: AgentChatItem, width: CGFloat) -> CGFloat {
        let rendered = AgentProseRenderer.rendered(for: item)
        let textWidth = textWidth(for: width)
        let zoom = CockpitUIZoomController.shared.factor
        let textHeight: CGFloat
        if let cached = ProseMeasure.heights[item.key], cached.width == textWidth, cached.zoom == zoom,
           cached.generation == rendered.generation {
            textHeight = cached.height
        } else {
            textHeight = rendered.text.length == 0 ? 0 : ProseMeasure.height(rendered.text, width: textWidth)
            ProseMeasure.heights.set(ProseMeasure.Entry(generation: rendered.generation, width: textWidth, zoom: zoom,
                                                        height: textHeight), for: item.key)
        }
        return max(24, textHeight + textInset * 2 + verticalInset * 2)
    }

    override func layout() {
        super.layout()
        let available = max(0, bounds.height - Self.verticalInset * 2)
        textView.minSize = NSSize(width: 0, height: available)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.frame = NSRect(x: Self.leadingInset, y: Self.verticalInset, width: Self.textWidth(for: bounds.width), height: available)
        if let container = textView.textContainer { textView.layoutManager?.ensureLayout(for: container) }
        textView.sizeToFit()
        let size = copyButton.cellSize
        copyButton.frame = NSRect(x: bounds.width - size.width - 4, y: Self.verticalInset, width: size.width, height: size.height)
        positionBlockButtons()
    }

    private func syncBlockButtons() {
        for (index, button) in blockButtons where index >= rendered.blocks.count {
            button.removeFromSuperview()
            blockButtons[index] = nil
        }
        for index in rendered.blocks.indices where blockButtons[index] == nil {
            let button = AgentChatClosureButton.link("Copy", color: .textMuted)
            button.toolTip = "Copy code"
            button.setAccessibilityLabel("Copy code block \(index + 1)")
            button.isHidden = true
            button.onPress = { [weak self] in
                guard let self, rendered.blocks.indices.contains(index) else { return }
                actions.copyText(rendered.blocks[index])
            }
            textView.addSubview(button)
            blockButtons[index] = button
        }
    }

    private func positionBlockButtons() {
        let rects = textView.blockRects()
        for (index, button) in blockButtons {
            guard let rect = rects[index] else {
                button.isHidden = true
                continue
            }
            let size = button.cellSize
            button.frame = NSRect(x: rect.maxX - size.width - 6, y: rect.minY + 2, width: size.width, height: size.height)
            button.isHidden = hoveredBlock != index
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        setHover(true, block: block(at: event))
    }

    override func mouseMoved(with event: NSEvent) {
        setHover(true, block: block(at: event))
    }

    override func mouseExited(with event: NSEvent) {
        setHover(false, block: nil)
    }

    /// Test and accessibility hook: shows hover affordances as if the pointer
    /// were over the message (and over `block`, when given).
    func setHover(_ hovering: Bool, block: Int?) {
        self.hovering = hovering
        hoveredBlock = block
        copyButton.isHidden = !hovering || rendered.copyText.isEmpty
        for (index, button) in blockButtons { button.isHidden = block != index }
    }

    private func block(at event: NSEvent) -> Int? {
        let point = textView.convert(event.locationInWindow, from: nil)
        return textView.blockRects().first { $0.value.contains(point) }?.key
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        agentChatRemoveAnimations()
        setHover(false, block: nil)
    }
}

// MARK: - User bubble

/// User message: right-aligned bubble ≤ 75% width, accent-tinted surface,
/// attachments, no copy icon. An optional muted caption beneath the bubble
/// marks steers ("Sending to running turn…" / "Sent to running turn").
final class UserBubbleCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("agent-chat.user")
    static let maximumWidthFraction: CGFloat = 0.75
    static let sideInset = AgentChatTimelineLayout.rowInset
    static let verticalInset: CGFloat = 4
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 8
    static let attachmentHeight: CGFloat = 24
    static let thumbnailSize = NSSize(width: 28, height: 24)

    let bubble = AgentChatSurfaceView(fill: .userBubble, cornerRadius: 12)
    let messageLabel = AgentChatText.makeLabel(wrapping: true, selectable: true)
    let captionLabel = AgentChatText.makeLabel()
    private var attachmentViews: [(image: NSImageView, name: NSTextField)] = []
    private var item: AgentChatItem?
    private var caption: String?

    static var captionFont: NSFont { AgentChatText.font(12) }

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        setAccessibilityIdentifier(Self.reuseIdentifier.rawValue)
        addSubview(bubble)
        bubble.addSubview(messageLabel)
        captionLabel.isHidden = true
        addSubview(captionLabel)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    private struct Layout {
        var bubble: NSRect
        var attachments: [(image: NSRect?, name: NSRect)]
        var message: NSRect?
        var caption: NSRect?
        var height: CGFloat
    }

    private static func text(_ item: AgentChatItem) -> String {
        guard case .user(let value) = item.content else { return "" }
        return redactProse(value)
    }

    private static func attachmentName(_ attachment: AgentChatAttachment) -> String {
        redactInline(String(attachment.name.prefix(256)))
    }

    private static func layout(item: AgentChatItem, width: CGFloat, caption: String?) -> Layout {
        let font = AgentChatText.font(AgentProseRenderer.bodySize)
        let nameFont = AgentChatText.font(12)
        let maximumContent = max(1, floor((width - sideInset * 2) * maximumWidthFraction) - horizontalPadding * 2)
        let message = text(item)
        let messageWidth = message.isEmpty ? 0 : min(maximumContent, AgentChatText.width(message, font: font) + 1)
        let messageHeight = message.isEmpty ? 0 : AgentChatText.height(message, font: font, width: messageWidth)
        var contentWidth = messageWidth
        var rows: [(hasImage: Bool, width: CGFloat)] = []
        for attachment in item.attachments {
            let hasImage = attachment.thumbnail != nil
            let lead = hasImage ? thumbnailSize.width + 6 : 0
            let rowWidth = min(maximumContent, lead + AgentChatText.width(attachmentName(attachment), font: nameFont))
            rows.append((hasImage, rowWidth))
            contentWidth = max(contentWidth, rowWidth)
        }
        let bubbleWidth = contentWidth + horizontalPadding * 2
        var y = verticalPadding
        var attachments: [(image: NSRect?, name: NSRect)] = []
        let nameHeight = AgentChatText.lineHeight(nameFont)
        for row in rows {
            let image = row.hasImage ? NSRect(origin: NSPoint(x: horizontalPadding, y: y), size: thumbnailSize) : nil
            let lead = row.hasImage ? thumbnailSize.width + 6 : 0
            let name = NSRect(x: horizontalPadding + lead, y: y + (attachmentHeight - nameHeight) / 2,
                              width: max(0, row.width - lead), height: nameHeight)
            attachments.append((image, name))
            y += attachmentHeight + 4
        }
        if !rows.isEmpty { y += message.isEmpty ? -4 : 2 }
        var messageFrame: NSRect?
        if !message.isEmpty {
            messageFrame = NSRect(x: horizontalPadding, y: y, width: messageWidth, height: messageHeight)
            y += messageHeight
        }
        let bubbleHeight = y + verticalPadding
        let bubbleFrame = NSRect(x: max(sideInset, width - sideInset - bubbleWidth), y: verticalInset,
                                 width: bubbleWidth, height: bubbleHeight)
        var height = bubbleHeight + verticalInset * 2
        var captionFrame: NSRect?
        if let caption, !caption.isEmpty {
            let lineHeight = AgentChatText.lineHeight(captionFont)
            let available = max(1, width - sideInset * 2)
            let captionWidth = min(available, ceil(AgentChatText.width(caption, font: captionFont)) + 2)
            captionFrame = NSRect(x: width - sideInset - captionWidth, y: bubbleFrame.maxY + 2, width: captionWidth, height: lineHeight)
            height += lineHeight + 2
        }
        return Layout(bubble: bubbleFrame, attachments: attachments, message: messageFrame, caption: captionFrame, height: height)
    }

    /// `item.content` is `.user`; attachments come from `item.attachments`.
    /// `caption` (muted, beneath the bubble) marks a pending or delivered steer.
    func configure(item: AgentChatItem, actions: AgentChatRowActions, caption: String? = nil) {
        self.item = item
        self.caption = caption
        AgentChatText.apply(captionLabel, text: caption ?? "", font: Self.captionFont, color: .textMuted)
        captionLabel.isHidden = (caption ?? "").isEmpty
        let message = Self.text(item)
        AgentChatText.apply(messageLabel, text: message, font: AgentChatText.font(AgentProseRenderer.bodySize), color: .textPrimary)
        messageLabel.isHidden = message.isEmpty
        while attachmentViews.count > item.attachments.count {
            let removed = attachmentViews.removeLast()
            removed.image.removeFromSuperview()
            removed.name.removeFromSuperview()
        }
        while attachmentViews.count < item.attachments.count {
            let image = NSImageView()
            image.imageScaling = .scaleProportionallyUpOrDown
            let name = AgentChatText.makeLabel()
            bubble.addSubview(image)
            bubble.addSubview(name)
            attachmentViews.append((image, name))
        }
        for (attachment, views) in zip(item.attachments, attachmentViews) {
            views.image.image = attachment.thumbnail.flatMap(NSImage.init(data:))
            views.image.isHidden = views.image.image == nil
            AgentChatText.apply(views.name, text: Self.attachmentName(attachment), font: AgentChatText.font(12), color: .textMuted)
            views.name.toolTip = Self.attachmentName(attachment)
        }
        setAccessibilityLabel("You: " + redactInline(String(message.prefix(400))) + (caption.map { ". " + $0 } ?? ""))
        needsLayout = true
    }

    static func height(item: AgentChatItem, width: CGFloat, caption: String? = nil) -> CGFloat {
        layout(item: item, width: width, caption: caption).height
    }

    override func layout() {
        super.layout()
        guard let item else { return }
        let layout = Self.layout(item: item, width: bounds.width, caption: caption)
        captionLabel.frame = layout.caption ?? .zero
        bubble.frame = layout.bubble
        for (frames, views) in zip(layout.attachments, attachmentViews) {
            views.image.frame = frames.image ?? .zero
            views.name.frame = frames.name
        }
        messageLabel.frame = layout.message ?? .zero
    }
}

// MARK: - Notice

/// Notices such as stop reasons. No copy; a failed-turn notice offers "Send again".
final class NoticeCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("agent-chat.notice")
    static let sideInset = AgentChatTimelineLayout.rowInset
    static let verticalInset: CGFloat = 4
    static let maximumLines = 6

    let messageLabel = AgentChatText.makeLabel(wrapping: true, selectable: true)
    let sendAgainButton = AgentChatClosureButton.link("Send again")
    private var offersSendAgain = false
    private var item: AgentChatItem?

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        setAccessibilityIdentifier(Self.reuseIdentifier.rawValue)
        addSubview(messageLabel)
        addSubview(sendAgainButton)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    private static func text(_ item: AgentChatItem) -> String {
        guard case .notice(let value) = item.content else { return "" }
        return redactProse(value.split(separator: "\n", maxSplits: 40, omittingEmptySubsequences: false).prefix(40).joined(separator: "\n"))
    }

    /// `item.content` is `.notice`. "Send again" calls `actions.sendAgain`.
    func configure(item: AgentChatItem, offersSendAgain: Bool, actions: AgentChatRowActions) {
        self.item = item
        self.offersSendAgain = offersSendAgain
        AgentChatText.apply(messageLabel, text: Self.text(item), font: AgentChatText.font(12), color: .textMuted,
                            maximumLines: Self.maximumLines)
        sendAgainButton.isHidden = !offersSendAgain
        sendAgainButton.onPress = { actions.sendAgain() }
        needsLayout = true
    }

    private static func messageHeight(_ item: AgentChatItem, width: CGFloat) -> CGFloat {
        AgentChatText.height(text(item), font: AgentChatText.font(12), width: max(1, width - sideInset * 2), maximumLines: maximumLines)
    }

    /// `offersSendAgain` (extension, defaulted) reserves the "Send again" line.
    static func height(item: AgentChatItem, width: CGFloat, offersSendAgain: Bool = false) -> CGFloat {
        let button = offersSendAgain ? 2 + AgentChatClosureButton.linkSize("Send again").height : 0
        return max(20, messageHeight(item, width: width) + button + verticalInset * 2)
    }

    override func layout() {
        super.layout()
        guard let item else { return }
        let height = Self.messageHeight(item, width: bounds.width)
        messageLabel.frame = NSRect(x: Self.sideInset, y: Self.verticalInset, width: max(0, bounds.width - Self.sideInset * 2), height: height)
        let size = sendAgainButton.cellSize
        sendAgainButton.frame = NSRect(x: Self.sideInset, y: Self.verticalInset + height + 2, width: size.width, height: size.height)
    }
}

// MARK: - Plan row

/// Compact `☰ Plan · 3/7 done` row; click opens the Inspector on `.plan(key:)`.
final class PlanRowView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("agent-chat.plan")
    static let rowHeight: CGFloat = 24

    let glyph = NSImageView()
    let label = AgentChatText.makeLabel()
    private var item: AgentChatItem?
    private var actions = AgentChatRowActions()

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        setAccessibilityIdentifier(Self.reuseIdentifier.rawValue)
        glyph.image = AgentChatGlyphs.image(for: .plan)
        glyph.contentTintColor = AgentChatPalette.color(.textMuted)
        addSubview(glyph)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    static func summary(_ entries: [ACPPlanEntry]) -> String {
        let done = entries.filter { $0.status == "completed" }.count
        var text = "Plan · \(done)/\(entries.count) done"
        if let current = entries.first(where: { $0.status == "in_progress" }) {
            text += " · " + redactInline(String(current.content.prefix(200)))
        }
        return text
    }

    /// `item.content` is `.plan`.
    func configure(item: AgentChatItem, actions: AgentChatRowActions) {
        self.item = item
        self.actions = actions
        guard case .plan(let entries) = item.content else { return }
        let text = Self.summary(entries)
        AgentChatText.apply(label, text: text, font: AgentChatText.font(12, .medium), color: .textMuted)
        label.toolTip = text
        setAccessibilityLabel(text)
        setAccessibilityHelp("Opens the plan in the Inspector")
        needsLayout = true
    }

    static func height(item: AgentChatItem, width: CGFloat) -> CGFloat {
        max(rowHeight, AgentChatText.lineHeight(AgentChatText.font(12, .medium)) + 8)
    }

    override func layout() {
        super.layout()
        let lineHeight = AgentChatText.lineHeight(AgentChatText.font(12, .medium))
        glyph.frame = NSRect(x: 8, y: (bounds.height - 14) / 2, width: 14, height: 14)
        label.frame = NSRect(x: 28, y: (bounds.height - lineHeight) / 2, width: max(0, bounds.width - 36), height: lineHeight)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        open()
    }

    override func accessibilityPerformPress() -> Bool {
        open()
        return true
    }

    private func open() {
        guard let item else { return }
        actions.openInspector(.plan(key: item.key), nil)
    }
}
