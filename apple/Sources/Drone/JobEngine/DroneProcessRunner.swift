import Darwin
import Foundation

struct DroneProcessRunOutcome {
    var exitCode: Int32?
    var signal: Int32?
    var standardOutputTruncated: Bool
    var standardErrorTruncated: Bool
    var wasCancelled: Bool
    var deadlineExceeded: Bool
}

final class DroneProcessGroupControl: @unchecked Sendable {
    enum StopReason {
        case cancelled
        case deadline
        case aborted
    }

    private let lock = NSLock()
    private let gracePeriod: TimeInterval
    private var groupID: pid_t?
    private var stopReason: StopReason?
    private var wake: (() -> Void)?
    private var finished = false

    init(gracePeriod: TimeInterval) {
        self.gracePeriod = gracePeriod
    }

    var requestedStop: StopReason? {
        lock.lock()
        defer { lock.unlock() }
        return stopReason
    }

    func cancel() {
        requestStop(.cancelled)
    }

    func setWakeHandler(_ handler: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        wake = handler
    }

    func register(groupID: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        self.groupID = groupID
        if stopReason != nil, !finished { terminateThenKill(groupID) }
    }

    func requestStop(_ reason: StopReason) {
        lock.lock()
        defer { lock.unlock() }
        guard stopReason == nil, !finished else { return }
        stopReason = reason
        if let groupID { terminateThenKill(groupID) }
        wake?()
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        // The runner retains the unreaped group leader until this point, so
        // its PID cannot be recycled while we finish cancellation escalation.
        if stopReason != nil, let groupID { _ = Darwin.kill(-groupID, SIGKILL) }
        finished = true
        groupID = nil
    }

    private func terminateThenKill(_ groupID: pid_t) {
        _ = Darwin.kill(-groupID, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + gracePeriod) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            if !self.finished, self.groupID == groupID {
                _ = Darwin.kill(-groupID, SIGKILL)
            }
        }
    }
}

enum DroneProcessRunner {
    static func run(
        operation: DroneProcessOperation,
        currentDirectory: URL,
        environment: [String: String],
        control: DroneProcessGroupControl,
        onOutput: @escaping (DroneJobStream, Data) throws -> Void,
        onTruncated: @escaping (DroneJobStream) throws -> Void
    ) throws -> DroneProcessRunOutcome {
        if control.requestedStop != nil {
            return DroneProcessRunOutcome(
                exitCode: nil,
                signal: nil,
                standardOutputTruncated: false,
                standardErrorTruncated: false,
                wasCancelled: control.requestedStop == .cancelled,
                deadlineExceeded: control.requestedStop == .deadline
            )
        }
        let stdoutPipe = try NonblockingPipe()
        defer { stdoutPipe.closeAll() }
        let stderrPipe = try NonblockingPipe()
        defer { stderrPipe.closeAll() }
        let waker = try DroneProcessWaker()
        let pid = try spawn(
            operation: operation,
            currentDirectory: currentDirectory,
            environment: environment,
            stdout: stdoutPipe.writeDescriptor,
            stderr: stderrPipe.writeDescriptor
        )
        stdoutPipe.closeWriter()
        stderrPipe.closeWriter()
        control.register(groupID: pid)
        defer {
            control.finish()
            reap(pid)
        }
        control.setWakeHandler { waker.signal() }
        defer { control.setWakeHandler {} }

        let stdout = DroneProcessOutputCapture(
            stream: .standardOutput,
            limit: operation.standardOutputLimit,
            onOutput: onOutput,
            onTruncated: onTruncated
        )
        let stderr = DroneProcessOutputCapture(
            stream: .standardError,
            limit: operation.standardErrorLimit,
            onOutput: onOutput,
            onTruncated: onTruncated
        )
        let started = ContinuousClock.now
        let deadline = started + .milliseconds(operation.timeoutMilliseconds)
        var waitStatus: Int32?
        var handlerError: Error?
        var forcedStopDeadline: ContinuousClock.Instant?

        while true {
            if waitStatus == nil {
                var info = siginfo_t()
                let result = Darwin.waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
                if result == 0, info.si_pid == pid {
                    waitStatus = info.si_code == CLD_EXITED ? info.si_status << 8 : info.si_status & 0x7F
                }
            }
            if ContinuousClock.now >= deadline { control.requestStop(.deadline) }
            if control.requestedStop != nil, forcedStopDeadline == nil {
                forcedStopDeadline = .now + .seconds(2)
            }
            do {
                try stdout.drain(stdoutPipe.readDescriptor)
                try stderr.drain(stderrPipe.readDescriptor)
            } catch {
                handlerError = error
                control.requestStop(.aborted)
            }
            let pipesClosed = stdout.reachedEOF && stderr.reachedEOF
            if waitStatus != nil && pipesClosed { break }
            if let forcedStopDeadline, ContinuousClock.now >= forcedStopDeadline { break }

            var descriptors: [Int32] = []
            if !stdout.reachedEOF { descriptors.append(stdoutPipe.readDescriptor) }
            if !stderr.reachedEOF { descriptors.append(stderrPipe.readDescriptor) }
            let wait = min(
                ContinuousClock.now.duration(to: deadline),
                .milliseconds(100)
            )
            waker.wait(descriptors: descriptors, timeout: wait)
        }
        if let handlerError { throw handlerError }
        guard let waitStatus else {
            return DroneProcessRunOutcome(
                exitCode: nil,
                signal: nil,
                standardOutputTruncated: stdout.truncated,
                standardErrorTruncated: stderr.truncated,
                wasCancelled: control.requestedStop == .cancelled,
                deadlineExceeded: control.requestedStop == .deadline
            )
        }
        let termination = decodeWaitStatus(waitStatus)
        return DroneProcessRunOutcome(
            exitCode: termination.exitCode,
            signal: termination.signal,
            standardOutputTruncated: stdout.truncated,
            standardErrorTruncated: stderr.truncated,
            wasCancelled: control.requestedStop == .cancelled,
            deadlineExceeded: control.requestedStop == .deadline
        )
    }

