import Foundation
import Testing
@testable import Copilot

@Suite("Walkie recording and delivery", .serialized)
@MainActor
struct CopilotWalkieTalkieTests {
    @Test("live text renders during a hold and finalization, but only final text is sent")
    func liveTranscriptPresentationAndDelivery() async throws {
        let harness = WalkieHarness()
        let controller = harness.makeController()
        let workspaceID = UUID()
        controller.beginRecording(workspaceID: workspaceID, allowRestrictedNetwork: false)
        await harness.startEntered.wait()
        #expect(controller.displayedTranscript(liveText: "old recording").isEmpty)
        harness.startResult.resolve(true)
        try await waitForWalkie { controller.phase == .recording && harness.startedRecordingID != nil }
        let recordingID = try #require(harness.startedRecordingID)

        #expect(controller.displayedTranscript(liveText: "git stash") == "git stash")
        #expect(controller.displayedTranscript(liveText: "git status") == "git status")
        #expect(controller.transcript.isEmpty)
        #expect(harness.events == [.start(workspaceID, recordingID)])
        controller.endRecording()
        await harness.finishEntered.wait()
        #expect(controller.displayedTranscript(liveText: "git status") == "git status")
        controller.execute(workspaceID: workspaceID)
        #expect(harness.events == [.start(workspaceID, recordingID)])

        harness.finishResult.resolve("git status --short")
        try await waitForWalkie { controller.phase == .idle }
        #expect(controller.displayedTranscript(liveText: "late preview") == "git status --short")
        #expect(harness.events == [
            .start(workspaceID, recordingID), .stop(workspaceID, recordingID),
            .speech(workspaceID, recordingID, "git status --short"), .execute(workspaceID, recordingID)
        ])
    }

    @Test("release before microphone readiness never displays the previous live transcript")
    func cancelledPreparationHidesLiveText() async throws {
        let harness = WalkieHarness()
        let controller = harness.makeController()
        controller.beginRecording(workspaceID: nil, allowRestrictedNetwork: false)
        await harness.startEntered.wait()
        controller.endRecording()
        await harness.finishEntered.wait()
        #expect(controller.displayedTranscript(liveText: "previous recording").isEmpty)
        harness.finishResult.resolve("previous recording")
        try await waitForWalkie { controller.phase == .idle }
        #expect(controller.displayedTranscript(liveText: "previous recording").isEmpty)
        harness.startResult.resolve(false)
    }

    @Test("Up waits for final transcription and executes the same recording exactly once")
    func deferredExecutionPreservesRecordingIdentity() async throws {
        let harness = WalkieHarness()
        let controller = harness.makeController()
        let workspaceID = UUID()
        try await harness.startRecording(controller, workspaceID: workspaceID)
        let recordingID = try #require(harness.startedRecordingID)

        controller.endRecording()
        await harness.finishEntered.wait()
        controller.execute(workspaceID: workspaceID)
        controller.execute(workspaceID: workspaceID)
        #expect(controller.phase == .finishing)
        #expect(harness.events == [.start(workspaceID, recordingID)])

        harness.finishResult.resolve("  swift test\n")
        try await waitForWalkie { controller.phase == .idle }
        #expect(controller.transcript == "swift test")
        #expect(controller.rearmToken == 1)
        #expect(harness.events == [
            .start(workspaceID, recordingID),
            .stop(workspaceID, recordingID),
            .speech(workspaceID, recordingID, "swift test"),
            .execute(workspaceID, recordingID),
        ])

        // A new Up callback after finalization also cannot execute the same
        // dictated command twice, even after the first send has completed.
        controller.execute(workspaceID: workspaceID)
        await drainWalkieTasks()
        #expect(harness.events.count == 4)
    }

    @Test("release waits for the in-flight start announcement before stop and speech")
    func releaseDuringStartAnnouncement() async throws {
        let harness = WalkieHarness()
        harness.startSendResult = WalkieGate<Bool>()
        let controller = harness.makeController()
        let workspaceID = UUID()
        controller.beginRecording(workspaceID: workspaceID, allowRestrictedNetwork: false)
        await harness.startEntered.wait()
        harness.startResult.resolve(true)
        try await waitForWalkie { harness.startedRecordingID != nil }
        let recordingID = try #require(harness.startedRecordingID)

        controller.endRecording()
        await harness.finishEntered.wait()
        harness.finishResult.resolve("echo ready")
        await drainWalkieTasks()
        #expect(controller.phase == .finishing)
        #expect(harness.events == [.start(workspaceID, recordingID)])

        harness.startSendResult?.resolve(true)
        try await waitForWalkie { controller.phase == .idle }
        #expect(harness.events == [
            .start(workspaceID, recordingID),
            .stop(workspaceID, recordingID),
            .speech(workspaceID, recordingID, "echo ready"),
        ])
    }

    @Test("no speech never becomes Enter", arguments: ["", " \n\t "])
    func emptyTranscriptCannotExecute(text: String) async throws {
        let harness = WalkieHarness()
        let controller = harness.makeController()
        let workspaceID = UUID()
        try await harness.startRecording(controller, workspaceID: workspaceID)
        let recordingID = try #require(harness.startedRecordingID)

        controller.endRecording()
        await harness.finishEntered.wait()
        controller.execute(workspaceID: workspaceID)
        harness.finishResult.resolve(text)
        try await waitForWalkie { controller.phase == .idle }
        controller.execute(workspaceID: workspaceID)
        await drainWalkieTasks()

        #expect(controller.transcript.isEmpty)
        #expect(harness.events == [.start(workspaceID, recordingID), .stop(workspaceID, recordingID)])
        #expect(controller.statusMessage?.contains("No speech detected") == true)
    }

    @Test("failed microphone startup sends no recording or execute messages")
    func failedStartupCannotExecute() async throws {
        let harness = WalkieHarness()
        let controller = harness.makeController()
        let workspaceID = UUID()
        controller.beginRecording(workspaceID: workspaceID, allowRestrictedNetwork: true)
        await harness.startEntered.wait()
        controller.execute(workspaceID: workspaceID)
        harness.startResult.resolve(false)
        try await waitForWalkie { controller.phase == .idle }
        controller.execute(workspaceID: workspaceID)
        await drainWalkieTasks()

        #expect(harness.events.isEmpty)
        #expect(harness.startNetworkOverrides == [true])
        #expect(controller.rearmToken == 1)
        #expect(controller.statusMessage?.contains("could not start") == true)
    }

    @Test("transport rejection retains dictated text and suppresses queued Enter")
    func rejectedTranscriptStaysOnPhone() async throws {
        let harness = WalkieHarness()
        harness.acceptSpeech = false
        let controller = harness.makeController()
        let workspaceID = UUID()
        try await harness.startRecording(controller, workspaceID: workspaceID)
        let recordingID = try #require(harness.startedRecordingID)

        controller.endRecording()
        await harness.finishEntered.wait()
        controller.execute(workspaceID: workspaceID)
        harness.finishResult.resolve("git status")
        try await waitForWalkie { controller.phase == .idle }
        controller.execute(workspaceID: workspaceID)
        await drainWalkieTasks()

        #expect(controller.transcript == "git status")
        #expect(controller.statusMessage?.contains("Could not send") == true)
        #expect(harness.events == [
            .start(workspaceID, recordingID),
            .stop(workspaceID, recordingID),
            .speech(workspaceID, recordingID, "git status"),
        ])
    }

    @Test("release before microphone readiness discards stale text and late startup")
    func cancellationBeforeReadiness() async throws {
        let harness = WalkieHarness()
        let controller = harness.makeController()
        controller.beginRecording(workspaceID: nil, allowRestrictedNetwork: false)
        await harness.startEntered.wait()

        controller.endRecording()
        await harness.finishEntered.wait()
        controller.execute(workspaceID: nil)
        harness.finishResult.resolve("the previous recording")
        try await waitForWalkie { controller.phase == .idle }
        #expect(controller.transcript.isEmpty)
        #expect(controller.rearmToken == 1)

        // Model/permission work can finish after cancellation. Its successful
        // return must not announce a recording whose button is already up.
        harness.startResult.resolve(true)
        try await waitForWalkie { harness.startReturned }
        await drainWalkieTasks()
        #expect(controller.phase == .idle)
        #expect(harness.events.isEmpty)
    }

    @Test("a new Down hold cannot replace a recording while its text is finalizing")
    func finalizationRejectsOverlappingRecording() async throws {
        let harness = WalkieHarness()
        let controller = harness.makeController()
        let firstWorkspaceID = UUID()
        try await harness.startRecording(controller, workspaceID: firstWorkspaceID)
        let recordingID = try #require(harness.startedRecordingID)

        controller.endRecording()
        await harness.finishEntered.wait()
        controller.beginRecording(workspaceID: UUID(), allowRestrictedNetwork: true)
        #expect(controller.phase == .finishing)
        #expect(harness.startNetworkOverrides == [false])

        harness.finishResult.resolve("pwd")
        try await waitForWalkie { controller.phase == .idle }
        #expect(harness.events == [
            .start(firstWorkspaceID, recordingID),
            .stop(firstWorkspaceID, recordingID),
            .speech(firstWorkspaceID, recordingID, "pwd"),
        ])
    }

    @Test("disconnect clears queued execution even if the peer reconnects before decoding finishes")
    func disconnectClearsDeferredExecution() async throws {
        let harness = WalkieHarness()
        let controller = harness.makeController()
        let workspaceID = UUID()
        try await harness.startRecording(controller, workspaceID: workspaceID)
        let recordingID = try #require(harness.startedRecordingID)

        controller.endRecording()
        await harness.finishEntered.wait()
        controller.execute(workspaceID: workspaceID)
        harness.connected = false
        controller.interrupt()
        harness.connected = true
        harness.finishResult.resolve("git diff")
        try await waitForWalkie { controller.phase == .idle }

        #expect(harness.events == [
            .start(workspaceID, recordingID),
            .stop(workspaceID, recordingID),
        ])
        #expect(controller.transcript == "git diff")
        #expect(harness.finishCalls == 1)
    }

    @Test("deferred Up cannot execute in a different workspace from the dictated text")
    func deferredExecutionRejectsChangedWorkspace() async throws {
        let harness = WalkieHarness()
        let controller = harness.makeController()
        let workspaceID = UUID()
        try await harness.startRecording(controller, workspaceID: workspaceID)
        let recordingID = try #require(harness.startedRecordingID)

        controller.endRecording()
        await harness.finishEntered.wait()
        controller.execute(workspaceID: UUID())
        harness.finishResult.resolve("git status")
        try await waitForWalkie { controller.phase == .idle }

        #expect(harness.events == [
            .start(workspaceID, recordingID),
            .stop(workspaceID, recordingID),
            .speech(workspaceID, recordingID, "git status"),
        ])
        #expect(controller.statusMessage?.contains("Select the recorded workspace") == true)

        // A later workspace snapshot or tap cannot reroute Enter after the
        // transcript has finished either. Returning to its workspace works.
        controller.execute(workspaceID: UUID())
        await drainWalkieTasks()
        #expect(harness.events.count == 3)
        controller.execute(workspaceID: workspaceID)
        try await waitForWalkie { harness.events.count == 4 }
        #expect(harness.events.last == .execute(workspaceID, recordingID))
    }

    @Test("attempting another recording while disconnected preserves unsent text")
    func disconnectedStartupPreservesUnsentTranscript() async throws {
        let harness = WalkieHarness()
        harness.acceptSpeech = false
        let controller = harness.makeController()
        let workspaceID = UUID()
        try await harness.startRecording(controller, workspaceID: workspaceID)
        controller.endRecording()
        await harness.finishEntered.wait()
        harness.finishResult.resolve("keep this command")
        try await waitForWalkie { controller.phase == .idle }

        harness.connected = false
        controller.beginRecording(workspaceID: workspaceID, allowRestrictedNetwork: false)
        #expect(controller.transcript == "keep this command")
        #expect(controller.phase == .idle)
        #expect(harness.startNetworkOverrides == [false])
    }

    @Test("interruption after selecting a workspace cancels an in-flight plain Enter")
    func interruptionCancelsPlainEnter() async throws {
        let harness = WalkieHarness()
        harness.selectionSendResult = WalkieGate<Bool>()
        let controller = harness.makeController()
        let workspaceID = UUID()
        controller.execute(workspaceID: workspaceID)
        try await waitForWalkie { harness.events == [.select(workspaceID)] }

        controller.interrupt()
        harness.selectionSendResult?.resolve(true)
        try await waitForWalkie { harness.selectionSendReturned }
        await drainWalkieTasks()
        #expect(harness.events == [.select(workspaceID)])
    }

    @Test("interruption cancels Enter awaiting transport acceptance", arguments: [false, true])
    func interruptionCancelsQueuedTranscriptExecution(deferred: Bool) async throws {
        let harness = WalkieHarness()
        harness.executionSendResult = WalkieGate<Bool>()
        let controller = harness.makeController()
        let workspaceID = UUID()
        try await harness.startRecording(controller, workspaceID: workspaceID)
        let recordingID = try #require(harness.startedRecordingID)

        controller.endRecording()
        await harness.finishEntered.wait()
        if deferred { controller.execute(workspaceID: workspaceID) }
        harness.finishResult.resolve("git status")
        if !deferred {
            try await waitForWalkie { controller.phase == .idle }
            controller.execute(workspaceID: workspaceID)
        }
        try await waitForWalkie { harness.executionSendEntered }

        controller.interrupt()
        harness.executionSendResult?.resolve(true)
        try await waitForWalkie { harness.executionSendReturned && controller.phase == .idle }
        #expect(controller.transcript == "git status")
        #expect(harness.finishCalls == 1)
        #expect(harness.events == [
            .start(workspaceID, recordingID),
            .stop(workspaceID, recordingID),
            .speech(workspaceID, recordingID, "git status"),
        ])

        // Cancelling an unaccepted send must leave the transcript eligible
        // for a later explicit Up hold, without duplicating accepted Enter.
        controller.execute(workspaceID: workspaceID)
        try await waitForWalkie { harness.events.count == 4 }
        controller.execute(workspaceID: workspaceID)
        await drainWalkieTasks()
        #expect(harness.events.filter { $0 == .execute(workspaceID, recordingID) }.count == 1)
    }

    @Test("interruption cancels plain Enter awaiting transport acceptance")
    func interruptionCancelsQueuedPlainEnter() async throws {
        let harness = WalkieHarness()
        harness.executionSendResult = WalkieGate<Bool>()
        let controller = harness.makeController()
        let workspaceID = UUID()
        controller.execute(workspaceID: workspaceID)
        try await waitForWalkie { harness.executionSendEntered }

        controller.interrupt()
        harness.executionSendResult?.resolve(true)
        try await waitForWalkie { harness.executionSendReturned }
        #expect(harness.events == [.select(workspaceID)])
    }

    @Test("interruption before the execution task runs sends no command")
    func interruptionBeforeExecutionStarts() async {
        let harness = WalkieHarness()
        let controller = harness.makeController()
        controller.execute(workspaceID: UUID())
        controller.interrupt()

        await drainWalkieTasks()
        #expect(harness.events.isEmpty)
    }

    @Test("rapid workspace taps ignore stale selection snapshots until the latest tap is confirmed")
    func rapidWorkspaceSelection() {
        let now = Date(timeIntervalSince1970: 1_000)
        let first = WorkspaceSummary(id: UUID(), name: "First")
        let second = WorkspaceSummary(id: UUID(), name: "Second")
        let third = WorkspaceSummary(id: UUID(), name: "Third")
        let workspaces = [first, second, third]
        var selection = CopilotWorkspaceSelectionState()
        selection.select(second.id, now: now)
        selection.select(third.id, now: now.addingTimeInterval(0.1))

        let staleFirst = selection.receive(
            WorkspaceState(workspaces: workspaces, selectedWorkspaceID: first.id),
            now: now.addingTimeInterval(0.2)
        )
        let staleSecond = selection.receive(
            WorkspaceState(workspaces: workspaces, selectedWorkspaceID: second.id),
            now: now.addingTimeInterval(0.3)
        )
        #expect(staleFirst == third.id)
        #expect(staleSecond == third.id)

        let confirmed = selection.receive(
            WorkspaceState(workspaces: workspaces, selectedWorkspaceID: third.id),
            now: now.addingTimeInterval(0.4)
        )
        let remoteChange = selection.receive(
            WorkspaceState(workspaces: workspaces, selectedWorkspaceID: first.id),
            now: now.addingTimeInterval(0.5)
        )
        #expect(confirmed == third.id)
        #expect(remoteChange == first.id)
    }

    @Test("deleted or unacknowledged workspace selections eventually accept the Mac state")
    func unavailableWorkspaceSelection() {
        let now = Date(timeIntervalSince1970: 1_000)
        let first = WorkspaceSummary(id: UUID(), name: "First")
        let second = WorkspaceSummary(id: UUID(), name: "Second")
        var selection = CopilotWorkspaceSelectionState()
        selection.select(second.id, now: now)
        let removed = selection.receive(
            WorkspaceState(workspaces: [first], selectedWorkspaceID: first.id), now: now
        )
        #expect(removed == first.id)

        selection.select(second.id, now: now)
        let expired = selection.receive(
            WorkspaceState(workspaces: [first, second], selectedWorkspaceID: first.id),
            now: now.addingTimeInterval(3)
        )
        #expect(expired == first.id)
    }
}

