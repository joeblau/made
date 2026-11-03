import CryptoKit
import Foundation
import XCTest

@testable import Copilot

final class DronePairingTests: XCTestCase {
    private final class MemoryStorage: PairingSecretStoring {
        var values: [String: Data] = [:]

        func read(account: String) throws -> Data? { values[account] }
        func write(_ data: Data, account: String) throws { values[account] = data }
        func delete(account: String) throws { values.removeValue(forKey: account) }
    }

    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value

        init(_ value: Value) {
            stored = value
        }

        func get() -> Value {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func set(_ value: Value) {
            lock.lock()
            stored = value
            lock.unlock()
        }

        func update(_ transform: (inout Value) -> Void) {
            lock.lock()
            transform(&stored)
            lock.unlock()
        }
    }

    func testIdentityStoresAreNamespacedPersistentAndExplicitlyRotated() throws {
        let storage = MemoryStorage()
        let controllerStore = DroneIdentityStore(role: .controller, storage: storage)
        let workerStore = DroneIdentityStore(role: .worker, storage: storage)
        let controller = try controllerStore.loadOrCreate()
        let worker = try workerStore.loadOrCreate()

        XCTAssertEqual(try controllerStore.loadOrCreate().rawRepresentation, controller.rawRepresentation)
        XCTAssertEqual(try workerStore.loadOrCreate().rawRepresentation, worker.rawRepresentation)
        XCTAssertNotEqual(controller.rawRepresentation, worker.rawRepresentation)
        XCTAssertNotEqual(controllerStore.account, workerStore.account)
        XCTAssertEqual(storage.values[controllerStore.account], controller.rawRepresentation)
        XCTAssertEqual(storage.values[workerStore.account], worker.rawRepresentation)

        let rotated = try workerStore.rotate()
        XCTAssertNotEqual(rotated.rawRepresentation, worker.rawRepresentation)
        XCTAssertEqual(try workerStore.loadOrCreate().rawRepresentation, rotated.rawRepresentation)
    }

    func testFifteenWorkersHaveIndependentPinsAndSessionRecords() throws {
        let controllerStorage = MemoryStorage()
        let pairings = DronePairingStore(role: .controller, storage: controllerStorage)
        let controller = try DroneIdentityStore(
            role: .controller,
            storage: controllerStorage
        ).loadOrCreate()
        var records: [Data] = []

        for index in 0 ..< 15 {
            let worker = Curve25519.KeyAgreement.PrivateKey()
            let peerID = DronePeerID()
            try pairings.approve(worker.publicKey, for: peerID, replacing: nil)
            let started = try DroneHandshake.start(
                localKey: controller,
                pinnedWorkerKey: worker.publicKey,
                hello: DroneHello(capabilities: ["terminal.v1", "proof.\(index)"])
            )
            let accepted = try DroneHandshake.accept(
                localKey: worker,
                pinnedControllerKey: controller.publicKey,
                message: started.message
            )
            var controllerChannel = try started.pending.receive(accepted.response).channel
            var workerChannel = accepted.channel
            let record = try controllerChannel.seal(DroneEnvelope(kind: .heartbeat))
            XCTAssertEqual(try workerChannel.open(record), DroneEnvelope(kind: .heartbeat))
            records.append(record)

            let otherWorker = Curve25519.KeyAgreement.PrivateKey()
            let otherStart = try DroneHandshake.start(
                localKey: controller,
                pinnedWorkerKey: otherWorker.publicKey
            )
            let otherAccepted = try DroneHandshake.accept(
                localKey: otherWorker,
                pinnedControllerKey: controller.publicKey,
                message: otherStart.message
            )
            var otherChannel = otherAccepted.channel
            XCTAssertThrowsError(try otherChannel.open(record))
        }

        XCTAssertEqual(try pairings.pairedPeerIDs().count, 15)
        XCTAssertEqual(Set(records).count, records.count)
    }

    func testChangedKeyApprovalCannotReplacePinWithoutCurrentValue() throws {
        let storage = MemoryStorage()
        let store = DronePairingStore(role: .controller, storage: storage)
        let peerID = DronePeerID()
        let original = Curve25519.KeyAgreement.PrivateKey().publicKey
        let replacement = Curve25519.KeyAgreement.PrivateKey().publicKey
        try store.approve(original, for: peerID, replacing: nil)

        XCTAssertThrowsError(try store.approve(replacement, for: peerID, replacing: nil)) {
            XCTAssertEqual($0 as? DronePairingError, .pinChanged)
        }
        XCTAssertEqual(try store.pinnedKey(for: peerID)?.rawRepresentation, original.rawRepresentation)
        try store.approve(replacement, for: peerID, replacing: original)
        XCTAssertEqual(try store.pinnedKey(for: peerID)?.rawRepresentation, replacement.rawRepresentation)

        try store.revoke(peerID)
        XCTAssertNil(try store.pinnedKey(for: peerID))
        XCTAssertEqual(try store.pairedPeerIDs(), [])
    }

