import Foundation
import SwiftData
import Testing
@testable import Pilot

@Suite("Walkie terminal and remote delivery", .serialized)
@MainActor
struct PilotWalkieDeliveryTests {
    @Test("Remote dictation and Enter stay on the original computer after selecting another tab")
    func remoteDeliveryRemainsPinned() async throws {
        try await withFixture { store, _, connections in
            let recorder = DeliveryRecorder()
            let sessionID = UUID()
            recorder.sessions[connections[0].id] = sessionID
            recorder.sessions[connections[1].id] = UUID()
            let delivery = recorder.delivery(store: store)
            let recordingID = UUID()
            let workspaceID = WorkspaceStore.remoteDesktopWorkspaceID
            store.selectRemoteDesktopTab(connections[0].id)
            var state = PilotWalkieInputState()
            delivery.start(.init(control: .start, workspaceID: workspaceID, recordingID: recordingID), state: &state)

            store.selectRemoteDesktopTab(connections[1].id)
            #expect(await delivery.receive(.init(workspaceID: workspaceID, text: "echo hello\nworld",
                                                recordingID: recordingID), state: &state))
            #expect(await delivery.execute(.init(recordingID: recordingID, workspaceID: workspaceID), state: &state))
            #expect(await delivery.execute(.init(recordingID: recordingID, workspaceID: workspaceID), state: &state) == false)

            let target = PilotWalkieInputState.Target(workspaceID: workspaceID, destination: .remoteDesktop(
                connectionID: connections[0].id, sessionID: sessionID
            ))
            #expect(recorder.events == [.text(target, "echo hello world"), .enter(target)])
            #expect(recorder.terminalLookups == 0)
        }
    }

    @Test("Reconnection before transcript delivery never types into the new VNC session")
    func reconnectionBeforeTextRejectsDelivery() async throws {
        try await withFixture { store, _, connections in
            let recorder = DeliveryRecorder()
            recorder.sessions[connections[0].id] = UUID()
            let delivery = recorder.delivery(store: store)
            let recordingID = UUID()
            let workspaceID = WorkspaceStore.remoteDesktopWorkspaceID
            store.selectRemoteDesktopTab(connections[0].id)
            var state = PilotWalkieInputState()
            delivery.start(.init(control: .start, workspaceID: workspaceID, recordingID: recordingID), state: &state)
            recorder.sessions[connections[0].id] = UUID()

            #expect(await delivery.receive(.init(workspaceID: workspaceID, text: "do not send",
                                                recordingID: recordingID), state: &state) == false)
            #expect(await delivery.execute(.init(recordingID: recordingID, workspaceID: workspaceID), state: &state) == false)
            #expect(recorder.events.isEmpty)
            #expect(recorder.terminalLookups == 0)
        }
    }

    @Test("Reconnection after text delivery cannot execute in a replacement VNC session")
    func reconnectionBeforeEnterRejectsExecution() async throws {
        try await withFixture { store, _, connections in
            let recorder = DeliveryRecorder()
            recorder.sessions[connections[0].id] = UUID()
            let delivery = recorder.delivery(store: store)
            let recordingID = UUID()
            let workspaceID = WorkspaceStore.remoteDesktopWorkspaceID
            store.selectRemoteDesktopTab(connections[0].id)
            var state = PilotWalkieInputState()
            delivery.start(.init(control: .start, workspaceID: workspaceID, recordingID: recordingID), state: &state)
            #expect(await delivery.receive(.init(workspaceID: workspaceID, text: "git status",
                                                recordingID: recordingID), state: &state))
            recorder.sessions[connections[0].id] = UUID()

            #expect(await delivery.execute(.init(recordingID: recordingID, workspaceID: workspaceID), state: &state) == false)
            #expect(recorder.events.count == 1)
        }
    }

    @Test("An offline remote computer cannot fall back to a local terminal")
    func unavailableRemoteNeverUsesTerminal() async throws {
        try await withFixture { store, _, connections in
            let recorder = DeliveryRecorder()
            let delivery = recorder.delivery(store: store)
            let recordingID = UUID()
            let workspaceID = WorkspaceStore.remoteDesktopWorkspaceID
            store.selectRemoteDesktopTab(connections[0].id)
            var state = PilotWalkieInputState()
            delivery.start(.init(control: .start, workspaceID: nil, recordingID: recordingID), state: &state)
            #expect(await delivery.receive(.init(workspaceID: nil, text: "offline", recordingID: recordingID), state: &state) == false)
            #expect(await delivery.execute(.init(recordingID: recordingID, workspaceID: workspaceID), state: &state) == false)
            #expect(await delivery.enterSelection() == false)
            #expect(recorder.events.isEmpty)
            #expect(recorder.terminalLookups == 0)
        }
    }

    @Test("Local dictation remains pinned when the user opens Remote Desktop")
    func localDeliveryStillUsesTerminal() async throws {
        try await withFixture { store, workspace, connections in
            let recorder = DeliveryRecorder()
            let delivery = recorder.delivery(store: store)
            let recordingID = UUID()
            var state = PilotWalkieInputState()
            delivery.start(.init(control: .start, workspaceID: workspace.id, recordingID: recordingID), state: &state)
            store.selectRemoteDesktopTab(connections[0].id)
            #expect(await delivery.receive(.init(workspaceID: workspace.id, text: "pwd", recordingID: recordingID), state: &state))
            #expect(await delivery.execute(.init(recordingID: recordingID, workspaceID: workspace.id), state: &state))
            let target = recorder.target(workspaceID: workspace.id)
            #expect(recorder.events == [.text(target, "pwd"), .enter(target)])
        }
    }

    @Test("Local dictation and Enter use the captured Cockpit terminal session")
    func localDeliveryUsesSession() async throws {
        try await verifySessionDelivery(destination: .local)
    }

    @Test("Drone dictation and Enter use the captured Cockpit terminal session")
    func droneDeliveryUsesSession() async throws {
        try await verifySessionDelivery(destination: .drone(droneID: UUID()))
    }

    @Test("Reset cancels queued Enter and prevents stale state from being resurrected")
    func queueResetInvalidatesPendingWorkAndCommit() async throws {
        try await withFixture { store, workspace, _ in
            let fixture = QueueDeliveryFixture()
            let queue = PilotWalkieDeliveryQueue(delivery: fixture.delivery(store: store))
            let started = WalkieDeliveryGate()
            let gate = WalkieDeliveryGate()
            fixture.insertText = { _, _ in
                started.open()
                await gate.wait()
                return true
            }
            let recordingID = UUID()
            queue.start(.init(control: .start, workspaceID: workspace.id, recordingID: recordingID))
            queue.receive(.init(workspaceID: workspace.id, text: "stale", recordingID: recordingID))
            await started.wait()
            queue.enterSelection()

            queue.reset()
            gate.open()
            await queue.waitForIdle()

            #expect(!queue.state.isRecording)
            #expect(fixture.events.isEmpty)
        }
    }

    @Test("Queued Enter keeps the pane captured at message receipt")
    func queuedEnterUsesReceiptTarget() async throws {
        try await withFixture { store, workspace, _ in
            let fixture = QueueDeliveryFixture()
            let queue = PilotWalkieDeliveryQueue(delivery: fixture.delivery(store: store))
            let gate = WalkieDeliveryGate()
            fixture.insertText = { _, _ in await gate.wait(); return true }
            let recordingID = UUID()
            queue.start(.init(control: .start, workspaceID: workspace.id, recordingID: recordingID))
            queue.receive(.init(workspaceID: workspace.id, text: "hold queue", recordingID: recordingID))
            queue.enterSelection()
            fixture.selectSecond()

            gate.open()
            await queue.waitForIdle()

            let entered = fixture.events.compactMap { event -> PilotWalkieInputState.Target? in
                guard case .enter(let target) = event else { return nil }
                return target
            }
            #expect(entered.count == 1)
            #expect(entered.first?.paneID == fixture.first.identity.paneID)
            #expect(entered.first?.terminalIdentity == fixture.first.identity)
        }
    }

    @Test("Terminal replacement rejects captured dictation without input or reconnect")
    func replacementSessionFailsClosed() async throws {
        try await withFixture { store, workspace, _ in
            let paneID = UUID()
            let droneID = UUID()
            let original = WalkieRecordingSession(destination: .drone(droneID: droneID), paneID: paneID)
            let replacement = WalkieRecordingSession(
                destination: .drone(droneID: droneID), paneID: paneID, generation: 2
            )
            let slot = WalkieSessionSlot(session: original)
            let delivery = PilotWalkieDelivery(store: store, terminalPaneID: { _ in paneID }, terminalSession: { _ in
                slot.session
            })
            let recordingID = UUID()
            var state = PilotWalkieInputState()
            delivery.start(.init(control: .start, workspaceID: workspace.id, recordingID: recordingID), state: &state)
            slot.session = replacement

            #expect(await delivery.receive(.init(workspaceID: workspace.id, text: "stale", recordingID: recordingID), state: &state) == false)
            #expect(original.inputs.isEmpty)
            #expect(replacement.inputs.isEmpty)
            #expect(replacement.restoreCount == 0)
        }
    }

    private func verifySessionDelivery(destination: TerminalDestination) async throws {
        try await withFixture { store, workspace, connections in
            let paneID = UUID()
            let session = WalkieRecordingSession(destination: destination, paneID: paneID)
            let delivery = PilotWalkieDelivery(store: store, terminalPaneID: { _ in paneID }, terminalSession: { _ in
                session
            })
            let recordingID = UUID()
            var state = PilotWalkieInputState()
            delivery.start(.init(control: .start, workspaceID: workspace.id, recordingID: recordingID), state: &state)
            store.selectRemoteDesktopTab(connections[0].id)

            #expect(await delivery.receive(.init(workspaceID: workspace.id, text: "echo hello\nworld",
                                                recordingID: recordingID), state: &state))
            #expect(await delivery.execute(.init(recordingID: recordingID, workspaceID: workspace.id), state: &state))
            #expect(session.inputs == [.literal("echo hello world"), .enter])
        }
    }

    private func withFixture(
        _ body: @MainActor (WorkspaceStore, Workspace, [RemoteDesktopConnection]) async throws -> Void
    ) async throws {
        let defaults = UserDefaults.standard
        let keys = ["selectedWorkspaceID", "selectedRemoteConnectionID", "selectedNoteID",
                    "notesMode", "remoteDesktopMode", "dockerMode", "agenticUseMode"]
        let original = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, original) {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        let schema = Schema([Workspace.self, Pane.self, BrowserState.self, EditorState.self,
                             Note.self, RemoteDesktopConnection.self, ExtensionWorkspaceLink.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(
            schema: schema, isStoredInMemoryOnly: true
        ))
        let workspace = Workspace(name: "Local")
        container.mainContext.insert(workspace)
        let connections = [RemoteDesktopConnection(host: "mini01.local"), RemoteDesktopConnection(host: "mini02.local")]
        for connection in connections { container.mainContext.insert(connection) }
        try container.mainContext.save()
        let store = WorkspaceStore(modelContext: container.mainContext)
        store.selectWorkspace(workspace.id)
        try await body(store, workspace, connections)
        withExtendedLifetime(container) {}
    }
}

