import CryptoKit
import Foundation

struct DronePendingInitiator {
    private let state: NoiseIK.Initiator
    private let offeredHello: DroneHello

    fileprivate init(state: NoiseIK.Initiator, offeredHello: DroneHello) {
        self.state = state
        self.offeredHello = offeredHello
    }

    func receive(_ message: Data) throws -> (channel: DroneSecureChannel, peerHello: DroneHello) {
        guard !message.isEmpty, message.count <= DroneLimits.maxHandshakeBytes else {
            throw DroneProtocolError.malformedMessage
        }
        let opened = try state.receive(message)
        let hello = try DroneProtocolCodec.decodeHello(opened.payload)
        guard hello.selectedVersion == DroneLimits.protocolVersion,
              offeredHello.supportedVersions.contains(DroneLimits.protocolVersion)
        else { throw DroneProtocolError.negotiationFailed }
        return (
            DroneSecureChannel(
                sendKey: opened.keys.initiatorToResponderKey,
                sendNonce: opened.keys.initiatorToResponderBaseNonce,
                receiveKey: opened.keys.responderToInitiatorKey,
                receiveNonce: opened.keys.responderToInitiatorBaseNonce
            ),
            hello
        )
    }
}

enum DroneHandshake {
    static func start(
        localKey: Curve25519.KeyAgreement.PrivateKey,
        pinnedWorkerKey: Curve25519.KeyAgreement.PublicKey,
        hello: DroneHello = DroneHello()
    ) throws -> (pending: DronePendingInitiator, message: Data) {
        try hello.validate()
        guard hello.selectedVersion == nil else { throw DroneProtocolError.negotiationFailed }
        let started = try NoiseIK.Initiator.start(
            staticKey: localKey,
            responderStatic: pinnedWorkerKey,
            payload: DroneProtocolCodec.encodeHello(hello)
        )
        guard started.message.count <= DroneLimits.maxHandshakeBytes else {
            throw DroneProtocolError.messageTooLarge
        }
        return (
            DronePendingInitiator(state: started.state, offeredHello: hello),
            started.message
        )
    }

    static func accept(
        localKey: Curve25519.KeyAgreement.PrivateKey,
        pinnedControllerKey: Curve25519.KeyAgreement.PublicKey,
        message: Data,
        hello: DroneHello = DroneHello()
    ) throws -> (channel: DroneSecureChannel, response: Data, peerHello: DroneHello) {
        let accepted = try accept(
            localKey: localKey,
            pinnedControllerKeys: [pinnedControllerKey],
            message: message,
            hello: hello
        )
        return (accepted.channel, accepted.response, accepted.peerHello)
    }

    static func accept(
        localKey: Curve25519.KeyAgreement.PrivateKey,
        pinnedControllerKeys: [Curve25519.KeyAgreement.PublicKey],
        message: Data,
        hello: DroneHello = DroneHello()
    ) throws -> (
        channel: DroneSecureChannel,
        response: Data,
        peerHello: DroneHello,
        controllerKey: Curve25519.KeyAgreement.PublicKey
    ) {
        guard !message.isEmpty, message.count <= DroneLimits.maxHandshakeBytes else {
            throw DroneProtocolError.malformedMessage
        }
        var attemptedKeys = Set<Data>()
        for pinnedControllerKey in pinnedControllerKeys
        where attemptedKeys.insert(pinnedControllerKey.rawRepresentation).inserted {
            let responder: NoiseIK.Responder
            do {
                responder = try NoiseIK.Responder.receive(
                    staticKey: localKey,
                    message: message,
                    expectedInitiator: pinnedControllerKey
                )
            } catch NoiseIK.HandshakeError.unauthorizedPeer {
                continue
            }
            let peerHello = try DroneProtocolCodec.decodeHello(responder.initiatorPayload)
            let responseHello = try peerHello.response()
            let commonCapabilities = Set(hello.capabilities).intersection(responseHello.capabilities)
            let negotiatedHello = DroneHello(
                supportedVersions: responseHello.supportedVersions,
                capabilities: commonCapabilities.sorted(),
                selectedVersion: responseHello.selectedVersion
            )
            let responded = try responder.respond(
                payload: DroneProtocolCodec.encodeHello(negotiatedHello)
            )
            guard responded.message.count <= DroneLimits.maxHandshakeBytes else {
                throw DroneProtocolError.messageTooLarge
            }
            return (
                DroneSecureChannel(
                    sendKey: responded.keys.responderToInitiatorKey,
                    sendNonce: responded.keys.responderToInitiatorBaseNonce,
                    receiveKey: responded.keys.initiatorToResponderKey,
                    receiveNonce: responded.keys.initiatorToResponderBaseNonce
                ),
                responded.message,
                peerHello,
                pinnedControllerKey
            )
        }
        throw NoiseIK.HandshakeError.unauthorizedPeer
    }
}

struct DroneSecureChannel {
    private let sendKey: SymmetricKey
    private let sendNonce: Data
    private let receiveKey: SymmetricKey
    private let receiveNonce: Data
    private var outboundCounter: UInt64 = 0
    private var replay = ReplayWindow(size: 4_096)

    fileprivate init(
        sendKey: SymmetricKey,
        sendNonce: Data,
        receiveKey: SymmetricKey,
        receiveNonce: Data
    ) {
        self.sendKey = sendKey
        self.sendNonce = sendNonce
        self.receiveKey = receiveKey
        self.receiveNonce = receiveNonce
    }

    mutating func seal(_ envelope: DroneEnvelope) throws -> Data {
        guard outboundCounter != UInt64.max else { throw DroneProtocolError.rejectedRecord }
        let plaintext = try DroneProtocolCodec.encode(envelope)
        let packet = try PacketCodec.seal(
            type: .reliableControl,
            counter: outboundCounter,
            plaintext: plaintext,
            key: sendKey,
            baseNonce: sendNonce
        )
        guard packet.count <= DroneLimits.maxFrameBytes else {
            throw DroneProtocolError.messageTooLarge
        }
        outboundCounter += 1
        return packet
    }

    mutating func open(_ packet: Data) throws -> DroneEnvelope {
        guard packet.count <= DroneLimits.maxFrameBytes else {
            throw DroneProtocolError.messageTooLarge
        }
        let opened = try PacketCodec.open(packet, key: receiveKey, baseNonce: receiveNonce)
        guard opened.type == .reliableControl, replay.accept(opened.counter) else {
            throw DroneProtocolError.rejectedRecord
        }
        return try DroneProtocolCodec.decode(opened.plaintext)
    }
}
