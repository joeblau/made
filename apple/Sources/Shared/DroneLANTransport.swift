import CryptoKit
import Foundation
import Network

struct DroneConnectionID: Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

enum DroneTransportFailure: Error, Equatable {
    case invalidRole
    case invalidBonjourInstance
    case pairingNotFound
    case peerNotPaired
    case peerRevoked
    case connectionLimit
    case storage
    case authentication
    case protocolViolation
    case disconnected
}

enum DroneTransportEvent {
    case listening(port: UInt16)
    case connecting(id: DroneConnectionID, peerID: DronePeerID)
    case connected(id: DroneConnectionID, peerID: DronePeerID, hello: DroneHello)
    case envelope(id: DroneConnectionID, peerID: DronePeerID, envelope: DroneEnvelope)
    case pairingRequired(DronePairingRequest)
    case disconnected(id: DroneConnectionID, peerID: DronePeerID?)
    case failed(id: DroneConnectionID?, failure: DroneTransportFailure)
}

final class DroneLANTransport: @unchecked Sendable {
    static let serviceType = "_blau-drone._tcp"

    private enum Phase {
        case connecting
        case awaitingControllerPairing(
            localKey: Curve25519.KeyAgreement.PrivateKey,
            existingPin: Curve25519.KeyAgreement.PublicKey?
        )
        case awaitingControllerApproval(
            localKey: Curve25519.KeyAgreement.PrivateKey,
            candidate: DronePairingAnnouncement,
            existingPin: Curve25519.KeyAgreement.PublicKey?
        )
        case awaitingNoiseResponse(DronePendingInitiator)
        case awaitingWorkerNoise
        case awaitingWorkerApproval(
            localKey: Curve25519.KeyAgreement.PrivateKey,
            request: DronePairingRequest,
            candidate: DronePairingAnnouncement,
            pendingNoise: Data?
        )
        case ready(DroneSecureChannel)
    }

    private final class ConnectionState: @unchecked Sendable {
        let id: DroneConnectionID
        let connection: NWConnection
        var phase: Phase
        var peerID: DronePeerID?
        var handshakeDeadline: DispatchWorkItem?
        var heartbeat: DispatchSourceTimer?
        var lastValidRecord = Date()
        var closed = false

        init(id: DroneConnectionID, connection: NWConnection, phase: Phase, peerID: DronePeerID?) {
            self.id = id
            self.connection = connection
            self.phase = phase
            self.peerID = peerID
        }
    }

    private let role: DroneRole
    private let identityStore: DroneIdentityStore
    private let pairingStore: DronePairingStore
    private let queue = DispatchQueue(label: "app.blau.drone.transport")
    private var listener: NWListener?
    private var connections: [DroneConnectionID: ConnectionState] = [:]
    private var requests: [UUID: DroneConnectionID] = [:]
    private var revokedPeerIDs: Set<DronePeerID> = []
    private var running = false

    var onEvent: ((DroneTransportEvent) -> Void)?

    init(
        role: DroneRole,
        identityStore: DroneIdentityStore? = nil,
        pairingStore: DronePairingStore? = nil
    ) {
        self.role = role
        self.identityStore = identityStore ?? DroneIdentityStore(role: role)
        self.pairingStore = pairingStore ?? DronePairingStore(role: role)
    }

    deinit {
        listener?.cancel()
        for state in connections.values {
            state.handshakeDeadline?.cancel()
            state.heartbeat?.cancel()
            state.connection.cancel()
        }
    }

