import Darwin
import Foundation

struct DroneStoredJob: Codable, Equatable {
    var id: DroneJobID
    var controllerID: UUID
    var idempotencyKey: String
    var request: DroneJobRequest
    var state: DroneJobState
    var createdAt: TimeInterval
    var updatedAt: TimeInterval
    var result: DroneJobResult?
    var failure: DroneJobFailure?
    var latestSequence: UInt64
    var droppedEventCount: UInt64
    var cancellationRequested: Bool
    var events: [DroneJobEvent]
    /// Persisted before the leader runs so recovery can kill a group that a
    /// crashed worker left behind. Absent in records written before #441.
    var processGroup: DroneProcessGroupRecord?

    var snapshot: DroneJobSnapshot {
        DroneJobSnapshot(
            id: id,
            controllerID: controllerID,
            idempotencyKey: idempotencyKey,
            request: request,
            state: state,
            createdAt: createdAt,
            updatedAt: updatedAt,
            result: result,
            failure: failure,
            latestSequence: latestSequence,
            earliestRetainedSequence: events.first?.sequence ?? latestSequence + 1,
            droppedEventCount: droppedEventCount,
            cancellationRequested: cancellationRequested
        )
    }
}

final class DroneJobStore: @unchecked Sendable {
    private struct JobKey: Hashable {
        var controllerID: UUID
        var idempotencyKey: String
    }

    private let lock = NSLock()
    private let stateURL: URL
    private let limits: DroneJobEngineLimits
    private let now: @Sendable () -> TimeInterval
    private var jobs: [DroneJobID: DroneStoredJob] = [:]
    private var keys: [JobKey: DroneJobID] = [:]

    init(
        stateURL: URL,
        limits: DroneJobEngineLimits,
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) throws {
        self.stateURL = stateURL.standardizedFileURL
        self.limits = limits
        self.now = now
        try Self.createPrivateDirectory(at: self.stateURL)
        try recover()
    }

    func create(_ create: DroneJobCreate) throws -> (snapshot: DroneJobSnapshot, isNew: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let key = JobKey(controllerID: create.controllerID, idempotencyKey: create.idempotencyKey)
        if let existingID = keys[key], let existing = jobs[existingID] {
            if now() - existing.createdAt >= limits.idempotencyLifetime,
               existing.state.isTerminal {
                try remove(existing)
            } else {
                guard existing.request == create.request else {
                    throw DroneJobError.idempotencyConflict
                }
                return (existing.snapshot, false)
            }
        }
        try purgeExpired(controllerID: create.controllerID)
        let controllerJobs = jobs.values.filter { $0.controllerID == create.controllerID }
        guard controllerJobs.count < limits.maximumJobsPerController,
              jobs.values.filter({ !$0.state.isTerminal }).count < limits.maximumConcurrentJobs
        else { throw DroneJobError.resourceLimit }

        let timestamp = now()
        let id = DroneJobID()
        let event = DroneJobEvent(sequence: 1, timestamp: timestamp, payload: .state(.accepted))
        let job = DroneStoredJob(
            id: id,
            controllerID: create.controllerID,
            idempotencyKey: create.idempotencyKey,
            request: create.request,
            state: .accepted,
            createdAt: timestamp,
            updatedAt: timestamp,
            result: nil,
            failure: nil,
            latestSequence: 1,
            droppedEventCount: 0,
            cancellationRequested: false,
            events: [event]
        )
        try persist(job)
        jobs[id] = job
        keys[key] = id
        return (job.snapshot, true)
    }

