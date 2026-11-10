import Foundation
import XCTest
import CryptoKit
import Network

@testable import Copilot

/// Unit tests for the pure, socket-free secure-channel value layer (issue #51):
/// the Noise IK handshake, packet AEAD codec, replay window, connection state
/// machine, and reliable-delivery bookkeeping.
final class SecureChannelTests: XCTestCase {

    // MARK: - Handshake

    /// A full IK handshake completes and BOTH sides derive identical directional
    /// transport keys and base nonces.
    func testFullHandshakeDerivesIdenticalDirectionalKeys() throws {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()

        let (initiatorState, msg1) = try NoiseIK.Initiator.start(
            staticKey: initiatorStatic,
            responderStatic: responderStatic.publicKey,
            payload: Data("hello".utf8)
        )

        let responder = try NoiseIK.Responder.receive(
            staticKey: responderStatic,
            message: msg1,
            expectedInitiator: initiatorStatic.publicKey
        )
        // Responder recovers and authenticates the initiator's static key + payload.
        XCTAssertEqual(responder.initiatorPayload, Data("hello".utf8))
        XCTAssertEqual(
            responder.initiatorStatic.rawRepresentation,
            initiatorStatic.publicKey.rawRepresentation
        )

        let (responderKeys, msg2) = try responder.respond(payload: Data("world".utf8))
        let (initiatorKeys, responderPayload) = try initiatorState.receive(msg2)
        XCTAssertEqual(responderPayload, Data("world".utf8))

        // Both sides MUST agree on both directional keys + base nonces.
        XCTAssertEqual(initiatorKeys, responderKeys)

        // Sanity: the two directions are distinct from each other.
        XCTAssertNotEqual(
            initiatorKeys.initiatorToResponderKey,
            initiatorKeys.responderToInitiatorKey
        )
        XCTAssertNotEqual(
            initiatorKeys.initiatorToResponderBaseNonce,
            initiatorKeys.responderToInitiatorBaseNonce
        )
    }

    /// The derived keys actually work end-to-end through the packet codec in
    /// both directions.
    func testTransportRoundtripBothDirections() throws {
        let keys = try completeHandshake().initiator

        // Initiator -> Responder.
        let p1 = try PacketCodec.seal(
            type: .reliableControl, counter: 0,
            plaintext: Data("i2r".utf8),
            key: keys.initiatorToResponderKey,
            baseNonce: keys.initiatorToResponderBaseNonce
        )
        let opened1 = try PacketCodec.open(
            p1, key: keys.initiatorToResponderKey,
            baseNonce: keys.initiatorToResponderBaseNonce
        )
        XCTAssertEqual(opened1.plaintext, Data("i2r".utf8))
        XCTAssertEqual(opened1.type, .reliableControl)

        // Responder -> Initiator.
        let p2 = try PacketCodec.seal(
            type: .bestEffortBlob, counter: 0,
            plaintext: Data("r2i".utf8),
            key: keys.responderToInitiatorKey,
            baseNonce: keys.responderToInitiatorBaseNonce
        )
        let opened2 = try PacketCodec.open(
            p2, key: keys.responderToInitiatorKey,
            baseNonce: keys.responderToInitiatorBaseNonce
        )
        XCTAssertEqual(opened2.plaintext, Data("r2i".utf8))
        XCTAssertEqual(opened2.type, .bestEffortBlob)
    }

    func testBothTransportRolesUseComplementaryDirectionalKeys() throws {
        let keys = try completeHandshake().initiator
        let initiatorSend = SecureChannelCore.Role.initiator.sendKey(from: keys)
        let responderReceive = SecureChannelCore.Role.responder.receiveKey(from: keys)
        let responderSend = SecureChannelCore.Role.responder.sendKey(from: keys)
        let initiatorReceive = SecureChannelCore.Role.initiator.receiveKey(from: keys)

        XCTAssertEqual(initiatorSend.key, responderReceive.key)
        XCTAssertEqual(initiatorSend.nonce, responderReceive.nonce)
        XCTAssertEqual(responderSend.key, initiatorReceive.key)
        XCTAssertEqual(responderSend.nonce, initiatorReceive.nonce)
        XCTAssertNotEqual(initiatorSend.key, responderSend.key)
    }

