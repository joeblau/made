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
    private let transportQueue = DispatchQueue(
        label: "app.blau.peersync.transport",
        qos: .userInitiated
    )
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var reconnectWork: DispatchWorkItem?
    private var pairingTimeoutWork: DispatchWorkItem?
    private var running = false
    private var authenticator: PeerSyncAuthenticator
    private var pendingPairing: PendingPairing?
    private var activePeer: MCPeerID?

    private static let serviceType = "blau-sync"
    private static let identityDiscoveryKey = "identity"
    private static let invitationTimeout: TimeInterval = 60
    private static let pairingTimeout: TimeInterval = 45

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

    init(role: Role, displayName: String) {
        let isTesting = ProcessInfo.processInfo.environment.keys.contains("XCTestConfigurationFilePath")
        let identity = isTesting
            ? Curve25519.KeyAgreement.PrivateKey()
            : ((try? DeviceIdentity.loadOrCreate()) ?? Curve25519.KeyAgreement.PrivateKey())
        self.role = role
        self.peerID = MCPeerID(displayName: displayName)
        self.session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        self.authenticator = PeerSyncAuthenticator(
            localKey: identity,
            peerPublicKeyBase64: isTesting ? nil : DeviceIdentity.peerPublicKeyBase64()
        )
        super.init()
        session.delegate = self
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
        guard let data = try? JSONEncoder().encode(message) else { return }
        transportQueue.async { [weak self] in
            self?.sendAuthenticated(data, mode: reliable ? .reliable : .unreliable)
        }
    }

    /// Reports whether the authenticated transport accepted the message. The
    /// caller can retain dictation when the connection disappears during stop.
    /// Cancellation prevents submission while the command is still queued.
    /// This is a transport result, not an acknowledgement from the remote UI.
    func sendReliably(_ message: SyncMessage) async -> Bool {
        guard let data = try? JSONEncoder().encode(message) else { return false }
        return await PeerSyncReliableSend.perform(on: transportQueue) { [weak self] in
            self?.sendAuthenticated(data, mode: .reliable) ?? false
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
        guard let trusted, !trusted.isEmpty else {
            return .approvalRequired(isKeyChange: false)
        }
        return candidate == trusted ? .trusted : .approvalRequired(isKeyChange: true)
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
        try? JSONEncoder().encode(InvitationContext(publicKey: authenticator.localPublicKeyBase64))
    }

    private func publicKey(from context: Data?) -> String? {
        guard let context,
              context.count <= 1_024 else { return nil }
        return try? JSONDecoder().decode(InvitationContext.self, from: context).publicKey
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
            guard activePeer == nil || activePeer == peerID else {
                session.cancelConnectPeer(peerID)
                return
            }
            activePeer = peerID
            guard let hello = authenticator.beginSession() else {
                updateStatus("Rejected unpaired sync peer")
                session.cancelConnectPeer(peerID)
                activePeer = nil
                return
            }
            updateStatus("Authenticating \(peerID.displayName)")
            sendRaw(hello, to: peerID)

        case .notConnected:
            if activePeer == peerID {
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
        guard activePeer == peerID,
              let opened = authenticator.open(data) else {
            updateStatus("Rejected unauthenticated sync data")
            return
        }
        switch opened {
        case .helloResponse(let response):
            sendRaw(response, to: peerID)

        case .authenticated:
            DispatchQueue.main.async { [weak self] in
                self?.isConnected = true
                self?.statusText = "Connected securely to \(peerID.displayName)"
            }

        case .message(let payload):
            guard authenticator.isAuthenticated,
                  let message = try? JSONDecoder().decode(SyncMessage.self, from: payload) else {
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
