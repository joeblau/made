import CryptoKit
import Foundation

struct ProofClient {
    let port: UInt16
    let controllerKey: Curve25519.KeyAgreement.PrivateKey
    let workerKey: Curve25519.KeyAgreement.PublicKey

    init(arguments: [String]) throws {
        guard arguments.count == 5,
              let port = UInt16(arguments[2]),
              let privateData = Data(
                  base64Encoded: ProcessInfo.processInfo.environment[
                      "DRONE_PROOF_CONTROLLER_PRIVATE"
                  ] ?? ""
              ),
              let controllerKey = try? Curve25519.KeyAgreement.PrivateKey(
                  rawRepresentation: privateData
              ),
              let workerData = Data(base64Encoded: arguments[4]),
              let workerKey = try? Curve25519.KeyAgreement.PublicKey(
                  rawRepresentation: workerData
              )
        else { throw ProofError.invalidClientArguments }
        self.port = port
        self.controllerKey = controllerKey
        self.workerKey = workerKey
    }

    func run() throws {
        try malformedConnectionIsClosed()
        try wrongControllerIdentityIsRejected()
        try wrongWorkerIdentityIsRejected()
        try requestAndStreamExchange()
        try replayAndIdempotentRetry()
        try ambiguousDisconnectAndIdempotentRetry()
        print("controller proof passed")
    }

    private func malformedConnectionIsClosed() throws {
        let socket = try ProofSocket.connect(port: port)
        try socket.write(Data([0x7F, 0xFF, 0xFF, 0xFF]))
        try expectDisconnect(socket)
    }

    private func wrongControllerIdentityIsRejected() throws {
        let socket = try ProofSocket.connect(port: port)
        let started = try DroneHandshake.start(
            localKey: Curve25519.KeyAgreement.PrivateKey(),
            pinnedWorkerKey: workerKey
        )
        try socket.writeFrame(started.message)
        try expectDisconnect(socket)
    }

    private func wrongWorkerIdentityIsRejected() throws {
        let socket = try ProofSocket.connect(port: port)
        let started = try DroneHandshake.start(
            localKey: controllerKey,
            pinnedWorkerKey: Curve25519.KeyAgreement.PrivateKey().publicKey
        )
        try socket.writeFrame(started.message)
        try expectDisconnect(socket)
    }

    private func requestAndStreamExchange() throws {
        let socket = try ProofSocket.connect(port: port)
        var channel = try handshake(on: socket)
        let create = makeCreate(key: "proof-create-alpha")
        try socket.writeFrame(channel.seal(create))
        let created = try receive(.created, on: socket, channel: &channel)
        let sessionID = try requireSession(created)

        try socket.writeFrame(channel.seal(request(
            kind: .attach,
            sessionID: sessionID,
            body: .attach(DroneAttachBody(afterSequence: 0, afterOffset: 0))
        )))
        _ = try receive(.attached, on: socket, channel: &channel)
        var output = Data()
        for expectedSequence in 0 ..< 3 {
            let envelope = try receive(.output, on: socket, channel: &channel)
            guard case .output(let chunk) = envelope.body,
                  chunk.sequence == UInt64(expectedSequence),
                  chunk.offset == output.count,
                  chunk.data.count <= DroneLimits.maxOutputChunkBytes
            else { throw ProofError.invalidOutputStream }
            output.append(chunk.data)
        }
        guard String(data: output, encoding: .utf8) == "onetwothree" else {
            throw ProofError.invalidOutputStream
        }

        try socket.writeFrame(channel.seal(request(
            kind: .input,
            sessionID: sessionID,
            body: .input(DroneInputBody(data: Data("input".utf8)))
        )))
        _ = try receive(.ack, on: socket, channel: &channel)
        try socket.writeFrame(channel.seal(request(
            kind: .resize,
            sessionID: sessionID,
            body: .resize(DroneResizeBody(columns: 120, rows: 40))
        )))
        _ = try receive(.ack, on: socket, channel: &channel)
        try socket.writeFrame(channel.seal(request(kind: .cancel, sessionID: sessionID)))
        _ = try receive(.cancelled, on: socket, channel: &channel)
        try socket.writeFrame(channel.seal(request(kind: .detach, sessionID: sessionID)))
        _ = try receive(.detached, on: socket, channel: &channel)
        try socket.writeFrame(channel.seal(request(kind: .close, sessionID: sessionID)))
        _ = try receive(.closed, on: socket, channel: &channel)
        socket.close()
    }

