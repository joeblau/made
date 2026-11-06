import Foundation

enum DroneRemoteTerminalError: Error, Equatable {
    case remote(code: String)
}

actor DroneRemoteTerminalClient: DroneTerminalClient, @preconcurrency DroneToolTransport {
    let droneID: UUID
    let authenticatedControllerID: UUID
    var authenticatedDroneID: UUID { droneID }
    let capabilities: Set<String> = ["terminal.v1", "tools.v1"]
    private var isClosed = false
    private let connection: any DroneConnection
    private var requests: [UUID: CheckedContinuation<DroneEnvelope, any Error>] = [:]
    private var toolRequests: [UUID: AsyncThrowingStream<DroneEnvelope, any Error>.Continuation] = [:]
    private struct Subscription {
        let token = UUID()
        let generation: UInt64
        let handler: @Sendable (DroneOutputBody) -> Bool
    }
    private var subscriptions: [UUID: Subscription] = [:]

    init(droneID: UUID, controllerID: UUID, connection: any DroneConnection) {
        self.droneID = droneID
        authenticatedControllerID = controllerID
        self.connection = connection
    }

    func createTerminal(
        workingDirectory: String?,
        generation: UInt64,
        requestID: UUID
    ) async throws -> UUID {
        let response = try await request(
            kind: .create,
            body: .create(DroneCreateBody(
                workspaceID: DroneWorkspaceIDs.default,
                environment: [:],
                columns: 80,
                rows: 24
            )),
            idempotencyKey: "terminal-\(requestID.uuidString)"
        )
        guard response.kind == .created, let sessionID = response.sessionID else {
            throw TerminalSessionFailure.remoteSessionMissing
        }
        return sessionID.rawValue
    }

    func attachTerminal(_ reference: DroneTerminalSessionReference) async throws {
        try await attachTerminal(reference, after: .zero)
    }

    func attachTerminal(_ reference: DroneTerminalSessionReference, after cursor: DroneTerminalCursor) async throws {
        try validate(reference)
        _ = try await request(
            kind: .attach,
            sessionID: DroneSessionID(rawValue: reference.sessionID),
            body: .attach(cursor.attachBody)
        )
    }

    func sendInput(_ data: Data, to reference: DroneTerminalSessionReference) async throws {
        try validate(reference)
        try await connection.send(DroneEnvelope(
            kind: .input,
            requestID: UUID(),
            sessionID: DroneSessionID(rawValue: reference.sessionID),
            body: .input(DroneInputBody(data: data))
        ))
    }

    func foregroundActivity(for reference: DroneTerminalSessionReference) async throws -> TerminalProcessActivity {
        try validate(reference)
        let response = try await request(
            kind: .activity,
            sessionID: DroneSessionID(rawValue: reference.sessionID)
        )
        guard case .activityReport(let activity) = response.body else {
            throw TerminalSessionFailure.remoteSessionMissing
        }
        return activity.isIdle ? .idle : .running
    }

    func currentDirectory(for reference: DroneTerminalSessionReference) async throws -> String? {
        try validate(reference)
        let response = try await request(
            kind: .workingDirectory,
            sessionID: DroneSessionID(rawValue: reference.sessionID)
        )
        guard case .workingDirectoryReport(let directory) = response.body else {
            throw TerminalSessionFailure.remoteSessionMissing
        }
        return directory.path
    }

    func interrupt(_ reference: DroneTerminalSessionReference) async throws {
        try validate(reference)
        _ = try await request(
            kind: .cancel,
            sessionID: DroneSessionID(rawValue: reference.sessionID)
        )
    }

    func detach(_ reference: DroneTerminalSessionReference) async throws {
        try validate(reference)
        let subscriptionToken = subscriptions[reference.sessionID]?.token
        _ = try await request(
            kind: .detach,
            sessionID: DroneSessionID(rawValue: reference.sessionID)
        )
        if subscriptions[reference.sessionID]?.token == subscriptionToken {
            subscriptions.removeValue(forKey: reference.sessionID)
        }
    }

    func close(_ reference: DroneTerminalSessionReference) async throws {
        try validate(reference)
        let subscriptionToken = subscriptions[reference.sessionID]?.token
        _ = try await request(
            kind: .close,
            sessionID: DroneSessionID(rawValue: reference.sessionID)
        )
        if subscriptions[reference.sessionID]?.token == subscriptionToken {
            subscriptions.removeValue(forKey: reference.sessionID)
        }
    }

    func perform(
        _ request: DroneEnvelope
    ) async throws -> AsyncThrowingStream<DroneEnvelope, any Error> {
        guard !isClosed else { throw DroneTransportError.disconnected }
        guard let requestID = request.requestID else { throw DroneProtocolError.malformedMessage }
        let stream = AsyncThrowingStream<DroneEnvelope, any Error> { continuation in
            toolRequests[requestID] = continuation
        }
        try await connection.send(request)
        return stream
    }

    func setOutputHandler(
        _ handler: @escaping @Sendable (DroneOutputBody) -> Bool,
        for reference: DroneTerminalSessionReference
    ) async {
        guard !isClosed, reference.droneID == droneID,
              subscriptions[reference.sessionID] != nil || subscriptions.count < DroneLimits.maxLiveSessions,
              (subscriptions[reference.sessionID]?.generation ?? 0) <= reference.generation
        else { return }
        subscriptions[reference.sessionID] = Subscription(generation: reference.generation, handler: handler)
    }

    private func validate(_ reference: DroneTerminalSessionReference) throws {
        guard !isClosed else { throw DroneTransportError.disconnected }
        guard reference.droneID == droneID else { throw TerminalSessionFailure.destinationChanged }
        guard subscriptions[reference.sessionID]?.generation == reference.generation else {
            throw TerminalSessionFailure.staleGeneration
        }
    }

    func handle(_ envelope: DroneEnvelope) {
        guard !isClosed else { return }
        if envelope.kind.isTool, let requestID = envelope.requestID,
           let continuation = toolRequests[requestID] {
            continuation.yield(envelope)
            switch envelope.kind {
            case .toolAccepted, .toolOutput:
                break
            default:
                toolRequests.removeValue(forKey: requestID)
                continuation.finish()
            }
            return
        }
        if envelope.kind == .error, let requestID = envelope.requestID,
           let continuation = toolRequests.removeValue(forKey: requestID) {
            continuation.yield(envelope)
            continuation.finish()
            return
        }
        if envelope.kind == .output, case .output(let output) = envelope.body {
            if let sessionID = envelope.sessionID,
               let subscription = subscriptions[sessionID.rawValue], subscription.handler(output) {
                let cursor = DroneTerminalCursor(output: output)
                Task {
                    guard !isClosed,
                          subscriptions[sessionID.rawValue]?.token == subscription.token else { return }
                    try? await connection.send(DroneEnvelope(
                        kind: .acknowledge,
                        requestID: UUID(),
                        sessionID: sessionID,
                        body: .attach(DroneAttachBody(
                            afterSequence: cursor.sequence,
                            afterOffset: cursor.offset
                        ))
                    ))
                }
            }
            return
        }
        if envelope.kind == .error {
            guard let requestID = envelope.requestID,
                  let continuation = requests.removeValue(forKey: requestID)
            else { return }
            if case .error(let error) = envelope.body {
                continuation.resume(throwing: DroneRemoteTerminalError.remote(code: error.code))
            } else {
                continuation.resume(throwing: DroneTransportError.remoteRejected)
            }
            return
        }
        guard let requestID = envelope.requestID,
              let continuation = requests.removeValue(forKey: requestID)
        else { return }
        continuation.resume(returning: envelope)
    }

    func closeRequests() {
        isClosed = true
        subscriptions.removeAll()
        let continuations = requests.values
        requests.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: DroneTransportError.disconnected)
        }
        for continuation in toolRequests.values { continuation.finish() }
        toolRequests.removeAll()
    }

    private func request(
        kind: DroneMessageKind,
        sessionID: DroneSessionID? = nil,
        body: DroneEnvelope.Body = .empty,
        idempotencyKey: String? = nil
    ) async throws -> DroneEnvelope {
        guard !isClosed else { throw DroneTransportError.disconnected }
        let requestID = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            requests[requestID] = continuation
            Task {
                do {
                    guard !isClosed else { throw DroneTransportError.disconnected }
                    try await connection.send(DroneEnvelope(
                        kind: kind,
                        requestID: requestID,
                        sessionID: sessionID,
                        idempotencyKey: idempotencyKey,
                        body: body
                    ))
                } catch {
                    requests.removeValue(forKey: requestID)?.resume(throwing: error)
                }
            }
        }
    }
}
