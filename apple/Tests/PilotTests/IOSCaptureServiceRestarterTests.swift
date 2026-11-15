import Foundation
import Testing
@testable import Pilot

@MainActor
@Suite struct IOSCaptureServiceRestarterTests {
    nonisolated private static func result(exit code: Int32, stderr: String = "") -> ProcessRunResult {
        ProcessRunResult(
            termination: .exit(code), standardOutput: Data(), standardError: Data(stderr.utf8),
            standardOutputTruncated: false, standardErrorTruncated: false,
            elapsed: .zero, redactedCommand: "osascript"
        )
    }

    @Test func invocationRunsOnlyTheFixedPrivilegedKill() {
        let invocation = IOSCaptureServiceRestarter.invocation(for: .captureService)
        let script = IOSCaptureServiceRestarter.script(for: .captureService)
        #expect(invocation.executableURL.path == "/usr/bin/osascript")
        #expect(invocation.arguments == ["-e", script])
        #expect(script.contains("\"/usr/bin/killall -q iOSScreenCaptureAssistant || true\""))
        #expect(script.contains("with administrator privileges"))
        let backup = IOSCaptureServiceRestarter.script(for: .usbAndCaptureServices)
        #expect(backup.contains("\"/usr/bin/killall -q usbmuxd iOSScreenCaptureAssistant || true\""))
        // The prompt waits on a person; the runner's 15s default would kill it.
        #expect(invocation.timeout >= .seconds(60))
    }

    @Test func successReportsRestarted() async {
        let restarter = IOSCaptureServiceRestarter(run: { _ in Self.result(exit: 0) })
        #expect(await restarter.restart() == .restarted)
        #expect(!restarter.isRestarting)
    }

    @Test func backupRestartIsOfferedOnlyAfterTheFirstOneRanAndUntilCaptureRecovers() async {
        let scripts = ScriptLog()
        let restarter = IOSCaptureServiceRestarter(run: { invocation in
            await scripts.append(invocation.arguments.last ?? "")
            return Self.result(exit: 0)
        })
        #expect(restarter.nextScope == .captureService)
        #expect(await restarter.restart() == .restarted)
        #expect(restarter.nextScope == .usbAndCaptureServices)
        #expect(await restarter.restart() == .restarted)
        #expect(await scripts.values == [
            IOSCaptureServiceRestarter.script(for: .captureService),
            IOSCaptureServiceRestarter.script(for: .usbAndCaptureServices),
        ])
        restarter.captureDidRecover()
        #expect(restarter.nextScope == .captureService)
    }

    @Test func dismissedPasswordPromptIsCancelledNotFailed() async {
        let restarter = IOSCaptureServiceRestarter(run: { _ in
            throw ProcessRunnerError.nonZeroExit(Self.result(exit: 1, stderr: "0:112: execution error: User canceled. (-128)\n"))
        })
        #expect(await restarter.restart() == .cancelled)
        #expect(!restarter.isRestarting)
        // Nothing was restarted, so the backup is not offered yet.
        #expect(restarter.nextScope == .captureService)
    }

    @Test func otherFailuresSurfaceAMessage() async {
        let denied = IOSCaptureServiceRestarter(run: { _ in
            throw ProcessRunnerError.nonZeroExit(Self.result(exit: 1, stderr: "execution error: not allowed (-60005)"))
        })
        guard case .failed = await denied.restart() else {
            Issue.record("a rejected password must be reported as a failure")
            return
        }
        let timedOut = IOSCaptureServiceRestarter(run: { _ in throw ProcessRunnerError.timedOut(Self.result(exit: 15)) })
        guard case .failed = await timedOut.restart() else {
            Issue.record("a timed-out prompt must be reported as a failure")
            return
        }
    }

    @Test func secondRestartWhileThePromptIsUpDoesNothing() async {
        let (gate, release) = AsyncStream<Void>.makeStream()
        let restarter = IOSCaptureServiceRestarter(run: { _ in
            for await _ in gate { break }
            return Self.result(exit: 0)
        })
        let first = Task { await restarter.restart() }
        while !restarter.isRestarting { await Task.yield() }
        #expect(await restarter.restart() == nil)
        release.yield()
        #expect(await first.value == .restarted)
    }
}

private actor ScriptLog {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}
