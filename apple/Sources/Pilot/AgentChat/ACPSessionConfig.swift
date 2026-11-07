import Foundation

/// One select-type session configuration option an agent advertises
/// (`configOptions`), or a legacy `models` / `modes` list adapted to the same
/// shape. Every field is bounded and sanitized before it is kept; Cockpit
/// never invents option IDs or values.
struct ACPConfigOption: Equatable, Sendable {
    enum Category: Equatable, Sendable {
        case model, thoughtLevel, mode, modelConfig
        case other(String)

        init(_ raw: String?, optionID: String) {
            switch raw {
            case "model"?: self = .model
            case "thought_level"?: self = .thoughtLevel
            case "mode"?: self = .mode
            case "model_config"?: self = .modelConfig
            case let raw?: self = .other(raw.utf8Prefix(ACPConfigBounds.idBytes))
            // Adapters that predate categories still name the model option "model".
            case nil: self = optionID == "model" ? .model : .other("")
            }
        }
    }

    struct Choice: Equatable, Sendable {
        var id: String
        var name: String
        var detail: String?
        var group: String?
    }

    /// Reserved IDs for the legacy APIs; agent options with these IDs are dropped.
    static let legacyModelID = "_cockpit/legacy-model"
    static let legacyModeID = "_cockpit/legacy-mode"

    var id: String
    var name: String
    var detail: String?
    var category: Category
    var currentID: String
    var choices: [Choice]

    init(id: String, name: String, detail: String? = nil, category: Category, currentID: String, choices: [Choice]) {
        self.id = id
        self.name = name
        self.detail = detail
        self.category = category
        self.currentID = currentID
        self.choices = choices
    }

    var isLegacy: Bool { id == Self.legacyModelID || id == Self.legacyModeID }
    var currentChoice: Choice? { choice(currentID) }
    /// The current choice's agent-given name, or its sanitized ID when it is not listed.
    var currentName: String { currentChoice?.name ?? ACPConfigText.label(forID: currentID) }
    /// The current choice's name, normalized for display.
    var currentDisplayName: String { currentChoice.map(displayName(of:)) ?? ACPConfigText.label(forID: currentID) }
    /// The current choice, or one synthesized from an unlisted current ID, so
    /// an unlisted unrestricted mode is still classified as unrestricted.
    var currentOrUnlistedChoice: Choice {
        currentChoice ?? Choice(id: currentID, name: ACPConfigText.label(forID: currentID))
    }

    func choice(_ id: String) -> Choice? { choices.first { $0.id == id } }

    /// The request that selects `value`, or nil when the option does not
    /// advertise it (or advertises no choices at all).
    func request(sessionID: String, value: String) -> (method: String, params: JSONValue)? {
        guard choice(value) != nil else { return nil }
        let session = JSONValue.string(sessionID)
        switch id {
        case Self.legacyModelID: return (ACP.Method.setModel, ["sessionId": session, "modelId": .string(value)])
        case Self.legacyModeID: return (ACP.Method.setMode, ["sessionId": session, "modeId": .string(value)])
        default: return (ACP.Method.setConfigOption, ["sessionId": session, "configId": .string(id), "value": .string(value)])
        }
    }

    /// Parses one `configOptions` entry; nil unless it is a bounded select option.
    init?(option json: JSONValue) {
        guard json["type"] == nil || json["type"]?.stringValue == "select",
              let id = ACPConfigText.id(json["id"]), id != Self.legacyModelID, id != Self.legacyModeID,
              let current = ACPConfigText.id(json["currentValue"]) else { return nil }
        self.id = id
        name = ACPConfigText.name(json["name"]) ?? ACPConfigText.label(forID: id)
        detail = ACPConfigText.detail(json["description"])
        category = Category(json["category"]?.stringValue, optionID: id)
        currentID = current
        choices = ACPConfigText.choices(json["options"]?.arrayValue ?? [])
    }

    /// Adapts `models` (`modelId`) or `modes` (`id`) lists.
    init?(legacy json: JSONValue?, isModel: Bool) {
        guard let json, let current = ACPConfigText.id(json[isModel ? "currentModelId" : "currentModeId"]) else { return nil }
        id = isModel ? Self.legacyModelID : Self.legacyModeID
        name = isModel ? "Model" : "Mode"
        category = isModel ? .model : .mode
        currentID = current
        var seen = Set<String>()
        choices = []
        for entry in (json[isModel ? "availableModels" : "availableModes"]?.arrayValue ?? []).prefix(ACPConfigBounds.scannedEntries) {
            guard choices.count < ACPConfigBounds.choices,
                  let value = ACPConfigText.id(entry[isModel ? "modelId" : "id"]), seen.insert(value).inserted else { continue }
            choices.append(Choice(id: value, name: ACPConfigText.name(entry["name"]) ?? ACPConfigText.label(forID: value),
                                  detail: ACPConfigText.detail(entry["description"])))
        }
    }
}

