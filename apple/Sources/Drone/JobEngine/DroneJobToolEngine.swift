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
    private let now: @Sendable () -> TimeInterval
    private var operations: [UUID: DroneJobID] = [:]

    init(
        jobs: DroneJobEngine,
        maximumRetainedEntries: Int = DroneLimits.maxIdempotencyEntries,
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.jobs = jobs
        self.maximumRetainedEntries = max(1, maximumRetainedEntries)
        self.now = now
    }

    func read(
        _ request: DroneToolReadRequest,
        context: DroneToolRequestContext
    ) async throws -> DroneToolReadResult {
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
            guard Self.digest(data) == expected else { throw DroneProtocolError.invalidState }
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
        let executable = try resolveExecutable(request.executable)
        let operation = DroneProcessOperation(
            executablePath: executable,
            arguments: request.arguments,
            relativeDirectory: request.workingDirectory ?? ".",
            timeoutMilliseconds: Int(request.timeout * 1_000),
            standardOutputLimit: request.outputLimit,
            standardErrorLimit: request.outputLimit
        )
        let snapshot = try create(operation: .process(operation), context: context)
        operations[context.requestID] = snapshot.id
        return stream(snapshot.id, context: context, outputKind: .process)
    }

    func diff(
        _ request: DroneToolDiffRequest,
        context: DroneToolRequestContext
    ) async throws -> AsyncThrowingStream<DroneToolEvent, Error> {
        guard request.paths.count <= 1 else { throw DroneProtocolError.resourceLimit }
        let operation = DroneGitDiffOperation(
            relativePath: request.paths.first,
            outputLimit: request.maxBytes
        )
        let snapshot = try create(operation: .gitDiff(operation), context: context)
        operations[context.requestID] = snapshot.id
        return stream(snapshot.id, context: context, outputKind: .diff)
    }

    func cancel(context: DroneToolRequestContext, operationRequestID: UUID) async throws {
        guard let jobID = operations[operationRequestID] else { throw DroneProtocolError.invalidIdentifier }
        _ = try jobs.cancelJob(id: jobID, controllerID: context.lease.controllerID)
    }

    private enum OutputKind {
        case process
        case diff
    }

    private func create(
        operation: DroneJobOperation,
        context: DroneToolRequestContext,
        keySuffix: String = ""
    ) throws -> DroneJobSnapshot {
        try jobs.createJob(DroneJobCreate(
            controllerID: context.lease.controllerID,
            idempotencyKey: try scopedKey(context) + keySuffix,
            request: DroneJobRequest(workspaceID: context.lease.workspaceID, operation: operation)
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
        outputKind: OutputKind
    ) -> AsyncThrowingStream<DroneToolEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var sequence: UInt64 = 0
                    var offsets = DroneToolStreamOffsets()
                    var latestSequence: UInt64 = 0
                    while true {
                        let page = try jobs.events(
                            id: id,
                            controllerID: context.lease.controllerID,
                            afterSequence: latestSequence
                        )
                        for event in page.events {
                            latestSequence = event.sequence
                            guard case .output(let output) = event.payload else { continue }
                            let stream: DroneToolStream = switch outputKind {
                            case .process:
                                output.stream == .standardOutput ? .standardOutput : .standardError
                            case .diff: .diff
                            }
                            let body = DroneToolOutputBody(
                                sequence: sequence,
                                offset: offsets[stream],
                                stream: stream,
                                data: output.data,
                                truncated: false
                            )
                            guard !body.data.isEmpty else { continue }
                            continuation.yield(.output(body))
                            sequence += 1
                            offsets[stream] += UInt64(body.data.count)
                        }
                        let snapshot = try jobs.snapshot(id: id, controllerID: context.lease.controllerID)
                        if snapshot.state.isTerminal {
                            let status: DroneToolCompletionStatus = switch snapshot.state {
                            case .completed: .succeeded
                            case .cancelled: .cancelled
                            default: .failed
                            }
                            var exitCode: Int32?
                            if case .process(let result)? = snapshot.result { exitCode = result.exitCode }
                            continuation.yield(.completed(DroneToolCompletionBody(
                                status: status,
                                exitCode: exitCode,
                                finalSequence: sequence
                            )))
                            continuation.finish()
                            return
                        }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
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
