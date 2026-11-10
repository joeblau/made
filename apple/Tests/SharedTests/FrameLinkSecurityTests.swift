import CryptoKit
import Foundation
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

    func testFrameLinkEndpointsProveTheStoredKeyAfterAnIdentityRotation() async {
        // A private center and loader stand in for the Keychain identity, so
        // this drives the production path: rotation notification ->
        // observer -> reload through the loader -> rebuilt FrameLink identity.
        let center = NotificationCenter()
        let stored = Curve25519.KeyAgreement.PrivateKey()
        let storedRaw = stored.rawRepresentation
        let storedPublic = stored.publicKey.rawRepresentation.base64EncodedString()
        let changes = DeviceIdentity.ChangeSource(
            center: center,
            load: { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: storedRaw) }
        )
        let sender = FrameSender(usesEphemeralIdentity: true, identityChanges: changes)
        let receiver = FrameReceiver(identityChanges: changes)
        let originalSender = await sender.localIdentityPublicKeyBase64()
        let originalReceiver = await receiver.localIdentityPublicKeyBase64()
        XCTAssertNotEqual(originalSender, storedPublic)
        XCTAssertNotEqual(originalReceiver, storedPublic)

        // `post` runs both observers synchronously and each reload is queued
        // on its endpoint's queue ahead of the getter, so these reads are ordered.
        center.post(name: DeviceIdentity.didChangeNotification, object: nil)

        let senderKey = await sender.localIdentityPublicKeyBase64()
        let receiverKey = await receiver.localIdentityPublicKeyBase64()
        XCTAssertEqual(senderKey, storedPublic, "Pilot's FrameLink must prove the stored key")
        XCTAssertEqual(receiverKey, storedPublic, "Plotter's FrameLink must prove the stored key")
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