@MainActor
private final class DeliveryRecorder {
    enum Event: Equatable {
        case text(PilotWalkieInputState.Target, String)
        case enter(PilotWalkieInputState.Target)
    }
    let paneID = UUID()
    let identity: TerminalSessionIdentity
    var terminalLookups = 0
    var sessions: [UUID: UUID] = [:]
    var events: [Event] = []

    init() {
        identity = TerminalSessionIdentity(
            paneID: paneID,
            ownership: TerminalDestination.local.ownership,
            generation: 1
        )
    }

    func target(workspaceID: UUID?) -> PilotWalkieInputState.Target {
        PilotWalkieInputState.Target(workspaceID: workspaceID, paneID: paneID, terminalIdentity: identity)
    }

    func delivery(store: WorkspaceStore) -> PilotWalkieDelivery {
        PilotWalkieDelivery(store: store, terminalPaneID: { [self] _ in
            terminalLookups += 1
            return paneID
        }, terminalSession: { [self] _ in
            LocalTerminalSession(identity: identity, persistentSessionName: "delivery-test")
        }, remoteSessionID: { [self] in sessions[$0] }, insertText: { [self] target, text in
            guard isAvailable(target) else { return false }
            events.append(.text(target, text))
            return true
        }, sendEnter: { [self] target in
            guard isAvailable(target) else { return false }
            events.append(.enter(target))
            return true
        })
    }

