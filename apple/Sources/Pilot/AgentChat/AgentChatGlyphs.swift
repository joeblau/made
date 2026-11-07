import AppKit
import QuartzCore

/// Agent Chat color tokens (dynamic light/dark, contrast-tested). Never use
/// LegibleAccent as a foreground. Dot fills may use system colors.
enum AgentChatPalette {
    /// sRGB hex values, 0xRRGGBB, for each appearance.
    struct Token: Equatable, Sendable {
        var light: UInt32
        var dark: UInt32
    }

    static func color(_ token: Token) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = isDark(appearance) ? token.dark : token.light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// WCAG 2.x relative luminance of an sRGB hex color.
    static func relativeLuminance(_ hex: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let value = Double((hex >> shift) & 0xFF) / 255
            return value <= 0.039_28 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    /// WCAG contrast ratio, 1…21.
    static func contrastRatio(_ first: UInt32, _ second: UInt32) -> Double {
        let lighter = max(relativeLuminance(first), relativeLuminance(second))
        let darker = min(relativeLuminance(first), relativeLuminance(second))
        return (lighter + 0.05) / (darker + 0.05)
    }

    static func contrastRatio(_ text: Token, on surface: Token, dark: Bool) -> Double {
        dark ? contrastRatio(text.dark, surface.dark) : contrastRatio(text.light, surface.light)
    }

    /// Every text token on every surface it is drawn on; each must meet 4.5:1.
    static let textPairs: [(name: String, text: Token, surface: Token)] = {
        var pairs: [(String, Token, Token)] = []
        let texts: [(String, Token)] = [
            ("textPrimary", .textPrimary), ("textMuted", .textMuted), ("live", .live),
            ("failure", .failure), ("success", .success),
        ]
        for (surfaceName, surface) in [("thread", Token.thread), ("card", .card), ("hover", .hover)] {
            for (textName, text) in texts { pairs.append(("\(textName) on \(surfaceName)", text, surface)) }
        }
        pairs.append(("textPrimary on userBubble", .textPrimary, .userBubble))
        pairs.append(("textMuted on userBubble", .textMuted, .userBubble))
        return pairs
    }()
}

extension AgentChatPalette.Token {
    static let thread = Self(light: 0xFFFFFF, dark: 0x0E0F11)
    static let card = Self(light: 0xF3F4F6, dark: 0x1C1F23)
    static let cardBorder = Self(light: 0xD5D8DD, dark: 0x30343A)
    static let textPrimary = Self(light: 0x1D1F22, dark: 0xECEEF1)
    static let textMuted = Self(light: 0x5B6169, dark: 0xA4AAB2)
    static let live = Self(light: 0x0A5BC4, dark: 0x7CB4FF)
    static let failure = Self(light: 0xC4271D, dark: 0xFF7A70)
    static let success = Self(light: 0x1E7A3E, dark: 0x5FD38A)
    /// Hovered step rows and chips (text tokens keep ≥ 4.5:1 on it).
    static let hover = Self(light: 0xEBEDF0, dark: 0x262A2F)
    /// User bubbles: an accent-tinted surface, never LegibleAccent.
    static let userBubble = Self(light: 0xE3EDFB, dark: 0x1D2B40)
}

/// Motion policy: 0.15–0.2 s ease-out, nothing under Reduce Motion.
@MainActor
enum AgentChatMotion {
    static let duration: TimeInterval = 0.18
    /// Injectable for tests; defaults to the system setting.
    static var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Whether a one-shot transition (expand/collapse) should animate in `view`:
    /// never under Reduce Motion or while the view's window is hidden.
    static func animatesTransitions(in view: NSView) -> Bool {
        !reduceMotion() && view.window?.isVisible == true
    }

    static var timing: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeOut) }
}

/// 14 pt monochrome template glyphs for every `AgentToolVerb.Glyph`.
@MainActor
enum AgentChatGlyphs {
    private static var cache: [String: NSImage] = [:]

