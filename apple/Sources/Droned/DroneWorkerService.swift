import Foundation

actor DroneWorkerService: DroneWorkerHealthReporting {
    private let transport: DroneLANTransport
    private let terminals: DroneTerminalEngine
    private let jobs: DroneJobEngine
    private let tools: DroneJobToolEngine
    private let pairingStore: DronePairingStore
    private let healthProbeDirectory: URL
    private var listenerReady = false
    private var storageHealthy = true
    private var stopping = false
    private var revokedControllers = Set<UUID>()
    private let permissionCeiling: DroneControllerPermissions
    private var controllerGrants: [UUID: DroneControllerPermissions] = [:]
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
        pairingStore: DronePairingStore? = nil,
        permissions: DroneControllerPermissions = [],
        onAudit: (@Sendable (String) -> Void)? = nil
    ) throws {
        self.transport = transport ?? DroneLANTransport(role: .worker)
        self.pairingStore = pairingStore ?? DronePairingStore(role: .worker)
        healthProbeDirectory = stateDirectory
        permissionCeiling = permissions
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

    func grantController(
        _ controllerID: UUID,
        permissions requested: DroneControllerPermissions
    ) async throws {
        guard !stopping, !revokedControllers.contains(controllerID),
              pairings.values.contains(controllerID), !requested.isEmpty,
              requested.isSubset(of: permissionCeiling)
        else { throw DroneProtocolError.unauthorized }
        if let removed = controllerGrants[controllerID]?.subtracting(requested), !removed.isEmpty {
            await revokeControllerGrants(controllerID, permissions: removed)
        }
        controllerGrants[controllerID] = requested
        onAudit?("controller.granted")
    }

    func revokeControllerGrants(
        _ controllerID: UUID,
        permissions revoked: DroneControllerPermissions = .all
    ) async {
        guard !revoked.isEmpty else { return }
        controllerGrants[controllerID]?.subtract(revoked)
        if controllerGrants[controllerID]?.isEmpty == true {
            controllerGrants.removeValue(forKey: controllerID)
        }
        onAudit?("controller.grants.revoked")
        guard revoked.contains(.terminal) else { return }
        let connections = pairings.filter { $0.value == controllerID }.map(\.key)
        for connection in connections {
            outputPumps.cancel(connectionID: connection)
            await terminals.disconnect(pairingID: controllerID, connectionID: connection.rawValue)
        }
    }

    /// Trusted local control API, never invoked by a remote tool request.
    func issueToolLease(
        controllerID: UUID,
        workspaceID: UUID = DroneWorkspaceIDs.default,
        permissions requested: DroneControllerPermissions,
        lifetime: TimeInterval = 300
    ) throws -> DroneToolLease {
        guard !stopping, !revokedControllers.contains(controllerID),
              pairings.values.contains(controllerID), workspaceID == DroneWorkspaceIDs.default,
              requested.isSubset(of: permissionCeiling)
        else { throw DroneProtocolError.unauthorized }
        let lease = try toolLeases.issue(
            controllerID: controllerID, workspaceID: workspaceID,
            permissions: requested, lifetime: lifetime, now: Date().timeIntervalSince1970
        )
        onAudit?("toolLease.issued")
        return lease
    }

    func ownerControl(_ request: DroneControlRequest) async throws -> DroneControlToolLease? {
        try request.validate()
        switch request.command {
        case "grant", "revoke-grants":
            guard let controller = request.controllerID, let names = request.permissions else {
                throw DroneWorkerError.invalidArguments
            }
            var requested: DroneControllerPermissions = []
            if names.contains("terminal") { requested.insert(.terminal) }
            if names.contains("files") { requested.insert(.files) }
            if names.contains("jobs") { requested.insert(.jobs) }
            if names.contains("git") { requested.insert(.git) }
            if request.command == "grant" {
                try await grantController(controller, permissions: requested)
            } else {
                await revokeControllerGrants(controller, permissions: requested)
            }
            return nil
        case "grant-tools":
            guard let controller = request.controllerID, let workspace = request.workspaceID,
                  let names = request.permissions, let lifetime = request.lifetimeSeconds else {
                throw DroneWorkerError.invalidArguments
            }
            var allowed: DroneControllerPermissions = []
            if names.contains("files") { allowed.insert(.files) }
            if names.contains("jobs") { allowed.insert(.jobs) }
            if names.contains("git") { allowed.insert(.git) }
            let lease = try issueToolLease(
                controllerID: controller, workspaceID: workspace, permissions: allowed, lifetime: TimeInterval(lifetime)
            )
            return DroneControlToolLease(
                id: lease.id, controllerID: lease.controllerID, droneID: lease.droneID,
                jobID: .init(rawValue: lease.jobID.rawValue), workspaceID: lease.workspaceID, expiresAt: lease.expiresAt
            )
        case "revoke":
            guard let controller = request.controllerID else { throw DroneWorkerError.invalidArguments }
            try await revokeController(controller)
            return nil
        default: throw DroneWorkerError.invalidArguments
        }
    }

    func connectedControllerIDs() -> [UUID] {
        Array(Set(pairings.values)).sorted { $0.uuidString < $1.uuidString }
    }

    func healthSnapshot() async -> DroneWorkerHealthSnapshot {
        var paired = false
        do {
            for id in try pairingStore.pairedPeerIDs() {
                if try pairingStore.pinnedKey(for: id) != nil { paired = true }
            }
            let probe = healthProbeDirectory.appendingPathComponent(".health-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: probe) }
            try Data([0]).write(to: probe, options: .atomic)
        } catch {
            storageHealthy = false
        }
        return DroneWorkerHealthSnapshot(
            listenerReady: listenerReady && !stopping, paired: paired, storageHealthy: storageHealthy
        )
    }

    /// Revoke locally before any suspension; accepted edits retain their durable outcome.
    /// Running tool processes are cancelled; detached user terminals are not terminated.
    func revokeController(_ controllerID: UUID) async throws {
        revokedControllers.insert(controllerID)
        controllerGrants.removeValue(forKey: controllerID)
        toolLeases.revoke(controllerID: controllerID)
        let connections = pairings.filter { $0.value == controllerID }.map(\.key)
        for connection in connections {
            pairings.removeValue(forKey: connection)
            outputPumps.cancel(connectionID: connection)
        }
        let operations = toolOperations.values.filter { $0.lease?.controllerID == controllerID }
        toolHistories = toolHistories.filter { $0.value.first?.lease?.controllerID != controllerID }
        toolHistoryOrder.removeAll { toolHistories[$0] == nil }
        onAudit?("controller.revoked")
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                transport.revoke(DronePeerID(rawValue: controllerID)) { result in
                    continuation.resume(with: result.mapError { $0 as any Error })
                }
            }
        } catch {
            storageHealthy = false
            onAudit?("revocation.storageFailed")
            // Local denial remains active even when persistent pin removal failed.
            await cancelRevokedOperations(operations)
            for connection in connections {
                await terminals.disconnect(pairingID: controllerID, connectionID: connection.rawValue)
            }
            throw error
        }
        await cancelRevokedOperations(operations)
        for connection in connections {
            await terminals.disconnect(pairingID: controllerID, connectionID: connection.rawValue)
        }
    }

    private func cancelRevokedOperations(_ operations: [DroneEnvelope]) async {
        for operation in operations {
            guard let lease = operation.lease, let id = operation.requestID else { continue }
            do {
                try await tools.cancelOwnedOperation(lease: lease, operationRequestID: id)
            } catch {
                onAudit?("revocation.cancelIncomplete")
            }
        }
    }

    func setOnListening(_ handler: @escaping @Sendable (UInt16) -> Void) {
        onListening = handler
    }

    func start(bonjourInstanceID: String) {
        guard !stopping else { return }
        listenerReady = false
        transport.onEvent = { [weak self] event in
            Task { await self?.handle(event) }
        }
        transport.startListening(bonjourInstanceID: bonjourInstanceID)
    }

    func stop() async {
        stopping = true
        listenerReady = false
        for controller in Set(pairings.values) { toolLeases.revoke(controllerID: controller) }
        controllerGrants.removeAll()
        pairings.removeAll()
        if !(await jobs.shutdown()) {
            storageHealthy = false
            onAudit?("shutdown.incomplete")
        }
        outputPumps.cancelAll()
        transport.stop()
        await terminals.shutdown()
    }

    func approvalSummaries() async -> [DroneApprovalSummary] {
        await retireEndedApprovals()
        return approvals.values.map {
            DroneApprovalSummary(
                requestID: $0.id,
                verificationCode: $0.verificationCode,
                isKeyChange: $0.isKeyChange
            )
        }.sorted { $0.requestID.uuidString < $1.requestID.uuidString }
    }

    private func retireEndedApprovals() async {
        // Only examine prompts present before suspension. A newer request may
        // arrive while the transport snapshot is in flight and must survive.
        let candidates = Set(approvals.keys)
        let pending = await transport.pendingPairingRequestIDs()
        for id in candidates.subtracting(pending) { approvals.removeValue(forKey: id) }
    }

    func resolvePairing(requestID: UUID, approved: Bool) {
        if let request = approvals.removeValue(forKey: requestID), approved {
            revokedControllers.remove(request.peerID.rawValue)
        }
        onAudit?(approved ? "pairing.approved" : "pairing.rejected")
        transport.resolvePairing(requestID: requestID, approved: approved)
    }

    private func handle(_ event: DroneTransportEvent) async {
        switch event {
        case .listening(let port):
            guard !stopping else { return }
            listenerReady = true
            onListening?(port)
        case .connecting:
            break
        case .connected(let id, let peerID, _):
            guard !stopping, !revokedControllers.contains(peerID.rawValue) else {
                transport.disconnect(id)
                return
            }
            pairings[id] = peerID.rawValue
        case .pairingRequired(let request):
            approvals[request.id] = request
        case .envelope(let id, _, let envelope):
            Task { await self.handle(envelope, connectionID: id) }
        case .disconnected(let id, _):
            await retireEndedApprovals()
            if let pairingID = pairings.removeValue(forKey: id) {
                outputPumps.cancel(connectionID: id)
                Task { await terminals.disconnect(pairingID: pairingID, connectionID: id.rawValue) }
            }
        case .failed(let id, let failure):
            await retireEndedApprovals()
            // Nil IDs also describe rejected owner requests and admission
            // limits; only listener startup/failure events invalidate readiness.
            if id == nil && [.disconnected, .invalidRole, .invalidBonjourInstance].contains(failure) {
                listenerReady = false
            }
            if failure == .storage { storageHealthy = false }
            if let id, let pairingID = pairings.removeValue(forKey: id) {
                outputPumps.cancel(connectionID: id)
                Task { await terminals.disconnect(pairingID: pairingID, connectionID: id.rawValue) }
            }
        }
    }

    private func handle(_ envelope: DroneEnvelope, connectionID: DroneConnectionID) async {
        guard !stopping, let pairingID = pairings[connectionID],
              !revokedControllers.contains(pairingID) else { return }
        do {
            if envelope.kind == .heartbeat { return }
            if envelope.kind.isTool {
                try await handleTool(envelope, connectionID: connectionID, pairingID: pairingID)
                return
            }
            try require(.terminal, controllerID: pairingID)
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
            if (error as? DroneProtocolError) == .unauthorized || (error as? DroneJobError) == .unauthorized {
                onAudit?("authorization.failed")
            }
            if (error as? DroneJobError) == .storeCorrupted { storageHealthy = false }
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
            let stream: AsyncThrowingStream<DroneToolEvent, Error>
            do {
                stream = try await tools.run(request, context: context)
            } catch {
                toolOperations.removeValue(forKey: requestID)
                throw error
            }
            // Execution ownership outlives delivery to this connection.
            try await streamTool(stream, envelope: envelope, connectionID: connectionID)
        case .toolDiff:
            guard case .toolDiff(let request) = envelope.body else { throw DroneProtocolError.malformedMessage }
            try registerToolOperation(envelope)
            let stream: AsyncThrowingStream<DroneToolEvent, Error>
            do {
                stream = try await tools.diff(request, context: context)
            } catch {
                toolOperations.removeValue(forKey: requestID)
                throw error
            }
            // Execution ownership outlives delivery to this connection.
            try await streamTool(stream, envelope: envelope, connectionID: connectionID)
        case .toolAttach:
            guard case .toolAttach(let attach) = envelope.body else {
                throw DroneProtocolError.malformedMessage
            }
            if let history = toolHistories[attach.originalRequestID] {
                guard attach.nextSequence <= UInt64(history.count) else {
                    throw DroneProtocolError.invalidIdentifier
                }
                try DroneToolWorkerAuthorization.authorizeReplay(
                    storedLease: history.first?.lease,
                    requestingLease: lease
                )
                guard let original = toolOperations[attach.originalRequestID],
                      let permission = Self.toolPermission(for: original.kind)
                else { throw DroneProtocolError.unauthorized }
                try toolLeases.authorizeReplay(
                    permission: permission,
                    lease: lease,
                    now: Date().timeIntervalSince1970
                )
                var offsets = DroneToolStreamOffsets()
                for event in history.prefix(Int(attach.nextSequence)) {
                    guard case .toolOutput(let output) = event.body else {
                        throw DroneProtocolError.malformedMessage
                    }
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
                    try await send(DroneEnvelope(
                        kind: event.kind,
                        requestID: event.requestID,
                        sessionID: event.sessionID,
                        lease: lease,
                        idempotencyKey: event.idempotencyKey,
                        body: event.body
                    ), on: connectionID)
                }
            } else {
                let replay = try await tools.attach(attach, context: context)
                try toolLeases.authorizeReplay(
                    permission: replay.permission,
                    lease: lease,
                    now: Date().timeIntervalSince1970
                )
                try await send(DroneEnvelope(
                    kind: .toolAttached,
                    requestID: requestID,
                    lease: lease,
                    idempotencyKey: idempotencyKey
                ), on: connectionID)
                for try await event in replay.events {
                    let response: DroneEnvelope
                    switch event {
                    case .output(let output):
                        response = DroneEnvelope(
                            kind: .toolOutput,
                            requestID: replay.originalRequestID,
                            lease: lease,
                            idempotencyKey: replay.idempotencyKey,
                            body: .toolOutput(output)
                        )
                    case .completed(let completion):
                        response = DroneEnvelope(
                            kind: .toolCompletion,
                            requestID: replay.originalRequestID,
                            lease: lease,
                            idempotencyKey: replay.idempotencyKey,
                            body: .toolCompletion(completion)
                        )
                    }
                    try await deliverTool(response, on: connectionID)
                }
            }
        case .toolCancel:
            guard case .toolCancel(let cancel) = envelope.body else { throw DroneProtocolError.malformedMessage }
            let permission = try await tools.operationPermission(
                context: context,
                operationRequestID: cancel.operationRequestID
            )
            try toolLeases.authorizeReplay(
                permission: permission,
                lease: lease,
                now: Date().timeIntervalSince1970
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
            guard existing.version == envelope.version,
                  existing.kind == envelope.kind,
                  existing.sessionID == envelope.sessionID,
                  existing.idempotencyKey == envelope.idempotencyKey,
                  existing.body == envelope.body,
                  existing.lease?.controllerID == envelope.lease?.controllerID,
                  existing.lease?.droneID == envelope.lease?.droneID,
                  existing.lease?.workspaceID == envelope.lease?.workspaceID
            else { throw DroneProtocolError.idempotencyConflict }
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
        try await deliverTool(DroneEnvelope(
            kind: .toolAccepted,
            requestID: requestID,
            lease: lease,
            idempotencyKey: key
        ), on: connectionID)
        var history: [DroneEnvelope] = []
        for try await event in stream {
            guard !revokedControllers.contains(lease.controllerID) else { continue }
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
            try await deliverTool(response, on: connectionID)
        }
        guard !revokedControllers.contains(lease.controllerID) else {
            toolOperations.removeValue(forKey: requestID)
            return
        }
        toolHistories[requestID] = history
        toolHistoryOrder.append(requestID)
        if toolHistoryOrder.count > 128, let expired = toolHistoryOrder.first {
            toolHistoryOrder.removeFirst()
            toolHistories.removeValue(forKey: expired)
            toolOperations.removeValue(forKey: expired)
        }
    }

    private func deliverTool(_ envelope: DroneEnvelope, on connectionID: DroneConnectionID) async throws {
        do {
            try await send(envelope, on: connectionID)
        } catch DroneProtocolError.disconnected {
            // Keep draining the bounded observer to terminal state and retaining
            // owner cancellation authority, even when its subscriber goes away.
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

    private func require(
        _ permission: DroneControllerPermissions,
        controllerID: UUID
    ) throws {
        guard controllerGrants[controllerID]?.contains(permission) == true else {
            onAudit?("authorization.failed")
            throw DroneProtocolError.unauthorized
        }
    }

    private static func toolPermission(for kind: DroneMessageKind) -> DroneControllerPermissions? {
        switch kind {
        case .toolRun: .jobs
        case .toolDiff: .git
        default: nil
        }
    }

    private static func errorCode(_ error: any Error) -> String {
        // Only payload-free protocol/job enums may be reflected onto the wire.
        if let code = error as? DroneProtocolError { return String(describing: code) }
        if let code = error as? DroneJobError { return String(describing: code) }
        return "remoteRejected"
    }

    private func send(_ envelope: DroneEnvelope, on connectionID: DroneConnectionID) async throws {
        guard !stopping, let controller = pairings[connectionID],
              !revokedControllers.contains(controller) else { throw DroneProtocolError.disconnected }
        if !envelope.kind.isTool && envelope.kind != .error {
            guard controllerGrants[controller]?.contains(.terminal) == true else {
                throw DroneProtocolError.disconnected
            }
        }
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
