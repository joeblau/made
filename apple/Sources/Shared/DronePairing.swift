import CryptoKit
import Foundation

struct DronePeerID: Codable, Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

enum DroneRole: String, Codable, Sendable {
    case controller
    case worker
}

enum DronePairingError: Error, Equatable {
    case invalidIdentity
    case invalidPublicKey
    case invalidAnnouncement
    case invalidPairingIndex
    case pinChanged
    case duplicatePeerKey
    case pairingLimit
    case selfPairing
}

struct DroneIdentityStore {
    let role: DroneRole
    private let storage: any PairingSecretStoring

    init(
        role: DroneRole,
        storage: any PairingSecretStoring = KeychainPairingSecretStorage()
    ) {
        self.role = role
        self.storage = storage
    }

    var account: String { "app.blau.drone.identity.\(role.rawValue)" }
    var peerIDAccount: String { "app.blau.drone.identity-peer-id.\(role.rawValue)" }

    func loadOrCreatePeerID() throws -> DronePeerID {
        if let data = try storage.read(account: peerIDAccount),
           let identifier = String(data: data, encoding: .utf8) {
            guard let id = UUID(uuidString: identifier) else { throw DronePairingError.invalidIdentity }
            return DronePeerID(rawValue: id)
        }
        let peerID = DronePeerID()
        let data = Data(peerID.rawValue.uuidString.utf8)
        try storage.write(data, account: peerIDAccount)
        return peerID
    }

    func loadOrCreate() throws -> Curve25519.KeyAgreement.PrivateKey {
        if let data = try storage.read(account: account) {
            guard data.count == NoiseIK.keyLength,
                  let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
            else { throw DronePairingError.invalidIdentity }
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        try storage.write(key.rawRepresentation, account: account)
        return key
    }

    func rotate() throws -> Curve25519.KeyAgreement.PrivateKey {
        let key = Curve25519.KeyAgreement.PrivateKey()
        try storage.write(key.rawRepresentation, account: account)
        return key
    }
}

struct DronePairingStore {
    let role: DroneRole
    private let storage: any PairingSecretStoring

    init(
        role: DroneRole,
        storage: any PairingSecretStoring = KeychainPairingSecretStorage()
    ) {
        self.role = role
        self.storage = storage
    }

    var indexAccount: String { "app.blau.drone.pairing-index.\(role.rawValue)" }

    func account(for peerID: DronePeerID) -> String {
        "app.blau.drone.pairing.\(role.rawValue).\(peerID.rawValue.uuidString.lowercased())"
    }

    func pairedPeerIDs() throws -> [DronePeerID] {
        guard let data = try storage.read(account: indexAccount) else { return [] }
        guard let peerIDs = try? JSONDecoder().decode([DronePeerID].self, from: data),
              peerIDs.count <= DroneLimits.maxPairedWorkers,
              Set(peerIDs).count == peerIDs.count
        else { throw DronePairingError.invalidPairingIndex }
        return peerIDs
    }

    func pinnedKey(for peerID: DronePeerID) throws -> Curve25519.KeyAgreement.PublicKey? {
        guard let data = try storage.read(account: account(for: peerID)) else { return nil }
        guard data.count == NoiseIK.keyLength,
              let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: data)
        else { throw DronePairingError.invalidPublicKey }
        return key
    }

    func approve(
        _ candidate: Curve25519.KeyAgreement.PublicKey,
        for peerID: DronePeerID,
        replacing expected: Curve25519.KeyAgreement.PublicKey?
    ) throws {
        let current = try pinnedKey(for: peerID)
        guard current?.rawRepresentation == expected?.rawRepresentation else {
            throw DronePairingError.pinChanged
        }
        let peerIDs = try pairedPeerIDs()
        for otherID in peerIDs where otherID != peerID {
            if try pinnedKey(for: otherID)?.rawRepresentation == candidate.rawRepresentation {
                throw DronePairingError.duplicatePeerKey
            }
        }
        if current == nil && !peerIDs.contains(peerID) {
            guard peerIDs.count < DroneLimits.maxPairedWorkers else {
                throw DronePairingError.pairingLimit
            }
        }

        try storage.write(candidate.rawRepresentation, account: account(for: peerID))
        var updated = peerIDs.filter { $0 != peerID }
        updated.append(peerID)
        do {
            try writeIndex(updated)
        } catch {
            if let current {
                try? storage.write(current.rawRepresentation, account: account(for: peerID))
            } else {
                try? storage.delete(account: account(for: peerID))
            }
            throw error
        }
    }