    static func image(for glyph: AgentToolVerb.Glyph, pointSize: CGFloat = 14) -> NSImage {
        let key = "\(glyph)-\(pointSize)"
        if let cached = cache[key] { return cached }
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: true) { rect in
            AgentChatGlyphs.draw(glyph, in: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityName(glyph)
        cache[key] = image
        return image
    }

    static func accessibilityName(_ glyph: AgentToolVerb.Glyph) -> String {
        switch glyph {
        case .shell: "Command"
        case .read: "Read"
        case .search: "Search"
        case .edit: "Edit"
        case .create: "Create"
        case .delete: "Delete"
        case .move: "Move"
        case .fetch: "Fetch"
        case .web: "Web search"
        case .think: "Reasoning"
        case .agent: "Agent"
        case .plan: "Plan"
        case .mcp: "Tool server"
        case .other: "Tool"
        }
    }

    /// Draws `glyph` in a 14-unit flipped grid scaled to `rect`.
    nonisolated static func draw(_ glyph: AgentToolVerb.Glyph, in rect: NSRect) {
        let scale = rect.width / 14
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }
        func oval(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) -> NSBezierPath {
            NSBezierPath(ovalIn: NSRect(x: rect.minX + (x - radius) * scale, y: rect.minY + (y - radius) * scale,
                                        width: radius * 2 * scale, height: radius * 2 * scale))
        }
        func segments(_ path: NSBezierPath, _ lines: [[(CGFloat, CGFloat)]]) {
            for line in lines {
                guard let first = line.first else { continue }
                path.move(to: point(first.0, first.1))
                for next in line.dropFirst() { path.line(to: point(next.0, next.1)) }
            }
        }
        let document = NSBezierPath(roundedRect: NSRect(x: rect.minX + 2.5 * scale, y: rect.minY + 1.5 * scale,
                                                         width: 9 * scale, height: 11 * scale),
                                    xRadius: 1.6 * scale, yRadius: 1.6 * scale)
        let path = NSBezierPath()
        var fills: [NSBezierPath] = []
        switch glyph {
        case .shell:
            segments(path, [[(2.5, 3.5), (6, 7), (2.5, 10.5)], [(7.5, 10.5), (11.5, 10.5)]])
        case .read:
            path.append(document)
            segments(path, [[(4.8, 5), (9.2, 5)], [(4.8, 7.5), (9.2, 7.5)], [(4.8, 10), (7.8, 10)]])
        case .search:
            path.append(oval(6, 6, 3.8))
            segments(path, [[(8.8, 8.8), (12.2, 12.2)]])
        case .edit:
            segments(path, [[(3, 11), (3.6, 8.4), (9.6, 2.4), (11.6, 4.4), (5.6, 10.4), (3, 11)], [(8.4, 3.6), (10.4, 5.6)]])
        case .create:
            path.append(document)
            segments(path, [[(7, 4.6), (7, 9.4)], [(4.6, 7), (9.4, 7)]])
        case .delete:
            segments(path, [[(2, 3.6), (12, 3.6)], [(5.4, 3.6), (5.4, 1.8), (8.6, 1.8), (8.6, 3.6)],
                            [(3.6, 3.6), (4.3, 12.2), (9.7, 12.2), (10.4, 3.6)]])
        case .move:
            segments(path, [[(2, 7), (12, 7)], [(8.5, 3.5), (12, 7), (8.5, 10.5)]])
        case .fetch:
            segments(path, [[(7, 9.8), (7, 2.2)], [(3.8, 5.4), (7, 2.2), (10.2, 5.4)], [(2.5, 12), (11.5, 12)]])
        case .web:
            path.append(oval(7, 7, 5.5))
            path.append(NSBezierPath(ovalIn: NSRect(x: rect.minX + 4.6 * scale, y: rect.minY + 1.5 * scale,
                                                    width: 4.8 * scale, height: 11 * scale)))
            segments(path, [[(1.5, 7), (12.5, 7)]])
        case .think:
            path.append(oval(7, 7, 5))
            path.setLineDash([1.7 * scale, 1.5 * scale], count: 2, phase: 0)
        case .agent:
            path.append(oval(7, 4.8, 2.6))
            path.move(to: point(2.4, 12.6))
            path.curve(to: point(11.6, 12.6), controlPoint1: point(2.4, 8.2), controlPoint2: point(11.6, 8.2))
        case .plan:
            for row: CGFloat in [3.5, 7, 10.5] { fills.append(oval(3, row, 0.95)) }
            segments(path, [[(5.6, 3.5), (12, 3.5)], [(5.6, 7), (12, 7)], [(5.6, 10.5), (12, 10.5)]])
        case .mcp:
            path.append(oval(4, 10, 2))
            path.append(oval(10, 4, 2))
            segments(path, [[(5.4, 8.6), (8.6, 5.4)]])
        case .other:
            segments(path, [[(7, 2), (12, 7), (7, 12), (2, 7), (7, 2)]])
        }
        path.lineWidth = 1.4 * scale
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor.black.setStroke()
        NSColor.black.setFill()
        path.stroke()
        for fill in fills { fill.fill() }
    }
}

