import Darwin
import Foundation

@main
enum DroneJobProof {
    private static let crashChildFlag = "--crash-during-process-job"

    static func main() async throws {
        let launchArguments = CommandLine.arguments
        if launchArguments.count == 6, launchArguments[1] == crashChildFlag {
            try await crashDuringProcessJob(launchArguments)
        }
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
        try await verifyFinishedJobKillsBackgroundChild(in: workspace, root: root)
        try await verifyCrashRecoveryKillsProcessGroup(in: workspace, root: root, leaderExitsFirst: false)
        try await verifyCrashRecoveryKillsProcessGroup(in: workspace, root: root, leaderExitsFirst: true)
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
        try verifyQuarantinedRecovery(in: workspace, root: root)
        try verifyUnrecoverableRecordQuarantine(in: workspace, root: root)
        try verifyUnremovableExpiredRecord(in: workspace, root: root)
        print("Drone job proof passed: idempotency, real build, files, Git, cancellation, bounds, and recovery.")
    }

    /// A leader that exits normally must not leave a descendant running after
    /// the job is recorded finished, even one that redirected its output.
    private static func verifyFinishedJobKillsBackgroundChild(in workspace: URL, root: URL) async throws {
        let workspaceID = UUID()
        let registry = try DroneWorkspaceRegistry(workspaces: [workspaceID: workspace])
        let engine = try DroneJobEngine(
            stateURL: root.appendingPathComponent("background-child"),
            workspaces: registry
        )
        let controllerID = UUID()
        let job = try engine.createJob(DroneJobCreate(
            controllerID: controllerID,
            idempotencyKey: "background-child-job-0001",
            request: DroneJobRequest(workspaceID: workspaceID, operation: .process(DroneProcessOperation(
                executablePath: "/bin/sh",
                arguments: ["-c", """
                /bin/sh -c 'echo $$ > background.tmp && /bin/mv background.tmp background.pid
                exec /bin/sleep 30' >/dev/null 2>&1 &
                while [ ! -s background.pid ]; do /bin/sleep 0.05; done
                exit 0
                """],
                timeoutMilliseconds: 30_000
            )))
        ))
        _ = try await terminal(job.id, controllerID: controllerID, engine: engine, expected: .completed)
        let pidFile = workspace.appendingPathComponent("background.pid")
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let child = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { throw ProofError.failed("background child never started") }
        defer { _ = Darwin.kill(child, SIGKILL) }
        try await waitUntilGone(child)
        expect(Darwin.kill(child, 0) != 0, "a completed job left its background child running")
        let stopped = await engine.shutdown()
        expect(stopped, "background-child engine did not shut down")
    }

