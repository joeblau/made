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
        let firstSent = await first.send(.literal("first"))
        precondition(firstSent)
        let originalConnection = factory.connections[0]
        let originalCreateKey = originalConnection.sent.first(where: { $0.kind == .create })?.idempotencyKey
        precondition(originalCreateKey == "terminal-\(pane.id.uuidString)", "create key depends on generation")
        store.retry(id: id)
        precondition(store.terminalClient(for: id) == nil, "retry retained retired client")
        await wait { factory.connections.count == 2 && store.states[id]?.isConnected == true }
        let next = provider.session(for: pane)
        precondition(next.identity.generation > first.identity.generation)
        let staleSent = await first.send(.literal("stale"))
        precondition(!staleSent, "retired session accepted input")
        let reattached = try await provider.restore(pane: pane)
        precondition(reattached.remoteSessionID == restored.remoteSessionID)
        let nextSent = await next.send(.literal("next"))
        precondition(nextSent)
        precondition(!factory.connections[1].sent.contains(where: { $0.kind == .create }), "reattach created another session")
        precondition(factory.connections[1].sent.contains(where: { $0.kind == .input }), "replacement did not receive input")
        precondition(originalConnection.sent.filter { $0.kind == .input }.count == 1)

        factory.revokeFails = true
        await store.forget(id: id)
        precondition(store.records.count == 1 && store.persistenceError != nil, "failed revoke erased metadata")
        precondition(provider.session(for: pane) is UnavailableTerminalSession)
        factory.revokeFails = false
        await store.forget(id: id)
        precondition(store.records.isEmpty, "successful revoke retained metadata")
        precondition(provider.session(for: pane) is UnavailableTerminalSession)
        store.stop()
        print("Drone session proof passed: offline recovery, client replacement, stable ID/key, stale input rejection, revoke failure/retry.")
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
    func connect(_ request: DroneTransportRequest) async throws -> any DroneConnection {
        let connection = SessionConnection(remoteID: remoteID)
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
    private let stream: AsyncThrowingStream<DroneEnvelope, any Error>
    private let continuation: AsyncThrowingStream<DroneEnvelope, any Error>.Continuation
    var sent: [DroneEnvelope] { lock.withLock { envelopes } }

    init(remoteID: UUID) {
        self.remoteID = remoteID
        (stream, continuation) = AsyncThrowingStream.makeStream()
    }
    func send(_ envelope: DroneEnvelope) async throws {
        try lock.withLock {
            guard !closed else { throw DroneTransportError.disconnected }
            envelopes.append(envelope)
        }
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
    func close() {
        lock.withLock { closed = true }
        continuation.finish()
    }
}
