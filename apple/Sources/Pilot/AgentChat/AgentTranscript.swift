import Foundation

/// Lines a write or edit tool changed in one file. Counts are nil when a
/// side exceeds 20k lines.
struct AgentEditSummary: Equatable, Sendable {
    var path: String
    var added: Int?
    var removed: Int?
    var created: Bool
}

/// One rendered entry in an agent chat.
struct AgentChatItem: Identifiable, Equatable, Sendable {
    struct ToolCall: Equatable, Sendable {
        enum Outcome: Equatable, Sendable {
            case completed, failed, cancelled, rejected, interrupted, notFinished
        }

        var title: String
        var kind: ACPToolKind?
        var status: ACPToolStatus?
        var content: String
        var toolCallID = ""
        var toolName: String? = nil
        var locations: [ACPToolLocation] = []
        var edits: [AgentEditSummary] = []
        /// ≤ 512 characters, derived from rawInput.
        var subject: String? = nil
        /// ≤ 200 characters, redacted before display.
        var errorSummary: String? = nil
        var nonExecutionKind: String? = nil
        var exitCode: Int? = nil
        /// Client receive times; nil for replayed history.
        var startedAt: Date? = nil
        var endedAt: Date? = nil
        var outcome: Outcome? = nil

        /// A settled call has an outcome even when, being replayed, it has no
        /// times; so an outcome also ends it.
        var isRunning: Bool { (status == .pending || status == .inProgress) && endedAt == nil && outcome == nil }
    }

    /// Reasoning text (≤ 256 KiB). Ends at the next non-thought item in its
    /// session, a non-nil `messageID` change, or the end of the turn.
    struct Thought: Equatable, Sendable {
        var text: String
        var messageID: String? = nil
        var startedAt: Date? = nil
        var endedAt: Date? = nil
    }

    struct Subagent: Equatable, Sendable {
        enum Lifecycle: String, Equatable, Sendable {
            case queued, running, done, failed, cancelled, ended, background
        }

        var childSessionID: String
        var title: String
        var detail: String?
        var state: String?
        var error: String?
        var stopReason: String? = nil
        var model: String? = nil
        var startedAt: Date? = nil
        var endedAt: Date? = nil
        var canCancel: Bool? = nil
        var spawnToolCallID: String? = nil
        /// The child has streamed work or reported running; before that an
        /// unreported card is queued.
        var hasStarted = false
        /// Still reported running when the root turn ended.
        var isBackground = false

        var isRunning: Bool { state == nil || state == "running" || state == "requires_action" }

        /// failed: stopReason "error" or an error; cancelled: stopReason
        /// "cancelled"; idle without a stopReason: ended; still running after
        /// the turn ended: background.
        var lifecycle: Lifecycle {
            if stopReason == "error" || error != nil { return .failed }
            if stopReason == "cancelled" { return .cancelled }
            if isRunning {
                if state == nil, !hasStarted { return .queued }
                return isBackground ? .background : .running
            }
            return stopReason == nil ? .ended : .done
        }
    }

    /// A permission request kept in the root timeline as a record.
    struct Approval: Equatable, Sendable {
        enum Decision: Equatable, Sendable {
            case pending
            case chose(optionID: String, name: String, allows: Bool)
            case cancelledByUser
            case withdrawnByAgent
            case autoCancelled
            case agentStopped
        }

        var requestID: JSONValue
        var sessionID: String
        var agentName: String
        var toolCallID: String?
        var title: String
        var kind: ACPToolKind?
        var subject: String?
        var options: [ACPPermissionRequest.Option]
        var decision: Decision
    }

    enum Content: Equatable, Sendable {
        case user(String)
        case assistant(String)
        case thought(Thought)
        case tool(ToolCall)
        case plan([ACPPlanEntry])
        case subagent(Subagent)
        case notice(String)
        case approval(Approval)
    }

    var id: String
    var content: Content
    var attachments: [AgentChatAttachment] = []
    /// Bumped on every mutation; the height-cache key.
    var revision = 0
    var turnIndex = 0
    var isReplayed = false
    /// The owning session: "root" or the child session ID.
    var sessionKey = "root"

    /// The namespaced key used for details, selection, caches, and events.
    var key: String { "\(sessionKey)/\(id)" }

    var isPendingApproval: Bool {
        if case .approval(let approval) = content { return approval.decision == .pending }
        return false
    }
}

