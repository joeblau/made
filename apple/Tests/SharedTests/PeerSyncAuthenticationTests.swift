import CryptoKit
import Foundation
@preconcurrency import MultipeerConnectivity
import XCTest

@testable import Copilot

final class PeerSyncAuthenticationTests: XCTestCase {
    @MainActor
    func testReliableSendReportsFailureWhenNoPeerIsConnected() async {
        let service = PeerSyncService(role: .browser, displayName: "Walkie Transport Test")
        let accepted = await service.sendReliably(.transcribedSpeech(TranscribedSpeech(
            workspaceID: UUID(),
            text: "Run the tests",
            recordingID: UUID()
        )))

        XCTAssertFalse(accepted, "dictation must remain recoverable when no authenticated peer can receive it")
        XCTAssertFalse(service.isConnected)
    }

    @MainActor
    func testServiceAdvertisesTheStoredKeyAfterAnIdentityRotation() async throws {
        // An in-memory vault stands in for the Keychain identity, so this
        // drives the production path: regenerate -> notification ->
        // observer -> reload through the vault -> rebuilt authenticator.
        let vault = DeviceIdentity.Vault.inMemory()
        let stored = try base64(vault.loadOrCreate())
        let service = PeerSyncService(
            role: .advertiser,
            displayName: "Rotation Test",
            usesEphemeralIdentity: true,
            identityChanges: vault.changeSource
        )
        // The service began from an ephemeral key; it reloads once after
        // subscribing, so a rotation before the observer existed is not missed.
        let atStart = await service.localIdentityPublicKeyBase64()
        XCTAssertEqual(atStart, stored, "a new service must prove the stored key")

        // `post` runs the observer synchronously and the reload is queued on
        // the transport queue ahead of the getter, so this read is ordered.
        let rotated = try base64(vault.regenerate())
        XCTAssertNotEqual(rotated, stored)

        let advertised = await service.localIdentityPublicKeyBase64()
        XCTAssertEqual(
            advertised,
            rotated,
            "after regeneration the sync transport must advertise and prove the stored key"
        )
    }

    /// #429 through a started service: an authenticated session is torn down
    /// the moment the identity rotates, and the reconnect proves only the new
    /// key, which the peer accepts once it approves the key change.
    @MainActor
    func testRotationTearsDownTheLiveSessionAndAdvertisesTheNewKey() async throws {
        let pilotKey = Curve25519.KeyAgreement.PrivateKey()
        let copilotKey = Curve25519.KeyAgreement.PrivateKey()
        let slot = InMemoryIdentitySlot()
        slot.data = pilotKey.rawRepresentation
        let vault = DeviceIdentity.Vault.inMemory(slot: slot)
        let transport = RecordingSyncTransport()
        let peer = MCPeerID(displayName: "Walkie Rotation Test")
        let mcSession = MCSession(peer: peer)
        let service = PeerSyncService(
            role: .advertiser,
            displayName: "Cockpit Rotation Test",
            authenticator: PeerSyncAuthenticator(
                localKey: pilotKey,
                peerPublicKeyBase64: base64(copilotKey)
            ),
            transport: transport,
            authenticationTimeout: 60,
            reconnectDelay: 60,
            identityChanges: vault.changeSource
        )
        var copilot = PeerSyncAuthenticator(localKey: copilotKey, peerPublicKeyBase64: base64(pilotKey))
        service.start()
        await transportBarrier(service)

        // Authenticate a live session with the stored (current) key.
        transport.connect(peer)
        service.session(mcSession, peer: peer, didChange: .connected)
        await transportBarrier(service)
        let copilotHello = try XCTUnwrap(copilot.beginSession(
            random: { Data(repeating: 0x55, count: $0) }
        ))
        guard let pilotHello = transport.sent.first,
              case .helloResponse(let readyForPilot)? = copilot.open(pilotHello) else {
            return XCTFail("expected the service hello")
        }
        service.session(mcSession, didReceive: copilotHello, fromPeer: peer)
        service.session(mcSession, didReceive: readyForPilot, fromPeer: peer)
        await transportBarrier(service)
        guard transport.sent.count == 2 else { return XCTFail("expected the service ready") }
        XCTAssertEqual(copilot.open(transport.sent[1]), .authenticated)
        let acceptedBefore = await service.sendReliably(.mouseClick(MouseClick(button: 0)))
        XCTAssertTrue(acceptedBefore)
        let connected = await waitUntil { service.isConnected }
        XCTAssertTrue(connected)
        let disconnectsBefore = transport.disconnectCount

        let rotatedKey = try vault.regenerate()
        await transportBarrier(service)

        XCTAssertEqual(
            transport.disconnectCount,
            disconnectsBefore + 1,
            "the session proven with the rotated-out key must be torn down"
        )
        XCTAssertTrue(transport.connectedPeers.isEmpty)
        let advertised = await service.localIdentityPublicKeyBase64()
        XCTAssertEqual(advertised, base64(rotatedKey), "the service must advertise the new key")
        let acceptedAfter = await service.sendReliably(.mouseClick(MouseClick(button: 0)))
        XCTAssertFalse(acceptedAfter, "nothing may be sealed for the torn-down session")
        let dropped = await waitUntil { !service.isConnected }
        XCTAssertTrue(dropped, "the UI must stop reporting the old session as connected")

        // The reconnect starts a fresh handshake that proves only the new key.
        let sentBefore = transport.sent.count
        transport.connect(peer)
        service.session(mcSession, peer: peer, didChange: .connected)
        await transportBarrier(service)
        XCTAssertEqual(transport.sent.count, sentBefore + 1, "the reconnect must send a fresh hello")
        let rotatedHello = try XCTUnwrap(transport.sent.last)
        var stalePin = PeerSyncAuthenticator(localKey: copilotKey, peerPublicKeyBase64: base64(pilotKey))
        _ = stalePin.beginSession(random: { Data(repeating: 0x66, count: $0) })
        XCTAssertNil(stalePin.open(rotatedHello), "a peer pinning the old key must refuse the new hello")
        var approved = PeerSyncAuthenticator(localKey: copilotKey, peerPublicKeyBase64: base64(rotatedKey))
        _ = approved.beginSession(random: { Data(repeating: 0x77, count: $0) })
        guard case .helloResponse? = approved.open(rotatedHello) else {
            return XCTFail("the peer must accept the new key once it approves the change")
        }
    }

