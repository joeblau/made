import Foundation
import Testing
@testable import Pilot

@Suite("Markdown table reflow")
struct MarkdownTableFormatterTests {

    // MARK: - Regression: lines vanished after Return (issue: notes line loss)

    /// A line with a pipe followed by a bare `---` thematic break must NOT be
    /// read as a table. Before the fix, `isDelimiterRow` accepted a pipe-less
    /// `---`, so this pair was reflowed into a table and the `---` line's text
    /// was overwritten with `| --- | --- |` — the "disappearing line" the user hit.
    @Test("Bare --- under a pipe line is a horizontal rule, not a table delimiter")
    func bareRuleUnderPipeLineIsNotATable() {
        #expect(MarkdownTableFormatter.reflow("| total | 42 |\n---") == nil)
        #expect(MarkdownTableFormatter.reflow("foo | bar\n---") == nil)
        #expect(MarkdownTableFormatter.reflow("| a | b |\n-----\nmore") == nil)
    }

    /// The reflow never changes how many lines the document has — and on text it
    /// doesn't recognize as a table, it must leave that text exactly alone.
    @Test("Reflow preserves line count and never rewrites non-table lines")
    func reflowPreservesLineCount() {
        let samples = [
            "| total | 42 |\n---",
            "notes\n- [ ] a\n- [x] b\nfoo | bar\n---\nend",
            "| a | b |\n| - | - |\n| 1 | 2 |",
            "no pipes here\njust prose\n---",
            "| x |\n| - |\n| y |\nrule below\n---\n| keep | me |",
        ]
        for input in samples {
            guard let out = MarkdownTableFormatter.reflow(input) else { continue }
            #expect(
                out.components(separatedBy: "\n").count == input.components(separatedBy: "\n").count,
                "line count changed for:\n\(input)"
            )
        }
    }

    // MARK: - Real tables still format

    @Test("A genuine GFM table is aligned to its widest cell")
    func realTableFormats() {
        let out = MarkdownTableFormatter.reflow("| a | b |\n| - | - |\n| 1 | 2 |")
        #expect(out == "| a   | b   |\n| --- | --- |\n| 1   | 2   |")
    }

    @Test("Single-column table with pipes still works")
    func singleColumnTable() {
        let out = MarkdownTableFormatter.reflow("| h |\n| - |\n| x |")
        #expect(out == "| h   |\n| --- |\n| x   |")
    }

    @Test("An already-formatted table is idempotent (returns nil — no churn)")
    func idempotentOnSettledTable() {
        let settled = "| a   | b   |\n| --- | --- |\n| 1   | 2   |"
        #expect(MarkdownTableFormatter.reflow(settled) == nil)
    }

    @Test("Alignment colons are honored and round-trip")
    func alignmentColons() {
        // left / center / right via :- / :-: / -:
        let out = MarkdownTableFormatter.reflow("| l | c | r |\n| :- | :-: | -: |\n| 1 | 2 | 3 |")
        #expect(out != nil)
        // The delimiter row keeps its colons after reflow, and re-running is a no-op.
        #expect(MarkdownTableFormatter.reflow(out!) == nil)
    }
}

@Suite("Markdown task reflow")
struct MarkdownTaskFormatterTests {
    @Test("Completing a subtask keeps it attached to its parent")
    func completedSubtaskStaysInPlace() {
        let checklist = """
        - [ ] Is there a token launch checklist
          - [x] Whitelisting
        - [ ] Any security intros we need
        """

        #expect(MarkdownTaskFormatter.reflow(checklist) == nil)
    }

    @Test("Completed root tasks move with all of their subtasks")
    func completedRootMovesAsAGroup() {
        let checklist = """
        - [x] Launch checklist
          - [ ] Whitelisting
          - [x] Security review
        - [ ] Prepare announcement
        """
        let expected = """
        - [ ] Prepare announcement
        - [x] Launch checklist
          - [ ] Whitelisting
          - [x] Security review
        """

        #expect(MarkdownTaskFormatter.reflow(checklist) == expected)
    }

    @Test("Flat completed tasks still sink below incomplete tasks")
    func flatTasksStillReorder() {
        let checklist = """
        - [x] Ship
        - [ ] Test
        """
        let expected = """
        - [ ] Test
        - [x] Ship
        """

        #expect(MarkdownTaskFormatter.reflow(checklist) == expected)
    }
}

@Suite("Regional Markdown reflow")
struct RegionalMarkdownReflowTests {
    @Test("Only the touched table block is aligned")
    func tableScope() {
        let text = "| a | b |\n| - | - |\n| 1 | 2 |\n\n| c | d |\n| - | - |\n| 3 | 4 |"
        let expected = "| a   | b   |\n| --- | --- |\n| 1   | 2   |\n\n| c | d |\n| - | - |\n| 3 | 4 |"
        #expect(MarkdownTableFormatter.reflow(
            text, touching: [NSRange(location: 2, length: 0)]
        ) == expected)
        #expect(MarkdownTableFormatter.reflow(text, touching: []) == nil)
    }

    @Test("Only the touched task group is reordered")
    func taskScope() {
        let text = "- [x] a\n- [ ] b\n\n- [x] c\n- [ ] d"
        let expected = "- [ ] b\n- [x] a\n\n- [x] c\n- [ ] d"
        #expect(MarkdownTaskFormatter.reflow(
            text, touching: [NSRange(location: 3, length: 0)]
        ) == expected)
        #expect(MarkdownTaskFormatter.reflow(text, touching: []) == nil)
    }
}
