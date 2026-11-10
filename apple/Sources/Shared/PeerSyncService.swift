import CryptoKit
import Foundation
@preconcurrency import MultipeerConnectivity

@Observable
final class PeerSyncService: NSObject, @unchecked Sendable {
    enum Role { case advertiser, browser }

    enum PairingDecision: Equatable {
        case trusted
        case approvalRequired(isKeyChange: Bool)
        case reject
    }

    private(set) var isConnected = false
    private(set) var statusText = "Idle"
    private(set) var pairingRequest: PeerSyncPairingRequest?

    var onReceive: (@MainActor (SyncMessage) -> Void)?

    private let role: Role
    private let peerID: MCPeerID
    private let session: MCSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let transportQueue = DispatchQueue(
        label: "app.blau.peersync.transport",
        qos: .userInitiated
    )
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var reconnectWork: DispatchWorkItem?
    private var pairingTimeoutWork: DispatchWorkItem?
    private var authenticationTimeoutWork: DispatchWorkItem?
    private var earlyFrames = PeerSyncEarlyFrameBuffer<MCPeerID>()
    private var running = false
    private var authenticator: PeerSyncAuthenticator
    private var pendingPairing: PendingPairing?
    /// Where identity rotations come from; `nil` for an ephemeral identity
    /// that must never adopt the device key.
    private let identityChanges: DeviceIdentity.ChangeSource?
    @ObservationIgnored private var identityObserver: (any NSObjectProtocol)?
    private var activePeer: MCPeerID?

    private static let serviceType = "blau-sync"
    private static let identityDiscoveryKey = "identity"
    private static let invitationTimeout: TimeInterval = 60
    private static let pairingTimeout: TimeInterval = 45
    /// Deadline for the sync hello/ready exchange after `.connected`. Pairing
    /// approval happens before the invitation is accepted, so this covers only
    /// the automatic handshake; a stalled one is torn down and retried (#430).
    static let authenticationTimeout: TimeInterval = 10

    private struct InvitationContext: Codable {
        let publicKey: String
    }

    private struct PendingPairing {
        let request: PeerSyncPairingRequest
        let peerID: MCPeerID
        let publicKey: String
        let completion: (Bool) -> Void
    }

    private final class InvitationReply: @unchecked Sendable {
        private let handler: (Bool, MCSession?) -> Void

        init(_ handler: @escaping (Bool, MCSession?) -> Void) {
            self.handler = handler
        }

        func call(_ accepted: Bool, session: MCSession?) {
            handler(accepted, session)
        }
    }

    /// `identityChanges` is a test seam: when set, the rotation observer is
    /// installed on its center and reloads through its loader even with an
    /// ephemeral identity. Production leaves it `nil`, which observes
    /// `DeviceIdentity.ChangeSource.stored` unless the identity is ephemeral.
    init(
        role: Role,
        displayName: String,
        usesEphemeralIdentity: Bool = false,
        identityChanges: DeviceIdentity.ChangeSource? = nil
    ) {
        let isTesting = usesEphemeralIdentity
            || ProcessInfo.processInfo.environment.keys.contains("XCTestConfigurationFilePath")
        let identity = isTesting
            ? Curve25519.KeyAgreement.PrivateKey()
            : ((try? DeviceIdentity.loadOrCreate()) ?? Curve25519.KeyAgreement.PrivateKey())
        self.role = role
        self.identityChanges = identityChanges ?? (isTesting ? nil : .stored)
        self.peerID = MCPeerID(displayName: displayName)
        self.session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        self.authenticator = PeerSyncAuthenticator(
            localKey: identity,
            peerPublicKeyBase64: isTesting ? nil : DeviceIdentity.peerPublicKeyBase64()
        )
        super.init()
        session.delegate = self
        if let center = self.identityChanges?.center {
            identityObserver = DeviceIdentity.observeChanges(center: center) { [weak self] in
                self?.reloadLocalIdentity()
            }
        }
    }

    deinit {
        if let identityObserver, let center = identityChanges?.center {
            center.removeObserver(identityObserver)
        }
    }

    func start() {
        transportQueue.async { [weak self] in
            self?.startTransport()
        }
    }

    func stop() {
        transportQueue.async { [weak self] in
            self?.stopTransport()
        }
    }