    func testRotatedLocalIdentityKeepsPinAndProvesOnlyTheNewKey() throws {
        let keys = makeAuthenticators()
        var pilot = keys.pilot
        var copilot = keys.copilot
        try authenticate(&pilot, &copilot)

        let rotatedKey = Curve25519.KeyAgreement.PrivateKey()
        let rotatedPublic = rotatedKey.publicKey.rawRepresentation.base64EncodedString()
        var rotated = pilot.replacingLocalKey(rotatedKey)
        XCTAssertEqual(rotated.localPublicKeyBase64, rotatedPublic)
        XCTAssertEqual(rotated.peerPublicKeyBase64, pilot.peerPublicKeyBase64)
        XCTAssertFalse(rotated.isAuthenticated, "no session may survive a rotation")
        XCTAssertNil(rotated.sealMessage(Data("stale".utf8)))

        // The peer still pins the old key, so the rotated hello is refused
        // until the user approves the key change.
        _ = copilot.beginSession(random: { Data(repeating: 0x51, count: $0) })
        let rotatedHello = try XCTUnwrap(rotated.beginSession(
            random: { Data(repeating: 0x52, count: $0) }
        ))
        XCTAssertNil(copilot.open(rotatedHello))

        XCTAssertTrue(copilot.trust(peerPublicKeyBase64: rotatedPublic))
        try authenticate(&rotated, &copilot, pilotNonce: 0x61, copilotNonce: 0x62)
        let command = try XCTUnwrap(rotated.sealMessage(Data("fresh".utf8)))
        XCTAssertEqual(copilot.open(command), .message(Data("fresh".utf8)))
    }

    func testUnknownAndChangedAdvertisersRequireExplicitApproval() {
        let trusted = Curve25519.KeyAgreement.PrivateKey()
            .publicKey.rawRepresentation.base64EncodedString()
        let candidate = Curve25519.KeyAgreement.PrivateKey()
            .publicKey.rawRepresentation.base64EncodedString()

        XCTAssertEqual(
            PeerSyncService.pairingDecision(candidate: candidate, trusted: nil),
            .approvalRequired(isKeyChange: false)
        )
        XCTAssertEqual(
            PeerSyncService.pairingDecision(candidate: candidate, trusted: trusted),
            .approvalRequired(isKeyChange: true)
        )
        XCTAssertEqual(
            PeerSyncService.pairingDecision(candidate: trusted, trusted: trusted),
            .trusted
        )
        XCTAssertEqual(
            PeerSyncService.pairingDecision(candidate: "not-a-key", trusted: trusted),
            .reject
        )
        XCTAssertEqual(
            PeerSyncAuthenticator.pairingCode(local: trusted, peer: candidate),
            PeerSyncAuthenticator.pairingCode(local: candidate, peer: trusted)
        )
    }

