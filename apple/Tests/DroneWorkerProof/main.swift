import Darwin
import Foundation

@main
enum DroneWorkerProof {
    static func main() async throws {
        await verifyTerminalPumps()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("drone-worker-proof-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let reviewIndex = CommandLine.arguments.firstIndex(of: "--review-case")
        let reviewCase = reviewIndex.flatMap { index in
            CommandLine.arguments.indices.contains(index + 1) ? CommandLine.arguments[index + 1] : nil
        }
        let replayOnly = CommandLine.arguments.contains("--tool-replay-authorization") || reviewCase != nil
        try prepareWorkspace(workspace, includeGit: !replayOnly)
        let workerIdentityStorage = ProofPairingStorage()
        let workerIdentity = DroneIdentityStore(role: .worker, storage: workerIdentityStorage)
        let workerID = try workerIdentity.loadOrCreatePeerID().rawValue
        let workerPairingStorage = ProofPairingStorage()
        let workerTransport = DroneLANTransport(
            role: .worker,
            identityStore: workerIdentity,
            pairingStore: DronePairingStore(role: .worker, storage: workerPairingStorage)
        )
        let service = try DroneWorkerService(
            workspace: workspace,
            stateDirectory: root.appendingPathComponent("state", isDirectory: true),
            transport: workerTransport,
            workerID: workerID,
            pairingStore: DronePairingStore(role: .worker, storage: workerPairingStorage),
            permissions: .all
        )
        let beforeStart = await service.healthSnapshot()
        expect(!beforeStart.listenerReady && !beforeStart.paired && beforeStart.storageHealthy,
               "initial health invented listener or pairing state")
        try await verifyQuarantinedStorageHealth(root: root, workspace: workspace)
        let observed = ProofObserved()
        await service.setOnListening { observed.set(port: $0) }
        await service.start(bonjourInstanceID: "drone-proof-\(UUID().uuidString)")

        let controllerIdentityStorage = ProofPairingStorage()
        let controllerIdentity = DroneIdentityStore(role: .controller, storage: controllerIdentityStorage)
        let controllerID = try controllerIdentity.loadOrCreatePeerID().rawValue
        let controllerPairingStorage = ProofPairingStorage()
        let controllerPairings = DronePairingStore(role: .controller, storage: controllerPairingStorage)
        let controller = DroneLANTransport(
            role: .controller,
            identityStore: controllerIdentity,
            pairingStore: controllerPairings
        )
        controller.onEvent = { event in
            switch event {
            case .pairingRequired(let request):
                controller.resolvePairing(requestID: request.id, approved: true)
            case .connected(let id, _, _):
                observed.set(connectionID: id)
            case .envelope(_, _, let envelope):
                observed.record(envelope)
            default:
                break
            }
        }
        let peerID = DronePeerID()
        var port: UInt16?
        for _ in 0..<200 {
            if let value = observed.port { port = value; break }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard let port else { throw ProofError.failed("worker did not listen") }
        controller.pair(peerID: peerID, host: "127.0.0.1", port: port)

        var connectionID: DroneConnectionID?
        for _ in 0..<400 {
            for approval in await service.approvalSummaries() {
                await service.resolvePairing(requestID: approval.requestID, approved: true)
            }
            if let value = observed.connectionID { connectionID = value; break }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard let connectionID else { throw ProofError.failed("controller did not authenticate") }

        if let reviewCase {
            do {
                switch reviewCase {
                case "expiry":
                    try await verifyExpiredOwnerRevocation(
                        controller: controller, connectionID: connectionID, controllerID: controllerID,
                        service: service, observed: observed,
                        stateDirectory: root.appendingPathComponent("state", isDirectory: true)
                    )
                case "disconnect":
                    try await verifyDisconnectedOwnerRevocation(
                        controller: controller, connectionID: connectionID, controllerID: controllerID,
                        service: service, observed: observed, port: port
                    )
                case "stale-approval":
                    try await verifyStaleApproval(service: service, port: port)
                case "durable-replay":
                    try await verifyDurableWorkerRestart(
                        controller: controller,
                        connectionID: connectionID,
                        controllerID: controllerID,
                        peerID: peerID,
                        service: service,
                        observed: observed,
                        workspace: workspace,
                        stateDirectory: root.appendingPathComponent("state", isDirectory: true),
                        workerID: workerID,
                        workerIdentityStorage: workerIdentityStorage,
                        workerPairingStorage: workerPairingStorage,
                        controllerIdentityStorage: controllerIdentityStorage,
                        controllerPairingStorage: controllerPairingStorage
                    )
                default: throw ProofError.failed("unknown review regression")
                }
            } catch {
                controller.stop()
                await service.stop()
                throw error
            }
            controller.stop()
            await service.stop()
            print("Drone worker review regression passed: \(reviewCase).")
            return
        }
        if replayOnly {
            try await verifyControllerGrants(controller: controller, connectionID: connectionID, controllerID: controllerID,
                                             service: service, observed: observed, port: port, workspace: workspace, root: root)
            try await verifyIssuedLeases(
                controller: controller, connectionID: connectionID, controllerID: controllerID,
                service: service, observed: observed
            )
            try await verifyToolReplay(
                controller: controller,
                connectionID: connectionID,
                controllerID: controllerID,
                service: service,
                observed: observed
            )
            try await verifyOwnerControl(service: service, port: port, workspace: workspace)
            try await verifyRevocationAndHealth(
                controller: controller, connectionID: connectionID, controllerID: controllerID,
                service: service, observed: observed, port: port, pairingStorage: workerPairingStorage,
                stateDirectory: root.appendingPathComponent("state", isDirectory: true)
            )
            controller.stop()
            await service.stop()
            print("Drone worker authorization passed: owner CLI/socket grants, issued leases, replay, revocation, health, shutdown, and pump isolation.")
            return
        }

        try await verifyWorkerAgentCycle(
            controller: controller,
            connectionID: connectionID,
            controllerID: controllerID,
            workerID: workerID,
            service: service,
            observed: observed,
            workspace: workspace,
            port: port
        )
        controller.stop()
        await service.stop()
        print("Drone worker proof passed: pairing, encrypted terminal, remote command, and agent tool cycle.")
    }

}

extension DroneWorkerProof {
    private static func verifyWorkerAgentCycle(
        controller: DroneLANTransport,
        connectionID: DroneConnectionID,
        controllerID: UUID,
        workerID: UUID,
        service: DroneWorkerService,
        observed: ProofObserved,
        workspace: URL,
        port: UInt16
    ) async throws {
        try await service.grantController(controllerID, permissions: .terminal)
        let createRequest = UUID()
        controller.send(DroneEnvelope(
            kind: .create,
            requestID: createRequest,
            idempotencyKey: "worker-proof-create-0001",
            body: .create(DroneCreateBody(
                workspaceID: DroneWorkspaceIDs.default,
                environment: [:],
                columns: 80,
                rows: 24
            ))
        ), on: connectionID)
        var sessionID: DroneSessionID?
        for _ in 0..<200 {
            if let value = observed.createdSession(requestID: createRequest) { sessionID = value; break }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard let sessionID else { throw ProofError.failed("terminal was not created") }
        try await verifyUngrantedInput(service: service, port: port, sessionID: sessionID, workspace: workspace)
        let terminal = try await verifyEncryptedTerminal(
            controller: controller, connectionID: connectionID, controllerID: controllerID,
            workerID: workerID, sessionID: sessionID, workspace: workspace, observed: observed
        )
        let terminalSession = terminal.session
        let terminalConnection = terminal.connection
        let terminalHandler = terminal.handler

        let toolTransport = ProofToolTransport(
            controller: controller,
            connectionID: connectionID,
            controllerID: controllerID,
            droneID: workerID
        )
        observed.onEnvelope = { envelope in
            terminalConnection.yield(envelope)
            toolTransport.handle(envelope)
        }
        let lease = try await service.issueToolLease(
            controllerID: controllerID, permissions: [.files, .jobs, .git]
        )
        let toolClient = try DroneToolClient(transport: toolTransport, lease: lease, now: 1)
        let report = try await DroneAgentDriver(client: toolClient).perform(DroneAgentPlan(
            path: "main.swift",
            oldData: Data("before".utf8),
            newData: Data("after".utf8),
            build: DroneToolProcessRequest(
                executable: "swiftc",
                arguments: ["main.swift", "-o", "tool-app"]
            ),
            test: DroneToolProcessRequest(
                executable: "sh",
                arguments: ["-c", "./tool-app"]
            ),
            diff: DroneToolDiffRequest(paths: ["main.swift"]),
            idempotencyKeyPrefix: "worker-agent-proof-0001"
        ))
        expect(report.build.completion.status == .succeeded, "remote build failed")
        expect(report.test.completion.status == .succeeded, "remote test failed")
        expect(report.test.standardOutput.range(of: Data("drone-tools-after".utf8)) != nil, "remote test output missing")
        expect(report.diff.range(of: Data("drone-tools-after".utf8)) != nil, "remote diff missing edit")

        let closed = await terminalSession.close()
        expect(closed, "encrypted client/session close failed")
        observed.onEnvelope = nil
        terminalHandler.cancel()
    }

    private static func verifyUngrantedInput(
        service: DroneWorkerService,
        port: UInt16,
        sessionID: DroneSessionID,
        workspace: URL
    ) async throws {
        let ungranted = try await connectController(service: service, port: port)
        defer { ungranted.transport.stop() }
        let deniedInput = UUID()
        ungranted.transport.send(DroneEnvelope(
            kind: .input,
            requestID: deniedInput,
            sessionID: sessionID,
            body: .input(DroneInputBody(data: Data("printf denied > denied-input.txt\n".utf8)))
        ), on: ungranted.connectionID)
        try await expectUnauthorized(deniedInput, observed: ungranted.observed)
        try await Task.sleep(for: .milliseconds(100))
        expect(
            !FileManager.default.fileExists(atPath: workspace.appendingPathComponent("denied-input.txt").path),
            "unauthorized controller released terminal input"
        )
    }

    private static func verifyEncryptedTerminal(
        controller: DroneLANTransport,
        connectionID: DroneConnectionID,
        controllerID: UUID,
        workerID: UUID,
        sessionID: DroneSessionID,
        workspace: URL,
        observed: ProofObserved
    ) async throws -> (
        session: DroneTerminalSession,
        connection: ProofTerminalConnection,
        handler: Task<Void, Never>
    ) {
        let gapRequest = UUID()
        controller.send(DroneEnvelope(
            kind: .attach,
            requestID: gapRequest,
            sessionID: sessionID,
            body: .attach(DroneAttachBody(afterSequence: 1, afterOffset: 5))
        ), on: connectionID)
        let gapResponse = try await waitForResponse(gapRequest, kind: .error, observed: observed)
        guard case .error(let gapError) = gapResponse.body, gapError.code == "outputGap", !gapError.retryable else {
            throw ProofError.failed("terminal output gap did not have a stable non-retryable error")
        }

        let terminalConnection = ProofTerminalConnection(
            controller: controller, connectionID: connectionID, controllerID: controllerID, droneID: workerID
        )
        let terminalClient = DroneRemoteTerminalClient(
            droneID: workerID, controllerID: controllerID, connection: terminalConnection
        )
        observed.onEnvelope = { envelope in terminalConnection.yield(envelope) }
        let terminalHandler = Task {
            while !Task.isCancelled {
                do {
                    let envelope = try await terminalConnection.receive()
                    await terminalClient.handle(envelope)
                } catch {
                    break
                }
            }
        }
        let resumeState = DroneTerminalResumeState(sessionID: sessionID.rawValue)
        _ = resumeState.append(DroneOutputBody(
            sequence: 0, offset: 0, data: Data("stale".utf8), isFinal: false
        ))
        let terminalSession = DroneTerminalSession(
            identity: TerminalSessionIdentity(
                paneID: UUID(),
                ownership: TerminalDestination.drone(droneID: workerID).ownership,
                generation: 1
            ),
            remoteSessionID: sessionID.rawValue,
            client: terminalClient,
            resumeState: resumeState
        )
        _ = try await terminalSession.restore(workingDirectory: nil)
        async let olderResize = terminalSession.resize(columns: 80, rows: 24)
        for _ in 0..<200 {
            if terminalConnection.resizeCount == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        expect(terminalConnection.resizeCount == 1, "older resize was not sent")
        async let newerResize = terminalSession.resize(columns: 132, rows: 43)
        let olderResized = await olderResize
        let newerResized = await newerResize
        expect(olderResized && newerResized, "ordered client/session resize failed")
        let sizeRequested = await terminalSession.send(.literal("stty size\n"))
        expect(sizeRequested, "encrypted stty input failed")
        var reportedSize = ""
        for _ in 0..<400 {
            reportedSize = terminalSession.visibleContents() ?? ""
            if reportedSize.contains("43 132") { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        expect(reportedSize.contains("43 132"), "remote PTY did not use resized dimensions: \(reportedSize)")
        expect(!reportedSize.contains("stale"), "resync retained stale controller output")
        let commandSent = await terminalSession.send(.literal("printf 'drone-e2e-✓' > proof.txt\n"))
        expect(commandSent, "encrypted terminal command failed")

        let proofFile = workspace.appendingPathComponent("proof.txt")
        var contents = ""
        for _ in 0..<400 {
            if let data = try? Data(contentsOf: proofFile) {
                contents = String(decoding: data, as: UTF8.self)
                if contents.contains("drone-e2e-✓") { break }
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        expect(contents.contains("drone-e2e-✓"), "remote command did not write expected file")
        return (terminalSession, terminalConnection, terminalHandler)
    }

    private static func prepareWorkspace(_ workspace: URL, includeGit: Bool) throws {
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("print(\"drone-tools-before\")\n".utf8).write(
            to: workspace.appendingPathComponent("main.swift")
        )
        if includeGit {
            try runProcess("/usr/bin/git", ["init", "-q"], directory: workspace)
            try runProcess("/usr/bin/git", ["add", "-N", "main.swift"], directory: workspace)
        }
    }

}

extension DroneWorkerProof {
    private static func verifyDurableWorkerRestart(
        controller: DroneLANTransport,
        connectionID: DroneConnectionID,
        controllerID: UUID,
        peerID: DronePeerID,
        service: DroneWorkerService,
        observed: ProofObserved,
        workspace: URL,
        stateDirectory: URL,
        workerID: UUID,
        workerIdentityStorage: ProofPairingStorage,
        workerPairingStorage: ProofPairingStorage,
        controllerIdentityStorage: ProofPairingStorage,
        controllerPairingStorage: ProofPairingStorage
    ) async throws {
        let lease = try await service.issueToolLease(controllerID: controllerID, permissions: .jobs)
        let operationID = UUID()
        let operationKey = "durable-worker-restart-key"
        let request = DroneToolProcessRequest(
            executable: "sh",
            arguments: ["-c", "printf worker-restart-output; printf x >> worker-restart-count"]
        )
        controller.send(DroneEnvelope(
            kind: .toolRun,
            requestID: operationID,
            lease: lease,
            idempotencyKey: operationKey,
            body: .toolRun(request)
        ), on: connectionID)
        let completion = try await waitForResponse(operationID, kind: .toolCompletion, observed: observed)
        guard case .toolCompletion(let body) = completion.body, body.status == .succeeded else {
            throw ProofError.failed("durable worker fixture failed")
        }
        let countURL = workspace.appendingPathComponent("worker-restart-count")
        expect((try? Data(contentsOf: countURL)) == Data("x".utf8), "worker fixture side effect missing")

        controller.stop()
        await service.stop()

        let restartedTransport = DroneLANTransport(
            role: .worker,
            identityStore: DroneIdentityStore(role: .worker, storage: workerIdentityStorage),
            pairingStore: DronePairingStore(role: .worker, storage: workerPairingStorage)
        )
        let restartedService = try DroneWorkerService(
            workspace: workspace,
            stateDirectory: stateDirectory,
            transport: restartedTransport,
            workerID: workerID,
            pairingStore: DronePairingStore(role: .worker, storage: workerPairingStorage),
            permissions: .all
        )
        let restartedObserved = ProofObserved()
        await restartedService.setOnListening { restartedObserved.set(port: $0) }
        await restartedService.start(bonjourInstanceID: "drone-proof-\(UUID().uuidString)")
        var restartedPort: UInt16?
        for _ in 0..<200 {
            if let value = restartedObserved.port { restartedPort = value; break }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard let restartedPort else { throw ProofError.failed("restarted worker did not listen") }

        let restartedController = DroneLANTransport(
            role: .controller,
            identityStore: DroneIdentityStore(role: .controller, storage: controllerIdentityStorage),
            pairingStore: DronePairingStore(role: .controller, storage: controllerPairingStorage)
        )
        restartedController.onEvent = { event in
            switch event {
            case .pairingRequired(let request):
                restartedController.resolvePairing(requestID: request.id, approved: true)
            case .connected(let id, _, _):
                restartedObserved.set(connectionID: id)
            case .envelope(_, _, let envelope):
                restartedObserved.record(envelope)
            default:
                break
            }
        }
        restartedController.connect(peerID: peerID, host: "127.0.0.1", port: restartedPort)
        var restartedConnectionID: DroneConnectionID?
        for _ in 0..<400 {
            for approval in await restartedService.approvalSummaries() {
                await restartedService.resolvePairing(requestID: approval.requestID, approved: true)
            }
            if let value = restartedObserved.connectionID { restartedConnectionID = value; break }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard let restartedConnectionID else {
            throw ProofError.failed("controller did not reauthenticate after restart")
        }
        let restartedFilesLease = try await restartedService.issueToolLease(
            controllerID: controllerID,
            permissions: .files
        )
        let deniedAttachID = UUID()
        restartedController.send(DroneEnvelope(
            kind: .toolAttach,
            requestID: deniedAttachID,
            lease: restartedFilesLease,
            idempotencyKey: UUID().uuidString,
            body: .toolAttach(DroneToolAttachBody(
                originalRequestID: operationID,
                nextSequence: 0,
                offsets: DroneToolStreamOffsets()
            ))
        ), on: restartedConnectionID)
        try await expectUnauthorized(deniedAttachID, observed: restartedObserved)
        expect(restartedObserved.responses(for: operationID).isEmpty,
               "restart replay ignored operation permissions")
        let freshLease = try await restartedService.issueToolLease(
            controllerID: controllerID,
            permissions: .jobs
        )
        expect(freshLease.id != lease.id && freshLease.jobID != lease.jobID, "restart reused the old grant")
        let attachID = UUID()
        restartedController.send(DroneEnvelope(
            kind: .toolAttach,
            requestID: attachID,
            lease: freshLease,
            idempotencyKey: UUID().uuidString,
            body: .toolAttach(DroneToolAttachBody(
                originalRequestID: operationID,
                nextSequence: 0,
                offsets: DroneToolStreamOffsets()
            ))
        ), on: restartedConnectionID)
        _ = try await waitForResponse(attachID, kind: .toolAttached, observed: restartedObserved)
        for _ in 0..<400 {
            let responses = restartedObserved.responses(for: operationID)
            if responses.contains(where: { $0.kind == .toolCompletion }) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let replayed = restartedObserved.responses(for: operationID)
        expect(replayed.contains { $0.kind == .toolOutput }, "restart lost durable output")
        expect(replayed.contains { $0.kind == .toolCompletion }, "restart lost durable completion")
        expect(replayed.allSatisfy { $0.idempotencyKey == operationKey }, "restart changed response correlation")
        expect(replayed.allSatisfy { $0.lease == freshLease }, "restart replay returned a stale lease")
        expect((try? Data(contentsOf: countURL)) == Data("x".utf8), "replay repeated process side effects")

        let priorCompletions = replayed.filter { $0.kind == .toolCompletion }.count
        restartedController.send(DroneEnvelope(
            kind: .toolRun,
            requestID: operationID,
            lease: freshLease,
            idempotencyKey: operationKey,
            body: .toolRun(request)
        ), on: restartedConnectionID)
        for _ in 0..<400 {
            let count = restartedObserved.responses(for: operationID).filter { $0.kind == .toolCompletion }.count
            if count > priorCompletions { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let retried = restartedObserved.responses(for: operationID)
        expect(retried.filter { $0.kind == .toolCompletion }.count > priorCompletions,
               "same-key retry did not return the durable completion")
        expect((try? Data(contentsOf: countURL)) == Data("x".utf8), "same-key retry repeated process side effects")
        restartedController.stop()
        await restartedService.stop()
    }

}

extension DroneWorkerProof {
    private static func verifyExpiredOwnerRevocation(
        controller: DroneLANTransport, connectionID: DroneConnectionID, controllerID: UUID,
        service: DroneWorkerService, observed: ProofObserved, stateDirectory: URL
    ) async throws {
        let finishedRecords = try await runFinishedJob(
            controller: controller, connectionID: connectionID, controllerID: controllerID,
            service: service, observed: observed, stateDirectory: stateDirectory
        )
        let lease = try await service.issueToolLease(controllerID: controllerID, permissions: .jobs, lifetime: 1)
        let pid = try await startTrackedProcess(
            controller: controller, connectionID: connectionID, lease: lease, observed: observed,
            command: "echo $$; exec sleep 30", timeout: 20
        )
        try await Task.sleep(for: .milliseconds(1_100))
        let remoteCancel = UUID()
        controller.send(DroneEnvelope(
            kind: .toolCancel, requestID: remoteCancel, lease: lease, idempotencyKey: UUID().uuidString,
            body: .toolCancel(DroneToolCancelBody(operationRequestID: UUID()))
        ), on: connectionID)
        try await expectUnauthorized(remoteCancel, observed: observed)
        try await service.revokeController(controllerID)
        try await expectProcessStopped(pid)
        expect(jobRecordNames(stateDirectory: stateDirectory, controllerID: controllerID).isDisjoint(with: finishedRecords),
               "revocation kept the controller's finished job records")
    }

    private static func verifyDisconnectedOwnerRevocation(
        controller: DroneLANTransport, connectionID: DroneConnectionID, controllerID: UUID,
        service: DroneWorkerService, observed: ProofObserved, port: UInt16
    ) async throws {
        let lease = try await service.issueToolLease(controllerID: controllerID, permissions: .jobs)
        let pid = try await startTrackedProcess(
            controller: controller, connectionID: connectionID, lease: lease, observed: observed,
            command: "echo $$; sleep 0.3; echo tick; exec sleep 30", timeout: 20
        )
        controller.disconnect(connectionID)
        for _ in 0..<100 {
            if !(await service.connectedControllerIDs()).contains(controllerID) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        // The second output arrives after the observer has disconnected.
        try await Task.sleep(for: .milliseconds(600))
        try await service.revokeController(controllerID)
        try await expectProcessStopped(pid)
        // Exceed the worker's 128 retained operation slots with disconnected
        // completions. Finished observers must become evictable, not leak slots.
        let next = try await connectController(service: service, port: port)
        defer { next.transport.stop() }
        let nextLease = try await service.issueToolLease(controllerID: next.controllerID, permissions: .jobs)
        var connection = next.connectionID
        for _ in 0..<130 {
            let requestID = UUID()
            next.transport.send(DroneEnvelope(
                kind: .toolRun, requestID: requestID, lease: nextLease, idempotencyKey: UUID().uuidString,
                body: .toolRun(DroneToolProcessRequest(
                    executable: "sh", arguments: ["-c", "sleep 0.05; printf done"], timeout: 2
                ))
            ), on: connection)
            _ = try await waitForResponse(requestID, kind: .toolAccepted, observed: next.observed)
            next.transport.disconnect(connection)
            next.observed.clearConnection()
            try await Task.sleep(for: .milliseconds(200))
            next.transport.connect(peerID: next.peerID, host: "127.0.0.1", port: port)
            var replacement: DroneConnectionID?
            for _ in 0..<200 {
                if let id = next.observed.connectionID, id != connection { replacement = id; break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard let replacement else { throw ProofError.failed("fixture reconnect failed") }
            connection = replacement
        }
    }

    private static func verifyStaleApproval(service: DroneWorkerService, port: UInt16) async throws {
        let identity = DroneIdentityStore(role: .controller, storage: ProofPairingStorage())
        let transport = DroneLANTransport(
            role: .controller, identityStore: identity,
            pairingStore: DronePairingStore(role: .controller, storage: ProofPairingStorage())
        )
        transport.onEvent = { event in
            if case .pairingRequired(let request) = event {
                transport.resolvePairing(requestID: request.id, approved: true)
            }
        }
        transport.pair(peerID: DronePeerID(), host: "127.0.0.1", port: port)
        var requestID: UUID?
        for _ in 0..<200 {
            if let approval = await service.approvalSummaries().first { requestID = approval.requestID; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let requestID else { transport.stop(); throw ProofError.failed("pending pairing fixture missing") }
        transport.stop()
        try await Task.sleep(for: .milliseconds(200))
        let staleWasRetired = !(await service.approvalSummaries()).contains { $0.requestID == requestID }
        await service.resolvePairing(requestID: requestID, approved: true)
        try await Task.sleep(for: .milliseconds(100))
        let health = await service.healthSnapshot()
        guard health.listenerReady else { throw ProofError.failed("stale approval marked live listener unavailable") }
        guard staleWasRetired else { throw ProofError.failed("ended pairing remained in approval summaries") }
        let another = try await connectController(service: service, port: port)
        another.transport.stop()
    }

}

extension DroneWorkerProof {
    private static func verifyControllerGrants(
        controller: DroneLANTransport,
        connectionID: DroneConnectionID,
        controllerID: UUID,
        service: DroneWorkerService,
        observed: ProofObserved,
        port: UInt16,
        workspace: URL,
        root: URL
    ) async throws {
        guard let index = CommandLine.arguments.firstIndex(of: "--proof-cli"),
              CommandLine.arguments.indices.contains(index + 1) else {
            throw ProofError.failed("CLI fixture executable missing")
        }
        let cli = CommandLine.arguments[index + 1]
        let controlRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("grants-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: controlRoot) }
        let paths = DronePaths(environment: [
            "BLAU_DRONE_ROOT": controlRoot.path,
            "BLAU_DRONE_WORKSPACE": workspace.path,
        ])
        let daemon = try DroneDaemon(paths: paths, workerService: service)
        try daemon.startControlListener()
        defer { daemon.stopControlListener() }
        let other = try await connectController(service: service, port: port)
        defer { other.transport.stop() }
        var deniedCreateKeys: [String] = []
        var deniedCreateRequests: [UUID] = []

        for probe in [
            (transport: controller, connectionID: connectionID, observed: observed),
            (transport: other.transport, connectionID: other.connectionID, observed: other.observed),
        ] {
            let requestID = UUID()
            let key = "denied-before-grant-\(UUID().uuidString)"
            deniedCreateKeys.append(key)
            deniedCreateRequests.append(requestID)
            probe.transport.send(DroneEnvelope(
                kind: .create,
                requestID: requestID,
                idempotencyKey: key,
                body: .create(DroneCreateBody(
                    workspaceID: DroneWorkspaceIDs.default,
                    environment: [:],
                    columns: 80,
                    rows: 24
                ))
            ), on: probe.connectionID)
            try await expectUnauthorized(requestID, observed: probe.observed)
        }

        let unknownGrant = try await runCLI(
            cli,
            arguments: ["grant", UUID().uuidString, "terminal"],
            root: controlRoot
        )
        expect(unknownGrant.status != 0, "owner granted an unauthenticated controller")
        let granted = try await runCLI(
            cli,
            arguments: ["grant", controllerID.uuidString, "terminal"],
            root: controlRoot
        )
        expect(
            granted.status == 0 && String(decoding: granted.output, as: UTF8.self) == "granted\n",
            "owner terminal grant failed"
        )
        let otherGranted = try await runCLI(
            cli,
            arguments: ["grant", other.controllerID.uuidString, "jobs"],
            root: controlRoot
        )
        expect(otherGranted.status == 0, "independent controller grant failed")
        try await expectTerminalGrant(controller: controller, observed: observed)

        let terminalKinds: [DroneMessageKind] = [
            .create, .attach, .reconnect, .input, .resize, .detach, .close, .cancel,
            .resync, .fastCommand, .activity, .workingDirectory, .acknowledge,
        ]
        for kind in terminalKinds {
            let requestID = UUID()
            let sessionID = DroneSessionID()
            let key = kind == .create ? "denied-other-\(UUID().uuidString)" : nil
            if let key {
                deniedCreateKeys.append(key)
                deniedCreateRequests.append(requestID)
            }
            let body: DroneEnvelope.Body
            switch kind {
            case .create:
                body = .create(DroneCreateBody(
                    workspaceID: DroneWorkspaceIDs.default,
                    environment: [:],
                    columns: 80,
                    rows: 24
                ))
            case .attach, .reconnect, .acknowledge:
                body = .attach(DroneAttachBody(afterSequence: 0, afterOffset: 0))
            case .input:
                body = .input(DroneInputBody(data: Data("printf denied > denied-replay.txt\n".utf8)))
            case .resize:
                body = .resize(DroneResizeBody(columns: 80, rows: 24))
            case .fastCommand:
                body = .fastCommand(DroneFastCommandBody(command: "printf denied > denied-replay.txt"))
            default:
                body = .empty
            }
            other.transport.send(DroneEnvelope(
                kind: kind,
                requestID: requestID,
                sessionID: kind == .create ? nil : sessionID,
                idempotencyKey: key,
                body: body
            ), on: other.connectionID)
            try await expectUnauthorized(requestID, observed: other.observed)
        }
        expect(
            !FileManager.default.fileExists(atPath: workspace.appendingPathComponent("denied-replay.txt").path),
            "unauthorized non-tool operation released command work"
        )

        other.transport.disconnect(other.connectionID)
        for _ in 0..<100 {
            if !(await service.connectedControllerIDs()).contains(other.controllerID) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let connectedAfterDisconnect = await service.connectedControllerIDs()
        expect(
            !connectedAfterDisconnect.contains(other.controllerID),
            "disconnected grant fixture remained authenticated"
        )
        let otherRevoked = try await runCLI(
            cli,
            arguments: ["revoke-grants", other.controllerID.uuidString, "jobs"],
            root: controlRoot
        )
        expect(otherRevoked.status == 0, "independent grant revocation failed")
        try await expectTerminalGrant(controller: controller, observed: observed)

        let firstRevoked = try await runCLI(
            cli,
            arguments: ["revoke-grants", controllerID.uuidString, "terminal"],
            root: controlRoot
        )
        expect(
            firstRevoked.status == 0 && String(decoding: firstRevoked.output, as: UTF8.self) == "grants revoked\n",
            "terminal grant revocation failed"
        )
        let revokedCreate = UUID()
        let revokedKey = "denied-after-revoke-\(UUID().uuidString)"
        deniedCreateKeys.append(revokedKey)
        deniedCreateRequests.append(revokedCreate)
        controller.send(DroneEnvelope(
            kind: .create,
            requestID: revokedCreate,
            idempotencyKey: revokedKey,
            body: .create(DroneCreateBody(
                workspaceID: DroneWorkspaceIDs.default,
                environment: [:],
                columns: 80,
                rows: 24
            ))
        ), on: connectionID)
        try await expectUnauthorized(revokedCreate, observed: observed)

        let regranted = try await runCLI(
            cli,
            arguments: ["grant", controllerID.uuidString, "terminal"],
            root: controlRoot
        )
        expect(regranted.status == 0, "controller could not be regranted after permission revocation")
        let replaced = try await runCLI(
            cli,
            arguments: ["grant", controllerID.uuidString, "jobs"],
            root: controlRoot
        )
        expect(replaced.status == 0, "controller grant replacement failed")
        let replacedProbe = UUID()
        controller.send(DroneEnvelope(
            kind: .activity,
            requestID: replacedProbe,
            sessionID: DroneSessionID()
        ), on: connectionID)
        try await expectUnauthorized(replacedProbe, observed: observed)
        let restored = try await runCLI(
            cli,
            arguments: ["grant", controllerID.uuidString, "terminal"],
            root: controlRoot
        )
        expect(restored.status == 0, "controller terminal grant was not restored")
        try await service.revokeController(other.controllerID)
        try await expectTerminalGrant(controller: controller, observed: observed)
        await service.revokeControllerGrants(controllerID, permissions: .terminal)

        let catalogURL = root.appendingPathComponent("state/terminals/terminals.json")
        let catalog = (try? Data(contentsOf: catalogURL)) ?? Data()
        for key in deniedCreateKeys {
            expect(!catalog.contains(Data(key.utf8)), "denied create reached terminal idempotency state")
        }
        for requestID in deniedCreateRequests {
            expect(
                observed.createdSession(requestID: requestID) == nil
                    && other.observed.createdSession(requestID: requestID) == nil,
                "denied create released a session"
            )
        }
    }

}

extension DroneWorkerProof {
    private static func verifyOwnerControl(service: DroneWorkerService, port: UInt16, workspace: URL) async throws {
        guard let index = CommandLine.arguments.firstIndex(of: "--proof-cli"),
              CommandLine.arguments.indices.contains(index + 1) else {
            throw ProofError.failed("CLI fixture executable missing")
        }
        let cli = CommandLine.arguments[index + 1]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctl-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = DronePaths(environment: ["BLAU_DRONE_ROOT": root.path, "BLAU_DRONE_WORKSPACE": workspace.path])
        let daemon = try DroneDaemon(paths: paths, workerService: service)
        try daemon.startControlListener()
        defer { daemon.stopControlListener() }
        var socketInfo = stat()
        expect(lstat(paths.controlSocket.path, &socketInfo) == 0 && socketInfo.st_mode & 0o777 == 0o600,
               "owner control socket is not private")
        let controller = try await connectController(service: service, port: port)
        defer { controller.transport.stop() }
        let listed = try await runCLI(cli, arguments: ["controllers"], root: root)
        expect(listed.status == 0 && String(decoding: listed.output, as: UTF8.self).contains(controller.controllerID.uuidString),
               "owner cannot discover connected controller IDs")
        let grantArgs = [
            "grant-tools", controller.controllerID.uuidString, DroneWorkspaceIDs.default.uuidString, "files", "60",
        ]
        let granted = try await runCLI(cli, arguments: grantArgs, root: root)
        expect(granted.status == 0, "owner grant CLI failed")
        let lease = try JSONDecoder().decode(DroneToolLease.self, from: granted.output)
        expect(lease.controllerID == controller.controllerID && lease.expiresAt > Date().timeIntervalSince1970,
               "CLI lease did not preserve identity/expiry")
        let id = UUID()
        controller.transport.send(DroneEnvelope(
            kind: .toolRead, requestID: id, lease: lease, idempotencyKey: UUID().uuidString,
            body: .toolRead(DroneToolReadRequest(path: "main.swift", maxBytes: 1_024))
        ), on: controller.connectionID)
        _ = try await waitForResponse(id, kind: .toolReadResult, observed: controller.observed)
        for invalid in [
            ["revoke", "not-a-uuid"],
            Array(grantArgs.dropLast()) + ["901"],
            ["grant-tools", controller.controllerID.uuidString, DroneWorkspaceIDs.default.uuidString, "files,files", "60"],
        ] {
            let result = try await runCLI(cli, arguments: invalid, root: root)
            expect(result.status == 64 && result.output.isEmpty, "invalid owner command did not fail before execution")
        }
        let revoked = try await runCLI(cli, arguments: ["revoke", controller.controllerID.uuidString], root: root)
        expect(revoked.status == 0 && String(decoding: revoked.output, as: UTF8.self) == "revoked\n",
               "owner revoke CLI did not confirm durable removal")
        do {
            _ = try await service.issueToolLease(controllerID: controller.controllerID, permissions: .files)
            throw ProofError.failed("CLI revocation left controller authorized")
        } catch DroneProtocolError.unauthorized {}
    }

    private static func runCLI(_ executable: String, arguments: [String], root: URL) async throws -> ProofCLIResult {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = [
                "PATH": "/usr/bin:/bin", "HOME": root.path,
                "TMPDIR": FileManager.default.temporaryDirectory.path, "BLAU_DRONE_ROOT": root.path,
            ]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return ProofCLIResult(status: process.terminationStatus, output: bytes)
        }.value
    }

    private static func verifyRevocationAndHealth(
        controller: DroneLANTransport,
        connectionID: DroneConnectionID,
        controllerID: UUID,
        service: DroneWorkerService,
        observed: ProofObserved,
        port: UInt16,
        pairingStorage: ProofPairingStorage,
        stateDirectory: URL
    ) async throws {
        let initial = await service.healthSnapshot()
        expect(initial.listenerReady && initial.paired && initial.storageHealthy, "live health was not truthful")
        let other = try await connectController(service: service, port: port)
        defer { other.transport.stop() }
        let lease = try await service.issueToolLease(controllerID: controllerID, permissions: [.files, .jobs])
        let foreignRead = UUID()
        other.transport.send(DroneEnvelope(
            kind: .toolRead, requestID: foreignRead, lease: lease, idempotencyKey: UUID().uuidString,
            body: .toolRead(DroneToolReadRequest(path: "main.swift", maxBytes: 1_024))
        ), on: other.connectionID)
        try await expectUnauthorized(foreignRead, observed: other.observed)
        let finishedRecords = try await runFinishedJob(
            controller: controller, connectionID: connectionID, controllerID: controllerID,
            service: service, observed: observed, stateDirectory: stateDirectory
        )
        let pid = try await startTrackedProcess(
            controller: controller, connectionID: connectionID, lease: lease, observed: observed
        )
        pairingStorage.setFailDeletes(true)
        do {
            try await service.revokeController(controllerID)
            throw ProofError.failed("persistent revocation failure was reported as success")
        } catch DroneTransportFailure.storage {}
        let failed = await service.healthSnapshot()
        expect(!failed.storageHealthy, "revocation storage failure was hidden from health")
        // Pin removal failed, but the local revocation still deletes job records.
        expect(jobRecordNames(stateDirectory: stateDirectory, controllerID: controllerID).isDisjoint(with: finishedRecords),
               "failed revocation kept the controller's finished job records")
        do {
            _ = try await service.issueToolLease(controllerID: controllerID, permissions: .files)
            throw ProofError.failed("revoked controller obtained a fresh grant")
        } catch DroneProtocolError.unauthorized {}
        try await expectProcessStopped(pid)
        pairingStorage.setFailDeletes(false)
        try await service.revokeController(controllerID)
        let recoveredIO = await service.healthSnapshot()
        expect(!recoveredIO.storageHealthy, "transient success cleared latched storage failure without restart")
        let otherLease = try await service.issueToolLease(
            controllerID: other.controllerID, permissions: [.files, .jobs]
        )
        let readID = UUID()
        other.transport.send(DroneEnvelope(
            kind: .toolRead, requestID: readID, lease: otherLease, idempotencyKey: UUID().uuidString,
            body: .toolRead(DroneToolReadRequest(path: "main.swift", maxBytes: 1_024))
        ), on: other.connectionID)
        _ = try await waitForResponse(readID, kind: .toolReadResult, observed: other.observed)
        let shutdownPID = try await startTrackedProcess(
            controller: other.transport, connectionID: other.connectionID,
            lease: otherLease, observed: other.observed
        )
        await service.stop()
        try await expectProcessStopped(shutdownPID)
        let stopped = await service.healthSnapshot()
        expect(!stopped.listenerReady && stopped.paired, "stop lost pin evidence or reported ready")
    }

}

extension DroneWorkerProof {
    private static func startTrackedProcess(
        controller: DroneLANTransport,
        connectionID: DroneConnectionID,
        lease: DroneToolLease,
        observed: ProofObserved,
        command: String = "echo $$; exec sleep 10",
        timeout: TimeInterval = 5
    ) async throws -> Int32 {
        let id = UUID()
        controller.send(DroneEnvelope(
            kind: .toolRun, requestID: id, lease: lease, idempotencyKey: UUID().uuidString,
            body: .toolRun(DroneToolProcessRequest(
                executable: "sh", arguments: ["-c", command], timeout: timeout
            ))
        ), on: connectionID)
        let response = try await waitForResponse(id, kind: .toolOutput, observed: observed)
        guard case .toolOutput(let output) = response.body,
              let pid = Int32(String(decoding: output.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1 else { throw ProofError.failed("fixture PID missing") }
        return pid
    }

    /// Runs one short tool job to completion and returns the job record files
    /// it added, so a revocation proof can check those specific records.
    private static func runFinishedJob(
        controller: DroneLANTransport, connectionID: DroneConnectionID, controllerID: UUID,
        service: DroneWorkerService, observed: ProofObserved, stateDirectory: URL
    ) async throws -> Set<String> {
        let before = jobRecordNames(stateDirectory: stateDirectory, controllerID: controllerID)
        let lease = try await service.issueToolLease(controllerID: controllerID, permissions: .jobs)
        let id = UUID()
        controller.send(DroneEnvelope(
            kind: .toolRun, requestID: id, lease: lease, idempotencyKey: UUID().uuidString,
            body: .toolRun(DroneToolProcessRequest(executable: "sh", arguments: ["-c", "printf done"], timeout: 5))
        ), on: connectionID)
        let completion = try await waitForResponse(id, kind: .toolCompletion, observed: observed)
        guard case .toolCompletion(let body) = completion.body, body.status == .succeeded else {
            throw ProofError.failed("finished job fixture failed")
        }
        let added = jobRecordNames(stateDirectory: stateDirectory, controllerID: controllerID).subtracting(before)
        expect(!added.isEmpty, "finished job left no record to purge")
        return added
    }

    private static func jobRecordNames(stateDirectory: URL, controllerID: UUID) -> Set<String> {
        let directory = stateDirectory.appendingPathComponent(
            "jobs/controllers/\(controllerID.uuidString)/jobs", isDirectory: true
        )
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") })
    }

    private static func expectProcessStopped(_ pid: Int32) async throws {
        for _ in 0..<120 {
            if kill(pid, 0) == -1 && errno == ESRCH { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw ProofError.failed("owned process survived cancellation/shutdown")
    }

    private static func connectController(service: DroneWorkerService, port: UInt16) async throws -> ProofController {
        let identity = DroneIdentityStore(role: .controller, storage: ProofPairingStorage())
        let controllerID = try identity.loadOrCreatePeerID().rawValue
        let transport = DroneLANTransport(
            role: .controller, identityStore: identity,
            pairingStore: DronePairingStore(role: .controller, storage: ProofPairingStorage())
        )
        let observed = ProofObserved()
        transport.onEvent = { event in
            switch event {
            case .pairingRequired(let request): transport.resolvePairing(requestID: request.id, approved: true)
            case .connected(let id, _, _): observed.set(connectionID: id)
            case .envelope(_, _, let envelope): observed.record(envelope)
            default: break
            }
        }
        let peerID = DronePeerID()
        transport.pair(peerID: peerID, host: "127.0.0.1", port: port)
        for _ in 0..<400 {
            for approval in await service.approvalSummaries() {
                await service.resolvePairing(requestID: approval.requestID, approved: true)
            }
            if let connectionID = observed.connectionID {
                return ProofController(
                    transport: transport, connectionID: connectionID, controllerID: controllerID,
                    peerID: peerID, observed: observed
                )
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        transport.stop()
        throw ProofError.failed("second controller failed to authenticate")
    }

    private static func verifyTerminalPumps() async {
        var pumps = DroneWorkerTerminalPumps()
        let connection = DroneConnectionID()
        let first = DroneWorkerTerminalPumps.Key(connectionID: connection, sessionID: DroneSessionID())
        let second = DroneWorkerTerminalPumps.Key(connectionID: connection, sessionID: DroneSessionID())
        let third = DroneWorkerTerminalPumps.Key(connectionID: DroneConnectionID(), sessionID: DroneSessionID())
        let generation = UUID()
        let tasks = (0..<4).map { _ in Task { try? await Task.sleep(for: .seconds(10)) } }
        // Convert the optional Void sleep result to a Void task without polling.
        let pumpTasks = tasks.map { sleeping in Task<Void, Never> { _ = await sleeping.value } }
        defer { for task in tasks { task.cancel() } }
        pumps.insert(pumpTasks[0], key: first, generation: generation)
        pumps.insert(pumpTasks[1], key: second, generation: UUID())
        pumps.insert(pumpTasks[2], key: third, generation: UUID())
        expect(pumps.contains(first) && pumps.contains(second), "second session lost its pump")
        pumps.cancel(connectionID: connection, sessionID: first.sessionID)
        expect(pumpTasks[0].isCancelled && !pumpTasks[1].isCancelled, "detach cancelled sibling session")
        pumps.insert(pumpTasks[3], key: first, generation: UUID())
        pumps.finish(first, generation: generation)
        expect(pumps.contains(first), "retired pump removed replacement")
        pumps.cancel(connectionID: connection)
        expect(pumpTasks[1].isCancelled && pumpTasks[3].isCancelled, "disconnect left owned pumps")
        expect(!pumpTasks[2].isCancelled && pumps.contains(third), "disconnect cancelled another connection")
        pumps.cancelAll()
        expect(pumpTasks[2].isCancelled, "stop left pump running")
    }

}

extension DroneWorkerProof {
    private static func verifyIssuedLeases(
        controller: DroneLANTransport,
        connectionID: DroneConnectionID,
        controllerID: UUID,
        service: DroneWorkerService,
        observed: ProofObserved
    ) async throws {
        let lease = try await service.issueToolLease(controllerID: controllerID, permissions: .files)
        for field in 0..<7 {
            let requestID = UUID()
            let requested = DroneToolLease(
                id: field == 0 ? UUID() : lease.id,
                controllerID: field == 1 ? UUID() : lease.controllerID,
                droneID: field == 2 ? UUID() : lease.droneID,
                jobID: field == 3 ? DroneJobID() : lease.jobID,
                workspaceID: field == 4 ? UUID() : lease.workspaceID,
                expiresAt: field == 5 ? lease.expiresAt + 60 : lease.expiresAt
            )
            controller.send(DroneEnvelope(
                kind: .toolRead, requestID: requestID, lease: requested,
                idempotencyKey: UUID().uuidString,
                body: .toolRead(DroneToolReadRequest(path: "main.swift", maxBytes: 1_024))
            ), on: connectionID)
            if field < 6 {
                try await expectUnauthorized(requestID, observed: observed)
            } else {
                _ = try await waitForResponse(requestID, kind: .toolReadResult, observed: observed)
            }
        }
        let deniedRun = UUID()
        controller.send(DroneEnvelope(
            kind: .toolRun, requestID: deniedRun, lease: lease,
            idempotencyKey: UUID().uuidString,
            body: .toolRun(DroneToolProcessRequest(executable: "printf", arguments: ["must-not-execute"]))
        ), on: connectionID)
        try await expectUnauthorized(deniedRun, observed: observed)
        let expired = try await service.issueToolLease(
            controllerID: controllerID, permissions: .files, lifetime: 0.01
        )
        try await Task.sleep(for: .milliseconds(30))
        let expiredRead = UUID()
        controller.send(DroneEnvelope(
            kind: .toolRead, requestID: expiredRead, lease: expired,
            idempotencyKey: UUID().uuidString,
            body: .toolRead(DroneToolReadRequest(path: "main.swift", maxBytes: 1_024))
        ), on: connectionID)
        try await expectUnauthorized(expiredRead, observed: observed)
        do {
            _ = try await service.issueToolLease(
                controllerID: controllerID, workspaceID: UUID(), permissions: .files
            )
            throw ProofError.failed("unregistered workspace granted")
        } catch DroneProtocolError.unauthorized {}
    }

    private static func expectTerminalGrant(
        controller: DroneLANTransport,
        observed: ProofObserved
    ) async throws {
        guard let connectionID = observed.connectionID else {
            throw ProofError.failed("grant probe lost authenticated connection")
        }
        let requestID = UUID()
        controller.send(DroneEnvelope(
            kind: .activity,
            requestID: requestID,
            sessionID: DroneSessionID()
        ), on: connectionID)
        try await expectError(requestID, code: "invalidSession", observed: observed)
    }

    private static func expectUnauthorized(_ requestID: UUID, observed: ProofObserved) async throws {
        try await expectError(requestID, code: "unauthorized", observed: observed)
    }

    private static func expectError(
        _ requestID: UUID,
        code: String,
        observed: ProofObserved
    ) async throws {
        let response = try await waitForResponse(requestID, kind: .error, observed: observed)
        guard case .error(let error) = response.body, error.code == code else {
            throw ProofError.failed("expected \(code) error")
        }
    }

}

extension DroneWorkerProof {
    private static func verifyToolReplay(
        controller: DroneLANTransport,
        connectionID: DroneConnectionID,
        controllerID: UUID,
        service: DroneWorkerService,
        observed: ProofObserved
    ) async throws {
        let lease = try await service.issueToolLease(controllerID: controllerID, permissions: .jobs)
        let operationID = UUID()
        controller.send(DroneEnvelope(
            kind: .toolRun, requestID: operationID, lease: lease,
            idempotencyKey: UUID().uuidString,
            body: .toolRun(DroneToolProcessRequest(executable: "printf", arguments: ["replay-fixture"]))
        ), on: connectionID)
        let completed = try await waitForResponse(operationID, kind: .toolCompletion, observed: observed)
        guard case .toolCompletion(let result) = completed.body, result.status == .succeeded else {
            throw ProofError.failed("replay fixture process failed")
        }
        let filesOnlyLease = try await service.issueToolLease(controllerID: controllerID, permissions: .files)
        let deniedAttachID = UUID()
        let beforeDeniedReplay = observed.responses(for: operationID).count
        controller.send(DroneEnvelope(
            kind: .toolAttach, requestID: deniedAttachID, lease: filesOnlyLease,
            idempotencyKey: UUID().uuidString,
            body: .toolAttach(DroneToolAttachBody(
                originalRequestID: operationID, nextSequence: 0, offsets: DroneToolStreamOffsets()
            ))
        ), on: connectionID)
        try await expectUnauthorized(deniedAttachID, observed: observed)
        expect(observed.responses(for: operationID).count == beforeDeniedReplay,
               "files-only lease replayed process output")
        let otherLease = try await service.issueToolLease(controllerID: controllerID, permissions: .jobs)
        let cancelID = UUID()
        controller.send(DroneEnvelope(
            kind: .toolCancel, requestID: cancelID, lease: otherLease,
            idempotencyKey: UUID().uuidString,
            body: .toolCancel(DroneToolCancelBody(operationRequestID: operationID))
        ), on: connectionID)
        _ = try await waitForResponse(cancelID, kind: .toolCancelled, observed: observed)
        for field in 0..<7 {
            let requestID = UUID()
            let requestedLease = DroneToolLease(
                id: field == 0 ? UUID() : lease.id,
                controllerID: field == 1 ? UUID() : lease.controllerID,
                droneID: field == 2 ? UUID() : lease.droneID,
                jobID: field == 3 ? DroneJobID() : lease.jobID,
                workspaceID: field == 4 ? UUID() : lease.workspaceID,
                expiresAt: field == 5 ? lease.expiresAt + 60 : lease.expiresAt
            )
            let previousCount = observed.responses(for: operationID).count
            controller.send(DroneEnvelope(
                kind: .toolAttach, requestID: requestID, lease: requestedLease,
                idempotencyKey: UUID().uuidString,
                body: .toolAttach(DroneToolAttachBody(
                    originalRequestID: operationID, nextSequence: 0, offsets: DroneToolStreamOffsets()
                ))
            ), on: connectionID)
            if field < 6 {
                let response = try await waitForResponse(requestID, kind: .error, observed: observed)
                guard case .error(let error) = response.body, error.code == "unauthorized" else {
                    throw ProofError.failed("changed replay lease was not denied as unauthorized")
                }
                expect(observed.responses(for: operationID).count == previousCount, "unauthorized output replayed")
            } else {
                _ = try await waitForResponse(requestID, kind: .toolAttached, observed: observed)
                for _ in 0..<200 {
                    if observed.responses(for: operationID).count >= previousCount + 2 { break }
                    try await Task.sleep(for: .milliseconds(25))
                }
                let replay = Array(observed.responses(for: operationID).dropFirst(previousCount))
                expect(replay.contains { $0.kind == .toolOutput }, "original lease did not replay output")
                expect(replay.last?.kind == .toolCompletion, "original lease did not replay completion")
            }
        }
        let freshAttachID = UUID()
        let previousCount = observed.responses(for: operationID).count
        controller.send(DroneEnvelope(
            kind: .toolAttach, requestID: freshAttachID, lease: otherLease,
            idempotencyKey: UUID().uuidString,
            body: .toolAttach(DroneToolAttachBody(
                originalRequestID: operationID, nextSequence: 0, offsets: DroneToolStreamOffsets()
            ))
        ), on: connectionID)
        _ = try await waitForResponse(freshAttachID, kind: .toolAttached, observed: observed)
        for _ in 0..<200 {
            if observed.responses(for: operationID).count >= previousCount + 2 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let freshReplay = Array(observed.responses(for: operationID).dropFirst(previousCount))
        expect(freshReplay.contains { $0.kind == .toolOutput }, "fresh lease did not replay output")
        expect(freshReplay.last?.kind == .toolCompletion, "fresh lease did not replay completion")
        expect(freshReplay.allSatisfy { $0.lease == otherLease }, "replay returned a stale lease")
    }

    private static func waitForResponse(
        _ requestID: UUID,
        kind: DroneMessageKind,
        observed: ProofObserved
    ) async throws -> DroneEnvelope {
        for _ in 0..<400 {
            if let response = observed.responses(for: requestID).first(where: { $0.kind == kind }) {
                return response
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw ProofError.failed("timed out waiting for \(kind)")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("Drone worker proof failed: \(message)\n".utf8))
            exit(1)
        }
    }
}

private func runProcess(_ executable: String, _ arguments: [String], directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw ProofError.failed("git setup failed") }
}

private struct ProofCLIResult: Sendable {
    let status: Int32
    let output: Data
}

private struct ProofController {
    let transport: DroneLANTransport
    let connectionID: DroneConnectionID
    let controllerID: UUID
    let peerID: DronePeerID
    let observed: ProofObserved
}

private final class ProofObserved: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPort: UInt16?
    private var storedConnection: DroneConnectionID?
    private var created: [UUID: DroneSessionID] = [:]
    private var received: [UUID: [DroneEnvelope]] = [:]

    func responses(for requestID: UUID) -> [DroneEnvelope] {
        lock.withLock { received[requestID] ?? [] }
    }
    var onEnvelope: ((DroneEnvelope) -> Void)?

    var port: UInt16? { lock.withLock { storedPort } }
    var connectionID: DroneConnectionID? { lock.withLock { storedConnection } }
    func clearConnection() { lock.withLock { storedConnection = nil } }
    func set(port: UInt16) { lock.withLock { storedPort = port } }
    func set(connectionID: DroneConnectionID) { lock.withLock { storedConnection = connectionID } }
    func record(_ envelope: DroneEnvelope) {
        if let requestID = envelope.requestID {
            lock.withLock { received[requestID, default: []].append(envelope) }
        }
        if envelope.kind == .created, let requestID = envelope.requestID, let sessionID = envelope.sessionID {
            lock.withLock { created[requestID] = sessionID }
        }
        onEnvelope?(envelope)
    }
    func createdSession(requestID: UUID) -> DroneSessionID? { lock.withLock { created[requestID] } }
}

final class ProofPairingStorage: PairingSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var failDeletes = false

    func setFailDeletes(_ value: Bool) { lock.withLock { failDeletes = value } }

    func read(account: String) throws -> Data? { lock.withLock { values[account] } }
    func write(_ data: Data, account: String) throws { lock.withLock { values[account] = data } }
    func delete(account: String) throws {
        try lock.withLock {
            if failDeletes { throw ProofError.failed("synthetic storage failure") }
            _ = values.removeValue(forKey: account)
        }
    }
}

private enum ProofError: Error {
    case failed(String)
}

private final class ProofTerminalConnection: DroneConnection, @unchecked Sendable {
    let peer: DroneAuthenticatedPeer
    private let controller: DroneLANTransport
    private let connectionID: DroneConnectionID
    private let stream: AsyncThrowingStream<DroneEnvelope, any Error>
    private let continuation: AsyncThrowingStream<DroneEnvelope, any Error>.Continuation
    private let lock = NSLock()
    private var storedResizeCount = 0
    var resizeCount: Int { lock.withLock { storedResizeCount } }

    init(
        controller: DroneLANTransport,
        connectionID: DroneConnectionID,
        controllerID: UUID,
        droneID: UUID
    ) {
        self.controller = controller
        self.connectionID = connectionID
        peer = DroneAuthenticatedPeer(
            identityFingerprint: droneID.uuidString,
            hardware: .unknown,
            hello: DroneHello(selectedVersion: DroneLimits.protocolVersion)
        )
        (stream, continuation) = AsyncThrowingStream.makeStream()
    }

    func send(_ envelope: DroneEnvelope) async throws {
        if envelope.kind == .resize {
            lock.withLock { storedResizeCount += 1 }
        }
        controller.send(envelope, on: connectionID)
    }

    func receive() async throws -> DroneEnvelope {
        var iterator = stream.makeAsyncIterator()
        guard let envelope = try await iterator.next() else { throw DroneTransportError.disconnected }
        return envelope
    }

    func yield(_ envelope: DroneEnvelope) {
        continuation.yield(envelope)
    }

    func close() {
        continuation.finish()
    }
}

private final class ProofToolTransport: DroneToolTransport, @unchecked Sendable {
    let authenticatedControllerID: UUID
    let authenticatedDroneID: UUID
    let capabilities: Set<String> = ["terminal.v1", "tools.v1"]

    private let controller: DroneLANTransport
    private let connectionID: DroneConnectionID
    private let lock = NSLock()
    private var requests: [UUID: AsyncThrowingStream<DroneEnvelope, any Error>.Continuation] = [:]

    init(
        controller: DroneLANTransport,
        connectionID: DroneConnectionID,
        controllerID: UUID,
        droneID: UUID
    ) {
        self.controller = controller
        self.connectionID = connectionID
        authenticatedControllerID = controllerID
        authenticatedDroneID = droneID
    }

    func perform(
        _ request: DroneEnvelope
    ) async throws -> AsyncThrowingStream<DroneEnvelope, any Error> {
        guard let requestID = request.requestID else { throw DroneProtocolError.malformedMessage }
        let stream = AsyncThrowingStream<DroneEnvelope, any Error> { continuation in
            lock.withLock { requests[requestID] = continuation }
        }
        controller.send(request, on: connectionID)
        return stream
    }

    func handle(_ envelope: DroneEnvelope) {
        guard let requestID = envelope.requestID,
              let continuation = lock.withLock({ requests[requestID] })
        else { return }
        continuation.yield(envelope)
        switch envelope.kind {
        case .toolAccepted:
            break
        case .toolReadResult, .toolEditResult, .toolCompletion, .toolCancelled, .toolAttached, .error:
            _ = lock.withLock { requests.removeValue(forKey: requestID) }
            continuation.finish()
        default:
            break
        }
    }
}
