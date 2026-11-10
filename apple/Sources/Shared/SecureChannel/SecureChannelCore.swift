import CryptoKit
import Foundation
import Network
import Observation

/// One role-parameterized secure-channel transport used by both Pilot and
/// Copilot. Socket lifecycle, deadlines, reliability, replay protection,
/// diagnostics, and cleanup live here; only Noise handshake direction and
/// directional transport keys vary by role.
@MainActor
@Observable
final class SecureChannelCore {
    enum Role: CaseIterable, Equatable {
        case initiator
        case responder

        func sendKey(from keys: TransportKeys) -> (key: SymmetricKey, nonce: Data) {
            switch self {
            case .initiator:
                (keys.initiatorToResponderKey, keys.initiatorToResponderBaseNonce)
            case .responder:
                (keys.responderToInitiatorKey, keys.responderToInitiatorBaseNonce)
            }
        }

        func receiveKey(from keys: TransportKeys) -> (key: SymmetricKey, nonce: Data) {
            switch self {
            case .initiator:
                (keys.responderToInitiatorKey, keys.responderToInitiatorBaseNonce)
            case .responder:
                (keys.initiatorToResponderKey, keys.initiatorToResponderBaseNonce)
            }
        }
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let date = Date()
        let text: String
    }

    private struct TextEnvelope: Codable {
        let msgID: UInt64
        let text: String
    }

    private static let receivedHistoryLimit = 200

    private(set) var state: ConnectionState = .signaling
    private(set) var log: [LogEntry] = []
    private(set) var received: [String] = []

    let role: Role
    private let signaling: SignalingClient
    private let token: String
    private let staticKey: Curve25519.KeyAgreement.PrivateKey
    private let peerStatic: Curve25519.KeyAgreement.PublicKey
    private let localPort: UInt16
    private let socketReadinessTimeout: Duration
    private let handshakeSchedule: HandshakeRetrySchedule

    private var connection: NWConnection?
    private var socketReady: CheckedContinuation<Void, Error>?
    private var initiatorHandshake: NoiseIK.Initiator?
    private var handshakePacket: Data?
    private var handshakeRetryTask: Task<Void, Never>?
    private var handshakeDeadlineTask: Task<Void, Never>?
    private var handshakeResponseCache = HandshakeResponseCache()
    private var transportKeys: TransportKeys?

    private var sendCounter: UInt64 = 0
    private var replay = ReplayWindow()
    private var messenger = ReliableMessenger()
    private var ackTracker = AckTracker()
    private var retransmitTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?

    private let clockOrigin = ContinuousClock.now
    private var nowSeconds: Double {
        clockOrigin.duration(to: ContinuousClock.now).seconds
    }

    var retainedDeliveryIDCount: Int { ackTracker.retainedCount }
    var abandonedMessageIDCount: Int { messenger.abandoned.count }

    init(
        role: Role,
        signaling: SignalingClient,
        token: String,
        staticKey: Curve25519.KeyAgreement.PrivateKey,
        peerStatic: Curve25519.KeyAgreement.PublicKey,
        localPort: UInt16 = SecureChannelCore.randomEphemeralPort(),
        socketReadinessTimeout: Duration = .seconds(8),
        handshakeSchedule: HandshakeRetrySchedule = HandshakeRetrySchedule()
    ) {
        self.role = role
        self.signaling = signaling
        self.token = token
        self.staticKey = staticKey
        self.peerStatic = peerStatic
        self.localPort = localPort
        self.socketReadinessTimeout = socketReadinessTimeout
        self.handshakeSchedule = handshakeSchedule
    }

    static func randomEphemeralPort() -> UInt16 {
        UInt16.random(in: 20_000...60_000)
    }

    func connect() {
        guard lifecycleTask == nil else { return }
        appendLog("Connecting (local UDP port \(localPort))…")
        lifecycleTask = Task { @MainActor [weak self] in
            await self?.runLifecycle()
        }
    }

    func disconnect() {
        lifecycleTask?.cancel()
        lifecycleTask = nil
        resolveSocketReady(with: .failure(CancellationError()))
        handshakeRetryTask?.cancel()
        handshakeRetryTask = nil
        handshakeDeadlineTask?.cancel()
        handshakeDeadlineTask = nil
        retransmitTask?.cancel()
        retransmitTask = nil
        connection?.cancel()
        connection = nil
        initiatorHandshake = nil
        handshakePacket = nil
        handshakeResponseCache.reset()
        transportKeys = nil
        sendCounter = 0
        replay = ReplayWindow()
        messenger = ReliableMessenger()
        ackTracker = AckTracker()
        state = .signaling
        appendLog("Disconnected.")
    }