    /// A WRONG responder static key (the authentication guarantee) must make the
    /// handshake fail to open — the initiator believed it was talking to one
    /// device, but the responder holds a different static key.
    func testWrongResponderStaticKeyFailsHandshake() throws {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let realResponder = Curve25519.KeyAgreement.PrivateKey()
        let wrongResponder = Curve25519.KeyAgreement.PrivateKey()

        // Initiator addresses the WRONG responder public key.
        let (_, msg1) = try NoiseIK.Initiator.start(
            staticKey: initiatorStatic,
            responderStatic: wrongResponder.publicKey
        )

        // The real responder (different static key) can't open msg1: DH(e,s)
        // differs, so the AEAD key differs and the open fails.
        XCTAssertThrowsError(
            try NoiseIK.Responder.receive(
                staticKey: realResponder,
                message: msg1,
                expectedInitiator: initiatorStatic.publicKey
            )
        ) { error in
            XCTAssertEqual(error as? NoiseIK.HandshakeError, .decryptFailed)
        }
    }

    /// Even when msg1 is accepted, a responder whose static key the initiator
    /// did NOT pin will produce mismatched transport keys; the first transport
    /// packet then fails to open. (Belt-and-suspenders authentication.)
    func testMismatchedStaticKeyProducesUndecryptableTransport() throws {
        // Initiator pins responderA, but msg2 is produced by responderB.
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderA = Curve25519.KeyAgreement.PrivateKey()
        let responderB = Curve25519.KeyAgreement.PrivateKey()

        let (initiatorState, msg1) = try NoiseIK.Initiator.start(
            staticKey: initiatorStatic,
            responderStatic: responderA.publicKey
        )
        // responderB happens to also receive msg1 — but it was sealed to A, so
        // it cannot even open it.
        XCTAssertThrowsError(
            try NoiseIK.Responder.receive(
                staticKey: responderB,
                message: msg1,
                expectedInitiator: initiatorStatic.publicKey
            )
        )
        // And the legitimate A completes fine (control).
        let respA = try NoiseIK.Responder.receive(
            staticKey: responderA,
            message: msg1,
            expectedInitiator: initiatorStatic.publicKey
        )
        let (_, msg2) = try respA.respond()
        XCTAssertNoThrow(try initiatorState.receive(msg2))
    }

    func testResponderRejectsUnpinnedInitiatorBeforeReleasingKeys() throws {
        let pairedInitiator = Curve25519.KeyAgreement.PrivateKey()
        let attacker = Curve25519.KeyAgreement.PrivateKey()
        let responder = Curve25519.KeyAgreement.PrivateKey()
        let (_, attackerMessage) = try NoiseIK.Initiator.start(
            staticKey: attacker,
            responderStatic: responder.publicKey
        )

        XCTAssertThrowsError(
            try NoiseIK.Responder.receive(
                staticKey: responder,
                message: attackerMessage,
                expectedInitiator: pairedInitiator.publicKey
            )
        ) { error in
            XCTAssertEqual(error as? NoiseIK.HandshakeError, .unauthorizedPeer)
        }
    }

    func testHandshakeResponseCacheOnlyReplaysMatchingRequest() {
        var cache = HandshakeResponseCache()
        cache.record(request: Data("msg1".utf8), response: Data("msg2".utf8))

        XCTAssertEqual(cache.response(for: Data("msg1".utf8)), Data("msg2".utf8))
        XCTAssertNil(cache.response(for: Data("forged".utf8)))
        cache.reset()
        XCTAssertNil(cache.response(for: Data("msg1".utf8)))
    }

