import Foundation
// RoyalVNCKit predates Swift 6 strict concurrency; `@preconcurrency` keeps its
// non-Sendable types (VNCConnection/VNCFramebuffer/…) from tripping the actor
// checks when we bridge its delegate callbacks back onto the main actor.
@preconcurrency import RoyalVNCKit

/// Live status of a single VNC session, observed by the SwiftUI pane.
enum RemoteConnectionStatus: Sendable, Equatable {
    case idle
    case connecting
    case connected
    case disconnected
    case failed(String)
}

/// What should happen to the Keychain copy of a connection's password.
///
/// Split out from `RemoteDesktopSession` so the rule can be unit-tested without
/// a live server: the decision is the whole fix for a password that used to be
/// written before the handshake and never invalidated.
enum RemoteDesktopCredentialAction: Equatable {
    case save
    case delete
    case leaveAlone
}

/// When to persist or drop a saved VNC password.
///
/// The old flow wrote the password to the Keychain the moment Connect was
/// pressed, so a *wrong* password was cached and then replayed by auto-connect
/// on every single tab-in, failing identically forever. Persisting only after
/// the server accepts the credential — and dropping it when the server rejects
/// it — is what stops that loop.
enum RemoteDesktopCredentialPolicy {
    /// RoyalVNCKit also labels local encryption and negotiation errors as
    /// authentication errors. Only a failed server SecurityResult rejects the
    /// supplied credential; those other failures must keep a saved password.
    static func credentialWasRejected(_ error: Error) -> Bool {
        guard let error = error as? VNCError,
              case .authentication(.securityHandshakingFailed) = error else { return false }
        return true
    }

    /// The server accepted the credential, so it is now known-good.
    static func onConnected(savePassword: Bool, password: String) -> RemoteDesktopCredentialAction {
        guard savePassword else { return .delete }
        return password.isEmpty ? .delete : .save
    }

    /// The session ended in failure. Only an *authentication* failure says
    /// anything about the credential; a dropped Wi-Fi link or an unreachable
    /// host must not wipe a password that was working a moment ago.
    static func onFailure(isAuthenticationFailure: Bool) -> RemoteDesktopCredentialAction {
        isAuthenticationFailure ? .delete : .leaveAlone
    }
}

/// A VNC session whose lifetime is owned by `RemoteDesktopSessionManager`
/// rather than by the SwiftUI view hierarchy.
///
/// That ownership move is the point of the type. Tabbing between machines used
/// to destroy the pane and, with it, the `VNCConnection` — so every tab switch
/// paid a fresh TCP connect, RFB handshake and re-authentication. Holding the
/// connection here means a tab switch only rebuilds the *view* over the
/// framebuffer this session already owns.
@MainActor
@Observable
final class RemoteDesktopSession {
    /// Bounds TCP connection and negotiation with an unresponsive RFB server.
    static let connectionTimeout: Duration = .seconds(20)
    /// Apple Screen Sharing uses 4096-bit DH keys. RoyalVNCKit's unoptimized
    /// crypto can take more than 20 seconds locally before sending credentials.
    /// Give authentication its own bounded deadline once negotiation succeeds.
    static let authenticationTimeout: Duration = .seconds(90)

    let connectionID: UUID

    private(set) var status: RemoteConnectionStatus = .idle
    private(set) var credentialRejected = false

    /// Bumped whenever the framebuffer identity changes (created, resized, or
    /// torn down) so a mounted `RemoteDesktopViewer` knows its view is stale.
    private(set) var framebufferGeneration = 0

    /// When this session stopped being the visible tab; `nil` while it is
    /// active. Read by the manager's idle sweep.
    var backgroundedAt: Date?

    @ObservationIgnored private var connection: VNCConnection?
    @ObservationIgnored private var relay: StatusRelay?
    @ObservationIgnored private var password = ""
    @ObservationIgnored private var shouldSavePassword = false
    @ObservationIgnored private var connectionTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var keyboardInput = RemoteDesktopKeyboardInput()
    private let timeout: Duration
    private let authenticationTimeout: Duration
    /// Incremented per connect attempt. Late delegate callbacks from a torn-down
    /// attempt carry a stale token and are ignored, so a dying connection can't
    /// stamp `.failed` over a newer one.
    @ObservationIgnored private var attempt = 0

