import Darwin
import Foundation
import OSLog

/// A single validated line for the device's `input` tool. Construction is the
/// security boundary: coordinates and durations are clamped Ints formatted by
/// Swift, keyevent codes come from a compile-time table, and text passes a
/// strict allowlist — nothing user- or device-derived is ever spliced into the
/// shell line unescaped.
struct AndroidInputCommand: Sendable, Equatable {
    let line: String

    private static func clampCoordinate(_ value: Int) -> Int { min(max(value, 0), 32_767) }
    private static func clampDuration(_ milliseconds: Int) -> Int { min(max(milliseconds, 16), 5_000) }

    static func tap(x: Int, y: Int) -> AndroidInputCommand {
        AndroidInputCommand(line: "input tap \(clampCoordinate(x)) \(clampCoordinate(y))")
    }

    static func swipe(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int) -> AndroidInputCommand {
        AndroidInputCommand(line: "input swipe \(clampCoordinate(fromX)) \(clampCoordinate(fromY)) "
            + "\(clampCoordinate(toX)) \(clampCoordinate(toY)) \(clampDuration(durationMS))")
    }

    /// A long-press is a zero-motion swipe held for the press duration.
    static func longPress(x: Int, y: Int, durationMS: Int) -> AndroidInputCommand {
        swipe(fromX: x, fromY: y, toX: x, toY: y, durationMS: durationMS)
    }

    /// True drag semantics (press, grab, move, release) — what app-icon drags
    /// and reorder gestures need, which a plain swipe cannot express.
    static func dragAndDrop(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int) -> AndroidInputCommand {
        AndroidInputCommand(line: "input draganddrop \(clampCoordinate(fromX)) \(clampCoordinate(fromY)) "
            + "\(clampCoordinate(toX)) \(clampCoordinate(toY)) \(clampDuration(durationMS))")
    }

    static func keyevent(_ code: Int) -> AndroidInputCommand {
        AndroidInputCommand(line: "input keyevent \(min(max(code, 0), 999))")
    }

    /// Escaped text entry, or nil when nothing typeable survives the
    /// allowlist. `dropped` counts characters the allowlist rejected so the
    /// UI can surface a one-time "some characters can't be typed" notice.
    static func text(_ raw: String) -> (command: AndroidInputCommand?, dropped: Int) {
        let (escaped, dropped) = escapeText(raw)
        guard !escaped.isEmpty else { return (nil, dropped) }
        return (AndroidInputCommand(line: "input text '\(escaped)'"), dropped)
    }

    /// Allowlist-first escaping for `input text`. The permitted set excludes
    /// quote, backslash, `%`, `$`, backtick, and all control/non-ASCII
    /// characters — excluded, not escaped, so the single-quoted shell word can
    /// never be broken out of. Space becomes `%s` (the `input` tool's own
    /// convention). Non-ASCII is dropped because `input text` only accepts
    /// what the on-device keymap can synthesize; injecting arbitrary Unicode
    /// needs a device-side IME install, which Pilot refuses by policy.
    static func escapeText(_ raw: String) -> (escaped: String, dropped: Int) {
        var escaped = ""
        var dropped = 0
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.,:;!?@#&*()-_+=/<>[]{}~^|")
        for character in raw.prefix(256) {
            if character == " " {
                escaped += "%s"
            } else if allowed.contains(character) {
                escaped.append(character)
            } else {
                dropped += 1
            }
        }
        dropped += max(0, raw.count - 256)
        return (escaped, dropped)
    }
}

