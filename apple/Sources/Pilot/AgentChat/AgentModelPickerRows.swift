import AppKit

// Building blocks of the model picker popover. Every surface draws in
// `draw(_:)` so gallery snapshots capture it, and every control keeps native
// focus, keyboard activation and accessibility.

extension AgentChatPalette.Token {
    /// Popover surface: near-black in dark (the reference), white in light.
    static let pickerSurface = Self(light: 0xFFFFFF, dark: 0x151618)
    static let pickerHairline = Self(light: 0xE2E4E8, dark: 0x2A2C30)
    /// Keycaps and the Standard | Fast track.
    static let pickerFill = Self(light: 0xEEF0F2, dark: 0x232529)
    /// The selected Standard | Fast segment.
    static let pickerRaised = Self(light: 0xFFFFFF, dark: 0x36393E)
    /// Hovered or keyboard-highlighted rows.
    static let pickerHighlight = Self(light: 0xEBEDF0, dark: 0x24262A)
    /// Unrestricted permission modes (glyph only).
    static let pickerWarning = Self(light: 0x8F5A00, dark: 0xE9AA4E)
    /// Anthropic's clay mark; other providers' marks are monochrome.
    static let pickerClaude = Self(light: 0xB8583A, dark: 0xD97757)
}

extension AgentChatPalette {
    /// Picker text on every picker surface; each must meet 4.5:1.
    static let pickerTextPairs: [(name: String, text: Token, surface: Token)] = {
        var pairs: [(String, Token, Token)] = []
        let texts: [(String, Token)] = [("textPrimary", .textPrimary), ("textMuted", .textMuted), ("pickerWarning", .pickerWarning)]
        let surfaces: [(String, Token)] = [("pickerSurface", .pickerSurface), ("pickerFill", .pickerFill),
                                           ("pickerRaised", .pickerRaised), ("pickerHighlight", .pickerHighlight)]
        for (surfaceName, surface) in surfaces {
            for (textName, text) in texts { pairs.append(("\(textName) on \(surfaceName)", text, surface)) }
        }
        return pairs
    }()
}

/// Provider marks shared by the rail, rows and trigger: the asset-catalog
/// brand symbol of `ChatAgent.provider` (the Plan Usage cards use the same).
@MainActor
enum AgentModelPickerBrand {
    static func image(for agent: ChatAgent) -> NSImage? {
        NSImage(named: agent.provider.brandSymbol)
    }

    static func tint(for agent: ChatAgent, emphasized: Bool) -> NSColor {
        if agent == .claude { return AgentChatPalette.color(.pickerClaude) }
        return AgentChatPalette.color(emphasized ? .textPrimary : .textMuted)
    }

    static func imageView(pointSize: CGFloat) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.symbolConfiguration = .init(pointSize: pointSize, weight: .regular)
        view.setAccessibilityElement(false)
        return view
    }
}

/// A flipped container (list documents and columns).
final class AgentModelPickerFlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Rail

/// One rail tab: ★ Favorites or a provider mark, with the accent bar on the
/// trailing edge while selected.
@MainActor
final class AgentModelPickerRailButton: NSButton {
    let kind: AgentModelPickerState.Tab.Kind
    private(set) var isSelectedTab = false
    var onPress: () -> Void = {}

    init(tab: AgentModelPickerState.Tab) {
        kind = tab.kind
        super.init(frame: .zero)
        title = ""
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        setButtonType(.momentaryChange)
        focusRingType = .exterior
        target = self
        action = #selector(press)
        toolTip = tab.title
        setAccessibilityLabel(tab.title)
        setAccessibilityRole(.radioButton)
        switch tab.kind {
        case .favorites:
            image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)
            setAccessibilityIdentifier("agent-model-picker.tab.favorites")
        case .agent(let agent):
            image = AgentModelPickerBrand.image(for: agent)
            setAccessibilityIdentifier("agent-model-picker.tab.\(agent.rawValue)")
        }
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { !isHidden }

    func configure(selected: Bool, scale: CGFloat) {
        isSelectedTab = selected
        setAccessibilityValue(selected ? 1 : 0)
        let size: CGFloat = kind == .favorites ? 17 : 24
        symbolConfiguration = .init(pointSize: size * scale, weight: kind == .favorites ? .semibold : .regular)
        switch kind {
        case .favorites: contentTintColor = AgentChatPalette.color(.textPrimary)
        case .agent(let agent): contentTintColor = AgentModelPickerBrand.tint(for: agent, emphasized: selected)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            AgentChatPalette.color(.pickerHighlight).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 2), xRadius: 8, yRadius: 8).fill()
        }
        super.draw(dirtyRect)
        guard isSelectedTab else { return }
        let height = min(bounds.height - 8, 20 * bounds.height / 36)
        let bar = NSRect(x: bounds.maxX - 6, y: bounds.midY - height / 2, width: 3, height: height)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
    }

    @objc private func press() { onPress() }
}

