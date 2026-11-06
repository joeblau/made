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
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let replayOnly = CommandLine.arguments.contains("--tool-replay-authorization")
        try Data("print(\"drone-tools-before\")\n".utf8).write(
            to: workspace.appendingPathComponent("main.swift")
        )
        if !replayOnly {
            try runProcess("/usr/bin/git", ["init", "-q"], directory: workspace)
            try runProcess("/usr/bin/git", ["add", "-N", "main.swift"], directory: workspace)
        }
        let workerIdentity = DroneIdentityStore(role: .worker, storage: ProofPairingStorage())
        let workerID = try workerIdentity.loadOrCreatePeerID().rawValue
        let workerPairingStorage = ProofPairingStorage()
        let workerPairings = DronePairingStore(role: .worker, storage: workerPairingStorage)
        let workerTransport = DroneLANTransport(
            role: .worker,
            identityStore: workerIdentity,
            pairingStore: workerPairings
        )
        let service = try DroneWorkerService(
            workspace: workspace,
            stateDirectory: root.appendingPathComponent("state", isDirectory: true),
            transport: workerTransport,
            workerID: workerID,
            pairingStore: workerPairings,
            permissions: .all
        )
        let beforeStart = await service.healthSnapshot()
        expect(!beforeStart.listenerReady && !beforeStart.paired && beforeStart.storageHealthy,
               "initial health invented listener or pairing state")
        let observed = ProofObserved()
        await service.setOnListening { observed.set(port: $0) }
        await service.start(bonjourInstanceID: "drone-proof-\(UUID().uuidString)")

        let controllerIdentity = DroneIdentityStore(role: .controller, storage: ProofPairingStorage())
        let controllerID = try controllerIdentity.loadOrCreatePeerID().rawValue
        let controller = DroneLANTransport(
            role: .controller,
            identityStore: controllerIdentity,
            pairingStore: DronePairingStore(role: .controller, storage: ProofPairingStorage())
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

        if replayOnly {
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
                service: service, observed: observed, port: port, pairingStorage: workerPairingStorage
            )
            controller.stop()
            await service.stop()
            print("Drone worker authorization passed: owner CLI/socket grants, issued leases, replay, revocation, health, shutdown, and pump isolation.")
            return
        }

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
        controller.send(DroneEnvelope(
            kind: .attach,
            requestID: UUID(),
            sessionID: sessionID,
            body: .attach(DroneAttachBody(afterSequence: 0, afterOffset: 0))
        ), on: connectionID)
        controller.send(DroneEnvelope(
            kind: .input,
            requestID: UUID(),
            sessionID: sessionID,
            body: .input(DroneInputBody(data: Data("printf 'drone-e2e-✓' > proof.txt\n".utf8)))
        ), on: connectionID)

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

        let toolTransport = ProofToolTransport(
            controller: controller,
            connectionID: connectionID,
            controllerID: controllerID,
            droneID: workerID
        )
        observed.onEnvelope = { envelope in toolTransport.handle(envelope) }
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
        observed.onEnvelope = nil

        controller.send(DroneEnvelope(kind: .close, requestID: UUID(), sessionID: sessionID), on: connectionID)
        try await Task.sleep(for: .milliseconds(100))
        controller.stop()
        await service.stop()
        print("Drone worker proof passed: pairing, encrypted terminal, remote command, and agent tool cycle.")
    }

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
        pairingStorage: ProofPairingStorage
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

    private static func startTrackedProcess(
        controller: DroneLANTransport,
        connectionID: DroneConnectionID,
        lease: DroneToolLease,
        observed: ProofObserved
    ) async throws -> Int32 {
        let id = UUID()
        controller.send(DroneEnvelope(
            kind: .toolRun, requestID: id, lease: lease, idempotencyKey: UUID().uuidString,
            body: .toolRun(DroneToolProcessRequest(
                executable: "sh", arguments: ["-c", "echo $$; exec sleep 10"], timeout: 5
            ))
        ), on: connectionID)
        let response = try await waitForResponse(id, kind: .toolOutput, observed: observed)
        guard case .toolOutput(let output) = response.body,
              let pid = Int32(String(decoding: output.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1 else { throw ProofError.failed("fixture PID missing") }
        return pid
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
        transport.pair(peerID: DronePeerID(), host: "127.0.0.1", port: port)
        for _ in 0..<400 {
            for approval in await service.approvalSummaries() {
                await service.resolvePairing(requestID: approval.requestID, approved: true)
            }
            if let connectionID = observed.connectionID {
                return ProofController(
                    transport: transport, connectionID: connectionID, controllerID: controllerID, observed: observed
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

    private static func expectUnauthorized(_ requestID: UUID, observed: ProofObserved) async throws {
        let response = try await waitForResponse(requestID, kind: .error, observed: observed)
        guard case .error(let error) = response.body, error.code == "unauthorized" else {
            throw ProofError.failed("expected authorization denial")
        }
    }

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
        let otherLease = try await service.issueToolLease(controllerID: controllerID, permissions: .jobs)
        let cancelID = UUID()
        controller.send(DroneEnvelope(
            kind: .toolCancel, requestID: cancelID, lease: otherLease,
            idempotencyKey: UUID().uuidString,
            body: .toolCancel(DroneToolCancelBody(operationRequestID: operationID))
        ), on: connectionID)
        try await expectUnauthorized(cancelID, observed: observed)
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

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
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

private final class ProofPairingStorage: PairingSecretStoring, @unchecked Sendable {
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
