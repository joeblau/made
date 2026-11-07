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
    verbForTool(tool, input: input, includeExactInput: true)
}

/// `includeExactInput: false` leaves `exactInput` nil and skips redacting and
/// rendering the whole input; for callers that only show the label, such as
/// the live status line on every projection.
func verbForTool(_ tool: AgentChatItem.ToolCall, input: JSONValue?, includeExactInput: Bool) -> AgentToolVerb {
    let category = AgentToolResolver.category(of: tool, input: input)
    let fields = AgentToolFields(tool: tool, input: input, category: category)
    return AgentToolResolver.verb(
        for: category, fields: fields, tool: tool, input: input, includeExactInput: includeExactInput
    )
}

/// "Thought for 12s" when both times are known, otherwise "Thought". While
/// the thought is open, `live` reads "Thinking" ("Thinking for 5s" once a
/// start time is known).
func verbForThought(_ thought: AgentChatItem.Thought, now: Date) -> AgentToolVerb {
    var live = "Thinking"
    if thought.endedAt == nil, let startedAt = thought.startedAt, now.timeIntervalSince(startedAt) >= 1 {
        live = "Thinking for \(AgentActivityFormat.duration(now.timeIntervalSince(startedAt)))"
    }
    var settled = "Thought"
    if let startedAt = thought.startedAt, let endedAt = thought.endedAt {
        settled = "Thought for \(AgentActivityFormat.duration(max(1, endedAt.timeIntervalSince(startedAt))))"
    }
    return AgentToolVerb(glyph: .think, live: live, settled: settled, detail: nil, exactInput: nil)
}

/// The verb for a `.tool` or `.thought` item; nil for other content.
func verbForItem(_ item: AgentChatItem, input: JSONValue?, now: Date) -> AgentToolVerb? {
    switch item.content {
    case .tool(let tool): verbForTool(tool, input: input)
    case .thought(let thought): verbForThought(thought, now: now)
    default: nil
    }
}

extension AgentToolVerb {
    /// The glyph alone, without building or redacting labels; cheap enough to
    /// classify every step of a large group.
    static func glyph(for tool: AgentChatItem.ToolCall, input: JSONValue?) -> Glyph {
        AgentToolResolver.category(of: tool, input: input).glyph
    }
}

// MARK: - Resolution

/// What a tool call does, before any label is built.
enum AgentToolCategory: Equatable, Sendable {
    case shell, read, search, edit, create, delete, move, fetch, web, plan, agent, mcp, skill, compact, switchMode
    case think, other

    var glyph: AgentToolVerb.Glyph {
        switch self {
        case .shell: .shell
        case .read: .read
        case .search: .search
        case .edit: .edit
        case .create: .create
        case .delete: .delete
        case .move: .move
        case .fetch: .fetch
        case .web: .web
        case .plan: .plan
        case .agent: .agent
        case .mcp: .mcp
        case .think: .think
        case .skill, .compact, .switchMode, .other: .other
        }
    }
}

enum AgentToolResolver {
    /// Known tool names across Claude, Codex, Grok, Kimi, and Gemini,
    /// normalized (lowercased, `_`/`-`/space/`.` removed).
    static let namedCategories: [String: AgentToolCategory] = {
        var table: [String: AgentToolCategory] = [:]
        let groups: [(AgentToolCategory, [String])] = [
            (.shell, ["bash", "shell", "execcommand", "runterminalcommand", "runterminalcmd", "execute", "runshellcommand",
                      "shellcommand", "terminal", "runcommand", "localshell", "exec"]),
            (.read, ["read", "readfile", "view", "readmanyfiles", "notebookread", "viewfile", "openfile"]),
            (.search, ["grep", "glob", "find", "search", "codebasesearch", "findfiles", "grepsearch", "filesearch",
                       "searchfiles", "searchfilecontent", "ls", "listdir", "listdirectory", "listfiles"]),
            (.edit, ["edit", "multiedit", "searchreplace", "hashlineedit", "applypatch", "strreplace", "strreplacefile",
                     "strreplacebasededittool", "strreplaceeditor", "editfile", "notebookedit", "patchfile", "replace",
                     "editnotebook"]),
            (.create, ["write", "writefile", "createfile"]),
            (.delete, ["delete", "deletefile", "removefile", "rm"]),
            (.move, ["move", "movefile", "rename", "renamefile"]),
            (.fetch, ["webfetch", "fetch", "fetchurl", "readurl", "urlfetch"]),
            (.web, ["websearch", "searchweb", "googlesearch", "googlewebsearch"]),
            (.plan, ["todowrite", "updateplan", "settodolist", "writetodos", "updatetodos", "createtodolist",
                     "updatetodolist"]),
            (.agent, ["task", "agent", "dispatchagent", "spawnagent", "delegate", "subagent", "spawnsubagent"]),
            (.skill, ["skill"]),
            (.compact, ["compact", "compactconversation"]),
            (.switchMode, ["exitplanmode", "enterplanmode", "switchmode"]),
            (.think, ["think"]),
        ]
        for (category, names) in groups {
            for name in names { table[name] = category }
        }
        return table
    }()