extension AgentChatItem.Approval {
    /// A pending record for `request`, as asked by `agentName`.
    init(_ request: ACPPermissionRequest, agentName: String) {
        let subject = AgentChatItem.ToolCall.subject(fromInput: request.rawInput?.value)
            ?? request.locations.first.map { String($0.path.prefix(ACPBounds.subjectCharacters)) }
        self.init(
            requestID: request.requestID, sessionID: request.sessionID,
            agentName: agentName.utf8Prefix(ACPBounds.nameBytes),
            toolCallID: request.toolCallID, title: request.title, kind: request.toolKind, subject: subject,
            options: request.options, decision: .pending
        )
    }
}

/// The chat's transcript, built by applying ACP session updates in order.
///
/// Updates from the root session go to `items`. Updates from any other
/// session are a subagent's: Claude and Codex announce those with
/// `subagent_update` (the subagents RFD); Grok streams the child session
/// without one, so an unannounced child gets a card on its first update,
/// titled after the parent's still-running tool call (Grok's spawn call), and
/// is marked finished when the turn ends. Kimi reports delegation as an
/// ordinary tool call, which renders as one.
///
/// `apply` and `finishTurn` return each lifecycle transition exactly once:
/// a step starts when its item is created and ends on its first terminal
/// outcome; reasoning starts with a thought item and ends when it closes; an
/// agent spawns with its card and ends on its first terminal lifecycle.
/// Replayed history (`isReplaying`) records no times and emits no events.
struct AgentTranscript: Equatable, Sendable {
    /// Bounds memory for very long sessions; the agent keeps the full history.
    static let maximumItemsPerSession = 2_000
    /// Render cap for child sessions; permission routing still tracks all.
    static let maximumChildSessions = 64
    /// Pane budget for `stepDetails` before LRU eviction.
    static let maximumStepDetailBytes = 64 * 1_024 * 1_024
    /// Diffs with more lines than this on either side get no line counts.
    static let maximumDiffLines = 20_000
    static let rootKey = "root"
    static let terminalTruncationMarker = "[earlier output truncated]\n"

    private(set) var items: [AgentChatItem] = []
    private(set) var childItems: [String: [AgentChatItem]] = [:]
    private(set) var stepDetails: [String: AgentStepDetail] = [:]
    /// True from session/load until the first user prompt after it. Ending
    /// replay settles replayed calls that never finished as `.notFinished`.
    var isReplaying = false {
        didSet { if oldValue, !isReplaying { settleReplay() } }
    }
    /// The `stepDetails` byte budget; `maximumStepDetailBytes` unless lowered.
    var stepDetailByteBudget = AgentTranscript.maximumStepDetailBytes
    /// The current turn; `finishTurn` advances it.
    private(set) var turnIndex = 0
    private var nextLocalID = 0
    private var revisionClock = 0
    /// Child session ID → the session key whose list holds its card.
    private var cardOwners: [String: String] = [:]
    /// Session key → the ID of its open thought.
    private var openThoughts: [String: String] = [:]
    private var ledger = DetailLedger()

    private struct DetailLedger: Equatable, Sendable {
        var bytes: [String: Int] = [:]
        var touched: [String: Int] = [:]
        var settled: Set<String> = []
        var truncatedDiffs: [String: Set<String>] = [:]
        var total = 0
        var clock = 0
    }

    /// Clears the chat. Revisions and local IDs keep counting, so no new item
    /// can match a cache entry (key, revision) left from before the reset.
    mutating func reset() {
        let (budget, revision, localID) = (stepDetailByteBudget, revisionClock, nextLocalID)
        self = AgentTranscript()
        (stepDetailByteBudget, revisionClock, nextLocalID) = (budget, revision, localID)
    }

    /// A user prompt; it also ends any replay. `now` ends an open thought.
    mutating func appendUser(_ text: String, attachments: [AgentChatAttachment] = [], now: Date = Date()) {
        isReplaying = false
        var events: [AgentActivityEvent] = []
        appendItem(.user(text), to: Self.rootKey, stamp: now, events: &events)
        if !items.isEmpty { items[items.count - 1].attachments = attachments }
    }

    mutating func appendNotice(_ text: String, now: Date = Date()) {
        var events: [AgentActivityEvent] = []
        appendItem(
            .notice(text.utf8Prefix(ACPBounds.pathBytes)), to: Self.rootKey,
            stamp: isReplaying ? nil : now, events: &events
        )
    }

    func children(of childSessionID: String) -> [AgentChatItem] {
        childItems[childSessionID] ?? []
    }

