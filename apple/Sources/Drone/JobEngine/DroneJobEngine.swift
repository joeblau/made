import Foundation

final class DroneJobEngine: @unchecked Sendable {
    private struct ExecutionOutcome {
        var state: DroneJobState
        var result: DroneJobResult?
        var failure: DroneJobFailure?
    }

    private let store: DroneJobStore
    private let workspaces: DroneWorkspaceRegistry
    private let limits: DroneJobEngineLimits
    private let gitExecutablePath: String
    private let controlsLock = NSCondition()
    private var pendingAcceptances = 0
    private var stopping = false
    private var controls: [DroneJobID: DroneProcessGroupControl] = [:]

    init(
        stateURL: URL,
        workspaces: DroneWorkspaceRegistry,
        limits: DroneJobEngineLimits = DroneJobEngineLimits(),
        gitExecutablePath: String = "/usr/bin/git",
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) throws {
        guard limits.maximumJobsPerController > 0,
              limits.maximumConcurrentJobs > 0,
              limits.maximumHistoryEvents >= 3,
              limits.maximumHistoryOutputBytes > 0,
              limits.maximumStoredRecordBytes > 0,
              limits.cancellationGracePeriod >= 0
        else { throw DroneJobError.invalidRequest }
        self.limits = limits
        self.workspaces = workspaces
        self.gitExecutablePath = gitExecutablePath
        store = try DroneJobStore(stateURL: stateURL, limits: limits, now: now)
    }

    func createJob(_ create: DroneJobCreate) throws -> DroneJobSnapshot {
        do {
            try DroneJobRequestValidator.validate(create, limits: limits)
        } catch let error as DroneProtocolError {
            switch error {
            case .resourceLimit: throw DroneJobError.resourceLimit
            default: throw DroneJobError.unauthorized
            }
        }
        try validateWorkspaceAccess(for: create.request)
        try beginAcceptance()
        defer { endAcceptance() }
        // Persistence may block. Never hold the lifecycle lock across it.
        let created = try store.create(create)
        if created.isNew {
            controlsLock.lock()
            startLocked(id: created.snapshot.id)
            controlsLock.unlock()
        }
        return created.snapshot
    }

    private func beginAcceptance() throws {
        controlsLock.lock()
        defer { controlsLock.unlock() }
        guard !stopping else { throw DroneJobError.shuttingDown }
        pendingAcceptances += 1
    }

    private func endAcceptance() {
        controlsLock.lock()
        pendingAcceptances -= 1
        controlsLock.broadcast()
        controlsLock.unlock()
    }

    func snapshot(id: DroneJobID, controllerID: UUID) throws -> DroneJobSnapshot {
        try store.snapshot(id: id, controllerID: controllerID)
    }

    func events(
        id: DroneJobID,
        controllerID: UUID,
        afterSequence: UInt64,
        maximumEvents: Int = 256
    ) throws -> DroneJobEventPage {
        try store.events(
            id: id,
            controllerID: controllerID,
            afterSequence: afterSequence,
            maximumEvents: maximumEvents
        )
    }

    func cancelJob(id: DroneJobID, controllerID: UUID) throws -> DroneJobSnapshot {
        let snapshot = try store.requestCancellation(id: id, controllerID: controllerID)
        controlsLock.lock()
        let control = controls[id]
        controlsLock.unlock()
        control?.cancel()
        return snapshot
    }

    /// Stops accepting work immediately, then cancels and joins owned tasks.
    /// False means the bounded wait expired; durable state is never deleted.
    func shutdown(timeout: TimeInterval = 5) async -> Bool {
        let boundedTimeout = timeout.isFinite ? min(10, max(0, timeout)) : 5
        let deadline = ContinuousClock.now + .seconds(boundedTimeout)
        return await withCheckedContinuation { continuation in
            let active = beginShutdown()
            DispatchQueue.global(qos: .utility).async { [self] in
                // Do not wait on persistence here: a task may already be
                // blocked in the store. It records cancellation when it exits.
                for control in active.values { control.cancel() }
                continuation.resume(returning: waitForShutdown(deadline: deadline))
            }
        }
    }

