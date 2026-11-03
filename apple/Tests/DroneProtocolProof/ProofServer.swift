import CryptoKit
import Foundation

struct ProofServer {
    private let workerKey: Curve25519.KeyAgreement.PrivateKey
    private let controllerKey: Curve25519.KeyAgreement.PrivateKey
    private var ledger = DroneIdempotencyLedger()
    private var sessions: [DroneSessionID: DroneSessionStateMachine] = [:]
    private var executedCreateKeys: Set<String> = []
    private var duplicateCreateResponses = 0

    init() {
        workerKey = Curve25519.KeyAgreement.PrivateKey()
        controllerKey = Curve25519.KeyAgreement.PrivateKey()
    }

    mutating func run() throws {
        try ProofPairing.run()
        let listener = try ProofSocket.listener()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = [
            "client",
            String(listener.port),
            controllerKey.publicKey.rawRepresentation.base64EncodedString(),
            workerKey.publicKey.rawRepresentation.base64EncodedString(),
        ]
        process.environment = [
            "DRONE_PROOF_CONTROLLER_PRIVATE":
                controllerKey.rawRepresentation.base64EncodedString(),
        ]
        try process.run()

        do {
            for connectionIndex in 0 ..< 8 {
                let socket = try listener.socket.accept()
                do {
                    if connectionIndex == 0 {
                        _ = try socket.readFrame()
                        throw ProofError.expectedMalformedConnection
                    }
                    var channel = try acceptHandshake(on: socket)
                    try serve(&channel, on: socket)
                    socket.close()
                } catch {
                    socket.close()
                    try validate(error: error, connectionIndex: connectionIndex)
                }
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw ProofError.clientFailed(process.terminationStatus)
            }
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }

        guard executedCreateKeys == [
            "proof-create-alpha",
            "proof-create-beta",
            "proof-create-gamma",
        ], duplicateCreateResponses == 2 else {
            throw ProofError.idempotencyProofFailed
        }
        print("worker proof passed: three unique creates, two duplicate responses")
    }

    private func acceptHandshake(on socket: ProofSocket) throws -> DroneSecureChannel {
        let accepted = try DroneHandshake.accept(
            localKey: workerKey,
            pinnedControllerKey: controllerKey.publicKey,
            message: socket.readFrame()
        )
        try socket.writeFrame(accepted.response)
        return accepted.channel
    }

    private mutating func serve(
        _ channel: inout DroneSecureChannel,
        on socket: ProofSocket
    ) throws {
        while true {
            let envelope = try channel.open(socket.readFrame())
            let responses = try handle(envelope)
            for response in responses {
                try socket.writeFrame(channel.seal(response))
            }
            if envelope.kind == .close { return }
        }
    }

    private mutating func handle(_ envelope: DroneEnvelope) throws -> [DroneEnvelope] {
        switch envelope.kind {
        case .create:
            if let cached = try ledger.response(
                for: envelope,
                now: Date().timeIntervalSinceReferenceDate
            ) {
                duplicateCreateResponses += 1
                return [cached]
            }
            guard case .create(let create) = envelope.body,
                  let key = envelope.idempotencyKey
            else { throw DroneProtocolError.malformedMessage }
            try DroneAuthorization.authorize(
                create: create,
                registeredWorkspaces: [ProofFixtures.workspaceID]
            )
            let sessionID = DroneSessionID()
            sessions[sessionID] = DroneSessionStateMachine()
            let response = DroneEnvelope(
                kind: .created,
                requestID: envelope.requestID,
                sessionID: sessionID,
                idempotencyKey: envelope.idempotencyKey
            )
            try ledger.store(
                request: envelope,
                response: response,
                now: Date().timeIntervalSinceReferenceDate
            )
            executedCreateKeys.insert(key)
            return [response]
        case .attach:
            let sessionID = try requireSession(envelope)
            try apply(.attach, to: sessionID)
            return [
                DroneEnvelope(
                    kind: .attached,
                    requestID: envelope.requestID,
                    sessionID: sessionID
                ),
                output(sessionID: sessionID, sequence: 0, offset: 0, text: "one"),
                output(sessionID: sessionID, sequence: 1, offset: 3, text: "two"),
                output(sessionID: sessionID, sequence: 2, offset: 6, text: "three"),
            ]
        case .input, .resize:
            let sessionID = try requireSession(envelope)
            try apply(envelope.kind == .input ? .input : .resize, to: sessionID)
            return [DroneEnvelope(
                kind: .ack,
                requestID: envelope.requestID,
                sessionID: sessionID
            )]
        case .cancel:
            let sessionID = try requireSession(envelope)
            try apply(.cancel, to: sessionID)
            return [DroneEnvelope(
                kind: .cancelled,
                requestID: envelope.requestID,
                sessionID: sessionID
            )]
        case .detach:
            let sessionID = try requireSession(envelope)
            try apply(.detach, to: sessionID)
            return [DroneEnvelope(
                kind: .detached,
                requestID: envelope.requestID,
                sessionID: sessionID
            )]
        case .close:
            let sessionID = try requireSession(envelope)
            try apply(.close, to: sessionID)
            return [DroneEnvelope(
                kind: .closed,
                requestID: envelope.requestID,
                sessionID: sessionID
            )]
        case .reconnect:
            let sessionID = try requireSession(envelope)
            try apply(.reconnect, to: sessionID)
            return [
                DroneEnvelope(
                    kind: .reconnected,
                    requestID: envelope.requestID,
                    sessionID: sessionID
                ),
                output(sessionID: sessionID, sequence: 3, offset: 11, text: "resumed"),
            ]
        default:
            throw DroneProtocolError.malformedMessage
        }
    }

    private func requireSession(_ envelope: DroneEnvelope) throws -> DroneSessionID {
        guard let sessionID = envelope.sessionID, sessions[sessionID] != nil else {
            throw DroneProtocolError.invalidIdentifier
        }
        return sessionID
    }

    private mutating func apply(
        _ event: DroneSessionStateMachine.Event,
        to sessionID: DroneSessionID
    ) throws {
        guard var machine = sessions[sessionID] else { throw DroneProtocolError.invalidIdentifier }
        try machine.apply(event)
        sessions[sessionID] = machine
    }

    private func output(
        sessionID: DroneSessionID,
        sequence: UInt64,
        offset: UInt64,
        text: String
    ) -> DroneEnvelope {
        DroneEnvelope(
            kind: .output,
            sessionID: sessionID,
            body: .output(DroneOutputBody(
                sequence: sequence,
                offset: offset,
                data: Data(text.utf8),
                isFinal: false
            ))
        )
    }

    private func validate(error: Error, connectionIndex: Int) throws {
        switch connectionIndex {
        case 0:
            guard let error = error as? DroneProtocolError, error == .messageTooLarge else {
                throw error
            }
        case 1:
            guard let error = error as? NoiseIK.HandshakeError,
                  error == .unauthorizedPeer
            else { throw error }
        case 2:
            guard let error = error as? NoiseIK.HandshakeError, error == .decryptFailed else {
                throw error
            }
        case 5, 6, 7:
            guard let error = error as? ProofSocketError, error == .disconnected else {
                throw error
            }
        case 4:
            guard let error = error as? DroneProtocolError, error == .rejectedRecord else {
                throw error
            }
        default:
            throw error
        }
    }
}
