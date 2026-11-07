import Foundation
import Testing
@testable import Pilot

/// Folding, approval/plan transparency, roster, weight rules, stable IDs, and
/// projection budgets.
@Suite("Agent timeline")
struct AgentTimelineTests {
    // WP3: implement

    @Test
    func emptyTranscriptProjectsNoRows() {
        let rows = AgentTimeline.project(
            AgentTranscript(), isTurnRunning: false, acknowledgedSettles: [], now: Date(timeIntervalSince1970: 0)
        )
        #expect(rows.isEmpty)
    }
}
