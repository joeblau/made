import CryptoKit
import Foundation

struct PeerSyncPairingRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let displayName: String
    let fingerprint: String
    let isKeyChange: Bool
}

/// Holds sync frames that MultipeerConnectivity delivered before the sender's
/// `.connected` state callback was handled. Data and state callbacks arrive
/// independently, and each side sends its hello exactly once, so dropping an
/// early hello stalls the handshake on both devices (#430). Frames are bounded
/// before they are retained, one per peer for a few peers, and are replayed
/// only through `PeerSyncAuthenticator.open`, which still verifies each one.
struct PeerSyncEarlyFrameBuffer<Peer: Hashable> {
    /// A sealed hello is a few hundred bytes of JSON; nothing larger is a hello.
    static var maxFrameBytes: Int { 4_096 }
    static var maxPeers: Int { 4 }

    private var frames: [Peer: Data] = [:]

    var count: Int { frames.count }

    /// Retains `data` as the newest pre-connection frame from `peer`. Returns
    /// false, retaining nothing, when the frame or the peer count is out of bounds.
    @discardableResult
    mutating func hold(_ data: Data, from peer: Peer) -> Bool {
        guard !data.isEmpty,
              data.count <= Self.maxFrameBytes,
              frames[peer] != nil || frames.count < Self.maxPeers else { return false }
        frames[peer] = data
        return true
    }

    /// Hands back the held frame for `peer` at most once.
    mutating func take(for peer: Peer) -> Data? {
        frames.removeValue(forKey: peer)
    }

    mutating func discard(_ peer: Peer) {
        frames.removeValue(forKey: peer)
    }

    mutating func removeAll() {
        frames.removeAll()
    }
}

/// Pure authentication state machine for the Multipeer control channel.
/// Multipeer still provides transport encryption; this layer binds every
/// command to the explicitly pinned X25519 device identity and a fresh,
/// mutually-authenticated session nonce.
struct PeerSyncAuthenticator {
    enum WireKind: UInt8, Codable {
        case hello = 1
        case ready = 2
        case message = 3
    }

    enum Opened: Equatable {
        case helloResponse(Data)
        case authenticated
        case message(Data)
    }

    private struct Envelope: Codable {
        let version: UInt8
        let senderPublicKey: Data
        let sequence: UInt64
        let kind: WireKind
        let sessionID: Data
        let payload: Data
        let tag: Data
    }

    static let maxMessageBytes = 2 * 1_024 * 1_024
    private static let version: UInt8 = 1
    private static let nonceBytes = 32
    private static let tagBytes = 32

    private let localKey: Curve25519.KeyAgreement.PrivateKey
    private var peerKey: Curve25519.KeyAgreement.PublicKey?
    private var authenticationKey: SymmetricKey?
    private var localNonce: Data?
    private var peerNonce: Data?
    private var sessionID: Data?
    private var outboundSequence: UInt64 = 0
    private var replay = ReplayWindow(size: 4_096)
    private(set) var isAuthenticated = false

    var localPublicKeyBase64: String {
        localKey.publicKey.rawRepresentation.base64EncodedString()
    }

    var peerPublicKeyBase64: String? {
        peerKey?.rawRepresentation.base64EncodedString()
    }

    init(
        localKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKeyBase64: String? = nil
    ) {
        self.localKey = localKey
        if let peerPublicKeyBase64,
           let peer = DeviceIdentity.parsePeerPublicKey(peerPublicKeyBase64) {
            peerKey = peer
            authenticationKey = Self.deriveKey(local: localKey, peer: peer)
        }
    }

    /// The same pinned peer, authenticated under a rotated local identity.
    /// No session state carries over: a handshake proven with the old key can
    /// never authorize traffic sealed by the new one (issue #429).
    func replacingLocalKey(_ key: Curve25519.KeyAgreement.PrivateKey) -> PeerSyncAuthenticator {
        PeerSyncAuthenticator(localKey: key, peerPublicKeyBase64: peerPublicKeyBase64)
    }

    mutating func trust(peerPublicKeyBase64: String) -> Bool {
        guard let peer = DeviceIdentity.parsePeerPublicKey(peerPublicKeyBase64),
              peer.rawRepresentation != localKey.publicKey.rawRepresentation else { return false }
        peerKey = peer
        authenticationKey = Self.deriveKey(local: localKey, peer: peer)
        resetSession()
        return true
    }

    mutating func revokePeer() {
        peerKey = nil
        authenticationKey = nil
        resetSession()
    }

    mutating func beginSession(random: (Int) -> Data = Self.randomBytes) -> Data? {
        guard authenticationKey != nil else { return nil }
        resetSession()
        let nonce = random(Self.nonceBytes)
        guard nonce.count == Self.nonceBytes else { return nil }
        localNonce = nonce
        return seal(kind: .hello, sessionID: Data(), payload: nonce, sequence: 0)
    }

    mutating func sealMessage(_ payload: Data) -> Data? {
        guard isAuthenticated, let sessionID,
              payload.count <= Self.maxMessageBytes else { return nil }
        let sequence = outboundSequence
        outboundSequence &+= 1
        return seal(kind: .message, sessionID: sessionID, payload: payload, sequence: sequence)
    }