/// Callbacks every Agent Chat view uses instead of holding the session.
/// Copy callbacks receive already-redacted text; the owner writes the pasteboard.
@MainActor
struct AgentChatRowActions {
    var openInspector: (AgentInspectorSubject, AgentInspectorTab?) -> Void = { _, _ in }
    var copyText: (String) -> Void = { _ in }
    /// User disclosure toggle for a group or roster ID.
    var toggleExpanded: (String) -> Void = { _ in }
    /// "Show N more" in a settled group with > 15 steps.
    var showAll: (String) -> Void = { _ in }
    /// The settle animation for a group ID finished (or was skipped).
    var collapseFinished: (String) -> Void = { _ in }
    /// Step key.
    var askToRetry: (String) -> Void = { _ in }
    /// Child session ID.
    var askToContinue: (String) -> Void = { _ in }
    var sendAgain: () -> Void = {}
}

/// Status dot with a distinct shape per state: queued gray dashed ring,
/// running filled live color with an opacity pulse (none under Reduce
/// Motion), done green check, failed red x, stopped hollow gray ring,
/// background half ring.
final class AgentStatusDotView: NSView {
    enum Status: Equatable, Sendable {
        case queued, running, done, failed, stopped, background

        init(_ lifecycle: AgentChatItem.Subagent.Lifecycle) {
            switch lifecycle {
            case .queued: self = .queued
            case .running: self = .running
            case .done, .ended: self = .done
            case .failed: self = .failed
            case .cancelled: self = .stopped
            case .background: self = .background
            }
        }

        init(_ tool: AgentChatItem.ToolCall) {
            if tool.isRunning {
                self = .running
                return
            }
            switch tool.outcome {
            case .failed: self = .failed
            case .cancelled, .rejected, .interrupted, .notFinished: self = .stopped
            case .completed: self = .done
            case nil: self = tool.status == .failed ? .failed : .done
            }
        }

        var accessibilityName: String {
            switch self {
            case .queued: "Queued"
            case .running: "Running"
            case .done: "Done"
            case .failed: "Failed"
            case .stopped: "Stopped"
            case .background: "Running in background"
            }
        }
    }

    static let size: CGFloat = 10
    static let pulseKey = "agent-chat.pulse"
    private(set) var status: Status = .queued

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(status.accessibilityName)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    var isPulsing: Bool { layer?.animation(forKey: Self.pulseKey) != nil }

    func configure(status: Status) {
        if self.status != status {
            self.status = status
            needsDisplay = true
        }
        setAccessibilityLabel(status.accessibilityName)
        setAccessibilityValue(status.accessibilityName)
        updatePulse()
    }