    private func beginShutdown() -> [DroneJobID: DroneProcessGroupControl] {
        controlsLock.lock()
        defer { controlsLock.unlock() }
        stopping = true
        return controls
    }

    private func waitForShutdown(deadline: ContinuousClock.Instant) -> Bool {
        controlsLock.lock()
        defer { controlsLock.unlock() }
        while pendingAcceptances > 0 || !controls.isEmpty {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { return false }
            let components = remaining.components
            let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
            _ = controlsLock.wait(until: Date().addingTimeInterval(seconds))
        }
        return true
    }

    // Caller holds controlsLock only for task registration, never persistence.
    private func startLocked(id: DroneJobID) {
        let control = DroneProcessGroupControl(gracePeriod: limits.cancellationGracePeriod)
        if stopping { control.cancel() }
        controls[id] = control
        DispatchQueue.global(qos: .utility).async { [self] in
            defer {
                controlsLock.lock()
                controls.removeValue(forKey: id)
                controlsLock.broadcast()
                controlsLock.unlock()
            }
            do {
                try store.markRunning(id: id)
                if try store.snapshot(
                    id: id,
                    controllerID: controllerID(for: id)
                ).cancellationRequested { control.cancel() }
                let outcome = try execute(id: id, control: control)
                try store.finish(
                    id: id,
                    state: outcome.state,
                    result: outcome.result,
                    failure: outcome.failure
                )
            } catch {
                let code: DroneJobFailureCode = switch operationKind(for: id) {
                case .process, .gitStatus, .gitDiff: .launchFailed
                default: .operationFailed
                }
                try? store.finish(
                    id: id,
                    state: .failed,
                    result: nil,
                    failure: DroneJobFailure(code: code, message: String(describing: error))
                )
            }
        }
    }

    private func execute(id: DroneJobID, control: DroneProcessGroupControl) throws -> ExecutionOutcome {
        if control.requestedStop != nil {
            return ExecutionOutcome(state: .cancelled, result: nil, failure: nil)
        }
        let job = try store.snapshot(id: id, controllerID: controllerID(for: id))
        let environment = try DroneJobEnvironment.make(requested: job.request.environment)
        switch job.request.operation {
        case .process(let operation):
            let directory = try workspaces.resolve(
                operation.relativeDirectory,
                workspaceID: job.request.workspaceID
            )
            return try runProcess(
                operation,
                id: id,
                directory: directory,
                environment: environment,
                control: control
            )
        case .readFile(let operation):
            let data = try DroneWorkspaceOperations.readFile(
                workspace: workspaces,
                workspaceID: job.request.workspaceID,
                operation: operation
            )
            return ExecutionOutcome(state: .completed, result: .file(data), failure: nil)
        case .writeFile(let operation):
            let count = try DroneWorkspaceOperations.writeFile(
                workspace: workspaces,
                workspaceID: job.request.workspaceID,
                operation: operation
            )
            return ExecutionOutcome(state: .completed, result: .bytesWritten(count), failure: nil)
        case .listDirectory(let operation):
            let entries = try DroneWorkspaceOperations.listDirectory(
                workspace: workspaces,
                workspaceID: job.request.workspaceID,
                operation: operation
            )
            return ExecutionOutcome(state: .completed, result: .directory(entries), failure: nil)
        case .gitStatus(let operation):
            let process = DroneProcessOperation(
                executablePath: gitExecutablePath,
                arguments: [
                    "--no-optional-locks", "status", "--porcelain=v1", "--branch", "-z",
                ],
                relativeDirectory: operation.relativeDirectory,
                timeoutMilliseconds: operation.timeoutMilliseconds,
                standardOutputLimit: operation.outputLimit,
                standardErrorLimit: operation.outputLimit
            )
            return try runProcess(
                process,
                id: id,
                directory: workspaces.resolve(
                    operation.relativeDirectory,
                    workspaceID: job.request.workspaceID
                ),
                environment: environment,
                control: control
            )
        case .gitDiff(let operation):
            var arguments = ["--no-optional-locks", "diff", "--no-ext-diff", "--no-textconv"]
            if let path = operation.relativePath { arguments += ["--", path] }
            let process = DroneProcessOperation(
                executablePath: gitExecutablePath,
                arguments: arguments,
                relativeDirectory: operation.relativeDirectory,
                timeoutMilliseconds: operation.timeoutMilliseconds,
                standardOutputLimit: operation.outputLimit,
                standardErrorLimit: operation.outputLimit
            )
            return try runProcess(
                process,
                id: id,
                directory: workspaces.resolve(
                    operation.relativeDirectory,
                    workspaceID: job.request.workspaceID
                ),
                environment: environment,
                control: control
            )
        }
    }