    init(
        connectionID: UUID,
        timeout: Duration = RemoteDesktopSession.connectionTimeout,
        authenticationTimeout: Duration = RemoteDesktopSession.authenticationTimeout
    ) {
        self.connectionID = connectionID
        self.timeout = timeout
        self.authenticationTimeout = authenticationTimeout
    }

    /// True while the socket is worth keeping — used by the idle sweep.
    var isLive: Bool {
        switch status {
        case .connecting, .connected: return true
        case .idle, .disconnected, .failed: return false
        }
    }

    var framebuffer: VNCFramebuffer? { connection?.framebuffer }
    var activeConnection: VNCConnection? { connection }
    var connectionDelegate: VNCConnectionDelegate? { relay }

    /// Capture this when dictation begins. A disconnect or reconnect invalidates
    /// the ID even when the saved machine and its SwiftUI tab stay the same.
    var inputSessionID: UUID? {
        guard status == .connected, connection?.connectionState.status == .connected else { return nil }
        return keyboardInput.sessionID
    }

    /// Returns whether text was enqueued on the captured live connection;
    /// VNC does not acknowledge whether the remote application accepted it.
    func sendText(_ text: String, sessionID: UUID) -> Bool {
        guard inputSessionID == sessionID else { return false }
        return keyboardInput.sendText(text, sessionID: sessionID)
    }

    func sendEnter(sessionID: UUID) -> Bool {
        guard inputSessionID == sessionID else { return false }
        return keyboardInput.sendEnter(sessionID: sessionID)
    }

    func connect(
        host: String,
        port: Int,
        username: String,
        password: String,
        savePasswordOnSuccess: Bool,
        isClipboardRedirectionEnabled: Bool
    ) {
        teardown(resettingStatusTo: nil)
        credentialRejected = false

        self.password = password
        shouldSavePassword = savePasswordOnSuccess
        attempt += 1

        let settings = VNCConnection.Settings(
            isDebugLoggingEnabled: false,
            hostname: host,
            port: UInt16(clamping: port),
            isShared: true,
            isScalingEnabled: true,
            useDisplayLink: true,
            inputMode: .forwardKeyboardShortcutsEvenIfInUseLocally,
            isClipboardRedirectionEnabled: isClipboardRedirectionEnabled,
            // 24-bit, not 16-bit: RoyalVNCKit silently drops the Tight and ZRLE
            // encodings below depth-24 and falls back to per-pixel colour
            // conversion, so "thousands of colours" costs *more* bandwidth and
            // CPU than millions. Verified in the encoder source, not assumed.
            colorDepth: .depth24Bit,
            frameEncodings: .default
        )

        // A fresh relay per attempt: its credentials are set at construction and
        // never mutated, so the background handshake thread only ever reads
        // values published before `connect()` was called.
        let relay = StatusRelay(session: self, attempt: attempt, username: username, password: password)
        let connection = VNCConnection(settings: settings)
        connection.delegate = relay

        self.relay = relay
        self.connection = connection
        backgroundedAt = nil
        status = .connecting
        framebufferGeneration += 1
        startDeadline(timeout, message:
            "The connection timed out. Check that the computer is awake, reachable, and has Screen Sharing enabled, then try again."
        )
        connection.connect()
    }

    fileprivate func beginAuthentication(attempt token: Int) -> Bool {
        guard token == attempt, status == .connecting else { return false }
        startDeadline(authenticationTimeout, message:
            "Screen Sharing was reached, but authentication timed out. Try again."
        )
        return true
    }