    /// Removes the pulse (reuse); `configure` adds it back while running.
    func removeAnimations() {
        layer?.removeAllAnimations()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePulse()
    }

    private func updatePulse() {
        guard let layer else { return }
        let wantsPulse = status == .running && !AgentChatMotion.reduceMotion()
        if !wantsPulse {
            layer.removeAnimation(forKey: Self.pulseKey)
            layer.opacity = 1
            return
        }
        guard layer.animation(forKey: Self.pulseKey) == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.35
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: Self.pulseKey)
    }

    override func draw(_ dirtyRect: NSRect) {
        let side = min(bounds.width, bounds.height)
        let box = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        let unit = side / 10
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: box.minX + x * unit, y: box.minY + y * unit) }
        let ring = NSBezierPath(ovalIn: box.insetBy(dx: unit, dy: unit))
        ring.lineWidth = 1.4 * unit
        switch status {
        case .queued:
            ring.setLineDash([1.6 * unit, 1.3 * unit], count: 2, phase: 0)
            AgentChatPalette.color(.textMuted).setStroke()
            ring.stroke()
        case .running:
            AgentChatPalette.color(.live).setFill()
            NSBezierPath(ovalIn: box.insetBy(dx: 0.5 * unit, dy: 0.5 * unit)).fill()
        case .done:
            let check = NSBezierPath()
            check.move(to: point(1.6, 5.3))
            check.line(to: point(4.1, 7.8))
            check.line(to: point(8.6, 2.6))
            check.lineWidth = 1.8 * unit
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            AgentChatPalette.color(.success).setStroke()
            check.stroke()
        case .failed:
            let cross = NSBezierPath()
            cross.move(to: point(2.2, 2.2))
            cross.line(to: point(7.8, 7.8))
            cross.move(to: point(7.8, 2.2))
            cross.line(to: point(2.2, 7.8))
            cross.lineWidth = 1.8 * unit
            cross.lineCapStyle = .round
            AgentChatPalette.color(.failure).setStroke()
            cross.stroke()
        case .stopped:
            AgentChatPalette.color(.textMuted).setStroke()
            ring.stroke()
        case .background:
            AgentChatPalette.color(.textMuted).withAlphaComponent(0.6).setStroke()
            ring.stroke()
            let half = NSBezierPath()
            half.move(to: point(5, 1))
            half.curve(to: point(5, 9), controlPoint1: point(-0.4, 1), controlPoint2: point(-0.4, 9))
            half.close()
            AgentChatPalette.color(.live).setFill()
            half.fill()
        }
    }
}

// MARK: - Shared text metrics and controls

/// Label construction and measurement shared by every Agent Chat view, so a
/// static `height` function measures exactly what the view draws.
@MainActor
enum AgentChatText {
    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular, monospaced: Bool = false) -> NSFont {
        CockpitTypography.font(size: size, weight: weight, monospaced: monospaced)
    }

    /// A non-editable label. Single-line labels truncate their tail; wrapping
    /// labels truncate their last visible line past `maximumLines`.
    static func makeLabel(wrapping: Bool = false, selectable: Bool = false) -> NSTextField {
        let field = wrapping ? NSTextField(wrappingLabelWithString: "") : NSTextField(labelWithString: "")
        field.isEditable = false
        field.isSelectable = selectable
        field.isBordered = false
        field.drawsBackground = false
        field.cell?.truncatesLastVisibleLine = true
        if !wrapping {
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            field.cell?.usesSingleLineMode = true
        }
        return field
    }

    static func apply(_ field: NSTextField, text: String, font: NSFont, color: AgentChatPalette.Token, maximumLines: Int? = nil) {
        if field.stringValue != text { field.stringValue = text }
        field.font = font
        field.textColor = AgentChatPalette.color(color)
        if let maximumLines { field.maximumNumberOfLines = maximumLines }
    }

    private static let measuringLine = makeLabel()
    private static let measuringWrap = makeLabel(wrapping: true)
    private static var lineHeights: [String: CGFloat] = [:]

    static func lineHeight(_ font: NSFont) -> CGFloat {
        let key = "\(font.fontName)-\(font.pointSize)"
        if let cached = lineHeights[key] { return cached }
        let value = size(of: "Xgy", font: font, width: nil).height
        lineHeights[key] = value
        return value
    }

    static func width(_ text: String, font: NSFont) -> CGFloat {
        size(of: text, font: font, width: nil).width
    }

    /// Height of `text` wrapped to `width` (`maximumLines` 0: unlimited).
    static func height(_ text: String, font: NSFont, width: CGFloat, maximumLines: Int = 0) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let field = measuringWrap
        field.maximumNumberOfLines = maximumLines
        field.font = font
        field.stringValue = text
        let size = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(1, width), height: .greatestFiniteMagnitude))
        return ceil(size?.height ?? 0)
    }

    /// Single-line size; `width` nil measures the untruncated intrinsic width.
    private static func size(of text: String, font: NSFont, width: CGFloat?) -> NSSize {
        let field = measuringLine
        field.font = font
        field.stringValue = text
        let bounds = NSRect(x: 0, y: 0, width: width ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let size = field.cell?.cellSize(forBounds: bounds) ?? .zero
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }
}