    func send(_ message: SyncMessage, reliable: Bool = true) {
        transportQueue.async { [weak self] in
            guard let self, let data = try? self.encoder.encode(message) else { return }
            self.sendAuthenticated(data, mode: reliable ? .reliable : .unreliable)
        }
    }

    /// Reports whether the authenticated transport accepted the message. The
    /// caller can retain dictation when the connection disappears during stop.
    /// Cancellation prevents submission while the command is still queued.
    /// This is a transport result, not an acknowledgement from the remote UI.
    func sendReliably(_ message: SyncMessage) async -> Bool {
        await PeerSyncReliableSend.perform(on: transportQueue) { [weak self] in
            guard let self, let data = try? self.encoder.encode(message) else { return false }
            return self.sendAuthenticated(data, mode: .reliable)
        }
    }

    @MainActor
    func resolvePairingRequest(approved: Bool) {
        guard let request = pairingRequest else { return }
        pairingRequest = nil
        transportQueue.async { [weak self] in
            self?.resolvePairingRequest(id: request.id, approved: approved)
        }
    }

    static func pairingDecision(candidate: String?, trusted: String?) -> PairingDecision {
        guard let candidate,
              DeviceIdentity.parsePeerPublicKey(candidate) != nil else { return .reject }
        // An empty or malformed pin is "unpaired": first-pairing approval, not
        // a key change. It can never equal a valid candidate, so this only
        // changes the prompt wording, never whether approval is required.
        guard let trusted, DeviceIdentity.parsePeerPublicKey(trusted) != nil else {
            return .approvalRequired(isKeyChange: false)
        }
        return candidate == trusted ? .trusted : .approvalRequired(isKeyChange: true)
    }

    /// The identity key the transport currently advertises and proves.
    func localIdentityPublicKeyBase64() async -> String {
        await withCheckedContinuation { continuation in
            transportQueue.async { [weak self] in
                continuation.resume(returning: self?.authenticator.localPublicKeyBase64 ?? "")
            }
        }
    }

    private func reloadLocalIdentity() {
        transportQueue.async { [weak self] in
            guard let self, let load = self.identityChanges?.load,
                  let key = try? load() else { return }
            self.adoptLocalIdentityOnQueue(key)
        }
    }

    /// Rebuild the authenticator around `key`, keeping the pinned peer, and
    /// restart the transport so every advertisement, invitation, pending
    /// approval and live session proves the current identity (issue #429).
    /// The peer still pins the old key, so it sees the key-change approval.
    private func adoptLocalIdentityOnQueue(_ key: Curve25519.KeyAgreement.PrivateKey) {
        guard key.publicKey.rawRepresentation.base64EncodedString()
            != authenticator.localPublicKeyBase64 else { return }
        authenticator = authenticator.replacingLocalKey(key)
        // `startTransport()` first tears down the session, any pending
        // approval and the advertisement that carried the old key.
        if running { startTransport() }
    }

    private func startTransport() {
        stopTransport()
        running = true
        switch role {
        case .advertiser:
            updateStatus("Advertising sync service")
            let adv = MCNearbyServiceAdvertiser(
                peer: peerID,
                discoveryInfo: [Self.identityDiscoveryKey: authenticator.localPublicKeyBase64],
                serviceType: Self.serviceType
            )
            adv.delegate = self
            advertiser = adv
            adv.startAdvertisingPeer()

        case .browser:
            updateStatus("Browsing for Cockpit sync service")
            let br = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
            br.delegate = self
            browser = br
            br.startBrowsingForPeers()
        }
    }

    private func stopTransport() {
        running = false
        reconnectWork?.cancel()
        reconnectWork = nil
        pairingTimeoutWork?.cancel()
        pairingTimeoutWork = nil
        authenticationTimeoutWork?.cancel()
        authenticationTimeoutWork = nil
        earlyFrames.removeAll()
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        browser?.stopBrowsingForPeers()
        browser = nil
        session.disconnect()
        pendingPairing?.completion(false)
        pendingPairing = nil
        activePeer = nil
        authenticator.resetSession()
        DispatchQueue.main.async { [weak self] in
            self?.isConnected = false
            self?.statusText = "Stopped"
            self?.pairingRequest = nil
        }
    }