    mutating func open(_ data: Data) -> Opened? {
        guard data.count <= Self.maxMessageBytes + 1_024,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == Self.version,
              envelope.senderPublicKey == peerKey?.rawRepresentation,
              envelope.tag.count == Self.tagBytes,
              let authenticationKey,
              HMAC<SHA256>.isValidAuthenticationCode(
                  envelope.tag,
                  authenticating: authenticatedBytes(for: envelope),
                  using: authenticationKey
              ) else { return nil }

        switch envelope.kind {
        case .hello:
            guard envelope.sequence == 0,
                  envelope.sessionID.isEmpty,
                  envelope.payload.count == Self.nonceBytes,
                  peerNonce == nil,
                  let localNonce else { return nil }
            peerNonce = envelope.payload
            let session = Self.makeSessionID(
                localPublicKey: localKey.publicKey.rawRepresentation,
                localNonce: localNonce,
                peerPublicKey: envelope.senderPublicKey,
                peerNonce: envelope.payload
            )
            sessionID = session
            replay = ReplayWindow(size: 4_096)
            outboundSequence = 1
            guard let response = seal(
                kind: .ready,
                sessionID: session,
                payload: Data("blau-sync-ready-v1".utf8),
                sequence: 0
            ) else { return nil }
            return .helloResponse(response)

        case .ready:
            guard envelope.sequence == 0,
                  envelope.sessionID == sessionID,
                  envelope.payload == Data("blau-sync-ready-v1".utf8),
                  !isAuthenticated else { return nil }
            isAuthenticated = true
            return .authenticated

        case .message:
            guard isAuthenticated,
                  envelope.sessionID == sessionID,
                  envelope.payload.count <= Self.maxMessageBytes,
                  replay.accept(envelope.sequence) else { return nil }
            return .message(envelope.payload)
        }
    }

    mutating func resetSession() {
        localNonce = nil
        peerNonce = nil
        sessionID = nil
        outboundSequence = 0
        replay = ReplayWindow(size: 4_096)
        isAuthenticated = false
    }

    static func fingerprint(of publicKeyBase64: String) -> String? {
        guard let key = DeviceIdentity.parsePeerPublicKey(publicKeyBase64) else { return nil }
        let digest = SHA256.hash(data: key.rawRepresentation)
        return digest.prefix(8).map { String(format: "%02X", $0) }
            .joined(separator: ":")
    }

    /// Symmetric short code shown on both devices during first pairing. Unlike
    /// a one-sided fingerprint, this produces the same value regardless of
    /// which peer computes it, so users can compare the two alerts directly.
    static func pairingCode(local: String, peer: String) -> String? {
        guard let localKey = DeviceIdentity.parsePeerPublicKey(local),
              let peerKey = DeviceIdentity.parsePeerPublicKey(peer) else { return nil }
        let keys = [localKey.rawRepresentation, peerKey.rawRepresentation].sorted {
            $0.lexicographicallyPrecedes($1)
        }
        var input = Data("blau-pairing-code-v1".utf8)
        input.append(keys[0])
        input.append(keys[1])
        let digest = SHA256.hash(data: input)
        return digest.prefix(8).map { String(format: "%02X", $0) }
            .joined(separator: ":")
    }

    private func seal(
        kind: WireKind,
        sessionID: Data,
        payload: Data,
        sequence: UInt64
    ) -> Data? {
        guard let authenticationKey else { return nil }
        let unsigned = Envelope(
            version: Self.version,
            senderPublicKey: localKey.publicKey.rawRepresentation,
            sequence: sequence,
            kind: kind,
            sessionID: sessionID,
            payload: payload,
            tag: Data()
        )
        let tag = Data(HMAC<SHA256>.authenticationCode(
            for: authenticatedBytes(for: unsigned),
            using: authenticationKey
        ))
        let envelope = Envelope(
            version: unsigned.version,
            senderPublicKey: unsigned.senderPublicKey,
            sequence: unsigned.sequence,
            kind: unsigned.kind,
            sessionID: unsigned.sessionID,
            payload: unsigned.payload,
            tag: tag
        )
        return try? JSONEncoder().encode(envelope)
    }

    private func authenticatedBytes(for envelope: Envelope) -> Data {
        var bytes = Data("blau-peer-sync-envelope-v1".utf8)
        bytes.append(envelope.version)
        bytes.append(envelope.senderPublicKey)
        var sequence = envelope.sequence.bigEndian
        bytes.append(Data(bytes: &sequence, count: 8))
        bytes.append(envelope.kind.rawValue)
        appendLength(envelope.sessionID.count, to: &bytes)
        bytes.append(envelope.sessionID)
        appendLength(envelope.payload.count, to: &bytes)
        bytes.append(envelope.payload)
        return bytes
    }

    private func appendLength(_ count: Int, to data: inout Data) {
        var value = UInt64(count).bigEndian
        data.append(Data(bytes: &value, count: 8))
    }

    private static func deriveKey(
        local: Curve25519.KeyAgreement.PrivateKey,
        peer: Curve25519.KeyAgreement.PublicKey
    ) -> SymmetricKey? {
        guard let secret = try? local.sharedSecretFromKeyAgreement(with: peer) else { return nil }
        let keys = [local.publicKey.rawRepresentation, peer.rawRepresentation].sorted {
            $0.lexicographicallyPrecedes($1)
        }
        var info = Data("blau-peer-sync-auth-v1".utf8)
        info.append(keys[0])
        info.append(keys[1])
        return secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("blau-peer-sync-salt-v1".utf8),
            sharedInfo: info,
            outputByteCount: 32
        )
    }

    private static func makeSessionID(
        localPublicKey: Data,
        localNonce: Data,
        peerPublicKey: Data,
        peerNonce: Data
    ) -> Data {
        let pairs = [(localPublicKey, localNonce), (peerPublicKey, peerNonce)].sorted {
            $0.0.lexicographicallyPrecedes($1.0)
        }
        var input = Data("blau-peer-sync-session-v1".utf8)
        input.append(pairs[0].0)
        input.append(pairs[0].1)
        input.append(pairs[1].0)
        input.append(pairs[1].1)
        return Data(SHA256.hash(data: input))
    }

    private static func randomBytes(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0 ..< count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
