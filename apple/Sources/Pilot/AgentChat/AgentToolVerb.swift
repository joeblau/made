import Foundation

/// A human verb for one step, never the raw command. Every string is redacted.
struct AgentToolVerb: Equatable, Sendable {
    enum Glyph: Equatable, Hashable, Sendable, CaseIterable {
        case shell, read, search, edit, create, delete, move, fetch, web, think, agent, plan, mcp, other
    }

    var glyph: Glyph
    /// While running, e.g. "Running git status".
    var live: String
    /// Once settled, e.g. "Ran git status".
    var settled: String
    /// Muted sub-line, e.g. "a.swift, b.swift +3".
    var detail: String?
    /// Full command or arguments for the tooltip and approval card (redacted,
    /// control and bidi characters escaped).
    var exactInput: String?
}

/// Resolution order: toolName (including `_meta`) → rawInput shape → title
/// heuristics → kind → fallback (title, else toolName, else "Tool call").
/// "Thought" is reserved for reasoning members.
func verbForTool(_ tool: AgentChatItem.ToolCall, input: JSONValue?) -> AgentToolVerb {
    // WP3: implement
    let label = redactInline(tool.title.isEmpty ? tool.toolName ?? "Tool call" : tool.title)
    return AgentToolVerb(glyph: .other, live: label, settled: label, detail: nil, exactInput: nil)
}

/// "Thought for 12s" when both times are known, otherwise "Thought".
func verbForThought(_ thought: AgentChatItem.Thought, now: Date) -> AgentToolVerb {
    // WP3: implement
    AgentToolVerb(glyph: .think, live: "Thinking", settled: "Thought", detail: nil, exactInput: nil)
}
