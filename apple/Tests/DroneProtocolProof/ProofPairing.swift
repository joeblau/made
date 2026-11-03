import CryptoKit
import Foundation

private final class ProofPairingStorage: PairingSecretStoring {
    var values: [String: Data] = [:]

    func read(account: String) throws -> Data? { values[account] }
    func write(_ data: Data, account: String) throws { values[account] = data }
    func delete(account: String) throws { values.removeValue(forKey: account) }
}

enum ProofPairing {
    static func run() throws {
        let storage = ProofPairingStorage()
        let identity = DroneIdentityStore(role: .controller, storage: storage)
        let pairings = DronePairingStore(role: .controller, storage: storage)
        let controller = try identity.loadOrCreate()
        var records: [Data] = []

        for _ in 0 ..< 15 {
            let worker = Curve25519.KeyAgreement.PrivateKey()
            let peerID = DronePeerID()
            try pairings.approve(worker.publicKey, for: peerID, replacing: nil)
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
            guard try workerChannel.open(record) == DroneEnvelope(kind: .heartbeat) else {
                throw ProofError.pairingProofFailed
            }
            records.append(record)
        }
        guard try pairings.pairedPeerIDs().count == 15, Set(records).count == 15 else {
            throw ProofError.pairingProofFailed
        }

        let peerID = try require(pairings.pairedPeerIDs().first)
        let original = try require(pairings.pinnedKey(for: peerID))
        let replacement = Curve25519.KeyAgreement.PrivateKey().publicKey
        do {
            try pairings.approve(replacement, for: peerID, replacing: nil)
            throw ProofError.pairingProofFailed
        } catch DronePairingError.pinChanged { }
        try pairings.approve(replacement, for: peerID, replacing: original)
        try pairings.revoke(peerID)
        guard try pairings.pinnedKey(for: peerID) == nil else {
            throw ProofError.pairingProofFailed
        }
        print("pairing proof passed: 15 independent workers, explicit rotation and revocation")
    }

    private static func require<Value>(_ value: Value?) throws -> Value {
        guard let value else { throw ProofError.pairingProofFailed }
        return value
    }
}
