import CryptoKit
import Foundation
import Network
import XCTest

@testable import Copilot

final class FrameLinkSecurityTests: XCTestCase {
    func testFirstPairingRequiresApprovalThenEncryptsBothDirections() throws {
        let pilotKey = Curve25519.KeyAgreement.PrivateKey()
        let plotterKey = Curve25519.KeyAgreement.PrivateKey()
        var pilot = FrameLinkSecureSession(localKey: pilotKey)
        var plotter = FrameLinkSecureSession(localKey: plotterKey)

        let pilotHello = try XCTUnwrap(pilot.begin(random: { Data(repeating: 1, count: $0) }))
        let plotterHello = try XCTUnwrap(plotter.begin(random: { Data(repeating: 2, count: $0) }))
        let plotterRequest = try pairingRequest(pilot.receive(plotterHello, displayName: "Plotter"))
        let pilotRequest = try pairingRequest(plotter.receive(pilotHello, displayName: "Pilot"))
        // `localPublicKeyBase64` reports the key the hello actually carries.
        XCTAssertEqual(pilotRequest.publicKey, pilot.localPublicKeyBase64)
        XCTAssertEqual(plotterRequest.publicKey, plotter.localPublicKeyBase64)
        XCTAssertFalse(pilot.isAuthenticated)
        XCTAssertFalse(plotter.isAuthenticated)

        let pilotApproval = try XCTUnwrap(pilot.approvePending(publicKey: plotterRequest.publicKey))
        let plotterApproval = try XCTUnwrap(plotter.approvePending(publicKey: pilotRequest.publicKey))
        XCTAssertEqual(pilot.receive(plotterApproval.proof), .authenticated)
        XCTAssertEqual(plotter.receive(pilotApproval.proof), .authenticated)

        let frame = FrameProtocol.encode(.sample(.init(
            frameID: 1,
            isKeyFrame: true,
            data: Data([1, 2, 3, 4])
        )))
        let annotation = FrameProtocol.encode(.annotation(seq: 1, message: .clear))
        let sealedFrame = try XCTUnwrap(pilot.seal(frame))
        let sealedAnnotation = try XCTUnwrap(plotter.seal(annotation))
        XCTAssertEqual(plotter.receive(sealedFrame), .plaintext(frame))
        XCTAssertEqual(pilot.receive(sealedAnnotation), .plaintext(annotation))
    }

    func testWrongKeyRequiresKeyChangeApprovalAndCannotSendPlaintext() throws {
        let pilotKey = Curve25519.KeyAgreement.PrivateKey()
        let trustedPlotter = Curve25519.KeyAgreement.PrivateKey()
        let rogue = Curve25519.KeyAgreement.PrivateKey()
        var pilot = FrameLinkSecureSession(
            localKey: pilotKey,
            trustedPeerPublicKey: trustedPlotter.publicKey.rawRepresentation.base64EncodedString()
        )
        var rogueSession = FrameLinkSecureSession(localKey: rogue)
        _ = try XCTUnwrap(pilot.begin(random: { Data(repeating: 3, count: $0) }))
        let rogueHello = try XCTUnwrap(rogueSession.begin(random: { Data(repeating: 4, count: $0) }))

        let request = try pairingRequest(pilot.receive(rogueHello, displayName: "Rogue"))
        XCTAssertTrue(request.isKeyChange)
        XCTAssertFalse(pilot.isAuthenticated)
        XCTAssertNil(pilot.receive(FrameProtocol.encode(.keyframeRequest)))
        pilot.rejectPending()
        XCTAssertNil(pilot.approvePending(publicKey: request.publicKey))
    }

