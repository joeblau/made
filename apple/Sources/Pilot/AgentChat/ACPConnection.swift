import Darwin
import Foundation
import os

/// Splits an agent's stdout into newline-delimited JSON-RPC messages.
///
/// Agent output is untrusted, so a line that grows past `maxLineBytes` fails
/// the stream before it is buffered further or parsed. Scanning resumes where
/// the previous chunk ended, keeping a long line linear rather than quadratic.
struct ACPLineFramer {
    enum Failure: Error, Equatable {
        case lineTooLong(limit: Int)
    }

    let maxLineBytes: Int
    private var buffer = Data()
    private var scanOffset = 0

    init(maxLineBytes: Int) {
        self.maxLineBytes = maxLineBytes
    }

    mutating func append(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        var lineStart = buffer.startIndex
        var searchFrom = buffer.startIndex + scanOffset
        while let newline = buffer[searchFrom...].firstIndex(of: 0x0A) {
            var line = buffer[lineStart..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            guard line.count <= maxLineBytes else { throw Failure.lineTooLong(limit: maxLineBytes) }
            if line.contains(where: { !Self.isWhitespace($0) }) {
                lines.append(Data(line))
            }
            lineStart = buffer.index(after: newline)
            searchFrom = lineStart
        }
        buffer = Data(buffer[lineStart...])
        scanOffset = buffer.count
        guard buffer.count <= maxLineBytes else { throw Failure.lineTooLong(limit: maxLineBytes) }
        return lines
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0D
    }
}

/// A message the agent initiated.
enum ACPIncoming: Sendable {
    case notification(method: String, params: JSONValue)
    case request(id: JSONValue, method: String, params: JSONValue)
}

/// A JSON-RPC error object returned by the agent.
struct ACPRemoteError: Error, Sendable, Equatable, LocalizedError {
    var code: Int
    var message: String

    static let methodNotFound = -32601
    /// ACP's `auth_required`.
    static let authRequired = -32000

    init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    init(_ json: JSONValue) {
        code = json["code"]?.intValue ?? -32603
        message = json["message"]?.stringValue ?? "Unknown agent error"
    }

    var errorDescription: String? { message }
}

enum ACPConnectionError: Error, Sendable, Equatable, LocalizedError {
    case notRunning
    case launchFailed(String)
    case lineTooLong(limit: Int)
    case exited(status: Int32?, diagnostics: String)
    case closedByClient
    case timedOut(method: String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: "The agent is not running."
        case .launchFailed(let message): "Could not start the agent: \(message)"
        case .lineTooLong(let limit): "The agent sent a message larger than \(limit / 1_048_576) MiB."
        case .exited(let status, let diagnostics):
            "The agent exited\(status.map { " with status \($0)" } ?? "")."
                + (diagnostics.isEmpty ? "" : "\n\(diagnostics)")
        case .closedByClient: "The agent was stopped."
        case .timedOut(let method): "The agent did not answer \(method) in time."
        case .writeFailed(let message): "Could not send to the agent: \(message)"
        }
    }
}

