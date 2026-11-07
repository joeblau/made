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
        static let steer = "_session/steering"
        static let cancelRequest = "$/cancel_request"
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

    /// Injects text into the running turn. `promptRequired` asks the agent to
    /// report an idle session instead of starting a new turn from the text.
    static func steerParams(sessionID: String, text: String) -> JSONValue {
        [
            "sessionId": .string(sessionID),
            "prompt": [["type": "text", "text": .string(text)]],
            "_meta": ["steering": ["idleBehavior": "promptRequired"]],
        ]
    }
}

/// The agent's answer to `_session/steering`. Anything unrecognized is a failure.
enum ACPSteerOutcome: Equatable, Sendable {
    case injected
    case promptRequired
    case failed(String)

    init(_ result: JSONValue) {
        switch result["outcome"]?.stringValue {
        case "injected": self = .injected
        case "promptRequired": self = .promptRequired
        // The agent's own text is never echoed: this message reaches the composer.
        case .some: self = .failed("The agent returned an unrecognized steering outcome.")
        case nil: self = .failed("The agent did not report a steering outcome.")
        }
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
    /// `_meta.steering.supported == true` in the initialize result.
    var supportsSteering = false

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
        supportsSteering = result["_meta"]?["steering"]?["supported"]?.boolValue == true
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

/// A file a tool call touches. `path` is bounded to 4 KiB.
struct ACPToolLocation: Equatable, Sendable {
    var path: String
    var line: Int?
}

/// One structured `content` block of a tool call.
enum ACPToolContent: Equatable, Sendable {
    case text(String)
    case diff(path: String, oldText: String?, newText: String)
    case terminal(id: String)
    case other(type: String)
}

/// Bounded untrusted JSON. Size is measured by an early-exit tree walk (no
/// serialization). Over the cap, `value` is nil and `prefixText` keeps a
/// bounded text rendering (≤ 256 KiB) with the dropped size in `truncatedBytes`.
struct ACPBoundedJSON: Equatable, Sendable {
    static let maximumBytes = 256 * 1_024

    var value: JSONValue?
    var prefixText: String?
    var truncatedBytes: Int?

    init(_ value: JSONValue?) {
        guard let value, value.estimatedByteCount(limit: Self.maximumBytes) > Self.maximumBytes else {
            self.value = value
            prefixText = nil
            truncatedBytes = nil
            return
        }
        let prefix = value.boundedRendering(maximumBytes: Self.maximumBytes)
        self.value = nil
        prefixText = prefix
        // An estimate: the walk measures unescaped text.
        truncatedBytes = max(value.estimatedByteCount() - prefix.utf8.count, 1)
    }

    /// Bytes this payload retains, for the step-detail budget.
    var retainedBytes: Int {
        prefixText?.utf8.count ?? value?.estimatedByteCount() ?? 0
    }
}

/// Retention bounds for untrusted agent input, applied before anything is kept.
enum ACPBounds {
    static let pathBytes = 4_096
    static let nameBytes = 256
    static let titleBytes = 4_096
    static let subjectCharacters = 512
    static let errorSummaryCharacters = 200
    static let thoughtBytes = 256 * 1_024
    static let terminalOutputBytes = 256 * 1_024
    static let contentBytes = 512 * 1_024
    static let blockTextBytes = 512 * 1_024
    static let blocks = 64
    static let locations = 64
    static let options = 16
    static let planEntries = 256
}

struct ACPToolCallFields: Equatable, Sendable {
    var toolCallID: String
    var title: String?
    var kind: ACPToolKind?
    /// The agent's `kind` string, kept even when it is not a known ACPToolKind.
    var rawKind: String? = nil
    var status: ACPToolStatus?
    /// Text and diff summaries from `content`; nil when the update carried none.
    /// Kept for compatibility; capped at 512 KiB.
    var content: String?
    /// Structured `content` blocks: ≤ 64 blocks, aggregate text ≤ 512 KiB.
    var blocks: [ACPToolContent]? = nil
    /// ≤ 64 locations.
    var locations: [ACPToolLocation]? = nil
    /// `update.name ?? _meta.claudeCode.toolName ?? _meta["x.ai/tool"].name` (≤ 256 B).
    var toolName: String? = nil
    /// `_meta.claudeCode.nonExecutionKind` (interrupted, cancelled, rejected…).
    var nonExecutionKind: String? = nil
    /// Codex `_meta.terminal_output_delta.data`, bounded; appended by the transcript.
    var terminalOutputDelta: String? = nil
    var exitCode: Int? = nil
    var rawInput: ACPBoundedJSON? = nil
    var rawOutput: ACPBoundedJSON? = nil
    /// Paths of diff blocks cut to fit the block-text budget; their line
    /// counts would be wrong, so the transcript reports none for them.
    var truncatedDiffPaths: [String] = []
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
    /// True when `state` arrived as an object (the RFD shape) rather than a bare string.
    var hasStateObject = false
    var canCancel: Bool? = nil
}

enum ACPUpdate: Equatable, Sendable {
    case agentMessage(String)
    /// `messageID` changes when the agent starts a new reasoning block.
    case agentThought(text: String, messageID: String?)
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
        // Session IDs key transcript lists, so an oversized one is malformed (§1.4).
        guard let sessionID = boundedID(params["sessionId"]),
              let update = params["update"],
              let kind = update["sessionUpdate"]?.stringValue else { return nil }
        let parsed: ACPUpdate
        switch kind {
        case "config_option_update":
            parsed = .modelConfiguration(ACPModelState(update))
        case "current_model_update":
            guard let id = boundedID(update["currentModelId"]) else { return nil }
            parsed = .currentModel(id)
        case "agent_message_chunk":
            parsed = .agentMessage(contentText(update["content"]) ?? "")
        case "agent_thought_chunk":
            parsed = .agentThought(
                text: contentText(update["content"]) ?? "",
                messageID: boundedID(update["messageId"])
            )
        case "user_message_chunk":
            parsed = .userMessage(contentText(update["content"]) ?? "")
        case "tool_call":
            guard let fields = toolCallFields(update) else { return nil }
            parsed = .toolCall(fields)
        case "tool_call_update":
            guard let fields = toolCallFields(update) else { return nil }
            parsed = .toolCallUpdate(fields)
        case "plan":
            parsed = .plan((update["entries"]?.arrayValue ?? []).prefix(ACPBounds.planEntries).compactMap { entry in
                guard let content = entry["content"]?.stringValue else { return nil }
                return ACPPlanEntry(
                    content: content.utf8Prefix(ACPBounds.pathBytes),
                    status: entry["status"]?.stringValue?.boundedNonEmpty(ACPBounds.nameBytes) ?? "pending"
                )
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
            guard let child = boundedID(update["sessionId"]) else { return nil }
            parsed = .subagent(subagentState(update, childSessionID: child))
        default:
            parsed = .other(kind: kind)
        }
        return ACPSessionNotification(sessionID: sessionID, update: parsed)
    }

    private static func contentText(_ content: JSONValue?) -> String? {
        guard let content, content["type"]?.stringValue == "text" else { return nil }
        return content["text"]?.stringValue
    }

    /// A string ID within the name bound; anything longer is malformed, not truncated.
    static func boundedID(_ value: JSONValue?) -> String? {
        guard let id = value?.stringValue, !id.isEmpty, id.utf8.count <= ACPBounds.nameBytes else { return nil }
        return id
    }

    /// The first non-empty string among `values`, bounded to `maximumBytes`.
    private static func firstText(_ values: JSONValue?..., maximumBytes: Int) -> String? {
        values.lazy.compactMap { $0?.stringValue?.boundedNonEmpty(maximumBytes) }.first
    }

    private static func subagentState(_ update: JSONValue, childSessionID: String) -> ACPSubagentState {
        let state = update["state"]
        let error = state?["error"]
        let capabilities = update["capabilities"]
        return ACPSubagentState(
            childSessionID: childSessionID,
            title: update["title"]?.stringValue?.boundedNonEmpty(ACPBounds.nameBytes),
            detail: update["description"]?.stringValue?.boundedNonEmpty(ACPBounds.pathBytes),
            state: (state?["state"]?.stringValue ?? state?.stringValue)?.boundedNonEmpty(ACPBounds.nameBytes),
            stopReason: state?["stopReason"]?.stringValue?.boundedNonEmpty(ACPBounds.nameBytes),
            error: firstText(error?["message"], error, maximumBytes: ACPBounds.pathBytes),
            hasStateObject: state?.objectValue != nil,
            canCancel: capabilities?.objectValue == nil ? nil : (capabilities?["cancel"] ?? .null) != .null
        )
    }

    /// Parses `locations`: at most 64, each path ≤ 4 KiB (longer paths are dropped, not cut).
    static func toolLocations(_ value: JSONValue?) -> [ACPToolLocation]? {
        guard let entries = value?.arrayValue else { return nil }
        var locations: [ACPToolLocation] = []
        for entry in entries {
            guard locations.count < ACPBounds.locations else { break }
            guard let path = entry["path"]?.stringValue, !path.isEmpty,
                  path.utf8.count <= ACPBounds.pathBytes else { continue }
            locations.append(ACPToolLocation(path: path, line: entry["line"]?.intValue))
        }
        return locations
    }

    /// Parses `content` blocks: at most 64, with ≤ 512 KiB of text in total.
    private static func toolContent(_ entries: [JSONValue]) -> (blocks: [ACPToolContent], truncatedDiffPaths: [String]) {
        var blocks: [ACPToolContent] = []
        var truncated: [String] = []
        var budget = ACPBounds.blockTextBytes
        for entry in entries {
            guard blocks.count < ACPBounds.blocks else { break }
            switch entry["type"]?.stringValue {
            case "content":
                let inner = entry["content"]
                guard inner?["type"]?.stringValue == "text", let text = inner?["text"]?.stringValue else {
                    blocks.append(.other(type: firstText(inner?["type"], maximumBytes: ACPBounds.nameBytes) ?? "content"))
                    continue
                }
                let kept = text.utf8Prefix(budget)
                if kept.isEmpty, !text.isEmpty { continue }
                budget -= kept.utf8.count
                blocks.append(.text(kept))
            case "diff":
                guard let path = entry["path"]?.stringValue, !path.isEmpty,
                      path.utf8.count <= ACPBounds.pathBytes else { continue }
                let oldText = entry["oldText"]?.stringValue
                let newText = entry["newText"]?.stringValue ?? ""
                let size = (oldText?.utf8.count ?? 0) + newText.utf8.count
                if size <= budget {
                    budget -= size
                    blocks.append(.diff(path: path, oldText: oldText, newText: newText))
                } else {
                    let keptOld = oldText?.utf8Prefix(budget / 2)
                    let keptNew = newText.utf8Prefix(budget - (keptOld?.utf8.count ?? 0))
                    budget -= (keptOld?.utf8.count ?? 0) + keptNew.utf8.count
                    truncated.append(path)
                    blocks.append(.diff(path: path, oldText: keptOld, newText: keptNew))
                }
            case "terminal":
                guard let id = boundedID(entry["terminalId"]) else { continue }
                blocks.append(.terminal(id: id))
            case let type?:
                blocks.append(.other(type: type.utf8Prefix(ACPBounds.nameBytes)))
            case nil:
                continue
            }
        }
        return (blocks, truncated)
    }

    /// The compatibility summary of `content`: text blocks and "Edited <path>" lines.
    private static func contentSummary(_ blocks: [ACPToolContent]) -> String {
        blocks.compactMap { block -> String? in
            switch block {
            case .text(let text): text
            case .diff(let path, _, _): "Edited \(path)"
            case .terminal, .other: nil
            }
        }
        .joined(separator: "\n")
        .utf8Prefix(ACPBounds.contentBytes)
    }

    private static func boundedJSON(_ value: JSONValue?) -> ACPBoundedJSON? {
        guard let value, value != .null else { return nil }
        return ACPBoundedJSON(value)
    }

    private static func toolCallFields(_ update: JSONValue) -> ACPToolCallFields? {
        guard let id = boundedID(update["toolCallId"]) else { return nil }
        let meta = update["_meta"]
        let claude = meta?["claudeCode"]
        let rawStatus = update["status"]?.stringValue
        // ACP v2's `cancelled` status reads as a stopped failure, like Claude's nonExecutionKind.
        let isCancelledStatus = rawStatus == "cancelled"
        var fields = ACPToolCallFields(
            toolCallID: id,
            title: update["title"]?.stringValue?.utf8Prefix(ACPBounds.titleBytes),
            kind: nil,
            rawKind: firstText(update["kind"], maximumBytes: ACPBounds.nameBytes),
            status: rawStatus.flatMap(ACPToolStatus.init(rawValue:)) ?? (isCancelledStatus ? .failed : nil),
            content: nil
        )
        fields.kind = fields.rawKind.flatMap(ACPToolKind.init(rawValue:))
        if let entries = update["content"]?.arrayValue {
            let parsed = toolContent(entries)
            fields.blocks = parsed.blocks
            fields.truncatedDiffPaths = parsed.truncatedDiffPaths
            fields.content = contentSummary(parsed.blocks)
        }
        fields.locations = toolLocations(update["locations"])
        fields.toolName = firstText(
            update["name"], claude?["toolName"], meta?["x.ai/tool"]?["name"], maximumBytes: ACPBounds.nameBytes
        )
        fields.nonExecutionKind = firstText(claude?["nonExecutionKind"], maximumBytes: ACPBounds.nameBytes)
            ?? (isCancelledStatus ? "cancelled" : nil)
        // Terminal output keeps its newest bytes, so an oversized delta keeps its tail.
        fields.terminalOutputDelta = meta?["terminal_output_delta"]?["data"]?.stringValue
            .flatMap { $0.isEmpty ? nil : $0.utf8SuffixAtLineBoundary(ACPBounds.terminalOutputBytes) }
        let rawOutput = update["rawOutput"]
        fields.exitCode = meta?["terminal_exit"]?["exit_code"]?.intValue
            ?? rawOutput?.int("exit_code", "exitCode")
        fields.rawInput = boundedJSON(update["rawInput"])
        fields.rawOutput = boundedJSON(rawOutput)
        return fields
    }

    /// The request a `$/cancel_request` notification withdraws.
    static func cancelledRequestID(_ params: JSONValue) -> JSONValue? {
        requestID(params["requestId"] ?? params["id"])
    }

    /// A JSON-RPC request id Cockpit will answer: a string (≤ 256 B) or a number.
    static func requestID(_ value: JSONValue?) -> JSONValue? {
        switch value {
        case .string(let id)? where id.utf8.count <= ACPBounds.nameBytes: value
        case .number(let id)? where id.isFinite: value
        default: nil
        }
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
    /// Bounded to 16 options; `requestID` is only a string or number.
    var options: [Option]
    var toolCallID: String?
    var rawInput: ACPBoundedJSON?
    var locations: [ACPToolLocation] = []

    var id: JSONValue { requestID }

    init?(requestID: JSONValue, params: JSONValue) {
        guard let requestID = ACP.requestID(requestID),
              let sessionID = ACP.boundedID(params["sessionId"]),
              let rawOptions = params["options"]?.arrayValue else { return nil }
        self.requestID = requestID
        self.sessionID = sessionID
        let toolCall = params["toolCall"]
        title = toolCall?["title"]?.stringValue?.boundedNonEmpty(ACPBounds.titleBytes) ?? "Use a tool"
        toolKind = toolCall?["kind"]?.stringValue.flatMap(ACPToolKind.init(rawValue:))
        toolCallID = ACP.boundedID(toolCall?["toolCallId"])
        if let input = toolCall?["rawInput"], input != .null { rawInput = ACPBoundedJSON(input) }
        locations = ACP.toolLocations(toolCall?["locations"]) ?? []
        options = []
        for option in rawOptions {
            guard options.count < ACPBounds.options else { break }
            guard let id = ACP.boundedID(option["optionId"]) else { continue }
            options.append(Option(
                id: id,
                name: option["name"]?.stringValue?.boundedNonEmpty(ACPBounds.nameBytes) ?? id,
                kind: option["kind"]?.stringValue.flatMap(OptionKind.init(rawValue:))
            ))
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

// MARK: - Tool payload interpretation

extension AgentChatItem.ToolCall {
    /// The input field a call acts on — command, path, pattern, or URL —
    /// across agents' input shapes (Claude `file_path`, Codex `cmd` or an
    /// argv array), ≤ 512 characters.
    static func subject(fromInput input: JSONValue?) -> String? {
        guard let input else { return nil }
        for field in ["command", "cmd", "file_path", "path", "notebook_path", "pattern", "url", "query"] {
            let text: String?
            switch input[field] {
            case .string(let value)?:
                text = value
            case .array(let parts)?:
                text = parts.prefix(64).compactMap { $0.stringValue?.utf8Prefix(ACPBounds.pathBytes) }
                    .joined(separator: " ")
            default:
                text = nil
            }
            let trimmed = text.map { String($0.prefix(4 * ACPBounds.subjectCharacters)).trimmingCharacters(in: .whitespacesAndNewlines) }
            if let trimmed, !trimmed.isEmpty { return String(trimmed.prefix(ACPBounds.subjectCharacters)) }
        }
        return nil
    }
}

extension AgentTranscript {
    /// Claude stamps calls it never ran: `interrupted`/`cancelled` were
    /// stopped (gray, not failed); `user-rejected`, `permission-rule`, and
    /// `automode-*` were refused.
    static func outcome(status: ACPToolStatus?, nonExecutionKind: String?) -> AgentChatItem.ToolCall.Outcome? {
        if let kind = nonExecutionKind?.lowercased() {
            if ["interrupted", "cancelled", "canceled"].contains(kind) { return .cancelled }
            if kind.contains("reject") || kind.hasPrefix("permission") || kind.hasPrefix("automode") { return .rejected }
        }
        switch status {
        case .completed?: return .completed
        case .failed?: return .failed
        case .pending?, .inProgress?, nil: return nil
        }
    }

    /// The first meaningful line of `text`, redacted, then clipped to ≤ 200
    /// characters (clipping first could leave a token head no rule matches):
    /// fences and Claude's `<tool_use_error>` wrapper are skipped.
    static func summaryLine(_ text: String) -> String? {
        for line in text.prefix(16_384).split(whereSeparator: \.isNewline) {
            let cleaned = line
                .replacingOccurrences(of: "<tool_use_error>", with: "")
                .replacingOccurrences(of: "</tool_use_error>", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty, !cleaned.hasPrefix("```") else { continue }
            return String(redactInline(String(cleaned.prefix(4_096))).prefix(ACPBounds.errorSummaryCharacters))
        }
        return nil
    }
}