    static func normalize(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { !"_- .".unicodeScalars.contains($0) })
    }

    static func category(of tool: AgentChatItem.ToolCall, input: JSONValue?) -> AgentToolCategory {
        if let name = tool.toolName?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            if mcpParts(name) != nil { return .mcp }
            if let category = namedCategories[normalize(name)] {
                return refineWrite(category, tool: tool)
            }
        }
        if let input, let category = shapeCategory(input, tool: tool) { return refineWrite(category, tool: tool) }
        if tool.kind != .execute, let category = titleCategory(tool.title) { return category }
        if let kind = tool.kind { return kindCategory(kind) }
        return .other
    }

    /// A write over an existing file is an edit.
    private static func refineWrite(_ category: AgentToolCategory, tool: AgentChatItem.ToolCall) -> AgentToolCategory {
        guard category == .create, let edit = tool.edits.first, !edit.created else { return category }
        return .edit
    }

    static func shapeCategory(_ input: JSONValue, tool: AgentChatItem.ToolCall) -> AgentToolCategory? {
        guard case .object(let object) = input else { return nil }
        func has(_ keys: String...) -> Bool { keys.contains { object[$0] != nil } }
        if has("command", "cmd") { return .shell }
        if has("url", "uri") { return .fetch }
        if object["todos"]?.arrayValue != nil || object["plan"]?.arrayValue != nil { return .plan }
        if has("subagent_type", "subagentType") || (has("description") && has("prompt")) { return .agent }
        if has("skill") { return .skill }
        if has("old_string", "new_string", "oldString", "newString", "edits", "patch", "changes", "diff", "old_str") {
            return .edit
        }
        if has("content", "contents", "file_text") && has("file_path", "path", "filePath") { return .create }
        if has("pattern", "regex", "glob") { return .search }
        if has("query", "q", "search_term") {
            let title = tool.title.lowercased()
            return tool.kind == .fetch || title.contains("web") ? .web : .search
        }
        if has("file_path", "path", "filePath", "paths", "files", "notebook_path", "absolute_path") { return .read }
        return nil
    }

    static func titleCategory(_ title: String) -> AgentToolCategory? {
        let lowered = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return nil }
        if mcpParts(lowered) != nil { return .mcp }
        // Some agents title a step with the bare tool name ("spawn_subagent").
        if lowered.count <= 64, !lowered.contains(where: \.isWhitespace), let named = namedCategories[normalize(lowered)] {
            return named
        }
        let prefixes: [(AgentToolCategory, [String])] = [
            (.compact, ["compact"]),
            (.web, ["web search", "searching the web", "search the web", "search web"]),
            (.fetch, ["fetch ", "fetching "]),
            (.read, ["read ", "reading ", "view "]),
            (.edit, ["edit ", "edit\t", "editing ", "apply patch", "applying patch", "patch "]),
            (.create, ["write ", "writing ", "create ", "creating "]),
            (.search, ["grep ", "search ", "searching ", "find ", "glob ", "list "]),
            (.delete, ["delete ", "deleting ", "remove "]),
            (.move, ["move ", "moving ", "rename "]),
            (.shell, ["run ", "running ", "$ "]),
            (.agent, ["delegat", "task:"]),
        ]
        for (category, candidates) in prefixes where candidates.contains(where: lowered.hasPrefix) {
            return category
        }
        return nil
    }

    static func kindCategory(_ kind: ACPToolKind) -> AgentToolCategory {
        switch kind {
        case .read: .read
        case .edit: .edit
        case .delete: .delete
        case .move: .move
        case .search: .search
        case .execute: .shell
        case .think: .think
        case .fetch: .fetch
        case .switchMode: .switchMode
        case .other: .other
        }
    }

    /// `mcp__server__tool` → (server, tool).
    static func mcpParts(_ name: String) -> (server: String, tool: String)? {
        guard name.lowercased().hasPrefix("mcp__") else { return nil }
        let rest = name.dropFirst(5)
        guard let separator = rest.range(of: "__") else { return nil }
        let server = String(rest[..<separator.lowerBound])
        let tool = String(rest[separator.upperBound...])
        guard !server.isEmpty, !tool.isEmpty else { return nil }
        return (server, tool)
    }

    // MARK: Labels

    // One switch over every category reads best as a table.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func verb(
        for category: AgentToolCategory,
        fields: AgentToolFields,
        tool: AgentChatItem.ToolCall,
        input: JSONValue?,
        includeExactInput: Bool = true
    ) -> AgentToolVerb {
        let exact = includeExactInput ? exactInput(for: category, fields: fields, tool: tool, input: input) : nil
        func make(_ live: String, _ settled: String, detail: String? = nil) -> AgentToolVerb {
            AgentToolVerb(glyph: category.glyph, live: live, settled: settled, detail: detail, exactInput: exact)
        }
        switch category {
        case .shell:
            guard let command = fields.command.map(firstLine), !command.isEmpty else {
                return make("Running a command", "Ran a command", detail: fields.descriptionLine)
            }
            let shown = clip(redactInline(command), 60)
            return make("Running \(shown)", "Ran \(shown)", detail: fields.descriptionLine)
        case .read:
            let count = fields.paths.count
            if count > 1 {
                return make("Reading \(count) files", "Read \(count) files", detail: basenameDetail(fields.paths))
            }
            let name = fields.firstBasename ?? fields.subjectLabel ?? "a file"
            return make("Reading \(name)", "Read \(name)")
        case .search:
            let root = fields.searchRoot.map(basenameLabel) ?? "repo"
            guard let pattern = fields.pattern, !pattern.isEmpty else {
                return make("Searching \(root)", "Searched \(root)")
            }
            let shown = label(pattern, 40)
            return make("Searching \"\(shown)\" in \(root)", "Searched \"\(shown)\" in \(root)")
        case .edit, .create:
            let count = fields.paths.count
            let verb = category == .create ? ("Creating", "Created") : ("Editing", "Edited")
            let counts = category == .edit ? editCounts(tool.edits) : ""
            if count > 1 {
                return make(
                    "\(verb.0) \(count) files", "\(verb.1) \(count) files\(counts)", detail: basenameDetail(fields.paths)
                )
            }
            let name = fields.firstBasename ?? fields.subjectLabel ?? "a file"
            return make("\(verb.0) \(name)", "\(verb.1) \(name)\(counts)")
        case .delete:
            let name = fields.firstBasename ?? fields.subjectLabel ?? "a file"
            return make("Deleting \(name)", "Deleted \(name)", detail: basenameDetail(fields.paths))
        case .move:
            let name = fields.firstBasename ?? fields.subjectLabel ?? "a file"
            return make("Moving \(name)", "Moved \(name)")
        case .fetch:
            let target = fields.url.map(urlLabel) ?? fields.subjectLabel ?? "a page"
            return make("Fetching \(target)", "Fetched \(target)")
        case .web:
            guard let query = fields.query, !query.isEmpty else { return make("Searching the web", "Searched the web") }
            let shown = label(query, 40)
            return make("Searching the web for \"\(shown)\"", "Searched the web for \"\(shown)\"")
        case .plan:
            return make("Updating plan", "Updated plan", detail: fields.planProgress)
        case .agent:
            // A title that is just the tool's name ("spawn_subagent") describes nothing.
            let title = cleanTitle(tool.title).flatMap { namedCategories[normalize($0)] == nil ? $0 : nil }
            let description = fields.agentDescription ?? title
            guard let description, !description.isEmpty else { return make("Delegating", "Delegated", detail: fields.agentType) }
            let shown = clip(redactInline(firstLine(description)), 48)
            return make("Delegating: \(shown)", "Delegated: \(shown)", detail: fields.agentType)
        case .mcp:
            let parts = mcpParts(tool.toolName ?? "") ?? mcpParts(tool.title)
            guard let parts else { return make("Using a tool", "Used a tool") }
            let shown = "\(label(parts.server, 40)) · \(label(parts.tool, 40))"
            return make("Using \(shown)", "Used \(shown)")
        case .skill:
            guard let name = fields.skillName, !name.isEmpty else { return make("Using a skill", "Used a skill") }
            let shown = label(name, 48)
            return make("Using skill \(shown)", "Used skill \(shown)")
        case .compact:
            return make("Compacting conversation", "Compacted conversation")
        case .switchMode:
            return make("Switching mode", "Switched mode")
        case .think:
            return make("Reasoning", "Reasoned")
        case .other:
            let label = fallbackLabel(tool)
            return make(label, label)
        }
    }

    /// Title, else toolName, else "Tool call" — never "Thought", never raw JSON.
    static func fallbackLabel(_ tool: AgentChatItem.ToolCall) -> String {
        for candidate in [cleanTitle(tool.title), tool.toolName] {
            guard let candidate, !candidate.isEmpty else { continue }
            let label = clip(redactInline(firstLine(candidate)), 80)
            if label.isEmpty { continue }
            return label.caseInsensitiveCompare("Thought") == .orderedSame ? "Thought step" : label
        }
        return "Tool call"
    }

    /// The title unless it is empty, a placeholder, or raw JSON.
    static func cleanTitle(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "Tool call", !trimmed.hasPrefix("{"), !trimmed.hasPrefix("[") else { return nil }
        return trimmed
    }

    private static func exactInput(for category: AgentToolCategory, fields: AgentToolFields, tool: AgentChatItem.ToolCall,
                                   input: JSONValue?) -> String? {
        if category == .shell, let command = fields.command, !command.isEmpty {
            let source = String(command.prefix(maximumExactInputSourceLength))
            return bounded(AgentRedactionPolicy.escapeControls(redactOutput(source, maximumLines: nil).text))
        }
        guard var input else { return nil }
        // A secret file's content (`.env`, keys) is masked whole, as in the Inspector.
        if agentStepTouchesSecretFile(tool, input: input) { input = maskSecretFileContent(input) }
        let redacted = redactJSON(boundingStrings(input)).value
        let rendered: String
        if case .object(let object) = redacted {
            rendered = object.keys.sorted().map { key in "\(key): \(render(object[key] ?? .null))" }.joined(separator: "\n")
        } else {
            rendered = render(redacted)
        }
        guard !rendered.isEmpty else { return nil }
        return bounded(AgentRedactionPolicy.escapeControls(rendered))
    }

    private static func render(_ value: JSONValue) -> String {
        if case .string(let text) = value { return text }
        guard let data = try? value.serialized() else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static let maximumExactInputLength = 16 * 1_024
    /// Input is cut to this before redaction, then to
    /// `maximumExactInputLength` after it: a secret split by the first cut
    /// sits past the second, so its unmasked head is never shown, and a
    /// 256 KiB payload isn't redacted in full for a 16 K tooltip.
    static let maximumExactInputSourceLength = 2 * maximumExactInputLength

    private static func bounded(_ text: String) -> String {
        text.count > maximumExactInputLength ? String(text.prefix(maximumExactInputLength)) + "…" : text
    }

    /// Every string value cut to `maximumExactInputSourceLength`.
    private static func boundingStrings(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let text):
            text.utf8.count > maximumExactInputSourceLength ? .string(String(text.prefix(maximumExactInputSourceLength))) : value
        case .array(let elements):
            .array(elements.map(boundingStrings))
        case .object(let object):
            .object(object.mapValues(boundingStrings))
        case .null, .bool, .number:
            value
        }
    }

    // MARK: Text helpers

    /// Labels show at most 80 characters, so only this much of a line is
    /// ever redacted. Redaction still runs before the final clip; the bound
    /// sits far past every label limit so a secret can't straddle both.
    static let maximumLabelSourceLength = 2_048

    /// The first non-blank line, bounded to `maximumLabelSourceLength`.
    static func firstLine(_ text: String) -> String {
        guard let start = text.firstIndex(where: { !$0.isWhitespace }) else { return "" }
        let rest = text[start...]
        let end = rest.firstIndex(where: \.isNewline) ?? rest.endIndex
        return String(rest[..<end].prefix(maximumLabelSourceLength)).trimmingCharacters(in: .whitespaces)
    }

    /// Redacted, single-line, clipped label text from a bounded prefix.
    static func label(_ text: String, _ limit: Int) -> String {
        clip(redactInline(String(text.prefix(maximumLabelSourceLength))), limit)
    }

    /// Clips to `limit` characters with a trailing ellipsis.
    static func clip(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(1, limit - 1))).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func basenameLabel(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        let name = (trimmed as NSString).lastPathComponent
        return label(name.isEmpty ? trimmed : name, 80)
    }

    /// "a.swift, b.swift +3" from paths; nil for fewer than two. Only the
    /// two shown names are redacted.
    static func basenameDetail(_ paths: [String]) -> String? {
        guard paths.count > 1 else { return nil }
        let shown = paths.prefix(2).map(basenameLabel).joined(separator: ", ")
        return paths.count > 2 ? "\(shown) +\(paths.count - 2)" : shown
    }

    /// " (+a −r)" when every edit reports counts, else "".
    static func editCounts(_ edits: [AgentEditSummary]) -> String {
        guard !edits.isEmpty else { return "" }
        var added = 0
        var removed = 0
        for edit in edits {
            guard let plus = edit.added, let minus = edit.removed else { return "" }
            added += plus
            removed += minus
        }
        return " (+\(added) \u{2212}\(removed))"
    }

    /// Host + path, no scheme, query, or fragment, ≤ 48 characters.
    static func urlLabel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var label: String
        if let components = URLComponents(string: trimmed), let host = components.host, !host.isEmpty {
            label = host + (components.percentEncodedPath == "/" ? "" : components.percentEncodedPath)
        } else {
            label = trimmed
            if let scheme = label.range(of: "://") { label = String(label[scheme.upperBound...]) }
            if let cut = label.firstIndex(where: { $0 == "?" || $0 == "#" }) { label = String(label[..<cut]) }
            // Drop `user:password@` before the host.
            let authority = label.prefix { $0 != "/" }
            if let at = authority.lastIndex(of: "@") { label = String(label[label.index(after: at)...]) }
        }
        return AgentToolResolver.label(label, 48)
    }
}

