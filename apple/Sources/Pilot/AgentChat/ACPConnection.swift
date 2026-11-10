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

/// A message the agent initiated, or an ordering marker.
enum ACPIncoming: Sendable {
    case notification(method: String, params: JSONValue)
    case request(id: JSONValue, method: String, params: JSONValue)
    /// Yielded when the response to a request sent with `barrier: token`
    /// arrives (result or error), after every message that preceded that
    /// response. A consumer that waits for the barrier before acting on the
    /// response sees all of the agent's earlier notifications first.
    case barrier(token: Int)
}

/// Waits, on the consumer's side of `ACPConnection.incoming`, for barriers
/// the event loop reaches. Tokens are allocated here and never reused, so a
/// barrier from an earlier connection cannot satisfy a later wait.
@MainActor
final class ACPBarrierGate {
    private var nextToken = 0
    private var reached: Set<Int> = []
    private var waiters: [Int: CheckedContinuation<Bool, Never>] = [:]
    private var isClosed = false

    func makeToken() -> Int {
        nextToken += 1
        return nextToken
    }

    /// True once the event loop reached `token`; false when the gate closed
    /// (connection ended or the consumer stopped) first.
    func wait(for token: Int) async -> Bool {
        if reached.remove(token) != nil { return true }
        if isClosed { return false }
        return await withCheckedContinuation { continuation in
            // One waiter per token; a second wait must not leak the first.
            waiters.updateValue(continuation, forKey: token)?.resume(returning: false)
        }
    }

    /// Called by the event loop on `.barrier(token)`.
    func reach(_ token: Int) {
        if let waiter = waiters.removeValue(forKey: token) {
            waiter.resume(returning: true)
        } else {
            reached.insert(token)
        }
    }

    /// Fails current and future waits for barriers not yet reached.
    func close() {
        isClosed = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending.values { waiter.resume(returning: false) }
    }

    /// Re-arms the gate for a new connection.
    func reopen() {
        close()
        reached.removeAll()
        isClosed = false
    }
}

/// A JSON-RPC error object returned by the agent.
struct ACPRemoteError: Error, Sendable, Equatable, LocalizedError {
    var code: Int
    var message: String

    static let methodNotFound = -32601
    /// ACP's `auth_required`.
    static let authRequired = -32000
    /// `$/cancel_request`: the answer to a request its sender withdrew.
    static let requestCancelled = -32800
    /// Agent-supplied messages are bounded before they are kept or shown.
    static let maximumMessageLength = 1_024

    init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    init(_ json: JSONValue) {
        code = json["code"]?.intValue ?? -32603
        message = Self.bounded(json["message"]?.stringValue ?? "Unknown agent error")
    }

    /// Caps an agent message at a word boundary, so a token cut by the cap
    /// is dropped whole rather than kept as a partial secret redaction can no
    /// longer recognize.
    static func bounded(_ text: String) -> String {
        guard let end = text.index(text.startIndex, offsetBy: maximumMessageLength, limitedBy: text.endIndex),
              end != text.endIndex else { return text }
        let head = text[..<end]
        guard let space = head.lastIndex(where: \.isWhitespace) else { return String(head) + "…" }
        return String(head[..<space]) + "…"
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
    /// Request ID → the barrier token yielded when its response arrives.
    private var barriers: [Int: Int] = [:]
    private var closure: ACPConnectionError?
    private var exitStatus: Int32?
    private var stderrTail = Data()
    /// The agent's process group, when it leads its own (Foundation spawns
    /// children that way). Signalling it also reaches the agent's tool
    /// subprocesses and MCP servers; it is never Cockpit's own group.
    private var processGroup: pid_t?
    /// Started by `close(with:)`: every close, for any reason, ends with the
    /// agent's process group gone, escalating from SIGTERM to SIGKILL.
    private var reaper: Task<Void, Never>?

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
        let pid = process.processIdentifier
        let group = getpgid(pid)
        processGroup = group == pid && group != getpgrp() ? group : nil
        stdin = input.fileHandleForWriting
        Task { await self.consumeStandardOutput(stdoutChunks) }
        Task { await self.consumeStandardError(stderrChunks) }
    }

