import AppKit
import Testing
@testable import Pilot

/// AppKit smoke checks for the Notes editor: the same text-view wiring the
/// SwiftUI bridge installs (Markdown styler, secret mask, automatic reflows)
/// driven through the normal NSTextView edit path, so undo registration,
/// caret restoration, and multi-cursor selection are exercised together.
@MainActor
@Suite("Notes editing smoke")
struct NotesEditingSmokeTests {
    @MainActor
    private final class Harness: NSObject, NSTextViewDelegate {
        let undo = UndoManager()
        let styler = MarkdownStyler(baseSize: 13)
        let mask = EnvMaskController()
        let scrollView: NSScrollView
        let textView: MultiCursorTextView
        let window: NSWindow
        private(set) var changeCount = 0

        init(_ text: String) throws {
            scrollView = MultiCursorTextView.scrollableTextView()
            textView = try #require(scrollView.documentView as? MultiCursorTextView)
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                styleMask: [.titled],
                backing: .buffered,
                defer: true
            )
            super.init()
            window.isReleasedWhenClosed = false
            scrollView.frame = window.contentLayoutRect
            window.contentView = scrollView
            window.makeFirstResponder(textView)
            undo.groupsByEvent = false
            textView.delegate = self
            textView.allowsUndo = true
            textView.isRichText = true
            textView.textStorage?.delegate = styler
            mask.textView = textView
            textView.maskController = mask
            textView.layoutManager?.delegate = mask
            textView.string = text
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        func textDidChange(_ notification: Notification) {
            changeCount += 1
            mask.refresh()
            textView.applyAutomaticReflows()
        }

        /// One user-visible edit inside its own undo group.
        func type(_ string: String, replacing range: NSRange) {
            undo.beginUndoGrouping()
            textView.setSelectedRange(range)
            textView.insertText(string, replacementRange: range)
            undo.endUndoGrouping()
        }

        var caret: Int { textView.selectedRange().location }
    }

    @Test("Checking a task sinks it, keeps the caret on its line, and undoes as one edit")
    func taskReflowUndo() throws {
        let original = "- [ ] alpha\n- [ ] beta\n- [ ] gamma"
        let harness = try Harness(original)

        harness.type("x", replacing: NSRange(location: 3, length: 1))

        let expected = "- [ ] beta\n- [ ] gamma\n- [x] alpha"
        #expect(harness.textView.string == expected)
        let movedLine = (expected as NSString).range(of: "- [x] alpha")
        #expect(harness.caret == movedLine.location + 4)
        #expect(harness.textView.selectedRanges.count == 1)

        // Undo replays the reflow and the keystroke as one group; reflows must
        // not run between those steps or the keystroke lands on a moved line.
        harness.undo.undo()
        #expect(harness.textView.string == original)
        harness.undo.redo()
        #expect(harness.textView.string == expected)
        #expect(harness.undo.canUndo)
    }

    @Test("Typing in a table cell leaves that table alone but aligns other tables")
    func tableCaretProtection() throws {
        let original = "| a | b |\n| - | - |\n| 1 | 2 |\n\ntext\n\n| c | d |\n| - | - |\n| 3 | 4 |"
        let harness = try Harness(original)

        // Append to the first table's "1" cell.
        let insertion = (original as NSString).range(of: "| 1").location + 3
        harness.type("23", replacing: NSRange(location: insertion, length: 0))

        let lines = harness.textView.string.components(separatedBy: "\n")
        #expect(lines[0] == "| a | b |")
        #expect(lines[2] == "| 123 | 2 |")
        #expect(lines[6] == "| c   | d   |")
        #expect(lines[7] == "| --- | --- |")
        #expect(lines[8] == "| 3   | 4   |")
        // The caret stays right after the typed text.
        #expect(harness.caret == insertion + 2)

        harness.undo.undo()
        #expect(harness.textView.string == original)
    }

