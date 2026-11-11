import CoreGraphics
import CoreMedia
import ScreenCaptureKit
import Testing
@testable import Pilot

@Suite("Screen-mirroring bitrate policy")
struct ScreenMirrorBitrateTests {
    @Test("Registered main window wins even when the extension is larger")
    func registeredMainWindowWinsOverLargerExtension() {
        let bundleID = "app.blau.pilot"
        let mainWindowID: CGWindowID = 10
        let candidates = [
            ScreenMirrorWindowCandidate(
                windowID: mainWindowID,
                bundleIdentifier: bundleID,
                isOnScreen: true,
                width: 1_000,
                height: 700,
                hasTitle: true,
                windowLayer: 0
            ),
            ScreenMirrorWindowCandidate(
                windowID: 20,
                bundleIdentifier: bundleID,
                isOnScreen: true,
                width: 1_600,
                height: 1_200,
                hasTitle: true,
                windowLayer: 0
            )
        ]

        let selectedID = ScreenMirrorWindowSelectionPolicy.pickWindowID(
            from: candidates,
            bundleIdentifier: bundleID,
            preferredWindowID: mainWindowID
        )

        #expect(selectedID == mainWindowID)
    }

    @Test("A registered Main window never falls back to Extension")
    func missingRegisteredMainWindowDoesNotSelectExtension() {
        let bundleID = "app.blau.pilot"
        let candidates = [
            ScreenMirrorWindowCandidate(
                windowID: 20,
                bundleIdentifier: bundleID,
                isOnScreen: true,
                width: 1_600,
                height: 1_200,
                hasTitle: true,
                windowLayer: 0
            )
        ]

        let selectedID = ScreenMirrorWindowSelectionPolicy.pickWindowID(
            from: candidates,
            bundleIdentifier: bundleID,
            preferredWindowID: 10
        )

        #expect(selectedID == nil)
    }

    @Test("First congestion report never raises the initial bitrate")
    func firstCongestionReportDoesNotIncreaseBitrate() {
        let initial = StreamBitratePolicy.initial
        let next = StreamBitratePolicy.next(
            current: initial,
            feedback: FrameProtocol.LinkFeedback(lossPct: 8, rttMs: 200, queueDepth: 8)
        )

        #expect(initial >= StreamBitratePolicy.minimum)
        #expect(next <= initial)
        #expect(next == StreamBitratePolicy.minimum)
    }

    @Test("Rejected forced frame restores the keyframe request for its replacement")
    func rejectedForcedFrameRestoresRequest() {
        var latch = KeyframeRequestLatch()
        latch.request()

        let rejectedFrameWasForced = latch.takeForSubmission()
        #expect(rejectedFrameWasForced)
        #expect(!latch.isPending)

        latch.restoreAfterRejectedSubmission(rejectedFrameWasForced)
        let replacementWasForced = latch.takeForSubmission()
        #expect(replacementWasForced)
    }

    @Test("Failed encoder output requests a recovery keyframe")
    func failedEncoderOutputRequestsRecoveryKeyframe() {
        var latch = KeyframeRequestLatch()
        latch.restoreAfterOutputFailure()

        let recoveryWasForced = latch.takeForSubmission()
        #expect(recoveryWasForced)
    }

    @Test("Snapshot gate throttles to one admission per interval")
    func snapshotGateThrottlesToInterval() {
        var gate = SnapshotGate(interval: 7)
        func pts(_ seconds: Double) -> CMTime {
            CMTime(seconds: seconds, preferredTimescale: 600)
        }

        let first = gate.admit(pts: pts(0))
        #expect(first)
        gate.finish()

        let beforeInterval = gate.admit(pts: pts(6.9))
        #expect(!beforeInterval)
        let atInterval = gate.admit(pts: pts(7))
        #expect(atInterval)
    }

    @Test("Snapshot gate admits at most one render in flight")
    func snapshotGateBoundsInFlightRenders() {
        var gate = SnapshotGate(interval: 7)
        func pts(_ seconds: Double) -> CMTime {
            CMTime(seconds: seconds, preferredTimescale: 600)
        }

        let first = gate.admit(pts: pts(0))
        #expect(first)
        // Interval elapsed but the previous render is still running: a slow
        // render must never stack retained capture buffers.
        let whileRenderInFlight = gate.admit(pts: pts(20))
        #expect(!whileRenderInFlight)
        gate.finish()
        let afterFinish = gate.admit(pts: pts(20))
        #expect(afterFinish)
    }
}

// MARK: - Capture lifecycle (#446)

/// Fake capture stream whose `startCapture()` can be held open so a test can
/// call `ScreenMirror.stop()` while a start is in flight.
@MainActor
private final class FakeMirrorCaptureStream: ScreenMirrorCaptureStream {
    var holdsStart = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var pendingStart: CheckedContinuation<Void, Never>?

    var isStartPending: Bool { pendingStart != nil }

