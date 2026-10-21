import AppKit
import Foundation
import Testing
@testable import Pilot

/// Pins the behavior of the Notes editor hot paths that were rewritten for
/// performance: `Note.displayTitle` (now redacting only the title line) and
/// the caret-line computation guarding markdown-table reflow.
@MainActor
struct NoteDisplayTitleTests {
    @Test("Title comes from the first non-empty line")
    func skipsLeadingBlankLines() {
        #expect(Note(body: "\n\n   \nHello world\nSecond").displayTitle == "Hello world")
    }

    @Test("Long first lines truncate to 24 characters")
    func truncatesLongFirstLine() {
        let title = Note(body: String(repeating: "a", count: 30) + "\nrest").displayTitle
        #expect(title == String(repeating: "a", count: 24) + "…")
    }

    @Test("A secret on the title line stays masked")
    func masksTitleLineSecret() {
        #expect(Note(body: "  API_TOKEN=secret-value  \nmore").displayTitle == "API_TOKEN=••••••••")
    }

    @Test("Secrets below the first line don't change the title")
    func laterSecretsDoNotAffectTitle() {
        #expect(Note(body: "Shopping list\nAPI_TOKEN=secret-value").displayTitle == "Shopping list")
    }

    @Test("Empty and whitespace-only bodies fall back")
    func fallsBackToNewNote() {
        #expect(Note(body: "").displayTitle == "New Note")
        #expect(Note(body: " \n\t\n").displayTitle == "New Note")
    }
}

@MainActor
struct NotesTableReflowCaretTests {
    private let unformatted = "title\n|a|b|\n|---|---|\n|1|2|"
    private let formatted = "title\n| a   | b   |\n| --- | --- |\n| 1   | 2   |"

    @Test("Reflow skips the table block the caret is inside")
    func caretProtectsItsTable() throws {
        let scrollView = MultiCursorTextView.scrollableTextView()
        let textView = try #require(scrollView.documentView as? MultiCursorTextView)
        textView.string = unformatted
        // Caret inside the header row "|a|b|" (line 1).
        textView.setSelectedRange(NSRange(location: 7, length: 0))

        textView.formatMarkdownTables()

        #expect(textView.string == unformatted)
    }

    @Test("Reflow formats a table the caret is not touching")
    func caretElsewhereAllowsReflow() throws {
        let scrollView = MultiCursorTextView.scrollableTextView()
        let textView = try #require(scrollView.documentView as? MultiCursorTextView)
        textView.string = unformatted
        // Caret on the "title" line (line 0), outside the table block.
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        textView.formatMarkdownTables()

        #expect(textView.string == formatted)
    }

    @Test("A selection spanning into the table protects it")
    func selectionProtectsTouchedLines() throws {
        let scrollView = MultiCursorTextView.scrollableTextView()
        let textView = try #require(scrollView.documentView as? MultiCursorTextView)
        textView.string = unformatted
        // "title\n|a" — lines 0 and 1, the latter inside the table.
        textView.setSelectedRange(NSRange(location: 0, length: 8))

        textView.formatMarkdownTables()

        #expect(textView.string == unformatted)
    }

    @Test("A caret at the end of the document protects the last table row")
    func caretAtEndProtectsLastRow() throws {
        let scrollView = MultiCursorTextView.scrollableTextView()
        let textView = try #require(scrollView.documentView as? MultiCursorTextView)
        textView.string = unformatted
        textView.setSelectedRange(NSRange(location: (unformatted as NSString).length, length: 0))

        textView.formatMarkdownTables()

        #expect(textView.string == unformatted)
    }
}
