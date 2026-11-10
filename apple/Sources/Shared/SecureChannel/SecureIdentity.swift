import Foundation
import Observation

/// Owns this device's long-term identity key and auto-exchanges public keys
/// with the paired device over the encrypted Multipeer sync channel — the user
/// never types or pastes anything (issue #51).
///
/// Each app creates one (`role: .copilot` / `.pilot`), wires `send` to its
/// `PeerSyncService.send`, calls `announce()` whenever the channel connects,
/// and feeds incoming `.deviceKey` messages to `receive(_:)`. The settings UI
/// reads `localPublicKey` / `peerPublicKey` from the environment and offers a
/// single "Regenerate & re-sync" action.
@MainActor
@Observable
final class SecureIdentity {
    let role: ConnectedDeviceAppRole
    /// Isolation belongs to the identity's lifetime, including later UI actions
    /// and peer callbacks, so fixtures can never access production keys.
    let isIsolated: Bool

    /// This device's public key (base64). Generated automatically on first use.
    private(set) var localPublicKey: String?
    /// The paired peer's public key (base64) once it has synced over the channel.
    private(set) var peerPublicKey: String?

    /// Wired by the app to `PeerSyncService.send`.
    var send: ((SyncMessage) -> Void)?

    var isSynced: Bool { peerPublicKey != nil }

    /// The identity key this device proves; `DeviceIdentity.vault` in production.
    private let vault: DeviceIdentity.Vault
    /// Reads the approved peer pin; the pairing store in production.
    private let loadPeerPin: @Sendable () -> String?

    init(role: ConnectedDeviceAppRole, isolated: Bool = false) {
        self.role = role
        self.vault = DeviceIdentity.vault
        self.loadPeerPin = { DeviceIdentity.peerPublicKeyBase64() }
        let environment = ProcessInfo.processInfo.environment
        self.isIsolated = isolated || environment["BLAU_COCKPIT_FIXTURE"] != nil
            || environment["XCTestConfigurationFilePath"] != nil
        guard !isIsolated else {
            // Hosted test apps must not touch the developer's Keychain. Besides
            // mutating real trust state, a locked Keychain can block test launch
            // before XCTest has a chance to execute the bundle.
            self.localPublicKey = nil
            self.peerPublicKey = nil
            return
        }
        // Auto-generate (or load) our key, and recall any previously synced peer.
        self.localPublicKey = Self.publicKeyBase64(from: DeviceIdentity.vault)
        self.peerPublicKey = DeviceIdentity.peerPublicKeyBase64()
    }

    /// Test seam (issue #429): a live identity over an injected vault and pin
    /// source, so regeneration runs end to end without touching any Keychain.
    init(
        role: ConnectedDeviceAppRole,
        vault: DeviceIdentity.Vault,
        peerPin: @escaping @Sendable () -> String?
    ) {
        self.role = role
        self.vault = vault
        self.loadPeerPin = peerPin
        self.isIsolated = false
        self.localPublicKey = Self.publicKeyBase64(from: vault)
        self.peerPublicKey = peerPin()
    }

    /// Broadcast our public key to the connected peer. Safe to call repeatedly
    /// (e.g. on every reconnect).
    func announce() {
        guard let localPublicKey else { return }
        send?(.deviceKey(DeviceKeyAnnounce(role: role, publicKey: localPublicKey)))
    }

    /// Accept only an announcement that matches the key already approved by
    /// the Multipeer pairing flow. Network traffic can never create or replace
    /// a trust pin; a changed key requires a fresh user confirmation there.
    func receive(_ announce: DeviceKeyAnnounce) {
        guard !isIsolated, announce.role != role,
              DeviceIdentity.parsePeerPublicKey(announce.publicKey) != nil,
              announce.publicKey == loadPeerPin() else { return }
        peerPublicKey = announce.publicKey
    }

    /// Reload the pin after an explicit pairing decision stored it.
    /// `DeviceIdentity` reports an empty or malformed pin as `nil`, so Settings
    /// shows "Waiting to sync…" instead of a "Synced" badge over a blank key.
    func refreshPeer() {
        guard !isIsolated else { return }
        peerPublicKey = loadPeerPin()
    }

    private static func publicKeyBase64(from vault: DeviceIdentity.Vault) -> String? {
        (try? vault.loadOrCreate())?.publicKey.rawRepresentation.base64EncodedString()
    }

    /// Generate a fresh identity key and push it to the peer.
    ///
    /// `DeviceIdentity.regenerate()` notifies the Multipeer, FrameLink and
    /// secure-messaging transports, which drop every session proven with the
    /// old key (issue #429). The peer must approve that key change first, so
    /// this side stops reporting "Synced" until an authenticated reconnect
    /// reloads the pin via `refreshPeer()`.
    func regenerate() {
        guard !isIsolated else { return }
        let rotated = (try? vault.regenerate()) != nil
        localPublicKey = Self.publicKeyBase64(from: vault)
        if rotated { peerPublicKey = nil }
        announce()
    }
}
