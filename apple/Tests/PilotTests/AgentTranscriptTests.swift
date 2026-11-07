import Foundation
import Testing
@testable import Pilot

/// Transcript model contracts: new fields, finishTurn paths, approvals,
/// bounds, and the activity events the transcript emits.
@Suite("Agent transcript")
struct AgentTranscriptTests {
    // WP1: implement

    @Test
    func newItemFieldsDefaultToARootFirstTurnItem() {
        let item = AgentChatItem(id: "local-1", content: .notice("Stopped."))
        #expect(item.revision == 0)
        #expect(item.turnIndex == 0)
        #expect(!item.isReplayed)
        #expect(item.key == "root/local-1")
        #expect(AgentTranscript().stepDetails.isEmpty)
        #expect(AgentTranscript.maximumChildSessions == 64)
    }
}