    private func startDeadline(_ timeout: Duration, message: String) {
        connectionTimeoutTask?.cancel()
        let token = attempt
        connectionTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard let self, self.attempt == token, self.status == .connecting else { return }
            self.teardown(resettingStatusTo: .failed(message))
        }
    }

    /// Drop the socket but keep the session object, so the tab stays and the
    /// connect form comes back clean.
    func disconnect() {
        teardown(resettingStatusTo: .idle)
    }

    /// `VNCCAFramebufferView.init` makes *itself* the connection's delegate and
    /// forwards through a weak reference. When that view goes away the
    /// connection's weak delegate would simply go nil and every status callback
    /// would stop arriving — so the viewer hands ownership back here first.
    func restoreConnectionDelegate() {
        guard let connection, let relay else { return }
        connection.delegate = relay
    }

    fileprivate func noteFramebufferChanged(attempt token: Int) {
        guard token == attempt else { return }
        framebufferGeneration += 1
    }

    fileprivate func apply(
        status newStatus: RemoteConnectionStatus,
        isAuthenticationFailure: Bool,
        attempt token: Int
    ) {
        guard token == attempt else { return }

        let action: RemoteDesktopCredentialAction
        switch newStatus {
        case .connected:
            guard status == .connecting else { return }
            connectionTimeoutTask?.cancel()
            connectionTimeoutTask = nil
            action = RemoteDesktopCredentialPolicy.onConnected(
                savePassword: shouldSavePassword,
                password: password
            )
        case .failed:
            credentialRejected = isAuthenticationFailure
            action = RemoteDesktopCredentialPolicy.onFailure(
                isAuthenticationFailure: isAuthenticationFailure
            )
        case .idle, .connecting, .disconnected:
            action = .leaveAlone
        }

        switch action {
        case .save: VNCKeychain.save(password, id: connectionID)
        case .delete: VNCKeychain.delete(id: connectionID)
        case .leaveAlone: break
        }

        switch newStatus {
        case .failed, .disconnected:
            teardown(resettingStatusTo: newStatus)
        case .connected:
            password = ""
            status = newStatus
            if let connection {
                keyboardInput.beginSession { [weak connection] event in
                    guard let connection, connection.connectionState.status == .connected else { return false }
                    let key = VNCKeyCode(event.keysym)
                    if event.isDown {
                        connection.keyDown(key)
                    } else {
                        connection.keyUp(key)
                    }
                    return true
                }
            }
        case .connecting:
            // A delayed progress callback must not reopen the spinner after
            // success, when its deadline has already been cancelled.
            break
        case .idle:
            status = newStatus
        }
    }

    private func teardown(resettingStatusTo newStatus: RemoteConnectionStatus?) {
        // Invalidate in-flight callbacks before dropping the connection.
        attempt += 1
        keyboardInput.endSession()
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        let oldConnection = connection
        connection = nil
        relay = nil
        password = ""
        shouldSavePassword = false
        framebufferGeneration += 1
        if let newStatus { status = newStatus }
        // RoyalVNCKit cancels its NWConnection synchronously without waiting
        // for the peer. Detach first so cancellation cannot revive the UI.
        oldConnection?.delegate = nil
        oldConnection?.disconnect()
    }
}

/// Bridges RoyalVNCKit's off-main delegate callbacks onto the main actor.
///
/// Kept separate from `RemoteDesktopSession` because `VNCConnectionDelegate` is
/// not actor-isolated: this object absorbs the `@unchecked Sendable` compromise
/// so the session itself stays a plain main-actor type.
private final class StatusRelay: NSObject, VNCConnectionDelegate, @unchecked Sendable {
    /// RoyalVNCKit's completion predates Sendable. Transfer this immutable reply
    /// to the main actor and invoke it exactly once, after checking the attempt.
    private struct CredentialReply: @unchecked Sendable {
        let credential: VNCCredential?
        let completion: (VNCCredential?) -> Void

        func send(accepted: Bool) {
            completion(accepted ? credential : nil)
        }
    }

    private weak var session: RemoteDesktopSession?
    private let attempt: Int
    private let username: String
    private let password: String

    init(session: RemoteDesktopSession, attempt: Int, username: String, password: String) {
        self.session = session
        self.attempt = attempt
        self.username = username
        self.password = password
    }

    func connection(
        _ connection: VNCConnection,
        stateDidChange connectionState: VNCConnection.ConnectionState
    ) {
        let status: RemoteConnectionStatus
        var isAuthenticationFailure = false

        switch connectionState.status {
        case .connecting:
            status = .connecting
        case .connected:
            status = .connected
        case .disconnecting:
            // The following .disconnected callback carries the actual error.
            // Disconnecting is never a new connection attempt.
            return
        case .disconnected:
            if let error = connectionState.error {
                status = .failed(error.localizedDescription)
                isAuthenticationFailure = RemoteDesktopCredentialPolicy.credentialWasRejected(error)
            } else {
                status = .disconnected
            }
        }

        let token = attempt
        let authFailure = isAuthenticationFailure
        Task { @MainActor [weak self] in
            self?.session?.apply(
                status: status,
                isAuthenticationFailure: authFailure,
                attempt: token
            )
        }
    }