    /// Debounced reconnection — cancels any pending restart before scheduling a new one.
    /// Both roles restart their respective transport so either side can recover.
    private func scheduleReconnect() {
        guard running else { return }
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWork = nil
            guard self.running else { return }
            // Don't reconnect if we already have peers
            guard self.session.connectedPeers.isEmpty else { return }
            switch self.role {
            case .advertiser:
                self.updateStatus("Restarting sync advertisement")
                self.advertiser?.stopAdvertisingPeer()
                let adv = MCNearbyServiceAdvertiser(
                    peer: self.peerID,
                    discoveryInfo: [
                        Self.identityDiscoveryKey: self.authenticator.localPublicKeyBase64,
                    ],
                    serviceType: Self.serviceType
                )
                adv.delegate = self
                self.advertiser = adv
                adv.startAdvertisingPeer()
            case .browser:
                self.updateStatus("Restarting Cockpit discovery")
                self.browser?.stopBrowsingForPeers()
                let br = MCNearbyServiceBrowser(peer: self.peerID, serviceType: Self.serviceType)
                br.delegate = self
                self.browser = br
                br.startBrowsingForPeers()
            }
        }
        reconnectWork = work
        transportQueue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    @discardableResult
    private func sendAuthenticated(_ data: Data, mode: MCSessionSendDataMode) -> Bool {
        guard let activePeer,
              session.connectedPeers.contains(activePeer),
              let envelope = authenticator.sealMessage(data) else { return false }
        do {
            try session.send(envelope, toPeers: [activePeer], with: mode)
            return true
        } catch {
            updateStatus("Could not send to Cockpit: \(error.localizedDescription)")
            return false
        }
    }

    private func sendRaw(_ data: Data, to peer: MCPeerID) {
        try? session.send(data, toPeers: [peer], with: .reliable)
    }

    private func updateStatus(_ status: String) {
        DispatchQueue.main.async { [weak self] in
            self?.statusText = status
        }
    }

    private func invitationContext() -> Data? {
        try? encoder.encode(InvitationContext(publicKey: authenticator.localPublicKeyBase64))
    }

    private func publicKey(from context: Data?) -> String? {
        guard let context,
              context.count <= 1_024 else { return nil }
        return try? decoder.decode(InvitationContext.self, from: context).publicKey
    }

    private func requestPairing(
        peerID: MCPeerID,
        displayName: String,
        publicKey: String,
        isKeyChange: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        guard pendingPairing == nil,
              activePeer == nil,
              let fingerprint = PeerSyncAuthenticator.pairingCode(
                  local: authenticator.localPublicKeyBase64,
                  peer: publicKey
              ) else {
            completion(false)
            return
        }
        let request = PeerSyncPairingRequest(
            id: UUID(),
            displayName: displayName,
            fingerprint: fingerprint,
            isKeyChange: isKeyChange
        )
        pendingPairing = PendingPairing(
            request: request,
            peerID: peerID,
            publicKey: publicKey,
            completion: completion
        )
        schedulePairingTimeout(for: request.id)
        DispatchQueue.main.async { [weak self] in
            self?.statusText = isKeyChange
                ? "Approval required for sync identity change"
                : "Approval required to pair \(displayName)"
            self?.pairingRequest = request
        }
    }

    private func resolvePairingRequest(id: UUID, approved: Bool) {
        guard let pending = pendingPairing,
              pending.request.id == id else { return }
        pendingPairing = nil
        pairingTimeoutWork?.cancel()
        pairingTimeoutWork = nil
        guard approved, authenticator.trust(peerPublicKeyBase64: pending.publicKey) else {
            pending.completion(false)
            updateStatus("Sync pairing rejected")
            return
        }
        if !ProcessInfo.processInfo.environment.keys.contains("XCTestConfigurationFilePath") {
            DeviceIdentity.storePeerPublicKey(pending.publicKey)
        }
        pending.completion(true)
        updateStatus("Sync device approved")
    }

