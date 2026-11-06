import Foundation

/// Agent Client Protocol (v1) method names, request builders, and parsers for
/// the subset of messages the chat pane renders. Everything here is a pure
/// function of JSON so it can be tested without launching an agent.
enum ACP {
    static let protocolVersion = 1

    enum Method {
        static let initialize = "initialize"
        static let authenticate = "authenticate"
        static let newSession = "session/new"
        static let loadSession = "session/load"
        static let prompt = "session/prompt"
        static let cancel = "session/cancel"
        static let update = "session/update"
        static let requestPermission = "session/request_permission"
        static let setConfigOption = "session/set_config_option"
        static let setModel = "session/set_model"
    }

    // MARK: Requests

    /// Cockpit renders files and terminals from the agent's own tool calls, so
    /// it advertises no fs/terminal capabilities: the agent keeps using its
    /// built-in tools exactly as it does in the TUI. `subagents` opts into the
    /// subagents RFD so delegated work arrives as child sessions.
    static func initializeParams(clientVersion: String) -> JSONValue {
        [
            "protocolVersion": .number(Double(protocolVersion)),
            "clientCapabilities": [
                "fs": ["readTextFile": false, "writeTextFile": false],
                "terminal": false,
                "subagents": [:],
            ],
            "clientInfo": ["name": "cockpit", "title": "Cockpit", "version": .string(clientVersion)],
        ]
    }

    /// Passing no MCP servers keeps the agent's own configured servers — and
    /// with them the same tool list, and cacheable prompt prefix, as its TUI.
    static func newSessionParams(cwd: String) -> JSONValue {
        ["cwd": .string(cwd), "mcpServers": []]
    }

    static func loadSessionParams(sessionID: String, cwd: String) -> JSONValue {
        ["sessionId": .string(sessionID), "cwd": .string(cwd), "mcpServers": []]
    }

    static func promptParams(sessionID: String, text: String, attachments: [JSONValue] = []) -> JSONValue {
        let textBlocks: [JSONValue] = text.isEmpty ? [] : [["type": "text", "text": .string(text)]]
        return ["sessionId": .string(sessionID), "prompt": .array(textBlocks + attachments)]
    }

    static func cancelParams(sessionID: String) -> JSONValue {
        ["sessionId": .string(sessionID)]
    }

    /// `nil` answers with the `cancelled` outcome, which ACP requires for any
    /// permission request still open when the client cancels a turn.
    static func permissionResult(optionID: String?) -> JSONValue {
        guard let optionID else { return ["outcome": ["outcome": "cancelled"]] }
        return ["outcome": ["outcome": "selected", "optionId": .string(optionID)]]
    }
}

// MARK: - Initialize / session results

struct ACPAgentInfo: Equatable, Sendable {
    struct AuthMethod: Equatable, Sendable {
        var id: String
        var name: String
        var isTerminalLogin: Bool
    }

    var name: String?
    var version: String?
    var canLoadSession: Bool
    var supportsImages: Bool
    var authMethods: [AuthMethod]
    /// An auth method the agent can complete without UI, such as Grok's
    /// cached token. Nil when signing in needs a terminal or browser.
    var silentAuthMethodID: String?

    init(_ result: JSONValue) {
        name = result["agentInfo"]?["title"]?.stringValue ?? result["agentInfo"]?["name"]?.stringValue
        version = result["agentInfo"]?["version"]?.stringValue ?? result["_meta"]?["agentVersion"]?.stringValue
        canLoadSession = result["agentCapabilities"]?["loadSession"]?.boolValue ?? false
        supportsImages = result["agentCapabilities"]?["promptCapabilities"]?["image"]?.boolValue ?? false
        authMethods = (result["authMethods"]?.arrayValue ?? []).compactMap { method in
            guard let id = method["id"]?.stringValue else { return nil }
            return AuthMethod(
                id: id,
                name: method["name"]?.stringValue ?? id,
                isTerminalLogin: method["type"]?.stringValue == "terminal"
            )
        }
        let declaredDefault = result["_meta"]?["defaultAuthMethodId"]?.stringValue
        silentAuthMethodID = authMethods.first { method in
            // Cursor's ACP method reads existing CLI credentials; the actual
            // interactive login is a separate `cursor-agent login` command.
            !method.isTerminalLogin && (method.id == declaredDefault || method.id.localizedCaseInsensitiveContains("cached")
                || method.id == "cursor_login")
        }?.id
    }
}