    /// Called when a prompt turn ends: cards for children that never reported
    /// a state can't still be running on the turn's behalf.
    mutating func finishUnreportedSubagents() {
        for owner in [Self.rootKey] + childItems.keys.sorted() {
            for index in list(owner).indices {
                guard case .subagent(var card) = list(owner)[index].content, card.state == nil else { continue }
                card.state = "idle"
                modify(owner, at: index) { $0.content = .subagent(card) }
            }
        }
    }

    /// Ends the turn: closes thoughts, settles running tools and nil-state
    /// subagents, and advances `turnIndex`. A child the agent still reports
    /// running keeps its thought and tools live and becomes `background`.
    @discardableResult
    mutating func finishTurn(stopReason: String?, now: Date) -> [AgentActivityEvent] {
        let events = settle(stopReason: stopReason, now: now, processEnded: false)
        turnIndex += 1
        return events
    }

    /// The agent process is gone, so nothing it ran still runs: background and
    /// running subagents end cancelled; their thoughts and tools close.
    @discardableResult
    mutating func stopAllSessions(stopReason: String?, now: Date) -> [AgentActivityEvent] {
        settle(stopReason: stopReason, now: now, processEnded: true)
    }

    private mutating func settle(stopReason: String?, now: Date, processEnded: Bool) -> [AgentActivityEvent] {
        let stamp = isReplaying ? nil : now
        var events: [AgentActivityEvent] = []
        let sessions = [Self.rootKey] + childItems.keys.sorted()
        for session in sessions where processEnded || !(session != Self.rootKey && childStillReportsRunning(session)) {
            closeOpenThought(in: session, stamp: stamp, events: &events)
            for index in list(session).indices {
                guard case .tool(var tool) = list(session)[index].content, tool.isRunning else { continue }
                let key = list(session)[index].key
                tool.outcome = stopReason == "cancelled" ? .cancelled : .notFinished
                tool.endedAt = stamp
                modify(session, at: index) { $0.content = .tool(tool) }
                settleDetail(key)
                events.append(.stepEnd(key: key))
            }
        }
        for owner in sessions {
            for index in list(owner).indices {
                guard case .subagent(var card) = list(owner)[index].content, card.isRunning else { continue }
                let before = card.lifecycle
                if processEnded {
                    (card.state, card.stopReason) = ("idle", "cancelled")
                } else if card.state == nil { card.state = "idle" } else { card.isBackground = true }
                transition(&card, from: before, stamp: stamp, events: &events)
                modify(owner, at: index) { $0.content = .subagent(card) }
            }
        }
        return isReplaying ? [] : events
    }

    /// Adds a pending approval record to the root list. Records are never
    /// trimmed while pending and do not close an open thought.
    mutating func recordApproval(_ request: ACPPermissionRequest, agentName: String, now: Date) {
        nextLocalID += 1
        let approval = AgentChatItem.Approval(request, agentName: agentName)
        appendRaw(makeItem(.approval(approval), id: "approval-\(nextLocalID)", session: Self.rootKey), to: Self.rootKey)
    }

    /// Decides the newest pending record for `requestID` in `sessionID`.
    mutating func resolveApproval(requestID: JSONValue, sessionID: String, decision: AgentChatItem.Approval.Decision) {
        guard let index = items.lastIndex(where: { item in
            guard case .approval(let approval) = item.content else { return false }
            return approval.decision == .pending && approval.requestID == requestID && approval.sessionID == sessionID
        }), case .approval(var approval) = items[index].content else { return }
        approval.decision = decision
        modify(Self.rootKey, at: index) { $0.content = .approval(approval) }
    }

    /// Tool steps in a child session.
    func stepStats(of childSessionID: String) -> (total: Int, failed: Int, running: Int) {
        var stats = (total: 0, failed: 0, running: 0)
        for item in children(of: childSessionID) {
            guard case .tool(let tool) = item.content else { continue }
            stats.total += 1
            if tool.outcome == .failed { stats.failed += 1 }
            if tool.isRunning { stats.running += 1 }
        }
        return stats
    }