// MARK: - Input fields

/// The raw fields a label needs, pulled from rawInput, locations, edits, and
/// the subject. Nothing here is redacted yet; the resolver redacts as it
/// builds labels.
struct AgentToolFields {
    var command: String?
    var descriptionLine: String?
    var paths: [String] = []
    var searchRoot: String?
    var pattern: String?
    var url: String?
    var query: String?
    var agentDescription: String?
    var agentType: String?
    var skillName: String?
    var planProgress: String?
    var subjectLabel: String?

    init(tool: AgentChatItem.ToolCall, input: JSONValue?, category: AgentToolCategory) {
        let object = input?.objectValue ?? [:]
        func string(_ keys: String...) -> String? {
            for key in keys {
                if let value = object[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    return value
                }
            }
            return nil
        }
        command = Self.command(object["command"] ?? object["cmd"])
        if command == nil, category == .shell, tool.kind == .execute || tool.toolName == nil,
           var title = AgentToolResolver.cleanTitle(tool.title) {
            // A title-heuristic shell step reads "Run npm test" / "$ npm test".
            for prefix in ["$ ", "running ", "run "] where title.lowercased().hasPrefix(prefix) {
                title = String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                break
            }
            command = title.isEmpty ? nil : title
        }
        if let description = string("description"), category == .shell {
            descriptionLine = AgentToolResolver.clip(redactInline(AgentToolResolver.firstLine(description)), 80)
        }
        if category == .search {
            searchRoot = string("path", "directory", "dir_path", "dir", "root", "include")
            pattern = string("pattern", "regex", "glob", "query", "q", "search_term") ?? tool.subject
        } else {
            paths = Self.paths(object, tool: tool)
        }
        url = string("url", "uri")
        query = string("query", "q", "search_term")
        agentDescription = string("description", "task") ?? string("prompt")
        if let type = string("subagent_type", "subagentType", "agent") {
            agentType = AgentToolResolver.label(type, 48)
        }
        skillName = string("skill", "name", "command")
        planProgress = Self.planProgress(object["todos"] ?? object["plan"])
        if let subject = tool.subject?.trimmingCharacters(in: .whitespacesAndNewlines), !subject.isEmpty {
            subjectLabel = AgentToolResolver.clip(redactInline(subject), 60)
        }
    }