    func connection(
        _ connection: VNCConnection,
        credentialFor authenticationType: VNCAuthenticationType,
        completion: @escaping (VNCCredential?) -> Void
    ) {
        let credential: VNCCredential?
        if authenticationType.requiresUsername {
            credential = VNCUsernamePasswordCredential(username: username, password: password)
        } else if authenticationType.requiresPassword {
            credential = VNCPasswordCredential(password: password)
        } else {
            credential = nil
        }
        // Arm the authentication deadline before resuming the library's key
        // exchange. A callback from a cancelled attempt must not restart it.
        let reply = CredentialReply(credential: credential, completion: completion)
        Task { @MainActor [weak self] in
            let accepted = self.map { $0.session?.beginAuthentication(attempt: $0.attempt) == true } ?? false
            reply.send(accepted: accepted)
        }
    }

    func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) {
        let token = attempt
        Task { @MainActor [weak self] in
            self?.session?.noteFramebufferChanged(attempt: token)
        }
    }

    func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) {
        let token = attempt
        Task { @MainActor [weak self] in
            self?.session?.noteFramebufferChanged(attempt: token)
        }
    }

    func connection(
        _ connection: VNCConnection,
        didUpdateFramebuffer framebuffer: VNCFramebuffer,
        x: UInt16, y: UInt16, width: UInt16, height: UInt16
    ) {}

    func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {}
}

/// App-lifetime owner of every remote-desktop session, keyed by connection id.
///
/// Lives outside the view tree on purpose: `RemoteDesktopView` is torn down
/// whenever the user leaves Remote Desktop mode, and the whole point is that
/// leaving and coming back does not cost a reconnect.
@MainActor
@Observable
final class RemoteDesktopSessionManager {
    static let shared = RemoteDesktopSessionManager()

    /// How long a session may stay connected after it stops being the visible
    /// tab.
    ///
    /// RoyalVNCKit drives its own framebuffer-update request loop internally
    /// (each received update immediately requests the next) and exposes no way
    /// to withhold those requests, so a backgrounded session keeps streaming
    /// whether or not anything is drawing it. Truly pausing one needs a fork.
    /// Until then, ageing idle sessions out bounds the cost while keeping
    /// ordinary back-and-forth tabbing instant.
    static let backgroundGracePeriod: TimeInterval = 5 * 60

    private var sessions: [UUID: RemoteDesktopSession] = [:]
    @ObservationIgnored private var sweepTask: Task<Void, Never>?

    init() {}

    /// The session for `id`, created idle on first use.
    func session(for id: UUID) -> RemoteDesktopSession {
        if let existing = sessions[id] { return existing }
        let session = RemoteDesktopSession(connectionID: id)
        sessions[id] = session
        return session
    }

    func existingSession(for id: UUID) -> RemoteDesktopSession? { sessions[id] }

    var liveSessionCount: Int { sessions.values.count(where: \.isLive) }

    /// Mark `id` as the visible tab; every other session starts ageing out.
    func setActive(_ id: UUID?) {
        setActiveConnections(Set(id.map { [$0] } ?? []))
    }

    /// Every screen in the selected group is visible, regardless of which
    /// machine currently has keyboard focus.
    func setActiveConnections(_ ids: Set<UUID>) {
        let now = Date()
        for (sessionID, session) in sessions {
            if ids.contains(sessionID) {
                session.backgroundedAt = nil
            } else if session.backgroundedAt == nil {
                session.backgroundedAt = now
            }
        }
        startSweeping()
    }

    /// Drop a session entirely — the connection is gone, not just hidden.
    func endSession(for id: UUID) {
        sessions.removeValue(forKey: id)?.disconnect()
    }

    func endAllSessions() {
        for session in sessions.values { session.disconnect() }
        sessions.removeAll()
        sweepTask?.cancel()
        sweepTask = nil
    }

    /// Disconnect sessions that have been backgrounded past the grace period.
    /// The session object survives so its tab keeps working; only the socket
    /// goes. Exposed (with injectable clock) so the sweep is testable.
    func reapIdleSessions(now: Date = Date(), gracePeriod: TimeInterval = backgroundGracePeriod) {
        for session in sessions.values {
            guard session.isLive,
                  let backgroundedAt = session.backgroundedAt,
                  now.timeIntervalSince(backgroundedAt) >= gracePeriod else { continue }
            session.disconnect()
        }
    }

    private func startSweeping() {
        guard sweepTask == nil else { return }
        sweepTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                self.reapIdleSessions()
            }
        }
    }
}
