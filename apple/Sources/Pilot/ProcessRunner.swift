import Darwin
import Foundation

/// An argument-array-only subprocess invocation. Diagnostics deliberately omit
/// the environment and can redact selected arguments before they reach logs.
struct ProcessInvocation: Sendable {
    var executableURL: URL
    var arguments: [String] = []
    var currentDirectoryURL: URL?
    var environment: [String: String]?
    var timeout: Duration = .seconds(15)
    var terminationGracePeriod: Duration = .milliseconds(250)
    var standardOutputLimit = 2 * 1_024 * 1_024
    var standardErrorLimit = 256 * 1_024
    var redactedArgumentIndexes: Set<Int> = []
    /// Scheduling class for the child and its output-draining worker. Keep
    /// `.utility` for background tooling; raise it only when the command's
    /// latency is itself being measured or awaited by a user.
    var qualityOfService: QualityOfService = .utility

    init(
        executableURL: URL,
        arguments: [String] = [],
        currentDirectoryURL: URL? = nil,
        environment: [String: String]? = nil,
        timeout: Duration = .seconds(15),
        terminationGracePeriod: Duration = .milliseconds(250),
        standardOutputLimit: Int = 2 * 1_024 * 1_024,
        standardErrorLimit: Int = 256 * 1_024,
        redactedArgumentIndexes: Set<Int> = [],
        qualityOfService: QualityOfService = .utility
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.currentDirectoryURL = currentDirectoryURL
        self.environment = environment
        self.timeout = timeout
        self.terminationGracePeriod = terminationGracePeriod
        self.standardOutputLimit = standardOutputLimit
        self.standardErrorLimit = standardErrorLimit
        self.redactedArgumentIndexes = redactedArgumentIndexes
        self.qualityOfService = qualityOfService
    }

