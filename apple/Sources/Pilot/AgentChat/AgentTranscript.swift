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

        var isRunning: Bool { (status == .pending || status == .inProgress) && endedAt == nil }
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

        var isRunning: Bool { state == nil || state == "running" || state == "requires_action" }

        /// failed: stopReason "error" or an error; cancelled: stopReason
        /// "cancelled"; idle without a stopReason: ended; still running after
        /// the turn ended: background.
        var lifecycle: Lifecycle {
            // WP1: implement (queued, background)
            if stopReason == "error" || error != nil { return .failed }
            if stopReason == "cancelled" { return .cancelled }
            if isRunning { return .running }
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
}

extension AgentChatItem.Approval {
    /// A pending record for `request`, as asked by `agentName`.
    init(_ request: ACPPermissionRequest, agentName: String) {
        // WP1: implement (subject from rawInput)
        self.init(
            requestID: request.requestID, sessionID: request.sessionID, agentName: agentName,
            toolCallID: request.toolCallID, title: request.title, kind: request.toolKind, subject: nil,
            options: request.options, decision: .pending
        )
    }
}

/// Raw, bounded per-step payloads kept beside the transcript, keyed
/// "<session>/<item>". Evicted (LRU, oldest settled first) over the pane budget.
struct AgentStepDetail: Equatable, Sendable {
    var rawInput: ACPBoundedJSON?
    var rawOutput: ACPBoundedJSON?
    var blocks: [ACPToolContent] = []
    var terminalOutput = ""
    var evicted = false
}

/// Typed lifecycle events the transcript emits as it applies updates. Keys
/// are namespaced "<session>/<item>".
enum AgentActivityEvent: Equatable, Sendable {
    case stepStart(key: String)
    case stepEnd(key: String)
    case stepFail(key: String, summary: String?)
    case agentSpawn(childSessionID: String, parentKey: String?)
    case agentEnd(childSessionID: String, lifecycle: String)
    case reasoningDelta(key: String)
    case reasoningEnd(key: String)
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
struct AgentTranscript: Equatable, Sendable {
    /// Bounds memory for very long sessions; the agent keeps the full history.
    static let maximumItemsPerSession = 2_000
    /// Render cap for child sessions; permission routing still tracks all.
    static let maximumChildSessions = 64
    /// Pane budget for `stepDetails` before LRU eviction.
    static let maximumStepDetailBytes = 64 * 1_024 * 1_024

    private(set) var items: [AgentChatItem] = []
    private(set) var childItems: [String: [AgentChatItem]] = [:]
    private(set) var stepDetails: [String: AgentStepDetail] = [:]
    /// True from session/load until the first user prompt after it.
    var isReplaying = false
    private var nextLocalID = 0

    mutating func reset() {
        self = AgentTranscript()
    }

    mutating func appendUser(_ text: String, attachments: [AgentChatAttachment] = []) {
        append(.user(text), to: nil)
        if !items.isEmpty { items[items.count - 1].attachments = attachments }
    }

    mutating func appendNotice(_ text: String) {
        append(.notice(text), to: nil)
    }

    func children(of childSessionID: String) -> [AgentChatItem] {
        childItems[childSessionID] ?? []
    }

    /// Called when a prompt turn ends: cards for children that never reported
    /// a state can't still be running on the turn's behalf.
    mutating func finishUnreportedSubagents() {
        for owner in [nil] + childItems.keys.map(Optional.some) {
            mutate(owner) { list in
                for index in list.indices {
                    if case .subagent(var card) = list[index].content, card.state == nil {
                        card.state = "idle"
                        list[index].content = .subagent(card)
                    }
                }
            }
        }
    }

    /// Ends the turn: closes thoughts, settles running tools and nil-state
    /// subagents, and advances `turnIndex`.
    @discardableResult
    mutating func finishTurn(stopReason: String?, now: Date) -> [AgentActivityEvent] {
        // WP1: implement
        finishUnreportedSubagents()
        return []
    }

    /// Adds a pending approval record to the root list.
    mutating func recordApproval(_ request: ACPPermissionRequest, agentName: String, now: Date) {
        // WP1: implement
    }

    mutating func resolveApproval(requestID: JSONValue, sessionID: String, decision: AgentChatItem.Approval.Decision) {
        // WP1: implement
    }

