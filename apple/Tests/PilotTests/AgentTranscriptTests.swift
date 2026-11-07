import Foundation
import Testing
@testable import Pilot

/// Transcript model contracts: new fields, finishTurn paths, approvals,
/// bounds, and the activity events the transcript emits. Payload shapes
/// follow what each adapter sends (Claude `_meta.claudeCode`, Codex terminal
/// meta, Grok `x.ai/tool`, Kimi plain rawInput).
@Suite("Agent transcript")
struct AgentTranscriptTests {
    private let start = Date(timeIntervalSince1970: 1_000)
    private var later: Date { start.addingTimeInterval(5) }

    @Test
    func newItemFieldsDefaultToARootFirstTurnItem() {
        let item = AgentChatItem(id: "local-1", content: .notice("Stopped."))
        #expect(item.revision == 0)
        #expect(item.turnIndex == 0)
        #expect(!item.isReplayed)
        #expect(item.key == "root/local-1")
        #expect(AgentTranscript().stepDetails.isEmpty)
        #expect(AgentTranscript.maximumChildSessions == 64)
    }

    // MARK: - Parsing

    @Test
    func claudeToolCallCarriesNameInputAndLocations() throws {
        let note = try update(#"""
        {"sessionUpdate":"tool_call","toolCallId":"toolu_1","title":"Read a.swift","kind":"read","status":"pending",
         "rawInput":{"file_path":"/repo/a.swift"},"locations":[{"path":"/repo/a.swift","line":3}],
         "_meta":{"claudeCode":{"toolName":"Read"}}}
        """#)
        let fields = try toolFields(note)
        #expect(fields.toolName == "Read")
        #expect(fields.kind == .read && fields.rawKind == "read")
        #expect(fields.locations == [ACPToolLocation(path: "/repo/a.swift", line: 3)])
        #expect(fields.rawInput?.value == ["file_path": "/repo/a.swift"])
        #expect(fields.rawOutput == nil && fields.blocks == nil)
    }

    @Test
    func toolNamePrefersTheUpdateThenClaudeThenGrok() throws {
        let named = try toolFields(update(#"""
        {"sessionUpdate":"tool_call","toolCallId":"a","name":"exec_command","_meta":{"claudeCode":{"toolName":"Bash"}}}
        """#))
        #expect(named.toolName == "exec_command")
        let grok = try toolFields(update(#"""
        {"sessionUpdate":"tool_call","toolCallId":"g","title":"run_terminal_command","kind":"execute",
         "rawInput":{"command":"ls"},"_meta":{"x.ai/tool":{"name":"run_terminal_command","namespace":"builtin"}}}
        """#))
        #expect(grok.toolName == "run_terminal_command")
        let unknownKind = try toolFields(update(#"{"sessionUpdate":"tool_call","toolCallId":"u","kind":"plan_mode"}"#))
        #expect(unknownKind.kind == nil && unknownKind.rawKind == "plan_mode" && unknownKind.toolName == nil)
    }

    @Test
    func contentBlocksParseEveryShape() throws {
        let fields = try toolFields(update(#"""
        {"sessionUpdate":"tool_call_update","toolCallId":"t","content":[
          {"type":"content","content":{"type":"text","text":"ok"}},
          {"type":"content","content":{"type":"image","data":"AA=="}},
          {"type":"diff","path":"new.swift","oldText":null,"newText":"let x = 1\n"},
          {"type":"terminal","terminalId":"term-1"},
          {"type":"mystery"}]}
        """#))
        #expect(fields.blocks == [
            .text("ok"), .other(type: "image"), .diff(path: "new.swift", oldText: nil, newText: "let x = 1\n"),
            .terminal(id: "term-1"), .other(type: "mystery"),
        ])
        #expect(fields.content == "ok\nEdited new.swift")
    }

    @Test
    func contentBlocksAndLocationsAreBounded() {
        let many: [JSONValue] = (0..<70).map { _ in ["type": "content", "content": ["type": "text", "text": "x"]] }
        let longPath = String(repeating: "p", count: 4_097)
        let locations: [JSONValue] = [["path": .string(longPath)]] + (0..<70).map { ["path": .string("/f\($0)")] }
        let fields = parsedTool(["blocks": .array(many), "locations": .array(locations)])
        #expect(fields?.blocks?.count == 64)
        #expect(fields?.locations?.count == 64)
        #expect(fields?.locations?.first?.path == "/f0")

        let big = String(repeating: "a", count: 300 * 1_024)
        let text: [JSONValue] = (0..<3).map { _ in ["type": "content", "content": ["type": "text", "text": .string(big)]] }
        let diff: JSONValue = ["type": "diff", "path": "huge.txt", "oldText": .string(big), "newText": .string(big)]
        let bounded = parsedTool(["blocks": .array([diff] + text)])
        let total = bounded?.blocks?.reduce(0) { sum, block in
            switch block {
            case .text(let text): sum + text.utf8.count
            case .diff(_, let old, let new): sum + (old?.utf8.count ?? 0) + new.utf8.count
            default: sum
            }
        }
        #expect(total == ACPBounds.blockTextBytes)
        #expect(bounded?.truncatedDiffPaths == ["huge.txt"])
        #expect(bounded?.blocks?.count == 1)
    }

    @Test
    func codexTerminalMetaAndExitCodes() throws {
        let delta = try toolFields(update(#"""
        {"sessionUpdate":"tool_call_update","toolCallId":"call_1","rawInput":null,
         "_meta":{"terminal_output_delta":{"data":"On branch main\n","terminal_id":"call_1"}}}
        """#))
        #expect(delta.terminalOutputDelta == "On branch main\n")
        #expect(delta.rawInput == nil)
        let exit = try toolFields(update(#"""
        {"sessionUpdate":"tool_call_update","toolCallId":"call_1","status":"completed",
         "_meta":{"terminal_exit":{"exit_code":2,"signal":null,"terminal_id":"call_1"}},"rawOutput":{"exit_code":0}}
        """#))
        #expect(exit.exitCode == 2)
        let fallback = try toolFields(update(#"""
        {"sessionUpdate":"tool_call_update","toolCallId":"call_1","status":"failed","rawOutput":{"exit_code":127,"stderr":"nope"}}
        """#))
        #expect(fallback.exitCode == 127)
        #expect(fallback.rawOutput?.value?["stderr"] == "nope")
    }

    @Test
    func nonExecutionKindAndCancelledStatus() throws {
        let rejected = try toolFields(update(#"""
        {"sessionUpdate":"tool_call_update","toolCallId":"t","status":"failed",
         "_meta":{"claudeCode":{"toolName":"Bash","nonExecutionKind":"user-rejected"}}}
        """#))
        #expect(rejected.nonExecutionKind == "user-rejected" && rejected.status == .failed)
        let cancelled = try toolFields(update(#"{"sessionUpdate":"tool_call_update","toolCallId":"t","status":"cancelled"}"#))
        #expect(cancelled.status == .failed && cancelled.nonExecutionKind == "cancelled")
    }

    @Test
    func oversizedOrMalformedIDsAreRejected() throws {
        let longID = String(repeating: "i", count: 257)
        #expect(ACP.parseSessionUpdate(["sessionId": "s", "update": [
            "sessionUpdate": "tool_call", "toolCallId": .string(longID),
        ]]) == nil)
        #expect(ACP.parseSessionUpdate(["sessionId": "s", "update": [
            "sessionUpdate": "subagent_update", "sessionId": .string(longID),
        ]]) == nil)
    }

    @Test
    func boundedJSONKeepsSmallValuesAndAPrefixOfLargeOnes() throws {
        let small: JSONValue = ["a": "bc", "arr": [1, 2, []], "f": true, "n": -12, "x": nil, "o": [:]]
        let serialized = try small.serialized()
        #expect(small.estimatedByteCount() == serialized.count)
        let kept = ACPBoundedJSON(small)
        #expect(kept.value == small && kept.prefixText == nil && kept.truncatedBytes == nil)
        #expect(try JSONValue.parse(Data(small.boundedRendering(maximumBytes: 1_000).utf8)) == small)

        let huge: JSONValue = ["output": .string(String(repeating: "é\"", count: 200_000))]
        #expect(huge.estimatedByteCount(limit: 1_024) < 700_000)
        let bounded = ACPBoundedJSON(huge)
        #expect(bounded.value == nil)
        let prefix = try #require(bounded.prefixText)
        #expect(prefix.utf8.count <= ACPBoundedJSON.maximumBytes)
        #expect(prefix.hasPrefix(#"{"output":"é\""#))
        #expect((bounded.truncatedBytes ?? 0) > 300_000)
        #expect(bounded.retainedBytes == prefix.utf8.count)
    }

    @Test
    func estimatorStopsEarlyPastItsLimit() {
        let wide = JSONValue.array((0..<100_000).map { _ in .string(String(repeating: "x", count: 100)) })
        let estimate = wide.estimatedByteCount(limit: 1_000)
        #expect(estimate > 1_000 && estimate < 1_300)
    }

    @Test
    func utf8BoundsNeverSplitACharacter() {
        let text = String(repeating: "é", count: 10)
        #expect(text.utf8Prefix(5) == "éé")
        #expect(text.utf8Suffix(5) == "éé")
        #expect("".boundedNonEmpty(4) == nil)
        #expect("👍🏽ok".utf8Prefix(4).isEmpty)
    }

    @Test
    func thoughtChunksCarryTheirMessageID() throws {
        let note = try update(#"""
        {"sessionUpdate":"agent_thought_chunk","messageId":"m1","content":{"type":"text","text":"Checking"}}
        """#)
        #expect(note.update == .agentThought(text: "Checking", messageID: "m1"))
    }

    @Test
    func subagentStateParsesErrorsAndCancelCapability() throws {
        let failed = try update(#"""
        {"sessionUpdate":"subagent_update","sessionId":"c","capabilities":{"cancel":{}},
         "state":{"state":"idle","stopReason":"error","error":{"code":-32603,"message":"Rate limited"}}}
        """#)
        #expect(failed.update == .subagent(ACPSubagentState(
            childSessionID: "c", title: nil, detail: nil, state: "idle", stopReason: "error", error: "Rate limited",
            hasStateObject: true, canCancel: true
        )))
        let noCancel = try update(#"{"sessionUpdate":"subagent_update","sessionId":"c","capabilities":{},"state":"running"}"#)
        guard case .subagent(let state) = noCancel.update else {
            Issue.record("expected a subagent update")
            return
        }
        #expect(state.canCancel == false && !state.hasStateObject && state.state == "running")
    }

    @Test
    func permissionRequestKeepsToolContextWithinBounds() throws {
        let options = (0..<20).map { #"{"optionId":"o\#($0)","name":"Option \#($0)","kind":"allow_once"}"# }
        let params = try json(#"""
        {"sessionId":"s","toolCall":{"toolCallId":"toolu_9","title":"rm -rf build","kind":"execute",
         "rawInput":{"command":"rm -rf build"},"locations":[{"path":"/repo/build"}]},"options":[\#(options.joined(separator: ","))]}
        """#)
        let request = try #require(ACPPermissionRequest(requestID: 7, params: params))
        #expect(request.toolCallID == "toolu_9")
        #expect(request.rawInput?.value == ["command": "rm -rf build"])
        #expect(request.locations.map(\.path) == ["/repo/build"])
        #expect(request.options.count == 16)
        #expect(ACPPermissionRequest(requestID: true, params: params) == nil)
        #expect(ACPPermissionRequest(requestID: ["id": 1], params: params) == nil)
        #expect(ACPPermissionRequest(requestID: .string(String(repeating: "r", count: 257)), params: params) == nil)
    }

    @Test
    func steeringCapabilityParamsOutcomesAndCancelRequests() throws {
        #expect(ACPAgentInfo(try json(#"{"_meta":{"steering":{"supported":true}}}"#)).supportsSteering)
        #expect(!ACPAgentInfo(try json(#"{"_meta":{"steering":{"supported":"yes"}}}"#)).supportsSteering)
        #expect(ACP.steerParams(sessionID: "s", text: "Use tabs") == [
            "sessionId": "s",
            "prompt": [["type": "text", "text": "Use tabs"]],
            "_meta": ["steering": ["idleBehavior": "promptRequired"]],
        ])
        #expect(ACPSteerOutcome(["outcome": "injected"]) == .injected)
        #expect(ACPSteerOutcome(["outcome": "promptRequired", "reason": "noRunningTurn"]) == .promptRequired)
        if case .failed(let message) = ACPSteerOutcome(["outcome": "sk-secret-outcome"]) {
            #expect(!message.contains("sk-secret"))
        } else {
            Issue.record("unknown outcomes must fail")
        }
        #expect(ACP.cancelledRequestID(["requestId": 4]) == 4)
        #expect(ACP.cancelledRequestID(["requestId": "p1"]) == "p1")
        #expect(ACP.cancelledRequestID(["requestId": ["nested": 1]]) == nil)
        #expect(ACP.cancelledRequestID([:]) == nil)
    }

    // MARK: - Tool steps

    @Test
    func toolStepRecordsFieldsTimesAndEventsOnce() throws {
        var transcript = AgentTranscript()
        let started = try transcript.apply(update(#"""
        {"sessionUpdate":"tool_call","toolCallId":"toolu_1","title":"`git status`","kind":"execute","status":"pending",
         "rawInput":{"command":"git status","description":"Show status"},"_meta":{"claudeCode":{"toolName":"Bash"}}}
        """#), rootSessionID: "s", now: start)
        #expect(started == [.stepStart(key: "root/tool-toolu_1")])
        let firstRevision = try #require(transcript.items.first).revision
        var tool = try #require(tools(transcript).first)
        #expect(tool.toolCallID == "toolu_1" && tool.toolName == "Bash" && tool.subject == "git status")
        #expect(tool.startedAt == start && tool.endedAt == nil && tool.outcome == nil && tool.isRunning)

        let ended = try transcript.apply(update(#"""
        {"sessionUpdate":"tool_call_update","toolCallId":"toolu_1","status":"completed",
         "content":[{"type":"content","content":{"type":"text","text":"clean"}}],"rawOutput":"clean"}
        """#), rootSessionID: "s", now: later)
        #expect(ended == [.stepEnd(key: "root/tool-toolu_1")])
        tool = try #require(tools(transcript).first)
        #expect(tool.outcome == .completed && tool.endedAt == later && !tool.isRunning)
        let endedRevision = try #require(transcript.items.first).revision
        #expect(endedRevision > firstRevision)
        #expect(transcript.stepDetails["root/tool-toolu_1"]?.rawOutput?.value == "clean")

        let repeated = try transcript.apply(update(#"{"sessionUpdate":"tool_call_update","toolCallId":"toolu_1","status":"completed"}"#),
                                            rootSessionID: "s", now: later.addingTimeInterval(1))
        #expect(repeated.isEmpty)
        #expect(tools(transcript).first?.endedAt == later)
    }

    @Test
    func toolFirstSeenTerminalStartsAndEndsTogether() throws {
        var transcript = AgentTranscript()
        let events = try transcript.apply(update(#"""
        {"sessionUpdate":"tool_call","toolCallId":"k1","title":"ReadFile","kind":"read","status":"completed",
         "rawInput":{"path":"notes/a.txt"}}
        """#), rootSessionID: "s", now: start)
        #expect(events == [.stepStart(key: "root/tool-k1"), .stepEnd(key: "root/tool-k1")])
        let tool = try #require(tools(transcript).first)
        #expect(tool.startedAt == start && tool.endedAt == start && tool.subject == "notes/a.txt")
    }

    @Test
    func failureSummaryComesFromContentThenRawOutput() throws {
        var transcript = AgentTranscript()
        let longError = String(repeating: "x", count: 300)
        let events = try transcript.apply(update(#"""
        {"sessionUpdate":"tool_call","toolCallId":"t1","status":"failed",
         "content":[{"type":"content","content":{"type":"text","text":"```\n<tool_use_error>\#(longError)</tool_use_error>\n```"}}]}
        """#), rootSessionID: "s", now: start)
        let summary = try #require(tools(transcript).first?.errorSummary)
        #expect(summary == String(repeating: "x", count: 200))
        #expect(events.last == .stepFail(key: "root/tool-t1", summary: redactInline(summary)))

        try transcript.apply(update(#"{"sessionUpdate":"tool_call","toolCallId":"t2","status":"in_progress"}"#),
                             rootSessionID: "s", now: start)
        try transcript.apply(update(#"""
        {"sessionUpdate":"tool_call_update","toolCallId":"t2","status":"failed","rawOutput":{"exit_code":1,"stderr":"\nfatal: not a git repository\n"}}
        """#), rootSessionID: "s", now: later)
        #expect(tools(transcript).last?.errorSummary == "fatal: not a git repository")
        #expect(tools(transcript).last?.exitCode == 1)
    }

    @Test
    func nonExecutionKindsSettleAsStoppedOrRejectedNotFailed() throws {
        var transcript = AgentTranscript()
        for (id, kind) in [("a", "interrupted"), ("b", "cancelled"), ("c", "user-rejected"), ("d", "automode-denied")] {
            let events = try transcript.apply(update(#"""
            {"sessionUpdate":"tool_call","toolCallId":"\#(id)","status":"failed","_meta":{"claudeCode":{"nonExecutionKind":"\#(kind)"}}}
            """#), rootSessionID: "s", now: start)
            #expect(events.last == .stepEnd(key: "root/tool-\(id)"))
        }
        #expect(tools(transcript).map(\.outcome) == [.cancelled, .cancelled, .rejected, .rejected])
        #expect(tools(transcript).allSatisfy { $0.errorSummary == nil })
    }

    @Test
    func editsAreCountedOnceFromDiffsOnCompletion() throws {
        var transcript = AgentTranscript()
        try transcript.apply(update(#"""
        {"sessionUpdate":"tool_call","toolCallId":"e1","title":"Edit a.swift","kind":"edit","status":"pending",
         "content":[{"type":"diff","path":"a.swift","oldText":"a\nb\nc\n","newText":"a\nB\nc\nd\n"},
                    {"type":"diff","path":"a.swift","oldText":"x\n","newText":""},
                    {"type":"diff","path":"new.swift","oldText":null,"newText":"1\n2\n"}]}
        """#), rootSessionID: "s", now: start)
        #expect(tools(transcript).first?.edits.isEmpty == true)
        try transcript.apply(update(#"{"sessionUpdate":"tool_call_update","toolCallId":"e1","status":"completed"}"#),
                             rootSessionID: "s", now: later)
        #expect(tools(transcript).first?.edits == [
            AgentEditSummary(path: "a.swift", added: 2, removed: 2, created: false),
            AgentEditSummary(path: "new.swift", added: 2, removed: 0, created: true),
        ])
        try transcript.apply(update(#"""
        {"sessionUpdate":"tool_call_update","toolCallId":"e1","status":"completed",
         "content":[{"type":"diff","path":"other.swift","oldText":"","newText":"z\n"}]}
        """#), rootSessionID: "s", now: later)
        #expect(tools(transcript).first?.edits.map(\.path) == ["a.swift", "new.swift"])

        try transcript.apply(update(#"""
        {"sessionUpdate":"tool_call","toolCallId":"e2","status":"failed","content":[{"type":"diff","path":"b.swift","oldText":"a","newText":"b"}]}
        """#), rootSessionID: "s", now: later)
        #expect(tools(transcript).last?.edits.isEmpty == true)
    }

    @Test
    func lineCountsAreMultisetDifferencesWithALineCap() {
        func counts(_ old: String, _ new: String) -> [Int]? {
            AgentTranscript.lineChanges(old: old, new: new).map { [$0.added, $0.removed] }
        }
        #expect(counts("a\nb\n", "b\na\n") == [0, 0])
        #expect(counts("", "x\ny") == [2, 0])
        #expect(counts("x\nx\nx\n", "x\n") == [0, 2])
        let tooLong = String(repeating: "l\n", count: AgentTranscript.maximumDiffLines + 1)
        #expect(AgentTranscript.lineChanges(old: tooLong, new: "") == nil)
        #expect(AgentTranscript.edits(
            blocks: [.diff(path: "t", oldText: "a", newText: "b")], truncatedPaths: ["t"]
        ) == [AgentEditSummary(path: "t", added: nil, removed: nil, created: false)])
    }

    @Test
    func subjectsFollowEachAgentsInputShape() {
        let subject = AgentChatItem.ToolCall.subject(fromInput:)
        #expect(subject(["command": "git status", "description": "Show"]) == "git status")      // Claude Bash
        #expect(subject(["file_path": "/repo/a.swift"]) == "/repo/a.swift")                     // Claude Read
        #expect(subject(["command": ["bash", "-lc", "ls"], "cwd": "/repo"]) == "bash -lc ls")   // Codex argv
        #expect(subject(["cmd": "rg foo"]) == "rg foo")                                         // Codex exec_command
        #expect(subject(["path": "notes/a.txt"]) == "notes/a.txt")                              // Kimi ReadFile
        #expect(subject(["pattern": "chain|protocol", "path": "src"]) == "src")
        #expect(subject(["url": "https://example.com"]) == "https://example.com")
        #expect(subject(["command": "   "]) == nil)
        #expect(subject(nil) == nil)
        #expect(subject(["command": .string(String(repeating: "c", count: 2_000))])?.count == 512)
    }

    @Test
    func codexTerminalDeltasAppendBoundedToStepDetails() throws {
        var transcript = AgentTranscript()
        try transcript.apply(update(#"""
        {"sessionUpdate":"tool_call","toolCallId":"call_1","title":"git status","kind":"execute","status":"in_progress",
         "rawInput":{"command":"git status","cwd":"/repo"},"_meta":{"terminal_info":{"cwd":"/repo","terminal_id":"call_1"}}}
        """#), rootSessionID: "s", now: start)
        for chunk in ["On branch ", #"main\n"#] {
            try transcript.apply(update(#"""
            {"sessionUpdate":"tool_call_update","toolCallId":"call_1","_meta":{"terminal_output_delta":{"data":"\#(chunk)"}}}
            """#), rootSessionID: "s", now: start)
        }
        #expect(transcript.stepDetails["root/tool-call_1"]?.terminalOutput == "On branch main\n")
        #expect(transcript.stepDetails["root/tool-call_1"]?.rawInput?.value?["cwd"] == "/repo")

        var output = ""
        let chunk = String(repeating: "o", count: 100 * 1_024)
        for _ in 0..<4 { AgentTranscript.appendTerminal(chunk, to: &output) }
        AgentTranscript.appendTerminal("END", to: &output)
        #expect(output.utf8.count <= ACPBounds.terminalOutputBytes)
        #expect(output.hasPrefix(AgentTranscript.terminalTruncationMarker) && output.hasSuffix("oEND"))
    }

    @Test
    func reusedToolIDFromAnEarlierTurnStartsANewStep() throws {
        var transcript = AgentTranscript()
        let first = try update(#"{"sessionUpdate":"tool_call","toolCallId":"x","status":"completed"}"#)
        transcript.apply(first, rootSessionID: "s", now: start)
        try transcript.apply(update(#"{"sessionUpdate":"tool_call_update","toolCallId":"x","title":"Same turn"}"#),
                             rootSessionID: "s", now: start)
        #expect(transcript.items.count == 1 && tools(transcript).first?.title == "Same turn")

        transcript.finishTurn(stopReason: "end_turn", now: start)
        let events = try transcript.apply(update(#"{"sessionUpdate":"tool_call","toolCallId":"x","status":"in_progress"}"#),
                                          rootSessionID: "s", now: later)
        #expect(transcript.items.map(\.id) == ["tool-x", "tool-x#1"])
        #expect(events == [.stepStart(key: "root/tool-x#1")])
        #expect(transcript.items.last?.turnIndex == 1)
        try transcript.apply(update(#"{"sessionUpdate":"tool_call_update","toolCallId":"x","status":"completed"}"#),
                             rootSessionID: "s", now: later)
        #expect(tools(transcript).map(\.outcome) == [.completed, .completed])
        #expect(transcript.items.count == 2)
    }

    // MARK: - Thoughts and notices

    @Test
    func thoughtsEndAtTheNextItemAMessageIDChangeOrTheTurn() throws {
        var transcript = AgentTranscript()
        let opened = transcript.apply(thought("Checking ", messageID: "m1"), rootSessionID: "s", now: start)
        let firstKey = try #require(transcript.items.first).key
        #expect(opened == [.reasoningDelta(key: firstKey)])
        #expect(transcript.apply(thought("files", messageID: nil), rootSessionID: "s", now: start).isEmpty)
        #expect(transcript.items.count == 1)

        let switched = transcript.apply(thought("Next", messageID: "m2"), rootSessionID: "s", now: later)
        let secondKey = try #require(transcript.items.last).key
        #expect(switched == [.reasoningEnd(key: firstKey), .reasoningDelta(key: secondKey)])
        #expect(thoughts(transcript).map(\.text) == ["Checking files", "Next"])
        #expect(thoughts(transcript).first?.endedAt == later)

        let message = transcript.apply(note(.agentMessage("Done.")), rootSessionID: "s", now: later)
        #expect(message == [.reasoningEnd(key: secondKey)])

        transcript.apply(thought("More", messageID: nil), rootSessionID: "s", now: later)
        let closing = transcript.finishTurn(stopReason: "end_turn", now: later.addingTimeInterval(2))
        let lastKey = try #require(transcript.items.last).key
        #expect(closing == [.reasoningEnd(key: lastKey)])
        #expect(thoughts(transcript).allSatisfy { $0.endedAt != nil })
    }

    @Test
    func thoughtTextIsBoundedAndApprovalsDoNotCloseIt() throws {
        var transcript = AgentTranscript()
        let chunk = String(repeating: "t", count: 100 * 1_024)
        for _ in 0..<3 { transcript.apply(thought(chunk, messageID: nil), rootSessionID: "s", now: start) }
        let request = try #require(ACPPermissionRequest(requestID: 1, params: permissionParams()))
        transcript.recordApproval(request, agentName: "Claude", now: start)
        transcript.apply(thought(chunk, messageID: nil), rootSessionID: "s", now: start)
        #expect(thoughts(transcript).count == 1)
        #expect(thoughts(transcript).first?.text.utf8.count == ACPBounds.thoughtBytes)
    }

    @Test
    func codexRerouteAndHistoryGapThoughtsBecomeNotices() throws {
        var transcript = AgentTranscript()
        transcript.apply(thought("Model rerouted from gpt-a to gpt-b (capacity).\n\n", messageID: nil),
                         rootSessionID: "s", now: start)
        try transcript.apply(update(#"""
        {"sessionUpdate":"agent_thought_chunk","messageId":"s:subagent-history-gap",
         "content":{"type":"text","text":"Some recorded child history is unavailable or incomplete."}}
        """#), rootSessionID: "s", now: start)
        #expect(transcript.items.map(\.content) == [
            .notice("Model rerouted from gpt-a to gpt-b (capacity)."),
            .notice("Some recorded child history is unavailable or incomplete."),
        ])
    }

    // MARK: - Subagents

    @Test
    func announcedSubagentLifecycleTimesAndEvents() throws {
        var transcript = AgentTranscript()
        let spawned = try transcript.apply(update(#"""
        {"sessionUpdate":"subagent_update","sessionId":"c","title":"Explore","capabilities":{"cancel":{}},"state":{"state":"running"}}
        """#), rootSessionID: "s", now: start)
        #expect(spawned == [.agentSpawn(childSessionID: "c", parentKey: nil)])
        var card = try #require(subagents(transcript).first)
        #expect(card.lifecycle == .running && card.startedAt == start && card.canCancel == true)

        try transcript.apply(update(#"""
        {"sessionUpdate":"config_option_update","configOptions":[{"id":"model","category":"model","type":"select",
         "currentValue":"haiku","options":[{"value":"haiku","name":"Claude Haiku"}]}]}
        """#, session: "c"), rootSessionID: "s", now: start)
        #expect(subagents(transcript).first?.model == "Claude Haiku")

        let failed = try transcript.apply(update(#"""
        {"sessionUpdate":"subagent_update","sessionId":"c","state":{"state":"idle","stopReason":"error","error":{"code":1,"message":"boom"}}}
        """#), rootSessionID: "s", now: later)
        #expect(failed == [.agentEnd(childSessionID: "c", lifecycle: "failed")])
        card = try #require(subagents(transcript).first)
        #expect(card.lifecycle == .failed && card.endedAt == later && card.error == "boom")

        let recovered = try transcript.apply(update(#"{"sessionUpdate":"subagent_update","sessionId":"c","state":{"state":"running"}}"#),
                                             rootSessionID: "s", now: later)
        #expect(recovered == [.agentSpawn(childSessionID: "c", parentKey: nil)])
        card = try #require(subagents(transcript).first)
        #expect(card.error == nil && card.stopReason == nil && card.lifecycle == .running && card.endedAt == nil)

        try transcript.apply(update(#"{"sessionUpdate":"subagent_update","sessionId":"c","state":{"state":"idle","stopReason":"end_turn"}}"#),
                             rootSessionID: "s", now: later)
        #expect(subagents(transcript).first?.lifecycle == .done)
    }

    @Test
    func lifecycleMapsStopReasonsAndQueuedCards() throws {
        var transcript = AgentTranscript()
        try transcript.apply(update(#"{"sessionUpdate":"subagent_update","sessionId":"q","title":"Later"}"#),
                             rootSessionID: "s", now: start)
        #expect(subagents(transcript).first?.lifecycle == .queued)
        #expect(subagents(transcript).first?.startedAt == nil)
        transcript.apply(note(.agentMessage("working"), session: "q"), rootSessionID: "s", now: later)
        #expect(subagents(transcript).first?.lifecycle == .running)
        #expect(subagents(transcript).first?.startedAt == later)

        let card = AgentChatItem.Subagent(childSessionID: "x", title: "X", detail: nil, state: "idle", error: nil)
        var cancelled = card
        cancelled.stopReason = "cancelled"
        var ended = card
        ended.stopReason = nil
        #expect(cancelled.lifecycle == .cancelled && ended.lifecycle == .ended)
    }

    @Test
    func grokUnannouncedChildLinksToItsSpawnCall() throws {
        var transcript = AgentTranscript()
        try transcript.apply(update(#"""
        {"sessionUpdate":"tool_call","toolCallId":"spawn","title":"spawn_subagent","status":"in_progress",
         "rawInput":{"description":"Count files"},"_meta":{"x.ai/tool":{"name":"spawn_subagent"}}}
        """#), rootSessionID: "s", now: start)
        let spawned = transcript.apply(note(.userMessage("Count the .txt files"), session: "grok-child"), rootSessionID: "s", now: start)
        #expect(spawned == [.agentSpawn(childSessionID: "grok-child", parentKey: "root/tool-spawn")])
        let card = try #require(subagents(transcript).first)
        #expect(card.spawnToolCallID == "spawn" && card.title == "spawn_subagent" && card.lifecycle == .running)
        #expect(transcript.children(of: "grok-child").first?.sessionKey == "grok-child")

        let finished = transcript.finishTurn(stopReason: "end_turn", now: later)
        #expect(finished == [
            .stepEnd(key: "root/tool-spawn"), .agentEnd(childSessionID: "grok-child", lifecycle: "ended"),
        ])
        #expect(subagents(transcript).first?.lifecycle == .ended)
        #expect(subagents(transcript).first?.endedAt == later)
        #expect(tools(transcript).first?.outcome == .notFinished)
    }

    @Test
    func childStillReportedRunningAfterTheTurnIsBackground() throws {
        var transcript = AgentTranscript()
        try transcript.apply(update(#"{"sessionUpdate":"subagent_update","sessionId":"bg","state":{"state":"running"}}"#),
                             rootSessionID: "s", now: start)
        try transcript.apply(update(#"{"sessionUpdate":"tool_call","toolCallId":"ct","status":"in_progress"}"#, session: "bg"),
                             rootSessionID: "s", now: start)
        transcript.apply(thought("child thinking", messageID: nil, session: "bg"), rootSessionID: "s", now: start)
        try transcript.apply(update(#"{"sessionUpdate":"tool_call","toolCallId":"rt","status":"in_progress"}"#),
                             rootSessionID: "s", now: start)

        let events = transcript.finishTurn(stopReason: "cancelled", now: later)
        #expect(events == [.stepEnd(key: "root/tool-rt")])
        #expect(subagents(transcript).first?.lifecycle == .background)
        let stats = transcript.stepStats(of: "bg")
        #expect(stats.total == 1 && stats.failed == 0 && stats.running == 1)
        #expect(tools(transcript).last?.outcome == .cancelled)

        let ended = try transcript.apply(update(#"{"sessionUpdate":"subagent_update","sessionId":"bg","state":{"state":"idle","stopReason":"end_turn"}}"#),
                                         rootSessionID: "s", now: later)
        #expect(ended == [.agentEnd(childSessionID: "bg", lifecycle: "done")])
    }

    @Test
    func childSessionsBeyondTheRenderCapAreDropped() throws {
        var transcript = AgentTranscript()
        for index in 0..<(AgentTranscript.maximumChildSessions + 1) {
            try transcript.apply(update(#"{"sessionUpdate":"subagent_update","sessionId":"c\#(index)","state":{"state":"running"}}"#),
                                 rootSessionID: "s", now: start)
        }
        #expect(subagents(transcript).count == AgentTranscript.maximumChildSessions)
        let dropped = transcript.apply(note(.agentMessage("hi"), session: "c64"), rootSessionID: "s", now: start)
        #expect(dropped.isEmpty && transcript.children(of: "c64").isEmpty)
        transcript.apply(note(.agentMessage("hi"), session: "c3"), rootSessionID: "s", now: start)
        #expect(transcript.children(of: "c3").count == 1)
        #expect(transcript.apply(note(.agentMessage("spoof"), session: "root"), rootSessionID: "s", now: start).isEmpty)
        #expect(transcript.children(of: "root").isEmpty)
    }

    @Test
    func stepStatsCountOnlyToolsByOutcome() throws {
        var transcript = AgentTranscript()
        for (id, status) in [("a", "completed"), ("b", "failed"), ("c", "in_progress")] {
            try transcript.apply(update(#"{"sessionUpdate":"tool_call","toolCallId":"\#(id)","status":"\#(status)"}"#, session: "kid"),
                                 rootSessionID: "s", now: start)
        }
        try transcript.apply(update(#"""
        {"sessionUpdate":"tool_call","toolCallId":"d","status":"failed","_meta":{"claudeCode":{"nonExecutionKind":"interrupted"}}}
        """#, session: "kid"), rootSessionID: "s", now: start)
        transcript.apply(note(.agentMessage("text"), session: "kid"), rootSessionID: "s", now: start)
        let stats = transcript.stepStats(of: "kid")
        #expect(stats.total == 4 && stats.failed == 1 && stats.running == 1)
    }

    // MARK: - Turns, replay, approvals, bounds

    @Test
    func finishTurnSettlesRunningToolsAndAdvancesTheTurn() throws {
        var transcript = AgentTranscript()
        transcript.appendUser("Go", now: start)
        try transcript.apply(update(#"{"sessionUpdate":"tool_call","toolCallId":"t","status":"pending"}"#),
                             rootSessionID: "s", now: start)
        let events = transcript.finishTurn(stopReason: "end_turn", now: later)
        #expect(events == [.stepEnd(key: "root/tool-t")])
        let tool = try #require(tools(transcript).first)
        #expect(tool.outcome == .notFinished && tool.endedAt == later && !tool.isRunning)
        #expect(transcript.finishTurn(stopReason: "end_turn", now: later).isEmpty)
        transcript.appendUser("Again", now: later)
        #expect(transcript.items.last?.turnIndex == 2)
        #expect(transcript.items.first?.turnIndex == 0)
    }

    @Test
    func replayRecordsNoTimesOrEventsAndSettlesOnThePrompt() throws {
        var transcript = AgentTranscript()
        transcript.isReplaying = true
        var events = transcript.apply(note(.userMessage("q1")), rootSessionID: "s", now: start)
        events += try transcript.apply(update(#"{"sessionUpdate":"tool_call","toolCallId":"old","status":"in_progress"}"#),
                                       rootSessionID: "s", now: start)
        events += transcript.apply(thought("hmm", messageID: nil), rootSessionID: "s", now: start)
        events += transcript.apply(note(.agentMessage("a1")), rootSessionID: "s", now: start)
        events += transcript.apply(note(.userMessage("q2")), rootSessionID: "s", now: start)
        #expect(events.isEmpty)
        #expect(transcript.items.allSatisfy { $0.isReplayed })
        #expect(transcript.items.map(\.turnIndex) == [0, 0, 0, 0, 1])
        #expect(tools(transcript).first?.startedAt == nil && thoughts(transcript).first?.startedAt == nil)
        #expect(tools(transcript).first?.isRunning == true)

        transcript.appendUser("live", now: later)
        #expect(!transcript.isReplaying)
        let tool = try #require(tools(transcript).first)
        #expect(tool.outcome == .notFinished && tool.endedAt == nil && !tool.isRunning)
        #expect(transcript.items.last?.isReplayed == false && transcript.items.last?.turnIndex == 2)
    }

    @Test
    func approvalsAreRecordedInTheRootAndResolvedByRequestAndSession() throws {
        var transcript = AgentTranscript()
        let params = try permissionParams()
        let numbered = try #require(ACPPermissionRequest(requestID: 1, params: params))
        let named = try #require(ACPPermissionRequest(requestID: "1", params: params))
        transcript.recordApproval(numbered, agentName: "Claude", now: start)
        transcript.recordApproval(named, agentName: "Claude", now: start)
        transcript.recordApproval(numbered, agentName: "Claude", now: start)
        let records = approvals(transcript)
        #expect(records.count == 3 && records.allSatisfy { $0.decision == .pending })
        #expect(records.first?.subject == "rm -rf build" && records.first?.toolCallID == "toolu_9")
        #expect(transcript.items.allSatisfy { $0.sessionKey == "root" })

        let chose = AgentChatItem.Approval.Decision.chose(optionID: "a", name: "Allow", allows: true)
        transcript.resolveApproval(requestID: 1, sessionID: "child", decision: chose)
        #expect(approvals(transcript).allSatisfy { $0.decision == .pending })
        transcript.resolveApproval(requestID: 1, sessionID: "s", decision: chose)
        #expect(approvals(transcript).map(\.decision) == [.pending, .pending, chose])
        transcript.resolveApproval(requestID: 1, sessionID: "s", decision: .withdrawnByAgent)
        #expect(approvals(transcript).map(\.decision) == [.withdrawnByAgent, .pending, chose])
        transcript.resolveApproval(requestID: "1", sessionID: "s", decision: .agentStopped)
        #expect(approvals(transcript).map(\.decision) == [.withdrawnByAgent, .agentStopped, chose])
    }

    @Test
    func trimDropsAChunkButKeepsPendingApprovalsAndForgetsDetails() throws {
        var transcript = AgentTranscript()
        let request = try #require(ACPPermissionRequest(requestID: 9, params: permissionParams()))
        transcript.recordApproval(request, agentName: "Claude", now: start)
        try transcript.apply(update(#"{"sessionUpdate":"tool_call","toolCallId":"t","status":"completed","rawOutput":"out"}"#),
                             rootSessionID: "s", now: start)
        #expect(transcript.stepDetails["root/tool-t"] != nil)
        for index in 0..<AgentTranscript.maximumItemsPerSession { transcript.appendNotice("n\(index)", now: start) }
        #expect(transcript.items.count == 1_801)
        #expect(transcript.items.first?.isPendingApproval == true)
        #expect(transcript.stepDetails["root/tool-t"] == nil)
    }

    @Test
    func stepDetailsEvictTheOldestSettledPastTheBudget() throws {
        var transcript = AgentTranscript()
        transcript.stepDetailByteBudget = 10_000
        let payload = String(repeating: "x", count: 3_000)
        for (id, status) in [("a", "completed"), ("b", "completed"), ("c", "completed"), ("d", "in_progress")] {
            try transcript.apply(update(#"""
            {"sessionUpdate":"tool_call","toolCallId":"\#(id)","status":"\#(status)","rawOutput":"\#(payload)"}
            """#), rootSessionID: "s", now: start)
        }
        #expect(transcript.stepDetails["root/tool-a"] == AgentStepDetail(evicted: true))
        #expect(transcript.stepDetails["root/tool-c"]?.evicted == false)
        #expect(transcript.stepDetails["root/tool-d"]?.rawOutput?.value == .string(payload))

        var running = AgentTranscript()
        running.stepDetailByteBudget = 100
        for id in ["r1", "r2"] {
            try running.apply(update(#"{"sessionUpdate":"tool_call","toolCallId":"\#(id)","status":"in_progress","rawOutput":"\#(payload)"}"#),
                              rootSessionID: "s", now: start)
        }
        #expect(running.stepDetails.values.allSatisfy { !$0.evicted })
    }

    @Test
    func everyMutationBumpsARevisionThatOnlyGrows() {
        var transcript = AgentTranscript()
        transcript.apply(note(.agentMessage("a")), rootSessionID: "s", now: start)
        let first = transcript.items[0].revision
        transcript.apply(note(.agentMessage("b")), rootSessionID: "s", now: start)
        let second = transcript.items[0].revision
        transcript.appendNotice("n", now: start)
        #expect(first > 0 && second > first && transcript.items[1].revision > second)
    }

    // MARK: - Review regressions

    @Test
    func oversizedSessionAndMessageIDsAndTerminalDeltasAreBounded() throws {
        let longID = String(repeating: "s", count: 257)
        #expect(ACP.parseSessionUpdate(["sessionId": .string(longID), "update": ["sessionUpdate": "agent_message_chunk"]]) == nil)
        #expect(ACP.parseSessionUpdate(["sessionId": "s", "update": [
            "sessionUpdate": "current_model_update", "currentModelId": .string(longID),
        ]]) == nil)
        let thought = ACP.parseSessionUpdate(["sessionId": "s", "update": [
            "sessionUpdate": "agent_thought_chunk", "messageId": .string(longID),
            "content": ["type": "text", "text": "hmm"],
        ]])
        #expect(thought?.update == .agentThought(text: "hmm", messageID: nil))

        let huge = String(repeating: "o", count: ACPBounds.terminalOutputBytes) + "TAIL"
        let delta = ACP.parseSessionUpdate(["sessionId": "s", "update": [
            "sessionUpdate": "tool_call_update", "toolCallId": "t",
            "_meta": ["terminal_output_delta": ["data": .string(huge)]],
        ]])
        guard case .toolCallUpdate(let fields)? = delta?.update else {
            Issue.record("expected a tool update")
            return
        }
        #expect(fields.terminalOutputDelta?.utf8.count == ACPBounds.terminalOutputBytes)
        #expect(fields.terminalOutputDelta?.hasSuffix("TAIL") == true)
    }

    @Test
    func failedEditSummaryIsTheErrorNotTheDiffLabel() throws {
        var transcript = AgentTranscript()
        try transcript.apply(update(#"""
        {"sessionUpdate":"tool_call","toolCallId":"e","kind":"edit","status":"failed",
         "content":[{"type":"diff","path":"b.swift","oldText":"a","newText":"b"}],
         "rawOutput":{"error":"String to replace not found in file."}}
        """#), rootSessionID: "s", now: start)
        #expect(tools(transcript).first?.errorSummary == "String to replace not found in file.")
        try transcript.apply(update(#"""
        {"sessionUpdate":"tool_call","toolCallId":"f","kind":"edit","status":"failed",
         "content":[{"type":"diff","path":"c.swift","oldText":"a","newText":"b"}]}
        """#), rootSessionID: "s", now: start)
        #expect(tools(transcript).last?.errorSummary == nil)
        #expect(AgentTranscript.summaryLine("```console\n$ make\nerror: no rule\n```") == "$ make")
    }

    @Test
    func payloadOnlyUpdatesBumpTheRevision() throws {
        var transcript = AgentTranscript()
        try transcript.apply(update(#"{"sessionUpdate":"tool_call","toolCallId":"c","status":"in_progress"}"#),
                             rootSessionID: "s", now: start)
        let before = try #require(transcript.items.first).revision
        try transcript.apply(update(#"""
        {"sessionUpdate":"tool_call_update","toolCallId":"c","_meta":{"terminal_output_delta":{"data":"line\n"}}}
        """#), rootSessionID: "s", now: start)
        #expect(try #require(transcript.items.first).revision > before)
        #expect(transcript.stepDetails["root/tool-c"]?.terminalOutput == "line\n")
    }

    @Test
    func resetKeepsRevisionsAndLocalIDsGrowing() {
        var transcript = AgentTranscript()
        transcript.appendNotice("before", now: start)
        let old = transcript.items[0]
        transcript.reset()
        #expect(transcript.items.isEmpty && transcript.turnIndex == 0)
        transcript.appendNotice("after", now: start)
        let new = transcript.items[0]
        #expect(new.revision > old.revision && new.id != old.id)
    }

    @Test
    func theRootSessionIsNeverItsOwnSubagent() throws {
        var transcript = AgentTranscript()
        let events = try transcript.apply(update(#"{"sessionUpdate":"subagent_update","sessionId":"s","state":{"state":"running"}}"#),
                                          rootSessionID: "s", now: start)
        #expect(events.isEmpty && transcript.items.isEmpty)
    }

    // MARK: - Helpers

    private func json(_ text: String) throws -> JSONValue {
        try JSONValue.parse(Data(text.utf8))
    }

    private func update(_ body: String, session: String = "s") throws -> ACPSessionNotification {
        let params = try json(#"{"sessionId":"\#(session)","update":\#(body)}"#)
        return try #require(ACP.parseSessionUpdate(params))
    }

    private func note(_ update: ACPUpdate, session: String = "s") -> ACPSessionNotification {
        ACPSessionNotification(sessionID: session, update: update)
    }

    private func thought(_ text: String, messageID: String?, session: String = "s") -> ACPSessionNotification {
        note(.agentThought(text: text, messageID: messageID), session: session)
    }

    private func toolFields(_ notification: ACPSessionNotification) throws -> ACPToolCallFields {
        switch notification.update {
        case .toolCall(let fields), .toolCallUpdate(let fields): return fields
        default: throw CancellationError()
        }
    }

    private func parsedTool(_ parts: [String: JSONValue]) -> ACPToolCallFields? {
        var update: [String: JSONValue] = ["sessionUpdate": "tool_call", "toolCallId": "t"]
        update["content"] = parts["blocks"]
        update["locations"] = parts["locations"]
        guard let note = ACP.parseSessionUpdate(["sessionId": "s", "update": .object(update)]),
              case .toolCall(let fields) = note.update else { return nil }
        return fields
    }

    private func permissionParams() throws -> JSONValue {
        try json(#"""
        {"sessionId":"s","toolCall":{"toolCallId":"toolu_9","title":"rm -rf build","kind":"execute",
         "rawInput":{"command":"rm -rf build"}},
         "options":[{"optionId":"a","name":"Allow","kind":"allow_once"},{"optionId":"r","name":"Reject","kind":"reject_once"}]}
        """#)
    }

    private func tools(_ transcript: AgentTranscript) -> [AgentChatItem.ToolCall] {
        transcript.items.compactMap { if case .tool(let tool) = $0.content { tool } else { nil } }
    }

    private func thoughts(_ transcript: AgentTranscript) -> [AgentChatItem.Thought] {
        transcript.items.compactMap { if case .thought(let thought) = $0.content { thought } else { nil } }
    }

    private func subagents(_ transcript: AgentTranscript) -> [AgentChatItem.Subagent] {
        transcript.items.compactMap { if case .subagent(let card) = $0.content { card } else { nil } }
    }

    private func approvals(_ transcript: AgentTranscript) -> [AgentChatItem.Approval] {
        transcript.items.compactMap { if case .approval(let approval) = $0.content { approval } else { nil } }
    }
}
