import Foundation
import Testing

@testable import Copilot

@Suite("Trackpad move coalescing")
struct TrackpadMoveCoalescerTests {
    private let start = ContinuousClock.Instant.now

    @Test("first delta sends immediately")
    func firstDeltaSendsImmediately() {
        var coalescer = TrackpadMoveCoalescer()
        let move = coalescer.accumulate(dx: 3, dy: -2, now: start)
        #expect(move?.dx == 3)
        #expect(move?.dy == -2)
        #expect(!coalescer.hasPendingDelta)
    }

    @Test("deltas within one frame interval are summed, not sent")
    func deltasWithinFrameAreAccumulated() {
        var coalescer = TrackpadMoveCoalescer()
        _ = coalescer.accumulate(dx: 1, dy: 1, now: start)
        let gatedA = coalescer.accumulate(dx: 2, dy: -1, now: start.advanced(by: .milliseconds(5)))
        let gatedB = coalescer.accumulate(dx: 4, dy: 3, now: start.advanced(by: .milliseconds(10)))
        #expect(gatedA == nil)
        #expect(gatedB == nil)
        #expect(coalescer.hasPendingDelta)

        let flushed = coalescer.flush(now: start.advanced(by: .milliseconds(16)))
        #expect(flushed?.dx == 6)
        #expect(flushed?.dy == 2)
        #expect(!coalescer.hasPendingDelta)
    }

    @Test("a delta after the send interval elapses sends immediately with the pending sum")
    func deltaAfterIntervalSendsPendingSum() {
        var coalescer = TrackpadMoveCoalescer()
        _ = coalescer.accumulate(dx: 1, dy: 0, now: start)
        _ = coalescer.accumulate(dx: 2, dy: 2, now: start.advanced(by: .milliseconds(8)))
        let move = coalescer.accumulate(dx: 3, dy: 1, now: start.advanced(by: .milliseconds(16)))
        #expect(move?.dx == 5)
        #expect(move?.dy == 3)
        #expect(!coalescer.hasPendingDelta)
    }

    @Test("flush with nothing pending sends nothing")
    func emptyFlushSendsNothing() {
        var coalescer = TrackpadMoveCoalescer()
        #expect(coalescer.flush(now: start) == nil)
        _ = coalescer.accumulate(dx: 1, dy: 1, now: start)
        #expect(coalescer.flush(now: start.advanced(by: .milliseconds(1))) == nil)
    }

    @Test("flush restarts the pacing gate")
    func flushRestartsPacing() {
        var coalescer = TrackpadMoveCoalescer()
        _ = coalescer.accumulate(dx: 1, dy: 1, now: start)
        _ = coalescer.accumulate(dx: 1, dy: 1, now: start.advanced(by: .milliseconds(5)))
        _ = coalescer.flush(now: start.advanced(by: .milliseconds(10)))

        let gated = coalescer.accumulate(dx: 2, dy: 2, now: start.advanced(by: .milliseconds(12)))
        #expect(gated == nil)
        let flushed = coalescer.flush(now: start.advanced(by: .milliseconds(26)))
        #expect(flushed?.dx == 2)
        #expect(flushed?.dy == 2)
    }
}
