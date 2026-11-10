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
        try verifyLaunchMarkerPrecedesSpawn(in: workspace)
        try await verifyFinishRecordsSurvivingGroup(in: workspace, root: root)
        try verifyUnverifiedGroupRecovery(in: workspace, root: root)
        try await verifyOrphanedGroupWithZombieMember(in: workspace)
        verifyGroupListingFailureIsNotEmpty()

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
        // The engine itself (not a hand-seeded store) wrote the launching
        // marker and the leader's group before the job ran (#441).
        let record = storedRecord(root.appendingPathComponent("background-child"), controllerID, "background-child-job-0001")
        expect(record?["launching"] as? Bool == true, "an engine-run process job never persisted its launching marker")
        expect((record?["processGroup"] as? [String: Any])?["groupID"] is Int,
               "an engine-run process job never persisted its process group")
        let pidFile = workspace.appendingPathComponent("background.pid")
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let child = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { throw ProofError.failed("background child never started") }
        defer { _ = Darwin.kill(child, SIGKILL) }
        // finish() waits for the killed group before the job is recorded, so
        // the child is no longer running the moment the record is terminal
        // (it may still be a zombie until launchd reaps it).
        expect(DroneProcessTable.entry(child).map(\.isZombie) ?? true,
               "a job was recorded finished while its background child was still running")
        expect(engine.unverifiedProcessGroupCount == 0, "a group that exited was reported unverified")
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
        // What recovery relies on was on disk before the worker died: the
        // engine marked the job launching and recorded the leader's group.
        let crashed = storedRecord(state, controllerID, "crash-recovery-job-0001")
        expect(crashed?["launching"] as? Bool == true, "the crashed engine never persisted its launching marker")
        expect((crashed?["processGroup"] as? [String: Any])?["groupID"] as? Int == Int(leader),
               "the crashed engine never persisted the leader's process group")
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
        expect(recovered.unverifiedProcessGroupCount == 0,
               "recovery reported a group it killed and confirmed gone as unverified")
        try await waitUntilGone(orphan)
        expect(Darwin.kill(orphan, 0) != 0, "recovery left the crashed job's process group running")
        expect(Darwin.kill(leader, 0) != 0, "recovery left the crashed job's leader running")
    }

    /// #441: the launching marker is written before any process exists, and a
    /// marker that cannot be written means nothing is spawned at all.
    private static func verifyLaunchMarkerPrecedesSpawn(in workspace: URL) throws {
        let marker = workspace.appendingPathComponent("launch-marker.txt")
        try? FileManager.default.removeItem(at: marker)
        let operation = DroneProcessOperation(
            executablePath: "/usr/bin/touch", arguments: ["launch-marker.txt"], timeoutMilliseconds: 10_000
        )
        do {
            _ = try DroneProcessRunner.run(
                operation: operation,
                currentDirectory: workspace,
                environment: [:],
                control: DroneProcessGroupControl(gracePeriod: 0.1),
                beforeLaunch: { throw ProofError.failed("marker write failed") },
                onLaunch: { _ in fatalError("a process was spawned without its launching marker") },
                onOutput: { _, _ in },
                onTruncated: { _ in }
            )
            throw ProofError.failed("run continued after the launching marker failed")
        } catch ProofError.failed(let message) where message == "marker write failed" {}
        expect(!FileManager.default.fileExists(atPath: marker.path),
               "a process ran although its launching marker was never written")

        var markerWritten = false
        let outcome = try DroneProcessRunner.run(
            operation: operation,
            currentDirectory: workspace,
            environment: [:],
            control: DroneProcessGroupControl(gracePeriod: 0.1),
            beforeLaunch: {
                expect(!FileManager.default.fileExists(atPath: marker.path), "spawned before the marker")
                markerWritten = true
            },
            onLaunch: { _ in expect(markerWritten, "group recorded before the launching marker") },
            onOutput: { _, _ in },
            onTruncated: { _ in }
        )
        expect(outcome.exitCode == 0 && FileManager.default.fileExists(atPath: marker.path),
               "launch-marker proof process did not run")
    }

    /// #441: SIGKILL is asynchronous, so a finished job waits (bounded) for its
    /// group to disappear. A member that outlives the wait is recorded on the
    /// job, keeps storage unhealthy, and keeps the record from being purged.
    private static func verifyFinishRecordsSurvivingGroup(in workspace: URL, root: URL) async throws {
        let workspaceID = UUID()
        let registry = try DroneWorkspaceRegistry(workspaces: [workspaceID: workspace])
        var limits = DroneJobEngineLimits()
        limits.processGroupExitTimeout = 0.2
        // Model a member this user cannot kill (a setuid descendant) as a
        // live process that never leaves the group.
        let survivor = getpid()
        let engine = try DroneJobEngine(
            stateURL: root.appendingPathComponent("finish-survivor"),
            workspaces: registry,
            limits: limits,
            processGroupMembers: { _ in [survivor] }
        )
        let controllerID = UUID()
        let job = try engine.createJob(DroneJobCreate(
            controllerID: controllerID,
            idempotencyKey: "finish-survivor-job-01",
            request: DroneJobRequest(workspaceID: workspaceID, operation: .process(DroneProcessOperation(
                executablePath: "/usr/bin/true", timeoutMilliseconds: 10_000
            )))
        ))
        _ = try await terminal(job.id, controllerID: controllerID, engine: engine, expected: .completed)
        expect(engine.unverifiedProcessGroupCount == 1,
               "a job whose group outlived SIGKILL was recorded finished silently")
        let page = try engine.events(id: job.id, controllerID: controllerID, afterSequence: 0)
        expect(page.events.contains { $0.payload == .notice(.processGroupUnverified) },
               "the surviving group was not recorded on the job")
        // Revocation still deletes the controller's record (request, output,
        // result) at once; the worker keeps only its own ledger entry.
        _ = try engine.removeFinishedJobs(controllerID: controllerID)
        expect((try? engine.snapshot(id: job.id, controllerID: controllerID)) == nil,
               "revocation kept a finished record because its group was unverified")
        expect(engine.unverifiedProcessGroupCount == 1, "revocation discarded the unverified-group evidence")
        let ledger = root.appendingPathComponent("finish-survivor/unverified-groups/\(job.id.rawValue.uuidString).json")
        let entry = (try? Data(contentsOf: ledger)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        expect(entry != nil, "the unverified group was not written to the worker's ledger")
        expect(entry.map { Set($0.keys).isDisjoint(with: ["controllerID", "idempotencyKey", "request", "events", "result"]) } == true,
               "the worker's ledger kept controller data")
        let stopped = await engine.shutdown()
        expect(stopped, "finish-survivor engine did not shut down")
    }

    /// #441: recovery never silently finalizes a job whose process group it
    /// cannot confirm gone: a refused or partial kill, or a launch that never
    /// recorded its group, is recorded on the job and keeps storage unhealthy
    /// across restarts until a later recovery confirms the group gone.
    private static func verifyUnverifiedGroupRecovery(in workspace: URL, root: URL) throws {
        let workspaceID = UUID()
        let registry = try DroneWorkspaceRegistry(workspaces: [workspaceID: workspace])
        let controllerID = UUID()
        let limits = DroneJobEngineLimits()
        let clock = ProofManualClock()
        func process(_ key: String) -> DroneJobCreate {
            DroneJobCreate(controllerID: controllerID, idempotencyKey: key, request: DroneJobRequest(
                workspaceID: workspaceID,
                operation: .process(DroneProcessOperation(
                    executablePath: "/bin/sleep", arguments: ["30"], timeoutMilliseconds: 60_000
                ))
            ))
        }
        func storedFlag(_ state: URL, _ key: String) -> Bool? {
            let url = state.appendingPathComponent("controllers/\(controllerID.uuidString)/jobs/\(key).json")
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return (object["processGroupUnverified"] as? Bool) ?? false
        }
        func unverifiedNotices(_ store: DroneJobStore, _ id: DroneJobID) throws -> Int {
            try store.events(id: id, controllerID: controllerID, afterSequence: 0).events.filter {
                $0.payload == .notice(.processGroupUnverified)
            }.count
        }

        let state = root.appendingPathComponent("unverified-recovery")
        let seeded = try DroneJobStore(stateURL: state, limits: limits, now: { clock.now() })
        // A record naming the worker's own process group is never signalled,
        // so its group cannot be confirmed gone.
        let refused = try seeded.create(process("unverified-own-group-01")).snapshot
        try seeded.markRunning(id: refused.id)
        try seeded.markLaunching(id: refused.id)
        try seeded.recordProcessGroup(id: refused.id, group: DroneProcessGroupRecord(
            groupID: getpgrp(), leaderStartSeconds: 0, leaderStartMicroseconds: 0
        ))
        // The worker died between the spawn and recording the group.
        let unrecorded = try seeded.create(process("unverified-no-group-001")).snapshot
        try seeded.markRunning(id: unrecorded.id)
        try seeded.markLaunching(id: unrecorded.id)
        // Control: a group that has already exited is confirmed gone.
        let exited = Process()
        exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try exited.run()
        exited.waitUntilExit()
        let clean = try seeded.create(process("unverified-clean-00001")).snapshot
        try seeded.markRunning(id: clean.id)
        try seeded.markLaunching(id: clean.id)
        try seeded.recordProcessGroup(id: clean.id, group: DroneProcessGroupRecord(
            groupID: exited.processIdentifier, leaderStartSeconds: 0, leaderStartMicroseconds: 0
        ))

        let recovered = try DroneJobStore(stateURL: state, limits: limits, now: { clock.now() })
        expect(recovered.unverifiedProcessGroupCount == 2,
               "recovery finalized \(2 - recovered.unverifiedProcessGroupCount) unverified groups silently")
        for (id, key) in [(refused.id, "unverified-own-group-01"), (unrecorded.id, "unverified-no-group-001")] {
            let snapshot = try recovered.snapshot(id: id, controllerID: controllerID)
            expect(snapshot.state == .failed && snapshot.failure?.code == .workerRestarted,
                   "an unverified job was not recovered as workerRestarted")
            let notices = try unverifiedNotices(recovered, id)
            expect(notices == 1, "the unverified group was not recorded on the job")
            expect(storedFlag(state, key) == true, "the unverified group was not persisted on the record")
        }
        let cleanNotices = try unverifiedNotices(recovered, clean.id)
        expect(cleanNotices == 0 && storedFlag(state, "unverified-clean-00001") == false,
               "a group that had exited was reported unverified")
        let engine = try DroneJobEngine(stateURL: state, workspaces: registry, now: { clock.now() })
        expect(engine.unverifiedProcessGroupCount == 2, "a restart forgot the unverified groups")

        // Past the idempotency lifetime every finished record expires as
        // usual, flagged or not, and its key is free again; the evidence of
        // an unverified group stays in the worker's own ledger.
        clock.advance(by: limits.idempotencyLifetime + 1)
        let expired = try DroneJobStore(stateURL: state, limits: limits, now: { clock.now() })
        _ = try expired.purgeExpired()
        _ = try expired.removeFinishedJobs(controllerID: controllerID)
        expect(expired.unverifiedProcessGroupCount == 2, "expiry discarded the unverified-group evidence")
        for key in ["unverified-own-group-01", "unverified-no-group-001", "unverified-clean-00001"] {
            expect(storedFlag(state, key) == nil, "an expired record was kept")
        }
        expect((try? expired.snapshot(id: refused.id, controllerID: controllerID)) == nil,
               "an expired record with an unverified group stayed readable")
        let reused = try expired.create(process("unverified-own-group-01"))
        expect(reused.isNew && reused.snapshot.id != refused.id,
               "an expired record with an unverified group kept its idempotency key")
        let ledgerEntries = (try? FileManager.default.contentsOfDirectory(
            atPath: state.appendingPathComponent("unverified-groups").path
        ))?.filter { $0.hasSuffix(".json") } ?? []
        expect(ledgerEntries.count == 2, "the worker's ledger does not hold one entry per unverified group")
        let restarted = try DroneJobStore(stateURL: state, limits: limits, now: { clock.now() })
        expect(restarted.unverifiedProcessGroupCount == 2, "a restart forgot unverified groups whose records expired")

        // A kill that does not finish within its bound is unverified too; a
        // later recovery that confirms the group gone clears the flag.
        let partialState = root.appendingPathComponent("unverified-partial-kill")
        let partialSeed = try DroneJobStore(stateURL: partialState, limits: limits)
        let partial = try partialSeed.create(process("unverified-partial-0001")).snapshot
        try partialSeed.markRunning(id: partial.id)
        try partialSeed.recordProcessGroup(id: partial.id, group: DroneProcessGroupRecord(
            groupID: 424_242, leaderStartSeconds: 1, leaderStartMicroseconds: 0
        ))
        let survived = try DroneJobStore(stateURL: partialState, limits: limits, reapOrphanedGroup: { _ in false })
        expect(survived.unverifiedProcessGroupCount == 1, "a partial kill was finalized silently")
        let partialSnapshot = try survived.snapshot(id: partial.id, controllerID: controllerID)
        expect(partialSnapshot.state == .failed, "a partially killed job was not finalized")
        let confirmed = try DroneJobStore(stateURL: partialState, limits: limits, reapOrphanedGroup: { _ in true })
        expect(confirmed.unverifiedProcessGroupCount == 0 && storedFlag(partialState, "unverified-partial-0001") == false,
               "a group confirmed gone on a later recovery stayed unverified")
        let confirmedNotices = try unverifiedNotices(confirmed, partial.id)
        expect(confirmedNotices == 1, "clearing the flag lost the job's history")
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

    /// #441: a zombie never blocks recovery. `proc_pidinfo` cannot read a
    /// zombie although `kill(pid, 0)` still succeeds, so a recorded group
    /// whose leader was reaped, with one live member and one exited but
    /// unreaped child, must still be killed and confirmed gone.
    private static func verifyOrphanedGroupWithZombieMember(in workspace: URL) async throws {
        let pidFile = workspace.appendingPathComponent("zombie-member.pid")
        try? FileManager.default.removeItem(at: pidFile)
        // The member execs a sleep that never reaps its short-lived child,
        // which therefore stays a zombie inside the group.
        let leader = try spawnSuspendedGroupLeader("/bin/sh", ["-c", """
            /bin/sh -c '/bin/sleep 0.1 & exec /bin/sleep 30' &
            echo $! > "$1/zombie-member.tmp" && /bin/mv "$1/zombie-member.tmp" "$1/zombie-member.pid"
            """, "sh", workspace.path])
        guard let record = DroneProcessGroupRecord.capture(leader: leader) else {
            _ = Darwin.kill(-leader, SIGKILL)
            throw ProofError.failed("zombie proof leader could not be captured")
        }
        _ = Darwin.kill(leader, SIGCONT)
        var status: Int32 = 0
        while Darwin.waitpid(leader, &status, 0) < 0, errno == EINTR {}
        var member: pid_t?
        try await waitUntil("zombie proof member never started") {
            member = (try? String(contentsOf: pidFile, encoding: .utf8))
                .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return member != nil
        }
        guard let member else { throw ProofError.failed("zombie proof member never started") }
        defer { _ = Darwin.kill(-record.groupID, SIGKILL) }
        var zombie: pid_t?
        try await waitUntil("zombie proof child never became a zombie") {
            zombie = DroneProcessTable.members(ofGroup: record.groupID)?.first {
                DroneProcessTable.entry($0)?.isZombie == true
            }
            return zombie != nil
        }
        expect(zombie.map { Darwin.kill($0, 0) } == 0, "zombie proof child was reaped before the check")
        expect(DroneProcessTable.liveMembers(ofGroup: record.groupID) == [member],
               "a zombie was counted as a running group member")
        expect(DroneProcessTable.killOrphanedGroup(record),
               "a zombie member kept recovery from killing and confirming its group gone")
        try await waitUntilGone(member)
        expect(Darwin.kill(member, 0) != 0, "recovery left the group's live member running")
    }

    /// #441: libproc reports a failed listing as 0 bytes with errno set, which
    /// must never read as an empty (gone) group.
    private static func verifyGroupListingFailureIsNotEmpty() {
        expect(DroneProcessTable.listedCount(bytes: 0, error: ENOMEM, limit: 16) == nil,
               "a failed group listing was reported as an empty group")
        expect(DroneProcessTable.listedCount(bytes: -1, error: EPERM, limit: 16) == nil,
               "a rejected group listing was reported as an empty group")
        expect(DroneProcessTable.listedCount(bytes: 0, error: 0, limit: 16) == 0,
               "an empty group listing was reported as a failure")
        expect(DroneProcessTable.members(ofGroup: getpgrp())?.contains(getpid()) == true,
               "the proof's own process group could not be listed")
    }

    private static func spawnSuspendedGroupLeader(_ executable: String, _ arguments: [String]) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw ProofError.failed("spawn attributes") }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setflags(
                  &attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_START_SUSPENDED)
              ) == 0
        else { throw ProofError.failed("spawn attributes") }
        let values = ([executable] + arguments).map { strdup($0) }
        defer { for value in values { free(value) } }
        var pointers = values
        pointers.append(nil)
        var pid = pid_t()
        let result = posix_spawn(&pid, executable, nil, &attributes, &pointers, environ)
        guard result == 0 else { throw ProofError.failed("spawn failed: \(result)") }
        return pid
    }

    private static func storedRecord(_ state: URL, _ controller: UUID, _ key: String) -> [String: Any]? {
        let url = state.appendingPathComponent("controllers/\(controller.uuidString)/jobs/\(key).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
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