    /// A PATH that covers system and common Homebrew developer-tool installs.
    static func developerTool(
        _ command: String,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        timeout: Duration = .seconds(15),
        standardOutputLimit: Int = 2 * 1_024 * 1_024,
        standardErrorLimit: Int = 256 * 1_024
    ) -> ProcessInvocation {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:"
            + (environment["PATH"] ?? "")
        return ProcessInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [command] + arguments,
            currentDirectoryURL: currentDirectoryURL,
            environment: environment,
            timeout: timeout,
            standardOutputLimit: standardOutputLimit,
            standardErrorLimit: standardErrorLimit
        )
    }

    fileprivate var dispatchQoS: DispatchQoS.QoSClass {
        switch qualityOfService {
        case .userInteractive: .userInteractive
        case .userInitiated: .userInitiated
        case .default: .default
        case .background: .background
        case .utility: .utility
        @unknown default: .utility
        }
    }

    var redactedCommand: String {
        let rendered = arguments.enumerated().map { index, argument in
            redactedArgumentIndexes.contains(index) ? "<redacted>" : Self.shellQuoted(argument)
        }
        return ([Self.shellQuoted(executableURL.path)] + rendered).joined(separator: " ")
    }

    private static func shellQuoted(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/:=@"))
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct ProcessRunResult: Sendable {
    enum Termination: Sendable, Equatable {
        case exit(Int32)
        case signal(Int32)
    }

    let termination: Termination
    let standardOutput: Data
    let standardError: Data
    let standardOutputTruncated: Bool
    let standardErrorTruncated: Bool
    let elapsed: Duration
    let redactedCommand: String

    var standardOutputString: String {
        String(decoding: standardOutput, as: UTF8.self)
    }

    var standardErrorString: String {
        String(decoding: standardError, as: UTF8.self)
    }

    /// Safe for logs: output and environment values are never interpolated.
    var diagnosticSummary: String {
        let status: String
        switch termination {
        case .exit(let code): status = "exit=\(code)"
        case .signal(let signal): status = "signal=\(signal)"
        }
        let truncation = standardOutputTruncated || standardErrorTruncated ? " output=truncated" : ""
        return "\(redactedCommand) [\(status)\(truncation)]"
    }
}

enum ProcessRunnerError: Error, Sendable, LocalizedError {
    case launch(command: String, message: String)
    case nonZeroExit(ProcessRunResult)
    case timedOut(ProcessRunResult)
    case cancelled(ProcessRunResult)
    case outputTruncated(ProcessRunResult)

    var result: ProcessRunResult? {
        switch self {
        case .launch: nil
        case .nonZeroExit(let result), .timedOut(let result), .cancelled(let result),
             .outputTruncated(let result): result
        }
    }

    var errorDescription: String? {
        switch self {
        case .launch(let command, let message):
            "Could not launch \(command): \(message)"
        case .nonZeroExit(let result):
            "Command failed: \(result.diagnosticSummary)"
        case .timedOut(let result):
            "Command timed out: \(result.diagnosticSummary)"
        case .cancelled(let result):
            "Command cancelled: \(result.diagnosticSummary)"
        case .outputTruncated(let result):
            "Command exceeded its output limit: \(result.diagnosticSummary)"
        }
    }
}

/// Runs developer tools without a shell, bounding both output streams and
/// reliably stopping children when the Swift task is cancelled or times out.
enum ProcessRunner {
    static func run(_ invocation: ProcessInvocation) async throws -> ProcessRunResult {
        let control = ProcessControl(gracePeriod: invocation.terminationGracePeriod)
        return try await withTaskCancellationHandler {
            // Process and pipe polling must not occupy Swift's cooperative
            // executor: enough concurrent commands would starve other tasks.
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: invocation.dispatchQoS).async {
                    continuation.resume(with: Result { try execute(invocation, control: control) })
                }
            }
        } onCancel: {
            control.requestStop(.cancelled)
        }
    }

    /// Compatibility bridge for synchronous framework APIs. New call sites
    /// should prefer `run`; both paths use the same bounded implementation.
    static func runBlocking(_ invocation: ProcessInvocation) throws -> ProcessRunResult {
        try execute(
            invocation,
            control: ProcessControl(gracePeriod: invocation.terminationGracePeriod),
            cancellationProbe: {
                withUnsafeCurrentTask { $0?.isCancelled ?? false }
            }
        )
    }

    private static func execute(
        _ invocation: ProcessInvocation,
        control: ProcessControl,
        cancellationProbe: (() -> Bool)? = nil
    ) throws -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.currentDirectoryURL = invocation.currentDirectoryURL
        if let environment = invocation.environment { process.environment = environment }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice
        process.qualityOfService = invocation.qualityOfService

        let stdout = OutputCapture(limit: invocation.standardOutputLimit)
        let stderr = OutputCapture(limit: invocation.standardErrorLimit)
        defer {
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            stdoutPipe.fileHandleForWriting.closeFile()
            stderrPipe.fileHandleForWriting.closeFile()
        }

        let started = ContinuousClock.now
        do {
            try stdout.makeNonblocking(stdoutPipe.fileHandleForReading)
            try stderr.makeNonblocking(stderrPipe.fileHandleForReading)
            try process.run()
        } catch {
            throw ProcessRunnerError.launch(
                command: invocation.redactedCommand,
                message: error.localizedDescription
            )
        }

        control.register(processIdentifier: process.processIdentifier)
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
        let deadline = started.advanced(by: invocation.timeout)
        while true {
            let running = process.isRunning
            // Retire the PID before waiting on inherited pipes. Cancellation
            // must never signal a PID that the OS could have reused.
            if !running { control.childDidExit() }
            if cancellationProbe?() == true { control.requestStop(.cancelled) }
            if ContinuousClock.now >= deadline { control.requestStop(.timedOut) }

            let readStdout = stdout.drainAvailable(stdoutPipe.fileHandleForReading)
            let readStderr = stderr.drainAvailable(stderrPipe.fileHandleForReading)
            if !running && ((stdout.reachedEOF && stderr.reachedEOF) || control.stopReason != nil) {
                break
            }
            // Poll again immediately while wanted output is flowing; a full
            // pipe otherwise stalls the child for the whole sleep. Each pass is
            // still bounded, so deadlines and cancellation stay responsive, and
            // output past a limit is discarded at the sleeping cadence.
            let flowing = (readStdout && !stdout.isTruncated) || (readStderr && !stderr.isTruncated)
            if !flowing { Thread.sleep(forTimeInterval: 0.01) }
        }
        let stopReason = control.finish()

        let termination: ProcessRunResult.Termination = switch process.terminationReason {
        case .exit: .exit(process.terminationStatus)
        case .uncaughtSignal: .signal(process.terminationStatus)
        @unknown default: .signal(process.terminationStatus)
        }
        let stdoutSnapshot = stdout.snapshot()
        let stderrSnapshot = stderr.snapshot()
        let result = ProcessRunResult(
            termination: termination,
            standardOutput: stdoutSnapshot.data,
            standardError: stderrSnapshot.data,
            standardOutputTruncated: stdoutSnapshot.truncated,
            standardErrorTruncated: stderrSnapshot.truncated,
            elapsed: started.duration(to: .now),
            redactedCommand: invocation.redactedCommand
        )

        switch stopReason {
        case .cancelled: throw ProcessRunnerError.cancelled(result)
        case .timedOut: throw ProcessRunnerError.timedOut(result)
        case nil: break
        }
        if result.standardOutputTruncated || result.standardErrorTruncated {
            throw ProcessRunnerError.outputTruncated(result)
        }
        guard result.termination == .exit(0) else {
            throw ProcessRunnerError.nonZeroExit(result)
        }
        return result
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

