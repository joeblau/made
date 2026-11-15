import Foundation
import OSLog
import Observation

/// Restarts macOS's `iOSScreenCaptureAssistant`, the root daemon that
/// publishes a USB iPhone or iPad as a capture device. When it wedges, the
/// device stops appearing (or its feed keeps dropping) and no amount of
/// in-process re-attaching helps; killing it makes launchd start a fresh one
/// on the next capture request.
///
/// The daemon runs as root, so the kill goes through the system
/// administrator prompt. Only ever started by an explicit click: a password
/// dialog that appears on its own teaches people to type passwords into
/// dialogs they did not ask for.
@MainActor
@Observable
final class IOSCaptureServiceRestarter {
    enum Outcome: Equatable, Sendable {
        case restarted
        /// The user dismissed the password prompt.
        case cancelled
        case failed(String)
    }

    /// How much of the USB device stack a restart takes down.
    enum Scope: Equatable, Sendable {
        /// Only the screen capture daemon. Tried first: nothing else notices.
        case captureService
        /// The backup when that was not enough: `usbmuxd` as well. This drops
        /// every USB device connection on the Mac (Xcode, Finder sync) until
        /// launchd restarts it, so it is only offered after the first failed.
        case usbAndCaptureServices

        var processNames: [String] {
            switch self {
            case .captureService: ["iOSScreenCaptureAssistant"]
            case .usbAndCaptureServices: ["usbmuxd", "iOSScreenCaptureAssistant"]
            }
        }

        var actionTitle: String {
            switch self {
            case .captureService: "Restart Capture Service…"
            case .usbAndCaptureServices: "Restart USB & Capture Services…"
            }
        }

        var prompt: String {
            switch self {
            case .captureService: "Cockpit wants to restart the iPhone screen capture service."
            case .usbAndCaptureServices: "Cockpit wants to restart the USB device and iPhone screen capture services."
            }
        }
    }

    static let shared = IOSCaptureServiceRestarter()

    /// What the next restart will do. Escalates once a capture-only restart
    /// has run without a device streaming since.
    private(set) var nextScope: Scope = .captureService

    /// One prompt at a time across every device pane.
    private(set) var isRestarting = false

    @ObservationIgnored private let run: @Sendable (ProcessInvocation) async throws -> ProcessRunResult
    @ObservationIgnored private let logger = Logger(subsystem: "app.blau.pilot.device", category: "capture-service")

    init(run: @escaping @Sendable (ProcessInvocation) async throws -> ProcessRunResult = ProcessRunner.run) {
        self.run = run
    }

    /// Nil when a restart is already in flight (its prompt is on screen).
    func restart() async -> Outcome? {
        let scope = nextScope
        guard !isRestarting else { return nil }
        isRestarting = true
        defer { isRestarting = false }
        let outcome: Outcome
        do {
            _ = try await run(Self.invocation(for: scope))
            outcome = .restarted
            nextScope = .usbAndCaptureServices
        } catch {
            outcome = Self.outcome(for: error)
        }
        switch outcome {
        case .restarted: logger.notice("restarted \(scope.processNames.joined(separator: ", "), privacy: .public)")
        case .cancelled: logger.notice("capture service restart cancelled at the password prompt")
        case .failed(let message): logger.error("capture service restart failed: \(message)")
        }
        return outcome
    }

    /// A device is streaming again, so the next problem starts over with the
    /// gentle restart.
    func captureDidRecover() {
        if nextScope != .captureService { nextScope = .captureService }
    }

    /// Built only from the constants above: nothing from a device, pane, or
    /// user reaches the privileged shell. `killall` exits 1 when a daemon is
    /// not running, which is as good as restarted, so that status is swallowed.
    static func script(for scope: Scope) -> String {
        """
        do shell script "/usr/bin/killall -q \(scope.processNames.joined(separator: " ")) || true" \
        with prompt "\(scope.prompt)" \
        with administrator privileges
        """
    }

    static func invocation(for scope: Scope) -> ProcessInvocation {
        ProcessInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", script(for: scope)],
            // The password prompt waits on a person, not on a subprocess.
            timeout: .seconds(300),
            standardOutputLimit: 16 * 1_024,
            standardErrorLimit: 16 * 1_024,
            qualityOfService: .userInitiated
        )
    }

    static func outcome(for error: Error) -> Outcome {
        guard let runnerError = error as? ProcessRunnerError else {
            return .failed("Couldn't restart the capture service: \(error.localizedDescription)")
        }
        switch runnerError {
        case .timedOut:
            return .failed("The password prompt timed out before anything was restarted.")
        case .cancelled:
            return .cancelled
        case .nonZeroExit(let result):
            // AppleScript reports a dismissed prompt as error -128.
            if result.standardErrorString.contains("(-128)") { return .cancelled }
            return .failed("Couldn't restart the capture service. An administrator password is required.")
        case .launch, .outputTruncated:
            return .failed("Couldn't restart the capture service.")
        }
    }
}

extension DeviceCaptureSession {
    /// The capture daemon was just restarted: re-allow screen-capture devices
    /// for the fresh daemon and look for the phone again. Discovery keeps
    /// polling until the daemon republishes it.
    func captureServiceDidRestart() {
        Self.enableScreenCaptureDevices()
        retry()
    }
}