    func testTamperingReplayAndPriorSessionRecordsAreRejected() throws {
        let pilotKey = Curve25519.KeyAgreement.PrivateKey()
        let plotterKey = Curve25519.KeyAgreement.PrivateKey()
        var pilot = FrameLinkSecureSession(
            localKey: pilotKey,
            trustedPeerPublicKey: plotterKey.publicKey.rawRepresentation.base64EncodedString()
        )
        var plotter = FrameLinkSecureSession(
            localKey: plotterKey,
            trustedPeerPublicKey: pilotKey.publicKey.rawRepresentation.base64EncodedString()
        )
        try authenticateTrusted(&pilot, &plotter, pilotNonce: 0x10, plotterNonce: 0x20)

        let record = try XCTUnwrap(pilot.seal(Data("private frame".utf8)))
        var tampered = record
        tampered[tampered.index(before: tampered.endIndex)] ^= 1
        XCTAssertNil(plotter.receive(tampered))
        XCTAssertEqual(plotter.receive(record), .plaintext(Data("private frame".utf8)))
        XCTAssertNil(plotter.receive(record), "encrypted records must not replay")

        let priorSession = try XCTUnwrap(pilot.seal(Data("prior".utf8)))
        try authenticateTrusted(&pilot, &plotter, pilotNonce: 0x30, plotterNonce: 0x40)
        XCTAssertNil(plotter.receive(priorSession), "reconnects use fresh transcript-bound keys")
    }

    func testProofMayArriveWhilePeerAwaitsApproval() throws {
        let pilotKey = Curve25519.KeyAgreement.PrivateKey()
        let plotterKey = Curve25519.KeyAgreement.PrivateKey()
        var pilot = FrameLinkSecureSession(localKey: pilotKey)
        var plotter = FrameLinkSecureSession(localKey: plotterKey)
        let pilotHello = try XCTUnwrap(pilot.begin(random: { Data(repeating: 5, count: $0) }))
        let plotterHello = try XCTUnwrap(plotter.begin(random: { Data(repeating: 6, count: $0) }))
        let plotterRequest = try pairingRequest(pilot.receive(plotterHello))
        let pilotRequest = try pairingRequest(plotter.receive(pilotHello))

        let pilotApproval = try XCTUnwrap(pilot.approvePending(publicKey: plotterRequest.publicKey))
        XCTAssertEqual(plotter.receive(pilotApproval.proof), .waiting)
        let plotterApproval = try XCTUnwrap(plotter.approvePending(publicKey: pilotRequest.publicKey))
        XCTAssertTrue(plotterApproval.authenticated)
        XCTAssertEqual(pilot.receive(plotterApproval.proof), .authenticated)
    }

    func testBufferedProofDoesNotSurviveReconnect() throws {
        let pilotKey = Curve25519.KeyAgreement.PrivateKey()
        let plotterKey = Curve25519.KeyAgreement.PrivateKey()
        var pilot = FrameLinkSecureSession(localKey: pilotKey)
        var plotter = FrameLinkSecureSession(localKey: plotterKey)

        // First connection: Pilot approves, Plotter buffers the proof and
        // never answers before the connection is torn down.
        let firstPilotHello = try XCTUnwrap(pilot.begin(random: { Data(repeating: 7, count: $0) }))
        let firstPlotterHello = try XCTUnwrap(plotter.begin(random: { Data(repeating: 8, count: $0) }))
        let plotterRequest = try pairingRequest(pilot.receive(firstPlotterHello))
        _ = try pairingRequest(plotter.receive(firstPilotHello))
        let firstApproval = try XCTUnwrap(pilot.approvePending(publicKey: plotterRequest.publicKey))
        XCTAssertEqual(plotter.receive(firstApproval.proof), .waiting)
        plotter.resetSession()

        // Reconnect: Pilot already trusts Plotter and sends its proof at once.
        let pilotHello = try XCTUnwrap(pilot.begin(random: { Data(repeating: 9, count: $0) }))
        let plotterHello = try XCTUnwrap(plotter.begin(random: { Data(repeating: 10, count: $0) }))
        guard case .send(let pilotProof)? = pilot.receive(plotterHello) else {
            return XCTFail("trusted Pilot must answer the hello with its proof")
        }
        let pilotRequest = try pairingRequest(plotter.receive(pilotHello))
        XCTAssertEqual(
            plotter.receive(pilotProof),
            .waiting,
            "a proof from a torn-down connection must not block the new handshake"
        )
        XCTAssertNil(plotter.receive(firstApproval.proof), "only one proof is buffered per handshake")
        let plotterApproval = try XCTUnwrap(plotter.approvePending(publicKey: pilotRequest.publicKey))
        XCTAssertTrue(plotterApproval.authenticated)
        XCTAssertEqual(pilot.receive(plotterApproval.proof), .authenticated)
    }