    @discardableResult
    mutating func apply(
        _ notification: ACPSessionNotification,
        rootSessionID: String,
        now: Date = Date()
    ) -> [AgentActivityEvent] {
        let stamp = isReplaying ? nil : now
        var events: [AgentActivityEvent] = []
        let isRoot = notification.sessionID == rootSessionID
        let session = isRoot ? Self.rootKey : notification.sessionID
        if !isRoot {
            guard admitsChild(session) else { return [] }
        }
        if case .subagent(let state) = notification.update {
            // A nested subagent announcing its own child attaches to that child's list.
            // The root session is never its own child.
            if state.childSessionID != rootSessionID, admitsChild(state.childSessionID) {
                updateSubagentCard(for: state.childSessionID, state: state, parent: session, stamp: stamp, events: &events)
            }
            return isReplaying ? [] : events
        }
        if !isRoot {
            updateSubagentCard(for: session, state: nil, parent: Self.rootKey, stamp: stamp, events: &events)
        }

        switch notification.update {
        case .agentMessage(let text):
            appendAssistant(text, to: session, stamp: stamp, events: &events)
        case .agentThought(let text, let messageID):
            appendThought(text, messageID: messageID, to: session, stamp: stamp, events: &events)
        case .userMessage(let text):
            // Replayed history on session/load, or a subagent's task prompt.
            if case .user(let existing)? = list(session).last?.content {
                modify(session, at: list(session).count - 1) { $0.content = .user(existing + text) }
            } else if !text.isEmpty {
                if isReplaying, isRoot, !items.isEmpty { turnIndex += 1 }
                appendItem(.user(text), to: session, stamp: stamp, events: &events)
            }
        case .toolCall(let fields), .toolCallUpdate(let fields):
            upsertTool(fields, in: session, stamp: stamp, events: &events)
        case .plan(let entries):
            upsertPlan(entries, in: session)
        case .configuration(let patch):
            if !isRoot, let name = patch.model?.currentName { setChildModel(name, for: session) }
        case .currentModel(let id):
            if !isRoot { setChildModel(id, for: session) }
        case .context, .currentMode, .subagent, .other:
            break
        }
        if !isRoot, Self.isChildActivity(notification.update) { markChildStarted(session, stamp: stamp) }
        return isReplaying ? [] : events
    }

    // MARK: - Subagents

    private static func isChildActivity(_ update: ACPUpdate) -> Bool {
        switch update {
        case .agentMessage, .agentThought, .userMessage, .toolCall, .toolCallUpdate, .plan: true
        case .context, .configuration, .currentModel, .currentMode, .subagent, .other: false
        }
    }

    /// Known children always pass; a new one only under the render cap. The
    /// key "root" is reserved for the root session.
    private func admitsChild(_ childID: String) -> Bool {
        guard childID != Self.rootKey else { return false }
        if cardOwners[childID] != nil || childItems[childID] != nil { return true }
        return Set(cardOwners.keys).union(childItems.keys).count < Self.maximumChildSessions
    }

    private func childStillReportsRunning(_ childID: String) -> Bool {
        guard let card = subagentCard(childID)?.card else { return false }
        return card.state != nil && card.isRunning
    }

    private func subagentCard(_ childID: String) -> (owner: String, index: Int, card: AgentChatItem.Subagent)? {
        let itemID = "subagent-\(childID)"
        guard let owner = cardOwners[childID],
              let index = list(owner).lastIndex(where: { $0.id == itemID }),
              case .subagent(let card) = list(owner)[index].content else { return nil }
        return (owner, index, card)
    }

    /// Creates the card for `childID` in `parent`'s list the first time the
    /// child is seen, wherever it was announced; later calls update the
    /// existing card in place. A state report replaces the stop reason and
    /// error, so a recovered child clears them.
    private mutating func updateSubagentCard(
        for childID: String,
        state: ACPSubagentState?,
        parent: String,
        stamp: Date?,
        events: inout [AgentActivityEvent]
    ) {
        if let found = subagentCard(childID) {
            guard let state else { return }
            var card = found.card
            let before = card.lifecycle
            if let title = state.title { card.title = title }
            if let detail = state.detail { card.detail = detail }
            if let value = state.state {
                card.state = value
                card.stopReason = state.stopReason
                card.error = state.error
            }
            if let canCancel = state.canCancel { card.canCancel = canCancel }
            if card.state != nil, card.isRunning, card.startedAt == nil { card.startedAt = stamp }
            transition(&card, from: before, stamp: stamp, events: &events)
            guard card != found.card else { return }
            modify(found.owner, at: found.index) { $0.content = .subagent(card) }
            return
        }
        let spawn = state == nil ? runningTool(in: parent) : nil
        var card = AgentChatItem.Subagent(
            childSessionID: childID,
            title: state?.title ?? spawn?.title ?? "Subagent",
            detail: state?.detail,
            state: state?.state,
            error: state?.error
        )
        card.stopReason = state?.stopReason
        card.canCancel = state?.canCancel
        card.spawnToolCallID = spawn?.toolCallID
        if card.state != nil, card.isRunning { card.startedAt = stamp }
        let itemID = "subagent-\(childID)"
        appendItem(.subagent(card), id: itemID, to: parent, stamp: stamp, events: &events)
        cardOwners[childID] = parent
        events.append(.agentSpawn(childSessionID: childID, parentKey: spawn?.key))
        let created = card
        transition(&card, from: .running, stamp: stamp, events: &events)
        if card != created, let found = subagentCard(childID) {
            modify(found.owner, at: found.index) { $0.content = .subagent(card) }
        }
    }

