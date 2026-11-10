import Darwin
import Foundation

struct DroneStoredJob: Codable, Equatable {
    /// The record layout this build reads and writes. A record without a version
    /// predates versioning and uses layout 1. Any other version is quarantined.
    static let currentSchemaVersion = 1
    /// Ceiling for the event sequence and dropped-event counters. Records keep
    /// these at or below it, so `+ 1` on either never traps; a decoded record
    /// above it is quarantined rather than trusted (#440).
    static let maximumCounter = UInt64(Int64.max)

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

    /// Decoded counters and history are untrusted. A record whose counters
    /// exceed `maximumCounter`, whose timestamps are not finite, or whose
    /// events are out of order or ahead of `latestSequence` is not loaded.
    var hasConsistentHistory: Bool {
        guard latestSequence <= Self.maximumCounter,
              droppedEventCount <= Self.maximumCounter,
              createdAt.isFinite, updatedAt.isFinite
        else { return false }
        var previous: UInt64 = 0
        for event in events {
            guard event.sequence > previous, event.sequence <= latestSequence else { return false }
            previous = event.sequence
        }
        return true
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
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) throws {
        self.stateURL = stateURL.standardizedFileURL
        self.limits = limits
        self.now = now
        try Self.createPrivateDirectory(at: self.stateURL)
        try recover()
    }