    private func isAvailable(_ target: PilotWalkieInputState.Target) -> Bool {
        switch target.destination {
        case .terminal: return true
        case .remoteDesktop(let connectionID, let sessionID): return sessions[connectionID] == sessionID
        }
    }
}

@MainActor
private final class QueueDeliveryFixture {
    let first = WalkieRecordingSession(destination: .local, paneID: UUID())
    let second = WalkieRecordingSession(destination: .local, paneID: UUID())
    var insertText: PilotWalkieDelivery.InsertText?
    var events: [DeliveryRecorder.Event] = []
    private var usesSecond = false

    func selectSecond() {
        usesSecond = true
    }

    func delivery(store: WorkspaceStore) -> PilotWalkieDelivery {
        PilotWalkieDelivery(store: store, terminalPaneID: { [self] _ in
            usesSecond ? second.identity.paneID : first.identity.paneID
        }, terminalSession: { [self] paneID in
            paneID == first.identity.paneID ? first : second
        }, insertText: { [self] target, text in
            if let insertText { return await insertText(target, text) }
            events.append(.text(target, text))
            return true
        }, sendEnter: { [self] target in
            events.append(.enter(target))
            return true
        })
    }
}

private final class WalkieDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        _ = await withCheckedContinuation { continuation in
            lock.withLock {
                if opened {
                    continuation.resume()
                } else {
                    self.continuation = continuation
                }
            }
        }
    }

    func open() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            opened = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }
}

