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

        factory.revokeFails = true
        await store.forget(id: id)
        precondition(store.records.count == 1 && store.persistenceError != nil, "failed revoke erased metadata")
        precondition(provider.session(for: pane) is UnavailableTerminalSession)
        factory.revokeFails = false
        await store.forget(id: id)
        precondition(store.records.isEmpty, "successful revoke retained metadata")
        precondition(provider.session(for: pane) is UnavailableTerminalSession)
        store.stop()
        print("Drone session proof passed: offline recovery, client replacement, stable ID/key/cursor, split UTF-8, output isolation/bounds, stale input, revoke retry.")
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

private final class DisplayRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    var latest: String { lock.withLock { value } }
    func record(_ text: String) { lock.withLock { value = text } }
}