    private func replayAndIdempotentRetry() throws {
        let firstSocket = try ProofSocket.connect(port: port)
        var firstChannel = try handshake(on: firstSocket)
        let create = makeCreate(key: "proof-create-beta")
        let originalRecord = try firstChannel.seal(create)
        try firstSocket.writeFrame(originalRecord)
        let firstResponse = try receive(.created, on: firstSocket, channel: &firstChannel)
        try firstSocket.writeFrame(originalRecord)
        try expectDisconnect(firstSocket)

        let retrySocket = try ProofSocket.connect(port: port)
        var retryChannel = try handshake(on: retrySocket)
        try retrySocket.writeFrame(retryChannel.seal(create))
        let retryResponse = try receive(.created, on: retrySocket, channel: &retryChannel)
        guard retryResponse == firstResponse else { throw ProofError.idempotencyProofFailed }
        retrySocket.close()
    }

    private func ambiguousDisconnectAndIdempotentRetry() throws {
        let firstSocket = try ProofSocket.connect(port: port)
        var firstChannel = try handshake(on: firstSocket)
        let create = makeCreate(key: "proof-create-gamma")
        try firstSocket.writeFrame(firstChannel.seal(create))
        firstSocket.close()

        let retrySocket = try ProofSocket.connect(port: port)
        var retryChannel = try handshake(on: retrySocket)
        try retrySocket.writeFrame(retryChannel.seal(create))
        let created = try receive(.created, on: retrySocket, channel: &retryChannel)
        let sessionID = try requireSession(created)
        try retrySocket.writeFrame(retryChannel.seal(request(
            kind: .reconnect,
            sessionID: sessionID,
            body: .attach(DroneAttachBody(afterSequence: 0, afterOffset: 0))
        )))
        _ = try receive(.reconnected, on: retrySocket, channel: &retryChannel)
        let output = try receive(.output, on: retrySocket, channel: &retryChannel)
        guard case .output(let chunk) = output.body, chunk.data == Data("resumed".utf8) else {
            throw ProofError.invalidOutputStream
        }
        retrySocket.close()
    }

    private func handshake(on socket: ProofSocket) throws -> DroneSecureChannel {
        let started = try DroneHandshake.start(
            localKey: controllerKey,
            pinnedWorkerKey: workerKey
        )
        try socket.writeFrame(started.message)
        return try started.pending.receive(socket.readFrame()).channel
    }

    private func receive(
        _ expectedKind: DroneMessageKind,
        on socket: ProofSocket,
        channel: inout DroneSecureChannel
    ) throws -> DroneEnvelope {
        let envelope = try channel.open(socket.readFrame())
        guard envelope.kind == expectedKind else { throw ProofError.unexpectedMessage }
        return envelope
    }

    private func makeCreate(key: String) -> DroneEnvelope {
        DroneEnvelope(
            kind: .create,
            requestID: UUID(),
            idempotencyKey: key,
            body: .create(DroneCreateBody(
                workspaceID: ProofFixtures.workspaceID,
                environment: ["TERM": "xterm-256color"],
                columns: 80,
                rows: 24
            ))
        )
    }

    private func request(
        kind: DroneMessageKind,
        sessionID: DroneSessionID,
        body: DroneEnvelope.Body = .empty
    ) -> DroneEnvelope {
        DroneEnvelope(
            kind: kind,
            requestID: UUID(),
            sessionID: sessionID,
            body: body
        )
    }

    private func requireSession(_ envelope: DroneEnvelope) throws -> DroneSessionID {
        guard let sessionID = envelope.sessionID else { throw ProofError.unexpectedMessage }
        return sessionID
    }

    private func expectDisconnect(_ socket: ProofSocket) throws {
        do {
            _ = try socket.readFrame()
            throw ProofError.expectedDisconnect
        } catch let error as ProofSocketError {
            guard error == .disconnected else { throw error }
        }
    }
}
