import AppKit

/// Keys the transcript table handles while it is first responder.
enum AgentChatTimelineKey: Equatable {
    case next, previous, open, focusComposer, escape, stop

    init?(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        let characters = event.charactersIgnoringModifiers ?? ""
        if flags == .command, characters == "." { self = .stop; return }
        guard flags.isEmpty else { return nil }
        switch (event.keyCode, characters) {
        case (53, _): self = .escape
        case (36, _), (76, _): self = .open
        case (_, "j"): self = .next
        case (_, "k"): self = .previous
        case (_, "/"): self = .focusComposer
        default: return nil
        }
    }
}

/// The transcript table: no type-select, a step cursor with a focus ring
/// over visible steps (a collapsed card is one stop), chips, and records.
/// j/k move only while the table is first responder; Enter opens the
/// Inspector; "/" focuses the composer; Esc closes the Inspector, else
/// cancels a running turn from an empty composer, else nothing.
final class AgentChatTimelineTableView: NSTableView {
    /// Returns true when the key was handled.
    var onKey: (AgentChatTimelineKey) -> Bool = { _ in false }
    var onFocusChange: (Bool) -> Void = { _ in }
    /// Window visibility or occlusion changed (the 1 Hz tick follows it).
    var onWindowStateChange: () -> Void = {}

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        allowsTypeSelect = false
        focusRingType = .none
    }

    required init?(coder: NSCoder) { nil }

    override func keyDown(with event: NSEvent) {
        if let key = AgentChatTimelineKey(event), onKey(key) { return }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange(false) }
        return resigned
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowStateChanged),
                                                   name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        onWindowStateChange()
    }

    @objc private func windowStateChanged() { onWindowStateChange() }

    isolated deinit { NotificationCenter.default.removeObserver(self) }
}