    func testFrameLinkEndpointsProveTheStoredKeyAfterAnIdentityRotation() async throws {
        // An in-memory vault stands in for the Keychain identity, so this
        // drives the production path: regenerate -> notification ->
        // observer -> reload through the vault -> rebuilt FrameLink identity.
        let vault = DeviceIdentity.Vault.inMemory()
        let stored = try base64(vault.loadOrCreate())
        let sender = FrameSender(usesEphemeralIdentity: true, identityChanges: vault.changeSource)
        let receiver = FrameReceiver(identityChanges: vault.changeSource)
        // Both endpoints began from an ephemeral key; each reloads once after
        // subscribing, so a rotation before the observer existed is not missed.
        let senderAtStart = await sender.localIdentityPublicKeyBase64()
        let receiverAtStart = await receiver.localIdentityPublicKeyBase64()
        XCTAssertEqual(senderAtStart, stored)
        XCTAssertEqual(receiverAtStart, stored)

        // `post` runs both observers synchronously and each reload is queued
        // on its endpoint's queue ahead of the getter, so these reads are ordered.
        let rotated = try base64(vault.regenerate())
        XCTAssertNotEqual(rotated, stored)

        let senderKey = await sender.localIdentityPublicKeyBase64()
        let receiverKey = await receiver.localIdentityPublicKeyBase64()
        XCTAssertEqual(senderKey, rotated, "Pilot's FrameLink must prove the stored key")
        XCTAssertEqual(receiverKey, rotated, "Plotter's FrameLink must prove the stored key")
    }

    /// #429 with a handshake in flight: Kneeboard is waiting on Cockpit's
    /// pairing approval when the identity rotates. The approval request and
    /// the connection handshaking with the old key must both be dropped.
    func testIdentityRotationDropsTheSenderConnectionAndPendingPairing() async throws {
        let vault = DeviceIdentity.Vault.inMemory()
        let sender = FrameSender(usesEphemeralIdentity: true, identityChanges: vault.changeSource)
        let pairing = PairingEvents()
        sender.onPairingRequestChanged = { pairing.record($0 != nil) }
        let kneeboardSocket = try LoopbackTCPPeer()
        defer { kneeboardSocket.stop() }
        let endpoint = try await kneeboardSocket.endpoint()
        sender.adoptForTesting(NWConnection(to: endpoint, using: FrameLink.tcpParameters()))

        // Cockpit's hello arrives first; Kneeboard answers with an identity
        // Cockpit has not pinned, so Cockpit asks the user to pair.
        try await waitUntil("Cockpit hello") { kneeboardSocket.receivedByteCount > 0 }
        var kneeboard = FrameLinkSecureSession(localKey: Curve25519.KeyAgreement.PrivateKey())
        let kneeboardHello = try XCTUnwrap(kneeboard.begin())
        kneeboardSocket.send(FrameLink.frame(kneeboardHello))
        try await waitUntil("pairing approval requested") { pairing.events == [true] }

        try vault.regenerate()

        try await waitUntil("pending pairing dropped") { pairing.events == [true, false] }
        try await waitUntil("old-key connection closed") { kneeboardSocket.isClosedByPeer }
        let senderKey = await sender.localIdentityPublicKeyBase64()
        XCTAssertEqual(senderKey, try base64(vault.loadOrCreate()))
    }

