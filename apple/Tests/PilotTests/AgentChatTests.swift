import Foundation
import Testing
@testable import Pilot

/// The agent chat pane drives coding-agent CLIs over the Agent Client
/// Protocol. These cover the untrusted-input boundary (framing, parsing,
/// bounds), the cross-agent normalizations that were verified against real
/// CLIs, and the full request/notification/permission loop against a scripted
/// agent so no real agent, login, or network is needed.
@Suite("Agent chat (ACP)")
struct AgentChatTests {
    // MARK: - JSON

    @Test
    func jsonDistinguishesBooleansFromNumbers() throws {
        let value = try JSONValue.parse(Data(#"{"flag":true,"one":1,"half":0.5,"nothing":null}"#.utf8))
        #expect(value["flag"] == .bool(true))
        #expect(value["one"]?.intValue == 1)
        #expect(value["one"]?.boolValue == nil)
        #expect(value["half"]?.intValue == nil)
        #expect(value["nothing"] == .null)
    }

    @Test
    func jsonSerializesIntegralNumbersWithoutFraction() throws {
        let value: JSONValue = ["id": 7]
        let data = try value.serialized()
        #expect(String(decoding: data, as: UTF8.self) == #"{"id":7}"#)
    }

    @Test
    func jsonRejectsExcessiveNesting() {
        let deep = String(repeating: "[", count: 200) + String(repeating: "]", count: 200)
        #expect(throws: JSONValueError.nestingTooDeep(limit: JSONValue.maximumDepth)) {
            try JSONValue.parse(Data(deep.utf8))
        }
    }

    // MARK: - Line framing

    @Test
    func framerJoinsLinesSplitAcrossChunks() throws {
        var framer = ACPLineFramer(maxLineBytes: 1_024)
        #expect(try framer.append(Data(#"{"a":"#.utf8)).isEmpty)
        let lines = try framer.append(Data("1}\r\n\n  \n{\"b\":2}\n{\"c\"".utf8))
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == [#"{"a":1}"#, #"{"b":2}"#])
        #expect(try framer.append(Data(":3}\n".utf8)).map { String(decoding: $0, as: UTF8.self) } == [#"{"c":3}"#])
    }

    @Test
    func framerFailsAnOversizedLineBeforeItsNewline() throws {
        var framer = ACPLineFramer(maxLineBytes: 8)
        #expect(throws: ACPLineFramer.Failure.lineTooLong(limit: 8)) {
            try framer.append(Data(String(repeating: "x", count: 9).utf8))
        }
    }

    @Test
    func framerFailsAnOversizedCompleteLine() throws {
        var framer = ACPLineFramer(maxLineBytes: 8)
        #expect(throws: ACPLineFramer.Failure.lineTooLong(limit: 8)) {
            try framer.append(Data((String(repeating: "x", count: 9) + "\n").utf8))
        }
    }

    // MARK: - Protocol parsing

