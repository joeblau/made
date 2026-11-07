import AppKit
import Testing
@testable import Pilot

/// Gallery fixtures (fixed clock, light and dark, widths 360/560/900). Asserts
/// structure always; writes PNGs when MADE_TOOL_REVIEW_OUTPUT is set.
@Suite("Agent chat gallery")
@MainActor
struct AgentChatGalleryTests {
    // WP4: implement

    @Test
    func everyViewKindCarriesItsIdentifier() {
        #expect(ProseCellView().identifier == ProseCellView.reuseIdentifier)
        #expect(ActivityCardView().accessibilityIdentifier() == "agent-chat.activity")
        #expect(ActivityStepView().accessibilityIdentifier() == "agent-chat.step")
        #expect(AgentRosterView().accessibilityIdentifier() == "agent-chat.roster")
        #expect(AgentChipView().accessibilityIdentifier() == "agent-chat.chip")
        #expect(ApprovalCardView().accessibilityIdentifier() == "agent-chat.approval")
        #expect(AgentInspectorViewController().view.accessibilityIdentifier() == "agent-chat.inspector")
    }
}