/// Persistent `adb shell` command channel: all device input flows through
/// here. One interactive shell per session amortizes the ~100 ms per-adb-spawn
/// cost down to the on-device `input` exec. The shell is lazily (re)spawned on
/// first use and after death; its stdout/stderr are drained and discarded —
/// Pilot never parses anything the shell says back.
actor AndroidInputInjector {
    private let adbURL: URL
    private let serial: String
    private let logger = Logger(subsystem: "app.blau.pilot.android", category: "input")
    /// Blocking stdin writes happen here, never on the actor's cooperative
    /// executor: a device that stops reading (wireless-adb black hole) blocks
    /// the write, and only a GCD thread may absorb that. The actor suspends on
    /// a continuation meanwhile, so `shutdown()` stays free to preempt — its
    /// SIGTERM makes the blocked write fail with EPIPE and everything unwinds.
    /// The stdin descriptor is also closed on this queue, so a close can never
    /// race an in-flight write on the same (possibly reused) descriptor.
    private let writeQueue = DispatchQueue(label: "app.blau.pilot.android.input-write", qos: .userInitiated)

    private var process: Process?
    private var stdin: FileHandle?
    private var drainHandles: [FileHandle] = []
    private var pending: [AndroidInputCommand] = []
    private var writerRunning = false
    private var shutDown = false
    /// Writes that failed with a catchable error (EPIPE from a dead shell).
    /// Diagnostic only; the tests use it to prove a dead shell surfaces as an
    /// error rather than a process-killing SIGPIPE.
    private(set) var failedWriteCount = 0

    /// Input is transient: when the device stalls, drop the newest commands
    /// rather than queueing unboundedly.
    private static let queueCap = 64

    init(adbURL: URL, serial: String) {
        self.adbURL = adbURL
        self.serial = serial
    }

    func send(_ command: AndroidInputCommand) {
        guard !shutDown else { return }
        guard pending.count < Self.queueCap else { return }
        pending.append(command)
        drainIfNeeded()
    }

    func shutdown() {
        shutDown = true
        pending.removeAll()
        terminateShell()
    }

    // MARK: - Shell lifecycle

    private func ensureShell() -> FileHandle? {
        if let stdin, let process, process.isRunning { return stdin }
        terminateShell()

        let child = AdbBridge.makeInteractiveShellProcess(adbURL: adbURL, serial: serial)
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        child.standardInput = input
        child.standardOutput = output
        child.standardError = errors
        // Invariant (#445): a write to a shell that already exited must fail
        // with a catchable EPIPE, never raise SIGPIPE — whose default action
        // terminates Cockpit with every open pane and agent. `isRunning` can't
        // guard this: adb may exit between the check and the write. Refuse to
        // launch rather than hand out a descriptor that could kill the app.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            let failure = errno
            logger.error("input shell launch refused: F_SETNOSIGPIPE failed (errno \(failure, privacy: .public))")
            return nil
        }
        // Drain-and-discard both output streams so the pipes can never fill
        // and backpressure the shell. The handler must detach itself at EOF —
        // a readability source is level-triggered and would otherwise spin at
        // 100% CPU (and leak the pipe) after the shell dies.
        let discardingDrain: @Sendable (FileHandle) -> Void = { handle in
            if handle.availableData.isEmpty {
                handle.readabilityHandler = nil
            }
        }
        output.fileHandleForReading.readabilityHandler = discardingDrain
        errors.fileHandleForReading.readabilityHandler = discardingDrain
        do {
            try child.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            logger.error("input shell launch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        process = child
        stdin = input.fileHandleForWriting
        drainHandles = [output.fileHandleForReading, errors.fileHandleForReading]
        return stdin
    }

    private func terminateShell() {
        if let stdin {
            // Close on the write queue, behind any in-flight write: closing
            // here on the actor could free the descriptor while a blocked
            // write still targets it. The SIGTERM below unblocks that write.
            writeQueue.async {
                try? stdin.close()
            }
        }
        stdin = nil
        for handle in drainHandles {
            handle.readabilityHandler = nil
        }
        drainHandles = []
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
    }

    private func drainIfNeeded() {
        guard !writerRunning else { return }
        writerRunning = true
        Task { await drain() }
    }

    private func drain() async {
        defer { writerRunning = false }
        while !pending.isEmpty, !shutDown {
            let command = pending.removeFirst()
            guard let handle = ensureShell() else {
                pending.removeAll()
                return
            }
            let payload = Data((command.line + "\n").utf8)
            do {
                try await write(payload, to: handle)
            } catch {
                // Broken pipe: the shell died (device unplugged, adb server
                // restarted, shutdown() preempted a blocked write). Drop the
                // command; the next send respawns.
                failedWriteCount += 1
                logger.warning("input shell write failed: \(error.localizedDescription, privacy: .public)")
                if !shutDown { terminateShell() }
                return
            }
        }
    }

    private func write(_ payload: Data, to handle: FileHandle) async throws {
        let queue = writeQueue
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try handle.write(contentsOf: payload)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
