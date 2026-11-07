import Foundation
import Testing
@testable import Pilot

/// Secret masking patterns, separators, PEM blocks, redact-before-truncate,
/// nested JSON strings, and false positives.
@Suite("Agent output redaction")
struct AgentRedactionTests {
    // WP3: implement

    @Test
    func ordinaryTextPassesThroughUnchanged() {
        #expect(redactOutput("git status\nOn branch main") == AgentRedaction(
            text: "git status\nOn branch main", redacted: false, truncatedLines: 0
        ))
        #expect(redactInline("Read README.md") == "Read README.md")
    }
}
