import Foundation
import Testing
@testable import Pilot

// MARK: - Session: ordered barrier, turns, steer, queue, approvals

/// Session behavior against scripted shell agents. Each script writes
/// notifications and the response they precede in one write, so ordering
/// bugs between the response and the event loop show up deterministically.
@Suite("Agent chat session (barrier, steer, queue, approvals)")
@MainActor
struct AgentChatSessionTests {
    @Test
    func loadAndPromptCompleteOnlyAfterEarlierNotifications() async throws {
        let defaults = try #require(UserDefaults(suiteName: "AgentChatSessionTests.\(UUID().uuidString)"))
        let paneID = UUID()
        AgentChatPaneStore.setSessionID("saved-1", for: paneID, agent: .claude, defaults: defaults)
        let session = makeSession(defaults: defaults, paneID: paneID, script(loadSession: true, sessionID: "saved-1", #"""
        printf '%s\n%s\n%s\n' "$(user_chunk 'Earlier question')" "$(chunk 'Earlier answer')" '{"jsonrpc":"2.0","id":2,"result":null}'
        read -r _
        printf '%s\n%s\n%s\n%s\n' "$(chunk Hello)" "$(tool t1 completed)" "$(chunk ' world')" "$(stop 3 end_turn)"
        read -r _
        """#))
        defer { session.shutDown() }

        session.start()
        try await waitUntil { session.phase == .ready }
        #expect(session.transcript.items.map(\.content) == [.user("Earlier question"), .assistant("Earlier answer")])
        #expect(session.transcript.isReplaying)

        session.draft = "Next"
        session.send()
        #expect(!session.transcript.isReplaying)
        try await waitUntil { session.phase == .ready }
        #expect(session.transcript.items.last?.content == .assistant(" world"))
        let finished = try #require(session.diagnostics.lastIndex(of: .turnFinished(stopReason: "end_turn")))
        // The prompt's own barrier, not only the load's, gates the turn's end.
        #expect(session.diagnostics.filter { if case .barrierReached = $0 { true } else { false } }.count == 2)
        #expect({ if case .barrierReached = session.diagnostics[finished - 1] { true } else { false } }())
    }

    @Test
    func everyPromptOutcomeFinishesTheTurnAndAFailureOffersSendAgain() async throws {
        let session = makeSession(script(#"""
        read -r _; stop 3 end_turn
        read -r _; stop 4 refusal
        read -r _; stop 5 max_tokens
        read -r _; stop 6 cancelled
        read -r _; printf '%s\n' '{"jsonrpc":"2.0","id":7,"error":{"code":-32603,"message":"boom"}}'
        read -r again; has "$again" '"text":"p5"' && exit 0; exit 9
        """#))
        defer { session.shutDown() }
        session.start()
        try await waitUntil { session.phase == .ready }

        for (index, reason) in ["end_turn", "refusal", "max_tokens", "cancelled"].enumerated() {
            session.draft = "p\(index + 1)"
            session.send()
            try await waitUntil { session.phase == .ready }
            #expect(session.diagnostics.last == .turnFinished(stopReason: reason))
        }
        session.draft = "p5"
        session.send()
        try await waitUntil { session.phase == .ready }
        #expect(session.diagnostics.last == .turnFinished(stopReason: nil))
        #expect(session.transcript.items.last?.content == .notice(redactInline("boom")))
        #expect(session.sendAgainNoticeKey == session.transcript.items.last?.key)
        #expect(session.canSendAgain)

        session.draft = "unsent"
        session.sendAgain()
        #expect(session.phase == .prompting)
        #expect(session.draft == "unsent")
        #expect(session.transcript.items.last?.content == .user("p5"))
        try await waitUntil { if case .failed = session.phase { true } else { false } }
        #expect(session.phase == .failed(redactInline(ACPConnectionError.exited(status: 0, diagnostics: "").localizedDescription)))
        #expect(session.diagnostics.filter { if case .turnFinished = $0 { true } else { false } }.count == 6)
    }

    @Test
    func restartAndSwitchAgentFinishTheTurnAndStopOpenApprovals() async throws {
        let defaults = try #require(UserDefaults(suiteName: "AgentChatSessionTests.\(UUID().uuidString)"))
        let session = makeSession(defaults: defaults, script(#"""
        read -r _; ask '"r1"' s1; read -r _
        """#))
        defer { session.shutDown() }
        session.start()
        try await waitUntil { session.phase == .ready }
        session.draft = "hold"
        session.send()
        try await waitUntil { session.pendingPermission != nil }
        session.restart()
        #expect(session.diagnostics.suffix(2) == [
            .turnFinished(stopReason: "cancelled"), .approvalResolved(requestID: "r1", decision: .agentStopped),
        ])
        #expect(session.permissionQueue.isEmpty)
        #expect(record("r1", in: session)?.decision == .agentStopped)

        try await waitUntil { session.phase == .ready }
        session.draft = "hold again"
        session.send()
        session.switchAgent(to: .codex)
        #expect(session.diagnostics.filter { $0 == .turnFinished(stopReason: "cancelled") }.count == 2)
        #expect(session.queuedPrompt == nil && session.transcript.items.isEmpty)
    }

    @Test
    func steerOutcomesInjectQueueOrRestoreTheDraft() async throws {
        let session = makeSession(script(#"""
        read -r _
        read -r s; has "$s" '_session/steering' && has "$s" '"idleBehavior":"promptRequired"' || exit 9
        printf '%s\n' '{"jsonrpc":"2.0","id":4,"result":{"outcome":"injected"}}'
        read -r _; printf '%s\n' '{"jsonrpc":"2.0","id":5,"result":{"outcome":"startedNewTurn"}}'
        read -r _; printf '%s\n' '{"jsonrpc":"2.0","id":6,"error":{"code":-32601,"message":"nope"}}'
        read -r _
        read -r _; printf '%s\n' '{"jsonrpc":"2.0","id":8,"result":{"outcome":"promptRequired"}}'
        /bin/sleep 1; stop 3 end_turn
        read -r q; has "$q" '"text":"steer five"' && stop 9 end_turn
        read -r _
        """#))
        defer { session.shutDown() }
        session.steerTimeout = .milliseconds(300)
        session.start()
        try await waitUntil { session.phase == .ready }
        session.draft = "first"
        session.send()
        #expect(session.canSteer)

        session.draft = "steer one"
        session.steer(session.draft)
        #expect(session.pendingSteer == "steer one")
        #expect(session.draft.isEmpty)
        try await waitUntil { session.pendingSteer == nil }
        let steered = try #require(session.transcript.items.last)
        #expect(steered.content == .user("steer one"))
        #expect(session.steeredItemKeys == [steered.key])
        #expect(session.phase == .prompting)

        // Unknown outcome, JSON-RPC error, then no answer within steerTimeout.
        for text in ["steer two", "steer three", "steer four"] {
            session.steer(text)
            try await waitUntil { session.pendingSteer == nil }
            #expect(session.draft == text)
            #expect(session.composerError != nil)
            session.draft = ""
            session.clearComposerError()
        }

        session.steer("steer five")
        try await waitUntil { session.queuedPrompt == "steer five" }
        #expect(!session.transcript.items.contains { $0.content == .user("steer five") })
        try await waitUntil { session.phase == .ready && session.queuedPrompt == nil }
        #expect(session.transcript.items.last { if case .user = $0.content { true } else { false } }?.content == .user("steer five"))
    }

    @Test
    func queuedPromptSendsOnlyAfterEndTurnAndOtherwiseReturnsToTheDraft() async throws {
        let session = makeSession(script(#"""
        read -r _; /bin/sleep 0.5; stop 3 end_turn
        read -r q; has "$q" 'queued one' || exit 9
        read -r c; has "$c" 'session/cancel' && stop 4 cancelled
        read -r _; read -r _
        """#))
        defer { session.shutDown() }
        session.start()
        try await waitUntil { session.phase == .ready }
        session.queueForNextTurn("not running")
        #expect(session.queuedPrompt == nil)

        session.draft = "first"
        session.send()
        session.queueForNextTurn("scratch")
        session.clearQueuedPrompt()
        session.queueForNextTurn("queued zero")
        session.editQueuedPrompt()
        #expect(session.queuedPrompt == nil)
        #expect(session.draft == "queued zero")
        session.draft = "queued one"
        session.queueForNextTurn(session.draft)
        #expect(session.draft.isEmpty)
        #expect(session.queuedPrompt == "queued one")
        try await waitUntil { session.transcript.items.last?.content == .user("queued one") }
        #expect(session.phase == .prompting)

        session.queueForNextTurn("queued two")
        session.cancelTurn()
        try await waitUntil { session.phase == .ready }
        #expect(session.queuedPrompt == nil)
        #expect(session.draft == "queued two")

        session.draft = "third"
        session.send()
        session.queueForNextTurn("queued three")
        session.shutDown()
        #expect(session.queuedPrompt == nil)
        #expect(session.draft == "queued three")
    }

    @Test
    func askToRetryAndContinuePrefillRedactedTextWithoutSending() async throws {
        let secret = "ghp_" + String(repeating: "a", count: 36)
        let session = makeSession(script(#"""
        read -r _
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"subagent_update","sessionId":"c1","title":"Research ethereum","state":{"state":"running"}}}}'
        printf '%s\n%s\n' "$(tool t1 failed 'Run deploy --token \#(secret)')" "$(stop 3 end_turn)"
        read -r _
        """#))
        defer { session.shutDown() }
        session.start()
        try await waitUntil { session.phase == .ready }
        session.draft = "go"
        session.send()
        try await waitUntil { session.phase == .ready }
        #expect(session.hasBackgroundAgents)
        let itemCount = session.transcript.items.count
        let step = try #require(session.transcript.items.first { if case .tool = $0.content { true } else { false } })

        session.draft = "keep me"
        session.prefillAskToRetry(stepKey: step.key)
        #expect(session.draft.hasPrefix("keep me\n\nThe step “"))
        #expect(session.draft.hasSuffix(". Please retry it."))
        #expect(!session.draft.dropFirst(9).contains("\n"))
        if redactInline(secret) != secret { #expect(!session.draft.contains(secret)) }

        session.draft = ""
        session.prefillAskToContinue(childSessionID: "c1")
        #expect(session.draft == redactInline("The subagent “Research ethereum” stopped before finishing. Please continue its task."))
        session.prefillAskToContinue(childSessionID: "unknown")
        session.prefillAskToRetry(stepKey: "root/missing")
        #expect(session.draft.hasPrefix("The subagent"))
        #expect(session.phase == .ready)
        #expect(session.transcript.items.count == itemCount)
    }

    @Test
    func backgroundSubagentsEndWhenTheAgentProcessExits() async throws {
        let session = makeSession(script(#"""
        read -r _
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"subagent_update","sessionId":"c1","title":"Research","state":{"state":"running"}}}}'
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"c1","update":{"sessionUpdate":"tool_call","toolCallId":"ct","title":"Read a","kind":"read","status":"in_progress"}}}'
        stop 3 end_turn
        sleep 0.5
        exit 0
        """#))
        defer { session.shutDown() }
        session.start()
        try await waitUntil { session.phase == .ready }
        session.draft = "go"
        session.send()
        try await waitUntil { session.phase == .ready && session.hasBackgroundAgents }
        try await waitUntil { if case .failed = session.phase { true } else { false } }
        let card = session.transcript.items.compactMap { if case .subagent(let card) = $0.content { card } else { nil } }.first
        #expect(card?.lifecycle == .cancelled)
        #expect(session.transcript.stepStats(of: "c1").running == 0)
        #expect(!session.hasBackgroundAgents)
    }

    @Test
    func cancelRequestWithdrawsOnlyTheExactlyMatchingRequest() async throws {
        let session = makeSession(script(#"""
        read -r _
        ask 7 s1; ask '"p2"' s1; cancel '"7"'; cancel 7
        read -r r; has "$r" '"id":7' && has "$r" '-32800' && say w1
        cancel '"p2"'
        read -r r; has "$r" '"id":"p2"' && has "$r" '-32800' && say w2
        read -r _
        """#))
        defer { session.shutDown() }
        session.start()
        try await waitUntil { session.phase == .ready }
        session.draft = "go"
        session.send()
        try await waitUntil { session.transcript.items.contains { $0.content == .assistant("w1w2") } }
        #expect(session.permissionQueue.isEmpty)
        let resolved = session.diagnostics.filter { if case .approvalResolved = $0 { true } else { false } }
        #expect(resolved == [
            .approvalResolved(requestID: 7, decision: .withdrawnByAgent),
            .approvalResolved(requestID: "p2", decision: .withdrawnByAgent),
        ])
        #expect(record(7, in: session)?.decision == .withdrawnByAgent)
        #expect(record("p2", in: session)?.decision == .withdrawnByAgent)
        #expect(record("7", in: session) == nil, "A string id never matches a numeric request")
    }

    @Test
    func approvalsAreRecordedPerAgentAndResolvedOnlyOnceAnswered() async throws {
        let session = makeSession(script(#"""
        read -r _
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"subagent_update","sessionId":"c1","title":"Research","state":{"state":"running"}}}}'
        ask '"a1"' s1; ask '"a2"' c1; ask '"a3"' ghost
        read -r r; has "$r" '"id":"a1"' && has "$r" '"optionId":"yes"' && say ok1
        read -r r; has "$r" '"id":"a2"' && has "$r" 'cancelled' && say ok2
        i=0; while [ "$i" -lt 32 ]; do ask "\"o$i\"" s1; i=$((i + 1)); done
        read -r r; has "$r" '"id":"o31"' && has "$r" 'cancelled' && say ok3
        while read -r r; do has "$r" 'session/cancel' && break; done
        stop 3 cancelled
        read -r _
        """#))
        defer { session.shutDown() }
        session.start()
        try await waitUntil { session.phase == .ready }
        session.draft = "go"
        session.send()
        try await waitUntil { session.permissionQueue.count == 3 }
        #expect(session.diagnostics.suffix(3) == [
            .approvalRecorded(requestID: "a1", agentName: ChatAgent.claude.displayName),
            .approvalRecorded(requestID: "a2", agentName: redactInline("Research")),
            .approvalRecorded(requestID: "a3", agentName: AgentChatSession.untrackedSubagentName),
        ])
        // Every request, child or untracked, is a pending record in the root timeline.
        #expect(record("a1", in: session)?.agentName == ChatAgent.claude.displayName)
        #expect(record("a2", in: session)?.agentName == "Research")
        #expect(record("a2", in: session)?.sessionID == "c1")
        #expect(record("a3", in: session)?.agentName == AgentChatSession.untrackedSubagentName)
        #expect(["a1", "a2", "a3"].allSatisfy { record($0, in: session)?.decision == .pending })

        session.answerPermission(session.permissionQueue[0], optionID: "yes")
        // The agent echoes each answer it read as an assistant chunk. Approval
        // records now sit between chunks in the root list, so join every reply.
        func replies() -> String {
            session.transcript.items.compactMap { item -> String? in
                if case .assistant(let text) = item.content { text } else { nil }
            }.joined()
        }
        try await waitUntil { replies().contains("ok1") }
        try await waitUntil { session.diagnostics.contains(.approvalResolved(
            requestID: "a1", decision: .chose(optionID: "yes", name: "Allow", allows: true)
        )) }
        session.dismissPermission(session.permissionQueue[0])
        try await waitUntil { replies().contains("ok2") }
        try await waitUntil { session.diagnostics.contains(.approvalResolved(requestID: "a2", decision: .cancelledByUser)) }
        #expect(record("a1", in: session)?.decision == .chose(optionID: "yes", name: "Allow", allows: true))
        #expect(record("a2", in: session)?.decision == .cancelledByUser)

        try await waitUntil { replies().hasSuffix("ok1ok2ok3") }
        #expect(session.permissionQueue.count == AgentChatSession.maximumPendingPermissions)
        #expect(!session.diagnostics.contains(.approvalRecorded(requestID: "o31", agentName: ChatAgent.claude.displayName)))
        #expect(record("o31", in: session) == nil, "Auto-cancelled overflow requests leave no record")

        session.cancelTurn()
        try await waitUntil { session.phase == .ready }
        let stopped = session.diagnostics.filter { $0 == .approvalResolved(requestID: "a3", decision: .agentStopped)
            || $0 == .approvalResolved(requestID: "o0", decision: .agentStopped) }
        #expect(stopped.count == 2)
        #expect(record("a3", in: session)?.decision == .agentStopped)
        #expect(record("o0", in: session)?.decision == .agentStopped)
        #expect(session.diagnostics.last == .turnFinished(stopReason: "cancelled"))
        #expect(session.hasBackgroundAgents)
    }

    @Test
    func steerAnsweredAfterTheTurnEndedSendsOnlyAfterEndTurn() async throws {
        let session = makeSession(script(#"""
        read -r _
        read -r s; has "$s" '_session/steering' || exit 9
        printf '%s\n%s\n' "$(stop 3 cancelled)" '{"jsonrpc":"2.0","id":4,"result":{"outcome":"promptRequired"}}'
        read -r _; read -r _
        printf '%s\n%s\n' "$(stop 5 end_turn)" '{"jsonrpc":"2.0","id":6,"result":{"outcome":"promptRequired"}}'
        read -r q; has "$q" '"text":"late two"' && stop 7 end_turn
        read -r _
        """#))
        defer { session.shutDown() }
        session.start()
        try await waitUntil { session.phase == .ready }
        session.draft = "first"
        session.send()
        session.steer("late one")
        try await waitUntil { session.phase == .ready && session.pendingSteer == nil }
        #expect(session.draft == "late one" && session.queuedPrompt == nil)
        #expect(!session.transcript.items.contains { $0.content == .user("late one") })

        session.draft = "second"
        session.send()
        session.steer("late two")
        try await waitUntil { session.diagnostics.filter { $0 == .turnFinished(stopReason: "end_turn") }.count == 2 }
        #expect(session.transcript.items.contains { $0.content == .user("late two") })
        #expect(session.draft.isEmpty && session.queuedPrompt == nil)
    }

    @Test
    func barrierGateHandlesEarlyBarriersDuplicateWaitsAndClosure() async {
        let gate = ACPBarrierGate()
        let early = gate.makeToken()
        let late = gate.makeToken()
        #expect(early != late)
        gate.reach(early)
        #expect(await gate.wait(for: early))
        async let first = gate.wait(for: late)
        async let second = gate.wait(for: late)
        try? await Task.sleep(for: .milliseconds(50))
        gate.reach(late)
        let results = await [first, second]
        #expect(results.sorted { !$0 && $1 } == [false, true])
        gate.close()
        #expect(await !gate.wait(for: gate.makeToken()))
        gate.reopen()
        let fresh = gate.makeToken()
        gate.reach(fresh)
        #expect(await gate.wait(for: fresh))
    }

    @Test
    func connectionYieldsTheBarrierAfterEveryEarlierMessage() async throws {
        let connection = ACPConnection()
        try await connection.start(ACPConnection.LaunchConfiguration(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", #"""
            n='{"jsonrpc":"2.0","method":"note","params":{}}'
            read -r _; printf '%s\n%s\n%s\n' "$n" "$n" '{"jsonrpc":"2.0","id":1,"result":{}}'
            read -r _; printf '%s\n%s\n' "$n" '{"jsonrpc":"2.0","id":2,"error":{"code":1,"message":"no"}}'
            read -r _; printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{}}'; read -r _
            """#],
            environment: [:], currentDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
        ))
        _ = try await connection.request("a", params: [:], barrier: 10)
        await #expect(throws: ACPRemoteError.self) { _ = try await connection.request("b", params: [:], barrier: 11) }
        _ = try await connection.request("c", params: [:])
        await connection.terminate()
        var order: [String] = []
        for await event in connection.incoming {
            switch event {
            case .notification(let method, _): order.append(method)
            case .barrier(let token): order.append("barrier \(token)")
            case .request: order.append("request")
            }
        }
        #expect(order == ["note", "note", "barrier 10", "note", "barrier 11"])
    }

    @Test
    func remoteErrorMessagesAreBoundedAtAWordBoundary() {
        let secret = "ghp_" + String(repeating: "b", count: 36)
        let long = String(repeating: "x", count: ACPRemoteError.maximumMessageLength - 10) + " " + secret
        let bounded = ACPRemoteError(["code": 1, "message": .string(long)]).message
        #expect(!bounded.contains("ghp_") && bounded.hasSuffix("…"))
        #expect(bounded.count <= ACPRemoteError.maximumMessageLength + 1)
        #expect(ACPRemoteError(["code": 1, "message": "short"]).message == "short")
    }

    // MARK: Helpers

    private func makeSession(
        defaults: UserDefaults? = nil,
        paneID: UUID = UUID(),
        _ launch: ACPConnection.LaunchConfiguration
    ) -> AgentChatSession {
        AgentChatSession(
            paneID: paneID, agent: .claude, workingDirectory: NSTemporaryDirectory(),
            defaults: defaults ?? UserDefaults(suiteName: "AgentChatSessionTests.\(UUID().uuidString)") ?? .standard,
            resolveLaunch: { _, _ in .success(launch) }
        )
    }

    /// A POSIX-sh agent that advertises steering, answers initialize and
    /// session/new (or session/load, whose answer `body` writes), then runs
    /// `body` with small JSON-writing helpers.
    private func script(loadSession: Bool = false, sessionID: String = "s1", _ body: String) -> ACPConnection.LaunchConfiguration {
        let preamble = #"""
        has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
        update() { printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"SID","update":%s}}\n' "$1"; }
        chunk() { update "{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"$1\"}}"; }
        user_chunk() { update "{\"sessionUpdate\":\"user_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"$1\"}}"; }
        say() { chunk "$1"; }
        tool() { update "{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"$1\",\"title\":\"${3:-Read README.md}\",\"kind\":\"execute\",\"status\":\"$2\"}"; }
        stop() { printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"%s"}}\n' "$1" "$2"; }
        ask() { printf '{"jsonrpc":"2.0","id":%s,"method":"session/request_permission","params":{"sessionId":"%s","toolCall":{"toolCallId":"t","title":"Run it"},"options":[{"optionId":"yes","name":"Allow","kind":"allow_once"},{"optionId":"no","name":"Reject","kind":"reject_once"}]}}\n' "$1" "$2"; }
        cancel() { printf '{"jsonrpc":"2.0","method":"$/cancel_request","params":{"requestId":%s}}\n' "$1"; }
        read -r _
        printf '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":LOAD},"_meta":{"steering":{"supported":true}}}}\n'
        read -r _

        """#
            .replacingOccurrences(of: "SID", with: sessionID)
            .replacingOccurrences(of: "LOAD", with: loadSession ? "true" : "false")
        let newSession = loadSession ? "" : #"printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s1"}}'"# + "\n"
        return ACPConnection.LaunchConfiguration(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", preamble + newSession + body],
            environment: [:],
            currentDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
        )
    }

    /// The newest approval record for `requestID` in the root timeline.
    private func record(_ requestID: JSONValue, in session: AgentChatSession) -> AgentChatItem.Approval? {
        for item in session.transcript.items.reversed() {
            if case .approval(let approval) = item.content, approval.requestID == requestID { return approval }
        }
        return nil
    }

    private func waitUntil(
        timeout: Duration = .seconds(10),
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("condition not met within \(timeout)", sourceLocation: sourceLocation)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
