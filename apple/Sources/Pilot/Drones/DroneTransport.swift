import Foundation

struct DroneTransportRequest: Sendable {
    var droneID: UUID
    var endpoint: DroneEndpoint
    var expectedIdentityFingerprint: String?
    var hello: DroneHello
}

/// #320 returns a connection only after pinned mutual authentication and
/// version/capability negotiation. The supervisor never sends credentials or
/// execution requests to an unauthenticated endpoint.
protocol DroneConnection: Sendable {
    var peer: DroneAuthenticatedPeer { get }
    func send(_ envelope: DroneEnvelope) async throws
    func receive() async throws -> DroneEnvelope
    func close()
}

@MainActor
protocol DroneTransportFactory: AnyObject {
    var onPairingRequest: ((DronePairingRequest) -> Void)? { get set }
    func connect(_ request: DroneTransportRequest) async throws -> any DroneConnection
    func revoke(droneID: UUID) async throws
    func resolvePairing(requestID: UUID, approved: Bool)
    func authenticatedControllerID() throws -> UUID
}

extension DroneTransportFactory {
    var onPairingRequest: ((DronePairingRequest) -> Void)? {
        get { nil }
        set {}
    }

    func resolvePairing(requestID: UUID, approved: Bool) {}
    func authenticatedControllerID() throws -> UUID { UUID() }
}

final class UnavailableDroneTransport: DroneTransportFactory {
    func connect(_ request: DroneTransportRequest) async throws -> any DroneConnection {
        throw DroneTransportError.transportUnavailable
    }

    func revoke(droneID: UUID) async throws {}
}

struct DroneSupervisorTiming: Sendable {
    var heartbeatInterval: Duration
    var heartbeatTimeout: Duration
    var sleep: @Sendable (Duration) async throws -> Void
    var now: @Sendable () -> ContinuousClock.Instant

    init(
        heartbeatInterval: Duration = .seconds(DroneLimits.heartbeatInterval),
        heartbeatTimeout: Duration = .seconds(DroneLimits.heartbeatTimeout),
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.heartbeatInterval = heartbeatInterval
        self.heartbeatTimeout = heartbeatTimeout
        self.sleep = sleep
        self.now = now
    }
}

extension DroneTransportError {
    var issue: DroneConnectionIssue {
        switch self {
        case .transportUnavailable: .transportUnavailable
        case .connectionFailed: .connectionFailed
        case .timedOut: .timedOut
        case .disconnected: .disconnected
        case .heartbeatTimedOut: .heartbeatTimedOut
        case .pairingRequired: .pairingRequired
        case .unauthorized: .unauthorized
        case .revoked: .revoked
        case .identityMismatch: .identityMismatch
        case .incompatible: .incompatible
        case .busy: .busy
        case .remoteRejected: .remoteRejected
        case .revocationFailed: .revocationFailed
        }
    }
}

extension DroneConnectionIssue {
    var title: String {
        switch self {
        case .transportUnavailable: "Secure transport unavailable"
        case .connectionFailed: "Connection failed"
        case .timedOut: "Connection timed out"
        case .disconnected: "Disconnected"
        case .heartbeatTimedOut: "Heartbeat timed out"
        case .pairingRequired: "Pairing required"
        case .unauthorized: "Unauthorized"
        case .revoked: "Access revoked"
        case .identityMismatch: "Identity changed"
        case .incompatible: "Incompatible protocol"
        case .busy: "Drone busy"
        case .remoteRejected: "Request rejected"
        case .revocationFailed: "Could not revoke access"
        }
    }

    var recoveryInstruction: String {
        switch self {
        case .transportUnavailable:
            "Secure transport is unavailable. Check the worker installation, then retry. Cockpit will not use Local as a substitute."
        case .connectionFailed, .timedOut, .disconnected, .heartbeatTimedOut:
            "Check that droned is running and the Mac is on this network, then retry."
        case .pairingRequired:
            "Approve this Drone in the pairing ceremony, then retry."
        case .unauthorized:
            "Approve Cockpit on the Drone again. No work was sent."
        case .revoked:
            "Pair again to create a new approval. The old pin remains revoked."
        case .identityMismatch:
            "The endpoint presented a different identity. Verify the Mac before pairing again; the saved pin was not replaced."
        case .incompatible:
            "Update Cockpit or droned so they share a protocol version, then retry."
        case .busy:
            "The Drone is at its connection or job limit. Retry after existing work finishes."
        case .remoteRejected:
            "The Drone rejected the connection. Review diagnostics and update or pair again."
        case .revocationFailed:
            "Local metadata is retained because its pin could not be removed. Retry Forget."
        }
    }
}
