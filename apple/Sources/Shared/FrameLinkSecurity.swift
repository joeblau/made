import CryptoKit
import Foundation

struct FrameLinkPairingRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let displayName: String
    let fingerprint: String
    let publicKey: String
    let isKeyChange: Bool
}

struct FrameLinkPairingStore {
    static let peerAccount = "app.blau.framelink.peer"

    private let storage: any PairingSecretStoring

    init(storage: any PairingSecretStoring = KeychainPairingSecretStorage()) {
        self.storage = storage
    }

    func loadPeerPublicKey() -> String? {
        guard let data = try? storage.read(account: Self.peerAccount),
              let value = String(data: data, encoding: .utf8),
              DeviceIdentity.parsePeerPublicKey(value) != nil else { return nil }
        return value
    }

    func setPeerPublicKey(_ value: String) throws {
        guard DeviceIdentity.parsePeerPublicKey(value) != nil,
              let data = value.data(using: .utf8) else {
            throw SecurePairingStore.StoreError.invalidEncoding
        }
        try storage.write(data, account: Self.peerAccount)
    }

    func revoke() throws {
        try storage.delete(account: Self.peerAccount)
    }
}

/// Authenticated-encryption state machine for FrameLink. Discovery metadata is
/// intentionally empty: identities are exchanged only after a direct TCP
/// connection, explicitly approved on first use, then proven with an X25519-
/// derived HMAC before any screen or annotation data is released.
struct FrameLinkSecureSession {
    enum Opened: Equatable {
        case send(Data)
        case pairingRequired(FrameLinkPairingRequest)
        case waiting
        case authenticated
        case plaintext(Data)
    }

    private enum RecordType: UInt8 {
        case hello = 0xF0
        case proof = 0xF1
        case encrypted = 0xF2
    }

    static let helloBytes = 1 + 32 + 32
    static let proofBytes = 1 + 32
    static let encryptedOverhead = 1 + 8 + 16

    private let localKey: Curve25519.KeyAgreement.PrivateKey
    private var peerKey: Curve25519.KeyAgreement.PublicKey?
    private var localNonce: Data?
    private var peerNonce: Data?
    private var transcriptHash: Data?
    private var authenticationKey: SymmetricKey?
    private var sendKey: SymmetricKey?
    private var receiveKey: SymmetricKey?
    private var outboundSequence: UInt64 = 0
    private var replay = ReplayWindow(size: 4_096)
    private var pendingHello: (key: String, nonce: Data, displayName: String)?
    private var pendingProof: Data?
    private(set) var isAuthenticated = false

    var trustedPeerPublicKey: String? {
        peerKey?.rawRepresentation.base64EncodedString()
    }

    /// The identity key this session's hello and proof records carry.
    var localPublicKeyBase64: String {
        localKey.publicKey.rawRepresentation.base64EncodedString()
    }

    init(
        localKey: Curve25519.KeyAgreement.PrivateKey,
        trustedPeerPublicKey: String? = nil
    ) {
        self.localKey = localKey
        if let trustedPeerPublicKey {
            peerKey = DeviceIdentity.parsePeerPublicKey(trustedPeerPublicKey)
        }
    }

    mutating func begin(random: (Int) -> Data = Self.randomBytes) -> Data? {
        resetSession()
        let nonce = random(32)
        guard nonce.count == 32 else { return nil }
        localNonce = nonce
        var hello = Data([RecordType.hello.rawValue])
        hello.append(localKey.publicKey.rawRepresentation)
        hello.append(nonce)
        return hello
    }

