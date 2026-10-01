import Foundation

/// Identifies the processes that belong to this app bundle: the main
/// executable and anything launched from its `Contents/Frameworks` directory.
/// Matching is by executable path prefix, so a foreign command that merely
/// mentions a bundle path in its arguments is never attributed to the app.
struct ChromiumProcessScope: Equatable, Sendable {
    /// `--type` of the macOS signing worker that the base helper launches and
    /// keeps until the signed test host exits. It is not a CEF subprocess.
    static let codeSignCloneCleanupSwitch = "--type=code-sign-clone-cleanup"

    static let helperExecutables = [
        "Pilot Helper.app/Contents/MacOS/Pilot Helper",
        "Pilot Helper (Alerts).app/Contents/MacOS/Pilot Helper (Alerts)",
        "Pilot Helper (GPU).app/Contents/MacOS/Pilot Helper (GPU)",
        "Pilot Helper (Plugin).app/Contents/MacOS/Pilot Helper (Plugin)",
        "Pilot Helper (Renderer).app/Contents/MacOS/Pilot Helper (Renderer)",
    ]

    let executablePath: String?
    /// Absolute `Contents/Frameworks` path with a trailing slash.
    let frameworksPath: String

    init(executablePath: String?, frameworksPath: String) {
        self.executablePath = executablePath
        self.frameworksPath = frameworksPath.hasSuffix("/")
            ? frameworksPath
            : frameworksPath + "/"
    }

    static func current(bundle: Bundle = .main) -> ChromiumProcessScope {
        ChromiumProcessScope(
            executablePath: bundle.executableURL?.path,
            frameworksPath: bundle.bundleURL
                .appendingPathComponent("Contents/Frameworks", isDirectory: true)
                .path
        )
    }

    /// A CEF browser subprocess launched from one of the pinned helper apps,
    /// excluding the signing cleanup worker.
    func isBrowserHelper(_ command: Substring) -> Bool {
        Self.helperExecutables.contains {
            Self.command(command, launches: frameworksPath + $0)
        } && !command.contains(Self.codeSignCloneCleanupSwitch)
    }

    /// Any process launched from this bundle. Resource accounting includes the
    /// signing worker and CEF's framework-internal helpers because they are
    /// part of the app's footprint.
    func isAppProcess(_ command: Substring) -> Bool {
        if let executablePath, Self.command(command, launches: executablePath) {
            return true
        }
        return command.hasPrefix(frameworksPath)
    }

    private static func command(_ command: Substring, launches path: String) -> Bool {
        command == path[...] || command.hasPrefix(path + " ")
    }
}

struct ChromiumProcessSample: Equatable, Sendable {
    let processID: Int32
    let cpuSeconds: TimeInterval
    let residentKilobytes: UInt64
    let command: String
}

struct ChromiumHelperRoles: Equatable, Sendable {
    var renderer: Bool
    var gpu: Bool

    init(renderer: Bool = false, gpu: Bool = false) {
        self.renderer = renderer
        self.gpu = gpu
    }

    init(commands: [String]) {
        self.init()
        for command in commands {
            if command.contains("Pilot Helper (Renderer).app/")
                && command.contains("--type=renderer") {
                renderer = true
            }
            if (command.contains("Pilot Helper.app/")
                || command.contains("Pilot Helper (GPU).app/"))
                && command.contains("--type=gpu-process") {
                gpu = true
            }
        }
    }

    func union(_ other: ChromiumHelperRoles) -> ChromiumHelperRoles {
        ChromiumHelperRoles(
            renderer: renderer || other.renderer,
            gpu: gpu || other.gpu
        )
    }
}

/// One `ps` observation of the app's processes. The OS records each process's
/// CPU time at some instant between `startedAt` and `finishedAt`.
struct ChromiumProcessSnapshot: Equatable, Sendable {
    let appProcesses: [Int32: ChromiumProcessSample]
    let helperCommands: [String]
    let rowCount: Int
    let malformedRowCount: Int
    let startedAt: ContinuousClock.Instant
    let finishedAt: ContinuousClock.Instant

    var helperRoles: ChromiumHelperRoles {
        ChromiumHelperRoles(commands: helperCommands)
    }

    /// Best estimate of when `ps` read CPU counters; the error is at most half
    /// of the subprocess's own run time.
    var midpoint: ContinuousClock.Instant {
        startedAt.advanced(by: startedAt.duration(to: finishedAt) / 2)
    }
}

/// Pure parsing of `ps -axo pid=,time=,rss=,command=` output. The text comes
/// from a subprocess, so every numeric field is validated and rows that do not
/// parse are counted and ignored rather than trusted.
enum ChromiumProcessTable {
    static let arguments = ["-axo", "pid=,time=,rss=,command="]

