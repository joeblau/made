import Foundation
import Network
import Testing
@preconcurrency @testable import RoyalVNCKit
@testable import Pilot

@Suite("Remote desktop credential policy")
struct RemoteDesktopCredentialPolicyTests {
    @Test("Only an explicit server rejection invalidates the password")
    func negotiationErrorsKeepCredentials() {
        #expect(RemoteDesktopCredentialPolicy.credentialWasRejected(
            VNCError.authentication(.securityHandshakingFailed(reason: "Incorrect password"))
        ))
        for error: VNCError in [
            .authentication(.ardAuthenticationFailed),
            .authentication(.encryptionFailed),
            .authentication(.serverOfferedNoAuthTypes(reason: nil)),
            .authentication(.clientCouldNotDecideOnSecurityType),
            .connection(.cancelled),
        ] {
            #expect(!RemoteDesktopCredentialPolicy.credentialWasRejected(error))
        }
    }

    @Test("A password is only persisted once the server accepts it")
    func savesOnlyAfterSuccess() {
        #expect(
            RemoteDesktopCredentialPolicy.onConnected(savePassword: true, password: "hunter2") == .save
        )
    }

    @Test("Opting out of saving clears any previously stored password")
    func optingOutDeletes() {
        #expect(
            RemoteDesktopCredentialPolicy.onConnected(savePassword: false, password: "hunter2") == .delete
        )
    }

    @Test("An empty password is never stored")
    func emptyPasswordIsNeverStored() {
        #expect(
            RemoteDesktopCredentialPolicy.onConnected(savePassword: true, password: "") == .delete
        )
    }

    /// The regression this policy exists for: a rejected password used to stay
    /// in the Keychain, so auto-connect replayed it on every tab-in and failed
    /// identically forever.
    @Test("A rejected password is dropped so auto-connect stops replaying it")
    func authenticationFailureDeletes() {
        #expect(RemoteDesktopCredentialPolicy.onFailure(isAuthenticationFailure: true) == .delete)
    }

    /// The other half: a dropped link must not discard a password that was
    /// working seconds earlier.
    @Test("A non-authentication failure leaves a working password alone")
    func networkFailureKeepsPassword() {
        #expect(RemoteDesktopCredentialPolicy.onFailure(isAuthenticationFailure: false) == .leaveAlone)
    }
}