    /// Records times and events for a lifecycle change: ending stamps
    /// `endedAt` (and a missing `startedAt`) once; running again reopens it.
    private func transition(
        _ card: inout AgentChatItem.Subagent,
        from before: AgentChatItem.Subagent.Lifecycle,
        stamp: Date?,
        events: inout [AgentActivityEvent]
    ) {
        let terminal: Set<AgentChatItem.Subagent.Lifecycle> = [.done, .failed, .cancelled, .ended]
        let after = card.lifecycle
        if terminal.contains(after), !terminal.contains(before) {
            card.endedAt = stamp
            if card.startedAt == nil { card.startedAt = stamp }
            card.isBackground = false
            events.append(.agentEnd(childSessionID: card.childSessionID, lifecycle: after.rawValue))
        } else if terminal.contains(before), !terminal.contains(after) {
            card.endedAt = nil
            events.append(.agentSpawn(childSessionID: card.childSessionID, parentKey: nil))
        }
    }

    private mutating func markChildStarted(_ childID: String, stamp: Date?) {
        guard let found = subagentCard(childID), !found.card.hasStarted || found.card.startedAt == nil else { return }
        var card = found.card
        card.hasStarted = true
        if card.startedAt == nil { card.startedAt = stamp }
        guard card != found.card else { return }
        modify(found.owner, at: found.index) { $0.content = .subagent(card) }
    }

    private mutating func setChildModel(_ name: String, for childID: String) {
        guard let found = subagentCard(childID), let model = name.boundedNonEmpty(ACPBounds.nameBytes),
              found.card.model != model else { return }
        var card = found.card
        card.model = model
        modify(found.owner, at: found.index) { $0.content = .subagent(card) }
    }

    /// The latest unfinished tool call in `session`: for an agent that spawns
    /// children without announcing them, the call that started this one.
    private func runningTool(in session: String) -> (title: String, toolCallID: String, key: String)? {
        for item in list(session).reversed() {
            if case .tool(let tool) = item.content, tool.isRunning {
                return (tool.title, tool.toolCallID, item.key)
            }
        }
        return nil
    }

    // MARK: - Text and thoughts

    private mutating func appendAssistant(_ text: String, to session: String, stamp: Date?, events: inout [AgentActivityEvent]) {
        guard !text.isEmpty else { return }
        if case .assistant? = list(session).last?.content {
            appendInPlace(text, session: session, at: list(session).count - 1)
        } else {
            appendItem(.assistant(text), to: session, stamp: stamp, events: &events)
        }
    }

    /// Codex reports a model reroute (for clients without notices) and gaps
    /// in replayed child history as reasoning; they are notices.
    static func isNoticeThought(_ text: String, messageID: String?) -> Bool {
        text.hasPrefix("Model rerouted from ")
            || messageID?.hasSuffix(":subagent-history-gap") == true
            || text.hasPrefix("Some recorded child history is unavailable or incomplete.")
    }

    private mutating func appendThought(
        _ text: String,
        messageID: String?,
        to session: String,
        stamp: Date?,
        events: inout [AgentActivityEvent]
    ) {
        guard !text.isEmpty else { return }
        if Self.isNoticeThought(text, messageID: messageID) {
            let notice = text.utf8Prefix(ACPBounds.pathBytes).trimmingCharacters(in: .whitespacesAndNewlines)
            appendItem(.notice(notice), to: session, stamp: stamp, events: &events)
            return
        }
        if let open = openThoughtRoom(in: session, messageID: messageID) {
            guard open.room > 0 else { return }
            appendInPlace(text.utf8Prefix(open.room), session: session, at: open.index)
            return
        }
        closeOpenThought(in: session, stamp: stamp, events: &events)
        nextLocalID += 1
        let thought = AgentChatItem.Thought(
            text: text.utf8Prefix(ACPBounds.thoughtBytes), messageID: messageID, startedAt: stamp
        )
        let item = makeItem(.thought(thought), id: "local-\(nextLocalID)", session: session)
        appendRaw(item, to: session)
        openThoughts[session] = item.id
        events.append(.reasoningDelta(key: item.key))
    }