    /// Tool steps in a child session.
    func stepStats(of childSessionID: String) -> (total: Int, failed: Int, running: Int) {
        // WP1: implement (outcome-based)
        var stats = (total: 0, failed: 0, running: 0)
        for item in children(of: childSessionID) {
            guard case .tool(let tool) = item.content else { continue }
            stats.total += 1
            if tool.status == .failed { stats.failed += 1 }
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
        // WP1: implement (emit events, record times from now)
        let child: String? = notification.sessionID == rootSessionID ? nil : notification.sessionID
        if let child, case .subagent = notification.update {
            // A nested subagent announcing its own child: attach to the parent child list.
            applySubagent(notification.update, in: child)
            return []
        }
        if let child { ensureSubagentCard(for: child, state: nil) }

        switch notification.update {
        case .agentMessage(let text):
            appendText(text, to: child, isThought: false)
        case .agentThought(let text, _):
            appendText(text, to: child, isThought: true)
        case .userMessage(let text):
            // Replayed history on session/load, or a subagent's task prompt.
            if case .user(let existing)? = lastContent(in: child) {
                replaceLast(in: child, with: .user(existing + text))
            } else if !text.isEmpty {
                append(.user(text), to: child)
            }
        case .toolCall(let fields), .toolCallUpdate(let fields):
            upsertTool(fields, in: child)
        case .plan(let entries):
            upsertPlan(entries, in: child)
        case .subagent:
            applySubagent(notification.update, in: nil)
        case .context, .modelConfiguration, .currentModel, .other:
            break
        }
        return []
    }

    // MARK: - Mutation helpers

    private mutating func applySubagent(_ update: ACPUpdate, in parent: String?) {
        guard case .subagent(let state) = update else { return }
        ensureSubagentCard(for: state.childSessionID, state: state, parent: parent)
    }

    /// Creates the card for `childID` in `parent`'s list (nil: the root) the
    /// first time the child is seen, wherever it was announced; later calls
    /// update the existing card in place.
    private mutating func ensureSubagentCard(for childID: String, state: ACPSubagentState?, parent: String? = nil) {
        let itemID = "subagent-\(childID)"
        if let found = locate(itemID) {
            guard let state, case .subagent(var card) = list(found.owner)[found.index].content else { return }
            if let title = state.title { card.title = title }
            if let detail = state.detail { card.detail = detail }
            if let value = state.state { card.state = value }
            card.error = state.error ?? card.error
            mutate(found.owner) { $0[found.index].content = .subagent(card) }
            return
        }
        let card = AgentChatItem.Subagent(
            childSessionID: childID,
            title: state?.title ?? runningToolTitle(in: parent) ?? "Subagent",
            detail: state?.detail,
            state: state?.state,
            error: state?.error
        )
        mutate(parent) { $0.append(AgentChatItem(id: itemID, content: .subagent(card))) }
        trim(parent)
    }

    /// The latest unfinished tool call in `session`: for an agent that spawns
    /// children without announcing them, the call that started this one.
    private func runningToolTitle(in session: String?) -> String? {
        for item in list(session).reversed() {
            if case .tool(let tool) = item.content, tool.status == .pending || tool.status == .inProgress {
                return tool.title
            }
        }
        return nil
    }

    /// The list holding `itemID` (`owner` nil for the root) and its index.
    private func locate(_ itemID: String) -> (owner: String?, index: Int)? {
        if let index = items.firstIndex(where: { $0.id == itemID }) { return (nil, index) }
        for (owner, list) in childItems {
            if let index = list.firstIndex(where: { $0.id == itemID }) { return (owner, index) }
        }
        return nil
    }

    private mutating func appendText(_ text: String, to session: String?, isThought: Bool) {
        guard !text.isEmpty else { return }
        switch lastContent(in: session) {
        case .assistant(let existing)? where !isThought:
            replaceLast(in: session, with: .assistant(existing + text))
        case .thought(var existing)? where isThought:
            existing.text += text
            replaceLast(in: session, with: .thought(existing))
        default:
            append(isThought ? .thought(AgentChatItem.Thought(text: text)) : .assistant(text), to: session)
        }
    }

    private mutating func upsertTool(_ fields: ACPToolCallFields, in session: String?) {
        let itemID = "tool-\(fields.toolCallID)"
        if let index = list(session).firstIndex(where: { $0.id == itemID }),
           case .tool(var tool) = list(session)[index].content {
            if let title = fields.title, !title.isEmpty { tool.title = title }
            if let kind = fields.kind { tool.kind = kind }
            if let status = fields.status { tool.status = status }
            if let content = fields.content { tool.content = content }
            mutate(session) { $0[index].content = .tool(tool) }
            return
        }
        let tool = AgentChatItem.ToolCall(
            title: fields.title ?? "Tool call",
            kind: fields.kind,
            status: fields.status ?? .pending,
            content: fields.content ?? ""
        )
        mutate(session) { $0.append(AgentChatItem(id: itemID, content: .tool(tool))) }
        trim(session)
    }

    private mutating func upsertPlan(_ entries: [ACPPlanEntry], in session: String?) {
        let itemID = "plan-\(session ?? "root")"
        if let index = list(session).firstIndex(where: { $0.id == itemID }) {
            mutate(session) { $0[index].content = .plan(entries) }
        } else {
            mutate(session) { $0.append(AgentChatItem(id: itemID, content: .plan(entries))) }
        }
    }

    private func list(_ session: String?) -> [AgentChatItem] {
        guard let session else { return items }
        return childItems[session] ?? []
    }

    private func lastContent(in session: String?) -> AgentChatItem.Content? {
        list(session).last?.content
    }

    private mutating func mutate(_ session: String?, _ body: (inout [AgentChatItem]) -> Void) {
        if let session {
            body(&childItems[session, default: []])
        } else {
            body(&items)
        }
    }

    private mutating func replaceLast(in session: String?, with content: AgentChatItem.Content) {
        mutate(session) { list in
            guard !list.isEmpty else { return }
            list[list.count - 1].content = content
        }
    }

    private mutating func append(_ content: AgentChatItem.Content, to session: String?) {
        nextLocalID += 1
        let item = AgentChatItem(id: "local-\(nextLocalID)", content: content)
        mutate(session) { $0.append(item) }
        trim(session)
    }

    private mutating func trim(_ session: String?) {
        mutate(session) { list in
            let overflow = list.count - Self.maximumItemsPerSession
            if overflow > 0 { list.removeFirst(overflow) }
        }
    }
}
