import Foundation

@MainActor
final class DroneWorkerSupervisor {
    let droneID: UUID

    private var record: DroneRecord
    private let transport: any DroneTransportFactory
    private let timing: DroneSupervisorTiming
    private let jitter: () -> Double
    private let date: () -> Date
    private let onUpdate: (UUID) -> Void
    private let onEnvelope: (UUID, DroneEnvelope) -> Void

    private(set) var state: DroneConnectionState = .pairing
    private(set) var diagnostics = DroneDiagnostics()
    private var generation: UInt64 = 0
    private var runTask: Task<Void, Never>?
    private(set) var connection: (any DroneConnection)?
    private var lastActivity = ContinuousClock.now
    private var isRunning = false

    init(
        record: DroneRecord,
        transport: any DroneTransportFactory,
        timing: DroneSupervisorTiming = DroneSupervisorTiming(),
        jitter: @escaping () -> Double = { .random(in: 0..<1) },
        date: @escaping () -> Date = Date.init,
        onUpdate: @escaping (UUID) -> Void,
        onEnvelope: @escaping (UUID, DroneEnvelope) -> Void = { _, _ in }
    ) {
        self.droneID = record.id
        self.record = record
        self.transport = transport
        self.timing = timing
        self.jitter = jitter
        self.date = date
        self.onUpdate = onUpdate
        self.onEnvelope = onEnvelope
        diagnostics.lastEndpoint = record.endpoints.first
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        beginGeneration()
    }

    func stop() {
        isRunning = false
        retireGeneration()
        transition(.offline(issue: .disconnected, retryAttempt: nil))
    }

    func retry() {
        isRunning = true
        beginGeneration()
    }

    func updateRecord(_ record: DroneRecord) {
        let endpointsChanged = self.record.endpoints != record.endpoints
        let identityChanged = self.record.verifiedIdentityFingerprint
            != record.verifiedIdentityFingerprint
        self.record = record
        if endpointsChanged || identityChanged {
            retry()
        }
    }

    private func beginGeneration() {
        retireGeneration()
        generation &+= 1
        diagnostics.generation = generation
        diagnostics.lastIssue = nil
        diagnostics.record("generation \(generation) started", at: date())
        onUpdate(droneID)
        runTask = Task { [weak self] in
            guard let self else { return }
            await self.run(generation: generation)
        }
    }

    private func retireGeneration() {
        generation &+= 1
        runTask?.cancel()
        runTask = nil
        connection?.close()
        connection = nil
    }

    private func isCurrent(_ candidate: UInt64) -> Bool {
        isRunning && generation == candidate && !Task.isCancelled
    }

    private func run(generation candidate: UInt64) async {
        var reconnectAttempt = 0
        while isCurrent(candidate) {
            var lastIssue = DroneConnectionIssue.connectionFailed
            for endpoint in record.endpoints {
                guard isCurrent(candidate) else { return }
                diagnostics.connectAttempts += 1
                diagnostics.lastEndpoint = endpoint
                diagnostics.record("connecting to \(endpoint.displayText)", at: date())
                transition(.connecting(attempt: diagnostics.connectAttempts))

                do {
                    let connection = try await transport.connect(DroneTransportRequest(
                        droneID: droneID,
                        endpoint: endpoint,
                        expectedIdentityFingerprint: record.verifiedIdentityFingerprint,
                        hello: DroneHello()
                    ))
                    guard isCurrent(candidate) else {
                        connection.close()
                        return
                    }
                    try connection.peer.validate()
                    if let expected = record.verifiedIdentityFingerprint,
                       connection.peer.identityFingerprint != expected {
                        connection.close()
                        throw DroneTransportError.identityMismatch
                    }
                    self.connection = connection
                    lastActivity = timing.now()
                    diagnostics.successfulConnections += 1
                    diagnostics.lastIssue = nil
                    diagnostics.record("authenticated and negotiated", at: date())
                    transition(.connected(connection.peer))
                    try await supervise(connection, generation: candidate)
                    throw DroneTransportError.disconnected
                } catch {
                    connection?.close()
                    connection = nil
                    guard isCurrent(candidate) else { return }
                    let issue = Self.issue(for: error)
                    diagnostics.lastIssue = issue
                    diagnostics.record("connection ended: \(issue.rawValue)", at: date())
                    onUpdate(droneID)
                    lastIssue = issue
                    guard !issue.isTerminal else {
                        transition(Self.terminalState(for: issue))
                        runTask = nil
                        return
                    }
                }
            }

            guard isCurrent(candidate) else { return }
            let delay = Self.reconnectDelay(
                attempt: reconnectAttempt,
                unitJitter: jitter()
            )
            reconnectAttempt += 1
            if lastIssue == .busy {
                transition(.busy(retryAttempt: reconnectAttempt))
            } else {
                transition(.offline(issue: lastIssue, retryAttempt: reconnectAttempt))
            }
            diagnostics.record("retry scheduled in \(delay)", at: date())
            onUpdate(droneID)
            do {
                try await timing.sleep(delay)
            } catch {
                return
            }
        }
    }