    func testMutualIdentityAuthenticationAndReplayRejection() throws {
        let keys = makeAuthenticators()
        var pilot = keys.pilot
        var copilot = keys.copilot
        try authenticate(&pilot, &copilot)

        let payload = try JSONEncoder().encode(SyncMessage.mouseClick(MouseClick(button: 0)))
        let envelope = try XCTUnwrap(copilot.sealMessage(payload))
        XCTAssertEqual(copilot.isAuthenticated, true)
        XCTAssertEqual(pilot.open(envelope), .message(payload))
        XCTAssertNil(pilot.open(envelope), "the same control command must not replay")
    }

    func testRogueIdentityCannotAuthenticateControlOrKeyAnnouncement() throws {
        let pilotKey = Curve25519.KeyAgreement.PrivateKey()
        let copilotKey = Curve25519.KeyAgreement.PrivateKey()
        let rogueKey = Curve25519.KeyAgreement.PrivateKey()
        let pilotPublic = pilotKey.publicKey.rawRepresentation.base64EncodedString()
        let copilotPublic = copilotKey.publicKey.rawRepresentation.base64EncodedString()

        var pilot = PeerSyncAuthenticator(
            localKey: pilotKey,
            peerPublicKeyBase64: copilotPublic
        )
        var rogue = PeerSyncAuthenticator(
            localKey: rogueKey,
            peerPublicKeyBase64: pilotPublic
        )
        _ = pilot.beginSession(random: { Data(repeating: 1, count: $0) })
        let rogueHello = try XCTUnwrap(rogue.beginSession(random: { Data(repeating: 9, count: $0) }))
        XCTAssertNil(pilot.open(rogueHello), "a copied service name cannot prove the pinned identity")

        let control = try JSONEncoder().encode(SyncMessage.terminalInput(.enter))
        let keyChange = try JSONEncoder().encode(SyncMessage.deviceKey(.init(
            role: .copilot,
            publicKey: rogueKey.publicKey.rawRepresentation.base64EncodedString()
        )))
        XCTAssertNil(rogue.sealMessage(control))
        XCTAssertNil(rogue.sealMessage(keyChange))
    }

    func testTamperingAndPriorSessionPacketsAreRejectedAfterReconnect() throws {
        let keys = makeAuthenticators()
        var pilot = keys.pilot
        var copilot = keys.copilot
        try authenticate(&pilot, &copilot)

        let oldEnvelope = try XCTUnwrap(copilot.sealMessage(Data("old".utf8)))
        var tampered = oldEnvelope
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        XCTAssertNil(pilot.open(tampered))

        try authenticate(
            &pilot,
            &copilot,
            pilotNonce: 0x31,
            copilotNonce: 0x42
        )
        XCTAssertNil(pilot.open(oldEnvelope), "a packet from a prior session must not authorize")
        let fresh = try XCTUnwrap(copilot.sealMessage(Data("fresh".utf8)))
        XCTAssertEqual(pilot.open(fresh), .message(Data("fresh".utf8)))
    }

