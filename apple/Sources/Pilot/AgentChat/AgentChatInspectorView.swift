import AppKit
import UniformTypeIdentifiers

// Mounting (WP6): `mount(in: transcriptContainer)` overlays the transcript; set `actions` and `runTraceSource` (built off the main
// actor), route `rowActions.openInspector` to `present`, call `update(_:)` each render, and `dismiss()` on Esc in the table.

/// What the Inspector shows. Keys are namespaced "<session>/<item>".
enum AgentInspectorSubject: Equatable, Hashable, Sendable {
    case step(key: String)
    case thought(key: String)
    case agent(childSessionID: String)
    case group(id: String)
    case plan(key: String)
    case run
}

/// Reasoning appears only for subjects that have it.
enum AgentInspectorTab: String, Equatable, Sendable, CaseIterable {
    case input, output, reasoning, meta
    var title: String { rawValue.prefix(1).uppercased() + String(rawValue.dropFirst()) }
}

/// Everything the Inspector renders for one subject, gathered by the pane; redacted before any sink.
struct AgentInspectorContent: Equatable, Sendable {
    var subject: AgentInspectorSubject
    var title: String
    /// Names the reporter: "No input reported by <agent>", "tokens reported by <agent>".
    var agentName: String
    /// The step, thought, plan, or subagent card item.
    var item: AgentChatItem?
    /// nil: no raw payload was reported; `evicted`: "Detail evicted".
    var detail: AgentStepDetail?
    /// Group subject, or the child's projected card for an agent subject.
    var group: AgentActivityGroup?
    /// An agent subject's final prose.
    var finalProse: String?
    var model: String?
    /// Per turn or per agent; never per step.
    var turnUsage: NormalizedTurnUsage?
    var context: ACPContextUsage?
}

/// The §2.4 redaction functions, injectable so tests prove every sink routes through them.
struct AgentInspectorRedactor: Sendable {
    var output: @Sendable (String, Int?) -> AgentRedaction
    var json: @Sendable (JSONValue) -> (value: JSONValue, redacted: Bool)
    var inline: @Sendable (String) -> String
    /// §2.4 whole-content mask for secret files (WP3's `isSecretLikePath`, the one policy source).
    var secretPath: @Sendable (String) -> Bool = { isSecretLikePath($0) }
    static let standard = Self(output: { redactOutput($0, maximumLines: $1) }, json: { redactJSON($0) }, inline: { redactInline($0) })
    static let mask = "••••"
    /// True when a step reads or writes a file whose whole content is masked.
    func touchesSecretFile(_ tool: AgentChatItem.ToolCall, detail: AgentStepDetail?) -> Bool {
        agentStepTouchesSecretFile(tool, input: detail?.rawInput?.value, blocks: detail?.blocks ?? [], secretPath: secretPath)
    }
    /// Masks every string in a secret file's payload except path fields, so the file content never reaches a sink.
    static func maskFileContent(_ value: JSONValue, key: String = "") -> JSONValue { maskSecretFileContent(value, key: key) }
}

