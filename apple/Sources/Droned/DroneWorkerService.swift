import Foundation

actor DroneWorkerService {
    private let transport: DroneLANTransport
    private let terminals: DroneTerminalEngine
    private let jobs: DroneJobEngine
    private let tools: DroneJobToolEngine
    private let permissions: DroneControllerPermissions
    private var toolLeases: DroneToolLeaseRegistry
    private var pairings: [DroneConnectionID: UUID] = [:]
    private var approvals: [UUID: DronePairingRequest] = [:]
    private var outputPumps = DroneWorkerTerminalPumps()
    private var toolOperations: [UUID: DroneEnvelope] = [:]
    private var toolHistories: [UUID: [DroneEnvelope]] = [:]
    private var toolHistoryOrder: [UUID] = []
    var onListening: (@Sendable (UInt16) -> Void)?
    var onAudit: (@Sendable (String) -> Void)?

    init(
        workspace: URL,
        stateDirectory: URL,
        transport: DroneLANTransport? = nil,
        workerID: UUID? = nil,
        permissions: DroneControllerPermissions = [],
        onAudit: (@Sendable (String) -> Void)? = nil
    ) throws {
        self.transport = transport ?? DroneLANTransport(role: .worker)
        self.permissions = permissions
        toolLeases = DroneToolLeaseRegistry(
            droneID: try workerID ?? DroneIdentityStore(role: .worker).loadOrCreatePeerID().rawValue
        )
        self.onAudit = onAudit
        let workspaceID = DroneWorkspaceIDs.default
        terminals = try DroneTerminalEngine(
            workspaces: [workspaceID: workspace],
            stateDirectory: stateDirectory.appendingPathComponent("terminals", isDirectory: true)
        )
        jobs = try DroneJobEngine(
            stateURL: stateDirectory.appendingPathComponent("jobs", isDirectory: true),
            workspaces: DroneWorkspaceRegistry(workspaces: [workspaceID: workspace])
        )
        tools = DroneJobToolEngine(jobs: jobs)
    }

    /// Trusted local control API, never invoked by a remote tool request.
    func issueToolLease(
        controllerID: UUID,
        workspaceID: UUID = DroneWorkspaceIDs.default,
        permissions requested: DroneControllerPermissions,
        lifetime: TimeInterval = 300
    ) throws -> DroneToolLease {
        guard pairings.values.contains(controllerID), workspaceID == DroneWorkspaceIDs.default,
              requested.isSubset(of: permissions)
        else { throw DroneProtocolError.unauthorized }
        let lease = try toolLeases.issue(
            controllerID: controllerID, workspaceID: workspaceID,
            permissions: requested, lifetime: lifetime, now: Date().timeIntervalSince1970
        )
        onAudit?("toolLease.issued")
        return lease
    }

    func setOnListening(_ handler: @escaping @Sendable (UInt16) -> Void) {
        onListening = handler
    }

    func start(bonjourInstanceID: String) {
        transport.onEvent = { [weak self] event in
            Task { await self?.handle(event) }
        }
        transport.startListening(bonjourInstanceID: bonjourInstanceID)
    }

    func stop() async {
        outputPumps.cancelAll()
        transport.stop()
        await terminals.shutdown()
    }

    func approvalSummaries() -> [DroneApprovalSummary] {
        approvals.values.map {
            DroneApprovalSummary(
                requestID: $0.id,
                verificationCode: $0.verificationCode,
                isKeyChange: $0.isKeyChange
            )
        }.sorted { $0.requestID.uuidString < $1.requestID.uuidString }
    }

    func resolvePairing(requestID: UUID, approved: Bool) {
        approvals.removeValue(forKey: requestID)
        onAudit?(approved ? "pairing.approved" : "pairing.rejected")
        transport.resolvePairing(requestID: requestID, approved: approved)
    }

    private func handle(_ event: DroneTransportEvent) {
        switch event {
        case .listening(let port):
            onListening?(port)
        case .connecting:
            break
        case .connected(let id, let peerID, _):
            pairings[id] = peerID.rawValue
        case .pairingRequired(let request):
            approvals[request.id] = request
        case .envelope(let id, _, let envelope):
            Task { await self.handle(envelope, connectionID: id) }
        case .disconnected(let id, _):
            if let pairingID = pairings.removeValue(forKey: id) {
                outputPumps.cancel(connectionID: id)
                Task { await terminals.disconnect(pairingID: pairingID, connectionID: id.rawValue) }
            }
        case .failed(let id, _):
            if let id, let pairingID = pairings.removeValue(forKey: id) {
                outputPumps.cancel(connectionID: id)
                Task { await terminals.disconnect(pairingID: pairingID, connectionID: id.rawValue) }
            }
        }
    }

    private func handle(_ envelope: DroneEnvelope, connectionID: DroneConnectionID) async {
        guard let pairingID = pairings[connectionID] else { return }
        do {
            if envelope.kind == .heartbeat { return }
            if envelope.kind.isTool {
                try await handleTool(envelope, connectionID: connectionID, pairingID: pairingID)
                return
            }
            try require(.terminal)
            switch envelope.kind {
            case .create:
                guard case .create(let body) = envelope.body, let key = envelope.idempotencyKey else {
                    throw DroneProtocolError.malformedMessage
                }
                let created = try await terminals.create(body, pairingID: pairingID, idempotencyKey: key)
                onAudit?("terminal.accepted")
                try await send(
                    DroneEnvelope(
                        kind: .created,
                        requestID: envelope.requestID,
                        sessionID: created.sessionID,
                        idempotencyKey: key
                    ),
                    on: connectionID
                )
            case .attach, .reconnect:
                guard let sessionID = envelope.sessionID, case .attach(let body) = envelope.body else {
                    throw DroneProtocolError.malformedMessage
                }
                _ = try await terminals.attach(
                    sessionID,
                    pairingID: pairingID,
                    connectionID: connectionID.rawValue,
                    after: DroneTerminalCursor(
                        sequence: body.afterSequence,
                        offset: body.afterOffset
                    )
                )
                try await send(
                    DroneEnvelope(
                        kind: envelope.kind == .attach ? .attached : .reconnected,
                        requestID: envelope.requestID,
                        sessionID: sessionID
                    ),
                    on: connectionID
                )
                startOutputPump(connectionID: connectionID, sessionID: sessionID, pairingID: pairingID)
            case .input:
                guard let sessionID = envelope.sessionID, case .input(let body) = envelope.body else {
                    throw DroneProtocolError.malformedMessage
                }
                try await terminals.input(
                    body.data,
                    sessionID: sessionID,
                    pairingID: pairingID,
                    connectionID: connectionID.rawValue
                )
            case .resize:
                guard let sessionID = envelope.sessionID, case .resize(let body) = envelope.body else {
                    throw DroneProtocolError.malformedMessage
                }
                try await terminals.resize(
                    columns: body.columns,
                    rows: body.rows,
                    sessionID: sessionID,
                    pairingID: pairingID,
                    connectionID: connectionID.rawValue
                )
                try await send(DroneEnvelope(kind: .ack, requestID: envelope.requestID, sessionID: sessionID), on: connectionID)
            case .detach:
                guard let sessionID = envelope.sessionID else { throw DroneProtocolError.malformedMessage }
                try await terminals.detach(sessionID, pairingID: pairingID, connectionID: connectionID.rawValue)
                outputPumps.cancel(connectionID: connectionID, sessionID: sessionID)
                try await send(DroneEnvelope(kind: .detached, requestID: envelope.requestID, sessionID: sessionID), on: connectionID)
            case .close:
                guard let sessionID = envelope.sessionID else { throw DroneProtocolError.malformedMessage }
                try await terminals.close(sessionID, pairingID: pairingID, connectionID: connectionID.rawValue)
                outputPumps.cancel(connectionID: connectionID, sessionID: sessionID)
                try await send(DroneEnvelope(kind: .closed, requestID: envelope.requestID, sessionID: sessionID), on: connectionID)
            case .cancel:
                guard let sessionID = envelope.sessionID else { throw DroneProtocolError.malformedMessage }
                try await terminals.interrupt(sessionID, pairingID: pairingID, connectionID: connectionID.rawValue)
                try await send(DroneEnvelope(kind: .cancelled, requestID: envelope.requestID, sessionID: sessionID), on: connectionID)
            case .activity:
                guard let sessionID = envelope.sessionID else { throw DroneProtocolError.malformedMessage }
                let activity = try await terminals.activity(sessionID, pairingID: pairingID)
                try await send(DroneEnvelope(
                    kind: .activityReport,
                    requestID: envelope.requestID,
                    sessionID: sessionID,
                    body: .activityReport(activity)
                ), on: connectionID)
            case .workingDirectory:
                guard let sessionID = envelope.sessionID else { throw DroneProtocolError.malformedMessage }
                let directory = try await terminals.workingDirectory(sessionID, pairingID: pairingID)
                try await send(DroneEnvelope(
                    kind: .workingDirectoryReport,
                    requestID: envelope.requestID,
                    sessionID: sessionID,
                    body: .workingDirectoryReport(directory)
                ), on: connectionID)
            case .fastCommand:
                guard let sessionID = envelope.sessionID, case .fastCommand(let body) = envelope.body else {
                    throw DroneProtocolError.malformedMessage
                }
                try await terminals.runFastCommand(
                    body.command,
                    sessionID: sessionID,
                    pairingID: pairingID,
                    connectionID: connectionID.rawValue
                )
                try await send(DroneEnvelope(kind: .ack, requestID: envelope.requestID, sessionID: sessionID), on: connectionID)
            case .acknowledge:
                guard let sessionID = envelope.sessionID, case .attach(let cursor) = envelope.body else {
                    throw DroneProtocolError.malformedMessage
                }
                try await terminals.acknowledge(
                    DroneTerminalCursor(sequence: cursor.afterSequence, offset: cursor.afterOffset),
                    sessionID: sessionID,
                    pairingID: pairingID,
                    connectionID: connectionID.rawValue
                )
            default:
                throw DroneProtocolError.malformedMessage
            }
        } catch {
            try? await send(DroneEnvelope(
                kind: .error,
                requestID: envelope.requestID,
                sessionID: envelope.sessionID,
                idempotencyKey: envelope.idempotencyKey,
                body: .error(DroneErrorBody(code: Self.errorCode(error), retryable: false))
            ), on: connectionID)
        }
    }

    private func handleTool(
        _ envelope: DroneEnvelope,
        connectionID: DroneConnectionID,
        pairingID: UUID
    ) async throws {
        guard let lease = envelope.lease, let requestID = envelope.requestID,
              let idempotencyKey = envelope.idempotencyKey
        else { throw DroneProtocolError.malformedMessage }
        try toolLeases.authorize(
            envelope, controllerID: pairingID, now: Date().timeIntervalSince1970
        )
        let context = DroneToolRequestContext(
            lease: lease,
            requestID: requestID,
            idempotencyKey: idempotencyKey
        )
        switch envelope.kind {
        case .toolRead:
            guard case .toolRead(let request) = envelope.body else { throw DroneProtocolError.malformedMessage }
            let result = try await tools.read(request, context: context)
            try await send(DroneEnvelope(
                kind: .toolReadResult,
                requestID: requestID,
                lease: lease,
                idempotencyKey: idempotencyKey,
                body: .toolReadResult(result)
            ), on: connectionID)
        case .toolEdit:
            guard case .toolEdit(let request) = envelope.body else { throw DroneProtocolError.malformedMessage }
            let result = try await tools.edit(request, context: context)
            try await send(DroneEnvelope(
                kind: .toolEditResult,
                requestID: requestID,
                lease: lease,
                idempotencyKey: idempotencyKey,
                body: .toolEditResult(result)
            ), on: connectionID)
        case .toolRun:
            guard case .toolRun(let request) = envelope.body else { throw DroneProtocolError.malformedMessage }
            try registerToolOperation(envelope)
            do {
                let stream = try await tools.run(request, context: context)
                try await streamTool(stream, envelope: envelope, connectionID: connectionID)
            } catch {
                toolOperations.removeValue(forKey: requestID)
                throw error
            }
        case .toolDiff:
            guard case .toolDiff(let request) = envelope.body else { throw DroneProtocolError.malformedMessage }
            try registerToolOperation(envelope)
            do {
                let stream = try await tools.diff(request, context: context)
                try await streamTool(stream, envelope: envelope, connectionID: connectionID)
            } catch {
                toolOperations.removeValue(forKey: requestID)
                throw error
            }
        case .toolAttach:
            guard case .toolAttach(let attach) = envelope.body,
                  let history = toolHistories[attach.originalRequestID],
                  attach.nextSequence <= UInt64(history.count)
            else { throw DroneProtocolError.invalidIdentifier }
            try DroneToolWorkerAuthorization.authorizeReplay(
                storedLease: history.first?.lease,
                requestingLease: lease
            )
            var offsets = DroneToolStreamOffsets()
            for event in history.prefix(Int(attach.nextSequence)) {
                guard case .toolOutput(let output) = event.body else { throw DroneProtocolError.malformedMessage }
                offsets[output.stream] += UInt64(output.data.count)
            }
            guard offsets == attach.offsets else { throw DroneProtocolError.invalidState }
            try await send(DroneEnvelope(
                kind: .toolAttached,
                requestID: requestID,
                lease: lease,
                idempotencyKey: idempotencyKey
            ), on: connectionID)
            for event in history.dropFirst(Int(attach.nextSequence)) {
                try await send(event, on: connectionID)
            }
        case .toolCancel:
            guard case .toolCancel(let cancel) = envelope.body else { throw DroneProtocolError.malformedMessage }
            try DroneToolWorkerAuthorization.authorizeReplay(
                storedLease: toolOperations[cancel.operationRequestID]?.lease,
                requestingLease: lease
            )
            try await tools.cancel(context: context, operationRequestID: cancel.operationRequestID)
            onAudit?("job.cancelled")
            try await send(DroneEnvelope(
                kind: .toolCancelled,
                requestID: requestID,
                lease: lease,
                idempotencyKey: idempotencyKey
            ), on: connectionID)
        default:
            throw DroneProtocolError.malformedMessage
        }
    }

    private func registerToolOperation(_ envelope: DroneEnvelope) throws {
        guard let id = envelope.requestID else { throw DroneProtocolError.malformedMessage }
        if let existing = toolOperations[id] {
            guard existing == envelope else { throw DroneProtocolError.idempotencyConflict }
            return
        }
        if toolOperations.count >= 128, let completed = toolHistoryOrder.first {
            toolHistoryOrder.removeFirst()
            toolHistories.removeValue(forKey: completed)
            toolOperations.removeValue(forKey: completed)
        }
        guard toolOperations.count < 128 else { throw DroneProtocolError.resourceLimit }
        toolOperations[id] = envelope
    }

    private func streamTool(
        _ stream: AsyncThrowingStream<DroneToolEvent, Error>,
        envelope: DroneEnvelope,
        connectionID: DroneConnectionID
    ) async throws {
        guard let requestID = envelope.requestID, let lease = envelope.lease,
              let key = envelope.idempotencyKey
        else { throw DroneProtocolError.malformedMessage }
        onAudit?("job.accepted")
        try await send(DroneEnvelope(
            kind: .toolAccepted,
            requestID: requestID,
            lease: lease,
            idempotencyKey: key
        ), on: connectionID)
        var history: [DroneEnvelope] = []
        for try await event in stream {
            let response: DroneEnvelope
            switch event {
            case .output(let output):
                response = DroneEnvelope(
                    kind: .toolOutput,
                    requestID: requestID,
                    lease: lease,
                    idempotencyKey: key,
                    body: .toolOutput(output)
                )
            case .completed(let completion):
                response = DroneEnvelope(
                    kind: .toolCompletion,
                    requestID: requestID,
                    lease: lease,
                    idempotencyKey: key,
                    body: .toolCompletion(completion)
                )
            }
            history.append(response)
            try await send(response, on: connectionID)
        }
        toolHistories[requestID] = history
        toolHistoryOrder.append(requestID)
        if toolHistoryOrder.count > 128, let expired = toolHistoryOrder.first {
            toolHistoryOrder.removeFirst()
            toolHistories.removeValue(forKey: expired)
            toolOperations.removeValue(forKey: expired)
        }
    }

    private func startOutputPump(
        connectionID: DroneConnectionID,
        sessionID: DroneSessionID,
        pairingID: UUID
    ) {
        let key = DroneWorkerTerminalPumps.Key(connectionID: connectionID, sessionID: sessionID)
        guard !outputPumps.contains(key) else { return }
        let generation = UUID()
        let task = Task {
            defer { outputPumps.finish(key, generation: generation) }
            while !Task.isCancelled {
                do {
                    let page = try await terminals.readOutput(
                        sessionID,
                        pairingID: pairingID,
                        connectionID: connectionID.rawValue,
                        maximumChunks: 32
                    )
                    guard !Task.isCancelled else { return }
                    for output in page.chunks {
                        try await send(
                            DroneEnvelope(kind: .output, sessionID: sessionID, body: .output(output)),
                            on: connectionID
                        )
                    }
                    if page.isFinal { return }
                    try await Task.sleep(for: .milliseconds(20))
                } catch {
                    return
                }
            }
        }
        outputPumps.insert(task, key: key, generation: generation)
    }

    private func require(_ permission: DroneControllerPermissions) throws {
        guard permissions.contains(permission) else {
            onAudit?("authorization.failed")
            throw DroneProtocolError.unauthorized
        }
    }

    private static func errorCode(_ error: any Error) -> String {
        let code = String(describing: error).filter { $0.isLetter || $0.isNumber || $0 == "_" }
        return code.isEmpty ? "remoteRejected" : String(code.prefix(64))
    }

    private func send(_ envelope: DroneEnvelope, on connectionID: DroneConnectionID) async throws {
        try envelope.validate()
        transport.send(envelope, on: connectionID)
    }
}