    /// Records set aside because this build could not decode or trust them,
    /// plus expired records recovery could neither delete nor move aside.
    /// Nonzero means storage is unhealthy until an owner inspects the directory.
    var quarantinedEntryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return quarantinedEntries
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
            try append(.state(.running), to: &job)
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
            try append(.output(DroneJobOutput(stream: stream, data: data)), to: &job)
        }
    }

    func appendTruncation(id: DroneJobID, stream: DroneJobStream) throws {
        try update(id: id) { job in
            guard !job.state.isTerminal else { return }
            try append(.truncated(stream), to: &job)
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
            try append(.state(finalState), to: &job)
        }
    }

    private func update(id: DroneJobID, mutation: (inout DroneStoredJob) throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var job = jobs[id] else { throw DroneJobError.jobNotFound }
        let original = job
        try mutation(&job)
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

    /// Sequence numbers must stay unique, so an exhausted counter is refused
    /// rather than wrapped or saturated.
    private func append(_ payload: DroneJobEventPayload, to job: inout DroneStoredJob) throws {
        guard job.latestSequence < DroneStoredJob.maximumCounter else {
            throw DroneJobError.resourceLimit
        }
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
            // A count, not an identifier: saturating at the ceiling is harmless.
            if job.droppedEventCount < DroneStoredJob.maximumCounter { job.droppedEventCount += 1 }
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
            $0.state.isTerminal
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
        let finished = owned.filter(\.state.isTerminal)
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
        retiredJobs.remove(job.id)
    }

    /// Loads every record this build can decode and trust. Any per-record
    /// failure (unreadable, unknown schema version, inconsistent counters,
    /// conflicting with another record, or a recovery append, persist or delete
    /// that fails) moves that record into `quarantine/` and recovery continues,
    /// so one bad or newer-version record never keeps the daemon down. A
    /// non-final record with a recorded process group has that group killed
    /// before it is set aside, whether it is quarantined for inconsistent
    /// counters or because recovery failed (#441). The
    /// quarantine entry reports storage as unhealthy. An expired record that
    /// can be neither deleted nor moved aside (for example, because its `jobs/`
    /// directory is read-only or immutable, which blocks unlink and rename
    /// alike) is left in place, never loaded, and counted as unhealthy storage
    /// rather than aborting startup: it was due for deletion, so nothing is
    /// lost if a later write replaces it. Any other failed move into
    /// quarantine stops startup, because the daemon would later overwrite the
    /// only copy of a record it still owes a controller.
    private func recover() throws {
        let controllersURL = stateURL.appendingPathComponent("controllers", isDirectory: true)
        try Self.createPrivateDirectory(at: controllersURL)
        guard let controllers = FileManager.default.enumerator(
            at: controllersURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { throw DroneJobError.storeCorrupted }
        var unremovableExpiredRecords = 0
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
                      let stored = loadRecord(at: recordURL, controllerID: controllerID)
                else {
                    try quarantine(recordURL)
                    continue
                }
                // A record that decodes but whose counters or history cannot be
                // trusted is never loaded. If it was still running, its process
                // group is killed before it is set aside, so rejecting the record
                // never strands the job's processes (#441). The recorded group is
                // untrusted too; `killOrphanedGroup` refuses group IDs <= 1, this
                // process's own pid and group, and any leader start-time mismatch.
                guard stored.hasConsistentHistory else {
                    if !stored.state.isTerminal, let group = stored.processGroup {
                        DroneProcessTable.killOrphanedGroup(group)
                    }
                    try quarantine(recordURL)
                    continue
                }
                let key = JobKey(controllerID: stored.controllerID, idempotencyKey: stored.idempotencyKey)
                guard jobs[stored.id] == nil, keys[key] == nil else {
                    try quarantine(recordURL)
                    continue
                }
                // Never reload a record past the idempotency lifetime: every job is
                // final after a restart, so it is purged here for every controller
                // (#444). A record that was still running when the worker died is
                // killed first so purging it never strands its process group (#441).
                if now() - stored.createdAt >= limits.idempotencyLifetime {
                    if !stored.state.isTerminal, let group = stored.processGroup {
                        DroneProcessTable.killOrphanedGroup(group)
                    }
                    do {
                        try FileManager.default.removeItem(at: recordURL)
                    } catch {
                        do {
                            try quarantine(recordURL)
                        } catch {
                            unremovableExpiredRecords += 1
                        }
                    }
                    continue
                }
                let job: DroneStoredJob
                do {
                    job = try recovered(stored)
                } catch {
                    // The record on disk is unchanged (persist renames
                    // atomically), so it is set aside intact.
                    try quarantine(recordURL)
                    continue
                }
                controllerCount += 1
                jobs[job.id] = job
                keys[key] = job.id
            }
        }
        quarantinedEntries = Self.entryCount(in: quarantineURL) + unremovableExpiredRecords
    }

    /// Finalizes a record that was not final when the worker stopped. Throws
    /// when the recovery notice cannot be appended or the result cannot be
    /// persisted; the caller quarantines the record. The process group is
    /// killed first, so it is stopped whether or not recovery succeeds (#441).
    private func recovered(_ stored: DroneStoredJob) throws -> DroneStoredJob {
        var job = stored
        job.schemaVersion = DroneStoredJob.currentSchemaVersion
        guard !job.state.isTerminal else { return job }
        if let group = job.processGroup {
            DroneProcessTable.killOrphanedGroup(group)
        }
        try append(.notice(.recoveredAfterRestart), to: &job)
        job.state = job.cancellationRequested ? .cancelled : .failed
        if !job.cancellationRequested {
            job.failure = DroneJobFailure(
                code: .workerRestarted,
                message: "The worker restarted before this job reached a final state."
            )
        }
        job.updatedAt = now()
        try persist(job)
        return job
    }

    /// Size is checked before any read so an oversized record is never allocated.
    /// Only decoding, schema, owner and name are checked here; `recover()`
    /// checks `hasConsistentHistory` itself so it can stop a rejected record's
    /// process group first.
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

    /// Moves an untrusted entry aside without reading it further. Throws
    /// `storeCorrupted` when the move fails, removing the empty destination so
    /// it is not counted as a quarantined entry; `recover()` then fails startup
    /// rather than silently overwriting the only copy, except for an expired
    /// record, which it leaves in place and reports as unhealthy.
    private func quarantine(_ url: URL) throws {
        let destination = quarantineURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try Self.createPrivateDirectory(at: destination)
            try FileManager.default.moveItem(
                at: url,
                to: destination.appendingPathComponent(url.lastPathComponent)
            )
        } catch {
            try? FileManager.default.removeItem(at: destination)
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
