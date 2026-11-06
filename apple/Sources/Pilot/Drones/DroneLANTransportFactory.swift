import Foundation

@MainActor
final class DroneLANTransportFactory: DroneTransportFactory {
    var onPairingRequest: ((DronePairingRequest) -> Void)?

    private let transport: DroneLANTransport
    private let identityStore: DroneIdentityStore
    private let pairingStore: DronePairingStore
    private var pendingPeers: [DronePeerID: CheckedContinuation<any DroneConnection, any Error>] = [:]
    private var pendingConnections: [DroneConnectionID: CheckedContinuation<any DroneConnection, any Error>] = [:]
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
        let peerID = DronePeerID(rawValue: request.droneID)
        let existingPin = try pairingStore.pinnedKey(for: peerID)
        return try await withCheckedThrowingContinuation { continuation in
            pendingPeers[peerID] = continuation
            switch request.endpoint {
            case .hostPort(let host, let port):
                if existingPin == nil {
                    transport.pair(peerID: peerID, host: host, port: port)
                } else {
                    transport.connect(peerID: peerID, host: host, port: port)
                }
            case .bonjour(let name, let type, let domain):
                if existingPin == nil {
                    transport.pair(peerID: peerID, serviceName: name, type: type, domain: domain)
                } else {
                    transport.connect(peerID: peerID, serviceName: name, type: type, domain: domain)
                }
            }
        }
    }

    func revoke(droneID: UUID) async throws {
        let peerID = DronePeerID(rawValue: droneID)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            transport.revoke(peerID) { result in
                switch result {
                case .success: continuation.resume()
                case .failure: continuation.resume(throwing: DroneTransportError.revocationFailed)
                }
            }
        }
        if let continuation = pendingPeers.removeValue(forKey: peerID) {
            continuation.resume(throwing: DroneTransportError.revoked)
        }
    }

    func resolvePairing(requestID: UUID, approved: Bool) {
        transport.resolvePairing(requestID: requestID, approved: approved)
    }

    private func handle(_ event: DroneTransportEvent) {
        switch event {
        case .listening:
            break
        case .connecting(let id, let peerID):
            guard let continuation = pendingPeers.removeValue(forKey: peerID) else { return }
            pendingConnections[id] = continuation
        case .connected(let id, let peerID, let hello):
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
                    onClose: { [weak self] in self?.connections.removeValue(forKey: id) }
                )
                connections[id] = connection
                pendingConnections.removeValue(forKey: id)?.resume(returning: connection)
            } catch {
                transport.disconnect(id)
                pendingConnections.removeValue(forKey: id)?.resume(throwing: error)
            }
        case .envelope(let id, _, let envelope):
            connections[id]?.receive(envelope)
        case .pairingRequired(let request):
            onPairingRequest?(request)
        case .disconnected(let id, _):
            connections[id]?.close()
            pendingConnections.removeValue(forKey: id)?.resume(throwing: DroneTransportError.disconnected)
        case .failed(let id, let failure):
            let error = Self.error(for: failure)
            if let id, let continuation = pendingConnections.removeValue(forKey: id) {
                continuation.resume(throwing: error)
            } else {
                let continuations = pendingPeers.values
                pendingPeers.removeAll()
                for continuation in continuations { continuation.resume(throwing: error) }
            }
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

    private let transport: DroneLANTransport
    private let id: DroneConnectionID
    private let onClose: () -> Void
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<DroneEnvelope, any Error>.Continuation?
    private var stream: AsyncThrowingStream<DroneEnvelope, any Error>?
    private var closed = false

    init(
        transport: DroneLANTransport,
        id: DroneConnectionID,
        peer: DroneAuthenticatedPeer,
        onClose: @escaping () -> Void
    ) {
        self.transport = transport
        self.id = id
        self.peer = peer
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
