import AppKit

/// Parallel subagents as a wrapping row of chips. When none are running it
/// collapses to `{n} agents · {done} done · {failed} failed`; the chevron
/// (`actions.toggleExpanded(roster id)`) shows the chips again.
final class AgentRosterView: NSView {
    static let accessibilityIdentifierValue = "agent-chat.roster"
    static let chipSpacing: CGFloat = 6
    static let chevronSize: CGFloat = 16

    let chevron = NSButton()
    let summaryLabel = AgentChatText.makeLabel()
    private(set) var chipViews: [String: AgentChipView] = [:]
    private(set) var entries: [AgentRosterEntry] = []
    private(set) var isExpanded = false
    private var actions = AgentChatRowActions()

    init() {
        super.init(frame: .zero)
        setAccessibilityIdentifier(Self.accessibilityIdentifierValue)
        setAccessibilityRole(.group)
        chevron.isBordered = false
        chevron.imagePosition = .imageOnly
        chevron.target = self
        chevron.action = #selector(toggle)
        chevron.setAccessibilityIdentifier("agent-chat.roster.toggle")
        addSubview(chevron)
        addSubview(summaryLabel)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    // MARK: Pure presentation

    /// Matches `AgentActivityMember.agents(entries).id`.
    static func rosterID(_ entries: [AgentRosterEntry]) -> String {
        AgentActivityMember.agents(entries).id
    }

    static func isRunning(_ lifecycle: AgentChatItem.Subagent.Lifecycle) -> Bool {
        lifecycle == .running || lifecycle == .queued || lifecycle == .background
    }

    static func isExpanded(entries: [AgentRosterEntry], expandedOverride: Bool?) -> Bool {
        expandedOverride ?? entries.contains { isRunning($0.lifecycle) }
    }

    struct Counts: Equatable {
        var total = 0, running = 0, done = 0, failed = 0, stopped = 0
    }

    static func counts(_ entries: [AgentRosterEntry]) -> Counts {
        var counts = Counts(total: entries.count)
        for entry in entries {
            switch entry.lifecycle {
            case .queued, .running, .background: counts.running += 1
            case .done, .ended: counts.done += 1
            case .failed: counts.failed += 1
            case .cancelled: counts.stopped += 1
            }
        }
        return counts
    }

    /// `{n} agents[ · {r} running] · {done} done[ · {failed} failed][ · {s} stopped]`.
    static func summary(_ entries: [AgentRosterEntry]) -> (text: String, failedRange: NSRange?) {
        let counts = counts(entries)
        var text = counts.total == 1 ? "1 agent" : "\(counts.total) agents"
        if counts.running > 0 { text += " · \(counts.running) running" }
        text += " · \(counts.done) done"
        var failedRange: NSRange?
        if counts.failed > 0 {
            text += " · "
            let token = "\(counts.failed) failed"
            failedRange = NSRange(location: (text as NSString).length, length: (token as NSString).length)
            text += token
        }
        if counts.stopped > 0 { text += " · \(counts.stopped) stopped" }
        return (text, failedRange)
    }

    static var font: NSFont { AgentChatText.font(12, .medium) }
    static var headerHeight: CGFloat { max(chevronSize, AgentChatText.lineHeight(font)) + 4 }

    /// Chip frames flowing left to right, wrapping at `width`.
    static func chipFrames(entries: [AgentRosterEntry], width: CGFloat) -> [NSRect] {
        var frames: [NSRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        let height = AgentChipView.height
        for entry in entries {
            let chipWidth = min(AgentChipView.width(for: entry), max(1, width))
            if x > 0, x + chipWidth > width {
                x = 0
                y += height + chipSpacing
            }
            frames.append(NSRect(x: x, y: y, width: chipWidth, height: height))
            x += chipWidth + chipSpacing
        }
        return frames
    }

    static func height(entries: [AgentRosterEntry], expandedOverride: Bool?, width: CGFloat) -> CGFloat {
        guard !entries.isEmpty else { return 0 }
        var height = headerHeight
        if isExpanded(entries: entries, expandedOverride: expandedOverride) {
            let flow = chipFrames(entries: entries, width: width).last?.maxY ?? 0
            height += 4 + flow
        }
        return height
    }

    // MARK: Configuration

    /// `expandedOverride` is the user's toggle (nil: expanded while any entry runs).
    func configure(entries: [AgentRosterEntry], expandedOverride: Bool?, now: Date, actions: AgentChatRowActions) {
        self.entries = entries
        self.actions = actions
        isExpanded = Self.isExpanded(entries: entries, expandedOverride: expandedOverride)
        let symbol = isExpanded ? "chevron.down" : "chevron.right"
        let title = isExpanded ? "Hide agents" : "Show agents"
        chevron.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        chevron.contentTintColor = AgentChatPalette.color(.textMuted)
        chevron.toolTip = title
        chevron.setAccessibilityLabel(title)
        let summary = Self.summary(entries)
        let attributed = NSMutableAttributedString(string: summary.text, attributes: [
            .font: Self.font, .foregroundColor: AgentChatPalette.color(.textMuted),
        ])
        if let range = summary.failedRange {
            attributed.addAttribute(.foregroundColor, value: AgentChatPalette.color(.failure), range: range)
        }
        summaryLabel.attributedStringValue = attributed
        summaryLabel.toolTip = summary.text
        setAccessibilityLabel(summary.text)
        var keep: [String: AgentChipView] = [:]
        if isExpanded {
            for entry in entries {
                let chip = chipViews[entry.id] ?? AgentChipView()
                chip.configure(entry: entry, now: now, actions: actions)
                if chip.superview !== self { addSubview(chip) }
                keep[entry.id] = chip
            }
        }
        for (id, chip) in chipViews where keep[id] == nil { chip.removeFromSuperview() }
        chipViews = keep
        needsLayout = true
    }

    /// Refreshes chip tooltips (elapsed time) on the controller's 1 Hz tick.
    func tick(now: Date) {
        for chip in chipViews.values { chip.updateTooltip(now: now) }
    }

    override func layout() {
        super.layout()
        let header = Self.headerHeight
        chevron.frame = NSRect(x: 0, y: (header - Self.chevronSize) / 2, width: Self.chevronSize, height: Self.chevronSize)
        let line = AgentChatText.lineHeight(Self.font)
        summaryLabel.frame = NSRect(x: Self.chevronSize + 4, y: (header - line) / 2,
                                    width: max(0, bounds.width - Self.chevronSize - 4), height: line)
        guard isExpanded else { return }
        for (entry, frame) in zip(entries, Self.chipFrames(entries: entries, width: bounds.width)) {
            chipViews[entry.id]?.frame = frame.offsetBy(dx: 0, dy: header + 4)
        }
    }

    @objc private func toggle() {
        actions.toggleExpanded(Self.rosterID(entries))
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.y <= Self.headerHeight, bounds.contains(point) { toggle() }
    }
}

/// `{dot} {name} · {steps}`, ≤ 160 pt with tail truncation and a tooltip of
/// name, lifecycle, and elapsed time. Click opens the Inspector on
/// `.agent(childSessionID:)`; failed chips offer "Ask to continue…" in their
/// context menu (`actions.askToContinue`).
final class AgentChipView: NSView {
    static let accessibilityIdentifierValue = "agent-chat.chip"
    static let maximumWidth: CGFloat = 160
    static let height: CGFloat = 22
    static let horizontalPadding: CGFloat = 8
    static let dotGap: CGFloat = 5
    static let continueTitle = "Ask to continue…"
    static let labelOverlap: CGFloat = 3
    static var font: NSFont { AgentChatText.font(12) }

    let surface = AgentChatSurfaceView(fill: .thread, border: .cardBorder, cornerRadius: 11)
    let dot = AgentStatusDotView()
    /// Tail-truncated name; the step count beside it is never truncated.
    let label = AgentChatText.makeLabel()
    let stepsLabel = AgentChatText.makeLabel()
    private(set) var entry: AgentRosterEntry?
    private var actions = AgentChatRowActions()

    init() {
        super.init(frame: .zero)
        setAccessibilityIdentifier(Self.accessibilityIdentifierValue)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        addSubview(surface)
        addSubview(dot)
        addSubview(label)
        addSubview(stepsLabel)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    static func name(for entry: AgentRosterEntry) -> String {
        redactInline(String(entry.name.prefix(256)))
    }

    static func stepsText(for entry: AgentRosterEntry) -> String {
        " · \(entry.steps)"
    }

    /// `{name} · {steps}` (redacted).
    static func title(for entry: AgentRosterEntry) -> String {
        name(for: entry) + stepsText(for: entry)
    }

    static func lifecycleName(_ lifecycle: AgentChatItem.Subagent.Lifecycle) -> String {
        switch lifecycle {
        case .queued: "Queued"
        case .running: "Running"
        case .done: "Done"
        case .failed: "Failed"
        case .cancelled: "Stopped"
        case .ended: "Ended"
        case .background: "Running in background"
        }
    }

    /// Name, lifecycle, elapsed time, and step counts (all redacted).
    static func tooltip(for entry: AgentRosterEntry, now: Date) -> String {
        var status = lifecycleName(entry.lifecycle)
        if let elapsed = AgentChatDuration.between(entry.startedAt, entry.endedAt, now: now) { status += " · \(elapsed)" }
        var steps = entry.steps == 1 ? "1 step" : "\(entry.steps) steps"
        if entry.failed > 0 { steps += " · \(entry.failed) failed" }
        return [redactInline(String(entry.name.prefix(256))), status, steps].joined(separator: "\n")
    }

    static func width(for entry: AgentRosterEntry) -> CGFloat {
        // The two labels' cell paddings overlap by `labelOverlap`.
        let text = AgentChatText.width(name(for: entry), font: font) + AgentChatText.width(stepsText(for: entry), font: font) - labelOverlap
        return min(maximumWidth, horizontalPadding * 2 + AgentStatusDotView.size + dotGap + text)
    }

    func configure(entry: AgentRosterEntry, now: Date, actions: AgentChatRowActions) {
        self.entry = entry
        self.actions = actions
        dot.configure(status: AgentStatusDotView.Status(entry.lifecycle))
        AgentChatText.apply(label, text: Self.name(for: entry), font: Self.font, color: .textPrimary)
        AgentChatText.apply(stepsLabel, text: Self.stepsText(for: entry), font: Self.font, color: .textMuted)
        updateTooltip(now: now)
        setAccessibilityHelp("Opens this agent in the Inspector")
        var custom = [NSAccessibilityCustomAction(name: "Open in Inspector", target: self, selector: #selector(accessibilityOpen))]
        if entry.lifecycle == .failed {
            custom.append(NSAccessibilityCustomAction(name: "Ask to continue", target: self, selector: #selector(accessibilityContinue)))
        }
        setAccessibilityCustomActions(custom)
        needsLayout = true
    }

    /// Tooltip and accessibility label: name, lifecycle, elapsed at `now`.
    func updateTooltip(now: Date) {
        guard let entry else { return }
        let tooltip = Self.tooltip(for: entry, now: now)
        guard tooltip != toolTip else { return }
        toolTip = tooltip
        setAccessibilityLabel(tooltip.replacingOccurrences(of: "\n", with: ", "))
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
        let size = AgentStatusDotView.size
        dot.frame = NSRect(x: Self.horizontalPadding, y: (bounds.height - size) / 2, width: size, height: size)
        let line = AgentChatText.lineHeight(Self.font)
        let x = Self.horizontalPadding + size + Self.dotGap
        let available = max(0, bounds.width - x - Self.horizontalPadding)
        let stepsWidth = min(available, AgentChatText.width(stepsLabel.stringValue, font: Self.font))
        let nameWidth = min(max(0, available - stepsWidth + Self.labelOverlap), AgentChatText.width(label.stringValue, font: Self.font))
        label.frame = NSRect(x: x, y: (bounds.height - line) / 2, width: nameWidth, height: line)
        stepsLabel.frame = NSRect(x: max(x, x + nameWidth - Self.labelOverlap), y: (bounds.height - line) / 2, width: stepsWidth, height: line)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        open()
    }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu() }

    /// "Ask to continue…" for failed agents; nil otherwise.
    func contextMenu() -> NSMenu? {
        guard entry?.lifecycle == .failed else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: Self.continueTitle, action: #selector(askToContinue), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    override func accessibilityPerformPress() -> Bool {
        open()
        return true
    }

    func open() {
        guard let entry else { return }
        actions.openInspector(.agent(childSessionID: entry.id), nil)
    }

    @objc func askToContinue() {
        guard let entry, entry.lifecycle == .failed else { return }
        actions.askToContinue(entry.id)
    }

    @objc private func accessibilityOpen() -> Bool {
        open()
        return true
    }

    @objc private func accessibilityContinue() -> Bool {
        askToContinue()
        return true
    }
}
