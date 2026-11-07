import AppKit

/// One visible row of an activity card: WP3's layout entry (the single
/// source of truth for paging, inline weight, and the collapsed failure cap).
typealias ActivityCardRow = AgentActivityLayout.Entry

/// What an activity card shows for a group, derived purely from its state.
struct ActivityCardPresentation: Equatable {
    /// Settled, ≤ 3 members, no failures, no agents: rows without card chrome.
    var inline: Bool
    var expanded: Bool
    var live: Bool
    var showsLiveLine: Bool
    var rows: [ActivityCardRow]
}

/// Header label pieces: `{summary} · {n} steps · {k} failed · {n} stopped · {duration}`.
struct ActivityHeaderParts: Equatable {
    var summary: String
    var steps: String
    var failed: String?
    var stopped: String?
    var duration: String?

    var accessibilityText: String {
        ([summary, steps] + [failed, stopped, duration].compactMap { $0 }).filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// One activity group. Header: the chevron toggles disclosure
/// (`actions.toggleExpanded(group.id)`); the label opens the Inspector on
/// `.group(id:)`. Label: `{summary} · {n} steps · {k} failed · {n} stopped ·
/// {duration}`, truncating the summary first. Live: shimmer liveStatus line
/// and steps streaming newest at the bottom (last 6 + "N earlier" past 15).
/// Settling: animates closed, then calls `actions.collapseFinished(group.id)`
/// (immediately under Reduce Motion or a hidden window). Settled: one line
/// plus failed rows beneath; expanded past 15 steps shows first 2 + last 2 +
/// "Show N more" (`actions.showAll(group.id)`). Settled groups of ≤ 3 steps
/// with no failures or agents render inline without card chrome.
final class ActivityCardView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("agent-chat.activity")
    static let outerInset = NSSize(width: 8, height: 2)
    static let padding = NSSize(width: 6, height: 6)
    static let rowSpacing: CGFloat = 2

    let chrome = AgentChatSurfaceView(fill: .card, border: .cardBorder, cornerRadius: 8)
    let header = ActivityHeaderView()
    let liveLine = AgentChatShimmerLabel()
    private(set) var stepViews: [String: ActivityStepView] = [:]
    private(set) var rosterViews: [String: AgentRosterView] = [:]
    private var auxButtons: [String: AgentChatClosureButton] = [:]
    private(set) var group: AgentActivityGroup?
    private(set) var presentation: ActivityCardPresentation?
    private var expandedOverride: Bool?
    private var showAll = false
    private var verbs: [String: AgentToolVerb] = [:]
    private var rosterOverrides: [String: Bool] = [:]
    private var now = Date()
    private var actions = AgentChatRowActions()
    private var collapseReported: String?
    private(set) var isAnimatingTransition = false
    private var pendingCollapse: (groupID: String, callback: (String) -> Void, removed: [NSView])?
    private var collapseToken = 0

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        setAccessibilityIdentifier(Self.reuseIdentifier.rawValue)
        setAccessibilityRole(.group)
        addSubview(chrome)
        addSubview(header)
        addSubview(liveLine)
        header.onToggle = { [weak self] in
            guard let self, let group else { return }
            actions.toggleExpanded(group.id)
        }
        header.onOpen = { [weak self] in
            guard let self, let group else { return }
            actions.openInspector(.group(id: group.id), nil)
        }
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    // MARK: Pure presentation

    /// Driven entirely by `AgentActivityGroup.layout(expandedOverride:showAll:)`.
    static func presentation(group: AgentActivityGroup, expandedOverride: Bool?, showAll: Bool) -> ActivityCardPresentation {
        let layout = group.layout(expandedOverride: expandedOverride, showAll: showAll)
        let inline = !layout.showsCardChrome
        return ActivityCardPresentation(inline: inline, expanded: layout.isExpanded, live: group.isLive,
                                        showsLiveLine: group.isLive && !inline, rows: layout.entries)
    }

    static func headerParts(group: AgentActivityGroup, now: Date) -> ActivityHeaderParts {
        let summary = redactInline(group.summary.isEmpty ? (group.state == .live || group.state == .idle ? "Working" : "Worked") : group.summary)
        // Groups of only reasoning or agents carry no step count.
        let steps = group.stepCount == 0 ? "" : group.stepCount == 1 ? "1 step" : "\(group.stepCount) steps"
        let live = group.state == .live || group.state == .idle
        return ActivityHeaderParts(
            summary: summary,
            steps: steps,
            failed: group.failedCount > 0 ? "\(group.failedCount) failed" : nil,
            stopped: group.stoppedCount > 0 ? "\(group.stoppedCount) stopped" : nil,
            duration: AgentChatDuration.between(group.startedAt, live ? nil : group.endedAt ?? group.startedAt, now: now)
        )
    }

    /// The live line; the turn's plan progress follows it ("· Plan · 3/7 done").
    static func liveText(_ group: AgentActivityGroup) -> String {
        var text = group.liveStatus.flatMap { $0.isEmpty ? nil : redactInline($0) }
            ?? (group.hasPendingApproval ? "Waiting for approval" : "Working…")
        if let plan = group.plan { text += " · " + plan.label }
        return text
    }

    static func verb(for item: AgentChatItem, verbs: [String: AgentToolVerb], now: Date) -> AgentToolVerb {
        if let verb = verbs[item.key] { return verb }
        switch item.content {
        case .tool(let tool): return verbForTool(tool, input: nil)
        case .thought(let thought): return verbForThought(thought, now: now)
        default: return AgentToolVerb(glyph: .other, live: "Working", settled: "Worked", detail: nil, exactInput: nil)
        }
    }

    static var headerHeight: CGFloat { AgentChatText.lineHeight(ActivityHeaderView.summaryFont) + 8 }
    static var liveLineHeight: CGFloat { AgentChatText.lineHeight(AgentChatText.font(12)) + 2 }
    static var auxRowHeight: CGFloat { AgentChatClosureButton.linkSize("Show 0 more").height + 2 }

    struct Frames {
        var chrome: NSRect?
        var header: NSRect?
        var liveLine: NSRect?
        var rows: [(row: ActivityCardRow, frame: NSRect)]
        var height: CGFloat
    }

    static func frames(group: AgentActivityGroup, presentation: ActivityCardPresentation, verbs: [String: AgentToolVerb],
                       rosterOverrides: [String: Bool], width: CGFloat) -> Frames {
        let contentX = presentation.inline ? outerInset.width : outerInset.width + padding.width
        let contentWidth = max(1, width - contentX * 2)
        let referenceNow = group.endedAt ?? group.startedAt ?? .distantPast
        var y = outerInset.height
        var frames = Frames(chrome: nil, header: nil, liveLine: nil, rows: [], height: 0)
        if !presentation.inline {
            y += padding.height
            frames.header = NSRect(x: contentX, y: y, width: contentWidth, height: headerHeight)
            y += headerHeight
            if presentation.showsLiveLine {
                frames.liveLine = NSRect(x: contentX + ActivityHeaderView.labelX, y: y,
                                         width: max(0, contentWidth - ActivityHeaderView.labelX), height: liveLineHeight)
                y += liveLineHeight
            }
            if !presentation.rows.isEmpty { y += rowSpacing }
        }
        for (index, row) in presentation.rows.enumerated() {
            if index > 0 { y += rowSpacing }
            let height: CGFloat
            switch row {
            case .member(.step(let item)), .member(.thought(let item)):
                height = ActivityStepView.height(item: item, verb: verb(for: item, verbs: verbs, now: referenceNow), width: contentWidth)
            case .member(.agents(let entries)):
                let member = AgentActivityMember.agents(entries)
                height = AgentRosterView.height(entries: entries, expandedOverride: rosterOverrides[member.id], width: contentWidth)
            case .earlier, .showMore, .earlierFailures:
                height = auxRowHeight
            }
            frames.rows.append((row, NSRect(x: contentX, y: y, width: contentWidth, height: height)))
            y += height
        }
        if !presentation.inline {
            y += padding.height
            frames.chrome = NSRect(x: outerInset.width, y: outerInset.height, width: max(0, width - outerInset.width * 2),
                                   height: y - outerInset.height)
        }
        frames.height = y + outerInset.height
        return frames
    }

    /// `verbs` (extension, defaulted) supplies per-member verbs by item key
    /// when the owner has raw input; otherwise `verbForTool(_:input: nil)`.
    /// `rosterOverrides` (extension, defaulted) holds roster toggles by roster ID.
    static func height(group: AgentActivityGroup, expandedOverride: Bool?, showAll: Bool, width: CGFloat,
                       verbs: [String: AgentToolVerb] = [:], rosterOverrides: [String: Bool] = [:]) -> CGFloat {
        let presentation = presentation(group: group, expandedOverride: expandedOverride, showAll: showAll)
        return frames(group: group, presentation: presentation, verbs: verbs, rosterOverrides: rosterOverrides, width: width).height
    }

    // MARK: Configuration

    /// `expandedOverride` is the user's toggle for this group (nil follows
    /// `group.state`). `showAll` expands a long settled group fully. `now`
    /// drives the live elapsed duration.
    func configure(
        group: AgentActivityGroup,
        expandedOverride: Bool?,
        showAll: Bool,
        now: Date,
        actions: AgentChatRowActions,
        verbs: [String: AgentToolVerb] = [:],
        rosterOverrides: [String: Bool] = [:]
    ) {
        let previous = presentation
        let sameGroup = self.group?.id == group.id
        if !sameGroup { liveLine.reset() }
        let next = Self.presentation(group: group, expandedOverride: expandedOverride, showAll: showAll)
        self.group = group
        self.expandedOverride = expandedOverride
        self.showAll = showAll
        self.verbs = verbs
        self.rosterOverrides = rosterOverrides
        self.now = now
        self.actions = actions
        presentation = next
        chrome.isHidden = next.inline
        header.isHidden = next.inline
        let parts = Self.headerParts(group: group, now: now)
        header.configure(parts: parts, expanded: next.expanded)
        liveLine.isHidden = !next.showsLiveLine
        if next.showsLiveLine {
            liveLine.setText(Self.liveText(group), font: AgentChatText.font(12))
            liveLine.startAnimating()
        } else {
            liveLine.stopAnimating()
        }
        let previousRowIDs = Set(previous?.rows.map(\.id) ?? [])
        let (added, removed) = syncRowViews(next.rows, group: group, now: now)
        var label = "Activity: " + parts.accessibilityText
        if next.showsLiveLine { label += ". " + Self.liveText(group) }
        setAccessibilityLabel(label)
        let collapsing = sameGroup && previous?.expanded == true && previous?.inline == false && !next.expanded && !next.inline
        let expanding = sameGroup && previous?.expanded == false && next.expanded && !next.inline
        let animates = AgentChatMotion.animatesTransitions(in: self)
        if group.state == .settling {
            if collapseReported != group.id {
                collapseReported = group.id
                if collapsing, animates {
                    animateCollapse(removing: removed, groupID: group.id, previousRowIDs: previousRowIDs)
                    return
                }
                reportCollapse(group.id)
            }
        } else {
            collapseReported = nil
            // A late start re-opened the group mid-animation: end the visuals
            // without acknowledging a settle that no longer applies.
            if isAnimatingTransition { finishCollapse(acknowledge: false) }
        }
        removed.forEach { $0.removeFromSuperview() }
        if expanding, animates {
            let fresh = added.filter { !previousRowIDs.contains($0.id) }.map(\.view)
            fadeIn(fresh)
        }
        needsLayout = true
    }

    /// Updates only the ticking duration (the controller's 1 Hz timer while a
    /// live group and its window are visible).
    func tick(now: Date) {
        guard let group, group.state == .live || group.state == .idle else { return }
        self.now = now
        header.configure(parts: Self.headerParts(group: group, now: now), expanded: presentation?.expanded ?? true)
        header.needsLayout = true
        // Chip tooltips carry each running agent's elapsed time.
        for roster in rosterViews.values { roster.tick(now: now) }
    }

    /// Creates or reuses row views by member key; returns views now shown and
    /// views no longer part of the card.
    private func syncRowViews(_ rows: [ActivityCardRow], group: AgentActivityGroup, now: Date)
        -> (added: [(id: String, view: NSView)], removed: [NSView]) {
        var shown: [(id: String, view: NSView)] = []
        var keepSteps: [String: ActivityStepView] = [:]
        var keepRosters: [String: AgentRosterView] = [:]
        var keepAux: [String: AgentChatClosureButton] = [:]
        for row in rows {
            let view: NSView
            switch row {
            case .member(.step(let item)), .member(.thought(let item)):
                let step = keepSteps[item.key] ?? stepViews[item.key] ?? ActivityStepView()
                step.configure(item: item, verb: Self.verb(for: item, verbs: verbs, now: now), actions: actions)
                keepSteps[item.key] = step
                view = step
            case .member(.agents(let entries)):
                let id = AgentActivityMember.agents(entries).id
                let roster = rosterViews[id] ?? AgentRosterView()
                roster.configure(entries: entries, expandedOverride: rosterOverrides[id], now: now, actions: actions)
                keepRosters[id] = roster
                view = roster
            case .earlier(let count):
                let button = auxButtons[row.id] ?? AgentChatClosureButton.link("")
                button.setLinkStyle(count == 1 ? "1 earlier step" : "\(count) earlier steps", color: .textMuted)
                let groupID = group.id
                button.onPress = { [weak self] in self?.actions.openInspector(.group(id: groupID), nil) }
                keepAux[row.id] = button
                view = button
            case .showMore(let count):
                let button = auxButtons[row.id] ?? AgentChatClosureButton.link("")
                button.setLinkStyle("Show \(count) more")
                let groupID = group.id
                button.onPress = { [weak self] in self?.actions.showAll(groupID) }
                keepAux[row.id] = button
                view = button
            case .earlierFailures(let count):
                let button = auxButtons[row.id] ?? AgentChatClosureButton.link("")
                button.setLinkStyle(count == 1 ? "1 earlier failure" : "\(count) earlier failures", color: .failure)
                let groupID = group.id
                button.onPress = { [weak self] in self?.actions.openInspector(.group(id: groupID), nil) }
                keepAux[row.id] = button
                view = button
            }
            if view.superview !== self { addSubview(view) }
            view.isHidden = false
            view.alphaValue = 1
            shown.append((row.id, view))
        }
        let removed: [NSView] = stepViews.filter { keepSteps[$0.key] == nil }.map(\.value)
            + rosterViews.filter { keepRosters[$0.key] == nil }.map(\.value)
            + auxButtons.filter { keepAux[$0.key] == nil }.map(\.value)
        stepViews = keepSteps
        rosterViews = keepRosters
        auxButtons = keepAux
        return (shown, removed)
    }

    private func view(for row: ActivityCardRow) -> NSView? {
        switch row {
        case .member(.step(let item)), .member(.thought(let item)): stepViews[item.key]
        case .member(let member): rosterViews[member.id]
        case .earlier, .showMore, .earlierFailures: auxButtons[row.id]
        }
    }

    private func reportCollapse(_ groupID: String) {
        let callback = actions.collapseFinished
        Task { @MainActor in callback(groupID) }
    }

    private func animateCollapse(removing removed: [NSView], groupID: String, previousRowIDs: Set<String>) {
        guard let group, let presentation else { return }
        let frames = Self.frames(group: group, presentation: presentation, verbs: verbs, rosterOverrides: rosterOverrides,
                                 width: bounds.width)
        isAnimatingTransition = true
        layoutStatic(frames)
        collapseToken += 1
        let token = collapseToken
        pendingCollapse = (groupID, actions.collapseFinished, removed)
        // Rows that were not on screen (e.g. a failure outside the live tail)
        // start at their final frame instead of flying in from the origin.
        for (row, frame) in frames.rows where !previousRowIDs.contains(row.id) { view(for: row)?.frame = frame }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = AgentChatMotion.duration
            context.timingFunction = AgentChatMotion.timing
            context.allowsImplicitAnimation = true
            for view in removed { view.animator().alphaValue = 0 }
            if let chromeFrame = frames.chrome { chrome.animator().frame = chromeFrame }
            for (row, frame) in frames.rows where previousRowIDs.contains(row.id) { view(for: row)?.animator().frame = frame }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.finishCollapse(token: token) }
        })
        // Display-link driven animations stall in an occluded or offscreen
        // window; the machine must still reach `settled`.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(AgentChatMotion.duration + 0.15))
            self?.finishCollapse(token: token)
        }
    }

    /// Ends the settle animation (`token` nil: whatever is pending) and
    /// acknowledges it exactly once (unless `acknowledge` is false).
    private func finishCollapse(token: Int? = nil, acknowledge: Bool = true) {
        if let token, token != collapseToken { return }
        guard let (groupID, callback, removed) = pendingCollapse else { return }
        pendingCollapse = nil
        isAnimatingTransition = false
        for view in removed {
            view.removeFromSuperview()
            view.alphaValue = 1
        }
        needsLayout = true
        if acknowledge { callback(groupID) }
    }

    private func fadeIn(_ views: [NSView]) {
        guard !views.isEmpty else { return }
        views.forEach { $0.alphaValue = 0 }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = AgentChatMotion.duration
            context.timingFunction = AgentChatMotion.timing
            views.forEach { $0.animator().alphaValue = 1 }
        }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        guard let group, let presentation else { return }
        let frames = Self.frames(group: group, presentation: presentation, verbs: verbs, rosterOverrides: rosterOverrides,
                                 width: bounds.width)
        layoutStatic(frames)
        guard !isAnimatingTransition else { return }
        chrome.frame = frames.chrome ?? .zero
        for (row, frame) in frames.rows { view(for: row)?.frame = frame }
    }

    /// Header and live line never animate.
    private func layoutStatic(_ frames: Frames) {
        header.frame = frames.header ?? .zero
        liveLine.frame = frames.liveLine ?? .zero
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        agentChatRemoveAnimations()
        liveLine.stopAnimating()
        if isAnimatingTransition { finishCollapse() }
        collapseReported = nil
    }
}