/// Retention bounds for advertised session configuration.
enum ACPConfigBounds {
    static let options = 32
    static let choices = 500
    static let idBytes = 256
    static let nameBytes = 512
    static let detailBytes = 2_048
    /// Entries examined (including group entries) before parsing stops.
    static let scannedEntries = 2_000
}

/// The session's advertised configuration: select-type `configOptions` in
/// agent order, plus the legacy `models` and `modes` lists when advertised.
struct ACPSessionConfig: Equatable, Sendable {
    /// The parts of a session result or `config_option_update`. A part that is
    /// absent (nil) leaves the current value alone when applied.
    struct Patch: Equatable, Sendable {
        var options: [ACPConfigOption]?
        var legacyModels: ACPConfigOption?
        var legacyModes: ACPConfigOption?

        var isEmpty: Bool { options == nil && legacyModels == nil && legacyModes == nil }
        /// The model option this patch carries, for subagent model labels.
        var model: ACPConfigOption? { options.flatMap(ACPSessionConfig.modelOption(in:)) ?? legacyModels }

        init(options: [ACPConfigOption]? = nil, legacyModels: ACPConfigOption? = nil, legacyModes: ACPConfigOption? = nil) {
            self.options = options
            self.legacyModels = legacyModels
            self.legacyModes = legacyModes
        }

        init(_ result: JSONValue) {
            if let entries = result["configOptions"]?.arrayValue {
                var parsed: [ACPConfigOption] = []
                var seen = Set<String>()
                for entry in entries.prefix(ACPConfigBounds.scannedEntries) {
                    guard parsed.count < ACPConfigBounds.options, let option = ACPConfigOption(option: entry),
                          seen.insert(option.id).inserted else { continue }
                    parsed.append(option)
                }
                options = parsed
            }
            legacyModels = ACPConfigOption(legacy: result["models"], isModel: true)
                // Grok's older adapter reports only the current model in `_meta`.
                ?? ACPConfigOption(legacy: result["_meta"]?["modelState"], isModel: true)
            legacyModes = ACPConfigOption(legacy: result["modes"], isModel: false)
        }
    }

    var options: [ACPConfigOption]
    var legacyModels: ACPConfigOption?
    var legacyModes: ACPConfigOption?

    init(options: [ACPConfigOption] = [], legacyModels: ACPConfigOption? = nil, legacyModes: ACPConfigOption? = nil) {
        self.options = options
        self.legacyModels = legacyModels
        self.legacyModes = legacyModes
    }

    /// From a `session/new`, `session/load`, or `set_config_option` result;
    /// nil when it carries no configuration.
    init?(_ result: JSONValue) {
        let patch = Patch(result)
        guard !patch.isEmpty else { return nil }
        self.init(options: patch.options ?? [], legacyModels: patch.legacyModels, legacyModes: patch.legacyModes)
    }

    func applying(_ patch: Patch) -> ACPSessionConfig {
        ACPSessionConfig(options: patch.options ?? options,
                         legacyModels: patch.legacyModels ?? legacyModels,
                         legacyModes: patch.legacyModes ?? legacyModes)
    }

    static func modelOption(in options: [ACPConfigOption]) -> ACPConfigOption? {
        options.first { $0.category == .model } ?? options.first { $0.id == "model" }
    }

    var model: ACPConfigOption? { Self.modelOption(in: options) ?? legacyModels }
    var thoughtLevel: ACPConfigOption? { options.first { $0.category == .thoughtLevel } }
    var mode: ACPConfigOption? { options.first { $0.category == .mode } ?? legacyModes }
    /// A `model_config` on/off switch named "fast" (Claude `fast`, Codex `fast-mode`).
    var fast: ACPConfigOption? {
        options.first { option in
            option.category == .modelConfig
                && (option.id.range(of: "fast", options: .caseInsensitive) != nil
                    || option.name.range(of: "fast", options: .caseInsensitive) != nil)
                && option.choice("on") != nil && option.choice("off") != nil
        }
    }

    /// Every option the session can change, including the adapted legacy lists.
    var allOptions: [ACPConfigOption] {
        var all = options
        if let legacyModels, Self.modelOption(in: options) == nil { all.append(legacyModels) }
        if let legacyModes, !options.contains(where: { $0.category == .mode }) { all.append(legacyModes) }
        return all
    }

    func option(id: String) -> ACPConfigOption? {
        if id == ACPConfigOption.legacyModelID { return legacyModels }
        if id == ACPConfigOption.legacyModeID { return legacyModes }
        return options.first { $0.id == id }
    }

    func request(sessionID: String, optionID: String, value: String) -> (method: String, params: JSONValue)? {
        option(id: optionID)?.request(sessionID: sessionID, value: value)
    }