    private static func reap(_ pid: pid_t) {
        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = Darwin.waitpid(pid, &status, WNOHANG)
        } while result < 0 && errno == EINTR
        if result == 0 {
            // A forced-stop deadline must not block the caller indefinitely,
            // but the owned child still needs a waiter to prevent a zombie.
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                while Darwin.waitpid(pid, &status, 0) < 0, errno == EINTR {}
            }
        }
    }

    private static func decodeWaitStatus(_ status: Int32) -> (exitCode: Int32?, signal: Int32?) {
        let signal = status & 0x7F
        if signal == 0 { return ((status >> 8) & 0xFF, nil) }
        return (nil, signal)
    }

    private static func spawn(
        operation: DroneProcessOperation,
        currentDirectory: URL,
        environment: [String: String],
        stdout: Int32,
        stderr: Int32
    ) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw POSIXError(.EIO)
        }
        defer { posix_spawnattr_destroy(&attributes) }
        // Start every job with no blocked signals and default dispositions:
        // a spawning Swift concurrency thread blocks SIGTERM, SIGHUP, SIGINT,
        // and more, and droned ignores SIGTERM/SIGINT. Both survive exec, so
        // without this a job would never see the group SIGTERM that cancels it.
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        var defaults = sigset_t()
        sigfillset(&defaults)
        sigdelset(&defaults, SIGKILL)
        sigdelset(&defaults, SIGSTOP)
        guard posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setsigmask(&attributes, &unblocked) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawnattr_setflags(
                  &attributes,
                  Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                      | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
              ) == 0
        else { throw POSIXError(.EIO) }

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw POSIXError(.EIO)
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        let nullDescriptor = Darwin.open("/dev/null", O_RDWR)
        guard nullDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(nullDescriptor) }
        guard posix_spawn_file_actions_adddup2(&fileActions, nullDescriptor, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&fileActions, stdout, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&fileActions, stderr, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addchdir(&fileActions, currentDirectory.path) == 0
        else { throw POSIXError(.EIO) }

        let values = [operation.executablePath] + operation.arguments
        let environmentValues = environment.map { "\($0.key)=\($0.value)" }
        let arguments = values.map { strdup($0) }
        let childEnvironment = environmentValues.map { strdup($0) }
        defer {
            for value in arguments { free(value) }
            for value in childEnvironment { free(value) }
        }
        var argumentPointers = arguments
        argumentPointers.append(nil)
        var environmentPointers = childEnvironment
        environmentPointers.append(nil)
        var pid = pid_t()
        let result = operation.executablePath.withCString { executable in
            posix_spawn(
                &pid,
                executable,
                &fileActions,
                &attributes,
                &argumentPointers,
                &environmentPointers
            )
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }
        return pid
    }
}