// MARK: - Keycap

/// "⌘1": a rounded rect with a subtle fill and muted medium text.
final class AgentModelPickerKeycap: NSView {
    private(set) var text = ""
    private var font = NSFont.systemFont(ofSize: 12, weight: .medium)
    /// Drawn on a hovered or highlighted row, whose fill matches `pickerFill`.
    var onHighlight = false { didSet { if onHighlight != oldValue { needsDisplay = true } } }

    /// The keycap fill: raised on a highlighted row so the box stays visible.
    static func fill(onHighlight: Bool) -> AgentChatPalette.Token { onHighlight ? .pickerRaised : .pickerFill }

    func configure(_ text: String, font: NSFont) {
        self.text = text
        self.font = font
        setAccessibilityElement(false)
        needsDisplay = true
    }

    var preferredSize: NSSize {
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        return NSSize(width: ceil(width + font.pointSize * 0.8), height: ceil(font.pointSize * 1.6))
    }

    override func draw(_ dirtyRect: NSRect) {
        AgentChatPalette.color(Self.fill(onHighlight: onHighlight)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: AgentChatPalette.color(.textMuted)]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                                withAttributes: attributes)
    }
}

// MARK: - Model row

/// `{brand} {name} {✓}` … `{☆} {⌘N}`. Hover reveals the favorite toggle;
/// the context menu adds or removes the favorite.
@MainActor
final class AgentModelPickerRowView: NSView {
    struct Callbacks {
        var select: () -> Void = {}
        var toggleFavorite: () -> Void = {}
        var hover: (Bool) -> Void = { _ in }
    }

    private(set) var row: AgentModelPickerState.Row
    let glyph = AgentModelPickerBrand.imageView(pointSize: 16)
    let nameLabel = AgentChatText.makeLabel()
    let check = NSImageView()
    let keycap = AgentModelPickerKeycap()
    let favoriteButton = NSButton()
    private(set) var isHovered = false
    private(set) var isHighlighted = false
    private(set) var enabled: Bool
    let scale: CGFloat
    var callbacks = Callbacks()

    init(row: AgentModelPickerState.Row, shortcut: Int?, enabled: Bool, scale: CGFloat) {
        self.row = row
        self.enabled = enabled
        self.scale = scale
        super.init(frame: .zero)
        glyph.image = AgentModelPickerBrand.image(for: row.agent)
        glyph.symbolConfiguration = .init(pointSize: 24 * scale, weight: .regular)
        glyph.contentTintColor = AgentModelPickerBrand.tint(for: row.agent, emphasized: false)
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        check.symbolConfiguration = .init(pointSize: 12 * scale, weight: .medium)
        check.contentTintColor = AgentChatPalette.color(.textMuted)
        favoriteButton.isBordered = false
        favoriteButton.imagePosition = .imageOnly
        favoriteButton.title = ""
        favoriteButton.target = self
        favoriteButton.action = #selector(toggleFavorite)
        favoriteButton.isHidden = true
        favoriteButton.setAccessibilityIdentifier("agent-model-picker.favorite")
        for view in [glyph, nameLabel, check, keycap, favoriteButton] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("agent-model-picker.row")
        configure(row: row, shortcut: shortcut, enabled: enabled)
    }

    required init?(coder: NSCoder) { nil }