    private func supervise(
        _ connection: any DroneConnection,
        generation candidate: UInt64
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [timing] in
                while !Task.isCancelled {
                    try await timing.sleep(timing.heartbeatInterval)
                    try Task.checkCancellation()
                    try await connection.send(DroneEnvelope(kind: .heartbeat))
                }
            }
            group.addTask { [weak self, timing] in
                while !Task.isCancelled {
                    let envelope = try await connection.receive()
                    try Self.validateIncoming(envelope)
                    await self?.noteActivity(generation: candidate, at: timing.now())
                    await self?.forward(envelope)
                }
            }
            group.addTask { [weak self, timing] in
                while !Task.isCancelled {
                    let checkInterval = Self.timeoutCheckInterval(timing)
                    try await timing.sleep(checkInterval)
                    guard let elapsed = await self?.timeSinceLastActivity(
                        generation: candidate,
                        now: timing.now()
                    ) else { return }
                    if elapsed >= timing.heartbeatTimeout {
                        throw DroneTransportError.heartbeatTimedOut
                    }
                }
            }
            _ = try await group.next()
            group.cancelAll()
            throw DroneTransportError.disconnected
        }
    }

    private func noteActivity(generation candidate: UInt64, at instant: ContinuousClock.Instant) {
        guard isCurrent(candidate) else { return }
        lastActivity = instant
        diagnostics.lastHeartbeatAt = date()
        diagnostics.record("valid record received", at: date())
        onUpdate(droneID)
    }

    private func forward(_ envelope: DroneEnvelope) {
        onEnvelope(droneID, envelope)
    }

    private func timeSinceLastActivity(
        generation candidate: UInt64,
        now: ContinuousClock.Instant
    ) -> Duration? {
        guard isCurrent(candidate) else { return nil }
        return now - lastActivity
    }

    private func transition(_ newState: DroneConnectionState) {
        state = newState
        onUpdate(droneID)
    }

    nonisolated private static func validateIncoming(_ envelope: DroneEnvelope) throws {
        guard envelope.kind == .error, case .error(let body) = envelope.body else { return }
        switch body.code {
        case "unauthorized": throw DroneTransportError.unauthorized
        case "revoked": throw DroneTransportError.revoked
        case "resourceLimit", "busy": throw DroneTransportError.busy
        case "unsupportedVersion", "negotiationFailed": throw DroneTransportError.incompatible
        default: throw DroneTransportError.remoteRejected
        }
    }

    nonisolated private static func issue(for error: any Error) -> DroneConnectionIssue {
        if let error = error as? DroneTransportError { return error.issue }
        if let error = error as? DroneProtocolError {
            switch error {
            case .unauthorized: return .unauthorized
            case .unsupportedVersion, .negotiationFailed: return .incompatible
            case .resourceLimit: return .busy
            case .disconnected, .rejectedRecord: return .disconnected
            default: return .remoteRejected
            }
        }
        return .connectionFailed
    }

    nonisolated private static func terminalState(for issue: DroneConnectionIssue) -> DroneConnectionState {
        switch issue {
        case .pairingRequired:
            .pairing
        case .unauthorized, .revoked, .identityMismatch:
            .unauthorized(issue)
        case .incompatible:
            .incompatible
        default:
            .offline(issue: issue, retryAttempt: nil)
        }
    }

    nonisolated static func reconnectDelay(attempt: Int, unitJitter: Double) -> Duration {
        let cappedAttempt = min(max(attempt, 0), 16)
        let base = min(pow(2.0, Double(cappedAttempt)), 30.0)
        let jitter = min(max(unitJitter, 0), 1)
        return .seconds(base / 2 + base / 2 * jitter)
    }

    nonisolated private static func timeoutCheckInterval(_ timing: DroneSupervisorTiming) -> Duration {
        min(timing.heartbeatInterval, timing.heartbeatTimeout)
    }
}