    func startCapture() async throws {
        startCount += 1
        guard holdsStart else { return }
        await withCheckedContinuation { continuation in
            pendingStart = continuation
        }
    }

    func releaseStart() {
        pendingStart?.resume()
        pendingStart = nil
    }

    func stopCapture() async throws {
        stopCount += 1
    }

    func updateConfiguration(_ configuration: SCStreamConfiguration) async throws {}
}

/// Fake capture source: no ScreenCaptureKit, no screen-recording permission.
/// The window lookup can also be held open, and `providesWindow = false`
/// models the main window not being on screen yet.
@MainActor
private final class FakeMirrorCaptureSource: ScreenMirrorCaptureSource {
    var providesWindow = true
    var holdsLookup = false
    var holdsStart = false
    private(set) var lookupCount = 0
    private(set) var streams: [FakeMirrorCaptureStream] = []
    private var pendingLookup: CheckedContinuation<Void, Never>?

    var isLookupPending: Bool { pendingLookup != nil }

    func hasCaptureAccess() -> Bool { true }

    func makeStream(
        mainWindowID: () -> CGWindowID?,
        configuration: (CGRect) -> SCStreamConfiguration
    ) async throws -> (any ScreenMirrorCaptureStream)? {
        lookupCount += 1
        if holdsLookup {
            await withCheckedContinuation { continuation in
                pendingLookup = continuation
            }
        }
        guard providesWindow, mainWindowID() != nil else { return nil }
        _ = configuration(CGRect(x: 0, y: 0, width: 1_280, height: 800))
        let stream = FakeMirrorCaptureStream()
        stream.holdsStart = holdsStart
        streams.append(stream)
        return stream
    }

    func releaseLookup() {
        pendingLookup?.resume()
        pendingLookup = nil
    }
}

@MainActor
@Suite("Screen-mirroring capture lifecycle")
struct ScreenMirrorLifecycleTests {
    private func makeMirror(_ source: FakeMirrorCaptureSource) -> ScreenMirror {
        let mirror = ScreenMirror(
            sender: FrameSender(usesEphemeralIdentity: true),
            captureSource: source,
            restartDelay: .milliseconds(10)
        )
        mirror.setMainWindowID(1)
        return mirror
    }

    /// Polls `condition` on the main actor until it holds or `timeout` passes.
    private func eventually(
        timeout: Duration = .seconds(2),
        _ condition: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    @Test("stop() stops a running capture")
    func stopStopsRunningCapture() async {
        let source = FakeMirrorCaptureSource()
        let mirror = makeMirror(source)

        mirror.start()
        let started = await eventually { source.streams.first?.startCount == 1 }
        #expect(started)
        #expect(mirror.isRunning)

        mirror.stop()
        let stopped = await eventually { source.streams.first?.stopCount == 1 }
        #expect(stopped)
        #expect(!mirror.isRunning)
    }

    @Test("stop() during startCapture stops the late stream")
    func stopDuringStartCaptureStopsLateStream() async {
        let source = FakeMirrorCaptureSource()
        source.holdsStart = true
        let mirror = makeMirror(source)

        mirror.start()
        let pending = await eventually { source.streams.first?.isStartPending == true }
        #expect(pending)

        mirror.stop()
        source.streams.first?.releaseStart()

        // The stream that finished starting after stop() must be stopped, not
        // committed as the live capture.
        let stopped = await eventually { source.streams.first?.stopCount == 1 }
        #expect(stopped)
        #expect(!mirror.isRunning)
        #expect(source.lookupCount == 1)
    }

    @Test("stop() during the window lookup never starts a stream")
    func stopDuringWindowLookupNeverStartsStream() async {
        let source = FakeMirrorCaptureSource()
        source.holdsLookup = true
        let mirror = makeMirror(source)

        mirror.start()
        let pending = await eventually { source.isLookupPending }
        #expect(pending)

        mirror.stop()
        source.releaseLookup()

        try? await Task.sleep(for: .milliseconds(50))
        #expect(source.streams.allSatisfy { $0.startCount == 0 })
        #expect(!mirror.isRunning)
    }

    @Test("stop() cancels the no-window retry")
    func stopCancelsNoWindowRetry() async {
        let source = FakeMirrorCaptureSource()
        source.providesWindow = false
        let mirror = makeMirror(source)

        mirror.start()
        // Positive control: without stop() the retry keeps looking.
        let retried = await eventually { source.lookupCount >= 2 }
        #expect(retried)

        mirror.stop()
        // Let a start() already dispatched before stop() drain.
        try? await Task.sleep(for: .milliseconds(30))
        let lookupsAfterStop = source.lookupCount

        // Many retry intervals later, nothing has looked again.
        try? await Task.sleep(for: .milliseconds(150))
        #expect(source.lookupCount == lookupsAfterStop)
        #expect(!mirror.isRunning)
        #expect(source.streams.isEmpty)
    }
}
