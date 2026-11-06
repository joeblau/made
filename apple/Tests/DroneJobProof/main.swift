import Foundation

@main
enum DroneJobProof {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("drone-job-proof-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let workspaceID = UUID()
        let controllerID = UUID()
        let registry = try DroneWorkspaceRegistry(workspaces: [workspaceID: workspace])
        let stateURL = root.appendingPathComponent("jobs.json")
        let engine = try DroneJobEngine(stateURL: stateURL, workspaces: registry)

        try verifyOutputBackpressure(in: workspace)

        let source = Data("print(\"drone-build-ok\")\n".utf8)
        let write = try engine.createJob(DroneJobCreate(
            controllerID: controllerID,
            idempotencyKey: "proof-write-source-0001",
            request: DroneJobRequest(
                workspaceID: workspaceID,
                operation: .writeFile(DroneWriteFileOperation(relativePath: "main.swift", data: source))
            )
        ))
        _ = try await terminal(write.id, controllerID: controllerID, engine: engine, expected: .completed)
        let duplicate = try engine.createJob(DroneJobCreate(
            controllerID: controllerID,
            idempotencyKey: "proof-write-source-0001",
            request: DroneJobRequest(workspaceID: workspaceID, operation: .writeFile(
                DroneWriteFileOperation(relativePath: "main.swift", data: source)
            ))
        ))
        expect(duplicate.id == write.id, "idempotent write returned a different job")
        expect(duplicate.state == .completed, "idempotent write executed twice")

        let build = try engine.createJob(DroneJobCreate(
            controllerID: controllerID,
            idempotencyKey: "proof-swift-build-0001",
            request: DroneJobRequest(workspaceID: workspaceID, operation: .process(
                DroneProcessOperation(
                    executablePath: "/usr/bin/xcrun",
                    arguments: ["swiftc", "main.swift", "-o", "proof-app"],
                    timeoutMilliseconds: 120_000
                )
            ))
        ))
        _ = try await terminal(build.id, controllerID: controllerID, engine: engine, expected: .completed)
        let run = try engine.createJob(DroneJobCreate(
            controllerID: controllerID,
            idempotencyKey: "proof-swift-run-00001",
            request: DroneJobRequest(workspaceID: workspaceID, operation: .process(
                DroneProcessOperation(executablePath: workspace.appendingPathComponent("proof-app").path)
            ))
        ))
        let runSnapshot = try await terminal(run.id, controllerID: controllerID, engine: engine, expected: .completed)
        let output = try engine.events(id: run.id, controllerID: controllerID, afterSequence: 0)
        let text = output.events.compactMap { event -> String? in
            guard case .output(let chunk) = event.payload else { return nil }
            return String(decoding: chunk.data, as: UTF8.self)
        }.joined()
        expect(text.contains("drone-build-ok"), "compiled program output missing")
        expect(runSnapshot.result != nil, "process result missing")

        let read = try engine.createJob(DroneJobCreate(
            controllerID: controllerID,
            idempotencyKey: "proof-read-source-0001",
            request: DroneJobRequest(workspaceID: workspaceID, operation: .readFile(
                DroneReadFileOperation(relativePath: "main.swift")
            ))
        ))
        let readSnapshot = try await terminal(read.id, controllerID: controllerID, engine: engine, expected: .completed)
        guard case .file(let data)? = readSnapshot.result else { throw ProofError.failed("file result missing") }
        expect(data == source, "read changed source bytes")

        try runProcess("/usr/bin/git", ["init", "-q"], directory: workspace)
        let status = try engine.createJob(DroneJobCreate(
            controllerID: controllerID,
            idempotencyKey: "proof-git-status-0001",
            request: DroneJobRequest(workspaceID: workspaceID, operation: .gitStatus(
                DroneGitStatusOperation()
            ))
        ))
        _ = try await terminal(status.id, controllerID: controllerID, engine: engine, expected: .completed)
        let diff = try engine.createJob(DroneJobCreate(
            controllerID: controllerID,
            idempotencyKey: "proof-git-diff-00001",
            request: DroneJobRequest(workspaceID: workspaceID, operation: .gitDiff(
                DroneGitDiffOperation(relativePath: "main.swift")
            ))
        ))
        _ = try await terminal(diff.id, controllerID: controllerID, engine: engine, expected: .completed)

        let cancelled = try engine.createJob(DroneJobCreate(
            controllerID: controllerID,
            idempotencyKey: "proof-cancel-job-0001",
            request: DroneJobRequest(workspaceID: workspaceID, operation: .process(
                DroneProcessOperation(
                    executablePath: "/bin/sh",
                    arguments: ["-c", "sleep 30"],
                    timeoutMilliseconds: 60_000
                )
            ))
        ))
        try await Task.sleep(for: .milliseconds(150))
        _ = try engine.cancelJob(id: cancelled.id, controllerID: controllerID)
        _ = try await terminal(cancelled.id, controllerID: controllerID, engine: engine, expected: .cancelled)

        do {
            _ = try engine.createJob(DroneJobCreate(
                controllerID: controllerID,
                idempotencyKey: "proof-path-reject-001",
                request: DroneJobRequest(workspaceID: workspaceID, operation: .readFile(
                    DroneReadFileOperation(relativePath: "../outside")
                ))
            ))
            throw ProofError.failed("path traversal was accepted")
        } catch DroneJobError.unauthorized {}

        let recoveryStore = try DroneJobStore(stateURL: stateURL, limits: DroneJobEngineLimits())
        let recovered = try recoveryStore.create(DroneJobCreate(
            controllerID: controllerID,
            idempotencyKey: "proof-restart-job-0001",
            request: DroneJobRequest(workspaceID: workspaceID, operation: .readFile(
                DroneReadFileOperation(relativePath: "main.swift")
            ))
        ))
        let recoveredEngine = try DroneJobEngine(stateURL: stateURL, workspaces: registry)
        let recoveredSnapshot = try recoveredEngine.snapshot(id: recovered.snapshot.id, controllerID: controllerID)
        expect(recoveredSnapshot.state == .failed, "interrupted job was rerun or left ambiguous")
        expect(recoveredSnapshot.failure?.code == .workerRestarted, "restart failure was not explicit")
        print("Drone job proof passed: idempotency, real build, files, Git, cancellation, bounds, and recovery.")
    }