/// Run-trace and step export documents. Always redacted; reasoning is excluded unless `includeReasoning`.
enum AgentRunTrace {
    static let schema = "cockpit.agent-chat.trace/1"
    static func json(transcript: AgentTranscript, agentName: String, includeReasoning: Bool) -> JSONValue { json(transcript: transcript, agentName: agentName, includeReasoning: includeReasoning, redactor: .standard) }
    static func json(transcript: AgentTranscript, agentName: String, includeReasoning: Bool, redactor: AgentInspectorRedactor) -> JSONValue {
        func items(_ list: [AgentChatItem]) -> JSONValue {
            .array(list.map { itemJSON($0, detail: transcript.stepDetails[$0.key], includeReasoning: includeReasoning, redactor: redactor) })
        }
        let subagents = transcript.childItems.keys.sorted().map { child -> JSONValue in
            ["childSessionID": .string(redactor.inline(child)), "items": items(transcript.children(of: child))]
        }
        return [
            "schema": .string(schema), "redacted": true, "reasoningIncluded": .bool(includeReasoning),
            "agent": .string(redactor.inline(agentName)), "items": items(transcript.items), "subagents": .array(subagents),
        ]
    }
    static func stepJSON(item: AgentChatItem, detail: AgentStepDetail?) -> JSONValue { stepJSON(item: item, detail: detail, includeReasoning: false) }
    static func stepJSON(item: AgentChatItem, detail: AgentStepDetail?, includeReasoning: Bool, redactor: AgentInspectorRedactor = .standard) -> JSONValue {
        [
            "schema": .string(schema), "redacted": true, "reasoningIncluded": .bool(includeReasoning),
            "step": itemJSON(item, detail: detail, includeReasoning: includeReasoning, redactor: redactor),
        ]
    }
    static func prettyData(_ value: JSONValue) -> Data {
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        guard let compact = try? value.serialized(),
              let object = try? JSONSerialization.jsonObject(with: compact, options: [.fragmentsAllowed]),
              let data = try? JSONSerialization.data(withJSONObject: object, options: options) else { return Data("null".utf8) }
        return data
    }
    static func prettyText(_ value: JSONValue) -> String {
        if case .string(let text) = value { return text }
        return String(bytes: prettyData(value), encoding: .utf8) ?? ""
    }
    private typealias Fields = [String: JSONValue?]
    private static func itemJSON(_ item: AgentChatItem, detail: AgentStepDetail?, includeReasoning: Bool, redactor: AgentInspectorRedactor) -> JSONValue {
        let inline = { (value: String?) -> JSONValue? in value.map { .string(redactor.inline($0)) } }
        let text = { (value: String?) -> JSONValue? in value.map { .string(redactor.output($0, nil).text) } }
        var fields: Fields = [
            "key": inline(item.key), "session": inline(item.sessionKey), "turn": number(item.turnIndex), "replayed": .bool(item.isReplayed),
        ]
        switch item.content {
        case .user(let value):
            fields.merge(["type": "user", "text": text(value), "attachments": number(item.attachments.isEmpty ? nil : item.attachments.count)]) { $1 }
        case .assistant(let value): fields.merge(["type": "assistant", "text": text(value)]) { $1 }
        case .notice(let value): fields.merge(["type": "notice", "text": text(value)]) { $1 }
        case .thought(let thought):
            fields.merge(includeReasoning ? ["type": "thought", "text": text(thought.text)] : ["type": "thought", "reasoningExcluded": true]) { $1 }
            fields.merge(times(thought.startedAt, thought.endedAt)) { $1 }
        case .tool(let tool):
            fields.merge(stepFields(tool, detail: detail, redactor: redactor)) { $1 }
        case .plan(let entries):
            let list = entries.map { entry -> JSONValue in ["content": text(entry.content) ?? .null, "status": .string(redactor.inline(entry.status))] }
            fields.merge(["type": "plan", "entries": .array(list)]) { $1 }
        case .subagent(let agent):
            fields.merge([
                "type": "agent", "childSessionID": inline(agent.childSessionID), "title": inline(agent.title),
                "lifecycle": inline(agent.lifecycle.rawValue), "model": inline(agent.model), "error": inline(agent.error.map { String($0.prefix(200)) }),
            ]) { $1 }
            fields.merge(times(agent.startedAt, agent.endedAt)) { $1 }
        case .approval(let approval):
            fields.merge([
                "type": "approval", "title": inline(approval.title), "agent": inline(approval.agentName), "subject": inline(approval.subject),
                "toolCallID": inline(approval.toolCallID), "decision": inline(decision(approval.decision)),
                "autoApproved": approval.autoApproved ? .bool(true) : nil,
            ]) { $1 }
        }
        return .object(fields.compactMapValues { $0 })
    }
    private static func stepFields(_ tool: AgentChatItem.ToolCall, detail: AgentStepDetail?, redactor: AgentInspectorRedactor) -> Fields {
        let inline = { (value: String?) -> JSONValue? in value.map { .string(redactor.inline($0)) } }
        let secret = redactor.touchesSecretFile(tool, detail: detail)
        let text = { (value: String) -> JSONValue in .string(secret ? AgentInspectorRedactor.mask : redactor.output(value, nil).text) }
        var fields: Fields = [
            "type": "step", "title": inline(tool.title), "toolName": inline(tool.toolName), "kind": inline(tool.kind?.rawValue),
            "status": inline(tool.status?.rawValue), "outcome": inline(tool.outcome.map { String(describing: $0) }),
            "subject": inline(tool.subject), "errorSummary": inline(tool.errorSummary), "nonExecutionKind": inline(tool.nonExecutionKind),
            "exitCode": number(tool.exitCode), "content": tool.content.isEmpty ? nil : text(tool.content),
            "locations": tool.locations.isEmpty ? nil : .array(tool.locations.map { location -> JSONValue in
                ["path": inline(location.path) ?? .null, "line": number(location.line) ?? .null]
            }),
            "edits": tool.edits.isEmpty ? nil : .array(tool.edits.map { edit -> JSONValue in
                ["path": inline(edit.path) ?? .null, "created": .bool(edit.created), "added": number(edit.added) ?? .null, "removed": number(edit.removed) ?? .null]
            }),
        ]
        fields.merge(times(tool.startedAt, tool.endedAt)) { $1 }
        guard let detail else { return fields }
        guard !detail.evicted else { return fields.merging(["detailEvicted": true]) { $1 } }
        let blocks = detail.blocks.map { block -> JSONValue in
            switch block {
            case .text(let value): ["type": "text", "text": text(value)]
            case .diff(let path, let old, let new):
                ["type": "diff", "path": inline(path) ?? .null, "oldText": old.map(text) ?? .null, "newText": text(new)]
            case .terminal(let id): ["type": "terminal", "terminalId": inline(id) ?? .null]
            case .other(let type): ["type": inline(type) ?? .null]
            }
        }
        return fields.merging([
            "input": detail.rawInput.map { payload($0, redactor: redactor, secret: secret) },
            "output": detail.rawOutput.map { payload($0, redactor: redactor, secret: secret) },
            "blocks": blocks.isEmpty ? nil : .array(blocks),
            "terminalOutput": detail.terminalOutput.isEmpty ? nil : text(detail.terminalOutput),
        ]) { $1 }
    }
    private static func payload(_ bounded: ACPBoundedJSON, redactor: AgentInspectorRedactor, secret: Bool) -> JSONValue {
        if let value = bounded.value { return redactor.json(secret ? AgentInspectorRedactor.maskFileContent(value) : value).value }
        let prefix = bounded.prefixText.map { JSONValue.string(secret ? AgentInspectorRedactor.mask : redactor.output($0, nil).text) }
        let object = (["prefix": prefix, "truncatedBytes": number(bounded.truncatedBytes)] as Fields).compactMapValues { $0 }
        return object.isEmpty ? .null : .object(object)
    }
    private static func times(_ start: Date?, _ end: Date?) -> Fields {
        ["startedAt": start.map { .string($0.formatted(.iso8601)) }, "endedAt": end.map { .string($0.formatted(.iso8601)) },
         // Milliseconds: a raw sub-microsecond interval doesn't survive a JSON
         // round trip exactly, which made exports compare unequal at random.
         "durationSeconds": start.flatMap { start in end.map { .number((max(0, $0.timeIntervalSince(start)) * 1000).rounded() / 1000) } }]
    }
    private static func number(_ value: Int?) -> JSONValue? { value.map { .number(Double($0)) } }
    private static func decision(_ decision: AgentChatItem.Approval.Decision) -> String {
        switch decision {
        case .pending: "pending"
        case .chose(_, let name, let allows): "\(allows ? "approved" : "rejected"): \(name)"
        case .cancelledByUser: "cancelled"
        case .withdrawnByAgent: "withdrawn by agent"
        case .autoCancelled: "auto-cancelled"
        case .agentStopped: "stopped"
        }
    }
}

// MARK: - Pure presentation

/// A chip under the tabs naming what the policy did or what is missing.
enum AgentInspectorNotice: Equatable, Sendable {
    case noInput(agent: String), noOutput(agent: String), noReasoning(agent: String), evicted
    var chip: (title: String, identifier: String) {
        switch self {
        case .noInput(let agent): ("No input reported by \(agent)", "no-input")
        case .noOutput(let agent): ("No output reported by \(agent)", "no-output")
        case .noReasoning(let agent): ("No reasoning reported by \(agent)", "no-reasoning")
        case .evicted: ("Detail evicted", "evicted")
        }
    }
}

enum AgentInspectorSource: Equatable, Sendable { case json(JSONValue), text(String) }

/// One tab's redacted text and chips.
struct AgentInspectorPage: Equatable, Sendable {
    var text: String
    var redacted = false, truncatedLines = 0, notices: [AgentInspectorNotice] = []
}

