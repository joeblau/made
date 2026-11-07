import Foundation

@main
@MainActor
enum DroneReapprovalProof {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("Drone reapproval proof failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        let worker = try Peer(role: .worker)
        let controller = try Peer(role: .controller)
        defer {
            controller.transport.stop()
            worker.transport.stop()
        }
        worker.transport.startListening()
        let listening = try await worker.events.wait("listener") {
            if case .listening = $0 { return true }
            return false
        }
        guard case .listening(let port) = listening else { throw ProofError.failed("listener event") }
        let originalKey = try controller.identity.loadOrCreate().publicKey.rawRepresentation
        try await pair(controller: controller, worker: worker, port: port)
        let firstWorkerConnection = try await connected(worker, peerID: controller.id)
        let firstControllerConnection = try await connected(controller, peerID: worker.id)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            worker.transport.revoke(controller.id) { result in
                continuation.resume(with: result.mapError { $0 as any Error })
            }
        }
        try await disconnected(worker, connection: firstWorkerConnection)
        try await disconnected(controller, connection: firstControllerConnection)
        guard try worker.pairings.pinnedKey(for: controller.id) == nil else {
            throw ProofError.failed("revocation retained pin")
        }

        // Ordinary reconnect must remain denied until explicit owner approval.
        controller.transport.connect(peerID: worker.id, host: "127.0.0.1", port: port)
        _ = try await controller.events.wait("revoked reconnect rejection") {
            if case .disconnected = $0 { return true }
            return false
        }
        guard !worker.events.containsConnection() else {
            throw ProofError.failed("revoked identity reconnected without approval")
        }
        worker.events.clear()
        controller.events.clear()

        // Both transports and identity stores survive: no restart or key rotation masks the tombstone.
        try await pair(controller: controller, worker: worker, port: port)
        let reapprovedWorkerConnection = try await connected(worker, peerID: controller.id)
        let reapprovedControllerConnection = try await connected(controller, peerID: worker.id)
        guard try controller.identity.loadOrCreate().publicKey.rawRepresentation == originalKey,
              try worker.pairings.pinnedKey(for: controller.id)?.rawRepresentation == originalKey else {
            throw ProofError.failed("reapproval changed identity or pinned key")
        }
        controller.transport.disconnect(reapprovedControllerConnection)
        try await disconnected(controller, connection: reapprovedControllerConnection)
        try await disconnected(worker, connection: reapprovedWorkerConnection)
        worker.events.clear()
        controller.events.clear()

        // This uses stored pins, with no pairing announcement or approval callback.
        controller.transport.connect(peerID: worker.id, host: "127.0.0.1", port: port)
        let finalWorkerConnection = try await connected(worker, peerID: controller.id)
        let finalControllerConnection = try await connected(controller, peerID: worker.id)
        let requestID = UUID()
        let envelope = DroneEnvelope(kind: .activity, requestID: requestID, sessionID: DroneSessionID())
        try envelope.validate()
        controller.transport.send(envelope, on: finalControllerConnection)
        _ = try await worker.events.wait("encrypted delivery after normal reconnect") {
            if case .envelope(let connection, let peer, let envelope) = $0 {
                return connection == finalWorkerConnection && peer == controller.id && envelope.requestID == requestID
            }
            return false
        }
        guard !worker.events.containsApproval(), !controller.events.containsApproval() else {
            throw ProofError.failed("normal reconnect required another approval")
        }
        print("Drone reapproval proof passed: approve, revoke, deny, same-key reapprove, normal reconnect, encrypted delivery.")
    }

    private static func pair(controller: Peer, worker: Peer, port: UInt16) async throws {
        controller.transport.pair(peerID: worker.id, host: "127.0.0.1", port: port)
        let workerEvent = try await worker.events.wait("worker owner approval request") {
            if case .pairingRequired = $0 { return true }
            return false
        }
        let controllerEvent = try await controller.events.wait("controller approval request") {
            if case .pairingRequired = $0 { return true }
            return false
        }
        guard case .pairingRequired(let workerRequest) = workerEvent,
              case .pairingRequired(let controllerRequest) = controllerEvent,
              workerRequest.peerID == controller.id else { throw ProofError.failed("pairing identity") }
        controller.transport.resolvePairing(requestID: controllerRequest.id, approved: true)
        worker.transport.resolvePairing(requestID: workerRequest.id, approved: true)
    }

    private static func connected(_ peer: Peer, peerID: DronePeerID) async throws -> DroneConnectionID {
        let event = try await peer.events.wait("authenticated connection") {
            if case .connected = $0 { return true }
            return false
        }
        guard case .connected(let connection, let authenticatedPeer, _) = event,
              authenticatedPeer == peerID else { throw ProofError.failed("authenticated identity") }
        return connection
    }

    private static func disconnected(_ peer: Peer, connection: DroneConnectionID) async throws {
        _ = try await peer.events.wait("disconnect") {
            if case .disconnected(let id, _) = $0 { return id == connection }
            return false
        }
    }
}

private struct Peer {
    let identity: DroneIdentityStore
    let pairings: DronePairingStore
    let id: DronePeerID
    let transport: DroneLANTransport
    let events = Events()

    init(role: DroneRole) throws {
        let storage = MemoryStorage()
        identity = DroneIdentityStore(role: role, storage: storage)
        pairings = DronePairingStore(role: role, storage: storage)
        id = try identity.loadOrCreatePeerID()
        transport = DroneLANTransport(role: role, identityStore: identity, pairingStore: pairings)
        transport.onEvent = { [events] in events.record($0) }
    }
}

private final class MemoryStorage: PairingSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func read(account: String) throws -> Data? { lock.withLock { values[account] } }
    func write(_ data: Data, account: String) throws { lock.withLock { values[account] = data } }
    func delete(account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DroneTransportEvent] = []

    func record(_ event: DroneTransportEvent) { lock.withLock { events.append(event) } }
    func clear() { lock.withLock { events.removeAll() } }
    func containsConnection() -> Bool {
        lock.withLock {
            events.contains {
                if case .connected = $0 { return true }
                return false
            }
        }
    }
    func containsApproval() -> Bool {
        lock.withLock {
            events.contains {
                if case .pairingRequired = $0 { return true }
                return false
            }
        }
    }

    @MainActor
    func wait(_ label: String, matching predicate: (DroneTransportEvent) -> Bool) async throws -> DroneTransportEvent {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if let event = take(matching: predicate) { return event }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ProofError.failed("timed out waiting for \(label)")
    }

    private func take(matching predicate: (DroneTransportEvent) -> Bool) -> DroneTransportEvent? {
        lock.withLock {
            guard let index = events.firstIndex(where: predicate) else { return nil }
            return events.remove(at: index)
        }
    }
}

private enum ProofError: Error {
    case failed(String)
}