    /// Crash a real worker process mid-job, then prove recovery kills the
    /// process group it left behind before reporting `workerRestarted`.
    private static func verifyCrashRecoveryKillsProcessGroup(
        in workspace: URL, root: URL, leaderExitsFirst: Bool
    ) async throws {
        let workspaceID = UUID()
        let controllerID = UUID()
        let registry = try DroneWorkspaceRegistry(workspaces: [workspaceID: workspace])
        let state = root.appendingPathComponent(leaderExitsFirst ? "crash-orphaned" : "crash-live-leader")
        let pidFile = workspace.appendingPathComponent("crash-orphan.pid")
        try? FileManager.default.removeItem(at: pidFile)
        let worker = Process()
        worker.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        worker.arguments = [
            crashChildFlag, state.path, workspace.path,
            workspaceID.uuidString, controllerID.uuidString,
        ]
        try worker.run()
        worker.waitUntilExit()
        expect(worker.terminationReason == .uncaughtSignal, "crash worker did not crash")
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8) else {
            throw ProofError.failed("crash worker never started its job")
        }
        let pids = text.split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
        guard pids.count == 2 else { throw ProofError.failed("crash worker wrote malformed pids") }
        let orphan = pids[0]
        let leader = pids[1]
        defer {
            _ = Darwin.kill(orphan, SIGKILL)
            _ = Darwin.kill(leader, SIGKILL)
        }
        expect(Darwin.kill(orphan, 0) == 0, "orphan did not outlive the crashed worker")
        if leaderExitsFirst {
            // The common crash shape: the leader dies (SIGPIPE, exit) and is
            // reaped by launchd while its descendants keep the group alive.
            _ = Darwin.kill(leader, SIGKILL)
            try await waitUntilGone(leader)
        }
        let recovered = try DroneJobEngine(stateURL: state, workspaces: registry)
        let snapshot = try recovered.snapshot(
            controllerID: controllerID,
            idempotencyKey: "crash-recovery-job-0001"
        )
        expect(snapshot.state == .failed && snapshot.failure?.code == .workerRestarted,
               "crashed job was not recovered as workerRestarted")
        try await waitUntilGone(orphan)
        expect(Darwin.kill(orphan, 0) != 0, "recovery left the crashed job's process group running")
        expect(Darwin.kill(leader, 0) != 0, "recovery left the crashed job's leader running")
    }

    /// Child-process mode: start a job whose TERM-immune descendant records
    /// its own pid and its leader's pid, then die without any cleanup.
    private static func crashDuringProcessJob(_ arguments: [String]) async throws -> Never {
        guard let workspaceID = UUID(uuidString: arguments[4]),
              let controllerID = UUID(uuidString: arguments[5])
        else { fatalError("crash worker received malformed identifiers") }
        let workspace = URL(fileURLWithPath: arguments[3], isDirectory: true)
        let registry = try DroneWorkspaceRegistry(workspaces: [workspaceID: workspace])
        let engine = try DroneJobEngine(
            stateURL: URL(fileURLWithPath: arguments[2], isDirectory: true),
            workspaces: registry
        )
        _ = try engine.createJob(DroneJobCreate(
            controllerID: controllerID,
            idempotencyKey: "crash-recovery-job-0001",
            request: DroneJobRequest(workspaceID: workspaceID, operation: .process(DroneProcessOperation(
                executablePath: "/bin/sh",
                arguments: ["-c", """
                /bin/sh -c 'trap "" TERM HUP
                echo $$ $PPID > crash-orphan.tmp && /bin/mv crash-orphan.tmp crash-orphan.pid
                i=0; while [ $i -lt 60 ]; do /bin/sleep 1; i=$((i + 1)); done' >/dev/null 2>&1 &
                exec /bin/sleep 30
                """],
                timeoutMilliseconds: 60_000
            )))
        ))
        let pidFile = workspace.appendingPathComponent("crash-orphan.pid")
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: pidFile.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        // A process-directed SIGKILL may be delivered on another thread while
        // this one keeps running, so never fall through to a normal exit.
        _ = pthread_kill(pthread_self(), SIGKILL)
        _ = Darwin.kill(getpid(), SIGKILL)
        while true { _ = Darwin.pause() }
    }

    private static func waitUntilGone(_ pid: pid_t) async throws {
        for _ in 0..<200 {
            if Darwin.kill(pid, 0) != 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
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

    /// #440: one undecodable or newer-version record must be set aside, not abort recovery.
    private static func verifyQuarantinedRecovery(in workspace: URL, root: URL) throws {
        let workspaceID = UUID()
        let registry = try DroneWorkspaceRegistry(workspaces: [workspaceID: workspace])
        let state = root.appendingPathComponent("quarantine-jobs", isDirectory: true)
        func create(_ controllerID: UUID, _ key: String) -> DroneJobCreate {
            DroneJobCreate(
                controllerID: controllerID,
                idempotencyKey: key,
                request: DroneJobRequest(workspaceID: workspaceID, operation: .readFile(
                    DroneReadFileOperation(relativePath: "main.swift")
                ))
            )
        }
        func recordURL(_ controllerID: UUID, _ key: String) -> URL {
            state.appendingPathComponent("controllers", isDirectory: true)
                .appendingPathComponent(controllerID.uuidString, isDirectory: true)
                .appendingPathComponent("jobs", isDirectory: true)
                .appendingPathComponent("\(key).json")
        }
        func rewrite(_ url: URL, _ change: (inout [String: Any]) -> Void) throws {
            guard var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                throw ProofError.failed("stored job record was not a JSON object")
            }
            change(&object)
            try JSONSerialization.data(withJSONObject: object).write(to: url)
        }
        let keptController = UUID()
        let futureController = UUID()
        let seeded = try DroneJobStore(stateURL: state, limits: DroneJobEngineLimits())
        expect(seeded.quarantinedEntryCount == 0, "a clean store reported quarantined records")
        let legacy = try seeded.create(create(keptController, "quarantine-legacy-0001")).snapshot
        let future = try seeded.create(create(futureController, "quarantine-future-0001")).snapshot
        // A record written before schema versioning must still load.
        try rewrite(recordURL(keptController, "quarantine-legacy-0001")) { _ = $0.removeValue(forKey: "schemaVersion") }
        // A record from a newer build (after a documented rollback) must be set aside.
        try rewrite(recordURL(futureController, "quarantine-future-0001")) { $0["schemaVersion"] = 2 }
        let garbage = recordURL(keptController, "quarantine-garbage-01")
        try Data("{\"id\": not json".utf8).write(to: garbage)
        let strayController = state.appendingPathComponent("controllers/not-a-controller", isDirectory: true)
        try FileManager.default.createDirectory(at: strayController, withIntermediateDirectories: true)

        let engine = try DroneJobEngine(stateURL: state, workspaces: registry)
        expect(engine.quarantinedRecordCount == 3, "recovery quarantined \(engine.quarantinedRecordCount) entries, expected 3")
        let kept = try engine.snapshot(id: legacy.id, controllerID: keptController)
        expect(kept.state == .failed && kept.failure?.code == .workerRestarted, "legacy record was not recovered")
        do {
            _ = try engine.snapshot(id: future.id, controllerID: futureController)
            throw ProofError.failed("a newer-version record was loaded by an older schema")
        } catch DroneJobError.jobNotFound {}
        expect(!FileManager.default.fileExists(atPath: garbage.path), "garbage record was left in place")
        expect(!FileManager.default.fileExists(atPath: strayController.path), "stray controller entry was left in place")
        expect(!FileManager.default.fileExists(atPath: recordURL(futureController, "quarantine-future-0001").path),
               "newer-version record was left where a retry could overwrite it")
        let quarantined = try FileManager.default.contentsOfDirectory(
            atPath: state.appendingPathComponent("quarantine", isDirectory: true).path
        )
        expect(quarantined.count == 3, "quarantined records were not preserved for the owner")

        // Storage stays reported as quarantined across restarts until the owner
        // clears it, and the records that were kept remain idempotent.
        let restarted = try DroneJobEngine(stateURL: state, workspaces: registry)
        expect(restarted.quarantinedRecordCount == 3, "restart hid previously quarantined records")
        let retried = try restarted.createJob(create(keptController, "quarantine-legacy-0001"))
        expect(retried.id == legacy.id, "recovered legacy record lost idempotency")
        let migrated = try JSONSerialization.jsonObject(
            with: Data(contentsOf: recordURL(keptController, "quarantine-legacy-0001"))
        ) as? [String: Any]
        expect((migrated?["schemaVersion"] as? Int) == DroneStoredJob.currentSchemaVersion,
               "recovered legacy record was not rewritten with the current schema version")
    }

    /// #440: a record that decodes and passes the schema, owner and name checks
    /// but cannot be recovered (overflow-prone counters, out-of-order history,
    /// or a recovery persist that throws) is quarantined, and the rest of the
    /// store still loads instead of trapping or failing startup. #441: the
    /// non-final `UInt64.max` record names a live process group, which must be
    /// killed even though the record itself is rejected.
    private static func verifyUnrecoverableRecordQuarantine(in workspace: URL, root: URL) throws {
        let workspaceID = UUID()
        let registry = try DroneWorkspaceRegistry(workspaces: [workspaceID: workspace])
        let controllerID = UUID()
        let files = FileManager.default
        func create(_ key: String) -> DroneJobCreate {
            DroneJobCreate(controllerID: controllerID, idempotencyKey: key, request: DroneJobRequest(
                workspaceID: workspaceID,
                operation: .readFile(DroneReadFileOperation(relativePath: "main.swift"))
            ))
        }
        func recordURL(_ state: URL, _ key: String) -> URL {
            state.appendingPathComponent("controllers/\(controllerID.uuidString)/jobs/\(key).json")
        }
        // Records are written with sorted keys, so each field is followed by another.
        func replace(_ url: URL, _ old: String, _ new: String) throws {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.contains(old) else { throw ProofError.failed("record fixture lacked \(old)") }
            try Data(text.replacingOccurrences(of: old, with: new).utf8).write(to: url)
        }

        let counterState = root.appendingPathComponent("unrecoverable-counters", isDirectory: true)
        let seeded = try DroneJobStore(stateURL: counterState, limits: DroneJobEngineLimits())
        let kept = try seeded.create(create("unrecoverable-kept-01")).snapshot
        // Non-final records: recovery appends a notice, so these exercise the
        // sequence arithmetic. Without the bound, UInt64.max traps the daemon.
        _ = try seeded.create(create("unrecoverable-maxseq-1"))
        _ = try seeded.create(create("unrecoverable-ceiling1"))
        _ = try seeded.create(create("unrecoverable-order-01"))
        let dropped = try seeded.create(create("unrecoverable-dropped")).snapshot
        try seeded.finish(id: dropped.id, state: .completed, result: nil, failure: nil)
        try replace(recordURL(counterState, "unrecoverable-maxseq-1"),
                    "\"latestSequence\":1,", "\"latestSequence\":\(UInt64.max),")
        let leader = try spawnGroupLeader()
        var reaped = false
        defer {
            if !reaped {
                _ = Darwin.kill(-leader, SIGKILL)
                var status: Int32 = 0
                _ = waitpid(leader, &status, 0)
            }
        }
        guard let group = DroneProcessGroupRecord.capture(leader: leader) else {
            throw ProofError.failed("could not capture the fixture's process group")
        }
        let groupJSON = String(decoding: try JSONEncoder().encode(group), as: UTF8.self)
        let maxSequenceURL = recordURL(counterState, "unrecoverable-maxseq-1")
        var maxSequenceText = try String(contentsOf: maxSequenceURL, encoding: .utf8)
        guard !maxSequenceText.contains("\"processGroup\""),
              let brace = maxSequenceText.firstIndex(of: "{")
        else { throw ProofError.failed("record fixture could not take a process group") }
        maxSequenceText.replaceSubrange(brace...brace, with: "{\"processGroup\":\(groupJSON),")
        try Data(maxSequenceText.utf8).write(to: maxSequenceURL)
        try replace(recordURL(counterState, "unrecoverable-ceiling1"),
                    "\"latestSequence\":1,", "\"latestSequence\":\(DroneStoredJob.maximumCounter),")
        try replace(recordURL(counterState, "unrecoverable-order-01"), "\"sequence\":1,", "\"sequence\":5,")
        try replace(recordURL(counterState, "unrecoverable-dropped"),
                    "\"droppedEventCount\":0,", "\"droppedEventCount\":\(UInt64.max),")

        let engine = try DroneJobEngine(stateURL: counterState, workspaces: registry)
        expect(engine.quarantinedRecordCount == 4,
               "recovery quarantined \(engine.quarantinedRecordCount) unrecoverable records, expected 4")
        var status: Int32 = 0
        for _ in 0..<200 {
            if waitpid(leader, &status, WNOHANG) == leader {
                reaped = true
                break
            }
            usleep(10_000)
        }
        expect(reaped && status & 0x7f == SIGKILL,
               "an inconsistent non-final record was quarantined without killing its process group")
        let recovered = try engine.snapshot(id: kept.id, controllerID: controllerID)
        expect(recovered.state == .failed && recovered.failure?.code == .workerRestarted,
               "a valid record beside unrecoverable ones was not recovered")
        for key in ["unrecoverable-maxseq-1", "unrecoverable-ceiling1", "unrecoverable-order-01", "unrecoverable-dropped"] {
            expect(!files.fileExists(atPath: recordURL(counterState, key).path), "\(key) was left in place")
            expect((try? engine.snapshot(controllerID: controllerID, idempotencyKey: key)) == nil,
                   "\(key) was loaded despite untrusted counters")
        }

        // Persist: both records decode within the size bound, but the recovery
        // notice and failure push the non-final record past it, so re-persisting
        // it throws resourceLimit. That record is quarantined intact; startup continues.
        let persistState = root.appendingPathComponent("unrecoverable-persist", isDirectory: true)
        let writer = try DroneJobStore(stateURL: persistState, limits: DroneJobEngineLimits())
        _ = try writer.create(create("unpersistable-job-01"))
        let finished = try writer.create(create("persistable-finished")).snapshot
        try writer.finish(id: finished.id, state: .completed, result: nil, failure: nil)
        let pending = try Data(contentsOf: recordURL(persistState, "unpersistable-job-01"))
        let finishedBytes = try Data(contentsOf: recordURL(persistState, "persistable-finished")).count
        var tight = DroneJobEngineLimits()
        tight.maximumStoredRecordBytes = max(pending.count, finishedBytes)
        let reopened = try DroneJobStore(stateURL: persistState, limits: tight)
        expect(reopened.quarantinedEntryCount == 1, "a record whose recovery persist failed was not quarantined")
        let survivor = try? reopened.snapshot(controllerID: controllerID, idempotencyKey: "persistable-finished")
        expect(survivor?.state == .completed, "a persistable record was lost when another record's persist failed")
        expect((try? reopened.snapshot(controllerID: controllerID, idempotencyKey: "unpersistable-job-01")) == nil,
               "a record whose recovery could not be persisted was served")
        expect(!files.fileExists(atPath: recordURL(persistState, "unpersistable-job-01").path),
               "an unpersistable record was left where it would be retried on every start")
        let entries = (try? files.contentsOfDirectory(
            at: persistState.appendingPathComponent("quarantine", isDirectory: true),
            includingPropertiesForKeys: nil
        )) ?? []
        expect(entries.count == 1 && entries.first.flatMap {
            try? Data(contentsOf: $0.appendingPathComponent("unpersistable-job-01.json"))
        } == pending, "the unpersistable record was not quarantined unchanged")
    }

    /// Starts `/bin/sleep` as the leader of its own process group, the shape
    /// `DroneProcessRunner` records in `processGroup`. The caller reaps it.
    private static func spawnGroupLeader() throws -> pid_t {
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw ProofError.failed("posix_spawnattr_init failed")
        }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0
        else { throw ProofError.failed("could not configure the fixture's process group") }
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("30"), nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, "/bin/sleep", nil, &attributes, argv, nil) == 0 else {
            throw ProofError.failed("could not start the fixture's process group")
        }
        return pid
    }

    /// #440: an expired record whose `jobs/` directory is read-only can be
    /// neither unlinked nor renamed into `quarantine/` (both need write access
    /// to the parent). Startup must skip it and report unhealthy storage, not
    /// fail with `storeCorrupted` and crash-loop under launchd.
    private static func verifyUnremovableExpiredRecord(in workspace: URL, root: URL) throws {
        // Root bypasses directory permissions, so the fixture cannot block the delete.
        guard geteuid() != 0 else { return }
        let workspaceID = UUID()
        let controllerID = UUID()
        let key = "unremovable-expired-1"
        let state = root.appendingPathComponent("unremovable-expired", isDirectory: true)
        let jobsURL = state.appendingPathComponent("controllers/\(controllerID.uuidString)/jobs", isDirectory: true)
        let recordURL = jobsURL.appendingPathComponent("\(key).json")
        let seeded = try DroneJobStore(stateURL: state, limits: DroneJobEngineLimits())
        let finished = try seeded.create(DroneJobCreate(
            controllerID: controllerID, idempotencyKey: key,
            request: DroneJobRequest(
                workspaceID: workspaceID,
                operation: .readFile(DroneReadFileOperation(relativePath: "main.swift"))
            )
        )).snapshot
        try seeded.finish(id: finished.id, state: .completed, result: nil, failure: nil)

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: jobsURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: jobsURL.path) }
        let lifetime = DroneJobEngineLimits().idempotencyLifetime
        let reopened: DroneJobStore
        do {
            reopened = try DroneJobStore(
                stateURL: state, limits: DroneJobEngineLimits(),
                now: { Date().timeIntervalSince1970 + lifetime + 1 }
            )
        } catch {
            throw ProofError.failed("an unremovable expired record failed startup: \(error)")
        }
        expect(reopened.quarantinedEntryCount == 1,
               "an unremovable expired record reported \(reopened.quarantinedEntryCount) unhealthy entries, expected 1")
        expect((try? reopened.snapshot(controllerID: controllerID, idempotencyKey: key)) == nil,
               "an unremovable expired record was served")
        expect(FileManager.default.fileExists(atPath: recordURL.path),
               "the fixture did not block deleting the expired record")
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