    /// The open thought a chunk continues and its remaining byte budget
    /// (only the index escapes, so the text buffer stays uniquely owned).
    private func openThoughtRoom(in session: String, messageID: String?) -> (index: Int, room: Int)? {
        guard let open = openThought(in: session), messageID == nil || messageID == open.thought.messageID else { return nil }
        return (open.index, ACPBounds.thoughtBytes - open.thought.text.utf8.count)
    }

    /// Appends to prose or a thought in place: taking the payload out first
    /// leaves its buffer uniquely referenced, so a chunk doesn't copy it all.
    private mutating func appendInPlace(_ text: String, session: String, at index: Int) {
        modify(session, at: index) { item in
            if case .assistant(var existing) = item.content {
                item.content = .notice("")
                existing += text
                item.content = .assistant(existing)
            } else if case .thought(var thought) = item.content {
                item.content = .notice("")
                thought.text += text
                item.content = .thought(thought)
            }
        }
    }

    private func openThought(in session: String) -> (index: Int, thought: AgentChatItem.Thought)? {
        guard let id = openThoughts[session],
              let index = list(session).lastIndex(where: { $0.id == id }),
              case .thought(let thought) = list(session)[index].content else { return nil }
        return (index, thought)
    }

    private mutating func closeOpenThought(in session: String, stamp: Date?, events: inout [AgentActivityEvent]) {
        guard let open = openThought(in: session) else {
            openThoughts[session] = nil
            return
        }
        openThoughts[session] = nil
        var thought = open.thought
        if thought.endedAt == nil { thought.endedAt = stamp }
        let key = list(session)[open.index].key
        modify(session, at: open.index) { $0.content = .thought(thought) }
        events.append(.reasoningEnd(key: key))
    }

    // MARK: - Tools

    private mutating func upsertTool(
        _ fields: ACPToolCallFields,
        in session: String,
        stamp: Date?,
        events: inout [AgentActivityEvent]
    ) {
        let existing = list(session).lastIndex { item in
            if case .tool(let tool) = item.content { return tool.toolCallID == fields.toolCallID }
            return false
        }
        if let index = existing, case .tool(var tool) = list(session)[index].content {
            let item = list(session)[index]
            // A settled call from an earlier turn is history: a reused ID starts a new step.
            if tool.outcome == nil || item.turnIndex == turnIndex {
                Self.merge(fields, into: &tool)
                // A payload-only update (terminal output) still bumps the revision.
                let detailChanged = recordDetail(item.key, fields)
                if tool.outcome == nil {
                    finishIfTerminal(&tool, key: item.key, stamp: stamp, events: &events)
                } else {
                    // A late payload for a settled call is evictable like the rest.
                    settleDetail(item.key)
                    if tool.outcome == .failed, tool.errorSummary == nil { tool.errorSummary = errorSummary(tool, key: item.key) }
                }
                if detailChanged || tool != (list(session)[index].content.toolCall) {
                    modify(session, at: index) { $0.content = .tool(tool) }
                }
                return
            }
        }
        let itemID = existing == nil ? "tool-\(fields.toolCallID)" : "tool-\(fields.toolCallID)#\(turnIndex)"
        var tool = AgentChatItem.ToolCall(title: "Tool call", kind: nil, status: .pending, content: "")
        tool.toolCallID = fields.toolCallID
        tool.startedAt = stamp
        Self.merge(fields, into: &tool)
        appendItem(.tool(tool), id: itemID, to: session, stamp: stamp, events: &events)
        let key = "\(session)/\(itemID)"
        events.append(.stepStart(key: key))
        recordDetail(key, fields)
        let started = tool
        finishIfTerminal(&tool, key: key, stamp: stamp, events: &events)
        if tool != started, let index = list(session).indices.last {
            modify(session, at: index) { $0.content = .tool(tool) }
        }
    }

    private static func merge(_ fields: ACPToolCallFields, into tool: inout AgentChatItem.ToolCall) {
        if let title = fields.title, !title.isEmpty { tool.title = title }
        if let kind = fields.kind { tool.kind = kind }
        if let status = fields.status { tool.status = status }
        if let content = fields.content { tool.content = content }
        if let locations = fields.locations { tool.locations = locations }
        if let name = fields.toolName { tool.toolName = name }
        if let kind = fields.nonExecutionKind { tool.nonExecutionKind = kind }
        if let code = fields.exitCode { tool.exitCode = code }
        if let subject = AgentChatItem.ToolCall.subject(fromInput: fields.rawInput?.value) { tool.subject = subject }
    }