    /// The first path's redacted basename; the only one a single-file label shows.
    var firstBasename: String? { paths.first.map(AgentToolResolver.basenameLabel) }

    /// Codex sends argv arrays; `bash -lc "<script>"` shows the script.
    static func command(_ value: JSONValue?) -> String? {
        if let text = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) {
            return text.isEmpty ? nil : text
        }
        guard let parts = value?.arrayValue?.compactMap(\.stringValue), !parts.isEmpty else { return nil }
        let shells: Set<String> = ["bash", "sh", "zsh", "fish", "/bin/bash", "/bin/sh", "/bin/zsh", "/usr/bin/env bash"]
        if parts.count >= 3, shells.contains(parts[0]), parts[1].hasPrefix("-"), parts[1].hasSuffix("c") {
            return parts[2]
        }
        return parts.map { $0.contains(where: \.isWhitespace) ? "'\($0)'" : $0 }.joined(separator: " ")
    }

    static let maximumPaths = 256

    static func paths(_ object: [String: JSONValue], tool: AgentChatItem.ToolCall) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        func add(_ path: String?) {
            guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty,
                  result.count < maximumPaths, seen.insert(path).inserted else { return }
            result.append(path)
        }
        for key in ["file_path", "filePath", "path", "notebook_path", "absolute_path", "target_file", "filename"] {
            add(object[key]?.stringValue)
        }
        for key in ["paths", "files", "file_paths"] {
            for element in object[key]?.arrayValue ?? [] {
                add(element.stringValue ?? element["path"]?.stringValue ?? element["file_path"]?.stringValue)
            }
        }
        if let changes = object["changes"]?.objectValue {
            for key in changes.keys.sorted() { add(key) }
        }
        for edit in tool.edits { add(edit.path) }
        for location in tool.locations { add(location.path) }
        return result
    }

    /// "3/7 done" for a todo list.
    static func planProgress(_ value: JSONValue?) -> String? {
        guard let todos = value?.arrayValue, !todos.isEmpty else { return nil }
        let done = todos.filter { ($0["status"]?.stringValue ?? "").lowercased() == "completed" }.count
        return "\(done)/\(todos.count) done"
    }
}