// MARK: - Header

/// Chevron (toggles) plus a label (opens the group in the Inspector). The
/// summary truncates first, then the step count; failed, stopped, and the
/// duration are never truncated.
final class ActivityHeaderView: NSView {
    static let chevronSize: CGFloat = 16
    static let labelX: CGFloat = 20
    static var summaryFont: NSFont { AgentChatText.font(13, .semibold) }
    static var detailFont: NSFont { AgentChatText.font(13) }
    static let separator = " · "

    let chevron = NSButton()
    let summaryLabel = AgentChatText.makeLabel()
    let stepsLabel = AgentChatText.makeLabel()
    let failedLabel = AgentChatText.makeLabel()
    let stoppedLabel = AgentChatText.makeLabel()
    let durationLabel = AgentChatText.makeLabel()
    var onToggle: () -> Void = {}
    var onOpen: () -> Void = {}
    private(set) var parts = ActivityHeaderParts(summary: "", steps: "")
    private var expanded = false

    init() {
        super.init(frame: .zero)
        chevron.isBordered = false
        chevron.imagePosition = .imageOnly
        chevron.target = self
        chevron.action = #selector(toggle)
        chevron.setAccessibilityIdentifier("agent-chat.activity.toggle")
        for view in [chevron, summaryLabel, stepsLabel, failedLabel, stoppedLabel, durationLabel] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("agent-chat.activity.header")
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func configure(parts: ActivityHeaderParts, expanded: Bool) {
        self.parts = parts
        self.expanded = expanded
        let symbol = expanded ? "chevron.down" : "chevron.right"
        let title = expanded ? "Hide steps" : "Show steps"
        chevron.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        chevron.contentTintColor = AgentChatPalette.color(.textMuted)
        chevron.toolTip = title
        chevron.setAccessibilityLabel(title)
        AgentChatText.apply(summaryLabel, text: parts.summary, font: Self.summaryFont, color: .textPrimary)
        AgentChatText.apply(stepsLabel, text: parts.steps.isEmpty ? "" : Self.separator + parts.steps, font: Self.detailFont,
                            color: .textMuted)
        stepsLabel.isHidden = parts.steps.isEmpty
        AgentChatText.apply(failedLabel, text: parts.failed.map { Self.separator + $0 } ?? "", font: Self.detailFont, color: .failure)
        AgentChatText.apply(stoppedLabel, text: parts.stopped.map { Self.separator + $0 } ?? "", font: Self.detailFont, color: .textMuted)
        AgentChatText.apply(durationLabel, text: parts.duration.map { Self.separator + $0 } ?? "", font: Self.detailFont, color: .textMuted)
        failedLabel.isHidden = parts.failed == nil
        stoppedLabel.isHidden = parts.stopped == nil
        durationLabel.isHidden = parts.duration == nil
        summaryLabel.toolTip = parts.summary
        setAccessibilityLabel(parts.accessibilityText)
        setAccessibilityHelp("Opens this activity in the Inspector")
        needsLayout = true
    }

    /// Label frames for `parts` in a header `width` wide: summary, steps,
    /// failed, stopped, duration (zero-width when absent or squeezed out).
    static func labelFrames(parts: ActivityHeaderParts, width: CGFloat, height: CGFloat) -> [NSRect] {
        let lineHeight = AgentChatText.lineHeight(summaryFont)
        let y = (height - lineHeight) / 2
        let fixed = [parts.failed, parts.stopped, parts.duration].map { part in
            part.map { AgentChatText.width(separator + $0, font: detailFont) } ?? 0
        }
        let stepsWidth = parts.steps.isEmpty ? 0 : AgentChatText.width(separator + parts.steps, font: detailFont)
        let summaryWidth = AgentChatText.width(parts.summary, font: summaryFont)
        let available = max(0, width - labelX - fixed.reduce(0, +))
        let stepsShown = min(stepsWidth, available)
        let summaryShown = min(summaryWidth, max(0, available - stepsShown))
        var x = labelX
        var frames: [NSRect] = []
        for itemWidth in [summaryShown, stepsShown] + fixed {
            frames.append(NSRect(x: x, y: y, width: itemWidth, height: lineHeight))
            x += itemWidth
        }
        return frames
    }

    override func layout() {
        super.layout()
        chevron.frame = NSRect(x: 0, y: (bounds.height - Self.chevronSize) / 2, width: Self.chevronSize, height: Self.chevronSize)
        let frames = Self.labelFrames(parts: parts, width: bounds.width, height: bounds.height)
        for (label, frame) in zip([summaryLabel, stepsLabel, failedLabel, stoppedLabel, durationLabel], frames) {
            label.frame = frame
        }
    }

    @objc private func toggle() { onToggle() }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if point.x < Self.labelX { onToggle() } else { onOpen() }
    }