    /// #429 with Plotter's stream connected and awaiting pairing approval:
    /// the rotation tears that connection down instead of letting it keep
    /// proving the old key.
    func testIdentityRotationTearsDownTheReceiverConnection() async throws {
        let vault = DeviceIdentity.Vault.inMemory()
        let receiver = FrameReceiver(identityChanges: vault.changeSource)
        let pairing = PairingEvents()
        receiver.onPairingRequestChanged = { pairing.record($0 != nil) }
        let cockpitSocket = try LoopbackTCPPeer()
        defer { cockpitSocket.stop() }
        let endpoint = try await cockpitSocket.endpoint()
        receiver.connectForTesting(to: endpoint)

        try await waitUntil("Kneeboard hello") { cockpitSocket.receivedByteCount > 0 }
        var cockpit = FrameLinkSecureSession(localKey: Curve25519.KeyAgreement.PrivateKey())
        let cockpitHello = try XCTUnwrap(cockpit.begin())
        cockpitSocket.send(FrameLink.frame(cockpitHello))
        try await waitUntil("pairing approval requested") { pairing.events == [true] }

        try vault.regenerate()

        try await waitUntil("old-key connection closed") { cockpitSocket.isClosedByPeer }
        XCTAssertEqual(pairing.events, [true, false], "the pending approval must be dropped")
        let receiverKey = await receiver.localIdentityPublicKeyBase64()
        XCTAssertEqual(receiverKey, try base64(vault.loadOrCreate()))
    }

    private func base64(_ key: Curve25519.KeyAgreement.PrivateKey) -> String {
        key.publicKey.rawRepresentation.base64EncodedString()
    }

    private func waitUntil(
        _ condition: String,
        timeout: TimeInterval = 5,
        _ predicate: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            guard Date() < deadline else {
                throw NSError(
                    domain: "FrameLinkSecurityTests",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "timed out waiting for \(condition)"]
                )
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func authenticateTrusted(
        _ pilot: inout FrameLinkSecureSession,
        _ plotter: inout FrameLinkSecureSession,
        pilotNonce: UInt8,
        plotterNonce: UInt8
    ) throws {
        let pilotHello = try XCTUnwrap(pilot.begin(
            random: { Data(repeating: pilotNonce, count: $0) }
        ))
        let plotterHello = try XCTUnwrap(plotter.begin(
            random: { Data(repeating: plotterNonce, count: $0) }
        ))
        guard case .send(let proofForPilot)? = plotter.receive(pilotHello),
              case .send(let proofForPlotter)? = pilot.receive(plotterHello) else {
            return XCTFail("expected proofs from trusted peers")
        }
        XCTAssertEqual(pilot.receive(proofForPilot), .authenticated)
        XCTAssertEqual(plotter.receive(proofForPlotter), .authenticated)
    }

    private func pairingRequest(
        _ opened: FrameLinkSecureSession.Opened?
    ) throws -> FrameLinkPairingRequest {
        guard case .pairingRequired(let request)? = opened else {
            throw NSError(domain: "FrameLinkSecurityTests", code: 1)
        }
        return request
    }
}

/// Records pairing-request callbacks (`true` raised, `false` cleared); the
/// endpoints invoke them on their own queues.
private final class PairingEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Bool] = []

    var events: [Bool] { lock.withLock { recorded } }

    func record(_ raised: Bool) {
        lock.withLock { recorded.append(raised) }
    }
}

/// A loopback TCP socket standing in for the other FrameLink device: it
/// records how many bytes arrive and whether the endpoint under test closed
/// the connection (#429).
private final class LoopbackTCPPeer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.blau.tests.framelink.loopback")
    private let listener: NWListener
    private let lock = NSLock()
    private var port: NWEndpoint.Port?
    private var accepted: NWConnection?
    private var received = 0
    private var closed = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state else { return }
            let port = self.listener.port
            self.lock.withLock { self.port = port }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.accept(connection)
        }
        listener.start(queue: queue)
    }

    var receivedByteCount: Int { lock.withLock { received } }
    var isClosedByPeer: Bool { lock.withLock { closed } }

    /// The loopback address, once the listener is ready.
    func endpoint() async throws -> NWEndpoint {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let port = lock.withLock({ port }) {
                return .hostPort(host: "127.0.0.1", port: port)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "FrameLinkSecurityTests", code: 3)
    }

    func send(_ data: Data) {
        lock.withLock { accepted }?.send(content: data, completion: .contentProcessed { _ in })
    }

    func stop() {
        lock.withLock { accepted }?.cancel()
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { accepted = connection }
        connection.start(queue: queue)
        receiveNext(on: connection)
    }

    private func receiveNext(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lock.withLock { self.received += data.count }
            }
            if isComplete || error != nil {
                self.lock.withLock { self.closed = true }
                return
            }
            self.receiveNext(on: connection)
        }
    }
}