    func sendText(_ text: String) {
        guard state.isConnected, let keys = transportKeys else {
            appendLog("Not connected; can't send.")
            return
        }
        let id = messenger.enqueue(Data(), now: nowSeconds).id
        let envelope = TextEnvelope(msgID: id, text: text)
        guard let json = try? JSONEncoder().encode(envelope) else { return }
        messenger.replacePayload(id: id, payload: json)
        appendLog("→ text #\(id): \(text)")
        transmit(type: .reliableControl, plaintext: json, keys: keys)
        scheduleRetransmit()
    }

    func sendTestBlob() {
        guard state.isConnected, let keys = transportKeys else {
            appendLog("Not connected; can't send blob.")
            return
        }
        let blob = Data((0..<256).map { UInt8($0 & 0xFF) })
        appendLog("→ best-effort blob (\(blob.count) bytes)")
        transmit(type: .bestEffortBlob, plaintext: blob, keys: keys)
    }

    private func runLifecycle() async {
        do {
            let myKey = staticKey.publicKey.rawRepresentation.base64EncodedString()
            appendLog("Registering with rendezvous…")
            var peer = try await signaling.register(
                token: token,
                publicKeyBase64: myKey,
                port: localPort
            )
            if peer == nil {
                appendLog("Waiting for peer to register…")
                peer = try await signaling.waitForPeer(token: token, publicKeyBase64: myKey)
            }
            guard let peer else {
                fail("Peer never registered.")
                return
            }
            appendLog("Peer endpoint: \(peer.ip):\(peer.port)")

            transition(to: .holePunching)
            try await openSocket(to: peer)
            appendLog("Hole punching…")
            for _ in 0..<5 {
                try Task.checkCancellation()
                sendRaw(Data([0x00]))
                try await Task.sleep(for: .milliseconds(150))
            }

            transition(to: .handshake)
            switch role {
            case .initiator:
                try startInitiatorHandshake()
            case .responder:
                appendLog("Waiting for handshake from initiator…")
                startResponderHandshakeDeadline()
            }
        } catch is CancellationError {
            // Explicit disconnect owns user-facing state reset.
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func openSocket(to peer: SignalingClient.PeerEndpoint) async throws {
        let host = NWEndpoint.Host(peer.ip)
        guard let port = NWEndpoint.Port(rawValue: peer.port) else {
            throw SignalingClient.SignalingError.decode
        }

        let parameters = NWParameters.udp
        if let localPort = NWEndpoint.Port(rawValue: localPort) {
            parameters.requiredLocalEndpoint = .hostPort(host: "0.0.0.0", port: localPort)
        }
        parameters.allowLocalEndpointReuse = true

        let connection = NWConnection(host: host, port: port, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] networkState in
            Task { @MainActor in self?.handleSocketState(networkState) }
        }

        try await SecureChannelDeadline.run(
            timeout: socketReadinessTimeout,
            timeoutError: .socketReadinessTimedOut
        ) { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.waitForSocketReady(connection)
        }
        startReceiveLoop(on: connection)
    }

    private func waitForSocketReady(_ connection: NWConnection) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                socketReady = continuation
                connection.start(queue: .global(qos: .userInitiated))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.connection?.cancel()
                self?.resolveSocketReady(with: .failure(CancellationError()))
            }
        }
    }

    private func resolveSocketReady(with result: Result<Void, Error>) {
        guard let continuation = socketReady else { return }
        socketReady = nil
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func handleSocketState(_ networkState: NWConnection.State) {
        switch networkState {
        case .ready:
            resolveSocketReady(with: .success(()))
        case .failed(let error):
            if socketReady != nil {
                resolveSocketReady(with: .failure(error))
            } else {
                fail("Socket failed: \(error.localizedDescription)")
            }
        case .cancelled:
            resolveSocketReady(with: .failure(CancellationError()))
        default:
            break
        }
    }

    private func startReceiveLoop(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            Task { @MainActor in
                guard let self, let connection, connection === self.connection else { return }
                if let data, !data.isEmpty {
                    self.handleInbound(data)
                }
                if error == nil {
                    self.startReceiveLoop(on: connection)
                } else {
                    self.fail("Receive failed: \(error?.localizedDescription ?? "unknown error")")
                }
            }
        }
    }

    private func sendRaw(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func startInitiatorHandshake() throws {
        let (state, message) = try NoiseIK.Initiator.start(
            staticKey: staticKey,
            responderStatic: peerStatic
        )
        initiatorHandshake = state
        appendLog("→ handshake msg1 (\(message.count) bytes)")
        var packet = PacketCodec.encodeHeader(type: .handshake, counter: 0)
        packet.append(message)
        handshakePacket = packet
        sendRaw(packet)
        startInitiatorHandshakeRetries()
    }

    private func startInitiatorHandshakeRetries() {
        handshakeRetryTask?.cancel()
        let schedule = handshakeSchedule
        handshakeRetryTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: schedule.timeout)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: schedule.interval)
                } catch {
                    return
                }
                guard let self, self.transportKeys == nil else { return }
                guard clock.now < deadline else {
                    self.handshakeRetryTask = nil
                    self.handshakePacket = nil
                    self.connection?.cancel()
                    self.fail(SecureChannelAttemptError.handshakeTimedOut.localizedDescription)
                    return
                }
                guard let packet = self.handshakePacket else { return }
                self.appendLog("↻ handshake msg1")
                self.sendRaw(packet)
            }
        }
    }

    private func startResponderHandshakeDeadline() {
        handshakeDeadlineTask?.cancel()
        let timeout = handshakeSchedule.timeout
        handshakeDeadlineTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard let self, self.transportKeys == nil else { return }
            self.handshakeDeadlineTask = nil
            self.connection?.cancel()
            self.fail(SecureChannelAttemptError.handshakeTimedOut.localizedDescription)
        }
    }

    /// Transport keys are installed only while in `.handshake`, so holding
    /// `transportKeys` always means the channel reached `.connected` (#427).
    /// The receive loop starts during `.holePunching`, and an initiator retry
    /// can land inside the responder's hole-punch window; such a packet is
    /// dropped here (the initiator keeps retrying) instead of installing keys
    /// whose `.holePunching -> .connected` edge the state machine rejects.
    private func handleHandshake(_ body: Data) {
        switch role {
        case .initiator:
            handleInitiatorHandshakeReply(body)
        case .responder:
            handleResponderHandshakeInit(body)
        }
    }

    private func handleInitiatorHandshakeReply(_ body: Data) {
        guard state == .handshake, let handshake = initiatorHandshake, transportKeys == nil else {
            return
        }
        do {
            transportKeys = try handshake.receive(body).keys
            initiatorHandshake = nil
            handshakePacket = nil
            handshakeRetryTask?.cancel()
            handshakeRetryTask = nil
            transition(to: .connected)
            appendLog("Handshake complete — channel encrypted.")
        } catch {
            fail("Handshake failed: \(error)")
        }
    }

    private func handleResponderHandshakeInit(_ body: Data) {
        if transportKeys != nil {
            if state.isConnected, let response = handshakeResponseCache.response(for: body) {
                appendLog("↻ duplicate handshake msg1; re-sending msg2")
                sendRaw(response)
            }
            return
        }
        guard state == .handshake else {
            appendLog("Ignored handshake msg1 outside the handshake state.")
            return
        }
        do {
            let responder = try NoiseIK.Responder.receive(
                staticKey: staticKey,
                message: body,
                expectedInitiator: peerStatic
            )
            let (keys, message) = try responder.respond()
            var packet = PacketCodec.encodeHeader(type: .handshake, counter: 0)
            packet.append(message)
            transportKeys = keys
            handshakeResponseCache.record(request: body, response: packet)
            appendLog("← handshake msg1 (\(body.count) bytes); peer authenticated.")
            sendRaw(packet)
            appendLog("→ handshake msg2 (\(message.count) bytes)")
            handshakeDeadlineTask?.cancel()
            handshakeDeadlineTask = nil
            transition(to: .connected)
            appendLog("Handshake complete — channel encrypted.")
        } catch NoiseIK.HandshakeError.unauthorizedPeer {
            fail("Handshake rejected: initiator key does not match the pinned peer key.")
        } catch {
            fail("Handshake failed: \(error)")
        }
    }

    private func handleInbound(_ data: Data) {
        if data.count == 1 { return }
        guard let packet = try? PacketCodec.parse(data) else { return }

        switch packet.type {
        case .handshake:
            handleHandshake(packet.ciphertextAndTag)
        case .reliableControl, .ack, .bestEffortBlob:
            guard state.isConnected, let keys = transportKeys else { return }
            let receive = role.receiveKey(from: keys)
            guard let opened = try? PacketCodec.open(
                data,
                key: receive.key,
                baseNonce: receive.nonce
            ) else {
                appendLog("Dropped undecryptable packet.")
                return
            }
            guard replay.accept(opened.counter) else {
                appendLog("Dropped replayed packet (counter \(opened.counter)).")
                return
            }
            dispatch(type: opened.type, plaintext: opened.plaintext, keys: keys)
        }
    }

    private func dispatch(type: PacketCodec.PacketType, plaintext: Data, keys: TransportKeys) {
        switch type {
        case .reliableControl:
            guard let envelope = try? JSONDecoder().decode(TextEnvelope.self, from: plaintext) else {
                return
            }
            sendAck(msgID: envelope.msgID, keys: keys)
            if ackTracker.receive(envelope.msgID) {
                appendReceived(envelope.text)
                appendLog("← text #\(envelope.msgID): \(envelope.text)")
            } else {
                appendLog("← duplicate text #\(envelope.msgID) (re-ACK'd).")
            }
        case .ack:
            guard plaintext.count == 8 else { return }
            var id: UInt64 = 0
            for byte in plaintext { id = (id << 8) | UInt64(byte) }
            if messenger.acknowledge(id) {
                appendLog("✓ ACK #\(id)")
            }
        case .bestEffortBlob:
            appendLog("← best-effort blob (\(plaintext.count) bytes)")
        case .handshake:
            break
        }
    }

    private func transmit(type: PacketCodec.PacketType, plaintext: Data, keys: TransportKeys) {
        let counter = sendCounter
        sendCounter &+= 1
        let send = role.sendKey(from: keys)
        guard let packet = try? PacketCodec.seal(
            type: type,
            counter: counter,
            plaintext: plaintext,
            key: send.key,
            baseNonce: send.nonce
        ) else { return }
        sendRaw(packet)
    }

    private func sendAck(msgID: UInt64, keys: TransportKeys) {
        var payload = Data(capacity: 8)
        var bigEndian = msgID.bigEndian
        withUnsafeBytes(of: &bigEndian) { payload.append(contentsOf: $0) }
        transmit(type: .ack, plaintext: payload, keys: keys)
    }

    private func scheduleRetransmit() {
        guard retransmitTask == nil else { return }
        retransmitTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let sleepFor = self.pumpRetransmit() else { return }
                try? await Task.sleep(for: .seconds(max(0.05, sleepFor)))
            }
        }
    }

    private func pumpRetransmit() -> Double? {
        guard let keys = transportKeys else {
            retransmitTask = nil
            return nil
        }
        let now = nowSeconds
        switch messenger.due(now: now) {
        case .send(let messages):
            for message in messages {
                appendLog("↻ retransmit #\(message.id)")
                transmit(type: .reliableControl, plaintext: message.payload, keys: keys)
            }
            return 0.1
        case .waitUntil(let when):
            return max(0.05, when - now)
        case .idle:
            retransmitTask = nil
            return nil
        }
    }

    private func transition(to next: ConnectionState) {
        guard state.canTransition(to: next) else { return }
        state = next
        appendLog("State → \(next.secureChannelLabel)")
    }

    private func fail(_ reason: String) {
        guard !state.isFailed else { return }
        handshakeRetryTask?.cancel()
        handshakeRetryTask = nil
        handshakeDeadlineTask?.cancel()
        handshakeDeadlineTask = nil
        handshakePacket = nil
        // Keys exist only while `.connected` (#427): a failed channel neither
        // decrypts inbound traffic nor retransmits outbound messages.
        transportKeys = nil
        state = .failed(reason: reason)
        appendLog("Failed: \(reason)")
    }

    private func appendLog(_ text: String) {
        log.append(LogEntry(text: text))
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    private func appendReceived(_ text: String) {
        received.append(text)
        if received.count > Self.receivedHistoryLimit {
            received.removeFirst(received.count - Self.receivedHistoryLimit)
        }
    }
}

private extension Duration {
    var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

private extension ConnectionState {
    var secureChannelLabel: String {
        switch self {
        case .signaling: "signaling"
        case .holePunching: "hole punching"
        case .handshake: "handshake"
        case .connected: "connected"
        case .failed(let reason): "failed (\(reason))"
        }
    }
}