    func testAttemptDeadlineBoundsPerpetuallyWaitingOperation() async {
        let started = ContinuousClock.now
        do {
            _ = try await SecureChannelDeadline.run(
                timeout: .milliseconds(25),
                timeoutError: .socketReadinessTimedOut
            ) {
                try await Task.sleep(for: .seconds(60))
                return true
            }
            XCTFail("expected socket timeout")
        } catch {
            XCTAssertEqual(error as? SecureChannelAttemptError, .socketReadinessTimedOut)
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
    }

    func testAttemptDeadlineReturnsCompletedOperation() async throws {
        let value = try await SecureChannelDeadline.run(
            timeout: .seconds(1),
            timeoutError: .handshakeTimedOut
        ) {
            42
        }
        XCTAssertEqual(value, 42)
    }

    // MARK: - Packet codec / tampering

    func testTamperedCiphertextFailsToOpen() throws {
        let keys = try completeHandshake().initiator
        var packet = try PacketCodec.seal(
            type: .reliableControl, counter: 7,
            plaintext: Data("secret".utf8),
            key: keys.initiatorToResponderKey,
            baseNonce: keys.initiatorToResponderBaseNonce
        )
        // Flip a bit in the ciphertext body.
        let flipIndex = PacketCodec.headerLength
        packet[flipIndex] ^= 0x01
        XCTAssertThrowsError(
            try PacketCodec.open(
                packet, key: keys.initiatorToResponderKey,
                baseNonce: keys.initiatorToResponderBaseNonce
            )
        ) { error in
            XCTAssertEqual(error as? PacketCodec.CodecError, .openFailed)
        }
    }

    func testTamperedHeaderFailsToOpen() throws {
        let keys = try completeHandshake().initiator
        var packet = try PacketCodec.seal(
            type: .reliableControl, counter: 3,
            plaintext: Data("secret".utf8),
            key: keys.initiatorToResponderKey,
            baseNonce: keys.initiatorToResponderBaseNonce
        )
        // Flip the type byte: header is AAD, so the tag check must fail.
        packet[1] = PacketCodec.PacketType.bestEffortBlob.rawValue
        XCTAssertThrowsError(
            try PacketCodec.open(
                packet, key: keys.initiatorToResponderKey,
                baseNonce: keys.initiatorToResponderBaseNonce
            )
        ) { error in
            XCTAssertEqual(error as? PacketCodec.CodecError, .openFailed)
        }
    }

    func testBadVersionRejected() throws {
        let keys = try completeHandshake().initiator
        var packet = try PacketCodec.seal(
            type: .ack, counter: 1, plaintext: Data(),
            key: keys.initiatorToResponderKey,
            baseNonce: keys.initiatorToResponderBaseNonce
        )
        packet[0] = 0x02
        XCTAssertThrowsError(try PacketCodec.parse(packet)) { error in
            XCTAssertEqual(error as? PacketCodec.CodecError, .badVersion(0x02))
        }
    }

    func testNonceXorIsUniquePerCounter() {
        let base = Data(repeating: 0xAB, count: 12)
        let n0 = PacketCodec.nonce(baseNonce: base, counter: 0)
        let n1 = PacketCodec.nonce(baseNonce: base, counter: 1)
        XCTAssertEqual(n0, base)            // counter 0 leaves base unchanged
        XCTAssertNotEqual(n0, n1)
        XCTAssertEqual(n1.count, 12)
        // Low byte should be base ^ 1.
        XCTAssertEqual(n1[11], base[11] ^ 0x01)
    }

    // MARK: - Replay window

    func testReplayWindowRejectsReplayedAndOldCounters() {
        var window = ReplayWindow()
        XCTAssertTrue(window.accept(0))
        XCTAssertTrue(window.accept(1))
        XCTAssertTrue(window.accept(2))

        // Replays of already-seen counters are rejected.
        XCTAssertFalse(window.accept(1))
        XCTAssertFalse(window.accept(2))

        // Out-of-order but fresh within the window is accepted...
        XCTAssertTrue(window.accept(5))
        // ...then a replay of it is rejected.
        XCTAssertFalse(window.accept(5))

        // Advance far past the window, then an ancient counter is too old.
        XCTAssertTrue(window.accept(5000))
        XCTAssertFalse(window.accept(1))     // below window bottom
        XCTAssertFalse(window.accept(5000))  // replay of current highest
    }

    func testReplayWindowAcceptsFreshWithinWindow() {
        var window = ReplayWindow(size: 1024)
        XCTAssertTrue(window.accept(1023))
        // Still within [0, 1023]: fresh, accept.
        XCTAssertTrue(window.accept(0))
        XCTAssertTrue(window.accept(512))
        // Replay rejected.
        XCTAssertFalse(window.accept(512))
    }

    func testReplayWindowHandlesCounterRollover() {
        var window = ReplayWindow(size: 16)
        XCTAssertTrue(window.accept(UInt64.max - 1))
        XCTAssertTrue(window.accept(UInt64.max))
        XCTAssertTrue(window.accept(0))
        XCTAssertTrue(window.accept(1))
        XCTAssertFalse(window.accept(UInt64.max))
    }

    // MARK: - Connection state machine

    func testStateMachineHappyPath() {
        var sm = ConnectionStateMachine()
        XCTAssertEqual(sm.state, .signaling)
        XCTAssertTrue(sm.transition(to: .holePunching))
        XCTAssertTrue(sm.transition(to: .handshake))
        XCTAssertTrue(sm.transition(to: .connected))
        XCTAssertTrue(sm.state.isConnected)
    }

    func testStateMachineRejectsIllegalTransition() {
        var sm = ConnectionStateMachine()
        // Can't skip straight to connected.
        XCTAssertFalse(sm.transition(to: .connected))
        XCTAssertEqual(sm.state, .signaling)
        // Can't skip the handshake.
        XCTAssertTrue(sm.transition(to: .holePunching))
        XCTAssertFalse(sm.transition(to: .connected))
        XCTAssertEqual(sm.state, .holePunching)
    }

    func testStateMachineCanFailFromAnyStage() {
        var sm = ConnectionStateMachine()
        sm.fail("signaling timeout")
        XCTAssertTrue(sm.state.isFailed)
        XCTAssertEqual(sm.state, .failed(reason: "signaling timeout"))
    }

    // MARK: - Reliable delivery / ACK bookkeeping

    func testReliableMessengerAckClearsInFlight() {
        var sender = ReliableMessenger()
        let m = sender.enqueue(Data("ctrl".utf8), now: 0)
        XCTAssertTrue(sender.isOutstanding(m.id))
        XCTAssertEqual(sender.outstandingCount, 1)

        XCTAssertTrue(sender.acknowledge(m.id))
        XCTAssertFalse(sender.isOutstanding(m.id))
        XCTAssertEqual(sender.outstandingCount, 0)

        // Duplicate/late ACK is a no-op.
        XCTAssertFalse(sender.acknowledge(m.id))
    }

    func testReliableMessengerRetransmitsWithBackoffUntilAcked() {
        var sender = ReliableMessenger(maxAttempts: 8, baseBackoff: 1.0, maxBackoff: 100)
        let m = sender.enqueue(Data("ctrl".utf8), now: 0)

        // First send is due immediately.
        guard case .send(let first) = sender.due(now: 0) else {
            return XCTFail("expected initial send")
        }
        XCTAssertEqual(first.map(\.id), [m.id])

        // Nothing due before the first backoff (1.0s) elapses.
        guard case .waitUntil(let t) = sender.due(now: 0.5) else {
            return XCTFail("expected waitUntil")
        }
        XCTAssertEqual(t, 1.0, accuracy: 0.0001)

        // At 1.0s a retransmit fires; next backoff doubles to 2.0s.
        guard case .send(let second) = sender.due(now: 1.0) else {
            return XCTFail("expected retransmit")
        }
        XCTAssertEqual(second.map(\.id), [m.id])
        guard case .waitUntil(let t2) = sender.due(now: 1.5) else {
            return XCTFail("expected waitUntil after retransmit")
        }
        XCTAssertEqual(t2, 3.0, accuracy: 0.0001)  // 1.0 + 2.0

        // Once ACK'd, it goes idle.
        XCTAssertTrue(sender.acknowledge(m.id))
        XCTAssertEqual(sender.due(now: 100), .idle)
    }

    func testReliableMessengerAbandonsAfterMaxAttempts() {
        var sender = ReliableMessenger(maxAttempts: 3, baseBackoff: 1.0, maxBackoff: 100)
        let m = sender.enqueue(Data("ctrl".utf8), now: 0)

        // Drive the clock forward well past every backoff window so each call
        // fires the next attempt. After maxAttempts sends, it's abandoned.
        var now: TimeInterval = 0
        for _ in 0..<10 {
            _ = sender.due(now: now)
            now += 1000
        }
        XCTAssertFalse(sender.isOutstanding(m.id))
        XCTAssertTrue(sender.abandoned.contains(m.id))
        XCTAssertEqual(sender.due(now: now), .idle)
    }

    func testAckTrackerDeliversOnceDedupesRetransmits() {
        var tracker = AckTracker()
        XCTAssertTrue(tracker.receive(42))   // first delivery
        XCTAssertFalse(tracker.receive(42))  // retransmit: ack again, don't redeliver
        XCTAssertTrue(tracker.hasDelivered(42))
        XCTAssertTrue(tracker.receive(43))
    }

    func testAckTrackerUsesBoundedSlidingWindowWithReordering() {
        var tracker = AckTracker(windowSize: 64)
        for id in UInt64(0)..<10_000 {
            XCTAssertTrue(tracker.receive(id))
        }

        XCTAssertLessThanOrEqual(tracker.retainedCount, 64)
        XCTAssertFalse(tracker.receive(9_999)) // recent duplicate
        XCTAssertFalse(tracker.receive(1)) // too old to re-deliver
        XCTAssertTrue(tracker.receive(10_002))
        XCTAssertTrue(tracker.receive(10_001)) // bounded reordering
    }

    func testAbandonedDiagnosticsAreBounded() {
        var sender = ReliableMessenger(
            maxAttempts: 0,
            abandonedHistoryLimit: 8
        )
        for _ in 0..<100 {
            _ = sender.enqueue(Data(), now: 0)
            _ = sender.due(now: 0)
        }

        XCTAssertEqual(sender.abandoned.count, 8)
        XCTAssertEqual(sender.abandoned, Array(93...100))
    }

    // MARK: - SecureChannelCore handshake state (#427)

    /// An initiator msg1 retry can land inside the responder's hole-punch
    /// window because the receive loop is already running. Before #427 the
    /// responder installed transport keys there, the `.holePunching ->
    /// .connected` edge was silently dropped, and the responder stayed in
    /// `.handshake` forever: later retries only re-sent msg2 and `sendText`
    /// refused to send. Keys are now installed only in `.handshake`, so the
    /// early msg1 is ignored and the next retry completes the channel.
    @MainActor
    func testHandshakeDuringHolePunchingDoesNotStrandResponder() async throws {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderPort = SecureChannelCore.randomEphemeralPort()
        var peerPort = SecureChannelCore.randomEphemeralPort()
        while peerPort == responderPort {
            peerPort = SecureChannelCore.randomEphemeralPort()
        }

        // The test plays the initiator over a real loopback UDP socket so it
        // controls exactly when msg1 reaches the responder.
        let peer = try LoopbackUDPPeer(localPort: peerPort, remotePort: responderPort)
        defer { peer.stop() }
        try await waitUntil("test peer socket ready") { peer.isReady }

        RendezvousStubProtocol.peerResponse = try JSONSerialization.data(withJSONObject: [
            "publicKey": initiatorStatic.publicKey.rawRepresentation.base64EncodedString(),
            "ip": "127.0.0.1",
            "port": Int(peerPort),
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RendezvousStubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            RendezvousStubProtocol.peerResponse = nil
        }

        let signaling = try SignalingClient(session: session)
        let token = try SecurePairingStore.generateToken()
        let responder = SecureChannelCore(
            role: .responder,
            signaling: signaling,
            token: token,
            staticKey: responderStatic,
            peerStatic: initiatorStatic.publicKey,
            localPort: responderPort,
            handshakeSchedule: HandshakeRetrySchedule(
                interval: .milliseconds(500),
                timeout: .seconds(30)
            )
        )
        defer { responder.disconnect() }
        responder.connect()

        // The first hole-punch byte proves the responder's socket and receive
        // loop are live while it is still in its 750 ms hole-punch window.
        try await waitUntil("responder hole-punch byte") { !peer.datagrams.isEmpty }
        let stateWhenMsg1Sent = responder.state
        XCTAssertEqual(stateWhenMsg1Sent, .holePunching)

        let (initiator, msg1) = try NoiseIK.Initiator.start(
            staticKey: initiatorStatic,
            responderStatic: responderStatic.publicKey
        )
        var msg1Packet = PacketCodec.encodeHeader(type: .handshake, counter: 0)
        msg1Packet.append(msg1)
        peer.send(msg1Packet)

        try await waitUntil("responder leaves hole punching") {
            responder.state != .holePunching
        }

        // The initiator's retry timer re-sends the identical msg1 packet.
        peer.send(msg1Packet)
        try await waitUntil("responder connects on the retried msg1") {
            responder.state == .connected
        }

        let reply = try XCTUnwrap(
            peer.datagrams
                .compactMap { try? PacketCodec.parse($0) }
                .first { $0.type == .handshake },
            "responder must answer the retried msg1 with msg2"
        )
        let initiatorKeys = try initiator.receive(reply.ciphertextAndTag).keys

        // The responder is genuinely usable: it sends traffic the initiator's
        // keys can open, instead of refusing with "Not connected".
        let sentBefore = peer.datagrams.count
        responder.sendText("ping")
        try await waitUntil("responder sends encrypted text") {
            peer.datagrams.count > sentBefore
        }
        let receive = SecureChannelCore.Role.initiator.receiveKey(from: initiatorKeys)
        let opened = try PacketCodec.open(
            peer.datagrams[sentBefore],
            key: receive.key,
            baseNonce: receive.nonce
        )
        XCTAssertEqual(opened.type, .reliableControl)
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: opened.plaintext) as? [String: Any]
        )
        XCTAssertEqual(envelope["text"] as? String, "ping")
    }