@MainActor
private final class WalkieHarness {
    enum Event: Equatable {
        case start(UUID?, UUID?)
        case stop(UUID?, UUID?)
        case speech(UUID?, UUID?, String)
        case execute(UUID?, UUID)
        case select(UUID)
        case enter
        case other
    }

    let startEntered = WalkieGate<Void>()
    let finishEntered = WalkieGate<Void>()
    let startResult = WalkieGate<Bool>()
    let finishResult = WalkieGate<String>()
    var startSendResult: WalkieGate<Bool>?
    var selectionSendResult: WalkieGate<Bool>?
    var executionSendResult: WalkieGate<Bool>?
    var connected = true
    var acceptSpeech = true
    var startReturned = false
    var selectionSendReturned = false
    var executionSendEntered = false
    var executionSendReturned = false
    var startNetworkOverrides: [Bool] = []
    var finishCalls = 0
    var events: [Event] = []

    var startedRecordingID: UUID? {
        for case .start(_, let id) in events { return id }
        return nil
    }

    func makeController() -> CopilotWalkieTalkie {
        CopilotWalkieTalkie(
            start: { [self] allowRestrictedNetwork in
                startNetworkOverrides.append(allowRestrictedNetwork)
                startEntered.resolve(())
                let result = await startResult.wait()
                startReturned = true
                return result
            },
            finish: { [self] in
                finishCalls += 1
                finishEntered.resolve(())
                return await finishResult.wait()
            },
            send: { [self] message in
                switch message {
                case .voiceRecord(let command):
                    if command.control == .start {
                        events.append(.start(command.workspaceID, command.recordingID))
                        if let startSendResult { return await startSendResult.wait() }
                    } else {
                        events.append(.stop(command.workspaceID, command.recordingID))
                    }
                case .transcribedSpeech(let speech):
                    events.append(.speech(speech.workspaceID, speech.recordingID, speech.text))
                    return acceptSpeech
                case .executeTranscript(let command):
                    guard await acceptExecution() else { return false }
                    events.append(.execute(command.workspaceID, command.recordingID))
                case .selectWorkspace(let command):
                    events.append(.select(command.workspaceID))
                    if let selectionSendResult {
                        let result = await selectionSendResult.wait()
                        selectionSendReturned = true
                        return result
                    }
                case .terminalInput(.enter):
                    guard await acceptExecution() else { return false }
                    events.append(.enter)
                default:
                    events.append(.other)
                }
                return connected
            },
            isConnected: { [self] in connected }
        )
    }

