import Foundation
import Testing
@testable import Pilot

/// The batched `list-panes -a` output covers every session on a tmux server
/// Pilot shares with the user, so parsing must keep only Pilot-owned sessions
/// and survive arbitrary bytes on every field.
@Suite("Batched tmux pane-runtime parsing")
struct PaneRuntimeBatchParsingTests {
    private func parse(_ output: String) -> [String: PersistentTerminalSession.PaneRuntime] {
        PersistentTerminalSession.parsePaneRuntimes(output)
    }

    @Test
    func keepsOnlyPilotSessionsWithValidPIDs() {
        let output = """
        pilot-abc\t101\t1\t1\t1
        personal\t202\t1\t1\t1
        pilot-text\tnope\t1\t1\t1
        pilot-zero\t0\t1\t1\t1
        pilot-negative\t-5\t1\t1\t1
        """
        let runtimes = parse(output)
        #expect(runtimes.count == 1)
        #expect(runtimes["pilot-abc"]?.shellPID == 101)
        #expect(runtimes["pilot-abc"]?.cursorVisible == true)
    }

    @Test
    func malformedLinesAreDropped() {
        let output = "pilot-abc\t101\t1\npilot-short\t7\n\ngarbage\npilot-extra\t9\t1\t1\t1\t1"
        #expect(parse(output).isEmpty)
    }

    @Test
    func cursorFlagParsesPerSession() {
        let runtimes = parse("pilot-a\t11\t0\t1\t1\npilot-b\t12\t1\t1\t1")
        #expect(runtimes["pilot-a"]?.cursorVisible == false)
        #expect(runtimes["pilot-b"]?.cursorVisible == true)
    }

    @Test
    func activePaneOfActiveWindowWinsInASplitSession() {
        // Matches the pane `display-message -t session` used to target.
        let output = """
        pilot-split\t301\t0\t1\t0
        pilot-split\t302\t1\t1\t1
        pilot-split\t303\t0\t0\t1
        """
        let runtimes = parse(output)
        #expect(runtimes.count == 1)
        #expect(runtimes["pilot-split"]?.shellPID == 302)
        #expect(runtimes["pilot-split"]?.cursorVisible == true)
    }

    @Test
    func firstPaneStandsInWhenNoneIsFullyActive() {
        let output = "pilot-split\t301\t0\t0\t1\npilot-split\t302\t1\t1\t0"
        #expect(parse(output)["pilot-split"]?.shellPID == 301)
    }

    @Test
    func sessionCountIsBounded() {
        let lines = (0..<600).map { "pilot-\($0)\t\($0 + 1)\t1\t1\t1" }
        #expect(parse(lines.joined(separator: "\n")).count == 512)
    }
}