enum AgentInspectorFormatter {
    typealias Found = (source: AgentInspectorSource?, notices: [AgentInspectorNotice])
    static let truncationLines = 200
    /// Pages above this are redacted off the main actor.
    static let largeTextBytes = 64 * 1_024
    static func tabs(for content: AgentInspectorContent) -> [AgentInspectorTab] {
        switch content.subject {
        case .step: [.input, .output, .meta]
        case .thought: [.reasoning, .meta]
        case .agent: reasoningParts(content).isEmpty ? [.output, .meta] : [.output, .reasoning, .meta]
        case .plan: [.output, .meta]
        case .group, .run: [.meta]
        }
    }
    static func defaultTab(for content: AgentInspectorContent) -> AgentInspectorTab {
        switch content.subject {
        case .step, .agent, .plan: .output
        case .thought: .reasoning
        case .group, .run: .meta
        }
    }
    static func reasoningText(_ content: AgentInspectorContent) -> String? {
        let parts = reasoningParts(content)
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
    private static func reasoningParts(_ content: AgentInspectorContent) -> [String] {
        if case .thought(let thought)? = content.item?.content { return thought.text.isEmpty ? [] : [thought.text] }
        guard case .agent = content.subject, let group = content.group else { return [] }
        return group.members.compactMap { member in
            guard case .thought(let item) = member, case .thought(let thought) = item.content, !thought.text.isEmpty else { return nil }
            return thought.text
        }
    }
    /// The unredacted payload behind a tab, plus the chips explaining gaps.
    static func source(_ tab: AgentInspectorTab, content: AgentInspectorContent, redactor: AgentInspectorRedactor = .standard) -> Found {
        let agent = redactor.inline(content.agentName)
        switch tab {
        case .input:
            guard case .tool = content.item?.content else { return (nil, [.noInput(agent: agent)]) }
            if content.detail?.evicted == true { return (nil, [.evicted]) }
            return content.detail?.rawInput.flatMap(bounded) ?? (nil, [.noInput(agent: agent)])
        case .output: return outputSource(content, agent: agent)
        case .reasoning: return reasoningText(content).map { (.text($0), []) } ?? (nil, [.noReasoning(agent: agent)])
        case .meta: return (nil, [])
        }
    }
    private static func outputSource(_ content: AgentInspectorContent, agent: String) -> Found {
        switch content.item?.content {
        case .tool(let tool)?:
            let evicted = content.detail?.evicted == true
            let detail = evicted ? nil : content.detail
            let notices: [AgentInspectorNotice] = evicted ? [.evicted] : []
            var parts = (detail?.blocks ?? []).compactMap(blockText)
            if let terminal = detail?.terminalOutput, !terminal.isEmpty { parts.append(terminal) }
            if parts.isEmpty, let found = detail?.rawOutput.flatMap(bounded) { return (found.source, notices + found.notices) }
            if parts.isEmpty, !tool.content.isEmpty { parts.append(tool.content) }
            if parts.isEmpty { return (nil, notices.isEmpty ? [.noOutput(agent: agent)] : notices) }
            return (.text(parts.joined(separator: "\n")), notices)
        case .plan(let entries)?:
            let marks = ["completed": "[x]", "in_progress": "[~]"]
            return (.text(entries.map { "\(marks[$0.status] ?? "[ ]") \($0.content)" }.joined(separator: "\n")), [])
        default:
            guard let prose = content.finalProse, !prose.isEmpty else { return (nil, [.noOutput(agent: agent)]) }
            return (.text(prose), [])
        }
    }
    private static func bounded(_ value: ACPBoundedJSON) -> Found? {
        if let json = value.value, json != .null { return (.json(json), []) }
        return value.prefixText.map { (.text($0), []) }
    }
    private static func blockText(_ block: ACPToolContent) -> String? {
        switch block {
        case .text(let text): text.isEmpty ? nil : text
        case .diff(let path, let old, let new): "--- \(path)\n+++ \(path)\n" + (old.map { "- \($0)\n" } ?? "") + "+ \(new)"
        case .terminal(let id): "[terminal \(id)]"
        case .other: nil
        }
    }
    /// Unredacted text, for "Copy unredacted" only.
    static func rawText(_ source: AgentInspectorSource) -> String {
        switch source {
        case .text(let text): text
        case .json(let value): AgentRunTrace.prettyText(value)
        }
    }
    /// Raw payloads are bounded (ACPBoundedJSON, 256 KiB), so measuring the text is cheap.
    static func isLarge(_ source: AgentInspectorSource) -> Bool { rawText(source).utf8.count > largeTextBytes }
    /// The page for one tab. Pure; safe off the main actor.
    static func page(_ tab: AgentInspectorTab, content: AgentInspectorContent, showAll: Bool, now: Date, redactor: AgentInspectorRedactor = .standard) -> AgentInspectorPage {
        if tab == .meta { return AgentInspectorPage(text: metaText(content, now: now, redactor: redactor)) }
        let (found, notices) = source(tab, content: content, redactor: redactor)
        guard var source = found else { return AgentInspectorPage(text: "", notices: notices) }
        var secret = false
        if case .tool(let tool)? = content.item?.content, redactor.touchesSecretFile(tool, detail: content.detail) {
            if tab == .input, case .json(let value) = source { (source, secret) = (.json(AgentInspectorRedactor.maskFileContent(value)), true) } else {
                return AgentInspectorPage(text: AgentInspectorRedactor.mask, redacted: true, notices: notices)
            }
        }
        var page = redact(source, maximumLines: showAll ? nil : truncationLines, redactor: redactor)
        (page.notices, page.redacted) = (notices, page.redacted || secret)
        return page
    }
    static func redact(_ source: AgentInspectorSource, maximumLines: Int?, redactor: AgentInspectorRedactor) -> AgentInspectorPage {
        // JSON is redacted value-by-value before it is printed; text goes straight to the output policy.
        var (masked, text) = (false, "")
        switch source {
        case .text(let raw): text = raw
        case .json(let value): let result = redactor.json(value); (masked, text) = (result.redacted, AgentRunTrace.prettyText(result.value))
        }
        let result = redactor.output(text, maximumLines)
        return AgentInspectorPage(text: result.text, redacted: result.redacted || masked, truncatedLines: result.truncatedLines)
    }
    static func metaText(_ content: AgentInspectorContent, now: Date, redactor: AgentInspectorRedactor) -> String {
        var rows: [String] = []
        func add(_ label: String, _ value: String?) { if let value, !value.isEmpty { rows.append("\(label): \(value)") } }
        func times(_ start: Date?, _ end: Date?) {
            [("Started", start?.formatted(date: .omitted, time: .standard)), ("Ended", end?.formatted(date: .omitted, time: .standard)),
             ("Duration", duration(start, end ?? (start == nil ? nil : now)))].forEach(add)
        }
        let agent = redactor.inline(content.agentName)
        add("Agent", agent)
        switch content.item?.content {
        case .tool(let tool)?:
            [("Tool", tool.toolName.map(redactor.inline)), ("Kind", tool.kind?.rawValue), ("Status", stateName(tool)),
             ("Exit code", tool.exitCode.map(String.init)), ("Error", tool.errorSummary.map(redactor.inline))].forEach(add)
            times(tool.startedAt, tool.endedAt)
            tool.locations.prefix(64).forEach { add("Location", redactor.inline($0.path) + ($0.line.map { ":\($0)" } ?? "")) }
            for edit in tool.edits.prefix(64) {
                let counts = [edit.added.map { "+\($0)" }, edit.removed.map { "−\($0)" }].compactMap { $0 }
                add(edit.created ? "Created" : "Edited", ([redactor.inline(edit.path)] + counts).joined(separator: " "))
            }
        case .thought(let thought)?: times(thought.startedAt, thought.endedAt)
        case .subagent(let card)?:
            [("Lifecycle", card.lifecycle.rawValue), ("Model", card.model.map(redactor.inline))].forEach(add)
            times(card.startedAt, card.endedAt)
        case .plan(let entries)?:
            [("Entries", "\(entries.count)"), ("Done", "\(entries.filter { $0.status == "completed" }.count)")].forEach(add)
        default: break
        }
        if let group = content.group {
            [("Summary", redactor.inline(group.summary)), ("Steps", "\(group.stepCount)"), ("Failed", "\(group.failedCount)"),
             ("Stopped", group.stoppedCount > 0 ? "\(group.stoppedCount)" : nil)].forEach(add)
            if case .group = content.subject { times(group.startedAt, group.endedAt) }
        }
        add("Model", content.model.map(redactor.inline))
        // Tokens are reported per turn for the run (agents report no per-step or per-subagent usage).
        let perRun = content.subject == .run
        if perRun, let context = content.context { add("Context", contextMeter(context, usage: content.turnUsage)) }
        if perRun, let usage = content.turnUsage {
            let line = [usage.uncachedInputTokens, usage.cacheReadTokens, usage.cacheWriteTokens, usage.outputTokens].map(AgentChatFormat.tokens)
            add("\(content.subject == .run ? "Last turn" : "Usage") (reported by \(agent))",
                "\(line[0]) input · \(line[1]) cached · \(line[2]) cache write · \(line[3]) output")
        }
        if let group = content.group {
            rows += ["", "Steps"] + group.members.map { memberLine($0, now: now, redactor: redactor) }
        }
        return rows.joined(separator: "\n")
    }
    static func contextMeter(_ context: ACPContextUsage, usage: NormalizedTurnUsage?) -> String {
        var parts = ["\(AgentChatFormat.tokens(context.usedTokens)) / \(AgentChatFormat.tokens(context.windowTokens))"]
        if let rate = usage?.cacheHitRate { parts.append("Cache \(AgentChatFormat.percent(rate))") }
        if let amount = context.costAmount, amount.isFinite {
            let code = context.costCurrency.flatMap { $0.count == 3 && $0.allSatisfy(\.isLetter) ? $0.uppercased() : nil } ?? "USD"
            parts.append(amount.formatted(.currency(code: code)))
        }
        return parts.joined(separator: " · ")
    }
    private static func stateName(_ tool: AgentChatItem.ToolCall) -> String {
        tool.isRunning ? "running" : tool.outcome.map { String(describing: $0) } ?? tool.status?.rawValue ?? ""
    }
    private static func memberLine(_ member: AgentActivityMember, now: Date, redactor: AgentInspectorRedactor) -> String {
        switch member {
        case .step(let item):
            guard case .tool(let tool) = item.content else { return "" }
            return "  \(redactor.inline(verbForTool(tool, input: nil).settled)) — \(stateName(tool))"
        case .thought(let item):
            guard case .thought(let thought) = item.content else { return "" }
            return "  \(redactor.inline(verbForThought(thought, now: now).settled))"
        case .agents(let entries):
            return entries.map { "  \(redactor.inline($0.name)) · \($0.steps) — \($0.lifecycle.rawValue)" }.joined(separator: "\n")
        }
    }
    static func duration(_ start: Date?, _ end: Date?) -> String? {
        guard let start, let end else { return nil }
        let seconds = max(0, Int(end.timeIntervalSince(start).rounded()))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m \(String(format: "%02d", seconds % 60))s" }
        return "\(seconds / 3_600)h \(String(format: "%02d", seconds % 3_600 / 60))m"
    }
    /// A save-panel name with no path separators, colons, controls, bidi marks, or a leading dot.
    static func sanitizedFileName(_ raw: String, pathExtension: String) -> String {
        // controlCharacters is Cc + Cf, which covers the bidi embeddings, overrides, isolates, and marks.
        let forbidden = CharacterSet(charactersIn: "/:\\").union(.controlCharacters).union(.newlines)
        var name = String(String.UnicodeScalarView(raw.unicodeScalars.map { forbidden.contains($0) ? "-" : $0 }))
        name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let first = name.first, first == "." || first == "-" || first == " " { name.removeFirst() }
        name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces)
        return (name.isEmpty ? "agent-chat" : name) + "." + pathExtension
    }
}

