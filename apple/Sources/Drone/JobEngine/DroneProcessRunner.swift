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

/// Identifies a job's process group across a worker restart. The leader's
/// start time distinguishes the original group from a later reuse of its PID.
struct DroneProcessGroupRecord: Codable, Equatable, Sendable {
    var groupID: Int32
    var leaderStartSeconds: UInt64
    var leaderStartMicroseconds: UInt64

    static func capture(leader pid: pid_t) -> DroneProcessGroupRecord? {
        guard let entry = DroneProcessTable.entry(pid), entry.groupID == pid else { return nil }
        return DroneProcessGroupRecord(
            groupID: pid,
            leaderStartSeconds: entry.startSeconds,
            leaderStartMicroseconds: entry.startMicroseconds
        )
    }

    fileprivate func startedNoLaterThan(_ entry: DroneProcessTable.Entry) -> Bool {
        (leaderStartSeconds, leaderStartMicroseconds) <= (entry.startSeconds, entry.startMicroseconds)
    }

    fileprivate func isLeader(_ entry: DroneProcessTable.Entry) -> Bool {
        leaderStartSeconds == entry.startSeconds && leaderStartMicroseconds == entry.startMicroseconds
    }
}

/// Lists the members of a process group that are still running (zombies
/// excluded), or nil when the group cannot be listed. Injectable so proofs can
/// model a member that outlives SIGKILL: another user's setuid descendant, or
/// one blocked in uninterruptible I/O.
typealias DroneProcessGroupMembers = @Sendable (pid_t) -> [pid_t]?

enum DroneProcessTable {
    /// `SZOMB` in `<sys/proc.h>`: exited, waiting for its parent to reap it.
    private static let zombieStatus: UInt32 = 5

    struct Entry {
        var groupID: pid_t
        var userID: uid_t
        var status: UInt32
        var startSeconds: UInt64
        var startMicroseconds: UInt64

        var isZombie: Bool { status == DroneProcessTable.zombieStatus }
    }