    @Test("Split-into-lines places carets at line ends and typing follows the kept carets")
    func multiCursorTyping() throws {
        let original = "one\ntwo\nthree"
        let harness = try Harness(original)
        harness.textView.setSelectedRange(NSRange(location: 0, length: (original as NSString).length))

        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "L",
            charactersIgnoringModifiers: "l",
            isARepeat: false,
            keyCode: 37
        ))
        #expect(harness.textView.performKeyEquivalent(with: event))

        // The gesture requests a caret at the end of every selected line;
        // AppKit decides how many zero-length ranges it keeps, so check the
        // kept carets are a sorted prefix of the requested ones.
        let lineEnds = [3, 7, 13]
        let carets = harness.textView.selectedRanges.map(\.rangeValue)
        #expect(!carets.isEmpty)
        #expect(carets.allSatisfy { $0.length == 0 })
        #expect(carets.map(\.location) == Array(lineEnds.prefix(carets.count)))

        harness.undo.beginUndoGrouping()
        harness.textView.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        harness.undo.endUndoGrouping()

        var expected = original
        for caret in carets.reversed() {
            let index = expected.utf16.index(expected.startIndex, offsetBy: caret.location)
            expected.insert("!", at: index)
        }
        #expect(harness.textView.string == expected)
        #expect(harness.changeCount == 1)

        harness.undo.undo()
        #expect(harness.textView.string == original)
    }

    @Test("Plain prose edits never trigger a programmatic reflow")
    func proseEditIsSingleChange() throws {
        let harness = try Harness("- [ ] open\n- [x] done\n\n| a   | b   |\n| --- | --- |\n\nprose")
        let end = (harness.textView.string as NSString).length

        harness.type(" more", replacing: NSRange(location: end, length: 0))

        #expect(harness.textView.string.hasSuffix("prose more"))
        #expect(harness.changeCount == 1)
        #expect(harness.caret == end + 5)
    }

    @Test("The caret anchor follows its line through a reorder and falls back when the line is gone")
    func caretAnchor() {
        let before = "a\nbeta line\nc" as NSString
        let anchor = NoteCaretAnchor(selection: NSRange(location: 6, length: 0), in: before)
        #expect(anchor.lineText == "beta line")
        #expect(anchor.column == 4)

        // Same line moved to the top.
        #expect(anchor.location(in: "beta line\na\nc") == 4)
        // Line gone: the old offset, clamped to the new text.
        #expect(anchor.location(in: "xy") == 2)
        // Caret at the very end of the document stays on the last line.
        let end = NoteCaretAnchor(selection: NSRange(location: before.length, length: 0), in: before)
        #expect(end.lineText == "c")
        #expect(end.location(in: "c\na\nbeta line") == 1)
    }

    @Test("A table left unaligned under the caret aligns on the next edit elsewhere")
    func deferredTableAlignsLater() throws {
        let original = "| a | b |\n| - | - |\n\nprose"
        let harness = try Harness(original)

        // Typing inside the table keeps it as typed.
        harness.type("z", replacing: NSRange(location: 3, length: 0))
        #expect(harness.textView.string.hasPrefix("| az | b |\n| - | - |"))

        // The next edit, away from any table, still aligns it.
        let end = (harness.textView.string as NSString).length
        harness.type("!", replacing: NSRange(location: end, length: 0))
        #expect(harness.textView.string == "| az  | b   |\n| --- | --- |\n\nprose!")
        #expect(harness.caret == (harness.textView.string as NSString).length)
    }

    @Test("Text replaced from outside the editor is settled by the next edit")
    func externalTextSettlesOnNextEdit() throws {
        let harness = try Harness("start")
        harness.textView.string = "- [x] done\n- [ ] open\n\nprose"
        let end = (harness.textView.string as NSString).length

        harness.type("!", replacing: NSRange(location: end, length: 0))

        #expect(harness.textView.string == "- [ ] open\n- [x] done\n\nprose!")
    }

    @Test("Reflow relevance is limited to edits touching or bordering task and table lines")
    func reflowScope() {
        let text = "- [ ] task\nplain one\nplain two\nplain three\n| a | b |" as NSString
        func scope(_ needle: String, _ replacement: String = "x") -> MultiCursorTextView.ReflowScope {
            let at = text.range(of: needle).location
            return MultiCursorTextView.reflowScope(
                of: NSRange(location: at, length: 0), replacement: replacement, in: text
            )
        }
        #expect(scope("two") == [])
        #expect(scope("one") == [.tasks])
        #expect(scope("three") == [.tables])
        #expect(scope("two", "|") == [.tables])
        #expect(scope("two", "- [ ] new") == [.tasks])
    }

    @Test("Bullet glyphs cover exactly the secret values as edits move, grow, and break them")
    func maskGlyphsFollowEdits() throws {
        let harness = try Harness("intro\nAPI_TOKEN=secret-value\nOTHER=x\ntail")
        harness.mask.refresh()

        /// Character indexes currently drawn as the bullet glyph.
        func bulletIndexes() throws -> [Int] {
            let layoutManager = try #require(harness.textView.layoutManager)
            let storage = try #require(harness.textView.textStorage)
            var bullets: [Int] = []
            for index in 0..<storage.length {
                let font = try #require(storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
                var character: [UniChar] = Array("•".utf16)
                var bullet: [CGGlyph] = [0]
                CTFontGetGlyphsForCharacters(font, &character, &bullet, 1)
                let glyphIndex = layoutManager.glyphIndexForCharacter(at: index)
                if layoutManager.cgGlyph(at: glyphIndex) == bullet[0] { bullets.append(index) }
            }
            return bullets
        }
        func expectedIndexes() -> [Int] {
            EnvSecret.matches(in: harness.textView.string).flatMap {
                Array($0.valueRange.location..<NSMaxRange($0.valueRange))
            }
        }

        #expect(try bulletIndexes() == expectedIndexes())
        let edits: [(String, (NSString) -> NSRange, String)] = [
            ("insert before the secrets", { _ in NSRange(location: 0, length: 0) }, "more "),
            ("type inside a value", { $0.range(of: "secret-") }, "longer-secret-"),
            ("append to a value", { NSRange(location: NSMaxRange($0.range(of: "value")), length: 0) }, "!"),
            ("break a key", { $0.range(of: "API_TOKEN") }, "api_token"),
            ("restore the key", { $0.range(of: "api_token") }, "API_TOKEN"),
            ("join two secret lines", { NSRange(location: $0.range(of: "\nOTHER").location, length: 1) }, " "),
        ]
        for (name, range, replacement) in edits {
            harness.type(replacement, replacing: range(harness.textView.string as NSString))
            #expect(try bulletIndexes() == expectedIndexes(), "\(name)")
        }
    }

    @Test("Reflows replace only the differing span, keeping surrogate pairs whole")
    func changedSpan() {
        let span = MultiCursorTextView.changedSpan(from: "abcXYZdef", to: "abc12def")
        #expect(span.old == NSRange(location: 3, length: 3))
        #expect(span.new == NSRange(location: 3, length: 2))

        // 😀 (D83D DE00) vs 😃 (D83D DE03) share a lead surrogate.
        let emoji = MultiCursorTextView.changedSpan(from: "a😀b", to: "a😃b")
        #expect(emoji.old == NSRange(location: 1, length: 2))
        #expect(emoji.new == NSRange(location: 1, length: 2))

        let same = MultiCursorTextView.changedSpan(from: "same", to: "same")
        #expect(same.old.length == 0)
        #expect(same.new.length == 0)
    }
}