    override func accessibilityPerformPress() -> Bool {
        onOpen()
        return true
    }

    override func accessibilityChildren() -> [Any]? { [chevron] }
}

// MARK: - Step

/// One step: glyph + verb (13 pt) + muted detail line. Failed: red dot,
/// inline errorSummary, "Ask to retry…" (hidden for replayed, cancelled, and
/// rejected steps). Hover shows `verb.exactInput` in a tooltip and a "Copy
/// command" button. Click opens the Inspector (`.step`, or `.thought` on the
/// Reasoning tab). Thoughts are never copyable from the thread. Exposes AX
/// custom actions: Copy command, Open in Inspector, Ask to retry.
final class ActivityStepView: NSView {
    static let accessibilityIdentifierValue = "agent-chat.step"
    static let verticalPadding: CGFloat = 3
    static let dotX: CGFloat = 3
    static let glyphX: CGFloat = 17
    static let textX: CGFloat = 37
    static let trailingInset: CGFloat = 4
    static let maximumErrorLines = 3
    static let retryTitle = "Ask to retry…"
    static let copyTitle = "Copy command"
    static var labelFont: NSFont { AgentChatText.font(13) }
    static var detailFont: NSFont { AgentChatText.font(12) }

    /// Everything the step shows, already redacted.
    struct Content: Equatable {
        var label: String
        var detail: String?
        var error: String?
        var status: AgentStatusDotView.Status
        var showsRetry: Bool
        var isThought: Bool
        var isStopped: Bool
        /// Tooltip text (single-line redaction).
        var exactInput: String?
        /// Bounded source of "Copy command", redacted (multi-line) only when
        /// copied, so layout never redacts a large command.
        var copySource: String?

