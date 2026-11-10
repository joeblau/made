import Darwin
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
        try await verifyShutdown(in: workspace, root: root)
        try await verifyShutdownTimeout(in: workspace, root: root)
        try await verifyAcceptanceShutdownTimeout(in: workspace, root: root)
        try await verifyExpiredJobPurge(in: workspace, root: root)

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

    private static func verifyAcceptanceShutdownTimeout(in workspace: URL, root: URL) async throws {
        let workspaceID = UUID()
        let registry = try DroneWorkspaceRegistry(workspaces: [workspaceID: workspace])
        let clock = ProofBlockingClock(blockAtCall: nil)
        let engine = try DroneJobEngine(
            stateURL: root.appendingPathComponent("acceptance-timeout"),
            workspaces: registry, now: { clock.now() }
        )
        let controller = UUID()
        let active = try engine.createJob(DroneJobCreate(
            controllerID: controller, idempotencyKey: "active-during-acceptance-001",
            request: DroneJobRequest(workspaceID: workspaceID, operation: .process(DroneProcessOperation(
                executablePath: "/bin/sh", arguments: ["-c", "echo $$ > active.pid; exec /bin/sleep 30"]
            )))
        ))
        var pid: pid_t?
        for _ in 0..<200 {
            if let text = try? String(contentsOf: workspace.appendingPathComponent("active.pid"), encoding: .utf8),
               let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { pid = value; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let pid else { throw ProofError.failed("active job did not start") }
        defer { _ = Darwin.kill(pid, SIGKILL); clock.release.signal() }
        clock.blockNextCall()
        let accepting = Task.detached {
            try engine.createJob(DroneJobCreate(
                controllerID: controller, idempotencyKey: "blocked-acceptance-0001",
                request: DroneJobRequest(workspaceID: workspaceID, operation: .writeFile(
                    DroneWriteFileOperation(relativePath: "acceptance-must-not-run", data: Data([1]))
                ))
            ))
        }
        let entered = await Task.detached { clock.waitUntilEntered() }.value
        expect(entered, "acceptance did not reach persistence gate")
        // Release the old implementation rather than hanging the test indefinitely.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { clock.release.signal() }
        let start = ContinuousClock.now
        let stopped = await engine.shutdown(timeout: 0.05)
        let elapsed = start.duration(to: .now)
        print("Acceptance shutdown: elapsed=\(elapsed), joined=\(stopped)")
        expect(!stopped && elapsed < .milliseconds(300), "acceptance blocked the shutdown deadline")
        for _ in 0..<30 {
            if Darwin.kill(pid, 0) != 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        expect(Darwin.kill(pid, 0) != 0, "pending acceptance delayed cancellation of an owned process")
        clock.release.signal()
        let accepted = try await accepting.value
        let joined = await engine.shutdown()
        expect(joined, "pending acceptance did not drain after persistence resumed")
        let activeResult = try engine.snapshot(id: active.id, controllerID: controller)
        let acceptedResult = try engine.snapshot(id: accepted.id, controllerID: controller)
        expect(activeResult.state == .cancelled && acceptedResult.state == .cancelled, "shutdown lost job cancellation")
        expect(!FileManager.default.fileExists(atPath: workspace.appendingPathComponent("acceptance-must-not-run").path),
               "accepted job executed after shutdown began")
    }

    /// Issue #444: finished records expire for every controller, not only for
    /// one that keeps creating jobs; restart and revocation delete them too.
    private static func verifyExpiredJobPurge(in workspace: URL, root: URL) async throws {
        let workspaceID = UUID()
        let registry = try DroneWorkspaceRegistry(workspaces: [workspaceID: workspace])
        try Data("purge-proof".utf8).write(to: workspace.appendingPathComponent("purge.txt"))
        let clock = ProofManualClock()
        let lifetime = DroneJobEngineLimits().idempotencyLifetime
        func read(_ controller: UUID, _ key: String) -> DroneJobCreate {
            DroneJobCreate(controllerID: controller, idempotencyKey: key, request: DroneJobRequest(
                workspaceID: workspaceID,
                operation: .readFile(DroneReadFileOperation(relativePath: "purge.txt"))
            ))
        }
        func recordExists(_ state: URL, _ controller: UUID, _ key: String) -> Bool {
            FileManager.default.fileExists(atPath: state
                .appendingPathComponent("controllers/\(controller.uuidString)/jobs/\(key).json").path)
        }

        // Restart: an idle controller's expired record is deleted, never reloaded.
        let restartState = root.appendingPathComponent("purge-restart")
        let idle = UUID()
        let fresh = UUID()
        let store = try DroneJobStore(stateURL: restartState, limits: DroneJobEngineLimits(), now: { clock.now() })
        let stale = try store.create(read(idle, "purge-restart-stale-01")).snapshot
        try store.finish(id: stale.id, state: .completed, result: .file(Data("source".utf8)), failure: nil)
        clock.advance(by: lifetime + 1)
        // Another controller's create purges only its own records.
        let kept = try store.create(read(fresh, "purge-restart-fresh-01")).snapshot
        try store.finish(id: kept.id, state: .completed, result: nil, failure: nil)
        let restarted = try DroneJobStore(stateURL: restartState, limits: DroneJobEngineLimits(), now: { clock.now() })
        expect(!recordExists(restartState, idle, "purge-restart-stale-01"), "restart kept an expired record on disk")
        expect((try? restarted.snapshot(controllerID: idle, idempotencyKey: "purge-restart-stale-01")) == nil,
               "restart reloaded an expired record into memory")
        let survivor = try? restarted.snapshot(controllerID: fresh, idempotencyKey: "purge-restart-fresh-01")
        expect(survivor?.state == .completed, "restart purged an unexpired record")

        let timerState = root.appendingPathComponent("purge-timer")
        let engine = try DroneJobEngine(
            stateURL: timerState, workspaces: registry, purgeInterval: 0.05, now: { clock.now() }
        )
        let idleJob = try engine.createJob(read(idle, "purge-timer-idle-0001"))
        _ = try await terminal(idleJob.id, controllerID: idle, engine: engine, expected: .completed)

        // Revocation: finished records go now; in-flight ones once they finish.
        let revoked = UUID()
        let revokedDone = try engine.createJob(read(revoked, "purge-revoked-done-01"))
        _ = try await terminal(revokedDone.id, controllerID: revoked, engine: engine, expected: .completed)
        let revokedLive = try engine.createJob(DroneJobCreate(
            controllerID: revoked, idempotencyKey: "purge-revoked-live-01",
            request: DroneJobRequest(workspaceID: workspaceID, operation: .process(DroneProcessOperation(
                executablePath: "/bin/sleep", arguments: ["30"], timeoutMilliseconds: 60_000
            )))
        ))
        try await Task.sleep(for: .milliseconds(100))
        let removed = try engine.removeFinishedJobs(controllerID: revoked)
        expect(removed == 1 && !recordExists(timerState, revoked, "purge-revoked-done-01"),
               "revocation kept a finished record")
        expect((try? engine.snapshot(id: revokedLive.id, controllerID: revoked)) != nil,
               "revocation dropped a running job's record before it finished")
        _ = try engine.cancelJob(id: revokedLive.id, controllerID: revoked)
        try await waitUntil("revoked controller's finished record was never purged") {
            !recordExists(timerState, revoked, "purge-revoked-live-01")
        }
        expect(recordExists(timerState, idle, "purge-timer-idle-0001"), "purge removed an unexpired record")

        // Re-pair: the same controller ID approved again keeps its new records
        // for the full idempotency lifetime; only records from before the
        // revocation were retired.
        let repaired = try engine.createJob(read(revoked, "purge-repaired-new-01"))
        _ = try await terminal(repaired.id, controllerID: revoked, engine: engine, expected: .completed)
        try await Task.sleep(for: .milliseconds(300))
        expect(recordExists(timerState, revoked, "purge-repaired-new-01"),
               "purge deleted a re-paired controller's unexpired record from disk")
        expect((try? engine.snapshot(id: repaired.id, controllerID: revoked))?.state == .completed,
               "purge dropped a re-paired controller's unexpired record from memory")

        // Timer: an idle controller's expired record is purged with no further creates.
        clock.advance(by: lifetime + 1)
        try await waitUntil("idle controller's expired record was never purged") {
            !recordExists(timerState, idle, "purge-timer-idle-0001")
                && (try? engine.snapshot(id: idleJob.id, controllerID: idle)) == nil
        }
        let joined = await engine.shutdown()
        expect(joined, "purge proof engine did not shut down")
    }

    private static func waitUntil(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw ProofError.failed(message)
    }

    private static func verifyShutdownTimeout(in workspace: URL, root: URL) async throws {
        let workspaceID = UUID()
        let registry = try DroneWorkspaceRegistry(workspaces: [workspaceID: workspace])
        let clock = ProofBlockingClock()
        let engine = try DroneJobEngine(
            stateURL: root.appendingPathComponent("shutdown-timeout"),
            workspaces: registry,
            now: { clock.now() }
        )
        let controllerID = UUID()
        let job = try engine.createJob(DroneJobCreate(
            controllerID: controllerID,
            idempotencyKey: "shutdown-timeout-job-001",
            request: DroneJobRequest(workspaceID: workspaceID, operation: .writeFile(
                DroneWriteFileOperation(relativePath: "must-not-run", data: Data("side effect".utf8))
            ))
        ))
        defer { clock.release.signal() }
        let blocked = await Task.detached { clock.waitUntilEntered() }.value
        expect(blocked, "job did not reach blocked persistence")
        let stopped = await engine.shutdown(timeout: 0.05)
        expect(!stopped, "shutdown claimed a blocked job had joined")
        clock.release.signal()
        let joined = await engine.shutdown()
        expect(joined, "shutdown did not join after persistence resumed")
        let snapshot = try engine.snapshot(id: job.id, controllerID: controllerID)
        expect(snapshot.state == .cancelled, "queued job did not record shutdown cancellation")
        expect(!FileManager.default.fileExists(atPath: workspace.appendingPathComponent("must-not-run").path),
               "cancelled queued file job executed a side effect")
    }

    private static func verifyShutdown(
        in workspace: URL, root: URL
    ) async throws {
        let workspaceID = UUID()
        let registry = try DroneWorkspaceRegistry(workspaces: [workspaceID: workspace])
        let state = root.appendingPathComponent("shutdown-jobs")
        var limits = DroneJobEngineLimits()
        limits.cancellationGracePeriod = 3
        let engine = try DroneJobEngine(stateURL: state, workspaces: registry, limits: limits)
        let controller = UUID()
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["30"]
        try unrelated.run()
        defer { unrelated.terminate(); unrelated.waitUntilExit() }
        let create = DroneJobCreate(
            controllerID: controller,
            idempotencyKey: "shutdown-resistant-child-001",
            request: DroneJobRequest(workspaceID: workspaceID, operation: .process(DroneProcessOperation(
                executablePath: "/bin/sh",
                arguments: ["-c", """
                /bin/sh -c 'trap "" TERM; echo $$ > child.pid; while :; do /bin/sleep 1; done' >/dev/null 2>&1 &
                exec /bin/sleep 30
                """],
                timeoutMilliseconds: 30_000
            )))
        )
        let job = try engine.createJob(create)
        var child: pid_t?
        for _ in 0..<200 {
            if let text = try? String(contentsOf: workspace.appendingPathComponent("child.pid"), encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                child = pid
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        defer { if let child { _ = Darwin.kill(child, SIGKILL) } }
        let stopped = await engine.shutdown()
        expect(stopped, "shutdown did not join owned tasks")
        guard let child else { throw ProofError.failed("shutdown child never started") }
        for _ in 0..<200 {
            if Darwin.kill(child, 0) != 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard Darwin.kill(child, 0) != 0 else {
            throw ProofError.failed("TERM-resistant descendant survived parent exit and shutdown")
        }
        expect(unrelated.isRunning, "shutdown killed an unrelated process")
        let final = try engine.snapshot(id: job.id, controllerID: controller)
        expect(final.state == .cancelled, "job not cancelled")
        do {
            _ = try engine.createJob(create)
            throw ProofError.failed("shutdown accepted new work")
        } catch DroneJobError.shuttingDown {}
        let stoppedAgain = await engine.shutdown()
        expect(stoppedAgain, "repeated shutdown did not finish")
        let recovered = try DroneJobEngine(stateURL: state, workspaces: registry)
        let retry = try recovered.createJob(create)
        expect(retry.id == job.id && retry.state == .cancelled, "restart duplicated cancelled work")
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

private final class ProofManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: TimeInterval = 0

    func advance(by seconds: TimeInterval) {
        lock.lock()
        offset += seconds
        lock.unlock()
    }

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince1970 + offset
    }
}

private final class ProofBlockingClock: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0
    private var blockAtCall: Int?

    init(blockAtCall: Int? = 2) { self.blockAtCall = blockAtCall }

    func blockNextCall() {
        lock.lock()
        blockAtCall = calls + 1
        lock.unlock()
    }

    func waitUntilEntered() -> Bool {
        entered.wait(timeout: .now() + 5) == .success
    }

    func now() -> TimeInterval {
        lock.lock()
        calls += 1
        let shouldBlock = calls == blockAtCall
        lock.unlock()
        if shouldBlock {
            entered.signal()
            release.wait()
        }
        return Date().timeIntervalSince1970
    }
}