// MARK: - Drawer

/// Trailing overlay drawer, resizable 240…min(520, 85% of the host), focus-trapped; Esc closes; an outside click dismisses
/// below 560 pt. Every sink is redacted except "Copy Unredacted" (concealed). Reasoning is selectable only when allowed.
final class AgentInspectorViewController: NSViewController, NSMenuDelegate {
    enum Action: String, CaseIterable, Sendable {
        case copyInput = "Copy Input", copyOutput = "Copy Output", copyUnredacted = "Copy Unredacted"
        case exportStepJSON = "Export Step JSON…", exportRunTrace = "Export Run Trace JSON…", exportReasoning = "Export Reasoning…"
        case askToContinue = "Ask to Continue…"
        /// The run's Meta: model, last turn's tokens, and the context meter.
        case showRun = "Show Run Usage"
    }
    static let accessibilityIdentifierValue = "agent-chat.inspector"
    static let allowReasoningExportKey = "agentChat.allowReasoningExport"
    /// `narrowHostWidth`: below it an outside click dismisses.
    static let minimumWidth: CGFloat = 240, maximumWidth: CGFloat = 520, defaultWidth: CGFloat = 360, narrowHostWidth: CGFloat = 560
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    /// Called after the drawer closes (Esc, close button, outside click).
    var onClose: () -> Void = {}
    /// Builds the run trace for export; the argument is whether reasoning is included. Runs on the main actor: prefer `runTraceSource`.
    var makeRunTrace: (Bool) -> JSONValue = { _ in .null }
    /// A copy-on-write snapshot; when set, the run trace is built and redacted off the main actor after a URL is chosen.
    var runTraceSource: (() -> (transcript: AgentTranscript, agentName: String))?
    var actions = AgentChatRowActions()
    var now: () -> Date = { Date() }
    var redactor = AgentInspectorRedactor.standard
    /// Writes copied text; `concealed` also marks it with `concealedType`.
    var writePasteboard: (String, Bool) -> Void = { AgentInspectorViewController.write($0, concealed: $1, to: .general) }
    /// Asks where to save (nil: NSSavePanel). Nothing is written without a chosen URL; the file is never opened.
    var chooseSaveURL: ((String, @escaping (URL?) -> Void) -> Void)?
    var writeFile: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    private(set) var subject: AgentInspectorSubject?
    var isPresented: Bool { subject != nil }
    private(set) var content: AgentInspectorContent?, tabs: [AgentInspectorTab] = []
    private(set) var selectedTab = AgentInspectorTab.output
    private(set) var page: AgentInspectorPage?, showsAll = false
    private(set) var preferredWidth = AgentInspectorViewController.defaultWidth
    private let allowsReasoningExport: () -> Bool
    private weak var host: NSView?
    let scrim = AgentInspectorScrim(), handle = AgentInspectorResizeHandle(), closeButton = NSButton()
    let titleLabel = NSTextField(labelWithString: ""), agentLabel = NSTextField(labelWithString: "")
    let actionsButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private(set) lazy var tabControl = PilotSegmentedControl<AgentInspectorTab>(
        "Inspector tabs", selection: .output, options: [.output], title: \.title, controlSize: .small
    ) { [weak self] tab in self?.select(tab) }
    private(set) var chips: [AgentInspectorChip] = []
    let nestedCard = ActivityCardView(), textView = AgentInspectorTextView()
    private let scrollView = NSScrollView()
    private var generation = 0, dragStartWidth: CGFloat = 0
    /// One off-main redaction at a time; updates arriving meanwhile coalesce into one rerun.
    private var redacting = false, redactAgain = false
    /// The page the text view shows ("subject|tab|showAll"); streaming appends only within one page.
    private var shownKey = "", chipSignature: [String] = []
    private weak var previousResponder: NSView?
    init(allowsReasoningExport: @escaping () -> Bool = {
        UserDefaults.standard.bool(forKey: AgentInspectorViewController.allowReasoningExportKey)
    }) {
        self.allowsReasoningExport = allowsReasoningExport
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        let drawer = AgentInspectorDrawerView()
        drawer.wantsLayer = true
        drawer.setAccessibilityIdentifier(Self.accessibilityIdentifierValue)
        drawer.setAccessibilityRole(.group); drawer.setAccessibilityLabel("Inspector")
        drawer.onLayout = { [weak self] in self?.layoutContent() }
        drawer.onEscape = { [weak self] in self?.dismiss() }
        drawer.onTab = { [weak self] backward in self?.cycleFocus(backward: backward) }
        view = drawer
        handle.onBegin = { [weak self] in self.map { $0.dragStartWidth = $0.view.frame.width } }
        handle.onDrag = { [weak self] delta in self.map { $0.resize(to: $0.dragStartWidth - delta) } }
        (titleLabel.textColor, agentLabel.textColor) = (AgentChatPalette.color(.textPrimary), AgentChatPalette.color(.textMuted))
        (titleLabel.lineBreakMode, agentLabel.lineBreakMode) = (.byTruncatingTail, .byTruncatingTail)
        (closeButton.image, closeButton.isBordered) = (NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Inspector"), false)
        closeButton.setAccessibilityIdentifier("agent-chat.inspector.close")
        (closeButton.target, closeButton.action) = (self, #selector(closeClicked))
        (actionsButton.controlSize, actionsButton.menu) = (.small, NSMenu())
        actionsButton.setAccessibilityIdentifier("agent-chat.inspector.actions"); actionsButton.setAccessibilityLabel("Inspector actions")
        actionsButton.menu?.delegate = self; actionsButton.menu?.addItem(withTitle: "Actions", action: nil, keyEquivalent: "")
        nestedCard.isHidden = true
        (textView.isEditable, textView.isRichText, textView.drawsBackground) = (false, false, false)
        (textView.textContainerInset, textView.autoresizingMask, textView.isVerticallyResizable) = (NSSize(width: 4, height: 6), [.width], true)
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textColor = AgentChatPalette.color(.textPrimary)
        zoomChanged()
        NotificationCenter.default.addObserver(self, selector: #selector(zoomChanged), name: .cockpitUIZoomDidChange, object: nil)
        textView.setAccessibilityIdentifier("agent-chat.inspector.text")
        (scrollView.documentView, scrollView.drawsBackground) = (textView, false)
        (scrollView.hasVerticalScroller, scrollView.autohidesScrollers) = (true, true)
        [handle, titleLabel, agentLabel, actionsButton, closeButton, tabControl, nestedCard, scrollView].forEach(drawer.addSubview)
        (scrim.onResize, scrim.onClickOutside) = ({ [weak self] in self?.layoutDrawer() }, { [weak self] in self?.dismiss() })
        (drawer.isHidden, scrim.isHidden) = (true, true)
    }
    /// Adds the outside-click scrim and the drawer on top of `host` without touching its other subviews.
    func mount(in host: NSView) {
        loadViewIfNeeded()
        [scrim, view].forEach { $0.removeFromSuperview() }
        self.host = host
        (scrim.frame, scrim.autoresizingMask) = (host.bounds, [.width, .height])
        host.addSubview(scrim, positioned: .above, relativeTo: nil)
        host.addSubview(view, positioned: .above, relativeTo: nil)
        layoutDrawer()
    }
    static func drawerWidth(preferred: CGFloat, hostWidth: CGFloat) -> CGFloat {
        let lower = min(minimumWidth, hostWidth)
        return min(max(preferred, lower), max(lower, min(maximumWidth, hostWidth * 0.85)))
    }
    /// Opens (or retargets) the drawer. `tab` nil picks the subject's default.
    func present(_ content: AgentInspectorContent, tab: AgentInspectorTab?) {
        loadViewIfNeeded()
        let (wasPresented, retarget) = (isPresented, subject != content.subject)
        if retarget { showsAll = false }
        subject = content.subject
        apply(content, requested: tab, keepTab: !retarget)
        guard !wasPresented else { return }
        slide(presenting: true)
        if let window = view.window {
            if let current = window.firstResponder as? NSView, !current.isDescendant(of: view) { previousResponder = current }
            window.makeFirstResponder(textView.isSelectable ? textView : view)
        }
    }
    /// Refreshes the open subject in place (streaming output, settled times).
    func update(_ content: AgentInspectorContent) {
        // Unchanged content re-renders only Meta (live durations): renders must not re-redact the page every frame.
        guard isPresented, content.subject == subject, content != self.content || selectedTab == .meta else { return }
        apply(content, requested: nil, keepTab: true)
    }
    func dismiss() {
        guard isPresented else { return }
        (subject, content, page, redactAgain) = (nil, nil, nil, false)
        generation += 1
        if let window = view.window, (window.firstResponder as? NSView)?.isDescendant(of: view) == true {
            window.makeFirstResponder(previousResponder?.window === window ? previousResponder : nil)
        }
        slide(presenting: false)
        onClose()
    }
    func select(_ tab: AgentInspectorTab) {
        guard tabs.contains(tab), let content else { return }
        if tab != selectedTab { showsAll = false }
        apply(content, requested: tab, keepTab: true)
    }
    /// "truncated · show all": re-redacts the full text without the line limit.
    func showAll() {
        guard let content, page?.truncatedLines ?? 0 > 0 else { return }
        showsAll = true; apply(content, requested: selectedTab, keepTab: true)
    }
    func resize(to width: CGFloat) {
        preferredWidth = Self.drawerWidth(preferred: width, hostWidth: host?.bounds.width ?? .greatestFiniteMagnitude)
        layoutDrawer()
    }
    private func apply(_ content: AgentInspectorContent, requested: AgentInspectorTab?, keepTab: Bool) {
        self.content = content
        let nextTabs = AgentInspectorFormatter.tabs(for: content)
        if let requested, nextTabs.contains(requested) {
            selectedTab = requested
        } else if !keepTab || !nextTabs.contains(selectedTab) {
            selectedTab = AgentInspectorFormatter.defaultTab(for: content)
        }
        if nextTabs != tabs { tabControl.options = nextTabs }
        tabs = nextTabs
        tabControl.selection = selectedTab
        tabControl.isHidden = tabs.count < 2
        (titleLabel.stringValue, agentLabel.stringValue) = (redactor.inline(content.title), redactor.inline(content.agentName))
        titleLabel.toolTip = titleLabel.stringValue
        textView.setAccessibilityLabel("\(selectedTab.title) — \(titleLabel.stringValue)")
        var group: AgentActivityGroup?
        if case .agent = content.subject, selectedTab == .output { group = content.group }
        nestedCard.isHidden = group == nil
        if let group { nestedCard.configure(group: group, expandedOverride: nestedExpands(group), showAll: false, now: now(), actions: actions) }
        generation += 1
        let (token, tab, showAll, date, policy) = (generation, selectedTab, showsAll, now(), redactor)
        let key = "\(content.subject)|\(tab)|\(showAll)"
        if let source = AgentInspectorFormatter.source(tab, content: content, redactor: policy).source, AgentInspectorFormatter.isLarge(source) {
            // A refresh of the shown page keeps its text until the new redaction lands; a new page shows a placeholder.
            if key != shownKey { show(AgentInspectorPage(text: "Redacting…"), generation: token, key: "") }
            guard !redacting else { return redactAgain = true }
            redacting = true
            Task.detached(priority: .userInitiated) { [weak self] in
                await self?.finishRedaction(AgentInspectorFormatter.page(tab, content: content, showAll: showAll, now: date, redactor: policy), generation: token, key: key)
            }
            return
        }
        show(AgentInspectorFormatter.page(tab, content: content, showAll: showAll, now: date, redactor: policy), generation: token, key: key)
    }
    private func finishRedaction(_ page: AgentInspectorPage, generation token: Int, key: String) {
        redacting = false; show(page, generation: token, key: key)
        guard redactAgain, let content else { return }
        redactAgain = false; apply(content, requested: nil, keepTab: true)
    }
    private func show(_ page: AgentInspectorPage, generation token: Int, key: String) {
        guard token == generation else { return }
        self.page = page
        let old = textView.string
        if page.text != old {
            // Streaming output of the same page appends, keeping the reader's selection and scroll.
            if key == shownKey, !old.isEmpty, page.text.hasPrefix(old), let storage = textView.textStorage {
                storage.append(NSAttributedString(string: String(page.text.dropFirst(old.count)), attributes: storage.attributes(at: 0, effectiveRange: nil)))
            } else {
                textView.string = page.text
            }
        }
        shownKey = key
        textView.isSelectable = selectedTab != .reasoning || allowsReasoningExport()
        updateChips(page)
        view.needsLayout = true
    }
    /// Rebuilds the chips only when they change, so streaming renders don't churn subviews.
    private func updateChips(_ page: AgentInspectorPage) {
        var specs: [(title: String, id: String, help: String?)] = page.redacted ? [("redacted", "redacted", "Secret values were masked.")] : []
        if page.truncatedLines > 0 { specs.append(("truncated · show all", "truncated", "\(page.truncatedLines) more lines")) }
        specs += page.notices.map { ($0.chip.title, $0.chip.identifier, nil) }
        let signature = specs.map { "\($0.id)|\($0.title)|\($0.help ?? "")" }
        guard signature != chipSignature else { return }
        chipSignature = signature
        chips.forEach { $0.removeFromSuperview() }
        chips = specs.map { AgentInspectorChip(title: $0.title, identifier: $0.id, help: $0.help, interactive: $0.id == "truncated") }
        chips.forEach { chip in (chip.target, chip.action) = chip.isInteractive ? (self, #selector(showAllClicked)) : (nil, nil) }
        chips.forEach(view.addSubview)
    }
    /// The Actions menu is built when it opens, keeping `availableActions` off the render path.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Actions", action: nil, keyEquivalent: "")
        for action in availableActions {
            let item = menu.addItem(withTitle: action.rawValue, action: #selector(menuAction(_:)), keyEquivalent: "")
            (item.target, item.representedObject) = (self, action.rawValue)
        }
    }
    /// CockpitTypography is zoom-aware; rebuilds fonts and chips when the UI zoom changes.
    @objc private func zoomChanged() {
        (titleLabel.font, agentLabel.font) = (CockpitTypography.font(size: 13, weight: .semibold), CockpitTypography.font(size: 12))
        (textView.font, chipSignature) = (CockpitTypography.font(size: 12, monospaced: true), [])
        page.map(updateChips)
        view.needsLayout = true
    }
    /// The failed child an agent subject can ask to continue (§3.4).
    private var failedChild: String? {
        guard case .agent(let child)? = subject, case .subagent(let card)? = content?.item?.content, card.lifecycle == .failed else { return nil }
        return child
    }
    var availableActions: [Action] {
        guard let content else { return [] }
        let allowed = allowsReasoningExport()
        func has(_ tab: AgentInspectorTab) -> Bool { tabs.contains(tab) && AgentInspectorFormatter.source(tab, content: content, redactor: redactor).source != nil }
        let reveals = [AgentInspectorTab.input, .output].contains(selectedTab) || (selectedTab == .reasoning && allowed)
        let candidates: [(Action, Bool)] = [
            (.copyInput, has(.input)), (.copyOutput, has(.output)), (.copyUnredacted, reveals && has(selectedTab)),
            (.exportStepJSON, content.item != nil), (.exportRunTrace, true),
            (.exportReasoning, allowed && AgentInspectorFormatter.reasoningText(content) != nil), (.askToContinue, failedChild != nil),
            (.showRun, subject != .run),
        ]
        return candidates.filter(\.1).map(\.0)
    }
    func perform(_ action: Action) {
        guard let content, availableActions.contains(action) else { return }
        let (allowed, policy, date) = (allowsReasoningExport(), redactor, now())
        func name(_ base: String, _ suffix: String, _ ext: String) -> String {
            AgentInspectorFormatter.sanitizedFileName("\(policy.inline(base)) \(suffix)", pathExtension: ext)
        }
        switch action {
        case .copyInput, .copyOutput:
            let tab: AgentInspectorTab = action == .copyInput ? .input : .output
            let make: @Sendable () -> String = { AgentInspectorFormatter.page(tab, content: content, showAll: true, now: date, redactor: policy).text }
            guard AgentInspectorFormatter.source(tab, content: content, redactor: policy).source.map(AgentInspectorFormatter.isLarge) == true else {
                return writePasteboard(make(), false)
            }
            Task.detached(priority: .userInitiated) { [weak self] in await self?.copyRedacted(make()) }
        case .copyUnredacted:
            guard let source = AgentInspectorFormatter.source(selectedTab, content: content, redactor: policy).source else { return }
            writePasteboard(AgentInspectorFormatter.rawText(source), true)
        case .exportStepJSON:
            guard let item = content.item else { return }
            let detail = content.detail
            save(name: name(content.title, "step", "json")) { AgentRunTrace.prettyData(AgentRunTrace.stepJSON(item: item, detail: detail, includeReasoning: allowed, redactor: policy)) }
        case .exportRunTrace:
            let file = name(content.agentName, "run trace", "json")
            if let run = runTraceSource?() {
                return save(name: file) {
                    AgentRunTrace.prettyData(AgentRunTrace.json(transcript: run.transcript, agentName: run.agentName, includeReasoning: allowed, redactor: policy))
                }
            }
            let trace = makeRunTrace(allowed)
            if trace != .null { save(name: file) { AgentRunTrace.prettyData(trace) } }
        case .exportReasoning:
            guard allowed, let text = AgentInspectorFormatter.reasoningText(content) else { return }
            save(name: name(content.title, "reasoning", "txt")) { Data(policy.output(text, nil).text.utf8) }
        case .askToContinue:
            failedChild.map(actions.askToContinue)
        case .showRun:
            actions.openInspector(.run, .meta)
        }
    }
    private func copyRedacted(_ text: String) { writePasteboard(text, false) }
    /// Asks where to save first; the document is built and redacted off the main actor only after a URL is chosen.
    private func save(name: String, build: @escaping @Sendable () -> Data) {
        let completion: (URL?) -> Void = { [weak self] url in
            guard let url else { return }
            Task.detached(priority: .userInitiated) { [weak self] in await self?.finishSave(build(), to: url) }
        }
        if let chooseSaveURL { return chooseSaveURL(name, completion) }
        let panel = NSSavePanel()
        (panel.nameFieldStringValue, panel.allowedContentTypes, panel.canCreateDirectories) = (name, [name.hasSuffix(".json") ? .json : .plainText], true)
        let handler: (NSApplication.ModalResponse) -> Void = { completion($0 == .OK ? panel.url : nil) }
        if let window = view.window { panel.beginSheetModal(for: window, completionHandler: handler) } else { panel.begin(completionHandler: handler) }
    }
    private func finishSave(_ data: Data, to url: URL) {
        do { try writeFile(data, url) } catch { view.window.map { NSAlert(error: error).beginSheetModal(for: $0) } }
    }
    /// Concealed copies also carry `concealedType` so clipboard managers skip recording them.
    static func write(_ string: String, concealed: Bool, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.declareTypes(concealed ? [.string, concealedType] : [.string], owner: nil)
        pasteboard.setString(string, forType: .string)
        if concealed { pasteboard.setString(string, forType: concealedType) }
    }
    @objc private func menuAction(_ sender: NSMenuItem) { (sender.representedObject as? String).flatMap(Action.init(rawValue:)).map(perform) }
    @objc private func closeClicked() { dismiss() }
    @objc private func showAllClicked() { showAll() }
    private func layoutDrawer() {
        guard let host, view.superview === host else { return }
        let bounds = host.bounds
        let width = Self.drawerWidth(preferred: preferredWidth, hostWidth: bounds.width)
        view.frame = NSRect(x: isPresented ? bounds.maxX - width : bounds.maxX, y: bounds.minY, width: width, height: bounds.height)
        scrim.interceptsClicks = bounds.width < Self.narrowHostWidth
    }
    /// 0.18 s ease-out slide; instant under Reduce Motion or a hidden window.
    private func slide(presenting: Bool) {
        scrim.isHidden = !presenting
        guard let host, view.superview === host else { return view.isHidden = !presenting }
        let (token, start) = (generation, view.frame)
        view.isHidden = false
        layoutDrawer()
        let target = view.frame
        guard !AgentChatMotion.reduceMotion(), host.window?.isVisible == true else { return view.isHidden = !presenting }
        // Present slides in from the trailing edge; dismiss slides out from where the drawer sat.
        view.frame = presenting ? target.offsetBy(dx: host.bounds.maxX - target.minX, dy: 0) : start
        NSAnimationContext.runAnimationGroup { context in
            context.duration = AgentChatMotion.duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().frame = target
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { if let self, !presenting, !self.isPresented, self.generation == token { self.view.isHidden = true } }
        }
    }
    private func layoutContent() {
        let bounds = view.bounds
        let (inset, left) = (CGFloat(12), AgentInspectorResizeHandle.width + 6)
        let width = max(0, bounds.width - left - inset)
        handle.frame = NSRect(x: 0, y: 0, width: AgentInspectorResizeHandle.width, height: bounds.height)
        closeButton.frame = NSRect(x: bounds.maxX - inset - 20, y: inset + 4, width: 20, height: 20)
        let actionsWidth = min(actionsButton.intrinsicContentSize.width, width / 2)
        actionsButton.frame = NSRect(x: closeButton.frame.minX - 6 - actionsWidth, y: inset + 2, width: actionsWidth, height: 24)
        let titleWidth = max(0, actionsButton.frame.minX - 8 - left)
        let (titleHeight, agentHeight) = (ceil(titleLabel.intrinsicContentSize.height), ceil(agentLabel.intrinsicContentSize.height))
        titleLabel.frame = NSRect(x: left, y: inset, width: titleWidth, height: titleHeight)
        agentLabel.frame = NSRect(x: left, y: inset + titleHeight + 1, width: titleWidth, height: agentHeight)
        var y = inset + titleHeight + agentHeight + 8
        if !tabControl.isHidden {
            tabControl.frame = NSRect(x: left, y: y, width: width, height: max(22, tabControl.fittingSize.height))
            y = tabControl.frame.maxY + 8
        }
        var (x, rowHeight) = (left, CGFloat(0))
        for chip in chips {
            let size = chip.intrinsicContentSize
            let chipWidth = min(size.width, width)
            if x > left, x + chipWidth > left + width { (x, y) = (left, y + rowHeight + 4) }
            chip.frame = NSRect(x: x, y: y, width: chipWidth, height: size.height)
            (x, rowHeight) = (x + chipWidth + 6, max(rowHeight, size.height))
        }
        if !chips.isEmpty { y += rowHeight + 8 }
        if !nestedCard.isHidden, let group = content?.group {
            let expands = nestedExpands(group)
            if nestedCard.presentation?.expanded != expands { nestedCard.configure(group: group, expandedOverride: expands, showAll: false, now: now(), actions: actions) }
            let height = min(ActivityCardView.height(group: group, expandedOverride: expands, showAll: false, width: width), bounds.height / 2)
            nestedCard.frame = NSRect(x: left, y: y, width: width, height: height)
            y = nestedCard.frame.maxY + 8
        }
        scrollView.frame = NSRect(x: left - 4, y: y, width: width + 4, height: max(0, bounds.height - y - inset))
    }
    /// The agent's nested card opens only when it fits half the drawer; otherwise it shows its one-line receipt, never clipped.
    private func nestedExpands(_ group: AgentActivityGroup) -> Bool { view.bounds.height <= 0 || ActivityCardView.height(group: group, expandedOverride: true,
        showAll: false, width: max(0, view.bounds.width - AgentInspectorResizeHandle.width - 18)) <= view.bounds.height / 2 }
    /// Tab cycles only among the drawer's controls while it is open.
    func cycleFocus(backward: Bool) {
        guard let window = view.window else { return }
        let candidates: [NSView] = [closeButton, actionsButton, tabControl.control] + chips.filter(\.isInteractive) + [textView]
        let views = candidates.filter { !$0.isHiddenOrHasHiddenAncestor && ($0 === textView ? textView.isSelectable : $0.canBecomeKeyView) }
        guard !views.isEmpty else { window.makeFirstResponder(view); return }
        let current = window.firstResponder as? NSView
        let index = views.firstIndex { current === $0 || current?.isDescendant(of: $0) == true }
        let next = index.map { (backward ? $0 - 1 + views.count : $0 + 1) % views.count } ?? (backward ? views.count - 1 : 0)
        window.makeFirstResponder(views[next])
    }
}

// MARK: - Drawer parts

/// The drawer root. Esc closes and Tab cycles within the drawer, wherever focus sits in it.
final class AgentInspectorDrawerView: NSView {
    var onLayout: () -> Void = {}
    var onEscape: () -> Void = {}
    var onTab: (Bool) -> Void = { _ in }
    private let border = CALayer()
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func layout() { super.layout(); border.frame = CGRect(x: 0, y: 0, width: 1, height: bounds.height); onLayout() }
    override func updateLayer() {
        layer?.backgroundColor = AgentChatPalette.color(.card).cgColor
        border.backgroundColor = AgentChatPalette.color(.cardBorder).cgColor
        if border.superlayer == nil { layer?.addSublayer(border) }
    }
    override func keyDown(with event: NSEvent) { if !handleKey(event) { super.keyDown(with: event) } }
    override func cancelOperation(_ sender: Any?) { onEscape() }
    /// Esc (53) closes; Tab (48) / Shift-Tab cycles.
    func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { onEscape() } else if event.keyCode == 48 { onTab(event.modifierFlags.contains(.shift)) } else { return false }
        return true
    }
}

/// Monospaced Inspector text; forwards Esc and Tab to the drawer.
final class AgentInspectorTextView: NSTextView {
    private var drawer: AgentInspectorDrawerView? { enclosingScrollView?.superview as? AgentInspectorDrawerView }
    override func keyDown(with event: NSEvent) { if drawer?.handleKey(event) != true { super.keyDown(with: event) } }
    override func cancelOperation(_ sender: Any?) { drawer?.onEscape() }
}

final class AgentInspectorResizeHandle: NSView {
    static let width: CGFloat = 6
    var onBegin: () -> Void = {}
    /// Horizontal drag distance since `onBegin` (negative widens the drawer).
    var onDrag: (CGFloat) -> Void = { _ in }
    private var startX: CGFloat = 0
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.splitter)
        setAccessibilityLabel("Resize Inspector"); setAccessibilityIdentifier("agent-chat.inspector.resize")
    }
    required init?(coder: NSCoder) { nil }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDragged(with event: NSEvent) { onDrag(event.locationInWindow.x - startX) }
    override func accessibilityPerformIncrement() -> Bool { nudge(-24) }
    override func accessibilityPerformDecrement() -> Bool { nudge(24) }
    override func mouseDown(with event: NSEvent) { startX = event.locationInWindow.x; onBegin() }
    private func nudge(_ delta: CGFloat) -> Bool { onBegin(); onDrag(delta); return true }
}

/// Covers the host behind the drawer; catches outside clicks only when narrow.
final class AgentInspectorScrim: NSView {
    var onResize: () -> Void = {}
    var onClickOutside: () -> Void = {}
    var interceptsClicks = false
    override func hitTest(_ point: NSPoint) -> NSView? { interceptsClicks ? super.hitTest(point) : nil }
    override func mouseDown(with event: NSEvent) { onClickOutside() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); onResize() }
}

/// A pill naming what the policy did; "truncated · show all" is a button.
final class AgentInspectorChip: NSButton {
    let isInteractive: Bool
    init(title: String, identifier: String, help: String?, interactive: Bool = false) {
        isInteractive = interactive
        super.init(frame: .zero)
        (isBordered, wantsLayer, refusesFirstResponder, toolTip) = (false, true, !interactive, help)
        let color = AgentChatPalette.color(interactive ? .live : .textMuted)
        attributedTitle = NSAttributedString(string: title, attributes: [.font: CockpitTypography.font(size: 11, weight: .medium), .foregroundColor: color])
        setAccessibilityLabel(title); setAccessibilityHelp(help); setAccessibilityIdentifier("agent-chat.inspector.chip.\(identifier)")
        if !interactive { setAccessibilityRole(.staticText) }
    }
    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override var intrinsicContentSize: NSSize { let size = attributedTitle.size(); return NSSize(width: ceil(size.width) + 16, height: max(18, ceil(size.height) + 4)) }
    override func updateLayer() {
        layer?.cornerRadius = bounds.height / 2; layer?.borderWidth = 1
        layer?.borderColor = AgentChatPalette.color(.cardBorder).cgColor
        layer?.backgroundColor = AgentChatPalette.color(.thread).cgColor
    }
}