    private func schedulePairingTimeout(for requestID: UUID) {
        pairingTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.running,
                  let pending = self.pendingPairing,
                  pending.request.id == requestID else { return }
            self.pairingTimeoutWork = nil
            self.pendingPairing = nil
            pending.completion(false)
            DispatchQueue.main.async { [weak self] in
                guard self?.pairingRequest?.id == requestID else { return }
                self?.pairingRequest = nil
                self?.statusText = "Sync pairing timed out; searching again"
            }
            self.scheduleReconnect()
        }
        pairingTimeoutWork = work
        transportQueue.asyncAfter(deadline: .now() + Self.pairingTimeout, execute: work)
    }

    /// Every `.connected` handshake either authenticates or is torn down by
    /// this deadline, so a lost or rejected hello cannot leave both apps at
    /// "Authenticating" with `scheduleReconnect` blocked by a connected peer.
    private func scheduleAuthenticationDeadline(for peerID: MCPeerID) {
        authenticationTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.authenticationTimeoutWork = nil
            guard self.running,
                  self.activePeer == peerID,
                  !self.authenticator.isAuthenticated else { return }
            self.tearDownStalledHandshake(with: peerID)
        }
        authenticationTimeoutWork = work
        transportQueue.asyncAfter(deadline: .now() + Self.authenticationTimeout, execute: work)
    }

    private func tearDownStalledHandshake(with peerID: MCPeerID) {
        authenticationTimeoutWork?.cancel()
        authenticationTimeoutWork = nil
        activePeer = nil
        authenticator.resetSession()
        earlyFrames.removeAll()
        // `cancelConnectPeer` alone may not drop an already-connected peer.
        // The session carries only the active peer, so disconnect it all.
        session.cancelConnectPeer(peerID)
        session.disconnect()
        DispatchQueue.main.async { [weak self] in
            self?.isConnected = false
            self?.statusText = "Sync authentication timed out; reconnecting"
        }
        scheduleReconnect()
    }

    private func clearPendingPairing(for peerID: MCPeerID, status: String) {
        guard let pending = pendingPairing,
              pending.peerID == peerID else { return }
        pendingPairing = nil
        pairingTimeoutWork?.cancel()
        pairingTimeoutWork = nil
        pending.completion(false)
        DispatchQueue.main.async { [weak self] in
            guard self?.pairingRequest?.id == pending.request.id else { return }
            self?.pairingRequest = nil
            self?.statusText = status
        }
    }
}

// MARK: - MCSessionDelegate