private final class NonblockingPipe {
    let readDescriptor: Int32
    let writeDescriptor: Int32
    private var closed = Set<Int32>()

    init() throws {
        var descriptors: [Int32] = [-1, -1]
        guard Darwin.pipe(&descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        readDescriptor = descriptors[0]
        writeDescriptor = descriptors[1]
        // Only the worker reader is nonblocking. Child stdout/stderr must retain
        // normal pipe backpressure instead of failing writes with EAGAIN.
        let flags = fcntl(readDescriptor, F_GETFL)
        guard flags >= 0, fcntl(readDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            let error = errno
            Darwin.close(readDescriptor)
            Darwin.close(writeDescriptor)
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
    }

    func closeWriter() {
        Darwin.close(writeDescriptor)
        closed.insert(writeDescriptor)
    }

    func closeAll() {
        for descriptor in [readDescriptor, writeDescriptor] where !closed.contains(descriptor) {
            Darwin.close(descriptor)
            closed.insert(descriptor)
        }
    }
}

private final class DroneProcessOutputCapture {
    let stream: DroneJobStream
    private let limit: Int
    private let onOutput: (DroneJobStream, Data) throws -> Void
    private let onTruncated: (DroneJobStream) throws -> Void
    private var retainedBytes = 0
    private(set) var truncated = false
    private(set) var reachedEOF = false

    init(
        stream: DroneJobStream,
        limit: Int,
        onOutput: @escaping (DroneJobStream, Data) throws -> Void,
        onTruncated: @escaping (DroneJobStream) throws -> Void
    ) {
        self.stream = stream
        self.limit = limit
        self.onOutput = onOutput
        self.onTruncated = onTruncated
    }

    func drain(_ descriptor: Int32) throws {
        guard !reachedEOF else { return }
        var buffer = [UInt8](repeating: 0, count: Int(DroneLimits.maxOutputChunkBytes))
        for _ in 0 ..< 4 {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 {
                reachedEOF = true
                return
            }
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { reachedEOF = true }
                return
            }
            guard !truncated else { continue }
            let remaining = max(0, limit - retainedBytes)
            let retainedCount = min(count, remaining)
            if retainedCount > 0 {
                try onOutput(stream, Data(buffer.prefix(retainedCount)))
                retainedBytes += retainedCount
            }
            if count > remaining {
                truncated = true
                try onTruncated(stream)
            }
        }
    }
}

private final class DroneProcessWaker {
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

    func wait(descriptors: [Int32], timeout: Duration) {
        var pollDescriptors = [pollfd(fd: readDescriptor, events: Int16(POLLIN), revents: 0)]
        for descriptor in descriptors {
            pollDescriptors.append(pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0))
        }
        _ = Darwin.poll(&pollDescriptors, nfds_t(pollDescriptors.count), milliseconds(timeout))
        var drained = [UInt8](repeating: 0, count: 64)
        while Darwin.read(readDescriptor, &drained, drained.count) == drained.count {}
    }

    private func milliseconds(_ duration: Duration) -> Int32 {
        guard duration > .zero else { return 0 }
        guard duration < .milliseconds(Int32.max) else { return Int32.max }
        let components = duration.components
        let value = components.seconds * 1_000
            + (components.attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000
        return Int32(clamping: value)
    }
}