/// Data source and delegate for `AgentChatTimelineTableView`: one reuse
/// identifier per row kind, arithmetic heights cached by (row id, revision,
/// width, zoom, expanded, state, showAll), and minimal diffs in `applyRows`.
/// It also owns the activity disclosure state: settle acknowledgements,
/// per-group expansion overrides, "show all", roster toggles, and the 1 Hz
/// tick for visible live cards.
@MainActor
final class AgentChatTimelineTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /// How the last `applyRows` updated the table (budget tests).
    enum ApplyPath: Equatable, Sendable {
        /// Identical IDs: changed cells reconfigured in place.
        case reconfigure
        /// Rows appended at the tail.
        case insert
        /// Rows removed from the head (transcript trim).
        case headTrim
        case reload
    }

    struct HeightKey: Hashable {
        var revision: Int
        var width: CGFloat
        var zoom: Double
        var expanded: Bool?
        var state: AgentActivityState?
        var showAll: Bool
        /// Inputs outside `revision`: roster counts and toggles, "Send again", text length.
        var extra: Int
    }

    let tableView: AgentChatTimelineTableView
    /// The pane's callbacks; disclosure callbacks are handled here.
    var actions = AgentChatRowActions()
    /// A step key's raw input (verbs read commands, paths, and patterns from it).
    var stepInput: (String) -> JSONValue? = { _ in nil }
    /// The prose row currently streaming.
    var streamingKey: String? {
        didSet { if oldValue != streamingKey { refresh(ids: [oldValue, streamingKey]) } }
    }
    /// The failed-turn notice that offers "Send again" (it changes the row's height).
    var sendAgainNoticeKey: String? {
        didSet { if oldValue != sendAgainNoticeKey { refresh(ids: [oldValue, sendAgainNoticeKey]) } }
    }
    /// Captions beneath user bubbles by item key: a pending or delivered steer.
    var userCaptions: [String: String] = [:] {
        didSet {
            guard oldValue != userCaptions else { return }
            let keys = Set(oldValue.keys).union(userCaptions.keys).filter { oldValue[$0] != userCaptions[$0] }
            refresh(ids: Array(keys))
        }
    }
    /// An inactive pane never ticks.
    var isPaused = false {
        didSet { if oldValue != isPaused { updateTimer() } }
    }
    var now: () -> Date = { Date() }
    /// A settle acknowledgement changed what the projection returns.
    var onStateChange: () -> Void = {}
    var onSelect: () -> Void = {}
    private(set) var rows: [AgentTimelineRow] = []
    private(set) var lastApplyPath: ApplyPath?
    /// Rows whose visible cells the last `applyRows` reconfigured in place.
    private(set) var lastReconfiguredRows: [Int] = []
    private(set) var acknowledgedSettles: Set<String> = []
    private(set) var expandedOverrides: [String: Bool] = [:]
    private(set) var showAllGroups: Set<String> = []
    private(set) var rosterOverrides: [String: Bool] = [:]
    let cursor: AgentChatTimelineCursor
    private var heights: [String: (key: HeightKey, height: CGFloat)] = [:]
    private var verbCache: [String: (revision: Int, verb: AgentToolVerb)] = [:]
    private var timer: Timer?
    private var applyingFollow: Bool?

    var isTicking: Bool { timer != nil }

    init(tableView: AgentChatTimelineTableView) {
        self.tableView = tableView
        cursor = AgentChatTimelineCursor(tableView: tableView)
        super.init()
        cursor.timeline = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("transcript"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.intercellSpacing = NSSize(width: 0, height: 8)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.setAccessibilityLabel("Agent conversation")
        tableView.setAccessibilityIdentifier("agent-chat.transcript")
        tableView.dataSource = self
        tableView.delegate = self
        tableView.onWindowStateChange = { [weak self] in self?.updateTimer() }
        tableView.onFocusChange = { [weak self] _ in self?.cursor.focusChanged() }
        // Cells consume mouseDown for their own clicks; a non-delaying click
        // recognizer still lets a click focus the table and place the cursor.
        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked(_:)))
        click.delaysPrimaryMouseButtonEvents = false
        tableView.addGestureRecognizer(click)
        NotificationCenter.default.addObserver(self, selector: #selector(proseRendered(_:)), name: .agentProseDidRender, object: nil)
    }

    /// A long message finished redacting off the main actor: its cached
    /// height measured the previous rendering.
    @objc private func proseRendered(_ notification: Notification) {
        guard let key = notification.object as? String, let index = rows.firstIndex(where: { $0.id == key }) else { return }
        let follow = followsOutput
        heights[key] = nil
        applyingFollow = follow
        refresh(rows: [index], animated: false)
        applyingFollow = nil
        if follow { scrollToEnd() }
    }

    @objc private func clicked(_ recognizer: NSClickGestureRecognizer) {
        onSelect()
        guard let window = tableView.window else { return }
        // Selecting prose keeps its text view as first responder; a click
        // elsewhere (a step after a selection) still focuses the table.
        if let text = window.firstResponder as? NSTextView, text.isDescendant(of: tableView),
           text.visibleRect.contains(text.convert(recognizer.location(in: nil), from: nil)) { return }
        if window.firstResponder !== tableView { window.makeFirstResponder(tableView) }
        cursor.select(at: recognizer.location(in: tableView))
    }

    /// Tracks scrolling so the tick and the cursor ring follow the visible rows.
    func observeScrolling(_ scrollView: NSScrollView) {
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
    }

    @objc private func scrolled() {
        updateTimer()
        cursor.updateRing()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Disclosure state

    /// Drops acknowledgements of groups that went live again and records them
    /// at once for settling groups that won't animate: inline groups, hidden
    /// windows, Reduce Motion, and cards that aren't on screen. Returns true
    /// when the projection must be recomputed.
    func acknowledgeSettles(in next: [AgentTimelineRow]) -> Bool {
        var settling: [AgentActivityGroup] = []
        for case .activity(let group) in next {
            if group.isLive { acknowledgedSettles.remove(group.id) }
            if group.state == .settling, !acknowledgedSettles.contains(group.id) { settling.append(group) }
        }
        guard !settling.isEmpty else { return false }
        let animates = AgentChatMotion.animatesTransitions(in: tableView)
        let visible = tableView.rows(in: tableView.visibleRect)
        let visibleIDs = Set((visible.location..<NSMaxRange(visible)).compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
        var changed = false
        for group in settling where !group.animatesSettle || !animates || !visibleIDs.contains(group.id) {
            acknowledgedSettles.insert(group.id)
            changed = true
        }
        return changed
    }

    /// The card's settle animation finished (or was skipped).
    func acknowledge(_ groupID: String) {
        guard rows.contains(where: { $0.id == groupID }), acknowledgedSettles.insert(groupID).inserted else { return }
        onStateChange()
    }

    /// Toggles a group (by group id) or a roster (by roster id, including a
    /// collapsed card's failed-agent roster).
    func toggleExpanded(_ id: String) {
        for (index, row) in rows.enumerated() {
            guard case .activity(let group) = row else { continue }
            if group.id == id {
                expandedOverrides[id] = !group.layout(expandedOverride: expandedOverrides[id], showAll: showAllGroups.contains(id)).isExpanded
            } else if let entries = rosterEntries(id, in: group) {
                rosterOverrides[id] = !AgentRosterView.isExpanded(entries: entries, expandedOverride: rosterOverrides[id])
            } else {
                continue
            }
            refresh(rows: [index], animated: true)
            return
        }
    }

    private func rosterEntries(_ id: String, in group: AgentActivityGroup) -> [AgentRosterEntry]? {
        let shown = group.layout(expandedOverride: expandedOverrides[group.id], showAll: showAllGroups.contains(group.id)).entries
        for case .member(.agents(let entries)) in shown where AgentActivityMember.agents(entries).id == id { return entries }
        for case .agents(let entries) in group.members where AgentActivityMember.agents(entries).id == id { return entries }
        return nil
    }

    func showAll(_ groupID: String) {
        guard let index = rows.firstIndex(where: { $0.id == groupID }), showAllGroups.insert(groupID).inserted else { return }
        refresh(rows: [index], animated: true)
    }

    private func refresh(ids: [String?]) {
        let wanted = Set(ids.compactMap { $0 })
        guard !wanted.isEmpty else { return }
        refresh(rows: rows.indices.filter { wanted.contains(rows[$0].id) }, animated: false)
    }

    private func refresh(rows indexes: [Int], animated: Bool) {
        guard !indexes.isEmpty else { return }
        for index in indexes { _ = reconfigure(index) }
        noteHeights(IndexSet(indexes), animated: animated)
        cursor.updateRing()
    }

    // MARK: Applying rows

    var followsOutput: Bool {
        guard let scroll = tableView.enclosingScrollView else { return true }
        return rows.isEmpty || scroll.contentView.bounds.maxY >= tableView.bounds.maxY - 32
    }

    func applyRows(_ next: [AgentTimelineRow], now: Date) {
        guard rows != next else { return }
        let follow = followsOutput
        applyingFollow = follow
        defer { applyingFollow = nil }
        let old = rows
        let oldIDs = old.map(\.id)
        let newIDs = next.map(\.id)
        rows = next
        var pairs: [(old: Int, new: Int)] = []
        if oldIDs == newIDs {
            lastApplyPath = .reconfigure
            pairs = old.indices.map { ($0, $0) }
        } else if newIDs.count >= oldIDs.count, newIDs[..<oldIDs.count].elementsEqual(oldIDs) {
            lastApplyPath = .insert
            pairs = old.indices.map { ($0, $0) }
            tableView.insertRows(at: IndexSet(integersIn: old.count..<next.count), withAnimation: [])
        } else if let first = newIDs.first, let trimmed = oldIDs.firstIndex(of: first), trimmed > 0,
                  newIDs.count >= oldIDs.count - trimmed, newIDs[..<(oldIDs.count - trimmed)].elementsEqual(oldIDs[trimmed...]) {
            lastApplyPath = .headTrim
            pairs = (trimmed..<old.count).map { ($0, $0 - trimmed) }
            tableView.removeRows(at: IndexSet(integersIn: 0..<trimmed), withAnimation: [])
            if next.count > old.count - trimmed {
                tableView.insertRows(at: IndexSet(integersIn: (old.count - trimmed)..<next.count), withAnimation: [])
            }
        } else {
            lastApplyPath = .reload
            lastReconfiguredRows = []
            prune(Set(newIDs))
            tableView.reloadData()
            finishApply(follow: follow)
            return
        }
        if lastApplyPath != .reconfigure { prune(Set(newIDs)) }
        var reconfigured: [Int] = []
        var changed = IndexSet()
        var collapsing = IndexSet()
        for (oldIndex, newIndex) in pairs where old[oldIndex] != next[newIndex] {
            changed.insert(newIndex)
            if Self.kind(old[oldIndex]) != Self.kind(next[newIndex]) {
                tableView.reloadData(forRowIndexes: [newIndex], columnIndexes: [0])
            } else if reconfigure(newIndex) {
                reconfigured.append(newIndex)
            }
            if case .activity(let before) = old[oldIndex], case .activity(let after) = next[newIndex],
               before.isLive, after.animatesSettle {
                collapsing.insert(newIndex)
            }
        }
        lastReconfiguredRows = reconfigured
        noteHeights(changed.subtracting(collapsing), animated: false)
        noteHeights(collapsing, animated: true)
        finishApply(follow: follow)
    }

    private func finishApply(follow: Bool) {
        if follow { scrollToEnd() }
        updateTimer()
        cursor.rowsChanged()
    }

    private func scrollToEnd() {
        if !rows.isEmpty, let scroll = tableView.enclosingScrollView {
            tableView.layoutSubtreeIfNeeded()
            // A capped message row can still be taller than the viewport;
            // scrollRowToVisible may align its top instead of the newest text.
            let clip = scroll.contentView
            clip.scroll(to: NSPoint(x: 0, y: max(0, tableView.bounds.maxY - clip.bounds.height)))
            scroll.reflectScrolledClipView(clip)
            // Visible cells already received the follow flag in configure.
            tableView.view(atColumn: 0, row: rows.count - 1, makeIfNecessary: false)?.layoutSubtreeIfNeeded()
        }
    }

    private func noteHeights(_ indexes: IndexSet, animated: Bool) {
        guard !indexes.isEmpty else { return }
        guard animated, AgentChatMotion.animatesTransitions(in: tableView) else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                tableView.noteHeightOfRows(withIndexesChanged: indexes)
            }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = AgentChatMotion.duration
            context.timingFunction = AgentChatMotion.timing
            tableView.noteHeightOfRows(withIndexesChanged: indexes)
        }
    }

    /// Width changed: every height is stale.
    func widthChanged() {
        guard !rows.isEmpty else { return }
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: rows.indices))
        cursor.updateRing()
    }

    /// Zoom changed: rebuild every cell.
    func reloadAll() {
        heights.removeAll()
        tableView.reloadData()
        cursor.updateRing()
    }

    private func prune(_ ids: Set<String>) {
        heights = heights.filter { ids.contains($0.key) }
        acknowledgedSettles.formIntersection(ids)
        expandedOverrides = expandedOverrides.filter { ids.contains($0.key) }
        showAllGroups.formIntersection(ids)
        if verbCache.count > 4_096 { verbCache.removeAll(keepingCapacity: true) }
    }

    private enum Kind { case user, prose, activity, record, plan, notice }

    private static func kind(_ row: AgentTimelineRow) -> Kind {
        switch row {
        case .user: .user
        case .prose: .prose
        case .activity: .activity
        case .approvalRecord: .record
        case .plan: .plan
        case .notice: .notice
        }
    }

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        onSelect()
        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let view: NSTableCellView
        switch rows[row] {
        case .user: view = make(UserBubbleCellView.reuseIdentifier) { UserBubbleCellView() }
        case .prose: view = make(ProseCellView.reuseIdentifier) { ProseCellView() }
        case .activity: view = make(ActivityCardView.reuseIdentifier) { ActivityCardView() }
        case .approvalRecord: view = make(ApprovalRecordView.reuseIdentifier) { ApprovalRecordView() }
        case .plan: view = make(PlanRowView.reuseIdentifier) { PlanRowView() }
        case .notice: view = make(NoticeCellView.reuseIdentifier) { NoticeCellView() }
        }
        configure(view, row: row)
        return view
    }

    private func make(_ identifier: NSUserInterfaceItemIdentifier, _ create: () -> NSTableCellView) -> NSTableCellView {
        let view = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? create()
        view.identifier = identifier
        return view
    }

    /// Reconfigures a visible cell in place; false when the row has no cell.
    @discardableResult
    private func reconfigure(_ row: Int) -> Bool {
        guard let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView else { return false }
        configure(view, row: row)
        return true
    }

    private var rowActions: AgentChatRowActions {
        var actions = actions
        actions.toggleExpanded = { [weak self] in self?.toggleExpanded($0) }
        actions.showAll = { [weak self] in self?.showAll($0) }
        actions.collapseFinished = { [weak self] in self?.acknowledge($0) }
        return actions
    }

    private func configure(_ view: NSTableCellView, row: Int) {
        guard rows.indices.contains(row) else { return }
        let actions = rowActions
        switch rows[row] {
        case .user(let item):
            (view as? UserBubbleCellView)?.configure(item: item, actions: actions, caption: userCaptions[item.key])
        case .prose(let item):
            let follows = applyingFollow ?? followsOutput
            // The streaming message follows even while a pending steer
            // bubble sits below it.
            (view as? ProseCellView)?.configure(item: item, isStreaming: item.key == streamingKey,
                                                followStreamingOutput: follows && (row == rows.count - 1 || item.key == streamingKey),
                                                actions: actions)
        case .activity(let group):
            (view as? ActivityCardView)?.configure(
                group: group, expandedOverride: expandedOverrides[group.id], showAll: showAllGroups.contains(group.id),
                now: now(), actions: actions, verbs: verbs(for: group), rosterOverrides: rosterOverrides
            )
        case .approvalRecord(let item):
            (view as? ApprovalRecordView)?.configure(item: item, actions: actions)
        case .plan(let item):
            (view as? PlanRowView)?.configure(item: item, actions: actions)
        case .notice(let item):
            (view as? NoticeCellView)?.configure(item: item, offersSendAgain: item.key == sendAgainNoticeKey, actions: actions)
        }
    }

    // MARK: Heights

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return 24 }
        let rowValue = rows[row]
        let width = max(1, tableView.tableColumns.first?.width ?? tableView.bounds.width)
        let key = heightKey(rowValue, width: width)
        if let cached = heights[rowValue.id], cached.key == key { return cached.height }
        let height = max(1, ceil(measure(rowValue, width: width)))
        heights[rowValue.id] = (key, height)
        return height
    }

    private func heightKey(_ row: AgentTimelineRow, width: CGFloat) -> HeightKey {
        let zoom = CockpitUIZoomController.shared.factor
        switch row {
        case .activity(let group):
            var hasher = Hasher()
            for entry in group.rosterEntries {
                hasher.combine(entry.id)
                hasher.combine(entry.lifecycle.rawValue)
                hasher.combine(entry.steps)
                hasher.combine(entry.failed)
            }
            for case .agents(let entries) in group.members {
                let id = AgentActivityMember.agents(entries).id
                hasher.combine(id)
                hasher.combine(rosterOverrides[id])
            }
            return HeightKey(revision: group.revision, width: width, zoom: zoom, expanded: expandedOverrides[group.id],
                             state: group.state, showAll: showAllGroups.contains(group.id), extra: hasher.finalize())
        case .prose(let item):
            let length = if case .assistant(let text) = item.content { text.utf16.count } else { 0 }
            return HeightKey(revision: item.revision, width: width, zoom: zoom, expanded: nil, state: nil, showAll: false, extra: length)
        case .user(let item):
            let length = if case .user(let text) = item.content { text.utf16.count } else { 0 }
            var hasher = Hasher()
            hasher.combine(length)
            hasher.combine(item.attachments.count)
            hasher.combine(userCaptions[item.key])
            return HeightKey(revision: item.revision, width: width, zoom: zoom, expanded: nil, state: nil, showAll: false,
                             extra: hasher.finalize())
        case .notice(let item):
            return HeightKey(revision: item.revision, width: width, zoom: zoom, expanded: nil, state: nil, showAll: false,
                             extra: item.key == sendAgainNoticeKey ? 1 : 0)
        case .approvalRecord(let item), .plan(let item):
            return HeightKey(revision: item.revision, width: width, zoom: zoom, expanded: nil, state: nil, showAll: false, extra: 0)
        }
    }

    private func measure(_ row: AgentTimelineRow, width: CGFloat) -> CGFloat {
        switch row {
        case .user(let item): UserBubbleCellView.height(item: item, width: width, caption: userCaptions[item.key])
        case .prose(let item): ProseCellView.height(item: item, width: width)
        case .activity(let group):
            ActivityCardView.height(group: group, expandedOverride: expandedOverrides[group.id], showAll: showAllGroups.contains(group.id),
                                    width: width, verbs: verbs(for: group), rosterOverrides: rosterOverrides)
        case .approvalRecord(let item): ApprovalRecordView.height(item: item, width: width)
        case .plan(let item): PlanRowView.height(item: item, width: width)
        case .notice(let item): NoticeCellView.height(item: item, width: width, offersSendAgain: item.key == sendAgainNoticeKey)
        }
    }

    // MARK: Verbs

    /// Per-member verbs built from raw input, cached by (key, revision).
    func verbs(for group: AgentActivityGroup) -> [String: AgentToolVerb] {
        var verbs: [String: AgentToolVerb] = [:]
        let now = now()
        for member in group.members {
            switch member {
            case .step(let item):
                guard case .tool(let tool) = item.content else { continue }
                if let cached = verbCache[item.key], cached.revision == item.revision {
                    verbs[item.key] = cached.verb
                } else {
                    let verb = verbForTool(tool, input: stepInput(item.key))
                    verbCache[item.key] = (item.revision, verb)
                    verbs[item.key] = verb
                }
            case .thought(let item):
                if case .thought(let thought) = item.content { verbs[item.key] = verbForThought(thought, now: now) }
            case .agents:
                continue
            }
        }
        return verbs
    }

    // MARK: Tick

    /// One 1 Hz timer, only while a live group is visible in a visible window.
    func updateTimer() {
        let windowVisible = tableView.window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
        let needed = windowVisible && !isPaused && !tableView.isHiddenOrHasHiddenAncestor && visibleRows().contains { index in
            if case .activity(let group) = rows[index] { group.isLive } else { false }
        }
        if needed, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        } else if !needed, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }

    /// Updates every visible live card's elapsed duration and chip tooltips.
    func tick() {
        let now = now()
        for index in visibleRows() {
            guard case .activity(let group) = rows[index], group.isLive else { continue }
            (tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? ActivityCardView)?.tick(now: now)
        }
        updateTimer()
    }

    func visibleRows() -> [Int] {
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.location != NSNotFound else { return [] }
        return (range.location..<NSMaxRange(range)).filter { rows.indices.contains($0) }
    }

    isolated deinit {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
}