    func testPairingStoreRejectsDuplicateKeysAndThirtyThirdPeer() throws {
        let storage = MemoryStorage()
        let store = DronePairingStore(role: .controller, storage: storage)
        let peerIDs = (0 ..< DroneLimits.maxPairedWorkers).map { _ in DronePeerID() }
        for peerID in peerIDs {
            let key = Curve25519.KeyAgreement.PrivateKey().publicKey
            try store.approve(key, for: peerID, replacing: nil)
            XCTAssertThrowsError(try store.approve(key, for: DronePeerID(), replacing: nil)) {
                XCTAssertEqual($0 as? DronePairingError, .duplicatePeerKey)
            }
        }
        XCTAssertThrowsError(try store.approve(
            Curve25519.KeyAgreement.PrivateKey().publicKey,
            for: DronePeerID(),
            replacing: nil
        )) { XCTAssertEqual($0 as? DronePairingError, .pairingLimit) }
        XCTAssertEqual(try store.pairedPeerIDs().count, 32)
    }

    func testDirectConnectionAnnouncementProducesMatchingFreshApprovalRequests() throws {
        let controller = Curve25519.KeyAgreement.PrivateKey()
        let worker = Curve25519.KeyAgreement.PrivateKey()
        let controllerNonce = Data(repeating: 7, count: 32)
        let workerNonce = Data(repeating: 9, count: 32)
        let controllerAnnouncement = DronePairingAnnouncement(
            publicKey: controller.publicKey,
            nonce: controllerNonce
        )
        let workerAnnouncement = DronePairingAnnouncement(
            publicKey: worker.publicKey,
            nonce: workerNonce
        )
        let decoded = try DronePairingAnnouncement.decode(controllerAnnouncement.encode())
        XCTAssertEqual(decoded, controllerAnnouncement)

        let controllerRequest = try workerAnnouncement.request(
            localKey: controller,
            peerID: DronePeerID(),
            existingPin: nil
        )
        let workerRequest = try controllerAnnouncement.request(
            localKey: worker,
            peerID: DronePeerID(),
            existingPin: nil
        )
        XCTAssertEqual(controllerRequest.verificationCode, workerRequest.verificationCode)
        XCTAssertFalse(controllerRequest.isKeyChange)
        let changed = try workerAnnouncement.request(
            localKey: controller,
            peerID: DronePeerID(),
            existingPin: Curve25519.KeyAgreement.PrivateKey().publicKey
        )
        XCTAssertTrue(changed.isKeyChange)
        XCTAssertNotEqual(
            try DronePairingAnnouncement.make(localKey: worker).nonce,
            try DronePairingAnnouncement.make(localKey: worker).nonce
        )
        XCTAssertThrowsError(try DronePairingAnnouncement.decode(Data("plaintext".utf8)))
        XCTAssertThrowsError(try controllerAnnouncement.request(
            localKey: controller,
            peerID: DronePeerID(),
            existingPin: nil
        )) { XCTAssertEqual($0 as? DronePairingError, .selfPairing) }
    }

    func testWorkerSelectsOnlyApprovedControllerAmongManyPins() throws {
        let worker = Curve25519.KeyAgreement.PrivateKey()
        let controllers = (0 ..< 15).map { _ in Curve25519.KeyAgreement.PrivateKey() }
        let selected = controllers[11]
        let started = try DroneHandshake.start(
            localKey: selected,
            pinnedWorkerKey: worker.publicKey
        )
        let accepted = try DroneHandshake.accept(
            localKey: worker,
            pinnedControllerKeys: controllers.map(\.publicKey),
            message: started.message
        )
        XCTAssertEqual(accepted.controllerKey.rawRepresentation, selected.publicKey.rawRepresentation)
        var controller = try started.pending.receive(accepted.response).channel
        var workerChannel = accepted.channel
        XCTAssertEqual(
            try workerChannel.open(controller.seal(DroneEnvelope(kind: .heartbeat))),
            DroneEnvelope(kind: .heartbeat)
        )

        let rogue = try DroneHandshake.start(
            localKey: Curve25519.KeyAgreement.PrivateKey(),
            pinnedWorkerKey: worker.publicKey
        )
        XCTAssertThrowsError(try DroneHandshake.accept(
            localKey: worker,
            pinnedControllerKeys: controllers.map(\.publicKey),
            message: rogue.message
        ))
    }

