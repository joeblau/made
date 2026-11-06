import Foundation
import Network

@main
enum DroneConnectionProof {
    @MainActor
    static func main() async throws {
        let deadline = Task {
            try await Task.sleep(for: .seconds(10))
            fatalError("Connection proof timed out")
        }
        defer { deadline.cancel() }
        let server = try StalledServer()
        defer { server.stop() }
        let port = try await server.start()
        let storage = MemoryStorage()
        let identity = DroneIdentityStore(role: .controller, storage: storage)
        let pairings = DronePairingStore(role: .controller, storage: storage)
        let transport = DroneLANTransport(role: .controller, identityStore: identity, pairingStore: pairings)
        let factory = DroneLANTransportFactory(transport: transport, identityStore: identity, pairingStore: pairings)
        let peer = UUID()
        let request = DroneTransportRequest(
            droneID: peer, endpoint: .hostPort(host: "127.0.0.1", port: port),
            expectedIdentityFingerprint: nil, hello: DroneHello()
        )
        let first = Task { try await factory.connect(request) }
        await wait { server.acceptedCount == 1 }
        let replacement = Task { try await factory.connect(request) }
        do {
            _ = try await first.value
            fatalError("replaced attempt succeeded")
        } catch is CancellationError {}
        await wait { server.acceptedCount == 2 }
        replacement.cancel()
        do {
            _ = try await replacement.value
            fatalError("cancelled attempt succeeded")
        } catch is CancellationError {}

        var retainedCompleted = false
        let retained = Task {
            defer { retainedCompleted = true }
            return try await factory.connect(request)
        }
        await wait { server.acceptedCount == 3 }
        // An early failure has a connection ID and cannot fail the stalled peer.
        storage.failIdentityRead = true
        var failingRequest = request
        failingRequest.droneID = UUID()
        do {
            _ = try await factory.connect(failingRequest)
            fatalError("failing identity unexpectedly connected")
        } catch DroneTransportError.remoteRejected {}
        precondition(!retainedCompleted, "one peer's failure ended another peer's attempt")
        storage.failIdentityRead = false
        try await factory.revoke(droneID: peer)
        do {
            _ = try await retained.value
            fatalError("revoked attempt succeeded")
        } catch DroneTransportError.revoked {}
        print("Drone connection proof passed: pending replacement, cancellation, per-attempt failure isolation, pending revoke.")
    }

    @MainActor
    static func wait(_ condition: () -> Bool) async {
        while !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

private final class StalledServer: @unchecked Sendable {
    let listener: NWListener
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    var acceptedCount: Int { lock.withLock { connections.count } }

    init() throws { listener = try NWListener(using: .tcp, on: .any) }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [self] connection in
            lock.withLock { connections.append(connection) }
            connection.start(queue: .global())
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                if case .ready = state {
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!.rawValue)
                }
            }
            listener.start(queue: .global())
        }
    }

    func stop() {
        listener.cancel()
        lock.withLock { connections.forEach { $0.cancel() } }
    }
}

private final class MemoryStorage: PairingSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var failRead = false
    var failIdentityRead: Bool {
        get { lock.withLock { failRead } }
        set { lock.withLock { failRead = newValue } }
    }
    func read(account: String) throws -> Data? {
        try lock.withLock {
            if failRead && account == "app.blau.drone.identity.controller" {
                throw DronePairingError.invalidIdentity
            }
            return values[account]
        }
    }
    func write(_ data: Data, account: String) throws { lock.withLock { values[account] = data } }
    func delete(account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}
