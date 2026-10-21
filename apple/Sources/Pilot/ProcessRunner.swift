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
    /// Optional scheduling class for the child and the worker that waits on
    /// it. `nil` (the default) leaves `Process.qualityOfService` unset, so the
    /// child keeps Foundation's default class, and runs the worker at
    /// `.utility`, the runner's long-standing behavior. Set it only when the
    /// command's latency is itself measured or awaited by a user.
    var qualityOfService: QualityOfService?

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
        qualityOfService: QualityOfService? = nil
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
        guard let qualityOfService else { return .utility }
        return switch qualityOfService {
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
            // The worker blocks waiting on the child and its pipes; that must
            // not occupy Swift's cooperative executor, or enough concurrent
            // commands would starve other tasks.
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

    /// Builds the child without launching it. Internal so tests can confirm
    /// the scheduling class a caller gets when it does not opt in.
    static func makeProcess(for invocation: ProcessInvocation) -> Process {
        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.currentDirectoryURL = invocation.currentDirectoryURL
        if let environment = invocation.environment { process.environment = environment }
        // Leave the child at Foundation's default unless a caller opts in:
        // assigning `.utility` here would demote every background command.
        if let qualityOfService = invocation.qualityOfService {
            process.qualityOfService = qualityOfService
        }
        return process
    }

    private static func execute(
        _ invocation: ProcessInvocation,
        control: ProcessControl,
        cancellationProbe: (() -> Bool)? = nil
    ) throws -> ProcessRunResult {
        let process = makeProcess(for: invocation)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let stdout = OutputCapture(limit: invocation.standardOutputLimit)
        let stderr = OutputCapture(limit: invocation.standardErrorLimit)
        defer {
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            stdoutPipe.fileHandleForWriting.closeFile()
            stderrPipe.fileHandleForWriting.closeFile()
        }

        let started = ContinuousClock.now
        let waker: EventWaker
        do {
            waker = try EventWaker()
            try stdout.makeNonblocking(stdoutPipe.fileHandleForReading)
            try stderr.makeNonblocking(stderrPipe.fileHandleForReading)
            // Exit and stop requests only wake the worker's wait below; the
            // loop itself re-reads all process and pipe state after waking.
            process.terminationHandler = { _ in waker.signal() }
            control.setStopHandler { waker.signal() }
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

            stdout.drainAvailable(stdoutPipe.fileHandleForReading)
            stderr.drainAvailable(stderrPipe.fileHandleForReading)
            if !running && ((stdout.reachedEOF && stderr.reachedEOF) || control.stopReason != nil) {
                break
            }

            // Block until pipe data or EOF, a wake (child exit or a stop
            // request), or the nearest timer — no periodic busy-poll.
            var wait = control.stopReason == nil
                ? ContinuousClock.now.duration(to: deadline)
                : Self.stopSettleInterval
            if cancellationProbe != nil { wait = min(wait, Self.cancellationProbeInterval) }
            var readable: [Int32] = []
            if !stdout.reachedEOF { readable.append(stdoutPipe.fileHandleForReading.fileDescriptor) }
            if !stderr.reachedEOF { readable.append(stderrPipe.fileHandleForReading.fileDescriptor) }
            waker.wait(forReadableDescriptors: readable, timeout: wait)
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

    /// The blocking bridge has no cancellation event to observe, so its waits
    /// are capped to keep the cancellation probe responsive.
    private static let cancellationProbeInterval: Duration = .milliseconds(50)

    /// Defensive wait bound after a stop request, in case the termination
    /// handler's wake is missed; exit normally wakes the wait immediately.
    private static let stopSettleInterval: Duration = .milliseconds(100)

    /// poll(2) timeout: rounds up so a positive remainder never spins at zero
    /// milliseconds, and saturates instead of overflowing Int32.
    static func pollMilliseconds(for duration: Duration) -> Int32 {
        guard duration > .zero else { return 0 }
        guard duration < .milliseconds(Int32.max) else { return Int32.max }
        let components = duration.components
        let milliseconds = components.seconds * 1_000
            + (components.attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000
        return Int32(clamping: milliseconds)
    }
}

/// A nonblocking self-pipe that lets the termination handler and stop requests
/// wake the worker's poll(2) wait. Close-on-exec keeps both ends out of
/// children, and the descriptors stay open until every signaller has released
/// its reference, so a late termination handler can never hit a reused
/// descriptor.
private final class EventWaker: @unchecked Sendable {
    private let readDescriptor: Int32
    private let writeDescriptor: Int32

    init() throws {
        var descriptors: [Int32] = [-1, -1]
        guard Darwin.pipe(&descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        readDescriptor = descriptors[0]
        writeDescriptor = descriptors[1]
        for descriptor in descriptors {
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }
    }

    deinit {
        Darwin.close(readDescriptor)
        Darwin.close(writeDescriptor)
    }

    func signal() {
        var token: UInt8 = 1
        _ = Darwin.write(writeDescriptor, &token, 1)
    }

    /// Blocks until any descriptor is readable, a wake token arrives, or the
    /// timeout lapses, then drains pending tokens so a handled wake cannot
    /// spin the caller.
    func wait(forReadableDescriptors descriptors: [Int32], timeout: Duration) {
        var pollDescriptors = [pollfd(fd: readDescriptor, events: Int16(POLLIN), revents: 0)]
        for descriptor in descriptors {
            pollDescriptors.append(pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0))
        }
        _ = Darwin.poll(
            &pollDescriptors,
            nfds_t(pollDescriptors.count),
            ProcessRunner.pollMilliseconds(for: timeout)
        )
        var drained = [UInt8](repeating: 0, count: 64)
        while Darwin.read(readDescriptor, &drained, drained.count) == drained.count {}
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

    func drainAvailable(_ handle: FileHandle) {
        guard !reachedEOF else { return }
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        // Bound each pass so a continuously writing child cannot starve the
        // other stream, deadline checks, or cancellation.
        for _ in 0..<4 {
            let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
            if count == 0 {
                reachedEOF = true
                return
            }
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { reachedEOF = true }
                return
            }
            let remaining = max(0, limit - data.count)
            if remaining > 0 { data.append(contentsOf: buffer.prefix(min(count, remaining))) }
            if count > remaining { truncated = true }
        }
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
    private var onStopRequested: (@Sendable () -> Void)?
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

    /// Wakes the worker's event wait when a stop arrives after the child has
    /// already exited, where no termination handler will fire again.
    func setStopHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        onStopRequested = handler
    }

    func requestStop(_ reason: StopReason) {
        lock.lock()
        defer { lock.unlock() }
        guard requestedStop == nil, !finished else { return }
        requestedStop = reason
        if let processIdentifier { terminateThenKill(processIdentifier) }
        onStopRequested?()
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
