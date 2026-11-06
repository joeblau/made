import Foundation

@MainActor
final class DroneLANTransportFactory: DroneTransportFactory {
    var onPairingRequest: ((DronePairingRequest) -> Void)?

    private let transport: DroneLANTransport
    private let identityStore: DroneIdentityStore
    private let pairingStore: DronePairingStore
    private struct PendingConnection {
        let peerID: DronePeerID
        let continuation: CheckedContinuation<any DroneConnection, any Error>
    }
    private var pendingConnections: [DroneConnectionID: PendingConnection] = [:]
    private var connections: [DroneConnectionID: DroneLANConnection] = [:]

    init(
        transport: DroneLANTransport? = nil,
        identityStore: DroneIdentityStore? = nil,
        pairingStore: DronePairingStore? = nil
    ) {
        let identity = identityStore ?? DroneIdentityStore(role: .controller)
        let store = pairingStore ?? DronePairingStore(role: .controller)
        self.identityStore = identity
        self.pairingStore = store
        self.transport = transport ?? DroneLANTransport(
            role: .controller,
            identityStore: identity,
            pairingStore: store
        )
        self.transport.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
    }

    func authenticatedControllerID() throws -> UUID {
        try identityStore.loadOrCreatePeerID().rawValue
    }

    func connect(_ request: DroneTransportRequest) async throws -> any DroneConnection {
        try Task.checkCancellation()
        let peerID = DronePeerID(rawValue: request.droneID)
        let existingPin = try pairingStore.pinnedKey(for: peerID)
        // Retire the old pending attempt before enqueueing its replacement.
        for (id, pending) in pendingConnections where pending.peerID == peerID {
            cancel(id, error: CancellationError())
        }
        let id = DroneConnectionID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingConnections[id] = PendingConnection(peerID: peerID, continuation: continuation)
                switch request.endpoint {
                case .hostPort(let host, let port):
                    if existingPin == nil {
                        transport.pair(peerID: peerID, host: host, port: port, connectionID: id)
                    } else {
                        transport.connect(peerID: peerID, host: host, port: port, connectionID: id)
                    }
                case .bonjour(let name, let type, let domain):
                    if existingPin == nil {
                        transport.pair(peerID: peerID, serviceName: name, type: type, domain: domain, connectionID: id)
                    } else {
                        transport.connect(peerID: peerID, serviceName: name, type: type, domain: domain, connectionID: id)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id, error: CancellationError()) }
        }
    }

    private func cancel(_ id: DroneConnectionID, error: any Error) {
        guard let pending = pendingConnections.removeValue(forKey: id) else { return }
        transport.disconnect(id)
        pending.continuation.resume(throwing: error)
    }

    func revoke(droneID: UUID) async throws {
        let peerID = DronePeerID(rawValue: droneID)
        for (id, pending) in pendingConnections where pending.peerID == peerID {
            cancel(id, error: DroneTransportError.revoked)
        }
        for connection in Array(connections.values) where connection.peerID == peerID {
            connection.close()
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            transport.revoke(peerID) { result in
                switch result {
                case .success: continuation.resume()
                case .failure: continuation.resume(throwing: DroneTransportError.revocationFailed)
                }
            }
        }
    }

    func resolvePairing(requestID: UUID, approved: Bool) {
        transport.resolvePairing(requestID: requestID, approved: approved)
    }

    private func handle(_ event: DroneTransportEvent) {
        switch event {
        case .listening:
            break
        case .connecting:
            break
        case .connected(let id, let peerID, let hello):
            guard let pending = pendingConnections.removeValue(forKey: id), pending.peerID == peerID else {
                transport.disconnect(id)
                return
            }
            do {
                guard let key = try pairingStore.pinnedKey(for: peerID) else {
                    throw DroneTransportError.unauthorized
                }
                let peer = DroneAuthenticatedPeer(
                    identityFingerprint: key.rawRepresentation.base64EncodedString(),
                    hardware: .unknown,
                    hello: hello
                )
                try peer.validate()
                let connection = DroneLANConnection(
                    transport: transport,
                    id: id,
                    peer: peer,
                    peerID: peerID,
                    onClose: { [weak self] in
                        Task { @MainActor in self?.connections.removeValue(forKey: id) }
                    }
                )
                connections[id] = connection
                pending.continuation.resume(returning: connection)
            } catch {
                transport.disconnect(id)
                pending.continuation.resume(throwing: error)
            }
        case .envelope(let id, _, let envelope):
            connections[id]?.receive(envelope)
        case .pairingRequired(let request):
            onPairingRequest?(request)
        case .disconnected(let id, _):
            connections[id]?.close()
            pendingConnections.removeValue(forKey: id)?.continuation.resume(throwing: DroneTransportError.disconnected)
        case .failed(let id, let failure):
            // Listener/global events must not terminate unrelated controller attempts.
            guard let id else { return }
            connections[id]?.close()
            cancel(id, error: Self.error(for: failure))
        }
    }

    private static func error(for failure: DroneTransportFailure) -> DroneTransportError {
        switch failure {
        case .invalidRole, .storage, .protocolViolation: .remoteRejected
        case .invalidBonjourInstance: .connectionFailed
        case .pairingNotFound, .peerNotPaired: .pairingRequired
        case .peerRevoked: .revoked
        case .connectionLimit: .busy
        case .authentication: .unauthorized
        case .disconnected: .disconnected
        }
    }
}

private final class DroneLANConnection: DroneConnection, @unchecked Sendable {
    let peer: DroneAuthenticatedPeer
    let peerID: DronePeerID

    private let transport: DroneLANTransport
    private let id: DroneConnectionID
    private let onClose: @Sendable () -> Void
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<DroneEnvelope, any Error>.Continuation?
    private var stream: AsyncThrowingStream<DroneEnvelope, any Error>?
    private var closed = false

    init(
        transport: DroneLANTransport,
        id: DroneConnectionID,
        peer: DroneAuthenticatedPeer,
        peerID: DronePeerID,
        onClose: @escaping @Sendable () -> Void
    ) {
        self.transport = transport
        self.id = id
        self.peer = peer
        self.peerID = peerID
        self.onClose = onClose
    }

    func send(_ envelope: DroneEnvelope) async throws {
        guard !lock.withLock({ closed }) else { throw DroneTransportError.disconnected }
        transport.send(envelope, on: id)
    }

    func receive() async throws -> DroneEnvelope {
        let stream = lock.withLock { () -> AsyncThrowingStream<DroneEnvelope, any Error> in
            if let stream { return stream }
            let stream = AsyncThrowingStream<DroneEnvelope, any Error> { continuation in
                self.continuation = continuation
            }
            self.stream = stream
            return stream
        }
        var iterator = stream.makeAsyncIterator()
        guard let envelope = try await iterator.next() else { throw DroneTransportError.disconnected }
        return envelope
    }

    func receive(_ envelope: DroneEnvelope) {
        _ = lock.withLock { continuation?.yield(envelope) }
    }

    func close() {
        let wasClosed = lock.withLock { () -> Bool in
            guard !closed else { return true }
            closed = true
            continuation?.finish()
            continuation = nil
            stream = nil
            return false
        }
        guard !wasClosed else { return }
        transport.disconnect(id)
        onClose()
    }
}