    /// Applies new values for the same model (favorite, current, enabled,
    /// keycap) without replacing the view, so hover and focus survive.
    func configure(row: AgentModelPickerState.Row, shortcut: Int?, enabled: Bool) {
        self.row = row
        self.enabled = enabled
        AgentChatText.apply(nameLabel, text: row.name, font: AgentChatText.font(15),
                            color: row.isPlaceholder ? .textMuted : .textPrimary)
        check.isHidden = !row.isCurrent
        keycap.configure(shortcut.map { "⌘\($0)" } ?? "", font: AgentChatText.font(12, .medium))
        keycap.isHidden = shortcut == nil
        configureFavoriteButton()
        favoriteButton.isHidden = !isHovered || row.isPlaceholder
        alphaValue = enabled ? 1 : 0.45
        toolTip = enabled ? row.detail : row.disabledReason ?? row.detail
        setAccessibilityLabel(row.isCurrent ? "\(row.name), current" : row.name)
        setAccessibilityHelp(enabled ? row.detail : row.disabledReason ?? row.detail)
        setAccessibilityEnabled(enabled)
        setAccessibilityCustomActions(row.isPlaceholder ? [] : [NSAccessibilityCustomAction(name: favoriteTitle) { [weak self] in
            self?.callbacks.toggleFavorite()
            return true
        }])
        updateKeycapEmphasis()
        needsLayout = true
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    var favoriteTitle: String { row.isFavorite ? "Remove from Favorites" : "Add to Favorites" }

    private func configureFavoriteButton() {
        favoriteButton.image = NSImage(systemSymbolName: row.isFavorite ? "star.fill" : "star", accessibilityDescription: nil)
        favoriteButton.symbolConfiguration = .init(pointSize: 13 * scale, weight: .medium)
        favoriteButton.contentTintColor = AgentChatPalette.color(row.isFavorite ? .textPrimary : .textMuted)
        favoriteButton.setAccessibilityLabel(favoriteTitle)
        favoriteButton.toolTip = favoriteTitle
    }

    /// The keycap keeps a visible box on the highlighted row fill.
    private func updateKeycapEmphasis() {
        keycap.onHighlight = (isHighlighted || isHovered) && enabled
    }

    func setHighlighted(_ highlighted: Bool) {
        guard isHighlighted != highlighted else { return }
        isHighlighted = highlighted
        setAccessibilitySelected(highlighted)
        updateKeycapEmphasis()
        needsDisplay = true
    }

    func setHovering(_ hovering: Bool) {
        isHovered = hovering
        favoriteButton.isHidden = !hovering || row.isPlaceholder
        updateKeycapEmphasis()
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let glyphSize = 24 * scale
        glyph.frame = NSRect(x: 5 * scale, y: (height - glyphSize) / 2, width: glyphSize, height: glyphSize)
        var trailing = bounds.width - 8 * scale
        if !keycap.isHidden {
            let size = keycap.preferredSize
            keycap.frame = NSRect(x: trailing - size.width, y: (height - size.height) / 2, width: size.width, height: size.height)
            trailing = keycap.frame.minX - 8 * scale
        }
        if !favoriteButton.isHidden {
            let size = 20 * scale
            favoriteButton.frame = NSRect(x: trailing - size, y: (height - size) / 2, width: size, height: size)
            trailing = favoriteButton.frame.minX - 6 * scale
        }
        let nameX = 33 * scale
        let checkWidth = check.isHidden ? 0 : 22 * scale
        let natural = AgentModelPickerDrawing.fit(nameLabel).width
        let nameWidth = max(0, min(natural, trailing - nameX - checkWidth))
        let lineHeight = AgentModelPickerDrawing.fit(nameLabel).height
        nameLabel.frame = NSRect(x: nameX, y: (height - lineHeight) / 2, width: nameWidth, height: lineHeight)
        let checkSize = 14 * scale
        check.frame = NSRect(x: nameLabel.frame.maxX + 8 * scale, y: (height - checkSize) / 2, width: checkSize, height: checkSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard (isHighlighted || isHovered) && enabled else { return }
        AgentChatPalette.color(.pickerHighlight).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if !favoriteButton.isHidden, favoriteButton.frame.contains(local) { return favoriteButton }
        return self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        setHovering(true)
        callbacks.hover(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
        callbacks.hover(false)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        press()
    }

    override func accessibilityPerformPress() -> Bool {
        press()
        return enabled
    }

    func press() {
        guard enabled else { return }
        callbacks.select()
    }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu() }

    func contextMenu() -> NSMenu? {
        guard !row.isPlaceholder else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: favoriteTitle, action: #selector(toggleFavorite), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: row.isFavorite ? "star.slash" : "star", accessibilityDescription: nil)
        menu.addItem(item)
        return menu
    }

    @objc func toggleFavorite() { callbacks.toggleFavorite() }
}

// MARK: - Reasoning choices

/// A reasoning level: text left, ✓ right. Focusable without Full Keyboard
/// Access so Tab reaches the column; ↑/↓ move between levels.
@MainActor
final class AgentModelPickerChoiceButton: NSButton {
    let choice: AgentModelPickerState.Choice
    var onPress: () -> Void = {}
    var onArrow: (Int) -> Void = { _ in }
    private var hovering = false
    private let scale: CGFloat

    init(choice: AgentModelPickerState.Choice, enabled: Bool, scale: CGFloat) {
        self.choice = choice
        self.scale = scale
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .exterior
        target = self
        action = #selector(press)
        isEnabled = enabled
        toolTip = choice.detail
        setAccessibilityRole(.radioButton)
        setAccessibilityIdentifier("agent-model-picker.reasoning")
        setAccessibilityLabel(choice.name)
        setAccessibilityValue(choice.isCurrent ? 1 : 0)
        setAccessibilityHelp(choice.detail)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled && !isHidden }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill() }

    override func draw(_ dirtyRect: NSRect) {
        if (hovering || isHighlighted) && isEnabled {
            AgentChatPalette.color(.pickerHighlight).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        let font = AgentChatText.font(15)
        let color = AgentChatPalette.color(.textPrimary).withAlphaComponent(isEnabled ? 1 : 0.45)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (choice.name as NSString).size(withAttributes: attributes)
        let checkReserve = 30 * scale
        let rect = NSRect(x: 9 * scale, y: (bounds.height - size.height) / 2,
                          width: max(0, bounds.width - 9 * scale - checkReserve), height: size.height)
        (choice.name as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                       attributes: attributes)
        guard choice.isCurrent,
              let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                  .withSymbolConfiguration(.init(pointSize: 13 * scale, weight: .medium)) else { return }
        let checkSize = check.size
        let checkRect = NSRect(x: bounds.maxX - 8 * scale - checkSize.width, y: (bounds.height - checkSize.height) / 2,
                               width: checkSize.width, height: checkSize.height)
        AgentModelPickerDrawing.draw(check, in: checkRect, color: AgentChatPalette.color(.textPrimary).withAlphaComponent(isEnabled ? 1 : 0.45))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: onArrow(1)
        case 126: onArrow(-1)
        case 36, 76: performClick(nil)
        default: super.keyDown(with: event)
        }
    }

    @objc private func press() { onPress() }
}

@MainActor
enum AgentModelPickerDrawing {
    /// The untruncated single-line size of a label's current text and font.
    static func fit(_ field: NSTextField) -> NSSize {
        let unbounded = NSRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let size = field.cell?.cellSize(forBounds: unbounded) ?? .zero
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    /// Draws a template symbol filled with `color` (snapshot-safe tinting).
    static func draw(_ image: NSImage, in rect: NSRect, color: NSColor) {
        let tinted = NSImage(size: rect.size, flipped: false) { bounds in
            image.draw(in: bounds)
            color.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

// MARK: - Footer

/// "Standard | ⚡ Fast": two radio segments on a rounded track.
@MainActor
final class AgentModelPickerFastToggle: NSView {
    final class Segment: NSButton {
        var onPress: () -> Void = {}
        var onArrow: () -> Void = {}
        var isOn = false { didSet { needsDisplay = true; setAccessibilityValue(isOn ? 1 : 0) } }
        var symbol: String?
        var scale: CGFloat = 1

        override var acceptsFirstResponder: Bool { isEnabled }
        override var canBecomeKeyView: Bool { isEnabled && !isHidden }
        override var focusRingMaskBounds: NSRect { bounds }
        override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }

        override func draw(_ dirtyRect: NSRect) {
            if isOn {
                AgentChatPalette.color(.pickerRaised).setFill()
                NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
            }
            let alpha: CGFloat = isEnabled ? 1 : 0.45
            let color = AgentChatPalette.color(isOn ? .textPrimary : .textMuted).withAlphaComponent(alpha)
            let attributes: [NSAttributedString.Key: Any] = [.font: AgentChatText.font(13, .medium), .foregroundColor: color]
            let size = (title as NSString).size(withAttributes: attributes)
            let icon = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12 * scale, weight: .semibold)) }
            let gap = 5 * scale
            let iconWidth = icon.map { $0.size.width + gap } ?? 0
            var x = (bounds.width - size.width - iconWidth) / 2
            if let icon {
                AgentModelPickerDrawing.draw(icon, in: NSRect(x: x, y: (bounds.height - icon.size.height) / 2,
                                                              width: icon.size.width, height: icon.size.height), color: color)
                x += iconWidth
            }
            (title as NSString).draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 123, 124: onArrow()
            case 36, 76: performClick(nil)
            default: super.keyDown(with: event)
            }
        }