/// Actor-owned pump bookkeeping; a connection may attach several independent sessions.
struct DroneWorkerTerminalPumps {
    struct Key: Hashable {
        let connectionID: DroneConnectionID
        let sessionID: DroneSessionID
    }

    private struct Entry {
        let generation: UUID
        let task: Task<Void, Never>
    }

    private var entries: [Key: Entry] = [:]

    func contains(_ key: Key) -> Bool { entries[key] != nil }

    mutating func insert(_ task: Task<Void, Never>, key: Key, generation: UUID) {
        entries.removeValue(forKey: key)?.task.cancel()
        entries[key] = Entry(generation: generation, task: task)
    }

    mutating func finish(_ key: Key, generation: UUID) {
        guard entries[key]?.generation == generation else { return }
        entries.removeValue(forKey: key)
    }

    mutating func cancel(connectionID: DroneConnectionID, sessionID: DroneSessionID) {
        entries.removeValue(forKey: Key(connectionID: connectionID, sessionID: sessionID))?.task.cancel()
    }

    mutating func cancel(connectionID: DroneConnectionID) {
        let keys = entries.keys.filter { $0.connectionID == connectionID }
        for key in keys { entries.removeValue(forKey: key)?.task.cancel() }
    }

    mutating func cancelAll() {
        for entry in entries.values { entry.task.cancel() }
        entries.removeAll()
    }
}
