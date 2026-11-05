import Foundation

/// One rendered entry in an agent chat.
struct AgentChatItem: Identifiable, Equatable, Sendable {
    struct ToolCall: Equatable, Sendable {
        var title: String
        var kind: ACPToolKind?
        var status: ACPToolStatus?
        var content: String
    }

    struct Subagent: Equatable, Sendable {
        var childSessionID: String
        var title: String
        var detail: String?
        var state: String?
        var error: String?

        var isRunning: Bool { state == nil || state == "running" || state == "requires_action" }
    }

    enum Content: Equatable, Sendable {
        case user(String)
        case assistant(String)
        case thought(String)
        case tool(ToolCall)
        case plan([ACPPlanEntry])
        case subagent(Subagent)
        case notice(String)
    }

    var id: String
    var content: Content
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

    private(set) var items: [AgentChatItem] = []
    private(set) var childItems: [String: [AgentChatItem]] = [:]
    private var nextLocalID = 0

    mutating func reset() {
        self = AgentTranscript()
    }

    mutating func appendUser(_ text: String) {
        append(.user(text), to: nil)
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

    mutating func apply(_ notification: ACPSessionNotification, rootSessionID: String) {
        let child: String? = notification.sessionID == rootSessionID ? nil : notification.sessionID
        if let child, case .subagent = notification.update {
            // A nested subagent announcing its own child: attach to the parent child list.
            applySubagent(notification.update, in: child)
            return
        }
        if let child { ensureSubagentCard(for: child, state: nil) }

        switch notification.update {
        case .agentMessage(let text):
            appendText(text, to: child, isThought: false)
        case .agentThought(let text):
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
        case .context, .other:
            break
        }
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
        case .thought(let existing)? where isThought:
            replaceLast(in: session, with: .thought(existing + text))
        default:
            append(isThought ? .thought(text) : .assistant(text), to: session)
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