        @objc func press() { onPress() }
    }

    let standard = Segment()
    let fast = Segment()
    var onChange: (Bool) -> Void = { _ in }
    private var scale: CGFloat = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Speed")
        setAccessibilityIdentifier("agent-model-picker.speed")
        for (segment, title, value) in [(standard, "Standard", false), (fast, "Fast", true)] {
            segment.title = title
            segment.isBordered = false
            segment.setButtonType(.momentaryChange)
            segment.focusRingType = .exterior
            segment.target = segment
            segment.action = #selector(Segment.press)
            segment.setAccessibilityRole(.radioButton)
            segment.setAccessibilityLabel(title)
            segment.onPress = { [weak self] in self?.onChange(value) }
            segment.onArrow = { [weak self] in self?.onChange(!value) }
            addSubview(segment)
        }
        fast.symbol = "bolt.fill"
        standard.setAccessibilityIdentifier("agent-model-picker.speed.standard")
        fast.setAccessibilityIdentifier("agent-model-picker.speed.fast")
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func configure(fast isFast: Bool, enabled: Bool, scale: CGFloat) {
        self.scale = scale
        standard.isOn = !isFast
        fast.isOn = isFast
        for segment in [standard, fast] {
            segment.isEnabled = enabled
            segment.scale = scale
        }
        needsLayout = true
        needsDisplay = true
    }

