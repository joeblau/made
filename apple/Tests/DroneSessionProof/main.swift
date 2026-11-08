import Foundation

@main
enum DroneSessionProof {
    @MainActor
    static func main() async throws {
        let deadline = Task {
            try await Task.sleep(for: .seconds(10))
            fatalError("Session proof timed out")
        }
        defer { deadline.cancel() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let factory = SessionTransport()
        let store = DroneStore(persistence: DroneRegistryPersistence(url: root.appendingPathComponent("drones.json")),
                               transport: factory)
        let id = try store.addManual(name: "Fixture", host: "fixture.invalid", port: "7400")
        let provider = TerminalSessionProvider { id in MainActor.assumeIsolated { store.terminalClient(for: id) } }
        let pane = Pane(droneID: id)
        precondition(provider.session(for: pane) is UnavailableTerminalSession)
        store.start()
        await wait { store.states[id]?.isConnected == true }
        let first = provider.session(for: pane)
        let restored = try await provider.restore(pane: pane)
        precondition(restored.remoteSessionID == factory.remoteID)
        let display = DisplayRecorder()
        await first.setOutputHandler { display.record($0) }
        let firstSent = await first.send(.literal("first"))
        precondition(firstSent)
        let originalConnection = factory.connections[0]
        let originalCreateKey = originalConnection.sent.first(where: { $0.kind == .create })?.idempotencyKey
        precondition(originalCreateKey == "terminal-\(pane.id.uuidString)", "create key depends on generation")
        originalConnection.emit(DroneEnvelope(kind: .output, sessionID: DroneSessionID(rawValue: factory.remoteID),
                                               body: .output(DroneOutputBody(sequence: 0, offset: 0,
                                                                            data: Data([0xE2, 0x9C]), isFinal: false))))
        await wait { first.visibleContents() != nil }
        originalConnection.emit(DroneEnvelope(kind: .output, sessionID: DroneSessionID(rawValue: factory.remoteID),
                                               body: .output(DroneOutputBody(sequence: 1, offset: 2,
                                                                            data: Data([0x93]), isFinal: false))))
        await wait { display.latest == "✓" }
        factory.holdNextAttach = true
        store.retry(id: id)
        precondition(store.terminalClient(for: id) == nil, "retry retained retired client")
        await wait { factory.connections.count == 2 && store.states[id]?.isConnected == true }
        // No UI task restart or explicit provider.restore: the registry event must reattach.
        await wait { factory.connections[1].sent.contains { $0.kind == .attach } }
        let next = provider.session(for: pane)
        precondition(next.identity.generation > first.identity.generation)
        let staleSent = await first.send(.literal("stale"))
        precondition(!staleSent, "retired session accepted input")
        var inputStarted = false
        let pendingInput = Task {
            inputStarted = true
            return await next.send(.literal("next"))
        }
        await wait { inputStarted }
        precondition(!factory.connections[1].sent.contains { $0.kind == .input }, "input preceded reattachment")
        factory.connections[1].releaseAttach()
        let reconnectedInput = await pendingInput.value
        precondition(reconnectedInput, "replacement rejected input without a manual restore")
        precondition(next.destination.remoteSessionID == restored.remoteSessionID)
        let attach = factory.connections[1].sent.first(where: { $0.kind == .attach })!
        precondition(attach.body == .attach(DroneAttachBody(afterSequence: 2, afterOffset: 3)), "reattach lost cursor")
        precondition(next.visibleContents() == "✓", "reattach lost retained bytes")
        await first.setOutputHandler { _ in fatalError("retired display handler replaced the live binding") }
        factory.connections[1].emit(DroneEnvelope(kind: .output, sessionID: DroneSessionID(rawValue: factory.remoteID),
                                                 body: .output(DroneOutputBody(sequence: 2, offset: 3,
                                                                              data: Data("!".utf8), isFinal: false))))
        await wait { display.latest == "✓!" }
        precondition(next.visibleContents() == "✓!", "replacement display did not follow output")
        try await routingProof(store: store, id: id, generation: next.identity.generation)
        precondition(!factory.connections[1].sent.contains(where: { $0.kind == .create }), "reattach created another session")
        precondition(factory.connections[1].sent.contains(where: { $0.kind == .input }), "replacement did not receive input")
        precondition(originalConnection.sent.filter { $0.kind == .input }.count == 1)

        try await delayedCleanupProof(store: store, id: id, connection: factory.connections[1])
        try await closeDuringCreateProof()
        try await closeDuringAttachProof()
        try await resyncAndResizeProof()
        try await resizeOrderingProof()

        factory.revokeFails = true
        await store.forget(id: id)
        precondition(store.records.count == 1 && store.persistenceError != nil, "failed revoke erased metadata")
        precondition(provider.session(for: pane) is UnavailableTerminalSession)
        factory.revokeFails = false
        await store.forget(id: id)
        precondition(store.records.isEmpty, "successful revoke retained metadata")
        precondition(provider.session(for: pane) is UnavailableTerminalSession)
        store.stop()
        try await presentationRecoveryProof(initiallyOffline: true)
        try await presentationRecoveryProof(initiallyOffline: false)
        print("Drone session proof passed: recovery, stable identity/cursor, close/create/attach races, output-gap resync/replay, resize, stale input isolation, and presentation recovery.")
    }

    @MainActor
    private static func routingProof(store: DroneStore, id: UUID, generation: UInt64) async throws {
        let client = store.terminalClient(for: id) as! DroneRemoteTerminalClient
        let firstID = UUID()
        let secondID = UUID()
        let first = DroneTerminalResumeState(sessionID: firstID)
        let second = DroneTerminalResumeState(sessionID: secondID)
        let firstRef = DroneTerminalSessionReference(droneID: id, sessionID: firstID, generation: generation)
        let secondRef = DroneTerminalSessionReference(droneID: id, sessionID: secondID, generation: generation)
        await client.setOutputHandler({ first.append($0) != nil }, for: firstRef)
        await client.setOutputHandler({ second.append($0) != nil }, for: secondRef)
        await client.handle(DroneEnvelope(kind: .output, sessionID: DroneSessionID(rawValue: firstID),
                                          body: .output(DroneOutputBody(sequence: 0, offset: 0,
                                                                       data: Data("one".utf8), isFinal: false))))
        await client.handle(DroneEnvelope(kind: .output, sessionID: DroneSessionID(rawValue: secondID),
                                          body: .output(DroneOutputBody(sequence: 0, offset: 0,
                                                                       data: Data("two".utf8), isFinal: false))))
        precondition(first.contents == "one" && second.contents == "two", "cross-session output")
        let stale = DroneTerminalSessionReference(droneID: id, sessionID: firstID, generation: generation - 1)
        await client.setOutputHandler({ _ in fatalError("stale subscriber invoked") }, for: stale)
        do {
            try await client.sendInput(Data("stale".utf8), to: stale)
            fatalError("stale client reference accepted")
        } catch TerminalSessionFailure.staleGeneration {}
        let oversized = DroneOutputBody(sequence: 1, offset: 3, data: Data(repeating: 65, count: 300 * 1_024), isFinal: false)
        _ = first.append(oversized)
        precondition(first.contents!.utf8.count == 256 * 1_024, "viewport not byte bounded")
        precondition(first.append(oversized) == nil, "duplicate output appended")
    }

    @MainActor
    private static func delayedCleanupProof(store: DroneStore, id: UUID, connection: SessionConnection) async throws {
        let client = store.terminalClient(for: id) as! DroneRemoteTerminalClient
        for operation in [DroneMessageKind.detach, .close] {
            let sessionID = UUID()
            let reference = DroneTerminalSessionReference(droneID: id, sessionID: sessionID, generation: 1)
            await client.setOutputHandler({ _ in false }, for: reference)
            let cleanup = Task {
                if operation == .detach { try await client.detach(reference) } else { try await client.close(reference) }
            }
            await wait { connection.sent.contains { $0.kind == operation && $0.sessionID?.rawValue == sessionID } }
            let request = connection.sent.first { $0.kind == operation && $0.sessionID?.rawValue == sessionID }!
            let replacement = DroneTerminalResumeState(sessionID: sessionID)
            await client.setOutputHandler({ replacement.append($0) != nil }, for: reference)
            try await client.attachTerminal(reference)
            connection.emit(DroneEnvelope(kind: operation == .detach ? .detached : .closed,
                                            requestID: request.requestID, sessionID: DroneSessionID(rawValue: sessionID)))
            try await cleanup.value
            await client.handle(DroneEnvelope(kind: .output, sessionID: DroneSessionID(rawValue: sessionID),
                                              body: .output(DroneOutputBody(sequence: 0, offset: 0,
                                                                           data: Data("new".utf8), isFinal: false))))
            precondition(replacement.contents == "new", "late cleanup removed same-generation replacement")
            try await client.sendInput(Data("kept".utf8), to: reference)
        }
    }

    @MainActor
    private static func closeDuringCreateProof() async throws {
        let droneID = UUID()
        let remoteID = UUID()
        let client = SessionRaceClient(droneID: droneID, remoteID: remoteID)
        client.holdCreate = true
        let identity = TerminalSessionIdentity(
            paneID: UUID(), ownership: TerminalDestination.drone(droneID: droneID).ownership, generation: 1
        )
        let session = DroneTerminalSession(identity: identity, remoteSessionID: nil, client: client)
        let restoring = Task { try await session.restore(workingDirectory: nil) }
        await wait { client.createCount == 1 }
        session.retire()
        let closing = Task { await session.close() }
        client.releaseCreate()
        do {
            _ = try await restoring.value
            preconditionFailure("closed restoration succeeded")
        } catch TerminalSessionFailure.staleGeneration {}
        let closedAfterCreate = await closing.value
        precondition(closedAfterCreate, "late-created session was not closed")
        precondition(client.closedSessionIDs == [remoteID], "close targeted the wrong late-created session")
        precondition(client.attachCount == 0, "closing session attached after creation")
        let sent = await session.send(.literal("after-close"))
        precondition(!sent && client.inputBytes.isEmpty, "closing session accepted input")
    }

    @MainActor
    private static func closeDuringAttachProof() async throws {
        let droneID = UUID()
        let remoteID = UUID()
        let client = SessionRaceClient(droneID: droneID, remoteID: remoteID)
        client.holdAttach = true
        let identity = TerminalSessionIdentity(
            paneID: UUID(), ownership: TerminalDestination.drone(droneID: droneID).ownership, generation: 1
        )
        let session = DroneTerminalSession(identity: identity, remoteSessionID: remoteID, client: client)
        let restoring = Task { try await session.restore(workingDirectory: nil) }
        await wait { client.attachCount == 1 }
        session.retire()
        let closing = Task { await session.close() }
        client.releaseAttach()
        do {
            _ = try await restoring.value
            preconditionFailure("closed attachment succeeded")
        } catch TerminalSessionFailure.staleGeneration {}
        let closedAfterAttach = await closing.value
        precondition(closedAfterAttach, "in-flight restoration prevented close")
        precondition(client.closedSessionIDs == [remoteID], "restored session was not closed")
        let sent = await session.send(.enter)
        precondition(!sent && client.inputBytes.isEmpty && client.attachCount == 1, "close reconnected or sent Enter")
    }

    @MainActor
    private static func resyncAndResizeProof() async throws {
        let droneID = UUID()
        let remoteID = UUID()
        let client = SessionRaceClient(droneID: droneID, remoteID: remoteID)
        client.gapNextAttach = true
        let resumeState = DroneTerminalResumeState(sessionID: remoteID)
        _ = resumeState.append(DroneOutputBody(
            sequence: 0, offset: 0, data: Data("stale".utf8), isFinal: false
        ))
        let identity = TerminalSessionIdentity(
            paneID: UUID(), ownership: TerminalDestination.drone(droneID: droneID).ownership, generation: 1
        )
        let session = DroneTerminalSession(
            identity: identity, remoteSessionID: remoteID, client: client, resumeState: resumeState
        )
        _ = try await session.restore(workingDirectory: nil)
        precondition(client.resyncCount == 1, "output gap did not request production resync")
        precondition(client.attachCursors == [DroneTerminalCursor(sequence: 1, offset: 5)], "wrong replay cursor")
        precondition(session.visibleContents() == "fresh", "resync retained stale output")
        client.emit("!", sequence: 41, offset: 4_101)
        precondition(session.visibleContents() == "fresh!", "output after snapshot did not append")
        let resized = await session.resize(columns: 132, rows: 43)
        precondition(resized, "session resize failed")
        precondition(client.resizes == [DroneResizeBody(columns: 132, rows: 43)], "resize did not reach client")
    }

    @MainActor
    private static func resizeOrderingProof() async throws {
        let droneID = UUID()
        let connection = ResizeOrderingConnection()
        let client = DroneRemoteTerminalClient(droneID: droneID, controllerID: UUID(), connection: connection)
        let reference = DroneTerminalSessionReference(droneID: droneID, sessionID: UUID(), generation: 1)
        await client.setOutputHandler({ _ in true }, for: reference)
        let handler = Task {
            while !Task.isCancelled {
                do {
                    await client.handle(try await connection.receive())
                } catch {
                    break
                }
            }
        }
        defer { handler.cancel() }
        let older = Task { try await client.resize(columns: 80, rows: 24, for: reference) }
        await wait { connection.resizes.count == 1 }
        let newer = Task { try await client.resize(columns: 132, rows: 43, for: reference) }
        await Task.yield()
        precondition(connection.resizes.count == 1, "newer resize overtook unacknowledged request")
        connection.releaseResize(at: 0)
        await wait { connection.resizes.count == 2 }
        connection.releaseResize(at: 1)
        try await older.value
        try await newer.value
        precondition(connection.resizes == [
            DroneResizeBody(columns: 80, rows: 24),
            DroneResizeBody(columns: 132, rows: 43),
        ], "resize completion order changed the final dimensions")
    }

    @MainActor
    private static func presentationRecoveryProof(initiallyOffline: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let factory = SessionTransport()
        let store = DroneStore(persistence: DroneRegistryPersistence(url: root.appendingPathComponent("drones.json")),
                               transport: factory)
        defer { store.stop() }
        let id = try store.addManual(name: "Recover", host: "fixture.invalid", port: "7400")
        let provider = TerminalSessionProvider { id in MainActor.assumeIsolated { store.terminalClient(for: id) } }
        let pane = Pane(droneID: id)
        let presentation = DroneTerminalPresentation(pane: pane, provider: provider)
        defer { presentation.stop() }
        if !initiallyOffline {
            factory.holdNextAttach = true
            store.start()
            await wait { store.states[id]?.isConnected == true }
        }
        presentation.start()
        if initiallyOffline {
            await wait { presentation.status.hasPrefix("Unavailable:") }
            precondition(!presentation.isConnected && presentation.contents.isEmpty)
            store.start()
        } else {
            await wait { factory.connections[0].sent.contains { $0.kind == .attach } }
            precondition(!presentation.isConnected, "unconfirmed first attachment enabled input")
            factory.holdNextAttach = false
            store.retry(id: id)
        }
        // The production presentation model must recover without another start/restore/bind call.
        await wait { presentation.isConnected }
        let connection = factory.connections.last!
        connection.emit(DroneEnvelope(kind: .output, sessionID: DroneSessionID(rawValue: factory.remoteID),
                                       body: .output(DroneOutputBody(sequence: 0, offset: 0,
                                                                    data: Data("recovered".utf8), isFinal: false))))
        await wait { presentation.contents == "recovered" }
        precondition(presentation.status == "Connected")
        let sent = await presentation.send("pwd")
        precondition(sent, "recovered presentation still disabled input")
        precondition(factory.connections.flatMap(\.sent).filter { $0.kind == .create }.count == 1)
        presentation.stop()
        connection.emit(DroneEnvelope(kind: .output, sessionID: DroneSessionID(rawValue: factory.remoteID),
                                       body: .output(DroneOutputBody(sequence: 1, offset: 9,
                                                                    data: Data(" late".utf8), isFinal: false))))
        await wait { provider.session(for: pane).visibleContents() == "recovered late" }
        precondition(presentation.contents == "recovered" && !presentation.isConnected, "stopped presentation accepted output")
    }

    @MainActor
    static func wait(_ condition: () -> Bool) async {
        while !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

@MainActor
private final class SessionTransport: DroneTransportFactory {
    let remoteID = UUID()
    var connections: [SessionConnection] = []
    var revokeFails = false
    var holdNextAttach = false
    func connect(_ request: DroneTransportRequest) async throws -> any DroneConnection {
        let connection = SessionConnection(remoteID: remoteID, holdAttach: holdNextAttach)
        connections.append(connection)
        return connection
    }
    func revoke(droneID: UUID) async throws {
        if revokeFails { throw DroneTransportError.revocationFailed }
    }
}

private final class SessionConnection: DroneConnection, @unchecked Sendable {
    let peer = DroneAuthenticatedPeer(identityFingerprint: "fixture", hardware: .unknown, hello: DroneHello(selectedVersion: 1))
    let remoteID: UUID
    private let lock = NSLock()
    private var envelopes: [DroneEnvelope] = []
    private var closed = false
    private var holdAttach: Bool
    private let stream: AsyncThrowingStream<DroneEnvelope, any Error>
    private let continuation: AsyncThrowingStream<DroneEnvelope, any Error>.Continuation
    var sent: [DroneEnvelope] { lock.withLock { envelopes } }

    init(remoteID: UUID, holdAttach: Bool) {
        self.remoteID = remoteID
        self.holdAttach = holdAttach
        (stream, continuation) = AsyncThrowingStream.makeStream()
    }
    func send(_ envelope: DroneEnvelope) async throws {
        try lock.withLock {
            guard !closed else { throw DroneTransportError.disconnected }
            envelopes.append(envelope)
        }
        if envelope.kind == .attach && lock.withLock({ holdAttach }) { return }
        if envelope.kind == .create || envelope.kind == .attach {
            continuation.yield(DroneEnvelope(kind: envelope.kind == .create ? .created : .attached,
                                             requestID: envelope.requestID,
                                             sessionID: DroneSessionID(rawValue: remoteID)))
        }
    }
    func receive() async throws -> DroneEnvelope {
        var iterator = stream.makeAsyncIterator()
        guard let value = try await iterator.next() else { throw DroneTransportError.disconnected }
        return value
    }
    func releaseAttach() {
        let request = lock.withLock { () -> DroneEnvelope in
            holdAttach = false
            return envelopes.first { $0.kind == .attach }!
        }
        emit(DroneEnvelope(kind: .attached, requestID: request.requestID, sessionID: DroneSessionID(rawValue: remoteID)))
    }

    func emit(_ envelope: DroneEnvelope) { continuation.yield(envelope) }

    func close() {
        lock.withLock { closed = true }
        continuation.finish()
    }
}

private final class ResizeOrderingConnection: DroneConnection, @unchecked Sendable {
    let peer = DroneAuthenticatedPeer(
        identityFingerprint: "resize-fixture", hardware: .unknown, hello: DroneHello(selectedVersion: 1)
    )
    private let lock = NSLock()
    private var pending: [DroneEnvelope] = []
    private var storedResizes: [DroneResizeBody] = []
    private let stream: AsyncThrowingStream<DroneEnvelope, any Error>
    private let continuation: AsyncThrowingStream<DroneEnvelope, any Error>.Continuation

    var resizes: [DroneResizeBody] { lock.withLock { storedResizes } }

    init() {
        (stream, continuation) = AsyncThrowingStream.makeStream()
    }

    func send(_ envelope: DroneEnvelope) async throws {
        guard envelope.kind == .resize, case .resize(let body) = envelope.body else { return }
        lock.withLock {
            storedResizes.append(body)
            pending.append(envelope)
        }
    }

    func releaseResize(at index: Int) {
        let envelope = lock.withLock { pending[index] }
        continuation.yield(DroneEnvelope(
            kind: .ack,
            requestID: envelope.requestID,
            sessionID: envelope.sessionID
        ))
    }

    func receive() async throws -> DroneEnvelope {
        var iterator = stream.makeAsyncIterator()
        guard let envelope = try await iterator.next() else { throw DroneTransportError.disconnected }
        return envelope
    }

    func close() {
        continuation.finish()
    }
}

private final class SessionRaceClient: DroneTerminalClient, @unchecked Sendable {
    let droneID: UUID
    private let remoteID: UUID
    private let lock = NSLock()
    private var createContinuation: CheckedContinuation<UUID, Never>?
    private var attachContinuation: CheckedContinuation<Void, Never>?
    private var outputHandler: (@Sendable (DroneOutputBody) -> Bool)?
    private var storedCreateCount = 0
    private var storedAttachCount = 0
    private var storedClosedSessionIDs: [UUID] = []
    private var storedInputBytes = Data()
    private var storedAttachCursors: [DroneTerminalCursor] = []
    private var storedResyncCount = 0
    private var storedResizes: [DroneResizeBody] = []
    var holdCreate = false
    var holdAttach = false
    var gapNextAttach = false

    var createCount: Int { lock.withLock { storedCreateCount } }
    var attachCount: Int { lock.withLock { storedAttachCount } }
    var closedSessionIDs: [UUID] { lock.withLock { storedClosedSessionIDs } }
    var inputBytes: Data { lock.withLock { storedInputBytes } }
    var attachCursors: [DroneTerminalCursor] { lock.withLock { storedAttachCursors } }
    var resyncCount: Int { lock.withLock { storedResyncCount } }
    var resizes: [DroneResizeBody] { lock.withLock { storedResizes } }

    init(droneID: UUID, remoteID: UUID) {
        self.droneID = droneID
        self.remoteID = remoteID
    }

    func createTerminal(workingDirectory: String?, generation: UInt64, requestID: UUID) async throws -> UUID {
        let shouldHold = lock.withLock { () -> Bool in
            storedCreateCount += 1
            return holdCreate
        }
        if shouldHold {
            _ = await withCheckedContinuation { continuation in
                lock.withLock { createContinuation = continuation }
            }
        }
        return remoteID
    }

    func attachTerminal(_ reference: DroneTerminalSessionReference) async throws {
        try await attachTerminal(reference, after: .zero)
    }

    func attachTerminal(_ reference: DroneTerminalSessionReference, after cursor: DroneTerminalCursor) async throws {
        let action = lock.withLock { () -> (hold: Bool, gap: Bool) in
            storedAttachCount += 1
            storedAttachCursors.append(cursor)
            defer { gapNextAttach = false }
            return (holdAttach, gapNextAttach)
        }
        if action.gap { throw DroneRemoteTerminalError.remote(code: "outputGap") }
        if action.hold {
            await withCheckedContinuation { continuation in
                lock.withLock { attachContinuation = continuation }
            }
        }
    }

    func releaseCreate() {
        let continuation = lock.withLock { () -> CheckedContinuation<UUID, Never>? in
            defer { createContinuation = nil }
            return createContinuation
        }
        continuation?.resume(returning: remoteID)
    }

    func releaseAttach() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { attachContinuation = nil }
            return attachContinuation
        }
        continuation?.resume()
    }

    func resynchronize(_ reference: DroneTerminalSessionReference) async throws {
        lock.withLock { storedResyncCount += 1 }
        emit("fresh", sequence: 40, offset: 4_096)
    }

    func resize(columns: UInt16, rows: UInt16, for reference: DroneTerminalSessionReference) async throws {
        lock.withLock { storedResizes.append(DroneResizeBody(columns: columns, rows: rows)) }
    }

    func emit(_ text: String, sequence: UInt64, offset: UInt64) {
        let handler = lock.withLock { outputHandler }
        _ = handler?(DroneOutputBody(
            sequence: sequence, offset: offset, data: Data(text.utf8), isFinal: false
        ))
    }

    func sendInput(_ data: Data, to reference: DroneTerminalSessionReference) async throws {
        lock.withLock { storedInputBytes.append(data) }
    }

    func close(_ reference: DroneTerminalSessionReference) async throws {
        lock.withLock { storedClosedSessionIDs.append(reference.sessionID) }
    }

    func setOutputHandler(
        _ handler: @escaping @Sendable (DroneOutputBody) -> Bool,
        for reference: DroneTerminalSessionReference
    ) async {
        lock.withLock { outputHandler = handler }
    }

    func foregroundActivity(for reference: DroneTerminalSessionReference) async throws -> TerminalProcessActivity {
        .idle
    }
    func currentDirectory(for reference: DroneTerminalSessionReference) async throws -> String? { nil }
    func interrupt(_ reference: DroneTerminalSessionReference) async throws {}
    func detach(_ reference: DroneTerminalSessionReference) async throws {}
}

private final class DisplayRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    var latest: String { lock.withLock { value } }
    func record(_ text: String) { lock.withLock { value = text } }
}
