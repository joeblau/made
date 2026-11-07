import CryptoKit
import Foundation

@main
enum DroneRevocationProof {
    @MainActor
    static func main() async throws {
        let storage = FailingStorage()
        let identity = DroneIdentityStore(role: .controller, storage: storage)
        let pairings = DronePairingStore(role: .controller, storage: storage)
        let peer = DronePeerID()
        try pairings.approve(Curve25519.KeyAgreement.PrivateKey().publicKey, for: peer, replacing: nil)
        let transport = DroneLANTransport(role: .controller, identityStore: identity, pairingStore: pairings)
        let factory = DroneLANTransportFactory(transport: transport, identityStore: identity, pairingStore: pairings)
        storage.failDeletes = true
        do {
            try await factory.revoke(droneID: peer.rawValue)
            fatalError("Revoke returned success before failed pin deletion")
        } catch DroneTransportError.revocationFailed {}
        let retained = try pairings.pinnedKey(for: peer)
        precondition(retained != nil, "failed deletion lost the pin")
        storage.failDeletes = false
        try await factory.revoke(droneID: peer.rawValue)
        let removed = try pairings.pinnedKey(for: peer)
        let remaining = try pairings.pairedPeerIDs()
        precondition(removed == nil && remaining.isEmpty, "revoke completed before pin/index deletion")
        try await factory.revoke(droneID: peer.rawValue)
        print("Drone revocation proof passed: failure propagation, retained pin, successful retry, index removal, idempotency.")
    }
}

private final class FailingStorage: PairingSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var failing = false
    var failDeletes: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }
    func read(account: String) throws -> Data? { lock.withLock { values[account] } }
    func write(_ data: Data, account: String) throws { lock.withLock { values[account] = data } }
    func delete(account: String) throws {
        try lock.withLock {
            if failing { throw DronePairingError.invalidPairingIndex }
            values.removeValue(forKey: account)
        }
    }
}
