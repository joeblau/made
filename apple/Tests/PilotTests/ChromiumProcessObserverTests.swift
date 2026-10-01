import Foundation
import Testing
@testable import Pilot

@Suite("Chromium process observation")
struct ChromiumProcessObserverTests {
    private static let bundle = "/Applications/Cockpit.app"
    private static let scope = ChromiumProcessScope(
        executablePath: "\(bundle)/Contents/MacOS/Cockpit",
        frameworksPath: "\(bundle)/Contents/Frameworks"
    )
    private static let frameworks = "\(bundle)/Contents/Frameworks/"
    private static let renderer = frameworks
        + "Pilot Helper (Renderer).app/Contents/MacOS/Pilot Helper (Renderer)"
        + " --type=renderer --lang=en-US"
    private static let gpu = frameworks
        + "Pilot Helper (GPU).app/Contents/MacOS/Pilot Helper (GPU)"
        + " --type=gpu-process"
    private static let baseGPU = frameworks
        + "Pilot Helper.app/Contents/MacOS/Pilot Helper --type=gpu-process"
    private static let signingCleanup = frameworks
        + "Pilot Helper.app/Contents/MacOS/Pilot Helper"
        + " --type=code-sign-clone-cleanup"
    private static let crashpad = frameworks
        + "Chromium Embedded Framework.framework/Versions/A/Helpers/"
        + "chrome_crashpad_handler --database=/tmp"

    private static func parse(_ output: String) -> ChromiumProcessSnapshot {
        let now = ContinuousClock.now
        return ChromiumProcessTable.parse(
            output,
            scope: scope,
            startedAt: now,
            finishedAt: now
        )
    }

    private static func result(
        _ output: String = "",
        termination: ProcessRunResult.Termination = .exit(0),
        standardOutputTruncated: Bool = false,
        standardErrorTruncated: Bool = false
    ) -> ProcessRunResult {
        ProcessRunResult(
            termination: termination,
            standardOutput: Data(output.utf8),
            standardError: Data(),
            standardOutputTruncated: standardOutputTruncated,
            standardErrorTruncated: standardErrorTruncated,
            elapsed: .milliseconds(5),
            redactedCommand: "/bin/ps"
        )
    }

    // MARK: - Matching

    @Test("Only this app's executable and bundled helpers are attributed to it")
    func scopesProcessesToThisApp() {
        let snapshot = Self.parse("""
              1   0:01.00   1000 /sbin/launchd
            100   0:02.50  20000 \(Self.bundle)/Contents/MacOS/Cockpit -NSDocumentRevisionsDebugMode YES
            101   0:00.25  30000 \(Self.renderer)
            102   1:00.00  40000 \(Self.gpu)
            103   0:00.01    500 \(Self.signingCleanup)
            104   0:00.02    600 \(Self.crashpad)
            200   0:09.00   9000 /usr/bin/codesign --verify \(Self.frameworks)Pilot Helper.app
            201   0:09.00   9000 \(Self.bundle)/Contents/MacOS/CockpitExtra
            202   0:09.00   9000 /Applications/Other.app/Contents/Frameworks/Pilot Helper.app/Contents/MacOS/Pilot Helper --type=renderer
            """)

        #expect(Set(snapshot.appProcesses.keys) == [100, 101, 102, 103, 104])
        #expect(snapshot.helperCommands == [Self.renderer, Self.gpu])
        #expect(snapshot.rowCount == 9)
        #expect(snapshot.malformedRowCount == 0)
        #expect(snapshot.appProcesses[102]?.cpuSeconds == 60)
        #expect(snapshot.appProcesses[101]?.residentKilobytes == 30_000)
    }

    @Test("The signing cleanup worker is not a browser helper")
    func excludesSigningCleanupHelper() {
        let snapshot = Self.parse("""
            103   0:00.01    500 \(Self.signingCleanup)
            """)
        #expect(snapshot.helperCommands.isEmpty)
        #expect(snapshot.appProcesses[103] != nil)
    }