    static func parse(
        _ output: String,
        scope: ChromiumProcessScope,
        startedAt: ContinuousClock.Instant,
        finishedAt: ContinuousClock.Instant
    ) -> ChromiumProcessSnapshot {
        var appProcesses: [Int32: ChromiumProcessSample] = [:]
        var helperCommands: [String] = []
        var rowCount = 0
        var malformedRowCount = 0
        for row in output.split(whereSeparator: \.isNewline) {
            guard row.contains(where: { !$0.isWhitespace }) else { continue }
            rowCount += 1
            let fields = row.split(
                maxSplits: 3,
                omittingEmptySubsequences: true,
                whereSeparator: \.isWhitespace
            )
            guard fields.count == 4,
                  let processID = Int32(fields[0]), processID > 0,
                  let cpuSeconds = cpuSeconds(fields[1]),
                  let residentKilobytes = UInt64(fields[2])
            else {
                malformedRowCount += 1
                continue
            }
            let command = fields[3].drop(while: \.isWhitespace)
            guard scope.isAppProcess(command) else { continue }
            appProcesses[processID] = ChromiumProcessSample(
                processID: processID,
                cpuSeconds: cpuSeconds,
                residentKilobytes: residentKilobytes,
                command: String(command)
            )
            if scope.isBrowserHelper(command) {
                helperCommands.append(String(command))
            }
        }
        return ChromiumProcessSnapshot(
            appProcesses: appProcesses,
            helperCommands: helperCommands,
            rowCount: rowCount,
            malformedRowCount: malformedRowCount,
            startedAt: startedAt,
            finishedAt: finishedAt
        )
    }

    /// Parses `ps` accumulated CPU time: `[[dd-]hh:]mm:ss[.ff]`, where the
    /// leading clock component may exceed its nominal range.
    static func cpuSeconds(_ value: Substring) -> TimeInterval? {
        let dayAndClock = value.split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let days: Double
        let clock: Substring
        if dayAndClock.count == 2 {
            guard let parsedDays = unsignedDecimal(dayAndClock[0], allowsFraction: false) else {
                return nil
            }
            days = parsedDays
            clock = dayAndClock[1]
        } else {
            days = 0
            clock = dayAndClock[0]
        }
        let parts = clock.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var seconds = 0.0
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            guard let parsed = unsignedDecimal(part, allowsFraction: isLast) else {
                return nil
            }
            seconds = seconds * 60 + parsed
        }
        return days * 86_400 + seconds
    }

    /// Accepts only ASCII digits with an optional single fractional part, so
    /// `Double`'s acceptance of `inf`, `nan`, exponents, and signs never applies.
    private static func unsignedDecimal(
        _ value: Substring,
        allowsFraction: Bool
    ) -> Double? {
        guard !value.isEmpty, value.utf8.count <= 32 else { return nil }
        var sawDigit = false
        var sawPoint = false
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                sawDigit = true
            case UInt8(ascii: ".") where allowsFraction && !sawPoint:
                sawPoint = true
            default:
                return nil
            }
        }
        return sawDigit ? Double(value) : nil
    }
}

struct ChromiumIdleResourceMeasurement: Equatable, Sendable {
    let cpuPercent: Double
    let residentMemoryBytes: UInt64
    /// Midpoint-to-midpoint interval between the two `ps` observations.
    let window: Duration
    let comparedProcessCount: Int
}

enum ChromiumIdleResourceError: LocalizedError, Equatable {
    case noProcesses
    case processSetChanged
    case invalidWindow

    var errorDescription: String? {
        switch self {
        case .noProcesses:
            "No Cockpit Chromium processes were available to sample."
        case .processSetChanged:
            "The Cockpit Chromium process set changed during idle sampling."
        case .invalidWindow:
            "The Chromium idle sampling interval was not positive."
        }
    }
}