    private func runProcess(
        _ operation: DroneProcessOperation,
        id: DroneJobID,
        directory: URL,
        environment: [String: String],
        control: DroneProcessGroupControl
    ) throws -> ExecutionOutcome {
        let outcome = try DroneProcessRunner.run(
            operation: operation,
            currentDirectory: directory,
            environment: environment,
            control: control,
            onOutput: { [store, limits] stream, data in
                let chunkSize = min(DroneLimits.maxOutputChunkBytes, limits.maximumHistoryOutputBytes)
                var remainder = data
                while !remainder.isEmpty {
                    let chunk = remainder.prefix(chunkSize)
                    try store.appendOutput(id: id, stream: stream, data: Data(chunk))
                    remainder.removeFirst(chunk.count)
                }
            },
            onTruncated: { [store] stream in
                try store.appendTruncation(id: id, stream: stream)
            }
        )
        let result = DroneJobResult.process(DroneProcessResult(
            exitCode: outcome.exitCode,
            signal: outcome.signal,
            standardOutputTruncated: outcome.standardOutputTruncated,
            standardErrorTruncated: outcome.standardErrorTruncated
        ))
        if outcome.wasCancelled {
            return ExecutionOutcome(state: .cancelled, result: result, failure: nil)
        }
        if outcome.deadlineExceeded {
            return ExecutionOutcome(
                state: .failed,
                result: result,
                failure: DroneJobFailure(
                    code: .deadlineExceeded,
                    message: "The process exceeded its execution deadline."
                )
            )
        }
        if outcome.exitCode == 0 {
            return ExecutionOutcome(state: .completed, result: result, failure: nil)
        }
        return ExecutionOutcome(
            state: .failed,
            result: result,
            failure: DroneJobFailure(
                code: .nonZeroExit,
                message: "The process exited unsuccessfully."
            )
        )
    }

    private func validateWorkspaceAccess(for request: DroneJobRequest) throws {
        switch request.operation {
        case .process(let operation):
            _ = try workspaces.resolve(
                operation.relativeDirectory,
                workspaceID: request.workspaceID
            )
        case .readFile(let operation):
            _ = try workspaces.resolve(operation.relativePath, workspaceID: request.workspaceID)
        case .writeFile(let operation):
            _ = try workspaces.resolve(
                operation.relativePath,
                workspaceID: request.workspaceID,
                allowMissingLeaf: true
            )
        case .listDirectory(let operation):
            _ = try workspaces.resolve(operation.relativePath, workspaceID: request.workspaceID)
        case .gitStatus(let operation):
            _ = try workspaces.resolve(
                operation.relativeDirectory,
                workspaceID: request.workspaceID
            )
        case .gitDiff(let operation):
            _ = try workspaces.resolve(
                operation.relativeDirectory,
                workspaceID: request.workspaceID
            )
            if let path = operation.relativePath {
                _ = try workspaces.resolve(
                    path,
                    workspaceID: request.workspaceID,
                    allowMissingLeaf: true
                )
            }
        }
    }

    private func controllerID(for id: DroneJobID) throws -> UUID {
        try store.controllerID(for: id)
    }

    private func operationKind(for id: DroneJobID) -> DroneJobOperation? {
        try? store.operation(for: id)
    }
}