        /// "Copy command" text (multi-line redaction).
        var copyText: String? { copySource.map { redactOutput($0, maximumLines: nil).text } }
    }

    /// Longest command "Copy command" writes; the Inspector has the rest.
    static let maximumCopyCharacters = 64 * 1_024

    let hoverSurface = AgentChatSurfaceView(fill: .hover, cornerRadius: 5)
    let dot = AgentStatusDotView()
    let glyph = NSImageView()
    let label = AgentChatText.makeLabel()
    let detailLabel = AgentChatText.makeLabel()
    let errorLabel = AgentChatText.makeLabel(wrapping: true)
    let retryButton = AgentChatClosureButton.link(retryTitle)
    let copyButton = AgentChatClosureButton.link(copyTitle, color: .textMuted)
    private(set) var item: AgentChatItem?
    private(set) var content: Content?
    private var actions = AgentChatRowActions()
    private(set) var isHovering = false

    init() {
        super.init(frame: .zero)
        setAccessibilityIdentifier(Self.accessibilityIdentifierValue)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        hoverSurface.isHidden = true
        glyph.imageScaling = .scaleProportionallyUpOrDown
        errorLabel.maximumNumberOfLines = Self.maximumErrorLines
        copyButton.isHidden = true
        for view in [hoverSurface, dot, glyph, label, detailLabel, errorLabel, retryButton, copyButton] as [NSView] { addSubview(view) }
        retryButton.onPress = { [weak self] in self?.askToRetry() }
        copyButton.onPress = { [weak self] in self?.copyCommand() }
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// `includesInput` false skips the tooltip/copy text (static heights).
    static func content(item: AgentChatItem, verb: AgentToolVerb, includesInput: Bool = true) -> Content {
        func nonEmpty(_ value: String?) -> String? {
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        switch item.content {
        case .tool(let tool):
            let status = AgentStatusDotView.Status(tool)
            let failed = status == .failed
            let stoppedOutcomes: [AgentChatItem.ToolCall.Outcome] = [.cancelled, .rejected, .interrupted]
            let exact = nonEmpty(verb.exactInput)
            // Heights only need to know a copy button can appear.
            let input = includesInput ? exact : exact.map { _ in "" }
            return Content(
                label: redactInline(tool.isRunning ? verb.live : verb.settled),
                detail: nonEmpty(verb.detail).map(redactInline),
                error: failed ? redactInline(String((nonEmpty(tool.errorSummary) ?? "Failed").prefix(200))) : nil,
                status: status,
                showsRetry: failed && !item.isReplayed && !stoppedOutcomes.contains(tool.outcome ?? .completed),
                isThought: false,
                isStopped: status == .stopped,
                exactInput: input.map { redactInline(String($0.prefix(4_096))) },
                copySource: input.map { String($0.prefix(maximumCopyCharacters)) }
            )
        case .thought(let thought):
            let running = thought.endedAt == nil && thought.startedAt != nil
            return Content(label: redactInline(running ? verb.live : verb.settled), detail: nil, error: nil,
                           status: running ? .running : .done, showsRetry: false, isThought: true, isStopped: false,
                           exactInput: nil, copySource: nil)
        default:
            return Content(label: redactInline(verb.settled), detail: nil, error: nil, status: .done, showsRetry: false,
                           isThought: false, isStopped: false, exactInput: nil, copySource: nil)
        }
    }

    struct Frames {
        var dot: NSRect
        var glyph: NSRect
        var label: NSRect
        var copy: NSRect?
        var detail: NSRect?
        var error: NSRect?
        var retry: NSRect?
        var height: CGFloat
    }

    static func frames(content: Content, width: CGFloat, hovering: Bool) -> Frames {
        let line = AgentChatText.lineHeight(labelFont)
        let small = AgentChatText.lineHeight(detailFont)
        let textWidth = max(1, width - textX - trailingInset)
        var y = verticalPadding
        let dotSize = AgentStatusDotView.size
        var frames = Frames(
            dot: NSRect(x: dotX, y: y + (line - dotSize) / 2, width: dotSize, height: dotSize),
            glyph: NSRect(x: glyphX, y: y + (line - 14) / 2, width: 14, height: 14),
            label: NSRect(x: textX, y: y, width: textWidth, height: line),
            height: 0
        )
        if hovering, content.copySource != nil {
            let size = AgentChatClosureButton.linkSize(copyTitle)
            let copy = NSRect(x: width - trailingInset - size.width, y: y + (line - size.height) / 2, width: size.width, height: size.height)
            frames.copy = copy
            frames.label.size.width = max(0, copy.minX - 6 - textX)
        }
        y += line
        if content.detail != nil {
            y += 1
            frames.detail = NSRect(x: textX, y: y, width: textWidth, height: small)
            y += small
        }
        if let error = content.error {
            y += 2
            let height = AgentChatText.height(error, font: detailFont, width: textWidth, maximumLines: maximumErrorLines)
            frames.error = NSRect(x: textX, y: y, width: textWidth, height: height)
            y += height
        }
        if content.showsRetry {
            y += 2
            let size = AgentChatClosureButton.linkSize(retryTitle)
            frames.retry = NSRect(x: textX - 2, y: y, width: size.width, height: size.height)
            y += size.height
        }
        frames.height = y + verticalPadding
        return frames
    }

    /// `item.content` is `.tool` or `.thought`; `verb` comes from
    /// `verbForTool(_:input:)` or `verbForThought(_:now:)`.
    func configure(item: AgentChatItem, verb: AgentToolVerb, actions: AgentChatRowActions) {
        self.item = item
        self.actions = actions
        let content = Self.content(item: item, verb: verb)
        self.content = content
        dot.configure(status: content.status)
        dot.isHidden = content.status == .done
        glyph.image = AgentChatGlyphs.image(for: verb.glyph)
        glyph.contentTintColor = AgentChatPalette.color(content.status == .failed ? .failure : .textMuted)
        AgentChatText.apply(label, text: content.label, font: Self.labelFont, color: content.isStopped ? .textMuted : .textPrimary)
        AgentChatText.apply(detailLabel, text: content.detail ?? "", font: Self.detailFont, color: .textMuted)
        AgentChatText.apply(errorLabel, text: content.error ?? "", font: Self.detailFont, color: .failure,
                            maximumLines: Self.maximumErrorLines)
        detailLabel.isHidden = content.detail == nil
        errorLabel.isHidden = content.error == nil
        retryButton.isHidden = !content.showsRetry
        copyButton.isHidden = !(isHovering && content.copySource != nil)
        toolTip = content.exactInput
        updateAccessibility(content)
        needsLayout = true
    }

    private func updateAccessibility(_ content: Content) {
        var parts: [String] = []
        if content.status != .done { parts.append(content.status.accessibilityName) }
        parts.append(content.label)
        if let detail = content.detail { parts.append(detail) }
        if let error = content.error { parts.append(error) }
        setAccessibilityLabel(parts.joined(separator: ", "))
        setAccessibilityHelp(content.exactInput)
        var custom: [NSAccessibilityCustomAction] = []
        if content.copySource != nil {
            custom.append(NSAccessibilityCustomAction(name: "Copy command", target: self, selector: #selector(accessibilityCopy)))
        }
        custom.append(NSAccessibilityCustomAction(name: "Open in Inspector", target: self, selector: #selector(accessibilityOpen)))
        if content.showsRetry {
            custom.append(NSAccessibilityCustomAction(name: "Ask to retry", target: self, selector: #selector(accessibilityRetry)))
        }
        setAccessibilityCustomActions(custom)
    }

    static func height(item: AgentChatItem, verb: AgentToolVerb, width: CGFloat) -> CGFloat {
        frames(content: content(item: item, verb: verb, includesInput: false), width: width, hovering: false).height
    }

    override func layout() {
        super.layout()
        guard let content else { return }
        let frames = Self.frames(content: content, width: bounds.width, hovering: isHovering)
        hoverSurface.frame = bounds
        dot.frame = frames.dot
        glyph.frame = frames.glyph
        label.frame = frames.label
        copyButton.frame = frames.copy ?? .zero
        detailLabel.frame = frames.detail ?? .zero
        errorLabel.frame = frames.error ?? .zero
        retryButton.frame = frames.retry ?? .zero
    }

    /// Shows or hides hover affordances (tracking areas and tests).
    func setHovering(_ hovering: Bool) {
        isHovering = hovering
        hoverSurface.isHidden = !hovering
        copyButton.isHidden = !(hovering && content?.copySource != nil)
        needsLayout = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        openInspector()
    }

    override func accessibilityPerformPress() -> Bool {
        openInspector()
        return true
    }

    func openInspector() {
        guard let item, let content else { return }
        if content.isThought {
            actions.openInspector(.thought(key: item.key), .reasoning)
        } else {
            actions.openInspector(.step(key: item.key), nil)
        }
    }

    func copyCommand() {
        guard let text = content?.copyText else { return }
        actions.copyText(text)
    }

    func askToRetry() {
        guard let item, content?.showsRetry == true else { return }
        actions.askToRetry(item.key)
    }

    @objc private func accessibilityCopy() -> Bool {
        copyCommand()
        return content?.copySource != nil
    }

    @objc private func accessibilityOpen() -> Bool {
        openInspector()
        return true
    }

    @objc private func accessibilityRetry() -> Bool {
        askToRetry()
        return content?.showsRetry == true
    }
}