enum ChromiumIdleResources {
    /// CPU is the summed per-process CPU delta over the interval between the
    /// two observations' midpoints, so time spent launching and reading `ps`
    /// is neither added to nor hidden from the denominator. Only processes
    /// present in both observations with an unchanged command line are
    /// compared: helpers that exit, or PIDs reused by another process, are
    /// excluded rather than counted as negative or foreign work. Resident
    /// memory is the app's footprint at the later observation.
    static func measure(
        before: ChromiumProcessSnapshot,
        after: ChromiumProcessSnapshot
    ) throws -> ChromiumIdleResourceMeasurement {
        guard !before.appProcesses.isEmpty, !after.appProcesses.isEmpty else {
            throw ChromiumIdleResourceError.noProcesses
        }
        let window = before.midpoint.duration(to: after.midpoint)
        guard window > .zero else {
            throw ChromiumIdleResourceError.invalidWindow
        }
        var cpuSeconds = 0.0
        var compared = 0
        for (processID, earlier) in before.appProcesses {
            guard let later = after.appProcesses[processID],
                  later.command == earlier.command else {
                continue
            }
            compared += 1
            cpuSeconds += max(0, later.cpuSeconds - earlier.cpuSeconds)
        }
        guard compared > 0 else {
            throw ChromiumIdleResourceError.processSetChanged
        }
        var residentKilobytes: UInt64 = 0
        for sample in after.appProcesses.values {
            let (sum, overflow) = residentKilobytes
                .addingReportingOverflow(sample.residentKilobytes)
            residentKilobytes = overflow ? .max : sum
        }
        let (bytes, overflow) = residentKilobytes.multipliedReportingOverflow(by: 1_024)
        let components = window.components
        let windowSeconds = Double(components.seconds)
            + Double(components.attoseconds) / 1e18
        return ChromiumIdleResourceMeasurement(
            cpuPercent: cpuSeconds / windowSeconds * 100,
            residentMemoryBytes: overflow ? .max : bytes,
            window: window,
            comparedProcessCount: compared
        )
    }
}

enum ChromiumProcessObservationError: LocalizedError, Equatable {
    case launchFailed(String)
    case timedOut(Duration)
    case exited(ProcessRunResult.Termination)
    case outputExceeded(limit: Int)
    case unreadableOutput(rows: Int)

    var errorDescription: String? {
        switch self {
        case let .launchFailed(message):
            "Cockpit could not run /bin/ps: \(message)"
        case let .timedOut(limit):
            "/bin/ps did not finish within \(limit)."
        case let .exited(.exit(code)):
            "/bin/ps exited with status \(code)."
        case let .exited(.signal(signal)):
            "/bin/ps was terminated by signal \(signal)."
        case let .outputExceeded(limit):
            "/bin/ps produced more than \(limit) bytes of output."
        case let .unreadableOutput(rows):
            "/bin/ps produced \(rows) rows and none had the expected format."
        }
    }
}

/// Observes the app's processes through the bounded `ProcessRunner`: the
/// subprocess never blocks the caller's actor, has an explicit deadline and
/// output limit, and is terminated when the observing task is cancelled.
struct ChromiumProcessObserver: Sendable {
    typealias Runner = @Sendable (ProcessInvocation) async throws -> ProcessRunResult

    let scope: ChromiumProcessScope
    let timeout: Duration
    let standardOutputLimit: Int
    private let runner: Runner

    init(
        scope: ChromiumProcessScope,
        timeout: Duration = .seconds(5),
        standardOutputLimit: Int = 8 * 1_024 * 1_024,
        runner: @escaping Runner = { try await ProcessRunner.run($0) }
    ) {
        self.scope = scope
        self.timeout = timeout
        self.standardOutputLimit = standardOutputLimit
        self.runner = runner
    }

    var invocation: ProcessInvocation {
        ProcessInvocation(
            executableURL: URL(fileURLWithPath: "/bin/ps"),
            arguments: ChromiumProcessTable.arguments,
            environment: ["LC_ALL": "C"],
            timeout: timeout,
            terminationGracePeriod: .milliseconds(250),
            standardOutputLimit: standardOutputLimit,
            standardErrorLimit: 64 * 1_024,
            // Probe durations include this command's latency; a utility-class
            // ps measurably lags on a loaded machine.
            qualityOfService: .userInitiated
        )
    }

    func snapshot() async throws -> ChromiumProcessSnapshot {
        try Task.checkCancellation()
        let startedAt = ContinuousClock.now
        let result: ProcessRunResult
        do {
            result = try await runner(invocation)
        } catch let error as ProcessRunnerError {
            throw observationError(for: error)
        }
        let finishedAt = ContinuousClock.now
        let snapshot = ChromiumProcessTable.parse(
            result.standardOutputString,
            scope: scope,
            startedAt: startedAt,
            finishedAt: finishedAt
        )
        guard snapshot.rowCount > snapshot.malformedRowCount else {
            throw ChromiumProcessObservationError.unreadableOutput(
                rows: snapshot.rowCount
            )
        }
        return snapshot
    }

    private func observationError(for error: ProcessRunnerError) -> any Error {
        switch error {
        case let .launch(_, message):
            ChromiumProcessObservationError.launchFailed(message)
        case .timedOut:
            ChromiumProcessObservationError.timedOut(timeout)
        case .cancelled:
            CancellationError()
        case let .nonZeroExit(result):
            ChromiumProcessObservationError.exited(result.termination)
        case .outputTruncated:
            ChromiumProcessObservationError.outputExceeded(limit: standardOutputLimit)
        }
    }
}
