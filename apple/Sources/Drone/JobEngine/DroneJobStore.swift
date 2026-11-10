import Darwin
import Foundation

struct DroneStoredJob: Codable, Equatable {
    /// The record layout this build reads and writes. A record without a version
    /// predates versioning and uses layout 1. Any other version is quarantined.
    static let currentSchemaVersion = 1

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
    var schemaVersion: Int? = DroneStoredJob.currentSchemaVersion
    /// Persisted before the leader runs so recovery can kill a group that a
    /// crashed worker left behind. Absent in records written before #441.
    var processGroup: DroneProcessGroupRecord?
    /// Persisted before the leader is spawned. With no `processGroup`, it
    /// means the worker died between the spawn and recording the group, so
    /// nothing identifies a leader that may still exist.
    var launching: Bool?
    /// Set when this job was recorded finished while its process group could
    /// not be confirmed gone. Such a record keeps storage unhealthy and is
    /// never deleted automatically; recovery retries the kill on each start.
    var processGroupUnverified: Bool?

    /// Finished, and nothing suggests its process group may still run.
    var isDeletable: Bool { state.isTerminal && processGroupUnverified != true }

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
    private let reapOrphanedGroup: @Sendable (DroneProcessGroupRecord) -> Bool
    private var jobs: [DroneJobID: DroneStoredJob] = [:]
    private var keys: [JobKey: DroneJobID] = [:]
    private var quarantinedEntries = 0
    /// Records that existed when their controller was revoked and are not yet
    /// deleted: jobs still running then, or finished ones whose removal failed.
    /// Each is removed by the first purge after it finishes, and `remove(_:)`
    /// drops its ID, so the set never outgrows the live records. Retiring
    /// records rather than controllers lets a controller that re-pairs with the
    /// same peer ID keep its new records for the full idempotency lifetime.
    /// In memory only: after a restart, any record left behind still expires
    /// through `purgeExpired()`.
    private var retiredJobs: Set<DroneJobID> = []

