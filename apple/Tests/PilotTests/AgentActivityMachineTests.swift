import Foundation
import Testing
@testable import Pilot

/// Every activity-card transition, fold, replay, and acknowledged settle.
@Suite("Agent activity machine")
struct AgentActivityMachineTests {
    // WP3: implement

    @Test
    func noInputsStayIdle() {
        #expect(AgentActivityMachine.fold([]) == .idle)
    }
}