extension PeerSyncService: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        transportQueue.async { [weak self] in
            self?.handlePeerState(state, peerID: peerID)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        transportQueue.async { [weak self] in
            self?.handleReceived(data, from: peerID)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

private extension PeerSyncService {
    func handlePeerState(_ state: MCSessionState, peerID: MCPeerID) {
        switch state {
        case .connecting:
            updateStatus("Connecting to \(peerID.displayName)")

        case .connected:
            // A repeated `.connected` must not restart the session: a new
            // nonce would replace the hello the peer already accepted, and
            // the peer rejects a second hello (#430).
            guard activePeer != peerID else { return }
            guard activePeer == nil else {
                session.cancelConnectPeer(peerID)
                return
            }
            activePeer = peerID
            guard let hello = authenticator.beginSession() else {
                updateStatus("Rejected unpaired sync peer")
                session.cancelConnectPeer(peerID)
                activePeer = nil
                earlyFrames.discard(peerID)
                return
            }
            updateStatus("Authenticating \(peerID.displayName)")
            sendRaw(hello, to: peerID)
            scheduleAuthenticationDeadline(for: peerID)
            // Replay the peer's hello if it arrived before this callback.
            let early = earlyFrames.take(for: peerID)
            earlyFrames.removeAll()
            if let early {
                handleReceived(early, from: peerID)
            }

        case .notConnected:
            earlyFrames.discard(peerID)
            if activePeer == peerID {
                authenticationTimeoutWork?.cancel()
                authenticationTimeoutWork = nil
                activePeer = nil
                authenticator.resetSession()
                DispatchQueue.main.async { [weak self] in
                    self?.isConnected = false
                    self?.statusText = "Disconnected from \(peerID.displayName)"
                }
            }
            scheduleReconnect()

        @unknown default:
            updateStatus("Unknown sync state")
        }
    }

    func handleReceived(_ data: Data, from peerID: MCPeerID) {
        // MultipeerConnectivity can deliver a peer's hello before its
        // `.connected` callback; hold one bounded frame for replay (#430).
        if running, activePeer == nil, earlyFrames.hold(data, from: peerID) {
            return
        }
        guard activePeer == peerID,
              let opened = authenticator.open(data) else {
            updateStatus("Rejected unauthenticated sync data")
            return
        }
        switch opened {
        case .helloResponse(let response):
            sendRaw(response, to: peerID)

        case .authenticated:
            authenticationTimeoutWork?.cancel()
            authenticationTimeoutWork = nil
            DispatchQueue.main.async { [weak self] in
                self?.isConnected = true
                self?.statusText = "Connected securely to \(peerID.displayName)"
            }

        case .message(let payload):
            guard authenticator.isAuthenticated,
                  let message = try? decoder.decode(SyncMessage.self, from: payload) else {
                updateStatus("Rejected invalid sync message")
                return
            }
            // MCSession's reliable messages arrive on our serial transport
            // queue. Preserve that order all the way to the UI command handler.
            DispatchQueue.main.async { [weak self] in
                self?.onReceive?(message)
            }
        }
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension PeerSyncService: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let reply = InvitationReply(invitationHandler)
        transportQueue.async { [weak self] in
            guard let self, self.advertiser === advertiser else {
                reply.call(false, session: nil)
                return
            }
            self.handleInvitation(
                from: peerID,
                context: context,
                reply: reply
            )
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        transportQueue.async { [weak self] in
            guard let self, self.advertiser === advertiser else { return }
            self.updateStatus("Sync advertise failed: \(error.localizedDescription)")
            self.advertiser?.stopAdvertisingPeer()
            self.advertiser = nil
            self.scheduleReconnect()
        }
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension PeerSyncService: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        transportQueue.async { [weak self] in
            guard let self, self.browser === browser else { return }
            self.handleFoundPeer(
                peerID,
                publicKey: info?[Self.identityDiscoveryKey],
                browser: browser
            )
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        transportQueue.async { [weak self] in
            guard let self, self.browser === browser else { return }
            self.clearPendingPairing(
                for: peerID,
                status: "Lost Cockpit sync peer \(peerID.displayName)"
            )
            self.scheduleReconnect()
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        transportQueue.async { [weak self] in
            guard let self, self.browser === browser else { return }
            self.updateStatus("Sync browse failed: \(error.localizedDescription)")
            self.browser?.stopBrowsingForPeers()
            self.browser = nil
            self.scheduleReconnect()
        }
    }
}

private extension PeerSyncService {
    private func handleInvitation(
        from peerID: MCPeerID,
        context: Data?,
        reply: InvitationReply
    ) {
        guard activePeer == nil,
              pendingPairing == nil,
              session.connectedPeers.isEmpty else {
            reply.call(false, session: nil)
            return
        }
        let candidate = publicKey(from: context)
        switch Self.pairingDecision(
            candidate: candidate,
            trusted: authenticator.peerPublicKeyBase64
        ) {
        case .trusted:
            updateStatus("Accepting trusted sync peer \(peerID.displayName)")
            reply.call(true, session: session)

        case .approvalRequired(let isKeyChange):
            guard let candidate else {
                reply.call(false, session: nil)
                return
            }
            requestPairing(
                peerID: peerID,
                displayName: peerID.displayName,
                publicKey: candidate,
                isKeyChange: isKeyChange
            ) { [weak self] approved in
                guard let self, approved else {
                    reply.call(false, session: nil)
                    return
                }
                reply.call(true, session: self.session)
            }

        case .reject:
            updateStatus("Rejected sync invite without a valid identity")
            reply.call(false, session: nil)
        }
    }

    func handleFoundPeer(
        _ peerID: MCPeerID,
        publicKey candidate: String?,
        browser: MCNearbyServiceBrowser
    ) {
        guard activePeer == nil,
              pendingPairing == nil,
              session.connectedPeers.isEmpty else { return }
        switch Self.pairingDecision(
            candidate: candidate,
            trusted: authenticator.peerPublicKeyBase64
        ) {
        case .trusted:
            updateStatus("Inviting trusted Cockpit sync peer \(peerID.displayName)")
            browser.invitePeer(
                peerID,
                to: session,
                withContext: invitationContext(),
                timeout: Self.invitationTimeout
            )

        case .approvalRequired(let isKeyChange):
            guard let candidate else { return }
            requestPairing(
                peerID: peerID,
                displayName: peerID.displayName,
                publicKey: candidate,
                isKeyChange: isKeyChange
            ) { [weak self, weak browser] approved in
                guard let self, let browser, approved else { return }
                browser.invitePeer(
                    peerID,
                    to: self.session,
                    withContext: self.invitationContext(),
                    timeout: Self.invitationTimeout
                )
            }

        case .reject:
            updateStatus("Ignored Cockpit sync service without a valid identity")
        }
    }
}