    func revoke(_ peerID: DronePeerID) throws {
        try storage.delete(account: account(for: peerID))
        let remaining = try pairedPeerIDs().filter { $0 != peerID }
        try writeIndex(remaining)
    }

    private func writeIndex(_ peerIDs: [DronePeerID]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try storage.write(encoder.encode(peerIDs), account: indexAccount)
    }
}

struct DronePairingRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let peerID: DronePeerID
    let peerPublicKey: Data
    let verificationCode: String
    let isKeyChange: Bool

    init(
        id: UUID = UUID(),
        peerID: DronePeerID,
        peerPublicKey: Data,
        verificationCode: String,
        isKeyChange: Bool
    ) {
        self.id = id
        self.peerID = peerID
        self.peerPublicKey = peerPublicKey
        self.verificationCode = verificationCode
        self.isKeyChange = isKeyChange
    }
}

struct DronePairingAnnouncement: Equatable, Sendable {
    private static let marker = Data("BLAUDRONEPAIR1".utf8)
    private static let identifierBytes = 36
    static let byteCount = marker.count + 2 * NoiseIK.keyLength + identifierBytes

    let publicKey: Curve25519.KeyAgreement.PublicKey
    let nonce: Data
    let senderID: DronePeerID

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.publicKey.rawRepresentation == rhs.publicKey.rawRepresentation
            && lhs.nonce == rhs.nonce && lhs.senderID == rhs.senderID
    }

    init(
        publicKey: Curve25519.KeyAgreement.PublicKey,
        nonce: Data,
        senderID: DronePeerID = DronePeerID()
    ) {
        self.publicKey = publicKey
        self.nonce = nonce
        self.senderID = senderID
    }

    static func make(
        localKey: Curve25519.KeyAgreement.PrivateKey,
        senderID: DronePeerID = DronePeerID(),
        random: (Int) -> Data = randomBytes
    ) throws -> DronePairingAnnouncement {
        let nonce = random(NoiseIK.keyLength)
        guard nonce.count == NoiseIK.keyLength else {
            throw DronePairingError.invalidAnnouncement
        }
        return DronePairingAnnouncement(
            publicKey: localKey.publicKey,
            nonce: nonce,
            senderID: senderID
        )
    }

    func encode() throws -> Data {
        guard nonce.count == NoiseIK.keyLength,
              publicKey.rawRepresentation.count == NoiseIK.keyLength
        else { throw DronePairingError.invalidAnnouncement }
        var data = Self.marker
        data.append(publicKey.rawRepresentation)
        data.append(nonce)
        data.append(Data(senderID.rawValue.uuidString.utf8))
        return data
    }

    static func decode(_ data: Data) throws -> DronePairingAnnouncement {
        guard data.count == byteCount, data.starts(with: marker) else {
            throw DronePairingError.invalidAnnouncement
        }
        let keyStart = marker.count
        let nonceStart = keyStart + NoiseIK.keyLength
        let identifierStart = nonceStart + NoiseIK.keyLength
        let keyData = data.subdata(in: keyStart ..< nonceStart)
        let nonce = data.subdata(in: nonceStart ..< identifierStart)
        let identifier = String(decoding: data.suffix(identifierBytes), as: UTF8.self)
        guard let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyData),
              let senderID = UUID(uuidString: identifier)
        else { throw DronePairingError.invalidPublicKey }
        return DronePairingAnnouncement(
            publicKey: key,
            nonce: nonce,
            senderID: DronePeerID(rawValue: senderID)
        )
    }

    func request(
        localKey: Curve25519.KeyAgreement.PrivateKey,
        peerID: DronePeerID,
        existingPin: Curve25519.KeyAgreement.PublicKey?
    ) throws -> DronePairingRequest {
        guard publicKey.rawRepresentation != localKey.publicKey.rawRepresentation else {
            throw DronePairingError.selfPairing
        }
        let local = localKey.publicKey.rawRepresentation.base64EncodedString()
        let peer = publicKey.rawRepresentation.base64EncodedString()
        guard let code = PeerSyncAuthenticator.pairingCode(local: local, peer: peer) else {
            throw DronePairingError.invalidPublicKey
        }
        return DronePairingRequest(
            peerID: peerID,
            peerPublicKey: publicKey.rawRepresentation,
            verificationCode: code,
            isKeyChange: existingPin?.rawRepresentation != publicKey.rawRepresentation
                && existingPin != nil
        )
    }

    private static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0 ..< count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
