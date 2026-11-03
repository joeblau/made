import CryptoKit
import Foundation
import XCTest

@testable import Copilot

final class DroneProtocolTests: XCTestCase {
    func testCreateAndOutputRoundtripWithTypedIdentifiers() throws {
        let request = makeCreate(idempotencyKey: "create-request-0001")
        XCTAssertEqual(try DroneProtocolCodec.decode(DroneProtocolCodec.encode(request)), request)

        let session = DroneSessionID()
        let output = DroneEnvelope(
            kind: .output,
            sessionID: session,
            body: .output(DroneOutputBody(
                sequence: 8,
                offset: 4_096,
                data: Data("bounded output".utf8),
                isFinal: false
            ))
        )
        XCTAssertEqual(try DroneProtocolCodec.decode(DroneProtocolCodec.encode(output)), output)
        XCTAssertNotEqual(DroneSessionID(rawValue: session.rawValue), DroneSessionID())
        XCTAssertEqual(DroneJobID(rawValue: session.rawValue).rawValue, session.rawValue)
    }

    func testMalformedUnknownVersionKindAndOversizeInputAreRejected() throws {
        let request = makeCreate(idempotencyKey: "create-request-0002")
        let unsupported = DroneEnvelope(
            version: 2,
            kind: request.kind,
            requestID: request.requestID,
            idempotencyKey: request.idempotencyKey,
            body: request.body
        )
        XCTAssertThrowsError(try DroneProtocolCodec.encode(unsupported)) {
            XCTAssertEqual($0 as? DroneProtocolError, .unsupportedVersion)
        }

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: DroneProtocolCodec.encode(request)) as? [String: Any]
        )
        object["kind"] = "futureExecution"
        XCTAssertThrowsError(try DroneProtocolCodec.decode(JSONSerialization.data(withJSONObject: object)))

        let oversized = DroneEnvelope(
            kind: .output,
            sessionID: DroneSessionID(),
            body: .output(DroneOutputBody(
                sequence: 0,
                offset: 0,
                data: Data(repeating: 1, count: DroneLimits.maxOutputChunkBytes + 1),
                isFinal: false
            ))
        )
        XCTAssertThrowsError(try DroneProtocolCodec.encode(oversized))
        XCTAssertThrowsError(try DroneProtocolCodec.decode(Data()))
    }

    func testLengthPrefixAndIncrementalDecoderFailBeforeLargeAllocation() throws {
        XCTAssertThrowsError(try DroneWire.payloadLength(Data([0, 0, 0, 0])))
        XCTAssertThrowsError(try DroneWire.payloadLength(Data([0xFF, 0xFF, 0xFF, 0xFF])))

        let record = Data("abc".utf8)
        let framed = try DroneWire.frame(record)
        var decoder = DroneWire.StreamDecoder()
        XCTAssertEqual(try decoder.append(framed.prefix(2)).get(), [])
        XCTAssertEqual(try decoder.append(framed.dropFirst(2)).get(), [record])

        let violation = decoder.append(Data([0x7F, 0xFF, 0xFF, 0xFF]))
        guard case .failure(.messageTooLarge) = violation else {
            return XCTFail("expected an over-budget prefix to poison the stream")
        }
        XCTAssertTrue(decoder.buffer.isEmpty)
    }

    func testEverySessionTransitionAndDisconnectRetainExecutionUntilClose() throws {
        var machine = DroneSessionStateMachine()
        XCTAssertEqual(machine.state, .detached)
        try machine.apply(.attach)
        XCTAssertEqual(machine.state, .attached)
        try machine.apply(.input)
        try machine.apply(.resize)
        try machine.apply(.cancel)
        XCTAssertEqual(machine.state, .attached)
        try machine.apply(.disconnect)
        XCTAssertEqual(machine.state, .detached)
        try machine.apply(.reconnect)
        try machine.apply(.detach)
        XCTAssertEqual(machine.state, .detached)
        try machine.apply(.cancel)
        try machine.apply(.close)
        try machine.apply(.close)
        XCTAssertEqual(machine.state, .closed)
        XCTAssertThrowsError(try machine.apply(.attach))
        XCTAssertThrowsError(try machine.apply(.input))
        XCTAssertThrowsError(try machine.apply(.cancel))
    }

    func testIdempotentCreateRetryAndConflictingReuse() throws {
        let request = makeCreate(idempotencyKey: "create-request-0003")
        let response = createdResponse(for: request)
        var ledger = DroneIdempotencyLedger(maximumEntries: 1)

        try ledger.store(request: request, response: response, now: 100)
        XCTAssertEqual(try ledger.response(for: request, now: 101), response)
        try ledger.store(request: request, response: response, now: 101)
        XCTAssertEqual(ledger.count, 1)

        let conflicting = makeCreate(idempotencyKey: "create-request-0003")
        XCTAssertThrowsError(try ledger.response(for: conflicting, now: 101)) {
            XCTAssertEqual($0 as? DroneProtocolError, .idempotencyConflict)
        }
        let second = makeCreate(idempotencyKey: "create-request-0004")
        XCTAssertThrowsError(
            try ledger.store(request: second, response: createdResponse(for: second), now: 102)
        ) { XCTAssertEqual($0 as? DroneProtocolError, .resourceLimit) }

        XCTAssertNil(try ledger.response(
            for: request,
            now: 100 + DroneLimits.idempotencyLifetime
        ))
        try ledger.store(request: second, response: createdResponse(for: second), now: 102)
        XCTAssertEqual(ledger.count, 1)
    }

    func testWorkspaceAndEnvironmentAuthorizationAreProtocolChecks() throws {
        let workspace = UUID()
        let create = DroneCreateBody(
            workspaceID: workspace,
            environment: ["TERM": "xterm-256color", "API_TOKEN": "must-not-cross"],
            columns: 80,
            rows: 24
        )
        XCTAssertThrowsError(try DroneAuthorization.authorize(
            create: create,
            registeredWorkspaces: [workspace]
        )) { XCTAssertEqual($0 as? DroneProtocolError, .unauthorized) }

        let allowed = DroneCreateBody(
            workspaceID: workspace,
            environment: ["TERM": "xterm-256color"],
            columns: 80,
            rows: 24
        )
        XCTAssertNoThrow(try DroneAuthorization.authorize(
            create: allowed,
            registeredWorkspaces: [workspace]
        ))
        XCTAssertThrowsError(try DroneAuthorization.authorize(
            create: allowed,
            registeredWorkspaces: []
        ))
    }

    func testAuthenticatedChannelsNegotiateAndRejectReplayAndPriorSessionRecords() throws {
        let workerKey = Curve25519.KeyAgreement.PrivateKey()
        let controllerKey = Curve25519.KeyAgreement.PrivateKey()
        let started = try DroneHandshake.start(
            localKey: controllerKey,
            pinnedWorkerKey: workerKey.publicKey
        )
        let accepted = try DroneHandshake.accept(
            localKey: workerKey,
            pinnedControllerKey: controllerKey.publicKey,
            message: started.message
        )
        let received = try started.pending.receive(accepted.response)
        var controller = received.channel
        var worker = accepted.channel
        XCTAssertEqual(received.peerHello.selectedVersion, DroneLimits.protocolVersion)
        XCTAssertEqual(received.peerHello.capabilities, ["terminal.v1"])

        let request = makeCreate(idempotencyKey: "create-request-0005")
        let record = try controller.seal(request)
        XCTAssertEqual(try worker.open(record), request)
        XCTAssertThrowsError(try worker.open(record)) {
            XCTAssertEqual($0 as? DroneProtocolError, .rejectedRecord)
        }

        let oldRecord = try controller.seal(request)
        let newStarted = try DroneHandshake.start(
            localKey: controllerKey,
            pinnedWorkerKey: workerKey.publicKey
        )
        let newAccepted = try DroneHandshake.accept(
            localKey: workerKey,
            pinnedControllerKey: controllerKey.publicKey,
            message: newStarted.message
        )
        var newWorker = newAccepted.channel
        XCTAssertThrowsError(try newWorker.open(oldRecord))
    }

    func testWrongControllerAndWrongWorkerPinsCannotAuthenticate() throws {
        let workerKey = Curve25519.KeyAgreement.PrivateKey()
        let controllerKey = Curve25519.KeyAgreement.PrivateKey()
        let rogueKey = Curve25519.KeyAgreement.PrivateKey()
        let rogueStart = try DroneHandshake.start(
            localKey: rogueKey,
            pinnedWorkerKey: workerKey.publicKey
        )
        XCTAssertThrowsError(try DroneHandshake.accept(
            localKey: workerKey,
            pinnedControllerKey: controllerKey.publicKey,
            message: rogueStart.message
        ))

        let wrongWorker = try DroneHandshake.start(
            localKey: controllerKey,
            pinnedWorkerKey: rogueKey.publicKey
        )
        XCTAssertThrowsError(try DroneHandshake.accept(
            localKey: workerKey,
            pinnedControllerKey: controllerKey.publicKey,
            message: wrongWorker.message
        ))
    }

    func testCapabilityAndHelloBoundsAreEnforced() throws {
        let workerKey = Curve25519.KeyAgreement.PrivateKey()
        let controllerKey = Curve25519.KeyAgreement.PrivateKey()
        let noCommonVersion = try DroneHandshake.start(
            localKey: controllerKey,
            pinnedWorkerKey: workerKey.publicKey,
            hello: DroneHello(supportedVersions: [2])
        )
        XCTAssertThrowsError(try DroneHandshake.accept(
            localKey: workerKey,
            pinnedControllerKey: controllerKey.publicKey,
            message: noCommonVersion.message
        )) { XCTAssertEqual($0 as? DroneProtocolError, .negotiationFailed) }

        let validStart = try DroneHandshake.start(
            localKey: controllerKey,
            pinnedWorkerKey: workerKey.publicKey
        )
        XCTAssertThrowsError(try DroneHello(supportedVersions: []).validate())
        XCTAssertThrowsError(try DroneHello(
            supportedVersions: [1],
            capabilities: Array(repeating: "terminal.v1", count: 2)
        ).validate())
        XCTAssertNoThrow(try DroneProtocolCodec.decodeHello(
            DroneProtocolCodec.encodeHello(DroneHello())
        ))
        XCTAssertNoThrow(try DroneHandshake.accept(
            localKey: workerKey,
            pinnedControllerKey: controllerKey.publicKey,
            message: validStart.message
        ))
    }

    private func makeCreate(idempotencyKey: String) -> DroneEnvelope {
        DroneEnvelope(
            kind: .create,
            requestID: UUID(),
            idempotencyKey: idempotencyKey,
            body: .create(DroneCreateBody(
                workspaceID: UUID(),
                environment: ["TERM": "xterm-256color"],
                columns: 80,
                rows: 24
            ))
        )
    }

    private func createdResponse(for request: DroneEnvelope) -> DroneEnvelope {
        DroneEnvelope(
            kind: .created,
            requestID: request.requestID,
            sessionID: DroneSessionID(),
            idempotencyKey: request.idempotencyKey
        )
    }
}