/// A rounded surface drawn in `draw(_:)` (so snapshots capture it) with
/// palette fill and optional border.
final class AgentChatSurfaceView: NSView {
    var fill: AgentChatPalette.Token? { didSet { needsDisplay = true } }
    var border: AgentChatPalette.Token? { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 8 { didSet { needsDisplay = true } }

    init(fill: AgentChatPalette.Token?, border: AgentChatPalette.Token? = nil, cornerRadius: CGFloat = 8) {
        self.fill = fill
        self.border = border
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        guard rect.width > 0, rect.height > 0 else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        if let fill {
            AgentChatPalette.color(fill).setFill()
            path.fill()
        }
        if let border {
            AgentChatPalette.color(border).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

/// A button that runs a closure. `link` buttons are borderless text in a
/// palette color.
final class AgentChatClosureButton: NSButton {
    var onPress: () -> Void

    init(title: String, onPress: @escaping () -> Void = {}) {
        self.onPress = onPress
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        action = #selector(press)
    }

    required init?(coder: NSCoder) { nil }

    static func link(_ title: String, size: CGFloat = 12, color: AgentChatPalette.Token = .live,
                     onPress: @escaping () -> Void = {}) -> AgentChatClosureButton {
        let button = AgentChatClosureButton(title: title, onPress: onPress)
        button.isBordered = false
        button.setLinkStyle(title, size: size, color: color)
        return button
    }

    func setLinkStyle(_ title: String, size: CGFloat = 12, color: AgentChatPalette.Token = .live) {
        self.title = title
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: AgentChatText.font(size, .medium),
            .foregroundColor: AgentChatPalette.color(color),
        ])
        setAccessibilityLabel(title)
    }

    private static var linkSizes: [String: NSSize] = [:]

    /// Cached cell size of a `link` button titled `title` (static layouts).
    static func linkSize(_ title: String, size: CGFloat = 12) -> NSSize {
        let key = "\(title)#\(size)#\(CockpitUIZoomController.shared.factor)"
        if let cached = linkSizes[key] { return cached }
        let value = link(title, size: size).cellSize
        if linkSizes.count > 256 { linkSizes.removeAll(keepingCapacity: true) }
        linkSizes[key] = value
        return value
    }

    /// Exact size of the button's cell, used by static layouts.
    var cellSize: NSSize {
        let size = cell?.cellSize ?? .zero
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    @objc private func press() { onPress() }
}

/// Live status line: the text is always drawn in the live color (≥ 4.5:1);
/// a brighter highlight sweeps across it through a CAGradientLayer mask. The
/// sweep is omitted under Reduce Motion. Text updates are throttled to 4 Hz.
final class AgentChatShimmerLabel: NSView {
    static let animationKey = "agent-chat.shimmer"
    static let minimumUpdateInterval: TimeInterval = 0.25
    private let base = AgentChatText.makeLabel()
    private let highlight = AgentChatText.makeLabel()
    private let gradient = CAGradientLayer()
    private var lastUpdate: CFTimeInterval = 0
    private var pending: String?
    private var pendingTask: Task<Void, Never>?
    private(set) var text = ""

    init() {
        super.init(frame: .zero)
        addSubview(base)
        addSubview(highlight)
        highlight.wantsLayer = true
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.colors = [NSColor.clear.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
        gradient.locations = [0, 0.15, 0.3]
        highlight.layer?.mask = gradient
        // The highlight is a decorative copy of the text: VoiceOver reads `base`
        // once. A label's accessibility element is its cell, not the field.
        highlight.setAccessibilityElement(false)
        highlight.cell?.setAccessibilityElement(false)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    var isShimmering: Bool { gradient.animation(forKey: Self.animationKey) != nil }

    /// Sets the line, at most four times a second.
    func setText(_ value: String, font: NSFont) {
        base.font = font
        highlight.font = font
        guard value != text || pending != nil else { return }
        let now = CACurrentMediaTime()
        let elapsed = now - lastUpdate
        if elapsed >= Self.minimumUpdateInterval || text.isEmpty {
            apply(value)
            return
        }
        pending = value
        guard pendingTask == nil else { return }
        let delay = Self.minimumUpdateInterval - elapsed
        pendingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            pendingTask = nil
            if let next = pending { apply(next) }
        }
    }

    private func apply(_ value: String) {
        pending = nil
        text = value
        lastUpdate = CACurrentMediaTime()
        AgentChatText.apply(base, text: value, font: base.font ?? AgentChatText.font(12), color: .live)
        AgentChatText.apply(highlight, text: value, font: base.font ?? AgentChatText.font(12), color: .textPrimary)
        needsLayout = true
    }

    func startAnimating() {
        let animate = !AgentChatMotion.reduceMotion()
        highlight.isHidden = !animate
        guard animate else {
            gradient.removeAnimation(forKey: Self.animationKey)
            return
        }
        guard gradient.animation(forKey: Self.animationKey) == nil else { return }
        let sweep = CABasicAnimation(keyPath: "locations")
        sweep.fromValue = [-0.4, -0.2, 0]
        sweep.toValue = [1, 1.2, 1.4]
        sweep.duration = 1.8
        sweep.repeatCount = .infinity
        gradient.add(sweep, forKey: Self.animationKey)
    }

    /// Forgets the current line and throttle (the card now shows another
    /// group), so the next `setText` lands at once and no other group's
    /// status lingers.
    func reset() {
        pendingTask?.cancel()
        pendingTask = nil
        pending = nil
        lastUpdate = 0
        text = ""
        base.stringValue = ""
        highlight.stringValue = ""
    }

    func stopAnimating() {
        pendingTask?.cancel()
        pendingTask = nil
        pending = nil
        gradient.removeAllAnimations()
        highlight.isHidden = true
    }

    override func layout() {
        super.layout()
        base.frame = bounds
        highlight.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = highlight.bounds
        CATransaction.commit()
    }
}

enum AgentChatDuration {
    /// "42s", "1m 42s", "1h 3m".
    static func format(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return seconds % 60 == 0 ? "\(seconds / 60)m" : "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
    }

    static func between(_ start: Date?, _ end: Date?, now: Date) -> String? {
        guard let start else { return nil }
        return format((end ?? now).timeIntervalSince(start))
    }
}

extension NSView {
    /// Removes CA animations from this view's subtree (cell reuse).
    @MainActor
    func agentChatRemoveAnimations() {
        layer?.removeAllAnimations()
        for child in subviews { child.agentChatRemoveAnimations() }
    }
}