    // MARK: Client → agent

    /// Sends a request and waits for its response. With `barrier`, the
    /// response also yields `.barrier(token: barrier)` on `incoming` after
    /// every message the agent sent before it.
    func request(_ method: String, params: JSONValue, barrier: Int? = nil) async throws -> JSONValue {
        if let closure { throw closure }
        let id = nextRequestID
        nextRequestID += 1
        if let barrier { barriers[id] = barrier }
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

    func request(
        _ method: String,
        params: JSONValue,
        timeout: Duration,
        barrier: Int? = nil
    ) async throws -> JSONValue {
        try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask { try await self.request(method, params: params, barrier: barrier) }
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

    /// Answers an agent request and returns only once the answer was written
    /// to a live agent's stdin; throws when the connection is closed or the
    /// write fails, so callers can record a decision only after it was sent.
    func respondConfirmed(to id: JSONValue, result: JSONValue) async throws {
        try await sendConfirmed(["jsonrpc": "2.0", "id": id, "result": result])
    }

    /// `respond(to:error:)`, confirmed like `respondConfirmed(to:result:)`.
    func respondConfirmed(to id: JSONValue, error: ACPRemoteError) async throws {
        try await sendConfirmed(
            ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(error.code)), "message": .string(error.message)]]
        )
    }

    /// Closes stdin so the agent can shut down cleanly, then escalates to
    /// SIGTERM and SIGKILL if it lingers. Idempotent: after an earlier close
    /// for another reason it waits for that close's escalation instead.
    func terminate() async {
        close(with: .closedByClient)
        await reaper?.value
    }

    // MARK: Internals

    private func sendConfirmed(_ message: JSONValue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            send(message, onFailure: { continuation.resume(throwing: $0) }, onWritten: { continuation.resume() })
        }
    }

    /// Exactly one of `onFailure` / `onWritten` runs when either is given.
    private func send(
        _ message: JSONValue,
        onFailure: (@Sendable (ACPConnectionError) -> Void)? = nil,
        onWritten: (@Sendable () -> Void)? = nil
    ) {
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
                onWritten?()
            } catch {
                onFailure?(.writeFailed(error.localizedDescription))
            }
        }
    }

    private func failPending(id: Int, error: any Error) {
        barriers.removeValue(forKey: id)
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func consumeStandardOutput(_ chunks: AsyncStream<Data>) async {
        for await chunk in chunks {
            let lines: [Data]
            do {
                lines = try framer.append(chunk)
            } catch {
                close(with: .lineTooLong(limit: framer.maxLineBytes))
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

    /// A client close first gives the agent a moment to exit on stdin EOF;
    /// any other close means it misbehaved or already exited, so whatever is
    /// left of its process group is signalled at once.
    private func reapAgent(gracefully: Bool) async {
        if gracefully { await waitForAgentExit() }
        if agentIsAlive { signalAgent(SIGTERM) }
        await waitForAgentExit()
        if agentIsAlive { signalAgent(SIGKILL) }
    }

    private func waitForAgentExit() async {
        for _ in 0..<20 where agentIsAlive {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private var agentIsAlive: Bool {
        if process?.isRunning == true { return true }
        guard let processGroup else { return false }
        return kill(-processGroup, 0) == 0
    }

    private func signalAgent(_ signo: Int32) {
        if let processGroup, kill(-processGroup, signo) == 0 { return }
        if let process, process.isRunning { kill(process.processIdentifier, signo) }
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
            // Every message before this response is already on `incoming`;
            // the barrier lands right behind them.
            if let token = barriers.removeValue(forKey: requestID) {
                incomingContinuation.yield(.barrier(token: token))
            }
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
        barriers.removeAll()
        incomingContinuation.finish()
        let handle = stdin
        stdin = nil
        writeQueue.async { try? handle?.close() }
        if process != nil {
            let gracefully = reason == .closedByClient
            reaper = Task { await self.reapAgent(gracefully: gracefully) }
        }
    }
}
