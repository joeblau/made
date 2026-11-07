import Foundation

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
