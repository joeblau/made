import CoreGraphics
import CoreMedia
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