    var preferredSize: NSSize {
        let font = AgentChatText.font(13, .medium)
        func width(_ text: String, icon: Bool) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: font]).width) + (icon ? 17 * scale : 0) + 24 * scale
        }
        return NSSize(width: width("Standard", icon: false) + width("Fast", icon: true) + 4 * scale, height: 28 * scale)
    }

    override func layout() {
        super.layout()
        let inset = 2 * scale
        let font = AgentChatText.font(13, .medium)
        let standardWidth = ceil(("Standard" as NSString).size(withAttributes: [.font: font]).width) + 24 * scale
        standard.frame = NSRect(x: inset, y: inset, width: standardWidth, height: bounds.height - inset * 2)
        fast.frame = NSRect(x: standard.frame.maxX, y: inset, width: bounds.width - standard.frame.maxX - inset,
                            height: bounds.height - inset * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        AgentChatPalette.color(.pickerFill).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}

/// `{shield} {mode} ⌃`: opens the permission-mode menu above itself.
@MainActor
final class AgentModelPickerModeButton: NSButton {
    var modeName = "" { didSet { setAccessibilityValue(modeName); needsDisplay = true } }
    var isUnrestricted = false { didSet { needsDisplay = true } }
    var scale: CGFloat = 1
    var onPress: () -> Void = {}

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .exterior
        target = self
        action = #selector(press)
        setAccessibilityLabel("Permission mode")
        setAccessibilityIdentifier("agent-model-picker.mode")
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled && !isHidden }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }

    var shieldSymbol: String { isUnrestricted ? "shield.slash" : "checkmark.shield" }

    private var labelFont: NSFont { AgentChatText.font(13, .medium) }

    var preferredSize: NSSize {
        let text = ceil((modeName as NSString).size(withAttributes: [.font: labelFont]).width)
        return NSSize(width: text + 48 * scale, height: 28 * scale)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            AgentChatPalette.color(.pickerHighlight).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let alpha: CGFloat = isEnabled ? 1 : 0.45
        let muted = AgentChatPalette.color(.textMuted).withAlphaComponent(alpha)
        var x = 4 * scale
        if let shield = NSImage(systemSymbolName: shieldSymbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13 * scale, weight: .regular)) {
            let tint = isUnrestricted ? AgentChatPalette.color(.pickerWarning).withAlphaComponent(alpha) : muted
            AgentModelPickerDrawing.draw(shield, in: NSRect(x: x, y: (bounds.height - shield.size.height) / 2,
                                                            width: shield.size.width, height: shield.size.height), color: tint)
            x += shield.size.width + 7 * scale
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: muted]
        let size = (modeName as NSString).size(withAttributes: attributes)
        (modeName as NSString).draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        if let chevron = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9 * scale, weight: .semibold)) {
            AgentModelPickerDrawing.draw(chevron, in: NSRect(x: bounds.maxX - 4 * scale - chevron.size.width,
                                                             y: (bounds.height - chevron.size.height) / 2,
                                                             width: chevron.size.width, height: chevron.size.height), color: muted)
        }
    }

    @objc private func press() { onPress() }
}