    /// Settles a call on its first terminal status: outcome, end time, error
    /// summary, and edit counts are computed once here.
    private mutating func finishIfTerminal(
        _ tool: inout AgentChatItem.ToolCall,
        key: String,
        stamp: Date?,
        events: inout [AgentActivityEvent]
    ) {
        guard tool.outcome == nil,
              let outcome = Self.outcome(status: tool.status, nonExecutionKind: tool.nonExecutionKind) else { return }
        tool.outcome = outcome
        if let stamp {
            tool.endedAt = stamp
            if tool.startedAt == nil { tool.startedAt = stamp }
        }
        switch outcome {
        case .failed:
            tool.errorSummary = errorSummary(tool, key: key)
        case .completed:
            tool.edits = Self.edits(
                blocks: stepDetails[key]?.blocks ?? [], truncatedPaths: ledger.truncatedDiffs[key] ?? []
            )
        case .cancelled, .rejected, .interrupted, .notFinished:
            break
        }
        settleDetail(key)
        events.append(outcome == .failed
            ? .stepFail(key: key, summary: tool.errorSummary.map(redactInline))
            : .stepEnd(key: key))
    }

    private func errorSummary(_ tool: AgentChatItem.ToolCall, key: String) -> String? {
        let detail = stepDetails[key]
        var candidates: [String] = []
        for case .text(let text) in detail?.blocks ?? [] { candidates.append(text) }
        if let output = detail?.rawOutput?.value {
            if let text = output.stringValue { candidates.append(text) }
            for field in ["error", "stderr", "message", "formatted_output", "aggregated_output", "output"] {
                if let text = output[field]?.stringValue ?? output[field]?["message"]?.stringValue {
                    candidates.append(text)
                }
            }
        }
        if let prefix = detail?.rawOutput?.prefixText { candidates.append(prefix) }
        // `content` repeats the text blocks plus "Edited <path>" lines, which
        // are no error; it is the fallback only once the detail is gone.
        if detail?.blocks.isEmpty ?? true { candidates.append(tool.content) }
        return candidates.lazy.compactMap(Self.summaryLine).first
    }

    // MARK: - Plans

    /// One plan item per session and turn, updated in place.
    private mutating func upsertPlan(_ entries: [ACPPlanEntry], in session: String) {
        if let index = list(session).lastIndex(where: { item in
            if case .plan = item.content { return item.turnIndex == turnIndex }
            return false
        }) {
            modify(session, at: index) { $0.content = .plan(entries) }
        } else {
            let id = turnIndex == 0 ? "plan-\(session)" : "plan-\(session)-\(turnIndex)"
            appendRaw(makeItem(.plan(entries), id: id, session: session), to: session)
        }
    }

    // MARK: - Replay

    private mutating func settleReplay() {
        for session in [Self.rootKey] + childItems.keys.sorted() {
            for index in list(session).indices {
                guard list(session)[index].isReplayed,
                      case .tool(var tool) = list(session)[index].content, tool.isRunning else { continue }
                tool.outcome = .notFinished
                let key = list(session)[index].key
                modify(session, at: index) { $0.content = .tool(tool) }
                settleDetail(key)
            }
        }
        openThoughts.removeAll()
        if !items.isEmpty { turnIndex += 1 }
    }

    // MARK: - List plumbing

    private func list(_ session: String) -> [AgentChatItem] {
        session == Self.rootKey ? items : childItems[session] ?? []
    }

    private mutating func mutate(_ session: String, _ body: (inout [AgentChatItem]) -> Void) {
        if session == Self.rootKey {
            body(&items)
        } else {
            body(&childItems[session, default: []])
        }
    }

    private mutating func nextRevision() -> Int {
        revisionClock += 1
        return revisionClock
    }

    /// Mutates one item and bumps its revision.
    private mutating func modify(_ session: String, at index: Int, _ body: (inout AgentChatItem) -> Void) {
        let revision = nextRevision()
        mutate(session) { list in
            guard list.indices.contains(index) else { return }
            body(&list[index])
            list[index].revision = revision
        }
    }

    private mutating func makeItem(_ content: AgentChatItem.Content, id: String, session: String) -> AgentChatItem {
        var item = AgentChatItem(id: id, content: content)
        item.revision = nextRevision()
        item.turnIndex = turnIndex
        item.isReplayed = isReplaying
        item.sessionKey = session
        return item
    }