    func testPlaintextTamperedWrongKeyAndPriorSessionRecordsFailClosed() throws {
        let controller = Curve25519.KeyAgreement.PrivateKey()
        let worker = Curve25519.KeyAgreement.PrivateKey()
        let started = try DroneHandshake.start(
            localKey: controller,
            pinnedWorkerKey: worker.publicKey
        )
        let accepted = try DroneHandshake.accept(
            localKey: worker,
            pinnedControllerKey: controller.publicKey,
            message: started.message
        )
        var controllerChannel = try started.pending.receive(accepted.response).channel
        var workerChannel = accepted.channel
        let record = try controllerChannel.seal(DroneEnvelope(kind: .heartbeat))

        XCTAssertThrowsError(try workerChannel.open(DroneProtocolCodec.encode(DroneEnvelope(
            kind: .heartbeat
        ))))
        var tampered = record
        tampered[tampered.startIndex] ^= 1
        XCTAssertThrowsError(try workerChannel.open(tampered))
        tampered = record
        tampered[tampered.index(before: tampered.endIndex)] ^= 1
        XCTAssertThrowsError(try workerChannel.open(tampered))
        XCTAssertEqual(try workerChannel.open(record), DroneEnvelope(kind: .heartbeat))
        XCTAssertThrowsError(try workerChannel.open(record)) {
            XCTAssertEqual($0 as? DroneProtocolError, .rejectedRecord)
        }

        let reconnected = try DroneHandshake.start(
            localKey: controller,
            pinnedWorkerKey: worker.publicKey
        )
        let reaccepted = try DroneHandshake.accept(
            localKey: worker,
            pinnedControllerKey: controller.publicKey,
            message: reconnected.message
        )
        var freshWorker = reaccepted.channel
        XCTAssertThrowsError(try freshWorker.open(record))
    }

    func testWorkerRejectsSurplusConnectionBeforeAuthentication() throws {
        let listening = expectation(description: "worker listening")
        let connected = expectation(description: "eight authenticated connections")
        connected.expectedFulfillmentCount = DroneLimits.maxConnectionsPerWorker
        let surplus = expectation(description: "surplus connection rejected")
        let port = Locked<UInt16?>(nil)
        let workerStorage = MemoryStorage()
        let workerIdentity = DroneIdentityStore(role: .worker, storage: workerStorage)
        let workerPairings = DronePairingStore(role: .worker, storage: workerStorage)
        let workerKey = try workerIdentity.loadOrCreate()
        let controllerKey = Curve25519.KeyAgreement.PrivateKey()
        let peerID = DronePeerID()
        try workerPairings.approve(controllerKey.publicKey, for: peerID, replacing: nil)
        let worker = DroneLANTransport(
            role: .worker,
            identityStore: workerIdentity,
            pairingStore: workerPairings
        )
        worker.onEvent = { event in
            switch event {
            case .listening(let boundPort):
                port.set(boundPort)
                listening.fulfill()
            case .connected:
                connected.fulfill()
            case .failed(_, let failure) where failure == .connectionLimit:
                surplus.fulfill()
            default:
                break
            }
        }
        worker.startListening()
        wait(for: [listening], timeout: 5)

        var controllers: [DroneLANTransport] = []
        for _ in 0 ... DroneLimits.maxConnectionsPerWorker {
            let storage = MemoryStorage()
            let identity = DroneIdentityStore(role: .controller, storage: storage)
            try storage.write(controllerKey.rawRepresentation, account: identity.account)
            let pairings = DronePairingStore(role: .controller, storage: storage)
            try pairings.approve(workerKey.publicKey, for: peerID, replacing: nil)
            let controller = DroneLANTransport(
                role: .controller,
                identityStore: identity,
                pairingStore: pairings
            )
            controller.onEvent = { _ in }
            controllers.append(controller)
            controller.connect(peerID: peerID, host: "127.0.0.1", port: try XCTUnwrap(port.get()))
        }
        wait(for: [connected, surplus], timeout: 15)
        for controller in controllers { controller.stop() }
        worker.stop()
    }