    func snapshot(id: DroneJobID, controllerID: UUID) throws -> DroneJobSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return try authorizedJob(id: id, controllerID: controllerID).snapshot
    }

    func snapshot(controllerID: UUID, idempotencyKey: String) throws -> DroneJobSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let key = JobKey(controllerID: controllerID, idempotencyKey: idempotencyKey)
        guard let id = keys[key], let job = jobs[id] else { throw DroneJobError.jobNotFound }
        return job.snapshot
    }

    func controllerID(for id: DroneJobID) throws -> UUID {
        lock.lock()
        defer { lock.unlock() }
        guard let job = jobs[id] else { throw DroneJobError.jobNotFound }
        return job.controllerID
    }

    func operation(for id: DroneJobID) throws -> DroneJobOperation {
        lock.lock()
        defer { lock.unlock() }
        guard let job = jobs[id] else { throw DroneJobError.jobNotFound }
        return job.request.operation
    }

    func events(
        id: DroneJobID,
        controllerID: UUID,
        afterSequence: UInt64,
        maximumEvents: Int = 256
    ) throws -> DroneJobEventPage {
        lock.lock()
        defer { lock.unlock() }
        let job = try authorizedJob(id: id, controllerID: controllerID)
        guard maximumEvents > 0, maximumEvents <= 256,
              afterSequence <= job.latestSequence
        else { throw DroneJobError.invalidRequest }
        let earliest = job.events.first?.sequence ?? job.latestSequence + 1
        if afterSequence < job.latestSequence + 1, afterSequence + 1 < earliest {
            throw DroneJobError.outputGap
        }
        var selected: [DroneJobEvent] = []
        var outputBytes = 0
        for event in job.events where event.sequence > afterSequence {
            guard selected.count < maximumEvents else { break }
            if case .output(let output) = event.payload {
                guard outputBytes + output.data.count <= DroneLimits.maxReconnectQueueBytes else {
                    break
                }
                outputBytes += output.data.count
            }
            selected.append(event)
        }
        return DroneJobEventPage(
            events: selected,
            latestSequence: job.latestSequence,
            droppedEventCount: job.droppedEventCount
        )
    }

    func markRunning(id: DroneJobID) throws {
        try update(id: id) { job in
            guard job.state == .accepted else { return }
            job.state = .running
            append(.state(.running), to: &job)
        }
    }

    func recordProcessGroup(id: DroneJobID, group: DroneProcessGroupRecord) throws {
        try update(id: id) { job in
            job.processGroup = group
        }
    }

    func appendOutput(id: DroneJobID, stream: DroneJobStream, data: Data) throws {
        guard !data.isEmpty else { return }
        try update(id: id) { job in
            guard !job.state.isTerminal else { return }
            append(.output(DroneJobOutput(stream: stream, data: data)), to: &job)
        }
    }

    func appendTruncation(id: DroneJobID, stream: DroneJobStream) throws {
        try update(id: id) { job in
            guard !job.state.isTerminal else { return }
            append(.truncated(stream), to: &job)
        }
    }

    func requestCancellation(id: DroneJobID, controllerID: UUID) throws -> DroneJobSnapshot {
        lock.lock()
        defer { lock.unlock() }
        var job = try authorizedJob(id: id, controllerID: controllerID)
        guard !job.state.isTerminal else { return job.snapshot }
        let original = job
        job.cancellationRequested = true
        job.updatedAt = now()
        do {
            try persist(job)
        } catch {
            jobs[id] = original
            throw error
        }
        jobs[id] = job
        return job.snapshot
    }

    func finish(
        id: DroneJobID,
        state: DroneJobState,
        result: DroneJobResult?,
        failure: DroneJobFailure?
    ) throws {
        try update(id: id) { job in
            guard !job.state.isTerminal else { return }
            let finalState = job.cancellationRequested ? DroneJobState.cancelled : state
            job.state = finalState
            job.result = result
            job.failure = finalState == .failed ? failure : nil
            append(.state(finalState), to: &job)
        }
    }

    private func update(id: DroneJobID, mutation: (inout DroneStoredJob) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var job = jobs[id] else { throw DroneJobError.jobNotFound }
        let original = job
        mutation(&job)
        guard job != original else { return }
        job.updatedAt = now()
        do {
            try persist(job)
        } catch {
            jobs[id] = original
            throw error
        }
        jobs[id] = job
    }

    private func append(_ payload: DroneJobEventPayload, to job: inout DroneStoredJob) {
        job.latestSequence += 1
        job.events.append(DroneJobEvent(
            sequence: job.latestSequence,
            timestamp: now(),
            payload: payload
        ))
        trimHistory(of: &job)
    }

    private func trimHistory(of job: inout DroneStoredJob) {
        var outputBytes = job.events.reduce(0) { total, event in
            if case .output(let output) = event.payload { return total + output.data.count }
            return total
        }
        while job.events.count > 1,
              job.events.count > limits.maximumHistoryEvents
                || outputBytes > limits.maximumHistoryOutputBytes {
            let removed = job.events.removeFirst()
            if case .output(let output) = removed.payload { outputBytes -= output.data.count }
            job.droppedEventCount += 1
        }
    }

    private func authorizedJob(id: DroneJobID, controllerID: UUID) throws -> DroneStoredJob {
        guard let job = jobs[id] else { throw DroneJobError.jobNotFound }
        guard job.controllerID == controllerID else { throw DroneJobError.unauthorized }
        return job
    }

    private func purgeExpired(controllerID: UUID) throws {
        let expired = jobs.values.filter {
            $0.controllerID == controllerID && $0.state.isTerminal
                && now() - $0.createdAt >= limits.idempotencyLifetime
        }
        for job in expired { try remove(job) }
    }

    private func remove(_ job: DroneStoredJob) throws {
        let key = JobKey(controllerID: job.controllerID, idempotencyKey: job.idempotencyKey)
        try FileManager.default.removeItem(at: fileURL(for: job))
        jobs.removeValue(forKey: job.id)
        keys.removeValue(forKey: key)
    }

    private func recover() throws {
        let controllersURL = stateURL.appendingPathComponent("controllers", isDirectory: true)
        try Self.createPrivateDirectory(at: controllersURL)
        guard let controllers = FileManager.default.enumerator(
            at: controllersURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { throw DroneJobError.storeCorrupted }
        for case let controllerURL as URL in controllers {
            guard let controllerID = UUID(uuidString: controllerURL.lastPathComponent) else {
                throw DroneJobError.storeCorrupted
            }
            let jobsURL = controllerURL.appendingPathComponent("jobs", isDirectory: true)
            guard let records = FileManager.default.enumerator(
                at: jobsURL,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) else { throw DroneJobError.storeCorrupted }
            var controllerCount = 0
            for case let recordURL as URL in records {
                controllerCount += 1
                guard controllerCount <= limits.maximumJobsPerController,
                      recordURL.pathExtension == "json",
                      let size = try recordURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= limits.maximumStoredRecordBytes,
                      let data = try? Data(contentsOf: recordURL, options: []),
                      var job = try? decoder().decode(DroneStoredJob.self, from: data),
                      job.controllerID == controllerID,
                      jobs[job.id] == nil
                else { throw DroneJobError.storeCorrupted }
                let key = JobKey(controllerID: job.controllerID, idempotencyKey: job.idempotencyKey)
                guard keys[key] == nil else { throw DroneJobError.storeCorrupted }
                if !job.state.isTerminal {
                    // Kill before recording a final state: a finished job
                    // must never leave its process group running (#441).
                    if let group = job.processGroup {
                        DroneProcessTable.killOrphanedGroup(group)
                    }
                    append(.notice(.recoveredAfterRestart), to: &job)
                    job.state = job.cancellationRequested ? .cancelled : .failed
                    if !job.cancellationRequested {
                        job.failure = DroneJobFailure(
                            code: .workerRestarted,
                            message: "The worker restarted before this job reached a final state."
                        )
                    }
                    job.updatedAt = now()
                    try persist(job)
                }
                jobs[job.id] = job
                keys[key] = job.id
            }
        }
    }

    private func persist(_ job: DroneStoredJob) throws {
        let url = fileURL(for: job)
        try Self.createPrivateDirectory(at: url.deletingLastPathComponent())
        let data = try encoder().encode(job)
        guard data.count <= limits.maximumStoredRecordBytes else {
            throw DroneJobError.resourceLimit
        }
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporaryURL, options: [])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
            let descriptor = temporaryURL.path.withCString { Darwin.open($0, O_RDONLY) }
            if descriptor >= 0 {
                _ = Darwin.fsync(descriptor)
                _ = Darwin.close(descriptor)
            }
            guard temporaryURL.path.withCString({ temporary in
                url.path.withCString({ destination in Darwin.rename(temporary, destination) })
            }) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func fileURL(for job: DroneStoredJob) -> URL {
        stateURL
            .appendingPathComponent("controllers", isDirectory: true)
            .appendingPathComponent(job.controllerID.uuidString, isDirectory: true)
            .appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent("\(job.idempotencyKey).json")
    }

    private static func createPrivateDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private func decoder() -> JSONDecoder {
        JSONDecoder()
    }
}