enum ACPSessionResult {
    /// Best-effort current model name; agents report it in different places.
    static func modelName(_ result: JSONValue) -> String? {
        ACPModelState(result)?.currentName
    }
}

/// Prefer the current config-options API, with the older models API retained
/// for installed adapters that still advertise it. Never invent model IDs.
struct ACPModelState: Equatable, Sendable {
    struct Choice: Equatable, Sendable {
        var id: String
        var name: String
        var detail: String?
        var group: String?
    }

    enum Selection: Equatable, Sendable {
        case configuration(String)
        case legacy
    }

    var currentID: String
    var choices: [Choice]
    var selection: Selection?
    var currentName: String { choices.first { $0.id == currentID }?.name ?? currentID }

    init?(_ result: JSONValue) {
        if let model = result["configOptions"]?.arrayValue?.first(where: {
            ($0["category"]?.stringValue == "model" || $0["id"]?.stringValue == "model")
                && ($0["type"] == nil || $0["type"]?.stringValue == "select")
        }), let id = model["id"]?.stringValue, let current = model["currentValue"]?.stringValue {
            currentID = current
            selection = .configuration(id)
            choices = []
            for option in model["options"]?.arrayValue ?? [] {
                let entries = option["options"]?.arrayValue ?? [option]
                for entry in entries.prefix(500) {
                    guard choices.count < 500, let value = entry["value"]?.stringValue,
                          !choices.contains(where: { $0.id == value }) else { continue }
                    choices.append(Choice(id: value, name: entry["name"]?.stringValue ?? value,
                                          detail: entry["description"]?.stringValue,
                                          group: option["options"] == nil ? nil : option["name"]?.stringValue))
                }
            }
        } else if let models = result["models"], let current = models["currentModelId"]?.stringValue {
            currentID = current
            selection = .legacy
            choices = (models["availableModels"]?.arrayValue ?? []).prefix(500).compactMap {
                guard let id = $0["modelId"]?.stringValue else { return nil }
                return Choice(id: id, name: $0["name"]?.stringValue ?? id, detail: $0["description"]?.stringValue)
            }
        } else if let current = result["_meta"]?["modelState"]?["currentModelId"]?.stringValue {
            currentID = current
            choices = []
            selection = nil
        } else { return nil }
    }

    func request(sessionID: String, modelID: String) -> (method: String, params: JSONValue)? {
        guard choices.contains(where: { $0.id == modelID }) else { return nil }
        switch selection {
        case .configuration(let id):
            return (ACP.Method.setConfigOption, ["sessionId": .string(sessionID), "configId": .string(id), "value": .string(modelID)])
        case .legacy:
            return (ACP.Method.setModel, ["sessionId": .string(sessionID), "modelId": .string(modelID)])
        case nil: return nil
        }
    }
}

// MARK: - Session updates

enum ACPToolKind: String, Sendable {
    case read, edit, delete, move, search, execute, think, fetch, other
    case switchMode = "switch_mode"
}

enum ACPToolStatus: String, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
    case failed
}

struct ACPToolCallFields: Equatable, Sendable {
    var toolCallID: String
    var title: String?
    var kind: ACPToolKind?
    var status: ACPToolStatus?
    /// Text and diff summaries from `content`; nil when the update carried none.
    var content: String?
}

struct ACPPlanEntry: Equatable, Sendable {
    var content: String
    var status: String
}

/// Context-window state from `usage_update`.
struct ACPContextUsage: Equatable, Sendable {
    var usedTokens: Int
    var windowTokens: Int
    var costAmount: Double?
    var costCurrency: String?
}

struct ACPSubagentState: Equatable, Sendable {
    var childSessionID: String
    var title: String?
    var detail: String?
    var state: String?
    var stopReason: String?
    var error: String?
}