    /// #430: MultipeerConnectivity can deliver the peer's hello before the
    /// local `.connected` callback runs `beginSession()`. The hello is sent
    /// once, so it must be held and replayed exactly once, not dropped.
    func testHelloDeliveredBeforeBeginSessionCompletesHandshakeWhenReplayed() throws {
        let keys = makeAuthenticators()
        var pilot = keys.pilot
        var copilot = keys.copilot
        var early = PeerSyncEarlyFrameBuffer<String>()

        let copilotHello = try XCTUnwrap(copilot.beginSession(
            random: { Data(repeating: 0x22, count: $0) }
        ))
        XCTAssertNil(pilot.open(copilotHello), "a hello before beginSession cannot be processed yet")
        XCTAssertLessThanOrEqual(copilotHello.count, PeerSyncEarlyFrameBuffer<String>.maxFrameBytes)
        XCTAssertTrue(early.hold(copilotHello, from: "copilot"))

        let pilotHello = try XCTUnwrap(pilot.beginSession(
            random: { Data(repeating: 0x11, count: $0) }
        ))
        let replay = try XCTUnwrap(early.take(for: "copilot"))
        XCTAssertNil(early.take(for: "copilot"), "the early hello replays exactly once")

        guard case .helloResponse(let readyForCopilot)? = pilot.open(replay),
              case .helloResponse(let readyForPilot)? = copilot.open(pilotHello) else {
            return XCTFail("expected mutual hello responses after replaying the early hello")
        }
        XCTAssertEqual(pilot.open(readyForPilot), .authenticated)
        XCTAssertEqual(copilot.open(readyForCopilot), .authenticated)
        XCTAssertTrue(pilot.isAuthenticated)
        XCTAssertTrue(copilot.isAuthenticated)
    }

    func testEarlyFrameBufferBoundsFramesAndPeersBeforeRetaining() {
        typealias Buffer = PeerSyncEarlyFrameBuffer<String>
        var early = Buffer()

        XCTAssertFalse(early.hold(Data(), from: "a"))
        XCTAssertFalse(early.hold(Data(count: Buffer.maxFrameBytes + 1), from: "a"))
        XCTAssertEqual(early.count, 0)

        for index in 0 ..< Buffer.maxPeers {
            XCTAssertTrue(early.hold(Data([UInt8(index)]), from: "peer-\(index)"))
        }
        XCTAssertFalse(early.hold(Data([0xFF]), from: "extra"), "peer count stays bounded")
        XCTAssertTrue(early.hold(Data([0xAA]), from: "peer-0"), "a known peer's newest frame replaces its old one")
        XCTAssertEqual(early.count, Buffer.maxPeers)
        XCTAssertEqual(early.take(for: "peer-0"), Data([0xAA]))
        XCTAssertNil(early.take(for: "extra"))

        early.discard("peer-1")
        XCTAssertNil(early.take(for: "peer-1"))
        early.removeAll()
        XCTAssertEqual(early.count, 0)
    }

    func testSyncHandshakeHasAuthenticationDeadline() {
        XCTAssertGreaterThan(PeerSyncService.authenticationTimeout, 0)
        XCTAssertLessThanOrEqual(
            PeerSyncService.authenticationTimeout,
            30,
            "a stalled sync handshake must be torn down well before users give up"
        )
    }

    /// #430 through the real service: the peer's hello reaches the delegate
    /// before `.connected`, is held, and is replayed after `beginSession()`.
    @MainActor
    func testServiceAuthenticatesWhenPeerHelloArrivesBeforeConnected() async throws {
        let harness = makeServiceHarness(authenticationTimeout: 60)
        var copilot = harness.copilot
        harness.service.start()
        await transportBarrier(harness.service)
        let disconnectsAfterStart = harness.transport.disconnectCount

        let copilotHello = try XCTUnwrap(copilot.beginSession(
            random: { Data(repeating: 0x22, count: $0) }
        ))
        harness.service.session(harness.mcSession, didReceive: copilotHello, fromPeer: harness.peer)
        harness.transport.connect(harness.peer)
        harness.service.session(harness.mcSession, peer: harness.peer, didChange: .connected)
        await transportBarrier(harness.service)

        let sent = harness.transport.sent
        XCTAssertEqual(sent.count, 2, "the service sends its hello, then answers the replayed early hello")
        guard sent.count == 2,
              case .helloResponse(let readyForPilot)? = copilot.open(sent[0]) else {
            return XCTFail("expected the service hello followed by its ready")
        }
        XCTAssertEqual(copilot.open(sent[1]), .authenticated)

        harness.service.session(harness.mcSession, didReceive: readyForPilot, fromPeer: harness.peer)
        let accepted = await harness.service.sendReliably(.mouseClick(MouseClick(button: 0)))
        XCTAssertTrue(accepted, "the service must authenticate and seal commands after the replay")
        let command = try XCTUnwrap(harness.transport.sent.last)
        guard case .message(let payload)? = copilot.open(command) else {
            return XCTFail("the peer must accept the authenticated command")
        }
        XCTAssertNotNil(try? JSONDecoder().decode(SyncMessage.self, from: payload))
        let connected = await waitUntil { harness.service.isConnected }
        XCTAssertTrue(connected)
        XCTAssertEqual(harness.transport.disconnectCount, disconnectsAfterStart)
        XCTAssertTrue(harness.transport.cancelledPeers.isEmpty)
    }