    private static func verifyOutputBackpressure(in workspace: URL) throws {
        var receivedBytes = 0
        let outcome = try DroneProcessRunner.run(
            operation: DroneProcessOperation(
                executablePath: "/bin/dd",
                arguments: ["if=/dev/zero", "bs=65536", "count=32"],
                timeoutMilliseconds: 10_000,
                standardOutputLimit: 2 * 1_024 * 1_024
            ),
            currentDirectory: workspace,
            environment: [:],
            control: DroneProcessGroupControl(gracePeriod: 0.1),
            onOutput: { stream, data in
                if stream == .standardOutput {
                    receivedBytes += data.count
                    // Model durable-store latency while the child fills its pipe.
                    Thread.sleep(forTimeInterval: 0.02)
                }
            },
            onTruncated: { _ in fatalError("unexpected output truncation") }
        )
        expect(outcome.exitCode == 0, "backpressure caused the child writer to fail")
        expect(receivedBytes == 2 * 1_024 * 1_024, "backpressure lost child output")
    }

    private static func terminal(
        _ id: DroneJobID,
        controllerID: UUID,
        engine: DroneJobEngine,
        expected: DroneJobState
    ) async throws -> DroneJobSnapshot {
        for _ in 0..<600 {
            let snapshot = try engine.snapshot(id: id, controllerID: controllerID)
            if snapshot.state.isTerminal {
                expect(snapshot.state == expected, "job ended in \(snapshot.state), expected \(expected)")
                return snapshot
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw ProofError.failed("job timed out waiting for terminal state")
    }

    private static func runProcess(_ executable: String, _ arguments: [String], directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        expect(process.terminationStatus == 0, "setup process failed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
}

private enum ProofError: Error {
    case failed(String)
}
