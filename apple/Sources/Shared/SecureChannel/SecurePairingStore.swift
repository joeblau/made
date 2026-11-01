import CryptoKit
import Foundation
import Security

struct PairingSecrets: Equatable {
    var token: String
    var peerPublicKey: String
}

protocol PairingSecretStoring {
    func read(account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    func delete(account: String) throws
}

struct KeychainPairingSecretStorage: PairingSecretStoring {
    private let service = "app.blau.securechannel"

    func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw SecurePairingStore.StoreError.keychain(status)
        }
    }

    func write(_ data: Data, account: String) throws {
        let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let updates: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility,
        ]
        let updateStatus = SecItemUpdate(
            baseQuery(account: account) as CFDictionary,
            updates as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw SecurePairingStore.StoreError.keychain(updateStatus)
        }

        var attributes = baseQuery(account: account)
        attributes.merge(updates) { _, new in new }
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SecurePairingStore.StoreError.keychain(addStatus)
        }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecurePairingStore.StoreError.keychain(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Stores pairing material in the Keychain and removes the legacy plaintext
/// UserDefaults values after a successful migration.
struct SecurePairingStore {
    static let tokenAccount = "app.blau.securechannel.pairing-token"
    static let peerAccount = "app.blau.securechannel.peer"
    static let legacyTokenKey = "p2p.token"
    static let legacyPeerKey = "p2p.peerPublicKey"

    enum StoreError: Error {
        case invalidEncoding
        /// Non-empty peer-key text that is not a valid base64 X25519 key.
        case invalidPeerPublicKey
        case keychain(OSStatus)
        case randomGeneration(OSStatus)
    }

    private let storage: any PairingSecretStoring
    private let defaults: UserDefaults

    init(
        storage: any PairingSecretStoring = KeychainPairingSecretStorage(),
        defaults: UserDefaults = .standard
    ) {
        self.storage = storage
        self.defaults = defaults
    }

    func loadMigratingLegacy() throws -> PairingSecrets {
        var token = try string(account: Self.tokenAccount) ?? ""
        var peer = try string(account: Self.peerAccount) ?? ""

        if let legacyToken = defaults.string(forKey: Self.legacyTokenKey) {
            if token.isEmpty {
                token = legacyToken.trimmingCharacters(in: .whitespacesAndNewlines)
                try setToken(token)
            }
            defaults.removeObject(forKey: Self.legacyTokenKey)
        }
        if let legacyPeer = defaults.string(forKey: Self.legacyPeerKey) {
            if peer.isEmpty {
                peer = legacyPeer.trimmingCharacters(in: .whitespacesAndNewlines)
                // Migration copies the legacy value verbatim (unchanged
                // policy). Readers still normalize it through
                // `DeviceIdentity.pairedPeerPublicKey`, so a malformed legacy
                // value loads as unpaired rather than as a pin.
                try set(peer, account: Self.peerAccount)
            }
            defaults.removeObject(forKey: Self.legacyPeerKey)
        }

        return PairingSecrets(token: token, peerPublicKey: peer)
    }

    /// The pinned peer key, or `nil` when unpaired. Unlike `PairingSecrets`,
    /// which keeps the raw text for the secure-messaging form, an empty,
    /// whitespace-only, or malformed stored value is never reported as a pin.
    func loadPairedPeerPublicKey() throws -> String? {
        DeviceIdentity.pairedPeerPublicKey(try loadMigratingLegacy().peerPublicKey)
    }

    func setToken(_ value: String) throws {
        try set(value, account: Self.tokenAccount)
    }

    /// What saving the secure-messaging form's peer-key text does to the pin.
    /// The pin is shared with PeerSync/Multipeer, so free text must never
    /// overwrite it.
    enum PeerKeyUpdate: Equatable {
        /// A well-formed X25519 key (trimmed) replaces the pin.
        case save(String)
        /// An empty or whitespace-only field removes the pin (unpair).
        case clear
        /// Malformed text: nothing is written and the existing pin is kept.
        case rejectInvalid
    }

    /// Pure decision for persisting user-entered peer-key text. Only the
    /// canonical base64 of a 32-byte X25519 key is saved: Foundation's
    /// decoder tolerates some non-canonical text (e.g. surplus `=` padding),
    /// which would be a pin that never string-matches the peer's announced
    /// key, so it is rejected rather than stored.
    static func peerKeyUpdate(for input: String) -> PeerKeyUpdate {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .clear }
        guard let key = DeviceIdentity.parsePeerPublicKey(trimmed),
              key.rawRepresentation.base64EncodedString() == trimmed
        else { return .rejectInvalid }
        return .save(trimmed)
    }

    /// Applies ``peerKeyUpdate(for:)``: writes only a valid key, deletes on an
    /// empty field, and leaves storage untouched for malformed text.
    @discardableResult
    func applyPeerKeyInput(_ input: String) throws -> PeerKeyUpdate {
        let update = Self.peerKeyUpdate(for: input)
        switch update {
        case .save(let key):
            try set(key, account: Self.peerAccount)
        case .clear:
            try storage.delete(account: Self.peerAccount)
        case .rejectInvalid:
            break
        }
        return update
    }

    /// Pins `value` (trimmed), or unpairs when it is empty. Throws
    /// ``StoreError/invalidPeerPublicKey`` without touching the existing pin
    /// when `value` is not a valid X25519 key.
    func setPeerPublicKey(_ value: String) throws {
        guard try applyPeerKeyInput(value) != .rejectInvalid else {
            throw StoreError.invalidPeerPublicKey
        }
    }

    static func isValidIdentifier(_ value: String) -> Bool {
        guard (32...128).contains(value.utf8.count),
              value.utf8.allSatisfy({ byte in
                  (48...57).contains(byte)
                      || (65...90).contains(byte)
                      || (97...122).contains(byte)
                      || byte == 45
                      || byte == 95
              }),
              Set(value).count >= 8
        else { return false }
        return true
    }

    static func generateToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw StoreError.randomGeneration(status) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func string(account: String) throws -> String? {
        guard let data = try storage.read(account: account) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else {
            throw StoreError.invalidEncoding
        }
        return value
    }

    private func set(_ rawValue: String, account: String) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            try storage.delete(account: account)
            return
        }
        guard let data = value.data(using: .utf8) else { throw StoreError.invalidEncoding }
        try storage.write(data, account: account)
    }
}