    @Test
    func parsesMessageToolAndUsageUpdates() throws {
        let chunk = try #require(ACP.parseSessionUpdate(json(#"""
        {"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hi"}}}
        """#)))
        #expect(chunk == ACPSessionNotification(sessionID: "s", update: .agentMessage("Hi")))

        let tool = try #require(ACP.parseSessionUpdate(json(#"""
        {"sessionId":"s","update":{"sessionUpdate":"tool_call","toolCallId":"t","title":"Edit a.swift","kind":"edit",
         "status":"in_progress","content":[{"type":"diff","path":"a.swift","oldText":"x","newText":"y"},
         {"type":"content","content":{"type":"text","text":"done"}}]}}
        """#)))
        #expect(tool.update == .toolCall(ACPToolCallFields(
            toolCallID: "t", title: "Edit a.swift", kind: .edit, status: .inProgress, content: "Edited a.swift\ndone"
        )))

        let usage = try #require(ACP.parseSessionUpdate(json(#"""
        {"sessionId":"s","update":{"sessionUpdate":"usage_update","used":31900,"size":1000000,
         "cost":{"amount":0.12,"currency":"USD"}}}
        """#)))
        #expect(usage.update == .context(ACPContextUsage(
            usedTokens: 31_900, windowTokens: 1_000_000, costAmount: 0.12, costCurrency: "USD"
        )))
    }

    /// Shape the Claude adapter sends under the subagents RFD (captured 2026-11-05).
    @Test
    func parsesSubagentLifecycle() throws {
        let running = try #require(ACP.parseSessionUpdate(json(#"""
        {"sessionId":"root","update":{"sessionUpdate":"subagent_update","sessionId":"child",
         "title":"Count .txt files in notes/","description":"Explore","state":{"state":"running"}}}
        """#)))
        #expect(running.update == .subagent(ACPSubagentState(
            childSessionID: "child", title: "Count .txt files in notes/", detail: "Explore",
            state: "running", stopReason: nil, error: nil
        )))
    }

    @Test
    func unknownUpdateKindsAreKeptAsOther() throws {
        let other = try #require(ACP.parseSessionUpdate(json(#"""
        {"sessionId":"s","update":{"sessionUpdate":"available_commands_update","availableCommands":[]}}
        """#)))
        #expect(other.update == .other(kind: "available_commands_update"))
        #expect(ACP.parseSessionUpdate(try json(#"{"update":{"sessionUpdate":"plan"}}"#)) == nil)
    }

    /// Grok offers a cached token silently; Kimi's only method is a terminal login.
    @Test
    func agentInfoFindsOnlyNonInteractiveAuth() throws {
        let grok = ACPAgentInfo(try json(#"""
        {"agentCapabilities":{"loadSession":true},"authMethods":[{"id":"cached_token","name":"cached_token"},
         {"id":"grok.com","name":"Grok"}],"_meta":{"defaultAuthMethodId":"cached_token","agentVersion":"1.0.70"}}
        """#))
        #expect(grok.canLoadSession)
        #expect(grok.silentAuthMethodID == "cached_token")
        #expect(grok.version == "1.0.70")

        let kimi = ACPAgentInfo(try json(#"""
        {"agentCapabilities":{"loadSession":true},"authMethods":[{"id":"login","type":"terminal","name":"Login"}],
         "agentInfo":{"name":"Kimi Code CLI","version":"2.5.0"}}
        """#))
        #expect(kimi.silentAuthMethodID == nil)
        #expect(kimi.name == "Kimi Code CLI")

        let cursor = ACPAgentInfo(try json(#"""
        {"authMethods":[{"id":"cursor_login","name":"Cursor Login",
         "description":"Authenticate using existing Cursor login credentials. Run 'agent login' first if not logged in."}]}
        """#))
        #expect(cursor.silentAuthMethodID == "cursor_login")
    }

    @Test
    func modelNameComesFromWhereEachAgentPutsIt() throws {
        #expect(ACPSessionResult.modelName(try json(#"""
        {"models":{"currentModelId":"m","availableModels":[{"modelId":"m","name":"Model M"}]}}
        """#)) == "Model M")
        #expect(ACPSessionResult.modelName(try json(#"""
        {"configOptions":[{"id":"model","currentValue":"k3","options":[{"value":"k3","name":"kimi-k3"}]}]}
        """#)) == "kimi-k3")
        #expect(ACPSessionResult.modelName(try json(#"""
        {"_meta":{"modelState":{"currentModelId":"grok-4.7-build-fast"}}}
        """#)) == "grok-4.7-build-fast")
    }

    @Test
    func permissionRequestRequiresOptions() throws {
        let request = try #require(ACPPermissionRequest(requestID: "p", params: json(#"""
        {"sessionId":"s","toolCall":{"toolCallId":"t","title":"ls notes","kind":"execute"},
         "options":[{"optionId":"a","name":"Allow","kind":"allow_once"},{"optionId":"r","name":"Reject","kind":"reject_once"}]}
        """#)))
        #expect(request.toolKind == .execute)
        #expect(request.options.map(\.kind) == [.allowOnce, .rejectOnce])
        #expect(ACPPermissionRequest(requestID: "p", params: try json(#"{"sessionId":"s","options":[]}"#)) == nil)
        #expect(ACP.permissionResult(optionID: nil) == ["outcome": ["outcome": "cancelled"]])
    }

    // MARK: - Usage normalization (figures from the 2026-11-05 probe, turn 3)

    @Test
    func claudeInputExcludesCacheReads() throws {
        let raw = try #require(ACPTurnUsage(promptResult: json(#"""
        {"stopReason":"end_turn","usage":{"inputTokens":4,"outputTokens":4,"cachedReadTokens":30100,"cachedWriteTokens":15}}
        """#)))
        let usage = try #require(NormalizedTurnUsage(raw, inputIncludesCacheReads: ChatAgent.claude.inputTokensIncludeCacheReads))
        #expect(usage.uncachedInputTokens == 4)
        #expect(usage.promptTokens == 30_119)
        #expect(try #require(usage.cacheHitRate) > 0.99)
    }

    @Test
    func grokInputIncludesCacheReads() throws {
        let raw = try #require(ACPTurnUsage(promptResult: json(#"""
        {"stopReason":"end_turn","_meta":{"usage":{"inputTokens":24100,"outputTokens":15,"cachedReadTokens":24100}}}
        """#)))
        let usage = try #require(NormalizedTurnUsage(raw, inputIncludesCacheReads: ChatAgent.grok.inputTokensIncludeCacheReads))
        #expect(usage.uncachedInputTokens == 0)
        #expect(usage.cacheHitRate == 1)
    }

    @Test
    func missingUsageIsNotInvented() throws {
        #expect(ACPTurnUsage(promptResult: try json(#"{"stopReason":"end_turn"}"#)) == nil)
        let summed = NormalizedTurnUsage(uncachedInputTokens: 1, cacheReadTokens: 2, cacheWriteTokens: 3, outputTokens: 4)
            + NormalizedTurnUsage(uncachedInputTokens: 10, cacheReadTokens: 20, cacheWriteTokens: 30, outputTokens: 40)
        #expect(summed == NormalizedTurnUsage(uncachedInputTokens: 11, cacheReadTokens: 22, cacheWriteTokens: 33, outputTokens: 44))
    }

    // MARK: - Transcript

    @Test
    func transcriptMergesChunksAndSplitsAroundTools() {
        var transcript = AgentTranscript()
        transcript.appendUser("Count files")
        transcript.apply(note("root", .agentMessage("I'll ")), rootSessionID: "root")
        transcript.apply(note("root", .agentMessage("look.")), rootSessionID: "root")
        transcript.apply(note("root", .toolCall(fields("t1", title: "ls", status: .pending))), rootSessionID: "root")
        transcript.apply(note("root", .toolCallUpdate(fields("t1", status: .completed, content: "a b"))), rootSessionID: "root")
        transcript.apply(note("root", .agentMessage("2 files.")), rootSessionID: "root")

        #expect(transcript.items.map(\.content) == [
            .user("Count files"),
            .assistant("I'll look."),
            .tool(.init(title: "ls", kind: nil, status: .completed, content: "a b")),
            .assistant("2 files."),
        ])
    }

    /// Claude and Codex announce children with subagent_update (the RFD).
    @Test
    func announcedSubagentGetsACardWithItsOwnTranscript() throws {
        var transcript = AgentTranscript()
        let running = ACPSubagentState(childSessionID: "c", title: "Explore", detail: nil, state: "running",
                                       stopReason: nil, error: nil)
        transcript.apply(note("root", .subagent(running)), rootSessionID: "root")
        transcript.apply(note("c", .toolCall(fields("t", title: "Read notes", status: .completed))), rootSessionID: "root")
        transcript.apply(note("c", .agentMessage("4")), rootSessionID: "root")
        var idle = running
        idle.state = "idle"
        idle.title = nil
        transcript.apply(note("root", .subagent(idle)), rootSessionID: "root")

        #expect(transcript.items.count == 1)
        guard case .subagent(let card) = try #require(transcript.items.first).content else {
            Issue.record("expected a subagent card")
            return
        }
        #expect(card.title == "Explore")
        #expect(card.state == "idle")
        #expect(!card.isRunning)
        #expect(transcript.children(of: "c").map(\.content).last == .assistant("4"))
    }

    /// Grok streams a child session without subagent_update.
    @Test
    func unannouncedChildSessionStillGetsACard() throws {
        var transcript = AgentTranscript()
        transcript.apply(note("root", .toolCall(fields("spawn", title: "spawn_subagent", status: .inProgress))), rootSessionID: "root")
        transcript.apply(note("grok-child", .userMessage("Count the .txt files")), rootSessionID: "root")
        transcript.apply(note("grok-child", .agentMessage("4")), rootSessionID: "root")

        #expect(transcript.items.count == 2)
        guard case .subagent(let card) = try #require(transcript.items.last).content else {
            Issue.record("expected a subagent card")
            return
        }
        #expect(card.childSessionID == "grok-child")
        #expect(card.title == "spawn_subagent")
        #expect(card.isRunning)
        #expect(transcript.children(of: "grok-child").map(\.content) == [.user("Count the .txt files"), .assistant("4")])

        transcript.finishUnreportedSubagents()
        guard case .subagent(let finished) = try #require(transcript.items.last).content else { return }
        #expect(!finished.isRunning)
    }

    @Test
    func transcriptIsBounded() {
        var transcript = AgentTranscript()
        for index in 0..<(AgentTranscript.maximumItemsPerSession + 10) {
            transcript.appendUser("message \(index)")
        }
        #expect(transcript.items.count == AgentTranscript.maximumItemsPerSession)
        #expect(transcript.items.first?.content == .user("message 10"))
    }

    // MARK: - Launching

    @Test
    func launchEnvironmentDropsParentClaudeSessionButKeepsConfiguration() {
        let environment = ChatAgentLauncher.launchEnvironment(base: [
            "CLAUDECODE": "1",
            "CLAUDE_CODE_SESSION_ID": "abc",
            "CLAUDE_CODE_USE_BEDROCK": "1",
            "PATH": "/bin",
        ])
        #expect(environment == ["CLAUDE_CODE_USE_BEDROCK": "1", "PATH": "/bin"])
    }

    @Test
    func configurationPointsAdaptersAtTheInstalledCLI() throws {
        let bin = try temporaryBin(executables: ["claude-agent-acp", "claude", "grok", "cursor-agent", "agent"])
        defer { try? FileManager.default.removeItem(at: bin) }

        let claude = try ChatAgentLauncher.configuration(
            for: .claude, workingDirectory: "/tmp", shellEnvironment: ["PATH": bin.path, "CLAUDECODE": "1"], fallbackDirectories: []
        ).get()
        #expect(claude.executable.lastPathComponent == "claude-agent-acp")
        #expect(claude.environment["CLAUDE_CODE_EXECUTABLE"] == bin.appendingPathComponent("claude").path)
        #expect(claude.environment["CLAUDECODE"] == nil)
        #expect(claude.environment["PATH"]?.hasPrefix(bin.path) == true)

        let grok = try ChatAgentLauncher.configuration(
            for: .grok, workingDirectory: "/tmp", shellEnvironment: ["PATH": bin.path], fallbackDirectories: []
        ).get()
        #expect(grok.arguments == ["agent", "stdio"])

        let cursor = try ChatAgentLauncher.configuration(
            for: .cursor, workingDirectory: "/tmp", shellEnvironment: ["PATH": bin.path], fallbackDirectories: []
        ).get()
        #expect(cursor.executable == bin.appendingPathComponent("cursor-agent"))
        #expect(cursor.arguments == ["acp"])
    }

    @Test
    func missingAdapterOrCLIExplainsWhatToInstall() throws {
        let bin = try temporaryBin(executables: ["codex-acp"])
        defer { try? FileManager.default.removeItem(at: bin) }

        let missingAdapter = ChatAgentLauncher.configuration(
            for: .claude, workingDirectory: "/tmp", shellEnvironment: ["PATH": bin.path], fallbackDirectories: []
        )
        #expect(missingAdapter.failure == .missingExecutable(
            name: "claude-agent-acp", installCommand: ChatAgent.claude.launchPlan.installCommand
        ))

        let missingCLI = ChatAgentLauncher.configuration(
            for: .codex, workingDirectory: "/tmp", shellEnvironment: ["PATH": bin.path], fallbackDirectories: []
        )
        #expect(missingCLI.failure == .missingExecutable(
            name: "codex", installCommand: try #require(ChatAgent.codex.launchPlan.wrappedCLI).installCommand
        ))
    }

    @Test
    func loginShellOutputIsReadOnlyBetweenMarkers() throws {
        let marker = "__MARK__"
        let output = Data("motd noise\n\(marker)\u{0}PATH=/opt/bin:/bin\u{0}EMPTY=\u{0}EQ=a=b\u{0}\(marker)trailing".utf8)
        let parsed = try #require(LoginShellEnvironment.parse(output, marker: marker))
        #expect(parsed == ["PATH": "/opt/bin:/bin", "EMPTY": "", "EQ": "a=b"])
        #expect(LoginShellEnvironment.parse(Data("no markers".utf8), marker: marker) == nil)
    }

    @Test
    func paneStoreRemembersAgentAndSessionPerPane() throws {
        let defaults = try #require(UserDefaults(suiteName: "AgentChatTests.\(UUID().uuidString)"))
        let pane = UUID()
        #expect(AgentChatPaneStore.agent(for: pane, defaults: defaults) == .claude)
        AgentChatPaneStore.setAgent(.kimi, for: pane, defaults: defaults)
        AgentChatPaneStore.setSessionID("k1", for: pane, agent: .kimi, defaults: defaults)
        #expect(AgentChatPaneStore.agent(for: pane, defaults: defaults) == .kimi)
        #expect(AgentChatPaneStore.agent(for: UUID(), defaults: defaults) == .kimi)
        #expect(AgentChatPaneStore.sessionID(for: pane, agent: .kimi, defaults: defaults) == "k1")
        #expect(AgentChatPaneStore.sessionID(for: pane, agent: .grok, defaults: defaults) == nil)
        AgentChatPaneStore.remove(paneID: pane, defaults: defaults)
        #expect(AgentChatPaneStore.sessionID(for: pane, agent: .kimi, defaults: defaults) == nil)
    }

    @Test
    func markdownSeparatesFencedCodeIncludingAnOpenFence() {
        #expect(AgentChatMarkdown.segments("Run:\n```sh\nls\n```\nDone.") == [.prose("Run:"), .code("ls"), .prose("Done.")])
        #expect(AgentChatMarkdown.segments("Streaming:\n```\nlet x") == [.prose("Streaming:"), .code("let x")])
    }

    @Test
    func tokenCountsAreCompact() {
        #expect(AgentChatFormat.tokens(950) == "950")
        #expect(AgentChatFormat.tokens(31_900) == "31.9k")
        #expect(AgentChatFormat.tokens(1_000_000) == "1M")
    }

    // MARK: - Connection and session against a scripted agent

    @Test
    func connectionRoutesResponsesNotificationsAndAgentRequests() async throws {
        let connection = ACPConnection()
        try await connection.start(shellAgent(#"""
        read -r _
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi"}}}}'
        printf '%s\n' 'not json from a chatty agent'
        printf '%s\n' '{"jsonrpc":"2.0","id":"p1","method":"session/request_permission","params":{"sessionId":"s","options":[]}}'
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'
        read -r reply
        printf '{"jsonrpc":"2.0","method":"echo","params":%s}\n' "$reply"
        read -r _
        """#))

        let result = try await connection.request("initialize", params: [:], timeout: .seconds(10))
        #expect(result["protocolVersion"]?.intValue == 1)

        var iterator = connection.incoming.makeAsyncIterator()
        guard case .notification(let method, _)? = await iterator.next() else {
            Issue.record("expected the session/update notification")
            return
        }
        #expect(method == "session/update")
        guard case .request(let id, let requestMethod, _)? = await iterator.next() else {
            Issue.record("expected the permission request")
            return
        }
        #expect(id == "p1")
        #expect(requestMethod == "session/request_permission")

        await connection.respond(to: id, result: ACP.permissionResult(optionID: "yes"))
        guard case .notification("echo", let echoed)? = await iterator.next() else {
            Issue.record("expected the agent to echo Cockpit's reply")
            return
        }
        #expect(echoed["id"] == "p1")
        #expect(echoed["result"]?["outcome"]?["optionId"] == "yes")
        await connection.terminate()
        #expect(await connection.closeReason == .closedByClient)
    }

    @Test
    func agentExitFailsPendingRequests() async throws {
        let connection = ACPConnection()
        try await connection.start(shellAgent("read -r _; echo 'fatal: no auth' >&2; exit 3"))
        await #expect {
            _ = try await connection.request("initialize", params: [:], timeout: .seconds(10))
        } throws: { error in
            guard case .exited(_, let diagnostics) = error as? ACPConnectionError else { return false }
            return diagnostics.contains("fatal: no auth")
        }
    }

    @Test
    func oversizedAgentOutputClosesTheConnection() async throws {
        let connection = ACPConnection(maxLineBytes: 64)
        try await connection.start(shellAgent("read -r _; printf '%0200d' 0; read -r _"))
        await #expect(throws: ACPConnectionError.lineTooLong(limit: 64)) {
            _ = try await connection.request("initialize", params: [:], timeout: .seconds(10))
        }
        await connection.terminate()
    }

    @MainActor
    @Test
    func sessionRunsATurnWithPermissionAndUsage() async throws {
        let defaults = try #require(UserDefaults(suiteName: "AgentChatTests.\(UUID().uuidString)"))
        let paneID = UUID()
        let launch = shellAgent(#"""
        read -r _
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":false}}}'
        read -r _
        printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s1","models":{"currentModelId":"m1","availableModels":[{"modelId":"m1","name":"Model One"}]}}}'
        read -r _
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hello"}}}}'
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Read README.md","kind":"read","status":"pending"}}}'
        printf '%s\n' '{"jsonrpc":"2.0","id":"p1","method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"t1","title":"Read README.md","kind":"read"},"options":[{"optionId":"yes","name":"Allow","kind":"allow_once"},{"optionId":"no","name":"Reject","kind":"reject_once"}]}}'
        read -r reply
        case "$reply" in *'"optionId":"yes"'*) status=completed ;; *) status=failed ;; esac
        printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call_update","toolCallId":"t1","status":"%s"}}}\n' "$status"
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"usage_update","used":1200,"size":200000}}}'
        printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn","usage":{"inputTokens":10,"outputTokens":5,"cachedReadTokens":990,"cachedWriteTokens":0}}}'
        read -r _
        """#)
        let session = AgentChatSession(
            paneID: paneID,
            agent: .claude,
            workingDirectory: NSTemporaryDirectory(),
            defaults: defaults,
            resolveLaunch: { _, _ in .success(launch) }
        )
        defer { session.shutDown() }

        session.start()
        try await waitUntil { session.phase == .ready }
        #expect(session.modelName == "Model One")
        #expect(AgentChatPaneStore.sessionID(for: paneID, agent: .claude, defaults: defaults) == "s1")

        session.draft = "Summarize the README"
        session.send()
        #expect(session.phase == .prompting)
        try await waitUntil { session.pendingPermission != nil }
        let request = try #require(session.pendingPermission)
        #expect(request.title == "Read README.md")
        session.answerPermission(request, optionID: "yes")

        try await waitUntil {
            session.phase == .ready && session.lastTurnUsage != nil && session.context != nil
                && session.transcript.items.contains { $0.content == .tool(.init(
                    title: "Read README.md", kind: .read, status: .completed, content: ""
                )) }
        }
        #expect(session.transcript.items.first?.content == .user("Summarize the README"))
        #expect(session.transcript.items.contains { $0.content == .assistant("Hello") })
        #expect(session.lastTurnUsage?.cacheHitRate == 0.99)
        #expect(session.context?.usedTokens == 1_200)
        #expect(session.pendingPermission == nil)
    }

    /// Reopening a pane replays its saved session; the replay streams before
    /// the load response, so the root session must already be known.
    @MainActor
    @Test
    func sessionReplaysSavedConversationOnLoad() async throws {
        let defaults = try #require(UserDefaults(suiteName: "AgentChatTests.\(UUID().uuidString)"))
        let paneID = UUID()
        AgentChatPaneStore.setSessionID("saved-1", for: paneID, agent: .kimi, defaults: defaults)
        let launch = shellAgent(#"""
        read -r _
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true}}}'
        read -r load
        case "$load" in *'"sessionId":"saved-1"'*) ;; *) exit 9 ;; esac
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"saved-1","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Earlier question"}}}}'
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"saved-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Earlier answer"}}}}'
        printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":null}'
        read -r _
        """#)
        let session = AgentChatSession(
            paneID: paneID, agent: .kimi, workingDirectory: NSTemporaryDirectory(), defaults: defaults,
            resolveLaunch: { _, _ in .success(launch) }
        )
        defer { session.shutDown() }

        session.start()
        try await waitUntil { session.phase == .ready && session.transcript.items.count == 2 }
        #expect(session.transcript.items.map(\.content) == [.user("Earlier question"), .assistant("Earlier answer")])
        #expect(AgentChatPaneStore.sessionID(for: paneID, agent: .kimi, defaults: defaults) == "saved-1")
    }

    @MainActor
    @Test
    func rejectedLoadFallsBackToANewSession() async throws {
        let defaults = try #require(UserDefaults(suiteName: "AgentChatTests.\(UUID().uuidString)"))
        let paneID = UUID()
        AgentChatPaneStore.setSessionID("gone", for: paneID, agent: .grok, defaults: defaults)
        let launch = shellAgent(#"""
        read -r _
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true}}}'
        read -r _
        printf '%s\n' '{"jsonrpc":"2.0","id":2,"error":{"code":-32002,"message":"Session not found"}}'
        read -r _
        printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"sessionId":"fresh"}}'
        read -r _
        """#)
        let session = AgentChatSession(
            paneID: paneID, agent: .grok, workingDirectory: NSTemporaryDirectory(), defaults: defaults,
            resolveLaunch: { _, _ in .success(launch) }
        )
        defer { session.shutDown() }

        session.start()
        try await waitUntil { session.phase == .ready }
        #expect(AgentChatPaneStore.sessionID(for: paneID, agent: .grok, defaults: defaults) == "fresh")
        #expect(session.transcript.items.isEmpty)
    }

    @MainActor
    @Test
    func sessionReportsSetupIssueWithoutLaunching() async throws {
        let session = AgentChatSession(
            paneID: UUID(),
            agent: .codex,
            workingDirectory: NSTemporaryDirectory(),
            defaults: try #require(UserDefaults(suiteName: "AgentChatTests.\(UUID().uuidString)")),
            resolveLaunch: { _, _ in .failure(.missingExecutable(name: "codex-acp", installCommand: "npm i")) }
        )
        session.start()
        try await waitUntil { session.phase != .starting }
        #expect(session.phase == .needsSetup(.missingExecutable(name: "codex-acp", installCommand: "npm i")))

        let noRoot = AgentChatSession(paneID: UUID(), agent: .grok, workingDirectory: nil)
        noRoot.start()
        #expect(noRoot.phase == .needsSetup(.noWorkingDirectory))
    }

    // MARK: - Helpers

    private func json(_ text: String) throws -> JSONValue {
        try JSONValue.parse(Data(text.utf8))
    }

    private func note(_ session: String, _ update: ACPUpdate) -> ACPSessionNotification {
        ACPSessionNotification(sessionID: session, update: update)
    }

    private func fields(
        _ id: String, title: String? = nil, status: ACPToolStatus? = nil, content: String? = nil
    ) -> ACPToolCallFields {
        ACPToolCallFields(toolCallID: id, title: title, kind: nil, status: status, content: content)
    }

    /// A fake ACP agent: a POSIX shell script using only builtins.
    private func shellAgent(_ script: String) -> ACPConnection.LaunchConfiguration {
        ACPConnection.LaunchConfiguration(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            environment: [:],
            currentDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
        )
    }

    private func temporaryBin(executables: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentChatTests-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in executables {
            let path = bin.appendingPathComponent(name).path
            FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8),
                                           attributes: [.posixPermissions: 0o755])
        }
        return bin
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(10),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("condition not met within \(timeout)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