    func testLoopbackPairingReconnectAndRevocation() throws {
        let listening = expectation(description: "worker listening")
        let paired = expectation(description: "paired on both sides")
        paired.expectedFulfillmentCount = 2
        let delivered = expectation(description: "authenticated envelope")
        let initialDisconnect = expectation(description: "transport-only disconnect")
        let reconnected = expectation(description: "fresh reconnect")
        let revokedDisconnect = expectation(description: "revocation disconnect")
        let rejectedReconnect = expectation(description: "revoked reconnect rejected")
        let port = Locked<UInt16?>(nil)
        let workerPeer = Locked<DronePeerID?>(nil)
        let controllerConnection = Locked<DroneConnectionID?>(nil)
        let controllerRequest = Locked<DronePairingRequest?>(nil)
        let workerRequest = Locked<DronePairingRequest?>(nil)
        let workerConnections = Locked(0)
        let controllerConnections = Locked(0)
        let disconnects = Locked(0)
        let deliveredOnce = Locked(false)
        let rejectedOnce = Locked(false)
        let workerStorage = MemoryStorage()
        let controllerStorage = MemoryStorage()
        let worker = DroneLANTransport(
            role: .worker,
            identityStore: DroneIdentityStore(role: .worker, storage: workerStorage),
            pairingStore: DronePairingStore(role: .worker, storage: workerStorage)
        )
        let controller = DroneLANTransport(
            role: .controller,
            identityStore: DroneIdentityStore(role: .controller, storage: controllerStorage),
            pairingStore: DronePairingStore(role: .controller, storage: controllerStorage)
        )
        let peerID = DronePeerID()

        worker.onEvent = { event in
            switch event {
            case .listening(let boundPort):
                port.set(boundPort)
                listening.fulfill()
            case .pairingRequired(let request):
                workerRequest.set(request)
                worker.resolvePairing(requestID: request.id, approved: true)
            case .connected:
                workerConnections.update { count in
                    if count == 0 { paired.fulfill() }
                    count += 1
                }
            case .envelope(_, _, let envelope) where envelope.kind == .heartbeat:
                deliveredOnce.update { deliveredBefore in
                    if !deliveredBefore { delivered.fulfill() }
                    deliveredBefore = true
                }
            default:
                break
            }
        }
        worker.startListening()
        wait(for: [listening], timeout: 5)

        controller.onEvent = { event in
            switch event {
            case .pairingRequired(let request):
                controllerRequest.set(request)
                controller.resolvePairing(requestID: request.id, approved: true)
            case .connected(let id, _, _):
                controllerConnections.update { count in
                    if count == 0 {
                        paired.fulfill()
                    } else if count == 1 {
                        reconnected.fulfill()
                    }
                    count += 1
                }
                controllerConnection.set(id)
            case .disconnected:
                disconnects.update { count in
                    if count == 0 {
                        initialDisconnect.fulfill()
                    } else if count == 1 {
                        revokedDisconnect.fulfill()
                    }
                    count += 1
                }
            case .failed where workerPeer.get() != nil && controllerConnections.get() >= 2:
                rejectedOnce.update { rejectedBefore in
                    if !rejectedBefore { rejectedReconnect.fulfill() }
                    rejectedBefore = true
                }
            default:
                break
            }
        }
        controller.pair(peerID: peerID, host: "127.0.0.1", port: try XCTUnwrap(port.get()))
        wait(for: [paired], timeout: 10)
        XCTAssertEqual(
            controllerRequest.get()?.verificationCode,
            workerRequest.get()?.verificationCode
        )
        controller.send(DroneEnvelope(kind: .heartbeat), on: try XCTUnwrap(controllerConnection.get()))
        wait(for: [delivered], timeout: 5)

        workerPeer.set(try DronePairingStore(role: .worker, storage: workerStorage).pairedPeerIDs().first)
        controller.disconnect(try XCTUnwrap(controllerConnection.get()))
        wait(for: [initialDisconnect], timeout: 5)
        controller.connect(peerID: peerID, host: "127.0.0.1", port: try XCTUnwrap(port.get()))
        wait(for: [reconnected], timeout: 10)

        worker.revoke(try XCTUnwrap(workerPeer.get()))
        wait(for: [revokedDisconnect], timeout: 5)
        controller.connect(peerID: peerID, host: "127.0.0.1", port: try XCTUnwrap(port.get()))
        wait(for: [rejectedReconnect], timeout: 10)
        controller.stop()
        worker.stop()
    }
}