enum ACPUpdate: Equatable, Sendable {
    case agentMessage(String)
    case agentThought(String)
    case userMessage(String)
    case toolCall(ACPToolCallFields)
    case toolCallUpdate(ACPToolCallFields)
    case plan([ACPPlanEntry])
    case context(ACPContextUsage)
    case modelConfiguration(ACPModelState?)
    case currentModel(String)
    case subagent(ACPSubagentState)
    case other(kind: String)
}

struct ACPSessionNotification: Equatable, Sendable {
    var sessionID: String
    var update: ACPUpdate
}

extension ACP {
    static func parseSessionUpdate(_ params: JSONValue) -> ACPSessionNotification? {
        guard let sessionID = params["sessionId"]?.stringValue,
              let update = params["update"],
              let kind = update["sessionUpdate"]?.stringValue else { return nil }
        let parsed: ACPUpdate
        switch kind {
        case "config_option_update":
            parsed = .modelConfiguration(ACPModelState(update))
        case "current_model_update":
            guard let id = update["currentModelId"]?.stringValue else { return nil }
            parsed = .currentModel(id)
        case "agent_message_chunk":
            parsed = .agentMessage(contentText(update["content"]) ?? "")
        case "agent_thought_chunk":
            parsed = .agentThought(contentText(update["content"]) ?? "")
        case "user_message_chunk":
            parsed = .userMessage(contentText(update["content"]) ?? "")
        case "tool_call":
            guard let fields = toolCallFields(update) else { return nil }
            parsed = .toolCall(fields)
        case "tool_call_update":
            guard let fields = toolCallFields(update) else { return nil }
            parsed = .toolCallUpdate(fields)
        case "plan":
            parsed = .plan((update["entries"]?.arrayValue ?? []).compactMap { entry in
                guard let content = entry["content"]?.stringValue else { return nil }
                return ACPPlanEntry(content: content, status: entry["status"]?.stringValue ?? "pending")
            })
        case "usage_update":
            guard let used = update.int("used"), let size = update.int("size") else { return nil }
            parsed = .context(ACPContextUsage(
                usedTokens: used,
                windowTokens: size,
                costAmount: update["cost"]?["amount"]?.doubleValue,
                costCurrency: update["cost"]?["currency"]?.stringValue
            ))
        case "subagent_update":
            guard let child = update["sessionId"]?.stringValue else { return nil }
            let state = update["state"]
            parsed = .subagent(ACPSubagentState(
                childSessionID: child,
                title: update["title"]?.stringValue,
                detail: update["description"]?.stringValue,
                state: state?["state"]?.stringValue ?? state?.stringValue,
                stopReason: state?["stopReason"]?.stringValue,
                error: state?["error"]?.stringValue
            ))
        default:
            parsed = .other(kind: kind)
        }
        return ACPSessionNotification(sessionID: sessionID, update: parsed)
    }

    private static func contentText(_ content: JSONValue?) -> String? {
        guard let content, content["type"]?.stringValue == "text" else { return nil }
        return content["text"]?.stringValue
    }

    private static func toolCallFields(_ update: JSONValue) -> ACPToolCallFields? {
        guard let id = update["toolCallId"]?.stringValue else { return nil }
        var content: String?
        if let blocks = update["content"]?.arrayValue {
            let parts = blocks.compactMap { block -> String? in
                switch block["type"]?.stringValue {
                case "content": return contentText(block["content"])
                case "diff": return block["path"]?.stringValue.map { "Edited \($0)" }
                default: return nil
                }
            }
            content = parts.joined(separator: "\n")
        }
        return ACPToolCallFields(
            toolCallID: id,
            title: update["title"]?.stringValue,
            kind: update["kind"]?.stringValue.flatMap(ACPToolKind.init(rawValue:)),
            status: update["status"]?.stringValue.flatMap(ACPToolStatus.init(rawValue:)),
            content: content
        )
    }
}

// MARK: - Permission requests

struct ACPPermissionRequest: Identifiable, Equatable, Sendable {
    enum OptionKind: String, Sendable {
        case allowOnce = "allow_once"
        case allowAlways = "allow_always"
        case rejectOnce = "reject_once"
        case rejectAlways = "reject_always"