    /// #430: a repeated `.connected` must not mint a second hello whose new
    /// nonce the peer would reject; the first handshake still completes.
    @MainActor
    func testRepeatedConnectedCallbackSendsOneHelloAndStillAuthenticates() async throws {
        let harness = makeServiceHarness(authenticationTimeout: 60)
        var copilot = harness.copilot
        harness.service.start()
        await transportBarrier(harness.service)
        harness.transport.connect(harness.peer)
        harness.service.session(harness.mcSession, peer: harness.peer, didChange: .connected)
        harness.service.session(harness.mcSession, peer: harness.peer, didChange: .connected)
        await transportBarrier(harness.service)

        XCTAssertEqual(harness.transport.sent.count, 1, "a repeated .connected must not send a second hello")
        XCTAssertTrue(harness.transport.cancelledPeers.isEmpty, "the active peer must not be cancelled")

        let copilotHello = try XCTUnwrap(copilot.beginSession(
            random: { Data(repeating: 0x33, count: $0) }
        ))
        guard let pilotHello = harness.transport.sent.first,
              case .helloResponse(let readyForPilot)? = copilot.open(pilotHello) else {
            return XCTFail("the first hello must stay valid after a repeated .connected")
        }
        harness.service.session(harness.mcSession, didReceive: copilotHello, fromPeer: harness.peer)
        harness.service.session(harness.mcSession, didReceive: readyForPilot, fromPeer: harness.peer)
        await transportBarrier(harness.service)

        let sent = harness.transport.sent
        XCTAssertEqual(sent.count, 2)
        guard sent.count == 2 else { return }
        XCTAssertEqual(copilot.open(sent[1]), .authenticated)
        let accepted = await harness.service.sendReliably(.mouseClick(MouseClick(button: 0)))
        XCTAssertTrue(accepted, "the handshake must authenticate despite the repeated callback")
    }

    /// #430: a peer that never answers is torn down at the (shortened)
    /// authentication deadline, the reconnect is no longer blocked by a
    /// connected peer, and the next connection starts a fresh handshake.
    @MainActor
    func testStalledHandshakeIsTornDownAtTheDeadlineAndReconnects() async throws {
        let harness = makeServiceHarness(authenticationTimeout: 0.05, reconnectDelay: 0.05)
        var copilot = harness.copilot
        harness.service.start()
        await transportBarrier(harness.service)
        let disconnectsAfterStart = harness.transport.disconnectCount

        harness.transport.connect(harness.peer)
        harness.service.session(harness.mcSession, peer: harness.peer, didChange: .connected)
        await transportBarrier(harness.service)
        XCTAssertEqual(harness.transport.sent.count, 1)

        let tornDown = await waitUntil { harness.transport.disconnectCount > disconnectsAfterStart }
        XCTAssertTrue(tornDown, "a stalled handshake must be disconnected at the deadline")
        XCTAssertEqual(harness.transport.cancelledPeers, [harness.peer])
        XCTAssertTrue(harness.transport.connectedPeers.isEmpty)
        let restarted = await waitUntil { harness.service.statusText == "Restarting sync advertisement" }
        XCTAssertTrue(restarted, "teardown must let the reconnect restart discovery")
        XCTAssertFalse(harness.service.isConnected)

        harness.transport.connect(harness.peer)
        harness.service.session(harness.mcSession, peer: harness.peer, didChange: .connected)
        await transportBarrier(harness.service)
        let sent = harness.transport.sent
        XCTAssertEqual(sent.count, 2, "the reconnected peer must receive a fresh hello")
        guard sent.count == 2 else { return }
        XCTAssertNotEqual(sent[0], sent[1])
        _ = copilot.beginSession(random: { Data(repeating: 0x44, count: $0) })
        guard case .helloResponse? = copilot.open(sent[1]) else {
            return XCTFail("the fresh hello must be a valid start of a new handshake")
        }
    }

    private struct ServiceHarness {
        let service: PeerSyncService
        let transport: RecordingSyncTransport
        let copilot: PeerSyncAuthenticator
        let peer: MCPeerID
        let mcSession: MCSession
    }