    /// The configuration with `optionID`'s current value set (an acknowledged
    /// legacy change or a `current_*_update`); unchanged if the option is absent.
    func settingCurrent(optionID: String, to value: String) -> ACPSessionConfig {
        var copy = self
        if optionID == ACPConfigOption.legacyModelID {
            copy.legacyModels?.currentID = value
        } else if optionID == ACPConfigOption.legacyModeID {
            copy.legacyModes?.currentID = value
        } else if let index = copy.options.firstIndex(where: { $0.id == optionID }) {
            copy.options[index].currentID = value
        }
        return copy
    }
}

// MARK: - Display normalization and mode safety

extension ACPConfigOption {
    /// A choice's name for display: a redundant option-name prefix removed
    /// ("Thinking Low" under "Thinking" → "Low") and `xhigh` spelled out as
    /// "Extra High". Never invents a value: other names pass through.
    func displayName(of choice: Choice) -> String {
        Self.displayName(choiceID: choice.id, name: choice.name, optionName: name)
    }

    static func displayName(choiceID: String, name: String, optionName: String) -> String {
        var result = name
        let prefix = optionName.trimmingCharacters(in: .whitespaces)
        if !prefix.isEmpty, let range = result.range(of: prefix, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) {
            let rest = result[range.upperBound...]
            let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":-–—"))
            if let first = rest.unicodeScalars.first, separators.contains(first) {
                let trimmed = rest.trimmingCharacters(in: separators)
                if !trimmed.isEmpty { result = trimmed }
            }
        }
        let compact = result.lowercased().filter { $0.isLetter }
        if choiceID.lowercased() == "xhigh", compact == "xhigh" { return "Extra High" }
        return result
    }

    /// A mode that lets the agent act without asking (Claude
    /// `bypassPermissions`, Codex `agent-full-access`, Kimi `yolo`).
    static func isUnrestrictedMode(_ choice: Choice) -> Bool {
        let exact: Set<String> = ["bypasspermissions", "yolo", "full-access", "agent-full-access"]
        if exact.contains(choice.id.lowercased()) { return true }
        let patterns = ["bypass", "full access", "full-access", "yolo", "danger"]
        return [choice.id, choice.name].contains { text in
            patterns.contains { text.range(of: $0, options: .caseInsensitive) != nil }
        }
    }
}

// MARK: - Bounded text

/// Bounds and sanitizes advertised strings before they are kept.
enum ACPConfigText {
    /// A non-empty string ID within the ID bound; longer IDs are malformed, not truncated.
    static func id(_ value: JSONValue?) -> String? {
        guard let id = value?.stringValue, !id.isEmpty, id.utf8.count <= ACPConfigBounds.idBytes else { return nil }
        return id
    }

    static func name(_ value: JSONValue?) -> String? { text(value, maximumBytes: ACPConfigBounds.nameBytes) }

    /// A display name for an unnamed ID: sanitized like a name, never the raw
    /// ID (which stays as-is only in requests). An ID with nothing printable
    /// shows as "Unnamed".
    static func label(forID id: String) -> String { name(.string(id)) ?? "Unnamed" }
    static func detail(_ value: JSONValue?) -> String? { text(value, maximumBytes: ACPConfigBounds.detailBytes) }

    /// One line: control and format characters (bidi overrides, isolates,
    /// zero-width) removed, whitespace runs folded, at most `maximumBytes`.
    static func text(_ value: JSONValue?, maximumBytes: Int) -> String? {
        guard let raw = value?.stringValue, !raw.isEmpty else { return nil }
        var output = String.UnicodeScalarView()
        var pendingSpace = false
        // The input is cut before it is scanned, so a huge string costs no more than the bound.
        for scalar in raw.utf8Prefix(maximumBytes * 2).unicodeScalars {
            switch scalar.properties.generalCategory {
            // Cf covers every bidi embedding, override, isolate, and mark.
            case .format:
                continue
            case .control, .lineSeparator, .paragraphSeparator, .spaceSeparator:
                pendingSpace = !output.isEmpty
            default:
                if pendingSpace { output.append(" ") }
                pendingSpace = false
                output.append(scalar)
            }
        }
        let result = String(output).utf8Prefix(maximumBytes)
        return result.isEmpty ? nil : result
    }

    /// Flattens plain and grouped (`{name, options:[…]}`) entries, keeping
    /// the first of each value and at most 500 choices.
    static func choices(_ entries: [JSONValue]) -> [ACPConfigOption.Choice] {
        var choices: [ACPConfigOption.Choice] = []
        var seen = Set<String>()
        var scanned = 0
        for entry in entries {
            let inner = entry["options"]?.arrayValue
            let group = inner == nil ? nil : name(entry["name"]) ?? name(entry["group"])
            for item in inner ?? [entry] {
                scanned += 1
                guard scanned <= ACPConfigBounds.scannedEntries, choices.count < ACPConfigBounds.choices else { return choices }
                guard let value = id(item["value"]), seen.insert(value).inserted else { continue }
                choices.append(.init(id: value, name: name(item["name"]) ?? label(forID: value), detail: detail(item["description"]),
                                     group: group))
            }
        }
        return choices
    }
}