    init(
        stateURL: URL,
        limits: DroneJobEngineLimits,
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 },
        reapOrphanedGroup: @escaping @Sendable (DroneProcessGroupRecord) -> Bool = {
            DroneProcessTable.killOrphanedGroup($0)
        }
    ) throws {
        self.stateURL = stateURL.standardizedFileURL
        self.limits = limits
        self.now = now
        self.reapOrphanedGroup = reapOrphanedGroup
        try Self.createPrivateDirectory(at: self.stateURL)
        try recover()
    }

    /// Records set aside because this build could not decode or trust them.
    /// Nonzero means storage is unhealthy until an owner inspects the directory.
    var quarantinedEntryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return quarantinedEntries
    }

    /// Records whose process group could not be confirmed gone when the job
    /// was recorded finished. Nonzero means storage is unhealthy (#441).
    var unverifiedProcessGroupCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return jobs.values.filter { $0.processGroupUnverified == true }.count
    }

    func create(_ create: DroneJobCreate) throws -> (snapshot: DroneJobSnapshot, isNew: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let key = JobKey(controllerID: create.controllerID, idempotencyKey: create.idempotencyKey)
        if let existingID = keys[key], let existing = jobs[existingID] {
            if now() - existing.createdAt >= limits.idempotencyLifetime,
               existing.isDeletable {
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

    func markLaunching(id: DroneJobID) throws {
        try update(id: id) { job in
            job.launching = true
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
        failure: DroneJobFailure?,
        processGroupSurvived: Bool = false
    ) throws {
        try update(id: id) { job in
            guard !job.state.isTerminal else { return }
            if processGroupSurvived { markProcessGroupUnverified(&job) }
            let finalState = job.cancellationRequested ? DroneJobState.cancelled : state
            job.state = finalState
            job.result = result
            job.failure = finalState == .failed ? failure : nil
            append(.state(finalState), to: &job)
        }
    }

    private func markProcessGroupUnverified(_ job: inout DroneStoredJob) {
        guard job.processGroupUnverified != true else { return }
        job.processGroupUnverified = true
        append(.notice(.processGroupUnverified), to: &job)
    }

    /// Kills what a dead worker may have left of this job's process group.
    /// True only when nothing of the group can still be running.
    private func reapLeftoverGroup(of job: DroneStoredJob) -> Bool {
        if let group = job.processGroup { return reapOrphanedGroup(group) }
        // Spawned (or about to be) but never recorded: nothing identifies it.
        return job.launching != true
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

    /// Removes every finished record past the idempotency lifetime, for all
    /// controllers, plus retired jobs that have since finished. Running jobs
    /// are never removed; they become eligible once they reach a final state.
    @discardableResult
    func purgeExpired() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let current = now()
        let expired = jobs.values.filter {
            $0.isDeletable
                && (current - $0.createdAt >= limits.idempotencyLifetime
                    || retiredJobs.contains($0.id))
        }
        try removeEach(expired)
        return expired.count
    }

    /// Deletes a revoked controller's finished records now and retires its
    /// in-flight records so the next purge after they finish deletes them.
    /// Records created later (after re-pairing) are not affected.
    @discardableResult
    func removeFinishedJobs(controllerID: UUID) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let owned = jobs.values.filter { $0.controllerID == controllerID }
        retiredJobs.formUnion(owned.map(\.id))
        let finished = owned.filter(\.isDeletable)
        try removeEach(finished)
        return finished.count
    }

    /// One unremovable record must not keep every other one alive.
    private func removeEach(_ records: [DroneStoredJob]) throws {
        var firstFailure: (any Error)?
        for job in records {
            do {
                try remove(job)
            } catch {
                firstFailure = firstFailure ?? error
            }
        }
        if let firstFailure { throw firstFailure }
    }

    private func purgeExpired(controllerID: UUID) throws {
        let expired = jobs.values.filter {
            $0.controllerID == controllerID && $0.isDeletable
                && now() - $0.createdAt >= limits.idempotencyLifetime
        }
        for job in expired { try remove(job) }
    }

    private func remove(_ job: DroneStoredJob) throws {
        let key = JobKey(controllerID: job.controllerID, idempotencyKey: job.idempotencyKey)
        try FileManager.default.removeItem(at: fileURL(for: job))
        jobs.removeValue(forKey: job.id)
        keys.removeValue(forKey: key)
        retiredJobs.remove(job.id)
    }

    /// Loads every record this build can decode and trust. A record that cannot
    /// be read, has an unknown schema version, or conflicts with another record
    /// is moved into `quarantine/` instead of aborting startup, so one bad or
    /// newer-version record never keeps the daemon down.
    private func recover() throws {
        let controllersURL = stateURL.appendingPathComponent("controllers", isDirectory: true)
        try Self.createPrivateDirectory(at: controllersURL)
        guard let controllers = FileManager.default.enumerator(
            at: controllersURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { throw DroneJobError.storeCorrupted }
        // Snapshot listings before moving entries out of the enumerated directory.
        for controllerURL in controllers.allObjects.compactMap({ $0 as? URL }) {
            guard let controllerID = UUID(uuidString: controllerURL.lastPathComponent),
                  (try? controllerURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let records = FileManager.default.enumerator(
                      at: controllerURL.appendingPathComponent("jobs", isDirectory: true),
                      includingPropertiesForKeys: [.fileSizeKey],
                      options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
                  )
            else {
                try quarantine(controllerURL)
                continue
            }
            var controllerCount = 0
            for recordURL in records.allObjects.compactMap({ $0 as? URL }) {
                guard controllerCount < limits.maximumJobsPerController,
                      var job = loadRecord(at: recordURL, controllerID: controllerID)
                else {
                    try quarantine(recordURL)
                    continue
                }
                let key = JobKey(controllerID: job.controllerID, idempotencyKey: job.idempotencyKey)
                guard jobs[job.id] == nil, keys[key] == nil else {
                    try quarantine(recordURL)
                    continue
                }
                // A job still running when the worker died, or one recorded
                // finished while its group survived, may have left processes
                // behind: kill them before anything else (#441). A group that
                // cannot be confirmed gone is recorded on the job and keeps
                // storage unhealthy instead of being finalized silently.
                let needsReap = !job.state.isTerminal || job.processGroupUnverified == true
                let groupGone = !needsReap || reapLeftoverGroup(of: job)
                // Never reload a record past the idempotency lifetime: every job is
                // final after a restart, so it is purged here for every controller
                // (#444), unless its process group is still unverified.
                if now() - job.createdAt >= limits.idempotencyLifetime, groupGone {
                    try FileManager.default.removeItem(at: recordURL)
                    continue
                }
                controllerCount += 1
                job.schemaVersion = DroneStoredJob.currentSchemaVersion
                let loaded = job
                if !job.state.isTerminal {
                    if !groupGone { markProcessGroupUnverified(&job) }
                    append(.notice(.recoveredAfterRestart), to: &job)
                    job.state = job.cancellationRequested ? .cancelled : .failed
                    if !job.cancellationRequested {
                        job.failure = DroneJobFailure(
                            code: .workerRestarted,
                            message: "The worker restarted before this job reached a final state."
                        )
                    }
                } else if groupGone {
                    job.processGroupUnverified = nil
                }
                if job != loaded {
                    job.updatedAt = now()
                    try persist(job)
                }
                jobs[job.id] = job
                keys[key] = job.id
            }
        }
        quarantinedEntries = Self.entryCount(in: quarantineURL)
    }

    /// Size is checked before any read so an oversized record is never allocated.
    private func loadRecord(at recordURL: URL, controllerID: UUID) -> DroneStoredJob? {
        guard recordURL.pathExtension == "json",
              let values = try? recordURL.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size <= limits.maximumStoredRecordBytes,
              let data = try? Data(contentsOf: recordURL, options: []),
              let job = try? decoder().decode(DroneStoredJob.self, from: data),
              (job.schemaVersion ?? 1) == DroneStoredJob.currentSchemaVersion,
              job.controllerID == controllerID,
              recordURL.lastPathComponent == "\(job.idempotencyKey).json"
        else { return nil }
        return job
    }

    private var quarantineURL: URL {
        stateURL.appendingPathComponent("quarantine", isDirectory: true)
    }

    /// Moves an untrusted entry aside without reading it further. If the move
    /// fails, startup fails rather than silently overwriting the only copy.
    private func quarantine(_ url: URL) throws {
        let destination = quarantineURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try Self.createPrivateDirectory(at: destination)
            try FileManager.default.moveItem(
                at: url,
                to: destination.appendingPathComponent(url.lastPathComponent)
            )
        } catch {
            throw DroneJobError.storeCorrupted
        }
    }

    private static func entryCount(in directory: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.count ?? 0
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