/// One coding agent running as an Agent Client Protocol server over stdio.
///
/// Requests resolve when the agent's response arrives; agent-initiated
/// notifications and requests are delivered in order on `incoming`, which
/// finishes when the process exits or the connection closes. The connection
/// never interprets message contents beyond JSON-RPC framing.
actor ACPConnection {
    struct LaunchConfiguration: Sendable {
        var executable: URL
        var arguments: [String]
        /// Never logged: it can hold the user's credentials.
        var environment: [String: String]
        var currentDirectory: URL
    }

    static let defaultMaxLineBytes = 16 * 1_048_576
    private static let stderrTailLimit = 16 * 1_024
    private static let logger = Logger(subsystem: "app.blau.pilot", category: "ACPConnection")

    nonisolated let incoming: AsyncStream<ACPIncoming>
    private let incomingContinuation: AsyncStream<ACPIncoming>.Continuation
    private let writeQueue = DispatchQueue(label: "app.blau.pilot.acp.write")

    private var framer: ACPLineFramer
    private var process: Process?
    private var stdin: FileHandle?
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var closure: ACPConnectionError?
    private var exitStatus: Int32?
    private var stderrTail = Data()

    init(maxLineBytes: Int = ACPConnection.defaultMaxLineBytes) {
        framer = ACPLineFramer(maxLineBytes: maxLineBytes)
        (incoming, incomingContinuation) = AsyncStream.makeStream(of: ACPIncoming.self)
    }

    var processIdentifier: pid_t? { process?.processIdentifier }

    /// Why the connection closed, once it has.
    var closeReason: ACPConnectionError? { closure }

    func start(_ configuration: LaunchConfiguration) throws {
        guard process == nil, closure == nil else { return }

        let process = Process()
        process.executableURL = configuration.executable
        process.arguments = configuration.arguments
        process.environment = configuration.environment
        process.currentDirectoryURL = configuration.currentDirectory

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // A write to an agent that already exited must surface as EPIPE,
        // not a SIGPIPE that terminates Cockpit.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let (stdoutChunks, stdoutSink) = AsyncStream.makeStream(of: Data.self)
        let (stderrChunks, stderrSink) = AsyncStream.makeStream(of: Data.self)
        // Readability sources are level-triggered: detach at EOF or they spin.
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stdoutSink.finish()
            } else {
                stdoutSink.yield(data)
            }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stderrSink.finish()
            } else {
                stderrSink.yield(data)
            }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { await self?.processDidExit(status: status) }
        }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            stdoutSink.finish()
            stderrSink.finish()
            close(with: .launchFailed(error.localizedDescription))
            throw ACPConnectionError.launchFailed(error.localizedDescription)
        }

        self.process = process
        stdin = input.fileHandleForWriting
        Task { await self.consumeStandardOutput(stdoutChunks) }
        Task { await self.consumeStandardError(stderrChunks) }
    }

    // MARK: Client → agent

    func request(_ method: String, params: JSONValue) async throws -> JSONValue {
        if let closure { throw closure }
        let id = nextRequestID
        nextRequestID += 1
        let message: JSONValue = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[id] = continuation
                send(message) { [weak self] error in
                    Task { await self?.failPending(id: id, error: error) }
                }
            }
        } onCancel: {
            Task { await self.failPending(id: id, error: CancellationError()) }
        }
    }

    func request(_ method: String, params: JSONValue, timeout: Duration) async throws -> JSONValue {
        try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask { try await self.request(method, params: params) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ACPConnectionError.timedOut(method: method)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw ACPConnectionError.timedOut(method: method) }
            return first
        }
    }

    func notify(_ method: String, params: JSONValue) {
        send(["jsonrpc": "2.0", "method": .string(method), "params": params])
    }

    func respond(to id: JSONValue, result: JSONValue) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func respond(to id: JSONValue, error: ACPRemoteError) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(error.code)), "message": .string(error.message)]])
    }

    /// Closes stdin so the agent can shut down cleanly, then escalates to
    /// SIGTERM and SIGKILL if it lingers.
    func terminate() async {
        guard let process else {
            close(with: .closedByClient)
            return
        }
        close(with: .closedByClient)
        for _ in 0..<20 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning { process.terminate() }
        for _ in 0..<20 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    // MARK: Internals

    private func send(_ message: JSONValue, onFailure: (@Sendable (ACPConnectionError) -> Void)? = nil) {
        guard closure == nil, let stdin else {
            onFailure?(closure ?? .notRunning)
            return
        }
        let payload: Data
        do {
            var data = try message.serialized()
            data.append(0x0A)
            payload = data
        } catch {
            onFailure?(.writeFailed(error.localizedDescription))
            return
        }
        // A serial queue keeps messages in call order without blocking the
        // actor on a full pipe.
        writeQueue.async {
            do {
                try stdin.write(contentsOf: payload)
            } catch {
                onFailure?(.writeFailed(error.localizedDescription))
            }
        }
    }

    private func failPending(id: Int, error: any Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func consumeStandardOutput(_ chunks: AsyncStream<Data>) async {
        for await chunk in chunks {
            let lines: [Data]
            do {
                lines = try framer.append(chunk)
            } catch {
                close(with: .lineTooLong(limit: framer.maxLineBytes))
                process?.terminate()
                return
            }
            for line in lines { dispatch(line) }
        }
        // EOF: give the exit status a moment to arrive for the error message.
        if let process {
            for _ in 0..<20 where process.isRunning {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if !process.isRunning { exitStatus = process.terminationStatus }
        }
        close(with: .exited(status: exitStatus, diagnostics: diagnostics))
    }

    private func consumeStandardError(_ chunks: AsyncStream<Data>) async {
        for await chunk in chunks {
            stderrTail.append(chunk)
            if stderrTail.count > Self.stderrTailLimit {
                stderrTail = Data(stderrTail.suffix(Self.stderrTailLimit))
            }
        }
    }

    private func processDidExit(status: Int32) async {
        exitStatus = status
        // A grandchild that inherited stdout can keep the pipe open after the
        // agent itself is gone; don't wait on it forever.
        try? await Task.sleep(for: .seconds(2))
        close(with: .exited(status: status, diagnostics: diagnostics))
    }

    private var diagnostics: String {
        let text = String(decoding: stderrTail, as: UTF8.self)
        let lines = text.split(whereSeparator: \.isNewline).suffix(6)
        return lines.joined(separator: "\n")
    }

    private func dispatch(_ line: Data) {
        guard let message = try? JSONValue.parse(line), message.objectValue != nil else {
            // Some agents print diagnostics on stdout; they are not protocol traffic.
            Self.logger.debug("ignored non-JSON-RPC stdout line (\(line.count) bytes)")
            return
        }
        let id = message["id"].flatMap { $0 == .null ? nil : $0 }
        if let method = message["method"]?.stringValue {
            let params = message["params"] ?? .null
            if let id {
                incomingContinuation.yield(.request(id: id, method: method, params: params))
            } else {
                incomingContinuation.yield(.notification(method: method, params: params))
            }
        } else if let requestID = id?.intValue, let continuation = pending.removeValue(forKey: requestID) {
            if let error = message["error"] {
                continuation.resume(throwing: ACPRemoteError(error))
            } else {
                continuation.resume(returning: message["result"] ?? .null)
            }
        }
    }

    private func close(with reason: ACPConnectionError) {
        guard closure == nil else { return }
        closure = reason
        for continuation in pending.values { continuation.resume(throwing: reason) }
        pending.removeAll()
        incomingContinuation.finish()
        let handle = stdin
        stdin = nil
        writeQueue.async { try? handle?.close() }
    }
}
