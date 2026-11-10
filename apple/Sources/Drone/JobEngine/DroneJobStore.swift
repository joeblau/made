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
    /// not be confirmed gone, so the controller sees why. The evidence that
    /// keeps storage unhealthy lives in the worker's own ledger
    /// (`DroneUnverifiedProcessGroup`), so this record still expires and is
    /// deleted on revocation like any other finished record.
    var processGroupUnverified: Bool?

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

/// Worker-owned evidence that a job's process group could not be confirmed
/// gone (#441). Stored apart from the controller's job record, under
/// `unverified-groups/`, and holding nothing a controller supplied or can
/// read: deleting the job record on expiry or revocation, and reusing its
/// idempotency key, never discards this evidence. Each entry keeps storage
/// unhealthy until a recovery confirms the group gone, or an owner removes it.
struct DroneUnverifiedProcessGroup: Codable, Equatable {
    static let maximumStoredBytes = 4 * 1_024

    var jobID: DroneJobID
    var processGroup: DroneProcessGroupRecord?
    /// The job was spawning (or about to) with no recorded group: nothing
    /// identifies a leader that may still exist, so only an owner can clear it.
    var launching: Bool
    var recordedAt: TimeInterval
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
    private var unverifiedGroups: [DroneJobID: DroneUnverifiedProcessGroup] = [:]
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

    /// Ledger entries for process groups that could not be confirmed gone,
    /// whether or not their job records still exist. Nonzero means storage is
    /// unhealthy (#441).
    var unverifiedProcessGroupCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return unverifiedGroups.count
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
        // Write the worker-owned evidence before the record turns terminal,
        // so no later deletion of the record can lose it.
        if processGroupSurvived { try recordUnverifiedGroup(id: id) }
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

    private func recordUnverifiedGroup(id: DroneJobID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let job = jobs[id], !job.state.isTerminal else { return }
        try recordUnverifiedGroup(of: job)
    }

    /// Caller holds `lock` (or is recovering). Kept in memory even when the
    /// write fails, so health reports it for the life of this process.
    private func recordUnverifiedGroup(of job: DroneStoredJob) throws {
        guard unverifiedGroups[job.id] == nil else { return }
        let entry = DroneUnverifiedProcessGroup(
            jobID: job.id,
            processGroup: job.processGroup,
            launching: job.launching == true,
            recordedAt: now()
        )
        unverifiedGroups[job.id] = entry
        try write(encoder().encode(entry), to: unverifiedGroupURL(for: job.id))
    }

