#if os(macOS)
import Darwin
import Foundation

final class DronePTY: @unchecked Sendable {
    private let master: Int32
    private let child: pid_t
    private let queue = DispatchQueue(label: "app.blau.drone.pty")
    private let lock = NSLock()
    private let source: DispatchSourceRead
    private let onOutput: @Sendable (DronePTY, Data) -> Void
    private let onExit: @Sendable () -> Void
    private var sourceSuspended = true
    private var flowBlocked = false
    private var closed = false
    /// Set from the moment a read starts until the receiver reports, through
    /// `completeOutputDelivery(resumeReading:)`, that it appended the chunk.
    /// While it is set the read source stays suspended and `resumeReading()`
    /// does nothing, so at most one chunk is ever on its way to the receiver
    /// and chunks are appended in the order they were read (#443).
    private var chunkInFlight = false

    init(
        executable: String,
        arguments: [String],
        environment: [String: String],
        columns: UInt16,
        rows: UInt16,
        onOutput: @escaping @Sendable (DronePTY, Data) -> Void,
        onExit: @escaping @Sendable () -> Void
    ) throws {
        self.onOutput = onOutput
        self.onExit = onExit
        var master: Int32 = -1
        var window = winsize(
            ws_row: rows,
            ws_col: columns,
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        let child = forkpty(&master, nil, nil, &window)
        if child == 0 {
            // A forked child keeps the calling thread's signal mask and any
            // ignored dispositions across execve. Swift concurrency threads
            // block SIGWINCH, SIGHUP, SIGINT, SIGTERM, and more, and droned
            // ignores SIGTERM/SIGINT, so without this reset the tmux client
            // never sees a resize or hangup and terminal programs inherit
            // ignored interrupts. Both calls are async-signal-safe.
            var unblocked = sigset_t()
            sigemptyset(&unblocked)
            sigprocmask(SIG_SETMASK, &unblocked, nil)
            for signalNumber in 1..<NSIG where signalNumber != SIGKILL && signalNumber != SIGSTOP {
                signal(signalNumber, SIG_DFL)
            }
            let executablePointer = strdup(executable)
            let argumentPointers = ([executable] + arguments).map { strdup($0) }
            var argv = argumentPointers + [nil]
            let environmentPointers = environment.map { strdup("\($0.key)=\($0.value)") }
            var envp = environmentPointers + [nil]
            execve(executablePointer, &argv, &envp)
            _exit(127)
        }
        guard child > 0, master >= 0 else {
            if master >= 0 { Darwin.close(master) }
            throw DroneTerminalError.processFailed
        }
        self.master = master
        self.child = child
        source = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        let flags = fcntl(master, F_GETFL)
        guard flags >= 0, fcntl(master, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            Darwin.close(master)
            kill(child, SIGHUP)
            throw DroneTerminalError.processFailed
        }
        source.setCancelHandler { [master] in
            Darwin.close(master)
        }
        source.setEventHandler { [weak self] in
            self?.readOneChunk()
        }
        source.resume()
        lock.withLock {
            sourceSuspended = false
        }
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        let deadline = Date().addingTimeInterval(2)
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < data.count {
                if isClosed() { throw DroneTerminalError.invalidState }
                let count = Darwin.write(master, base.advanced(by: written), data.count - written)
                if count > 0 {
                    written += count
                } else if count < 0, errno == EINTR {
                    continue
                } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    guard Date() < deadline else { throw DroneTerminalError.resourceLimit }
                    var descriptor = pollfd(fd: master, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&descriptor, 1, 10)
                } else {
                    throw DroneTerminalError.processFailed
                }
            }
        }
    }

    func resize(columns: UInt16, rows: UInt16) throws {
        var window = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        guard ioctl(master, TIOCSWINSZ, &window) == 0 else {
            throw DroneTerminalError.processFailed
        }
    }

    func pauseReading() {
        lock.withLock {
            flowBlocked = true
        }
    }

    /// Resumes reading unless the PTY is closed or a chunk is still in
    /// flight; in that case only `completeOutputDelivery` may resume it.
    func resumeReading() {
        lock.withLock {
            guard !closed, !chunkInFlight else { return }
            flowBlocked = false
            if sourceSuspended {
                sourceSuspended = false
                source.resume()
            }
        }
    }

    /// Called by the receiver once the chunk passed to `onOutput` has been
    /// appended (or dropped). Clears the in-flight gate and, if requested,
    /// resumes reading the next chunk.
    func completeOutputDelivery(resumeReading shouldResume: Bool) {
        lock.withLock {
            chunkInFlight = false
        }
        if shouldResume { resumeReading() }
    }

    func close() {
        let shouldReap = lock.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true
            flowBlocked = true
            source.cancel()
            if sourceSuspended {
                source.resume()
                sourceSuspended = false
            }
            return true
        }
        guard shouldReap else { return }
        kill(child, SIGHUP)
        DispatchQueue.global().async { [child] in
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0, errno == EINTR {}
        }
    }

    private func readOneChunk() {
        // Claim the in-flight gate in the same critical section that suspends
        // the source, so a concurrent `resumeReading()` cannot let a second
        // read start before this chunk has been delivered.
        let shouldRead = lock.withLock { () -> Bool in
            guard !closed, !sourceSuspended else { return false }
            sourceSuspended = true
            source.suspend()
            guard !chunkInFlight else { return false }
            chunkInFlight = true
            return true
        }
        guard shouldRead else { return }
        var bytes = [UInt8](repeating: 0, count: DroneLimits.maxOutputChunkBytes)
        let count = Darwin.read(master, &bytes, bytes.count)
        if count > 0 {
            onOutput(self, Data(bytes.prefix(count)))
        } else if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
            completeOutputDelivery(resumeReading: true)
        } else {
            // End of output: the gate stays claimed so nothing resumes reading
            // and the exit can only follow every chunk already delivered.
            onExit()
        }
    }

    private func isClosed() -> Bool {
        lock.withLock { closed }
    }
}
#endif