@Suite("Remote desktop session manager")
@MainActor
struct RemoteDesktopSessionManagerTests {
    @Test("All four visible machines stay active while other groups age out")
    func allVisibleMachinesStayActive() {
        let manager = RemoteDesktopSessionManager()
        defer { manager.endAllSessions() }
        let visible = Set((0..<4).map { _ in UUID() })
        let hidden = UUID()
        for id in visible.union([hidden]) { _ = manager.session(for: id) }
        manager.setActiveConnections(visible)
        for id in visible { #expect(manager.existingSession(for: id)?.backgroundedAt == nil) }
        #expect(manager.existingSession(for: hidden)?.backgroundedAt != nil)
        manager.setActiveConnections([hidden])
        for id in visible { #expect(manager.existingSession(for: id)?.backgroundedAt != nil) }
        #expect(manager.existingSession(for: hidden)?.backgroundedAt == nil)
    }

    /// The property that makes tab switching free: the same connection id hands
    /// back the same session, so its `VNCConnection` is never rebuilt.
    @Test("The same connection keeps the same session across lookups")
    func sessionIsReusedPerConnection() {
        let manager = RemoteDesktopSessionManager()
        let id = UUID()
        #expect(manager.session(for: id) === manager.session(for: id))
    }

    @Test("Different connections get different sessions")
    func sessionsAreKeyedByConnection() {
        let manager = RemoteDesktopSessionManager()
        #expect(manager.session(for: UUID()) !== manager.session(for: UUID()))
    }

    @Test("A new session starts idle and is not live")
    func newSessionIsIdle() {
        let manager = RemoteDesktopSessionManager()
        let session = manager.session(for: UUID())
        #expect(session.status == .idle)
        #expect(!session.isLive)
        #expect(manager.liveSessionCount == 0)
    }

    @Test("Ending a session forgets it")
    func endingASessionForgetsIt() {
        let manager = RemoteDesktopSessionManager()
        let id = UUID()
        let original = manager.session(for: id)
        manager.endSession(for: id)
        #expect(manager.existingSession(for: id) == nil)
        #expect(manager.session(for: id) !== original)
    }

    @Test("Only the inactive tabs start ageing out")
    func activeTabIsNotBackgrounded() {
        let manager = RemoteDesktopSessionManager()
        let active = UUID()
        let other = UUID()
        _ = manager.session(for: active)
        _ = manager.session(for: other)

        manager.setActive(active)
        #expect(manager.existingSession(for: active)?.backgroundedAt == nil)
        #expect(manager.existingSession(for: other)?.backgroundedAt != nil)

        // Tabbing over flips which one is ageing.
        manager.setActive(other)
        #expect(manager.existingSession(for: other)?.backgroundedAt == nil)
        #expect(manager.existingSession(for: active)?.backgroundedAt != nil)
    }

    @Test("Backgrounding stamps once, not on every selection change")
    func backgroundTimestampIsNotRefreshed() {
        let manager = RemoteDesktopSessionManager()
        let active = UUID()
        let other = UUID()
        _ = manager.session(for: active)
        _ = manager.session(for: other)

        manager.setActive(active)
        let firstStamp = manager.existingSession(for: other)?.backgroundedAt
        manager.setActive(active)
        #expect(manager.existingSession(for: other)?.backgroundedAt == firstStamp)
    }

    /// Reaping drops the socket, never the tab: the session object has to
    /// survive so the connection still has somewhere to reconnect into.
    @Test("Reaping keeps the session object so the tab survives")
    func reapingKeepsTheSession() {
        let manager = RemoteDesktopSessionManager()
        let id = UUID()
        let session = manager.session(for: id)
        manager.setActive(nil)

        manager.reapIdleSessions(now: Date().addingTimeInterval(3600), gracePeriod: 60)

        #expect(manager.existingSession(for: id) === session)
        #expect(session.status == .idle)
    }
}

@Suite("Remote desktop connection lifecycle")
@MainActor
struct RemoteDesktopConnectionLifecycleTests {
    @Test("Apple authentication gets a bounded deadline that success cancels", arguments: [false, true])
    func authenticationHasSeparateDeadline(succeeds: Bool) async throws {
        let server = try SilentVNCServer()
        defer { server.stop() }
        try await waitUntil { server.port != nil }
        let session = RemoteDesktopSession(
            connectionID: UUID(), timeout: .milliseconds(100), authenticationTimeout: .milliseconds(500)
        )
        defer { session.disconnect() }
        connect(session, port: try #require(server.port))
        let connection = try #require(session.activeConnection)
        let relay = try #require(session.connectionDelegate)
        let credential = await withCheckedContinuation { continuation in
            relay.connection(connection, credentialFor: .appleRemoteDesktop) {
                continuation.resume(returning: $0 != nil)
            }
        }
        #expect(credential)
        try await Task.sleep(for: .milliseconds(200))
        #expect(session.status == .connecting)
        if succeeds {
            relay.connection(connection, stateDidChange: .connected)
            try await waitUntil { session.status == .connected }
            try await Task.sleep(for: .milliseconds(400))
            #expect(session.status == .connected)
            return
        }
        try await waitUntil { !session.isLive }
        guard case .failed(let message) = session.status else {
            Issue.record("Stalled authentication should time out")
            return
        }
        #expect(message.contains("authentication timed out"))
        #expect(!session.credentialRejected)
        #expect(session.activeConnection == nil)
    }

    @Test("A stale credential request cannot extend a replacement connection's deadline")
    func staleAuthenticationDoesNotExtendDeadline() async throws {
        let server = try SilentVNCServer()
        defer { server.stop() }
        try await waitUntil { server.port != nil }
        let session = RemoteDesktopSession(
            connectionID: UUID(), timeout: .milliseconds(150), authenticationTimeout: .seconds(10)
        )
        defer { session.disconnect() }
        let port = try #require(server.port)
        connect(session, port: port)
        let oldConnection = try #require(session.activeConnection)
        let oldRelay = try #require(session.connectionDelegate)
        connect(session, port: port)
        let rejected = await withCheckedContinuation { continuation in
            oldRelay.connection(oldConnection, credentialFor: .appleRemoteDesktop) {
                continuation.resume(returning: $0 == nil)
            }
        }
        #expect(rejected)
        try await waitUntil { !session.isLive }
        guard case .failed(let message) = session.status else {
            Issue.record("The replacement connection should keep its negotiation deadline")
            return
        }
        #expect(message.contains("connection timed out"))
    }

    @Test("Disconnect and timeout keep the saved password")
    func interruptedConnectionKeepsPassword() async throws {
        let server = try SilentVNCServer()
        defer { server.stop() }
        try await waitUntil { server.port != nil }
        let id = UUID()
        VNCKeychain.save("saved-test-password", id: id)
        defer { VNCKeychain.delete(id: id) }
        try #require(VNCKeychain.load(id: id) == "saved-test-password")
        let session = RemoteDesktopSession(connectionID: id, timeout: .milliseconds(100))
        defer { session.disconnect() }
        connect(session, port: try #require(server.port))
        session.disconnect()
        #expect(VNCKeychain.load(id: id) == "saved-test-password")
        connect(session, port: try #require(server.port))
        try await waitUntil { !session.isLive }
        #expect(VNCKeychain.load(id: id) == "saved-test-password")
        #expect(!session.credentialRejected)
    }

    @Test("A closed connection keeps the saved password; a server rejection deletes it", arguments: [false, true])
    func passwordOnlyDeletedOnRejection(rejected: Bool) async throws {
        let server = try SilentVNCServer()
        defer { server.stop() }
        try await waitUntil { server.port != nil }
        let id = UUID()
        VNCKeychain.save("saved-test-password", id: id)
        defer { VNCKeychain.delete(id: id) }
        try #require(VNCKeychain.load(id: id) == "saved-test-password")
        let session = RemoteDesktopSession(connectionID: id)
        defer { session.disconnect() }
        connect(session, port: try #require(server.port))
        let connection = try #require(session.activeConnection)
        let relay = try #require(session.connectionDelegate)
        let error: VNCError = rejected
            ? .authentication(.securityHandshakingFailed(reason: "Incorrect password"))
            : .connection(.closed)
        relay.connection(connection, stateDidChange: .disconnected(error: error))
        try await waitUntil { !session.isLive }
        #expect(session.credentialRejected == rejected)
        #expect(VNCKeychain.load(id: id) == (rejected ? nil : "saved-test-password"))
    }

    @Test("A server that accepts TCP but stalls the handshake times out")
    func stalledHandshakeTimesOut() async throws {
        let server = try SilentVNCServer()
        defer { server.stop() }
        try await waitUntil { server.port != nil }
        let session = RemoteDesktopSession(connectionID: UUID(), timeout: .milliseconds(300))
        defer { session.disconnect() }
        connect(session, port: try #require(server.port))
        try await waitUntil { !server.clients.isEmpty }
        try await waitUntil { !session.isLive }

        guard case .failed(let message) = session.status else {
            Issue.record("A stalled handshake should show a retryable error")
            return
        }
        #expect(message.contains("timed out"))
        #expect(session.activeConnection == nil)
        #expect(session.connectionDelegate == nil)
    }

    @Test("Cancel returns immediately and ignores late success and its old deadline")
    func cancellationInvalidatesAttempt() async throws {
        let server = try SilentVNCServer()
        defer { server.stop() }
        try await waitUntil { server.port != nil }
        let session = RemoteDesktopSession(connectionID: UUID(), timeout: .milliseconds(100))
        connect(session, port: try #require(server.port))
        let connection = try #require(session.activeConnection)
        let relay = try #require(session.connectionDelegate)

        session.disconnect()
        #expect(session.status == .idle)
        #expect(session.activeConnection == nil)
        relay.connection(connection, stateDidChange: .connected)
        try await Task.sleep(for: .milliseconds(200))
        #expect(session.status == .idle)
    }

    @Test("A retry ignores callbacks from a timed-out attempt and cancels its deadline on success")
    func retrySurvivesOldCallbacks() async throws {
        let server = try SilentVNCServer()
        defer { server.stop() }
        try await waitUntil { server.port != nil }
        let session = RemoteDesktopSession(connectionID: UUID(), timeout: .milliseconds(100))
        defer { session.disconnect() }
        let port = try #require(server.port)
        connect(session, port: port)
        let oldConnection = try #require(session.activeConnection)
        let oldRelay = try #require(session.connectionDelegate)
        try await waitUntil { !session.isLive }

        connect(session, port: port)
        let newConnection = try #require(session.activeConnection)
        let newRelay = try #require(session.connectionDelegate)
        oldRelay.connection(oldConnection, stateDidChange: .connected)
        oldRelay.connection(oldConnection, stateDidChange: .disconnected)
        try await Task.sleep(for: .milliseconds(20))
        #expect(session.status == .connecting)
        #expect(session.activeConnection === newConnection)

        newRelay.connection(newConnection, stateDidChange: .connected)
        try await waitUntil { session.status == .connected }
        newRelay.connection(newConnection, stateDidChange: .connecting)
        try await Task.sleep(for: .milliseconds(200))
        #expect(session.status == .connected)
        #expect(session.activeConnection === newConnection)
    }

    @Test("Disconnecting never reopens the connecting overlay and final failure releases the socket")
    func disconnectionDoesNotLookLikeConnection() async throws {
        let server = try SilentVNCServer()
        defer { server.stop() }
        try await waitUntil { server.port != nil }
        let session = RemoteDesktopSession(connectionID: UUID())
        defer { session.disconnect() }
        connect(session, port: try #require(server.port))
        let connection = try #require(session.activeConnection)
        let relay = try #require(session.connectionDelegate)
        relay.connection(connection, stateDidChange: .connected)
        try await waitUntil { session.status == .connected }
        relay.connection(connection, stateDidChange: .disconnecting)
        try await Task.sleep(for: .milliseconds(20))
        #expect(session.status == .connected)

        let error = NSError(domain: "RemoteDesktopTest", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "The remote computer closed the connection."])
        relay.connection(connection, stateDidChange: .disconnected(error: error))
        try await waitUntil { !session.isLive }
        #expect(session.status == .failed(error.localizedDescription))
        #expect(session.activeConnection == nil)
        relay.connection(connection, stateDidChange: .connecting)
        try await Task.sleep(for: .milliseconds(20))
        #expect(session.status == .failed(error.localizedDescription))
    }

    @Test("Replacing an attempt gives the new connection its own full deadline")
    func replacementHasItsOwnDeadline() async throws {
        let server = try SilentVNCServer()
        defer { server.stop() }
        try await waitUntil { server.port != nil }
        let session = RemoteDesktopSession(connectionID: UUID(), timeout: .milliseconds(400))
        defer { session.disconnect() }
        let port = try #require(server.port)
        connect(session, port: port)
        try await Task.sleep(for: .milliseconds(250))
        connect(session, port: port)
        try await Task.sleep(for: .milliseconds(250))
        #expect(session.status == .connecting)
        try await waitUntil { !session.isLive }
        guard case .failed(let message) = session.status else {
            Issue.record("The replacement attempt should have its own timeout")
            return
        }
        #expect(message.contains("timed out"))
    }

    private func connect(_ session: RemoteDesktopSession, port: Int) {
        session.connect(host: "127.0.0.1", port: port, username: "", password: "",
                        savePasswordOnSuccess: false, isClipboardRedirectionEnabled: false)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "Connection lifecycle did not reach the expected state")
    }
}

/// Accepts real connections without sending an RFB greeting, reproducing a
/// reachable computer whose Screen Sharing handshake never completes.
@MainActor
private final class SilentVNCServer {
    private let listener: NWListener
    private(set) var clients: [NWConnection] = []
    private(set) var port: Int?

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, case .ready = state else { return }
                self.port = self.listener.port.map { Int($0.rawValue) }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self else { connection.cancel(); return }
                self.clients.append(connection)
                connection.start(queue: .main)
            }
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener.cancel()
        clients.forEach { $0.cancel() }
        clients.removeAll()
    }
}