@MainActor
private final class WalkieSessionSlot {
    var session: WalkieRecordingSession
    init(session: WalkieRecordingSession) { self.session = session }
}

private final class WalkieRecordingSession: CockpitTerminalSession, @unchecked Sendable {
    let identity: TerminalSessionIdentity
    let destination: TerminalDestination
    private let lock = NSLock()
    private var storedInputs: [TerminalSessionInput] = []
    private var storedRestoreCount = 0

    var inputs: [TerminalSessionInput] { lock.withLock { storedInputs } }
    var restoreCount: Int { lock.withLock { storedRestoreCount } }
    var hasRuntimeSnapshot: Bool { true }

    init(destination: TerminalDestination, paneID: UUID, generation: UInt64 = 1) {
        self.destination = destination
        identity = TerminalSessionIdentity(paneID: paneID, ownership: destination.ownership, generation: generation)
    }

    func bootstrap(workingDirectory: String?) -> TerminalSessionBootstrap {
        destination.kind == .local ? .local(initialInput: nil) : .remote
    }

    func restore(workingDirectory: String?) async throws -> TerminalSessionRestoration {
        lock.withLock { storedRestoreCount += 1 }
        return TerminalSessionRestoration(identity: identity, remoteSessionID: destination.remoteSessionID)
    }

    func send(_ input: TerminalSessionInput) async -> Bool {
        lock.withLock { storedInputs.append(input) }
        return true
    }

    func foregroundActivity(unavailableActivity: TerminalProcessActivity) async -> TerminalProcessActivity {
        unavailableActivity
    }

    func interrupt() async -> Bool { false }
    func currentDirectorySnapshot() -> String? { nil }
    func runtimeSnapshot() -> TerminalSessionRuntime? { nil }
    func visibleContents() -> String? { nil }
    func close() async -> Bool { true }
    func suspend() async {}
}