        var allows: Bool { self == .allowOnce || self == .allowAlways }
    }

    struct Option: Identifiable, Equatable, Sendable {
        var id: String
        var name: String
        var kind: OptionKind?
    }

    /// The JSON-RPC id to answer.
    var requestID: JSONValue
    var sessionID: String
    var title: String
    var toolKind: ACPToolKind?
    var options: [Option]

    var id: JSONValue { requestID }

    init?(requestID: JSONValue, params: JSONValue) {
        guard let sessionID = params["sessionId"]?.stringValue,
              let rawOptions = params["options"]?.arrayValue else { return nil }
        self.requestID = requestID
        self.sessionID = sessionID
        title = params["toolCall"]?["title"]?.stringValue ?? "Use a tool"
        toolKind = params["toolCall"]?["kind"]?.stringValue.flatMap(ACPToolKind.init(rawValue:))
        options = rawOptions.compactMap { option in
            guard let id = option["optionId"]?.stringValue else { return nil }
            return Option(
                id: id,
                name: option["name"]?.stringValue ?? id,
                kind: option["kind"]?.stringValue.flatMap(OptionKind.init(rawValue:))
            )
        }
        guard !options.isEmpty else { return nil }
    }
}

// MARK: - Turn usage

/// Token usage for one prompt turn, as the agent reported it.
struct ACPTurnUsage: Equatable, Sendable {
    var inputTokens: Int?
    var outputTokens: Int?
    var cachedReadTokens: Int?
    var cachedWriteTokens: Int?

    /// Reads `usage` from a `session/prompt` result, falling back to the
    /// vendor `_meta.usage` some agents use.
    init?(promptResult result: JSONValue) {
        guard let usage = result["usage"] ?? result["_meta"]?["usage"], usage.objectValue != nil else { return nil }
        inputTokens = usage.int("inputTokens", "input_tokens")
        outputTokens = usage.int("outputTokens", "output_tokens")
        cachedReadTokens = usage.int("cachedReadTokens", "cached_read_tokens")
        cachedWriteTokens = usage.int("cachedWriteTokens", "cached_write_tokens")
        if inputTokens == nil, outputTokens == nil, cachedReadTokens == nil { return nil }
    }

    init(inputTokens: Int?, outputTokens: Int?, cachedReadTokens: Int?, cachedWriteTokens: Int?) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedReadTokens = cachedReadTokens
        self.cachedWriteTokens = cachedWriteTokens
    }
}

/// Turn usage in one shape across agents. Agents disagree on whether
/// `inputTokens` already counts cache reads (Grok's does; Claude's and Codex's
/// do not), so comparing raw numbers across agents would be misleading.
struct NormalizedTurnUsage: Equatable, Sendable {
    var uncachedInputTokens: Int
    var cacheReadTokens: Int
    var cacheWriteTokens: Int
    var outputTokens: Int

    var promptTokens: Int { uncachedInputTokens + cacheReadTokens + cacheWriteTokens }

    /// Share of the prompt served from cache, or nil when the agent reports no cache data.
    var cacheHitRate: Double? {
        guard promptTokens > 0 else { return nil }
        return Double(cacheReadTokens) / Double(promptTokens)
    }

    init(uncachedInputTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int, outputTokens: Int) {
        self.uncachedInputTokens = uncachedInputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.outputTokens = outputTokens
    }

    init?(_ usage: ACPTurnUsage, inputIncludesCacheReads: Bool) {
        guard let input = usage.inputTokens else { return nil }
        let read = usage.cachedReadTokens ?? 0
        let write = usage.cachedWriteTokens ?? 0
        uncachedInputTokens = inputIncludesCacheReads ? max(input - read, 0) : input
        cacheReadTokens = read
        cacheWriteTokens = write
        outputTokens = usage.outputTokens ?? 0
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        NormalizedTurnUsage(
            uncachedInputTokens: lhs.uncachedInputTokens + rhs.uncachedInputTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            cacheWriteTokens: lhs.cacheWriteTokens + rhs.cacheWriteTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens
        )
    }
}