    /// A Cockpit-role service pinned to the returned Walkie authenticator,
    /// driven through its real MCSession delegate callbacks.
    private func makeServiceHarness(
        authenticationTimeout: TimeInterval,
        reconnectDelay: TimeInterval = 60
    ) -> ServiceHarness {
        let keys = makeAuthenticators()
        let transport = RecordingSyncTransport()
        let peer = MCPeerID(displayName: "Walkie Handshake Test")
        return ServiceHarness(
            service: PeerSyncService(
                role: .advertiser,
                displayName: "Cockpit Handshake Test",
                authenticator: keys.pilot,
                transport: transport,
                authenticationTimeout: authenticationTimeout,
                reconnectDelay: reconnectDelay
            ),
            transport: transport,
            copilot: keys.copilot,
            peer: peer,
            mcSession: MCSession(peer: peer)
        )
    }

    /// Returns after everything already queued on the service's serial
    /// transport queue has run.
    @MainActor
    private func transportBarrier(_ service: PeerSyncService) async {
        _ = await service.localIdentityPublicKeyBase64()
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    private func base64(_ key: Curve25519.KeyAgreement.PrivateKey) -> String {
        key.publicKey.rawRepresentation.base64EncodedString()
    }

    private func makeAuthenticators() -> (
        pilot: PeerSyncAuthenticator,
        copilot: PeerSyncAuthenticator
    ) {
        let pilotKey = Curve25519.KeyAgreement.PrivateKey()
        let copilotKey = Curve25519.KeyAgreement.PrivateKey()
        return (
            PeerSyncAuthenticator(
                localKey: pilotKey,
                peerPublicKeyBase64: copilotKey.publicKey.rawRepresentation.base64EncodedString()
            ),
            PeerSyncAuthenticator(
                localKey: copilotKey,
                peerPublicKeyBase64: pilotKey.publicKey.rawRepresentation.base64EncodedString()
            )
        )
    }

    private func authenticate(
        _ pilot: inout PeerSyncAuthenticator,
        _ copilot: inout PeerSyncAuthenticator,
        pilotNonce: UInt8 = 0x11,
        copilotNonce: UInt8 = 0x22
    ) throws {
        let pilotHello = try XCTUnwrap(pilot.beginSession(
            random: { Data(repeating: pilotNonce, count: $0) }
        ))
        let copilotHello = try XCTUnwrap(copilot.beginSession(
            random: { Data(repeating: copilotNonce, count: $0) }
        ))

        guard case .helloResponse(let readyForPilot)? = copilot.open(pilotHello),
              case .helloResponse(let readyForCopilot)? = pilot.open(copilotHello) else {
            return XCTFail("expected mutual hello responses")
        }
        XCTAssertEqual(pilot.open(readyForPilot), .authenticated)
        XCTAssertEqual(copilot.open(readyForCopilot), .authenticated)
        XCTAssertTrue(pilot.isAuthenticated)
        XCTAssertTrue(copilot.isAuthenticated)
    }
}

/// Records what `PeerSyncService` asks of its MCSession so tests drive the
/// real delegate callbacks, replay and deadline logic without radios (#430).
/// The service calls it on its transport queue; tests read it on the main actor.
private final class RecordingSyncTransport: PeerSyncSessionTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [MCPeerID] = []
    private var frames: [Data] = []
    private var cancelled: [MCPeerID] = []
    private var disconnects = 0

    var connectedPeers: [MCPeerID] { lock.withLock { peers } }
    var sent: [Data] { lock.withLock { frames } }
    var cancelledPeers: [MCPeerID] { lock.withLock { cancelled } }
    var disconnectCount: Int { lock.withLock { disconnects } }

    func connect(_ peer: MCPeerID) {
        lock.withLock { peers = [peer] }
    }

    func send(_ data: Data, toPeers peerIDs: [MCPeerID], with mode: MCSessionSendDataMode) throws {
        lock.withLock { frames.append(data) }
    }

    func cancelConnectPeer(_ peerID: MCPeerID) {
        lock.withLock { cancelled.append(peerID) }
    }

    /// Like MCSession, disconnecting drops every connected peer.
    func disconnect() {
        lock.withLock {
            disconnects += 1
            peers = []
        }
    }
}
