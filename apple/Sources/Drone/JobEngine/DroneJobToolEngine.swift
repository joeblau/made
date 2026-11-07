import CryptoKit
import Foundation

actor DroneJobToolEngine: DroneToolEngine {
    private let jobs: DroneJobEngine
    private struct EditEntry {
        let fingerprint: String
        let task: Task<DroneToolEditResult, Error>
        var finished = false
        let expiresAt: TimeInterval
    }

    private var edits: [String: EditEntry] = [:]
    private let maximumRetainedEntries: Int
    private let eventPageSize: Int
    private let now: @Sendable () -> TimeInterval
    private struct OperationEntry {
        let jobID: DroneJobID
        let lease: DroneToolLease
    }

    private var operations: [String: OperationEntry] = [:]

    init(
        jobs: DroneJobEngine,
        maximumRetainedEntries: Int = DroneLimits.maxIdempotencyEntries,
        eventPageSize: Int = 256,
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.jobs = jobs
        self.maximumRetainedEntries = max(1, maximumRetainedEntries)
        self.now = now
        self.eventPageSize = min(256, max(1, eventPageSize))
    }

    func read(
        _ request: DroneToolReadRequest,
        context: DroneToolRequestContext
    ) async throws -> DroneToolReadResult {
        try DroneToolValidation.validate(read: request)
        let snapshot = try await complete(
            operation: .readFile(DroneReadFileOperation(
                relativePath: request.path,
                maximumBytes: request.maxBytes + 1
            )),
            context: context
        )
        guard case .file(let data)? = snapshot.result else { throw DroneJobError.storeCorrupted }
        return DroneToolReadResult(
            data: data.prefix(request.maxBytes),
            truncated: data.count > request.maxBytes
        )
    }

    func edit(
        _ request: DroneToolEditRequest,
        context: DroneToolRequestContext
    ) async throws -> DroneToolEditResult {
        try DroneToolValidation.validate(edit: request)
        let key = try scopedKey(context)
        let fingerprint = try Self.fingerprint(request)
        edits = edits.filter { !$0.value.finished || $0.value.expiresAt > now() }
        if let existing = edits[key] {
            guard existing.fingerprint == fingerprint else { throw DroneProtocolError.idempotencyConflict }
            return try await existing.task.value
        }
        guard edits.count < maximumRetainedEntries else { throw DroneProtocolError.resourceLimit }
        let task = Task { try await self.performEdit(request, context: context) }
        edits[key] = EditEntry(
            fingerprint: fingerprint, task: task,
            expiresAt: min(context.lease.expiresAt, now() + DroneLimits.idempotencyLifetime)
        )
        defer { edits[key]?.finished = true }
        return try await task.value
    }

    private func performEdit(
        _ request: DroneToolEditRequest,
        context: DroneToolRequestContext
    ) async throws -> DroneToolEditResult {
        let read = try await complete(
            operation: .readFile(DroneReadFileOperation(relativePath: request.path)),
            context: context,
            keySuffix: "-read"
        )
        guard case .file(let data)? = read.result else { throw DroneJobError.storeCorrupted }
        if let expected = request.expectedSHA256 {
            guard Self.digest(data) == expected.lowercased() else { throw DroneProtocolError.invalidState }
        }
        guard let range = data.range(of: request.oldData),
              data.range(of: request.oldData, in: range.upperBound..<data.endIndex) == nil
        else { throw DroneProtocolError.invalidState }
        var updated = data
        updated.replaceSubrange(range, with: request.newData)
        let written = try await complete(
            operation: .writeFile(DroneWriteFileOperation(relativePath: request.path, data: updated)),
            context: context,
            keySuffix: "-write"
        )
        guard case .bytesWritten = written.result else { throw DroneJobError.storeCorrupted }
        let result = DroneToolEditResult(bytesWritten: updated.count, sha256: Self.digest(updated))
        return result
    }

    func run(
        _ request: DroneToolProcessRequest,
        context: DroneToolRequestContext
    ) async throws -> AsyncThrowingStream<DroneToolEvent, Error> {
        try DroneToolValidation.validate(process: request)
        let executable = try resolveExecutable(request.executable)
        let operation = DroneProcessOperation(
            executablePath: executable,
            arguments: request.arguments,
            relativeDirectory: request.workingDirectory ?? ".",
            timeoutMilliseconds: Int((request.timeout * 1_000).rounded(.up)),
            standardOutputLimit: request.outputLimit,
            standardErrorLimit: request.outputLimit
        )
        let snapshot = try createTracked(
            operation: .process(operation), context: context, environment: request.environment
        )
        return stream(snapshot.id, context: context, outputKind: .process, outputLimit: request.outputLimit)
    }

    func diff(
        _ request: DroneToolDiffRequest,
        context: DroneToolRequestContext
    ) async throws -> AsyncThrowingStream<DroneToolEvent, Error> {
        try DroneToolValidation.validate(diff: request)
        // The durable typed Git operation currently supports one path and the default context only.
        guard request.paths.count <= 1, request.contextLines == 3 else {
            throw DroneProtocolError.resourceLimit
        }
        let operation = DroneGitDiffOperation(
            relativePath: request.paths.first,
            outputLimit: request.maxBytes
        )
        let snapshot = try createTracked(operation: .gitDiff(operation), context: context)
        return stream(snapshot.id, context: context, outputKind: .diff, outputLimit: request.maxBytes)
    }

    func cancel(context: DroneToolRequestContext, operationRequestID: UUID) async throws {
        _ = try scopedKey(context)
        let key = try operationKey(lease: context.lease, requestID: operationRequestID)
        guard let entry = operations[key] else { throw DroneProtocolError.invalidIdentifier }
        _ = try jobs.cancelJob(id: entry.jobID, controllerID: context.lease.controllerID)
    }

    private func operationKey(lease: DroneToolLease, requestID: UUID) throws -> String {
        try Self.fingerprint(lease) + requestID.uuidString
    }

    private func createTracked(
        operation: DroneJobOperation,
        context: DroneToolRequestContext,
        environment: [String: String] = [:]
    ) throws -> DroneJobSnapshot {
        _ = try scopedKey(context)
        let key = try operationKey(lease: context.lease, requestID: context.requestID)
        // Completed jobs remain in the durable store; only live cancellation mappings are needed.
        for (key, entry) in operations {
            do {
                if try jobs.snapshot(id: entry.jobID, controllerID: entry.lease.controllerID).state.isTerminal {
                    operations.removeValue(forKey: key)
                }
            } catch DroneJobError.jobNotFound {
                operations.removeValue(forKey: key)
            }
        }
        guard operations[key] != nil || operations.count < maximumRetainedEntries else {
            throw DroneProtocolError.resourceLimit
        }
        if let entry = operations[key] {
            let existing = try jobs.snapshot(id: entry.jobID, controllerID: context.lease.controllerID)
            guard existing.idempotencyKey == (try scopedKey(context)),
                  existing.request.operation == operation, existing.request.environment == environment
            else { throw DroneProtocolError.idempotencyConflict }
            return existing
        }
        let snapshot = try create(operation: operation, context: context, environment: environment)
        operations[key] = OperationEntry(jobID: snapshot.id, lease: context.lease)
        return snapshot
    }

    private enum OutputKind {
        case process
        case diff
    }

    private func create(
        operation: DroneJobOperation,
        context: DroneToolRequestContext,
        keySuffix: String = "",
        environment: [String: String] = [:]
    ) throws -> DroneJobSnapshot {
        try jobs.createJob(DroneJobCreate(
            controllerID: context.lease.controllerID,
            idempotencyKey: try scopedKey(context) + keySuffix,
            request: DroneJobRequest(
                workspaceID: context.lease.workspaceID, operation: operation, environment: environment
            )
        ))
    }

    private func complete(
        operation: DroneJobOperation,
        context: DroneToolRequestContext,
        keySuffix: String = ""
    ) async throws -> DroneJobSnapshot {
        let created = try create(operation: operation, context: context, keySuffix: keySuffix)
        for _ in 0..<6_000 {
            let snapshot = try jobs.snapshot(id: created.id, controllerID: context.lease.controllerID)
            if snapshot.state.isTerminal {
                guard snapshot.state == .completed else { throw DroneProtocolError.invalidState }
                return snapshot
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw DroneProtocolError.invalidState
    }

    private func stream(
        _ id: DroneJobID,
        context: DroneToolRequestContext,
        outputKind: OutputKind,
        outputLimit: Int
    ) -> AsyncThrowingStream<DroneToolEvent, Error> {
        let reader = OutputReader(
            jobs: jobs, id: id, controllerID: context.lease.controllerID,
            kind: outputKind, limit: outputLimit, pageSize: eventPageSize
        )
        // Pull-based delivery retains at most one bounded event page, not a producer task's queue.
        return AsyncThrowingStream(unfolding: { try await reader.next() })
    }

    private actor OutputReader {
        let jobs: DroneJobEngine
        let id: DroneJobID
        let controllerID: UUID
        let kind: OutputKind
        let pageSize: Int
        var remaining: Int
        var latestSequence: UInt64 = 0
        var sequence: UInt64 = 0
        var offsets = DroneToolStreamOffsets()
        var queued: [DroneToolEvent] = []
        var pending: [DroneToolStream: Data] = [:]
        var pendingOrder: [DroneToolStream] = []
        var truncated = false
        var finished = false

        init(jobs: DroneJobEngine, id: DroneJobID, controllerID: UUID,
             kind: OutputKind, limit: Int, pageSize: Int) {
            self.jobs = jobs
            self.id = id
            self.controllerID = controllerID
            self.kind = kind
            self.remaining = limit
            self.pageSize = pageSize
        }

        func next() async throws -> DroneToolEvent? {
            try Task.checkCancellation()
            while queued.isEmpty && !finished {
                try Task.checkCancellation()
                let page = try jobs.events(
                    id: id, controllerID: controllerID, afterSequence: latestSequence,
                    maximumEvents: pageSize
                )
                for event in page.events {
                    latestSequence = event.sequence
                    switch event.payload {
                    case .output(let output):
                        let stream: DroneToolStream = switch kind {
                        case .process:
                            output.stream == .standardOutput ? .standardOutput : .standardError
                        case .diff: .diff
                        }
                        let data = Data(output.data.prefix(remaining))
                        remaining -= data.count
                        truncated = truncated || data.count < output.data.count
                        if !data.isEmpty {
                            if let previous = pending[stream] { emit(previous, stream: stream, truncated: false) }
                            // Keep one byte per stream so late truncation has a valid, nonempty marker.
                            if data.count > 1 { emit(Data(data.dropLast()), stream: stream, truncated: false) }
                            pending[stream] = Data(data.suffix(1))
                            pendingOrder.removeAll { $0 == stream }
                            pendingOrder.append(stream)
                        }
                    case .truncated: truncated = true
                    default: break
                    }
                }
                let snapshot = try jobs.snapshot(id: id, controllerID: controllerID)
                // A terminal snapshot can be newer than this page. Drain through its terminal event.
                if snapshot.state.isTerminal && latestSequence >= snapshot.latestSequence {
                    for stream in pendingOrder {
                        if let data = pending[stream] { emit(data, stream: stream, truncated: truncated) }
                    }
                    pending.removeAll()
                    pendingOrder.removeAll()
                    let status: DroneToolCompletionStatus = switch snapshot.state {
                    case .completed: .succeeded
                    case .cancelled: .cancelled
                    default: .failed
                    }
                    var exitCode: Int32?
                    if status != .cancelled, case .process(let result)? = snapshot.result {
                        exitCode = result.exitCode
                    }
                    queued.append(.completed(DroneToolCompletionBody(
                        status: status, exitCode: exitCode, finalSequence: sequence
                    )))
                    finished = true
                } else if latestSequence >= page.latestSequence {
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            return queued.isEmpty ? nil : queued.removeFirst()
        }

        private func emit(_ data: Data, stream: DroneToolStream, truncated: Bool) {
            queued.append(.output(DroneToolOutputBody(
                sequence: sequence, offset: offsets[stream], stream: stream,
                data: data, truncated: truncated
            )))
            sequence += 1
            offsets[stream] += UInt64(data.count)
        }
    }

    private func resolveExecutable(_ name: String) throws -> String {
        for directory in ["/usr/bin", "/bin", "/opt/homebrew/bin", "/usr/local/bin"] {
            let path = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        throw DroneProtocolError.unauthorized
    }

    private func scopedKey(_ context: DroneToolRequestContext) throws -> String {
        guard context.lease.expiresAt.isFinite, context.lease.expiresAt > now() else {
            throw DroneProtocolError.unauthorized
        }
        let key = context.idempotencyKey
        guard (16...128).contains(key.utf8.count), key.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0) || $0 == 45 || $0 == 95
        }) else { throw DroneProtocolError.invalidIdentifier }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return Self.digest(try encoder.encode(context.lease) + Data(key.utf8))
    }

    private static func fingerprint(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return digest(try encoder.encode(value))
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