// MARK: - Formatting

enum AgentActivityFormat {
    /// "42s", "3m 05s", "1h 02m".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded())
        if total < 60 { return "\(total)s" }
        if total < 3_600 { return "\(total / 60)m \(twoDigits(total % 60))s" }
        return "\(total / 3_600)h \(twoDigits(total % 3_600 / 60))m"
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}

enum AgentActivityText {
    static let liveStatusLimit = 80
    /// Only the tail of a long thought is scanned.
    static let scanLimit = 4_096

    private static let markdownLink: NSRegularExpression = {
        // A compile-time literal covered by tests.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"!?\[([^\]\n]{0,300})\]\([^)\n]{0,1000}\)"#)
    }()

    /// The last complete sentence (or line) of `text`, markdown stripped,
    /// redacted, ≤ 80 characters; before any sentence completes, the start of
    /// the text so far. Nil for blank text.
    static func liveSentence(_ text: String) -> String? {
        let tail = text.utf8.count > scanLimit ? String(text.suffix(scanLimit)) : text
        let lines = tail.split(separator: "\n", omittingEmptySubsequences: false)
        var latest: String?
        for (index, line) in lines.enumerated() {
            let lineIsComplete = index < lines.count - 1
            for sentence in sentences(in: stripMarkdown(String(line))) where sentence.complete || lineIsComplete {
                latest = sentence.text
            }
        }
        if latest == nil {
            latest = lines.lazy.map { stripMarkdown(String($0)) }.first { !$0.isEmpty }
        }
        guard let latest, !latest.isEmpty else { return nil }
        return AgentToolResolver.clip(redactInline(latest), liveStatusLimit)
    }

    /// Sentences in one line; a sentence is complete when `.`, `!`, `?`, or
    /// `…` is followed by whitespace or ends the line.
    static func sentences(in line: String) -> [(text: String, complete: Bool)] {
        var result: [(String, Bool)] = []
        var current = ""
        var previousWasTerminator = false
        for character in line {
            if previousWasTerminator, character.isWhitespace {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { result.append((trimmed, true)) }
                current = ""
                previousWasTerminator = false
                continue
            }
            current.append(character)
            previousWasTerminator = ".!?…".contains(character)
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { result.append((trimmed, previousWasTerminator)) }
        return result
    }

    /// Drops headings, quote and list markers, emphasis, code ticks, and link
    /// targets.
    static func stripMarkdown(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        while let first = text.first, "#>".contains(first) {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        for marker in ["- ", "* ", "+ "] where text.hasPrefix(marker) {
            text = String(text.dropFirst(marker.count))
            break
        }
        if text.contains("](") {
            let range = NSRange(location: 0, length: (text as NSString).length)
            text = markdownLink.stringByReplacingMatches(in: text, range: range, withTemplate: "$1")
        }
        for marker in ["**", "__", "~~", "`", "*"] where text.contains(marker) {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
