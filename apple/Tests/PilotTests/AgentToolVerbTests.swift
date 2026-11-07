import Foundation
import Testing
@testable import Pilot

/// verbForTool mapping per agent shape, fallbacks, and the Thought reservation.
@Suite("Agent tool verbs")
struct AgentToolVerbTests {
    // WP3: implement

    @Test
    func unknownToolFallsBackToItsTitle() {
        let tool = AgentChatItem.ToolCall(title: "Frobnicate", kind: nil, status: .completed, content: "")
        let verb = verbForTool(tool, input: nil)
        #expect(verb.glyph == .other)
        #expect(verb.settled == "Frobnicate")
    }
}