    mutating func receive(_ record: Data, displayName: String = "Peer") -> Opened? {
        guard let first = record.first,
              let type = RecordType(rawValue: first) else { return nil }
        switch type {
        case .hello:
            guard record.count == Self.helloBytes,
                  localNonce != nil else { return nil }
            let keyData = Data(record[record.startIndex + 1 ..< record.startIndex + 33])
            let nonce = Data(record[record.startIndex + 33 ..< record.endIndex])
            guard let candidate = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyData),
                  candidate.rawRepresentation != localKey.publicKey.rawRepresentation else { return nil }
            let base64 = keyData.base64EncodedString()
            guard candidate.rawRepresentation == peerKey?.rawRepresentation else {
                pendingHello = (base64, nonce, displayName)
                guard let fingerprint = PeerSyncAuthenticator.pairingCode(
                    local: localKey.publicKey.rawRepresentation.base64EncodedString(),
                    peer: base64
                ) else { return nil }
                return .pairingRequired(FrameLinkPairingRequest(
                    id: UUID(),
                    displayName: displayName,
                    fingerprint: fingerprint,
                    publicKey: base64,
                    isKeyChange: peerKey != nil
                ))
            }
            guard let proof = acceptHello(peerKey: candidate, peerNonce: nonce) else { return nil }
            return .send(proof)

        case .proof:
            guard record.count == Self.proofBytes, !isAuthenticated else { return nil }
            guard let authenticationKey,
                  let transcriptHash,
                  let peerKey else {
                guard pendingHello != nil, pendingProof == nil else { return nil }
                pendingProof = record
                return .waiting
            }
            let supplied = Data(record.dropFirst())
            let expected = proof(
                key: authenticationKey,
                transcriptHash: transcriptHash,
                senderPublicKey: peerKey.rawRepresentation
            )
            guard HMAC<SHA256>.isValidAuthenticationCode(
                supplied,
                authenticating: proofInput(
                    transcriptHash: transcriptHash,
                    senderPublicKey: peerKey.rawRepresentation
                ),
                using: authenticationKey
            ), supplied == expected else { return nil }
            isAuthenticated = true
            return .authenticated

        case .encrypted:
            guard isAuthenticated,
                  record.count >= Self.encryptedOverhead,
                  record.count <= FrameLink.maxTCPPayloadBytes + Self.encryptedOverhead,
                  let receiveKey,
                  let transcriptHash,
                  let peerKey else { return nil }
            let sequence = readUInt64(record, offset: 1)
            let cipherStart = 9
            let tagStart = record.count - 16
            guard tagStart >= cipherStart,
                  let nonce = nonce(sequence: sequence, senderPublicKey: peerKey.rawRepresentation),
                  let box = try? ChaChaPoly.SealedBox(
                      nonce: nonce,
                      ciphertext: Data(record[cipherStart ..< tagStart]),
                      tag: Data(record[tagStart ..< record.count])
                  ),
                  let plaintext = try? ChaChaPoly.open(
                      box,
                      using: receiveKey,
                      authenticating: associatedData(
                          transcriptHash: transcriptHash,
                          sequence: sequence,
                          senderPublicKey: peerKey.rawRepresentation
                      )
                  ),
                  replay.accept(sequence) else { return nil }
            return .plaintext(plaintext)
        }
    }

    mutating func approvePending(publicKey: String) -> (proof: Data, authenticated: Bool)? {
        guard let pendingHello,
              pendingHello.key == publicKey,
              let key = DeviceIdentity.parsePeerPublicKey(publicKey) else { return nil }
        peerKey = key
        self.pendingHello = nil
        guard let proof = acceptHello(peerKey: key, peerNonce: pendingHello.nonce) else { return nil }
        if let pendingProof {
            self.pendingProof = nil
            guard receive(pendingProof) == .authenticated else { return nil }
        }
        return (proof, isAuthenticated)
    }

    mutating func rejectPending() {
        pendingHello = nil
        pendingProof = nil
    }

    mutating func seal(_ plaintext: Data) -> Data? {
        guard isAuthenticated,
              plaintext.count <= FrameLink.maxTCPPayloadBytes,
              outboundSequence != UInt64.max,
              let sendKey,
              let transcriptHash else { return nil }
        let sequence = outboundSequence
        outboundSequence += 1
        let sender = localKey.publicKey.rawRepresentation
        guard let nonce = nonce(sequence: sequence, senderPublicKey: sender),
              let box = try? ChaChaPoly.seal(
                  plaintext,
                  using: sendKey,
                  nonce: nonce,
                  authenticating: associatedData(
                      transcriptHash: transcriptHash,
                      sequence: sequence,
                      senderPublicKey: sender
                  )
              ) else { return nil }
        var record = Data([RecordType.encrypted.rawValue])
        var encodedSequence = sequence.bigEndian
        record.append(Data(bytes: &encodedSequence, count: 8))
        record.append(box.ciphertext)
        record.append(box.tag)
        return record
    }

    mutating func revokePeer() {
        peerKey = nil
        resetSession()
    }

    mutating func resetSession() {
        localNonce = nil
        peerNonce = nil
        transcriptHash = nil
        authenticationKey = nil
        sendKey = nil
        receiveKey = nil
        outboundSequence = 0
        replay = ReplayWindow(size: 4_096)
        pendingHello = nil
        isAuthenticated = false
    }

    private mutating func acceptHello(
        peerKey: Curve25519.KeyAgreement.PublicKey,
        peerNonce: Data
    ) -> Data? {
        guard let localNonce,
              let shared = try? localKey.sharedSecretFromKeyAgreement(with: peerKey) else { return nil }
        self.peerNonce = peerNonce
        let transcript = Self.transcriptHash(
            localKey: localKey.publicKey.rawRepresentation,
            localNonce: localNonce,
            peerKey: peerKey.rawRepresentation,
            peerNonce: peerNonce
        )
        transcriptHash = transcript
        let authKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcript,
            sharedInfo: Data("blau-framelink-auth-v1".utf8),
            outputByteCount: 32
        )
        authenticationKey = authKey
        sendKey = directionalKey(
            base: authKey,
            transcriptHash: transcript,
            senderPublicKey: localKey.publicKey.rawRepresentation
        )
        receiveKey = directionalKey(
            base: authKey,
            transcriptHash: transcript,
            senderPublicKey: peerKey.rawRepresentation
        )
        replay = ReplayWindow(size: 4_096)
        outboundSequence = 0

        var record = Data([RecordType.proof.rawValue])
        record.append(proof(
            key: authKey,
            transcriptHash: transcript,
            senderPublicKey: localKey.publicKey.rawRepresentation
        ))
        return record
    }

    private func proof(
        key: SymmetricKey,
        transcriptHash: Data,
        senderPublicKey: Data
    ) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: proofInput(
                transcriptHash: transcriptHash,
                senderPublicKey: senderPublicKey
            ),
            using: key
        ))
    }

    private func proofInput(transcriptHash: Data, senderPublicKey: Data) -> Data {
        var input = Data("blau-framelink-proof-v1".utf8)
        input.append(transcriptHash)
        input.append(senderPublicKey)
        return input
    }

    private func directionalKey(
        base: SymmetricKey,
        transcriptHash: Data,
        senderPublicKey: Data
    ) -> SymmetricKey {
        var info = Data("blau-framelink-direction-v1".utf8)
        info.append(senderPublicKey)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: base,
            salt: transcriptHash,
            info: info,
            outputByteCount: 32
        )
    }

    private func nonce(sequence: UInt64, senderPublicKey: Data) -> ChaChaPoly.Nonce? {
        var data = Data(SHA256.hash(data: senderPublicKey).prefix(4))
        var value = sequence.bigEndian
        data.append(Data(bytes: &value, count: 8))
        return try? ChaChaPoly.Nonce(data: data)
    }

    private func associatedData(
        transcriptHash: Data,
        sequence: UInt64,
        senderPublicKey: Data
    ) -> Data {
        var data = Data("blau-framelink-record-v1".utf8)
        data.append(transcriptHash)
        data.append(senderPublicKey)
        var value = sequence.bigEndian
        data.append(Data(bytes: &value, count: 8))
        return data
    }

    private static func transcriptHash(
        localKey: Data,
        localNonce: Data,
        peerKey: Data,
        peerNonce: Data
    ) -> Data {
        let pairs = [(localKey, localNonce), (peerKey, peerNonce)].sorted {
            $0.0.lexicographicallyPrecedes($1.0)
        }
        var transcript = Data("blau-framelink-handshake-v1".utf8)
        transcript.append(pairs[0].0)
        transcript.append(pairs[0].1)
        transcript.append(pairs[1].0)
        transcript.append(pairs[1].1)
        return Data(SHA256.hash(data: transcript))
    }

    private func readUInt64(_ data: Data, offset: Int) -> UInt64 {
        data[(data.startIndex + offset) ..< (data.startIndex + offset + 8)].reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        }
    }

    private static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0 ..< count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
