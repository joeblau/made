import Foundation
import Testing
@testable import Pilot

@Suite("Remote screen discovery backoff")
struct RemoteScreenDiscoveryBackoffTests {
    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    @Test func delayGrowsExponentiallyWithinEqualJitterWindow() {
        // Zero jitter pins the lower edge of each window (2^attempt / 2)...
        #expect(seconds(RemoteScreenDiscovery.restartDelay(attempt: 0, unitJitter: 0)) == 0.5)
        #expect(seconds(RemoteScreenDiscovery.restartDelay(attempt: 1, unitJitter: 0)) == 1.0)
        #expect(seconds(RemoteScreenDiscovery.restartDelay(attempt: 3, unitJitter: 0)) == 4.0)
        // ...and full jitter the upper edge (2^attempt).
        #expect(seconds(RemoteScreenDiscovery.restartDelay(attempt: 0, unitJitter: 1)) == 1.0)
        #expect(seconds(RemoteScreenDiscovery.restartDelay(attempt: 3, unitJitter: 1)) == 8.0)
    }

    @Test func delayIsCappedAtThirtySeconds() {
        #expect(seconds(RemoteScreenDiscovery.restartDelay(attempt: 50, unitJitter: 1)) == 30.0)
        #expect(seconds(RemoteScreenDiscovery.restartDelay(attempt: 50, unitJitter: 0)) == 15.0)
        #expect(seconds(RemoteScreenDiscovery.restartDelay(attempt: Int.max, unitJitter: 1)) == 30.0)
    }

    @Test func outOfRangeInputsAreClamped() {
        #expect(seconds(RemoteScreenDiscovery.restartDelay(attempt: -3, unitJitter: -1)) == 0.5)
        #expect(seconds(RemoteScreenDiscovery.restartDelay(attempt: 0, unitJitter: 2)) == 1.0)
    }
}