    func startListening(port: UInt16 = 0, bonjourInstanceID: String? = nil) {
        queue.async(execute: DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.role == .worker else {
                self.emit(.failed(id: nil, failure: .invalidRole))
                return
            }
            if let bonjourInstanceID, !Self.isValidBonjourInstance(bonjourInstanceID) {
                self.emit(.failed(id: nil, failure: .invalidBonjourInstance))
                return
            }
            self.stopLocked()
            self.running = true
            do {
                let listener = try NWListener(using: Self.tcpParameters(), on: .init(integerLiteral: port))
                if let bonjourInstanceID {
                    listener.service = NWListener.Service(
                        name: bonjourInstanceID,
                        type: Self.serviceType,
                        txtRecord: NWTXTRecord(["version": String(DroneLimits.protocolVersion)])
                    )
                }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if let port = listener.port {
                            self.emit(.listening(port: port.rawValue))
                        }
                    case .failed:
                        self.emit(.failed(id: nil, failure: .disconnected))
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.adopt(connection)
                }
                self.listener = listener
                listener.start(queue: self.queue)
            } catch {
                self.emit(.failed(id: nil, failure: .disconnected))
            }
        })
    }

    func connect(
        peerID: DronePeerID, host: String, port: UInt16,
        connectionID: DroneConnectionID = DroneConnectionID()
    ) {
        begin(
            id: connectionID,
            peerID: peerID,
            endpoint: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: port)),
            pairing: false
        )
    }

    func connect(
        peerID: DronePeerID, serviceName: String, type: String, domain: String,
        connectionID: DroneConnectionID = DroneConnectionID()
    ) {
        begin(
            id: connectionID,
            peerID: peerID,
            endpoint: .service(name: serviceName, type: type, domain: domain, interface: nil),
            pairing: false
        )
    }

    func pair(
        peerID: DronePeerID, host: String, port: UInt16,
        connectionID: DroneConnectionID = DroneConnectionID()
    ) {
        begin(
            id: connectionID,
            peerID: peerID,
            endpoint: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: port)),
            pairing: true
        )
    }

    func pair(
        peerID: DronePeerID, serviceName: String, type: String, domain: String,
        connectionID: DroneConnectionID = DroneConnectionID()
    ) {
        begin(
            id: connectionID,
            peerID: peerID,
            endpoint: .service(name: serviceName, type: type, domain: domain, interface: nil),
            pairing: true
        )
    }

    /// Local lifecycle query used to retire owner approval prompts after a
    /// handshake closes. Never exposes pins, keys, or remote execution payloads.
    func pendingPairingRequestIDs() async -> Set<UUID> {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: Set(requests.keys))
            }
        }
    }

    func resolvePairing(requestID: UUID, approved: Bool) {
        queue.async { [weak self] in
            guard let self, let id = self.requests.removeValue(forKey: requestID),
                  let state = self.connections[id], !state.closed
            else {
                self?.emit(.failed(id: nil, failure: .pairingNotFound))
                return
            }
            guard approved else {
                self.close(state, failure: nil)
                return
            }
            do {
                switch state.phase {
                case .awaitingControllerApproval(let localKey, let candidate, let existingPin):
                    guard let peerID = state.peerID else { throw DroneTransportFailure.peerNotPaired }
                    try self.pairingStore.approve(
                        candidate.publicKey,
                        for: peerID,
                        replacing: existingPin
                    )
                    self.revokedPeerIDs.remove(peerID)
                    try self.startNoise(state, localKey: localKey, workerKey: candidate.publicKey)
                case .awaitingWorkerApproval(let localKey, let request, let candidate, let pendingNoise):
                    try self.pairingStore.approve(
                        candidate.publicKey,
                        for: request.peerID,
                        replacing: nil
                    )
                    self.revokedPeerIDs.remove(request.peerID)
                    state.peerID = request.peerID
                    if let pendingNoise {
                        try self.acceptWorkerNoise(
                            pendingNoise,
                            state: state,
                            localKey: localKey,
                            pinnedControllers: [(request.peerID, candidate.publicKey)]
                        )
                    } else {
                        state.phase = .awaitingWorkerNoise
                    }
                default:
                    throw DroneTransportFailure.pairingNotFound
                }
            } catch {
                self.close(state, failure: .storage)
            }
        }
    }

    func send(_ envelope: DroneEnvelope, on id: DroneConnectionID) {
        queue.async { [weak self] in
            guard let self, let state = self.connections[id], !state.closed else { return }
            do {
                guard case .ready(var channel) = state.phase else {
                    throw DroneProtocolError.unauthorized
                }
                let record = try channel.seal(envelope)
                state.phase = .ready(channel)
                self.sendRecord(record, state: state)
            } catch {
                self.close(state, failure: .protocolViolation)
            }
        }
    }

    func disconnect(_ id: DroneConnectionID) {
        queue.async { [weak self] in
            guard let self, let state = self.connections[id] else { return }
            self.close(state, failure: nil)
        }
    }

    func revoke(
        _ peerID: DronePeerID,
        completion: (@Sendable (Result<Void, DroneTransportFailure>) -> Void)? = nil
    ) {
        // Retain the transport until the caller receives a definitive storage result.
        queue.async { [self] in
            revokedPeerIDs.insert(peerID)
            for state in Array(connections.values) where state.peerID == peerID {
                close(state, failure: nil)
            }
            do {
                try pairingStore.revoke(peerID)
                completion?(.success(()))
            } catch {
                if let completion {
                    completion(.failure(.storage))
                } else {
                    emit(.failed(id: nil, failure: .storage))
                }
            }
        }
    }

    func rotateIdentity() {
        queue.async { [weak self] in
            guard let self else { return }
            for state in Array(self.connections.values) {
                self.close(state, failure: nil)
            }
            do {
                _ = try self.identityStore.rotate()
            } catch {
                self.emit(.failed(id: nil, failure: .storage))
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopLocked()
        }
    }

    private func begin(id: DroneConnectionID, peerID: DronePeerID, endpoint: NWEndpoint, pairing: Bool) {
        queue.async { [weak self] in
            guard let self, self.role == .controller else {
                self?.emit(.failed(id: id, failure: .invalidRole))
                return
            }
            guard pairing || !self.revokedPeerIDs.contains(peerID) else {
                self.emit(.failed(id: id, failure: .peerRevoked))
                return
            }
            // The controller owns one outgoing connection per saved worker. The
            // eight-connection preauthentication budget applies only to a worker listener.
            guard self.connections.count < DroneLimits.maxPairedWorkers,
                  !self.connections.values.contains(where: { $0.peerID == peerID && !$0.closed })
            else {
                self.emit(.failed(id: id, failure: .connectionLimit))
                return
            }
            do {
                let localKey = try self.identityStore.loadOrCreate()
                let existingPin = try self.pairingStore.pinnedKey(for: peerID)
                guard pairing || existingPin != nil else { throw DroneTransportFailure.peerNotPaired }
                let connection = NWConnection(to: endpoint, using: Self.tcpParameters())
                let state = ConnectionState(
                    id: id,
                    connection: connection,
                    phase: .connecting,
                    peerID: peerID
                )
                self.connections[state.id] = state
                self.emit(.connecting(id: state.id, peerID: peerID))
                self.configure(state) {
                    if pairing {
                        let announcement = try DronePairingAnnouncement.make(
                            localKey: localKey,
                            senderID: self.identityStore.loadOrCreatePeerID()
                        )
                        state.phase = .awaitingControllerPairing(
                            localKey: localKey,
                            existingPin: existingPin
                        )
                        self.sendRecord(try announcement.encode(), state: state)
                    } else {
                        guard let existingPin else { throw DroneTransportFailure.peerNotPaired }
                        try self.startNoise(state, localKey: localKey, workerKey: existingPin)
                    }
                }
            } catch let failure as DroneTransportFailure {
                self.emit(.failed(id: id, failure: failure))
            } catch {
                self.emit(.failed(id: id, failure: .storage))
            }
        }
    }

    private func adopt(_ connection: NWConnection) {
        guard running else {
            connection.cancel()
            return
        }
        guard connections.count < DroneLimits.maxConnectionsPerWorker else {
            connection.cancel()
            emit(.failed(id: nil, failure: .connectionLimit))
            return
        }
        let state = ConnectionState(
            id: DroneConnectionID(),
            connection: connection,
            phase: .awaitingWorkerNoise,
            peerID: nil
        )
        connections[state.id] = state
        configure(state) { }
    }

    private func configure(_ state: ConnectionState, ready: @escaping @Sendable () throws -> Void) {
        state.connection.stateUpdateHandler = { [weak self, weak state] update in
            guard let self, let state, !state.closed else { return }
            switch update {
            case .ready:
                do {
                    try ready()
                    self.scheduleHandshakeDeadline(state)
                    self.receivePrefix(state)
                } catch {
                    self.close(state, failure: .authentication)
                }
            case .failed:
                self.close(state, failure: .disconnected)
            case .cancelled:
                self.close(state, failure: nil)
            default:
                break
            }
        }
        state.connection.start(queue: queue)
    }

    private func startNoise(
        _ state: ConnectionState,
        localKey: Curve25519.KeyAgreement.PrivateKey,
        workerKey: Curve25519.KeyAgreement.PublicKey
    ) throws {
        let started = try DroneHandshake.start(localKey: localKey, pinnedWorkerKey: workerKey)
        state.phase = .awaitingNoiseResponse(started.pending)
        sendRecord(started.message, state: state)
    }

    private func receivePrefix(_ state: ConnectionState) {
        guard !state.closed else { return }
        state.connection.receive(
            minimumIncompleteLength: DroneWire.headerSize,
            maximumLength: DroneWire.headerSize
        ) { [weak self, weak state] content, _, _, error in
            guard let self, let state, !state.closed else { return }
            if error != nil {
                self.close(state, failure: .disconnected)
                return
            }
            guard let content, content.count == DroneWire.headerSize else {
                self.close(state, failure: .disconnected)
                return
            }
            do {
                let length = try DroneWire.payloadLength(content)
                let maximumLength: Int
                if case .ready = state.phase {
                    maximumLength = DroneLimits.maxFrameBytes
                } else {
                    maximumLength = DroneLimits.maxHandshakeBytes
                }
                guard length <= maximumLength else { throw DroneProtocolError.messageTooLarge }
                self.receivePayload(state, length: length)
            } catch {
                self.close(state, failure: .protocolViolation)
            }
        }
    }

    private func receivePayload(_ state: ConnectionState, length: Int) {
        state.connection.receive(minimumIncompleteLength: length, maximumLength: length) {
            [weak self, weak state] content, _, _, error in
            guard let self, let state, !state.closed else { return }
            if error != nil {
                self.close(state, failure: .disconnected)
                return
            }
            guard let content, content.count == length else {
                self.close(state, failure: .disconnected)
                return
            }
            do {
                try self.handle(content, state: state)
                self.receivePrefix(state)
            } catch {
                self.close(state, failure: .protocolViolation)
            }
        }
    }

    private func handle(_ record: Data, state: ConnectionState) throws {
        switch state.phase {
        case .awaitingControllerPairing(let localKey, let existingPin):
            let candidate = try DronePairingAnnouncement.decode(record)
            guard let peerID = state.peerID else { throw DroneTransportFailure.peerNotPaired }
            let request = try candidate.request(
                localKey: localKey,
                peerID: peerID,
                existingPin: existingPin
            )
            state.phase = .awaitingControllerApproval(
                localKey: localKey,
                candidate: candidate,
                existingPin: existingPin
            )
            requests[request.id] = state.id
            emit(.pairingRequired(request))

        case .awaitingControllerApproval:
            throw DroneTransportFailure.authentication

        case .awaitingNoiseResponse(let pending):
            let received = try pending.receive(record)
            state.phase = .ready(received.channel)
            didAuthenticate(state, hello: received.peerHello)

        case .awaitingWorkerNoise:
            if let announcement = try? DronePairingAnnouncement.decode(record) {
                try beginWorkerPairing(announcement, state: state)
            } else {
                try acceptWorkerNoise(record, state: state, localKey: nil, pinnedControllers: nil)
            }

        case .awaitingWorkerApproval(_, _, _, let pendingNoise):
            guard pendingNoise == nil, record.count <= DroneLimits.maxHandshakeBytes else {
                throw DroneTransportFailure.authentication
            }
            if case .awaitingWorkerApproval(let localKey, let request, let candidate, _) = state.phase {
                state.phase = .awaitingWorkerApproval(
                    localKey: localKey,
                    request: request,
                    candidate: candidate,
                    pendingNoise: record
                )
            }

        case .ready(var channel):
            let envelope = try channel.open(record)
            state.phase = .ready(channel)
            state.lastValidRecord = Date()
            guard let peerID = state.peerID else { throw DroneTransportFailure.authentication }
            emit(.envelope(id: state.id, peerID: peerID, envelope: envelope))

        case .connecting:
            throw DroneTransportFailure.authentication
        }
    }

    private func beginWorkerPairing(
        _ candidate: DronePairingAnnouncement,
        state: ConnectionState
    ) throws {
        let localKey = try identityStore.loadOrCreate()
        let announcement = try DronePairingAnnouncement.make(
            localKey: localKey,
            senderID: identityStore.loadOrCreatePeerID()
        )
        let request = try candidate.request(
            localKey: localKey,
            peerID: candidate.senderID,
            existingPin: nil
        )
        state.phase = .awaitingWorkerApproval(
            localKey: localKey,
            request: request,
            candidate: candidate,
            pendingNoise: nil
        )
        sendRecord(try announcement.encode(), state: state)
        requests[request.id] = state.id
        emit(.pairingRequired(request))
    }

    private func acceptWorkerNoise(
        _ record: Data,
        state: ConnectionState,
        localKey suppliedLocalKey: Curve25519.KeyAgreement.PrivateKey?,
        pinnedControllers suppliedPins: [(DronePeerID, Curve25519.KeyAgreement.PublicKey)]?
    ) throws {
        let localKey = try suppliedLocalKey ?? identityStore.loadOrCreate()
        let pinnedControllers: [(DronePeerID, Curve25519.KeyAgreement.PublicKey)]
        if let suppliedPins {
            pinnedControllers = suppliedPins
        } else {
            pinnedControllers = try pairingStore.pairedPeerIDs().compactMap { peerID in
                guard !revokedPeerIDs.contains(peerID),
                      let key = try pairingStore.pinnedKey(for: peerID)
                else { return nil }
                return (peerID, key)
            }
        }
        let accepted = try DroneHandshake.accept(
            localKey: localKey,
            pinnedControllerKeys: pinnedControllers.map(\.1),
            message: record
        )
        guard let peerID = pinnedControllers.first(where: {
            $0.1.rawRepresentation == accepted.controllerKey.rawRepresentation
        })?.0 else { throw DroneTransportFailure.authentication }
        state.peerID = peerID
        state.phase = .ready(accepted.channel)
        sendRecord(accepted.response, state: state)
        didAuthenticate(state, hello: accepted.peerHello)
    }

    private func didAuthenticate(_ state: ConnectionState, hello: DroneHello) {
        state.handshakeDeadline?.cancel()
        state.handshakeDeadline = nil
        state.lastValidRecord = Date()
        startHeartbeat(state)
        guard let peerID = state.peerID else { return }
        emit(.connected(id: state.id, peerID: peerID, hello: hello))
    }

    private func scheduleHandshakeDeadline(_ state: ConnectionState) {
        state.handshakeDeadline?.cancel()
        let deadline = DispatchWorkItem { [weak self, weak state] in
            guard let self, let state, !state.closed else { return }
            if case .ready = state.phase { return }
            self.close(state, failure: .authentication)
        }
        state.handshakeDeadline = deadline
        queue.asyncAfter(deadline: .now() + DroneLimits.handshakeTimeout, execute: deadline)
    }

    private func startHeartbeat(_ state: ConnectionState) {
        state.heartbeat?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + DroneLimits.heartbeatInterval,
            repeating: DroneLimits.heartbeatInterval
        )
        timer.setEventHandler { [weak self, weak state] in
            guard let self, let state, !state.closed else { return }
            if Date().timeIntervalSince(state.lastValidRecord) >= DroneLimits.heartbeatTimeout {
                self.close(state, failure: .disconnected)
                return
            }
            self.send(DroneEnvelope(kind: .heartbeat), on: state.id)
        }
        state.heartbeat = timer
        timer.resume()
    }

    private func sendRecord(_ record: Data, state: ConnectionState) {
        do {
            let framed = try DroneWire.frame(record)
            state.connection.send(content: framed, completion: .contentProcessed {
                [weak self, weak state] error in
                guard let self, let state, error != nil, !state.closed else { return }
                self.close(state, failure: .disconnected)
            })
        } catch {
            close(state, failure: .protocolViolation)
        }
    }

    private func close(_ state: ConnectionState, failure: DroneTransportFailure?) {
        guard !state.closed else { return }
        state.closed = true
        state.handshakeDeadline?.cancel()
        state.heartbeat?.cancel()
        connections.removeValue(forKey: state.id)
        requests = requests.filter { $0.value != state.id }
        state.connection.stateUpdateHandler = nil
        state.connection.cancel()
        if let failure {
            emit(.failed(id: state.id, failure: failure))
        }
        emit(.disconnected(id: state.id, peerID: state.peerID))
    }

    private func stopLocked() {
        running = false
        listener?.cancel()
        listener = nil
        for state in Array(connections.values) {
            close(state, failure: nil)
        }
    }

    private func emit(_ event: DroneTransportEvent) {
        onEvent?(event)
    }

    private static func tcpParameters() -> NWParameters {
        let options = NWProtocolTCP.Options()
        options.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: options)
        parameters.includePeerToPeer = true
        return parameters
    }

    private static func isValidBonjourInstance(_ value: String) -> Bool {
        (16 ... 64).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (65 ... 90).contains($0)
                || (97 ... 122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}