    /// Reads a process through `sysctl(KERN_PROC_PID)`, which, unlike
    /// `proc_pidinfo(PROC_PIDTBSDINFO)`, also describes a zombie (that call
    /// fails with ESRCH once a process has exited, even before it is reaped).
    /// The start time is the same value `proc_pidinfo` reports, so records
    /// written by either read compare equal. Nil means no such process.
    static func entry(_ pid: pid_t) -> Entry? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard Darwin.sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.size,
              info.kp_proc.p_pid == pid
        else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        guard start.tv_sec >= 0, start.tv_usec >= 0 else { return nil }
        return Entry(
            groupID: info.kp_eproc.e_pgid,
            userID: info.kp_eproc.e_ucred.cr_uid,
            status: UInt32(UInt8(bitPattern: info.kp_proc.p_stat)),
            startSeconds: UInt64(start.tv_sec),
            startMicroseconds: UInt64(start.tv_usec)
        )
    }

    /// Bounded: a group larger than `limit` is reported only partially. Nil
    /// means the kernel could not list the group, which never proves it empty.
    static func members(ofGroup groupID: pid_t, limit: Int = 4_096) -> [pid_t]? {
        guard groupID > 0, limit > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: limit)
        errno = 0
        let bytes = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(
                UInt32(PROC_PGRP_ONLY),
                UInt32(bitPattern: groupID),
                buffer.baseAddress,
                Int32(clamping: buffer.count)
            )
        }
        guard let count = listedCount(bytes: bytes, error: errno, limit: limit) else { return nil }
        return pids.prefix(count).filter { $0 > 0 }
    }

    /// Interprets a `proc_listpids` result. libproc maps a failed listing to
    /// 0 (not -1) and leaves errno set, so with errno cleared before the call
    /// only errno tells a failure apart from an empty group.
    static func listedCount(bytes: Int32, error: Int32, limit: Int) -> Int? {
        guard bytes >= 0, bytes > 0 || error == 0 else { return nil }
        return min(limit, Int(bytes) / MemoryLayout<pid_t>.stride)
    }

    /// Members that are still running; a zombie never runs again and is never
    /// counted. A listed PID that cannot be read but still exists (`kill(pid,
    /// 0)` succeeds or is denied) counts, so an unreadable process is never
    /// mistaken for an exited one.
    static func liveMembers(ofGroup groupID: pid_t) -> [pid_t]? {
        Self.members(ofGroup: groupID)?.filter { pid in
            if let member = Self.entry(pid) { return !member.isZombie && member.groupID == groupID }
            return Darwin.kill(pid, 0) == 0 || errno == EPERM
        }
    }

    /// Polls until no member of `groupID` is still running, or `timeout`
    /// passes. `unreapedLeader` is a child of this process that is still
    /// waiting to be reaped: it counts as gone once it has exited, because a
    /// zombie never runs again and its PID (the group ID) stays reserved until
    /// the caller reaps it. `resignal` runs on every poll that still finds a
    /// member running, so a child forked while an earlier SIGKILL was being
    /// delivered is signalled again. False means a member was still running,
    /// or the group could not be listed, when the wait gave up.
    static func waitForGroupExit(
        _ groupID: pid_t,
        unreapedLeader: pid_t? = nil,
        timeout: TimeInterval,
        liveMembers: DroneProcessGroupMembers = { DroneProcessTable.liveMembers(ofGroup: $0) },
        resignal: ((pid_t) -> Void)? = nil
    ) -> Bool {
        let bounded = timeout.isFinite ? max(0, min(timeout, 10)) : 0
        let deadline = Date().addingTimeInterval(bounded)
        while true {
            if let members = liveMembers(groupID),
               members.allSatisfy({ $0 == unreapedLeader }),
               unreapedLeader.map(childHasExited) ?? true {
                return true
            }
            guard Date() < deadline else { return false }
            resignal?(groupID)
            usleep(10_000)
        }
    }

    private static func childHasExited(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        let result = Darwin.waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        if result == 0 { return info.si_pid == pid }
        return errno == ECHILD
    }

    /// Kills a group that a crashed worker left behind, then waits a bounded
    /// time for it to disappear, signalling it again on every poll while it
    /// still matches the record. Returns true only when nothing of the
    /// recorded group can still be running; recovery treats false as an
    /// unverified group (#441) and never silently finalizes it.
    static func killOrphanedGroup(_ record: DroneProcessGroupRecord, timeout: TimeInterval = 1) -> Bool {
        let groupID = pid_t(record.groupID)
        guard groupID > 1, groupID != getpid(), groupID != getpgrp() else { return false }
        switch orphanedGroupState(record) {
        case .gone: return true
        case .unsafe: return false
        case .killable: break
        }
        guard Darwin.kill(-groupID, SIGKILL) == 0 else { return errno == ESRCH }
        return waitForGroupExit(groupID, timeout: timeout, resignal: { groupID in
            // The leader is not this process's child, so the group ID is only
            // known to be the recorded one while the group still matches.
            if case .killable = orphanedGroupState(record) { _ = Darwin.kill(-groupID, SIGKILL) }
        })
    }

    private enum OrphanedGroupState {
        /// Nothing of the recorded group is still running.
        case gone
        /// Every running member provably belongs to the recorded group.
        case killable
        /// A member that cannot be attributed to the record, or no listing.
        case unsafe
    }

    /// Classifies a recorded group without signalling it. A live or zombie
    /// leader with another start time means the recorded group is gone (a PID
    /// is never reused while its process group exists). With the leader
    /// already reaped, every running member must belong to this user and have
    /// started no earlier than the recorded leader. Zombies never block: they
    /// have exited and are only waiting for a parent to reap them.
    private static func orphanedGroupState(_ record: DroneProcessGroupRecord) -> OrphanedGroupState {
        let groupID = pid_t(record.groupID)
        if let leader = Self.entry(groupID) {
            return record.isLeader(leader) ? .killable : .gone
        }
        guard let survivors = Self.liveMembers(ofGroup: groupID) else { return .unsafe }
        var running = false
        for pid in survivors {
            guard let member = Self.entry(pid) else {
                // Exited since the listing, or unreadable: only the latter blocks.
                if Darwin.kill(pid, 0) == 0 || errno == EPERM { return .unsafe }
                continue
            }
            // Exited or left the group since the listing.
            if member.isZombie || member.groupID != groupID { continue }
            guard member.userID == getuid(), record.startedNoLaterThan(member) else { return .unsafe }
            running = true
        }
        return running ? .killable : .gone
    }
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
    private var survived = false
    private let exitTimeout: TimeInterval
    private let liveMembers: DroneProcessGroupMembers

    /// `exitTimeout` bounds how long `finish()` waits for the killed group to
    /// disappear before the job may be recorded finished.
    init(
        gracePeriod: TimeInterval,
        exitTimeout: TimeInterval = 2,
        liveMembers: @escaping DroneProcessGroupMembers = { DroneProcessTable.liveMembers(ofGroup: $0) }
    ) {
        self.gracePeriod = gracePeriod
        self.exitTimeout = exitTimeout
        self.liveMembers = liveMembers
    }

    /// True once `finish()` gave up with a group member still running (for
    /// example another user's setuid descendant, which this user cannot
    /// kill). The job must then be recorded as leaving an unverified group.
    var processGroupSurvived: Bool {
        lock.lock()
        defer { lock.unlock() }
        return survived
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

    /// Kills the group and waits, bounded by `exitTimeout`, until none of it
    /// is still running. Returns false (and latches `processGroupSurvived`)
    /// when a member outlived the wait.
    @discardableResult
    func finish() -> Bool {
        lock.lock()
        // The runner retains the unreaped group leader until after this
        // returns, so its PID (and therefore the group ID) cannot be recycled.
        // Kill the group on every exit path, not only after a stop request: a
        // leader that exits normally can leave descendants that redirected
        // their output, and nothing else would ever signal them (#441).
        let groupID = self.groupID
        if let groupID { _ = Darwin.kill(-groupID, SIGKILL) }
        finished = true
        self.groupID = nil
        lock.unlock()
        guard let groupID else { return true }
        // SIGKILL is asynchronous: confirm the group is gone before the
        // caller records the job finished. Wait outside the lock so a
        // concurrent cancel never blocks behind it.
        // Re-send SIGKILL on every poll: a member forking at the moment of
        // the first signal can create a child that signal missed. The
        // unreaped leader reserves the group ID, so this never reaches
        // another group (#441).
        let gone = DroneProcessTable.waitForGroupExit(
            groupID,
            unreapedLeader: groupID,
            timeout: exitTimeout,
            liveMembers: liveMembers,
            resignal: { _ = Darwin.kill(-$0, SIGKILL) }
        )
        if !gone {
            lock.lock()
            survived = true
            lock.unlock()
        }
        return gone
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
        beforeLaunch: () throws -> Void = {},
        onLaunch: (DroneProcessGroupRecord) throws -> Void = { _ in },
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
        // Mark the job as launching before any process exists. The PID is
        // unknown until posix_spawn returns, so a worker that dies between the
        // spawn and `onLaunch` leaves only this marker: recovery then reports
        // the group as unverified instead of finalizing silently (#441). The
        // leader in that window is still suspended and has run nothing.
        try beforeLaunch()
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
        // The leader starts suspended. Persist its group identity before it
        // runs a single instruction, so a worker crash at any later point
        // leaves a record that recovery can match and kill (#441). A failure
        // here kills the still-suspended group through the deferred finish.
        guard let group = DroneProcessGroupRecord.capture(leader: pid) else {
            throw POSIXError(.ESRCH)
        }
        try onLaunch(group)
        guard Darwin.kill(pid, SIGCONT) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ESRCH)
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
                      | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
                      | POSIX_SPAWN_START_SUSPENDED)
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