    private func acceptExecution() async -> Bool {
        guard let executionSendResult else { return true }
        executionSendEntered = true
        let accepted = await executionSendResult.wait()
        executionSendReturned = true
        // Model the transport's final cancellation check before submission.
        return accepted && !Task.isCancelled
    }

    func startRecording(_ controller: CopilotWalkieTalkie, workspaceID: UUID?) async throws {
        controller.beginRecording(workspaceID: workspaceID, allowRestrictedNetwork: false)
        await startEntered.wait()
        startResult.resolve(true)
        try await waitForWalkie { controller.phase == .recording && startedRecordingID != nil }
    }
}

/// Explicit gates put the controller at the exact await being tested; no
/// microphone, model download, network peer, or wall-clock delay is involved.
@MainActor
private final class WalkieGate<Value: Sendable> {
    private var result: Value?
    private var waiter: CheckedContinuation<Value, Never>?

    func wait() async -> Value {
        if let result { return result }
        return await withCheckedContinuation { waiter = $0 }
    }

    func resolve(_ value: Value) {
        precondition(result == nil, "A test gate must only be resolved once")
        result = value
        waiter?.resume(returning: value)
        waiter = nil
    }
}

@MainActor
private func waitForWalkie(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition(), ContinuousClock.now < deadline {
        await Task.yield()
    }
    try #require(condition(), "The Walkie controller did not reach the expected state")
}

@MainActor
private func drainWalkieTasks() async {
    for _ in 0..<20 { await Task.yield() }
}