    // MARK: - Helpers

    private struct WaitTimedOut: Error {
        let condition: String
    }

    @MainActor
    private func waitUntil(
        _ condition: String,
        timeout: Duration = .seconds(5),
        _ predicate: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard predicate() else { throw WaitTimedOut(condition: condition) }
    }

    private func completeHandshake() throws -> (initiator: TransportKeys, responder: TransportKeys) {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()
        let (initiatorState, msg1) = try NoiseIK.Initiator.start(
            staticKey: initiatorStatic,
            responderStatic: responderStatic.publicKey
        )
        let responder = try NoiseIK.Responder.receive(
            staticKey: responderStatic,
            message: msg1,
            expectedInitiator: initiatorStatic.publicKey
        )
        let (responderKeys, msg2) = try responder.respond()
        let (initiatorKeys, _) = try initiatorState.receive(msg2)
        return (initiatorKeys, responderKeys)
    }

    /// Answers every rendezvous request with the configured peer endpoint so a
    /// `SecureChannelCore` proceeds straight to hole punching.
    private final class RendezvousStubProtocol: URLProtocol {
        nonisolated(unsafe) static var peerResponse: Data?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url,
                  let body = Self.peerResponse,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 200,
                      httpVersion: nil,
                      headerFields: nil
                  )
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }
}

/// A connected loopback UDP socket that stands in for the remote secure-channel
/// peer, recording every datagram it receives.
@MainActor
private final class LoopbackUDPPeer {
    private let connection: NWConnection
    private(set) var isReady = false
    private(set) var datagrams: [Data] = []

    init(localPort: UInt16, remotePort: UInt16) throws {
        guard let local = NWEndpoint.Port(rawValue: localPort),
              let remote = NWEndpoint.Port(rawValue: remotePort)
        else { throw URLError(.badURL) }
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: local)
        parameters.allowLocalEndpointReuse = true
        connection = NWConnection(host: "127.0.0.1", port: remote, using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                if case .ready = state { self?.isReady = true }
            }
        }
        connection.start(queue: .main)
        receiveNext()
    }

    func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func stop() {
        connection.cancel()
    }

    private func receiveNext() {
        connection.receiveMessage { [weak self] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data, !data.isEmpty { self.datagrams.append(data) }
                if error == nil { self.receiveNext() }
            }
        }
    }
}