    /// Appends a narrative or step item, which closes the session's open thought.
    private mutating func appendItem(
        _ content: AgentChatItem.Content,
        id: String? = nil,
        to session: String,
        stamp: Date?,
        events: inout [AgentActivityEvent]
    ) {
        closeOpenThought(in: session, stamp: stamp, events: &events)
        let itemID: String
        if let id {
            itemID = id
        } else {
            nextLocalID += 1
            itemID = "local-\(nextLocalID)"
        }
        appendRaw(makeItem(content, id: itemID, session: session), to: session)
    }

    private mutating func appendRaw(_ item: AgentChatItem, to session: String) {
        mutate(session) { $0.append(item) }
        trim(session)
    }

    /// Over the cap, drops the oldest 10% in one chunk, keeping pending
    /// approvals, and forgets what the dropped items held.
    private mutating func trim(_ session: String) {
        let current = list(session)
        guard current.count > Self.maximumItemsPerSession else { return }
        var toDrop = current.count - (Self.maximumItemsPerSession - Self.maximumItemsPerSession / 10)
        var kept: [AgentChatItem] = []
        var dropped: [AgentChatItem] = []
        kept.reserveCapacity(current.count - toDrop)
        for item in current {
            if toDrop > 0, !item.isPendingApproval {
                dropped.append(item)
                toDrop -= 1
            } else {
                kept.append(item)
            }
        }
        mutate(session) { $0 = kept }
        for item in dropped {
            forgetDetail(item.key)
            if openThoughts[session] == item.id { openThoughts[session] = nil }
            guard case .subagent(let card) = item.content else { continue }
            cardOwners[card.childSessionID] = nil
            if !card.isRunning, let orphaned = childItems.removeValue(forKey: card.childSessionID) {
                orphaned.forEach { forgetDetail($0.key) }
                openThoughts[card.childSessionID] = nil
            }
        }
    }

    // MARK: - Step details

    /// Stores the call's payloads; true when the stored detail changed.
    @discardableResult
    private mutating func recordDetail(_ key: String, _ fields: ACPToolCallFields) -> Bool {
        guard fields.rawInput != nil || fields.rawOutput != nil || fields.blocks != nil
            || fields.terminalOutputDelta != nil else { return false }
        // Taken out so the terminal buffer is uniquely referenced while it grows.
        var detail = stepDetails.removeValue(forKey: key) ?? AgentStepDetail()
        guard !detail.evicted else { stepDetails[key] = detail; return false }
        if let input = fields.rawInput { detail.rawInput = input }
        if let output = fields.rawOutput { detail.rawOutput = output }
        if let blocks = fields.blocks {
            detail.blocks = blocks
            ledger.truncatedDiffs[key] = fields.truncatedDiffPaths.isEmpty ? nil : Set(fields.truncatedDiffPaths)
        }
        if let delta = fields.terminalOutputDelta { Self.appendTerminal(delta, to: &detail.terminalOutput) }
        let bytes = Self.retainedBytes(detail)
        ledger.total += bytes - (ledger.bytes[key] ?? 0)
        ledger.bytes[key] = bytes
        ledger.clock += 1
        ledger.touched[key] = ledger.clock
        stepDetails[key] = detail
        evictIfNeeded()
        return true
    }

    private mutating func settleDetail(_ key: String) {
        guard let detail = stepDetails[key], !detail.evicted else { return }
        ledger.settled.insert(key)
        evictIfNeeded()
    }

    /// Over budget, evicts settled details least recently written first,
    /// down to 90% of the budget. Running steps are never evicted.
    private mutating func evictIfNeeded() {
        guard ledger.total > stepDetailByteBudget else { return }
        let target = stepDetailByteBudget - stepDetailByteBudget / 10
        let oldestFirst = ledger.settled.sorted { (ledger.touched[$0] ?? 0) < (ledger.touched[$1] ?? 0) }
        for key in oldestFirst {
            guard ledger.total > target else { break }
            forgetDetail(key)
            stepDetails[key] = AgentStepDetail(evicted: true)
        }
    }

    private mutating func forgetDetail(_ key: String) {
        ledger.total -= ledger.bytes.removeValue(forKey: key) ?? 0
        ledger.touched[key] = nil
        ledger.settled.remove(key)
        ledger.truncatedDiffs[key] = nil
        stepDetails[key] = nil
    }
}

private extension AgentChatItem.Content {
    var toolCall: AgentChatItem.ToolCall? {
        if case .tool(let tool) = self { return tool }
        return nil
    }
}
