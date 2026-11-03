import Foundation

@main
enum DroneWorkerProof {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("drone-worker-proof-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("print(\"drone-tools-before\")\n".utf8).write(
            to: workspace.appendingPathComponent("main.swift")
        )
        try runProcess("/usr/bin/git", ["init", "-q"], directory: workspace)
        try runProcess("/usr/bin/git", ["add", "-N", "main.swift"], directory: workspace)
        let workerTransport = DroneLANTransport(
            role: .worker,
            identityStore: DroneIdentityStore(role: .worker, storage: ProofPairingStorage()),
            pairingStore: DronePairingStore(role: .worker, storage: ProofPairingStorage())
        )
        let service = try DroneWorkerService(
            workspace: workspace,
            stateDirectory: root.appendingPathComponent("state", isDirectory: true),
            transport: workerTransport,
            permissions: .all
        )
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
            droneID: peerID.rawValue
        )
        observed.onEnvelope = { envelope in toolTransport.handle(envelope) }
        let lease = DroneToolLease(
            id: UUID(),
            controllerID: controllerID,
            droneID: peerID.rawValue,
            jobID: DroneJobID(),
            workspaceID: DroneWorkspaceIDs.default,
            expiresAt: Date().timeIntervalSince1970 + 60
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

private final class ProofObserved: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPort: UInt16?
    private var storedConnection: DroneConnectionID?
    private var created: [UUID: DroneSessionID] = [:]
    var onEnvelope: ((DroneEnvelope) -> Void)?

    var port: UInt16? { lock.withLock { storedPort } }
    var connectionID: DroneConnectionID? { lock.withLock { storedConnection } }
    func set(port: UInt16) { lock.withLock { storedPort = port } }
    func set(connectionID: DroneConnectionID) { lock.withLock { storedConnection = connectionID } }
    func record(_ envelope: DroneEnvelope) {
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

    func read(account: String) throws -> Data? { lock.withLock { values[account] } }
    func write(_ data: Data, account: String) throws { lock.withLock { values[account] = data } }
    func delete(account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
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
