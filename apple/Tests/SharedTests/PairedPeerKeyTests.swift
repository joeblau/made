import CryptoKit
import Foundation
import Testing
@testable import Copilot

/// An empty, whitespace-only, or malformed stored pin must mean "unpaired"
/// everywhere, and build monitoring must never bind to such a value.
@Suite("Paired peer key normalization")
struct PairedPeerKeyTests {
    private final class MemoryStorage: PairingSecretStoring {
        var values: [String: Data] = [:]

        func read(account: String) throws -> Data? { values[account] }
        func write(_ data: Data, account: String) throws { values[account] = data }
        func delete(account: String) throws { values.removeValue(forKey: account) }
    }

    static let unpairedValues = ["", "   ", "\n\t ", "not-a-key", Data(count: 31).base64EncodedString()]
    static let unpairedArguments: [String?] = [nil] + unpairedValues.map(Optional.some)

    private static func validKey() -> String {
        Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    }

    private static func withStore(_ body: (SecurePairingStore, MemoryStorage, UserDefaults) throws -> Void) throws {
        let suite = "PairedPeerKeyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = MemoryStorage()
        try body(SecurePairingStore(storage: storage, defaults: defaults), storage, defaults)
    }

    @Test("Only a well-formed X25519 key counts as a pin")
    func normalization() {
        #expect(DeviceIdentity.pairedPeerPublicKey(nil) == nil)
        for value in Self.unpairedValues {
            #expect(DeviceIdentity.pairedPeerPublicKey(value) == nil, "\(value.debugDescription)")
        }
        let key = Self.validKey()
        #expect(DeviceIdentity.pairedPeerPublicKey(key) == key)
        #expect(DeviceIdentity.pairedPeerPublicKey("  \(key)\n") == key)
    }

    @Test("Nothing stored, or an empty stored key, loads as unpaired")
    func emptyStoredKeyIsUnpaired() throws {
        try Self.withStore { store, storage, _ throws in
            #expect(try store.loadMigratingLegacy().peerPublicKey.isEmpty)
            #expect(try store.loadPairedPeerPublicKey() == nil)
            for value in Self.unpairedValues {
                storage.values[SecurePairingStore.peerAccount] = Data(value.utf8)
                #expect(try store.loadPairedPeerPublicKey() == nil, "\(value.debugDescription)")
            }
        }
    }

    @Test("A blank legacy UserDefaults pin migrates to unpaired")
    func blankLegacyPinIsUnpaired() throws {
        try Self.withStore { store, storage, defaults throws in
            defaults.set("   ", forKey: SecurePairingStore.legacyPeerKey)
            #expect(try store.loadPairedPeerPublicKey() == nil)
            #expect(storage.values[SecurePairingStore.peerAccount] == nil)
            #expect(defaults.object(forKey: SecurePairingStore.legacyPeerKey) == nil)
        }
    }

    @Test("Explicit pairing stores a key that loads back; clearing it unpairs")
    func pairingRoundTrip() throws {
        try Self.withStore { store, _, _ throws in
            let key = Self.validKey()
            try store.setPeerPublicKey(key)
            #expect(try store.loadPairedPeerPublicKey() == key)
            try store.setPeerPublicKey("")
            #expect(try store.loadPairedPeerPublicKey() == nil)
        }
    }

    @Test("Peer sync treats a blank pin exactly like no pin: first pairing needs approval")
    func blankPinStillRequiresExplicitPairing() {
        let candidate = Self.validKey()
        for trusted in Self.unpairedArguments {
            #expect(PeerSyncService.pairingDecision(candidate: candidate, trusted: trusted) == .approvalRequired(isKeyChange: false))
            #expect(PeerSyncService.pairingDecision(candidate: candidate, trusted: DeviceIdentity.pairedPeerPublicKey(trusted))
                    == .approvalRequired(isKeyChange: false))
            var authenticator = PeerSyncAuthenticator(localKey: .init(), peerPublicKeyBase64: trusted)
            #expect(authenticator.peerPublicKeyBase64 == nil)
            #expect(authenticator.beginSession() == nil)
        }
    }

    @Test("Walkie refuses to follow a build without a real paired key", arguments: unpairedArguments)
    @MainActor
    func followRefusesWithoutPairedKey(stored: String?) async throws {
        let item: [String: Any] = ["id": 123, "run_attempt": 1, "html_url": "https://github.com/blau/made/actions/runs/123",
                                   "status": "in_progress", "name": "Apple builds", "head_branch": "main"]
        let run = try #require(BuildWorkflowRun.parse(item, workspaceID: UUID(), workspaceName: "made", checkedAt: Date()))
        let controller = BuildActivityController(peerKey: { stored })
        var sent: [SyncMessage] = []
        controller.send = { sent.append($0) }

        await controller.follow(run, connected: true)

        #expect(controller.followedRun == nil)
        #expect(controller.message == "Pair Walkie with Cockpit to follow a build.")
        #expect(sent.isEmpty)
    }
}