    @Test("Helper roles require both the helper bundle and the process type")
    func detectsHelperRoles() {
        #expect(ChromiumHelperRoles(commands: [Self.renderer, Self.gpu])
            == ChromiumHelperRoles(renderer: true, gpu: true))
        #expect(ChromiumHelperRoles(commands: [Self.baseGPU]).gpu)
        #expect(ChromiumHelperRoles(commands: [Self.renderer]).gpu == false)
        let mislabeled = Self.frameworks
            + "Pilot Helper (GPU).app/Contents/MacOS/Pilot Helper (GPU) --type=renderer"
        #expect(ChromiumHelperRoles(commands: [mislabeled])
            == ChromiumHelperRoles())
        #expect(ChromiumHelperRoles(renderer: true)
            .union(ChromiumHelperRoles(gpu: true))
            == ChromiumHelperRoles(renderer: true, gpu: true))
    }

    // MARK: - Untrusted rows

    @Test("Malformed rows are counted and never attributed")
    func countsMalformedRows() {
        let snapshot = Self.parse("""
            abc   0:01.00   1000 \(Self.renderer)
              0   0:01.00   1000 \(Self.renderer)
             -5   0:01.00   1000 \(Self.renderer)
            101   inf       1000 \(Self.renderer)
            102   0:01.00   -1 \(Self.renderer)
            103   0:01.00
            99999999999 0:01.00 1000 \(Self.renderer)

            104   0:00.50   2000 \(Self.renderer)
            """)
        #expect(snapshot.rowCount == 8)
        #expect(snapshot.malformedRowCount == 7)
        #expect(Array(snapshot.appProcesses.keys) == [104])
    }

    @Test(
        "CPU time accepts only ps clock formats",
        arguments: [
            ("0:00.12", 0.12),
            ("12:34.56", 754.56),
            ("61:05.00", 3_665.0),
            ("1:02:03.50", 3_723.5),
            ("2-03:04:05", 183_845.0),
            ("7", 7.0),
        ]
    )
    func parsesCPUTime(value: String, seconds: Double) throws {
        let parsed = try #require(ChromiumProcessTable.cpuSeconds(value[...]))
        #expect(abs(parsed - seconds) < 0.000_1)
    }

    @Test(
        "CPU time rejects non-clock values",
        arguments: [
            "", "inf", "nan", "1e3", "-1:00", "1:-2", "1::2", ":30",
            "1:2:3:4", "1.5:00", "1-", "-", "0x10", "1:00.5.5", "1 :00",
        ]
    )
    func rejectsInvalidCPUTime(value: String) {
        #expect(ChromiumProcessTable.cpuSeconds(value[...]) == nil)
    }

    // MARK: - Idle measurement

    private static func snapshot(
        _ samples: [ChromiumProcessSample],
        startedAt: ContinuousClock.Instant,
        finishedAt: ContinuousClock.Instant
    ) -> ChromiumProcessSnapshot {
        ChromiumProcessSnapshot(
            appProcesses: Dictionary(
                uniqueKeysWithValues: samples.map { ($0.processID, $0) }
            ),
            helperCommands: [],
            rowCount: samples.count,
            malformedRowCount: 0,
            startedAt: startedAt,
            finishedAt: finishedAt
        )
    }

    private static func sample(
        _ processID: Int32,
        cpu: Double,
        rss: UInt64,
        command: String = renderer
    ) -> ChromiumProcessSample {
        ChromiumProcessSample(
            processID: processID,
            cpuSeconds: cpu,
            residentKilobytes: rss,
            command: command
        )
    }

    @Test("Idle CPU uses the midpoint interval between observations")
    func measuresOverMidpointWindow() throws {
        let origin = ContinuousClock.now
        // A 200 ms first observation, 1 s of idle sleep, and a 400 ms second
        // observation: midpoints are 0.1 s and 1.4 s, a 1.3 s window. The
        // sleep alone (1 s) would overstate CPU; the outer bounds (1.6 s)
        // would understate it.
        let before = Self.snapshot(
            [Self.sample(1, cpu: 10, rss: 100), Self.sample(2, cpu: 5, rss: 50, command: Self.gpu)],
            startedAt: origin,
            finishedAt: origin.advanced(by: .milliseconds(200))
        )
        let after = Self.snapshot(
            [Self.sample(1, cpu: 10.26, rss: 300), Self.sample(2, cpu: 5.13, rss: 60, command: Self.gpu)],
            startedAt: origin.advanced(by: .milliseconds(1_200)),
            finishedAt: origin.advanced(by: .milliseconds(1_600))
        )
        let measurement = try ChromiumIdleResources.measure(
            before: before,
            after: after
        )
        #expect(measurement.window == .milliseconds(1_300))
        #expect(abs(measurement.cpuPercent - 30) < 0.000_1)
        #expect(measurement.residentMemoryBytes == 360 * 1_024)
        #expect(measurement.comparedProcessCount == 2)
    }

    @Test("Exited helpers, reused PIDs, and clock regressions are not counted")
    func excludesDisappearingAndReusedProcesses() throws {
        let origin = ContinuousClock.now
        let before = Self.snapshot(
            [
                Self.sample(1, cpu: 10, rss: 100),
                Self.sample(2, cpu: 5, rss: 50, command: Self.gpu),
                Self.sample(3, cpu: 1, rss: 10, command: Self.renderer),
                Self.sample(4, cpu: 9, rss: 10, command: Self.baseGPU),
            ],
            startedAt: origin,
            finishedAt: origin
        )
        let after = Self.snapshot(
            [
                Self.sample(1, cpu: 10.5, rss: 100),
                // PID 3 now belongs to a different helper: not comparable.
                Self.sample(3, cpu: 4, rss: 20, command: Self.gpu),
                // Counter regressed (should not happen): clamped to zero.
                Self.sample(4, cpu: 8, rss: 30, command: Self.baseGPU),
            ],
            startedAt: origin.advanced(by: .seconds(1)),
            finishedAt: origin.advanced(by: .seconds(1))
        )
        let measurement = try ChromiumIdleResources.measure(
            before: before,
            after: after
        )
        #expect(measurement.comparedProcessCount == 2)
        #expect(abs(measurement.cpuPercent - 50) < 0.000_1)
        #expect(measurement.residentMemoryBytes == 150 * 1_024)
    }

    @Test("Empty, replaced, or zero-length samples fail with a reason")
    func rejectsUnmeasurableSamples() {
        let origin = ContinuousClock.now
        let empty = Self.snapshot([], startedAt: origin, finishedAt: origin)
        let one = Self.snapshot(
            [Self.sample(1, cpu: 1, rss: 1)],
            startedAt: origin,
            finishedAt: origin
        )
        let replaced = Self.snapshot(
            [Self.sample(2, cpu: 1, rss: 1)],
            startedAt: origin.advanced(by: .seconds(1)),
            finishedAt: origin.advanced(by: .seconds(1))
        )
        #expect(throws: ChromiumIdleResourceError.noProcesses) {
            try ChromiumIdleResources.measure(before: empty, after: one)
        }
        #expect(throws: ChromiumIdleResourceError.processSetChanged) {
            try ChromiumIdleResources.measure(before: one, after: replaced)
        }
        #expect(throws: ChromiumIdleResourceError.invalidWindow) {
            try ChromiumIdleResources.measure(before: one, after: one)
        }
    }

    // MARK: - Subprocess outcomes

    @Test("The observer runs a bounded ps invocation without a shell")
    func buildsBoundedInvocation() async throws {
        let recorded = RecordedInvocation()
        let observer = ChromiumProcessObserver(
            scope: Self.scope,
            timeout: .seconds(3),
            standardOutputLimit: 1_024
        ) { invocation in
            recorded.set(invocation)
            return Self.result("101 0:00.25 30000 \(Self.renderer)\n")
        }
        let snapshot = try await observer.snapshot()
        let invocation = try #require(recorded.value)
        #expect(invocation.executableURL.path == "/bin/ps")
        #expect(invocation.arguments == ["-axo", "pid=,time=,rss=,command="])
        #expect(invocation.environment == ["LC_ALL": "C"])
        #expect(invocation.timeout == .seconds(3))
        #expect(invocation.standardOutputLimit == 1_024)
        #expect(invocation.qualityOfService == .userInitiated)
        #expect(invocation.standardErrorLimit == ChromiumProcessObserver.standardErrorLimit)
        #expect(snapshot.helperCommands == [Self.renderer])
        #expect(snapshot.startedAt <= snapshot.finishedAt)
    }

    @Test("Runner failures map to bounded observation errors")
    func mapsRunnerFailures() async {
        func observer(
            _ failure: ProcessRunnerError
        ) -> ChromiumProcessObserver {
            ChromiumProcessObserver(
                scope: Self.scope,
                timeout: .seconds(2),
                standardOutputLimit: 4_096
            ) { _ in throw failure }
        }
        await #expect(throws: ChromiumProcessObservationError.timedOut(.seconds(2))) {
            try await observer(.timedOut(Self.result())).snapshot()
        }
        await #expect(throws: ChromiumProcessObservationError.exited(.exit(1))) {
            try await observer(.nonZeroExit(Self.result(termination: .exit(1)))).snapshot()
        }
        await #expect(throws: ChromiumProcessObservationError.exited(.signal(9))) {
            try await observer(.nonZeroExit(Self.result(termination: .signal(9)))).snapshot()
        }
        await #expect(throws: ChromiumProcessObservationError.outputExceeded(limit: 4_096)) {
            try await observer(.outputTruncated(Self.result(standardOutputTruncated: true))).snapshot()
        }
        await #expect(throws: ChromiumProcessObservationError.outputExceeded(limit: 4_096)) {
            try await observer(.outputTruncated(Self.result(
                standardOutputTruncated: true,
                standardErrorTruncated: true
            ))).snapshot()
        }
        await #expect(throws: ChromiumProcessObservationError.errorOutputExceeded(
            limit: ChromiumProcessObserver.standardErrorLimit
        )) {
            try await observer(.outputTruncated(Self.result(standardErrorTruncated: true))).snapshot()
        }
        await #expect(throws: ChromiumProcessObservationError.launchFailed("denied")) {
            try await observer(.launch(command: "/bin/ps", message: "denied")).snapshot()
        }
        await #expect(throws: CancellationError.self) {
            try await observer(.cancelled(Self.result())).snapshot()
        }
    }

    @Test("Output with no parseable rows is rejected", arguments: ["", "\n\n", "garbage\nmore garbage\n"])
    func rejectsUnreadableOutput(output: String) async {
        let observer = ChromiumProcessObserver(scope: Self.scope) { _ in
            Self.result(output)
        }
        await #expect(throws: ChromiumProcessObservationError.self) {
            try await observer.snapshot()
        }
    }

    @Test("A cancelled task never launches ps")
    func cancelledTaskDoesNotLaunch() async {
        let recorded = RecordedInvocation()
        let observer = ChromiumProcessObserver(scope: Self.scope) { invocation in
            recorded.set(invocation)
            return Self.result()
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await observer.snapshot()
        }
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(recorded.value == nil)
    }

    @Test("The real process table includes the test host")
    func observesTheRealHostProcess() async throws {
        let observer = ChromiumProcessObserver(scope: .current())
        let snapshot = try await observer.snapshot()
        let hostID = ProcessInfo.processInfo.processIdentifier
        #expect(snapshot.appProcesses[hostID] != nil)
        #expect(snapshot.rowCount > snapshot.malformedRowCount)
        #expect(snapshot.helperCommands.isEmpty)
    }
}

private final class RecordedInvocation: @unchecked Sendable {
    private let lock = NSLock()
    private var invocation: ProcessInvocation?

    var value: ProcessInvocation? {
        lock.withLock { invocation }
    }

    func set(_ invocation: ProcessInvocation) {
        lock.withLock { self.invocation = invocation }
    }
}