    /// Kills what a dead worker may have left of a process group.
    /// True only when nothing of the group can still be running.
    private func reapLeftoverGroup(_ group: DroneProcessGroupRecord?, launching: Bool) -> Bool {
        if let group { return reapOrphanedGroup(group) }
        // Spawned (or about to be) but never recorded: nothing identifies it.
        return !launching
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

    /// Loads every record this build can decode and trust. A record that cannot
    /// be read, has an unknown schema version, or conflicts with another record
    /// is moved into `quarantine/` instead of aborting startup, so one bad or
    /// newer-version record never keeps the daemon down.
    private func recover() throws {
        let carried = try loadUnverifiedGroups()
        let controllersURL = stateURL.appendingPathComponent("controllers", isDirectory: true)
        try Self.createPrivateDirectory(at: controllersURL)
        guard let controllers = FileManager.default.enumerator(
            at: controllersURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { throw DroneJobError.storeCorrupted }
        var loaded: [(job: DroneStoredJob, key: JobKey)] = []
        var loadedIDs: Set<DroneJobID> = []
        var loadedKeys: Set<JobKey> = []
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
                      let job = loadRecord(at: recordURL, controllerID: controllerID)
                else {
                    try quarantine(recordURL)
                    continue
                }
                let key = JobKey(controllerID: job.controllerID, idempotencyKey: job.idempotencyKey)
                guard !loadedIDs.contains(job.id), !loadedKeys.contains(key) else {
                    try quarantine(recordURL)
                    continue
                }
                // A job still running when the worker died may have left
                // processes behind: kill them before anything else (#441). A
                // group that cannot be confirmed gone is written to the
                // worker's ledger before the record is finalized or deleted.
                // A ledger entry carried over is retried below instead.
                let needsReap = !job.state.isTerminal || job.processGroupUnverified == true
                if needsReap, unverifiedGroups[job.id] == nil,
                   !reapLeftoverGroup(job.processGroup, launching: job.launching == true) {
                    try recordUnverifiedGroup(of: job)
                }
                // Never reload a record past the idempotency lifetime: every job is
                // final after a restart, so it is purged here for every controller
                // (#444). Any unverified group survives in the ledger.
                if now() - job.createdAt >= limits.idempotencyLifetime {
                    try FileManager.default.removeItem(at: recordURL)
                    continue
                }
                controllerCount += 1
                loadedIDs.insert(job.id)
                loadedKeys.insert(key)
                loaded.append((job, key))
            }
        }
        // Retry every group an earlier run could not confirm gone, whether
        // or not its job record still exists.
        for id in carried {
            guard let entry = unverifiedGroups[id],
                  reapLeftoverGroup(entry.processGroup, launching: entry.launching)
            else { continue }
            try FileManager.default.removeItem(at: unverifiedGroupURL(for: id))
            unverifiedGroups.removeValue(forKey: id)
        }
        for (original, key) in loaded {
            var job = original
            job.schemaVersion = DroneStoredJob.currentSchemaVersion
            let unverified = unverifiedGroups[job.id] != nil
            if !job.state.isTerminal {
                if unverified { markProcessGroupUnverified(&job) }
                append(.notice(.recoveredAfterRestart), to: &job)
                job.state = job.cancellationRequested ? .cancelled : .failed
                if !job.cancellationRequested {
                    job.failure = DroneJobFailure(
                        code: .workerRestarted,
                        message: "The worker restarted before this job reached a final state."
                    )
                }
            } else if unverified {
                markProcessGroupUnverified(&job)
            } else {
                job.processGroupUnverified = nil
            }
            if job != original {
                job.updatedAt = now()
                try persist(job)
            }
            jobs[job.id] = job
            keys[key] = job.id
        }
        quarantinedEntries = Self.entryCount(in: quarantineURL)
    }

    private var unverifiedGroupsURL: URL {
        stateURL.appendingPathComponent("unverified-groups", isDirectory: true)
    }

    private func unverifiedGroupURL(for id: DroneJobID) -> URL {
        unverifiedGroupsURL.appendingPathComponent("\(id.rawValue.uuidString).json")
    }

    /// Loads the ledger and returns the job IDs it held. An entry that cannot
    /// be read or trusted is quarantined, which keeps storage unhealthy too.
    private func loadUnverifiedGroups() throws -> [DroneJobID] {
        try Self.createPrivateDirectory(at: unverifiedGroupsURL)
        guard let entries = FileManager.default.enumerator(
            at: unverifiedGroupsURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { throw DroneJobError.storeCorrupted }
        for url in entries.allObjects.compactMap({ $0 as? URL }) {
            guard url.pathExtension == "json",
                  let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                  size <= DroneUnverifiedProcessGroup.maximumStoredBytes,
                  let data = try? Data(contentsOf: url, options: []),
                  let entry = try? decoder().decode(DroneUnverifiedProcessGroup.self, from: data),
                  url.lastPathComponent == "\(entry.jobID.rawValue.uuidString).json",
                  unverifiedGroups[entry.jobID] == nil
            else {
                try quarantine(url)
                continue
            }
            unverifiedGroups[entry.jobID] = entry
        }
        return Array(unverifiedGroups.keys)
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
        let data = try encoder().encode(job)
        guard data.count <= limits.maximumStoredRecordBytes else {
            throw DroneJobError.resourceLimit
        }
        try write(data, to: fileURL(for: job))
    }

    /// Atomically replaces `url` with a private, fsynced copy of `data`.
    private func write(_ data: Data, to url: URL) throws {
        try Self.createPrivateDirectory(at: url.deletingLastPathComponent())
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