/// Owned exclusively by the command's worker. No blocking reads or orphaned
/// reader threads, even when grandchildren inherit the command's output pipes.
private final class OutputCapture {
    private let limit: Int
    private var data = Data()
    private var truncated = false
    private(set) var reachedEOF = false
    var isTruncated: Bool { truncated }

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    func makeNonblocking(_ handle: FileHandle) throws {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Returns whether any bytes were read during this pass.
    @discardableResult
    func drainAvailable(_ handle: FileHandle) -> Bool {
        guard !reachedEOF else { return false }
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        var didRead = false
        // Bound each pass so a continuously writing child cannot starve the
        // other stream, deadline checks, or cancellation.
        for _ in 0..<4 {
            let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
            if count == 0 {
                reachedEOF = true
                return didRead
            }
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { reachedEOF = true }
                return didRead
            }
            didRead = true
            let remaining = max(0, limit - data.count)
            if remaining > 0 { data.append(contentsOf: buffer.prefix(min(count, remaining))) }
            if count > remaining { truncated = true }
        }
        return didRead
    }

    func snapshot() -> (data: Data, truncated: Bool) {
        return (data, truncated)
    }
}

private final class ProcessControl: @unchecked Sendable {
    enum StopReason {
        case cancelled
        case timedOut
    }

    private let lock = NSLock()
    private let gracePeriod: Duration
    private var processIdentifier: pid_t?
    private var requestedStop: StopReason?
    private var finished = false

    init(gracePeriod: Duration) {
        self.gracePeriod = gracePeriod
    }

    func register(processIdentifier: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        self.processIdentifier = processIdentifier
        let shouldStop = requestedStop != nil && !finished
        if shouldStop { terminateThenKill(processIdentifier) }
    }

    func requestStop(_ reason: StopReason) {
        lock.lock()
        defer { lock.unlock() }
        guard requestedStop == nil, !finished else { return }
        requestedStop = reason
        if let processIdentifier { terminateThenKill(processIdentifier) }
    }

    func childDidExit() {
        lock.lock()
        defer { lock.unlock() }
        processIdentifier = nil
    }

    var stopReason: StopReason? {
        lock.lock()
        defer { lock.unlock() }
        return requestedStop
    }

    func finish() -> StopReason? {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        processIdentifier = nil
        return requestedStop
    }

    private func terminateThenKill(_ pid: pid_t) {
        Darwin.kill(pid, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + gracePeriod.timeInterval
        ) {
            // The queue owns this bounded escalation, not ProcessControl, so
            // retaining self cannot form a cycle. Keep it alive in optimized
            // blocking calls until the scheduled kill has checked ownership.
            self.lock.lock()
            defer { self.lock.unlock() }
            let shouldKill = !self.finished && self.processIdentifier == pid
            if shouldKill { Darwin.kill(pid, SIGKILL) }
        }
    }
}
