import AppKit
import Foundation
import Testing
@testable import Pilot

/// Incremental styling must be indistinguishable from a full pass: after every
/// edit, the live storage (styled region by region through the delegate) is
/// compared attribute-for-attribute with a fresh storage given one full pass.
@MainActor
@Suite("Incremental Markdown styling")
struct MarkdownStylerIncrementalTests {
    static let fixture = """
    # Release notes

    Prose with **bold**, *italic*, _under_, ~~strike~~, `inline`, a [link](https://example.com) and www.example.org.
    > Quoted line with https://example.com/path.
    API_TOKEN="secret*value*"
    export OTHER_KEY=plain
    Swatch `#00FF3F` and `rgb(10, 20, 30)` here.

    - [ ] open task
      - [x] done child
    - [x] done task
    1. numbered

    | name | value |
    | ---- | ----- |
    | a    | 1     |

    ```swift
    # not a heading
    let x = "**not bold**"
    ```

    ![Diagram](https://example.com/diagram.png) ![Second](https://example.com/two.png)
    ***
    Café 東京 line with `code`.
    Last line without newline
    """

    private final class Live {
        let styler = MarkdownStyler(baseSize: 13)
        let storage: NSTextStorage

        init(_ text: String) {
            storage = NSTextStorage(string: text)
            storage.delegate = styler
            styler.style(storage)
        }

        func replace(_ range: NSRange, with string: String) {
            storage.replaceCharacters(in: range, with: string)
        }
    }

    /// Attributes with fonts reduced to face and size: two font-fallback
    /// instances of the same face (e.g. PingFang for CJK) need not compare
    /// equal as objects even though they render identically.
    private static func comparable(_ attributes: [NSAttributedString.Key: Any]) -> NSDictionary {
        var normalized = attributes
        if let font = normalized[.font] as? NSFont {
            normalized[.font] = "\(font.fontName)@\(font.pointSize)"
        }
        return normalized as NSDictionary
    }

    /// First UTF-16 offset whose attributes differ, for a readable failure.
    private static func firstDifference(_ lhs: NSAttributedString, _ rhs: NSAttributedString) -> String? {
        guard lhs.string == rhs.string else { return "strings differ" }
        let ns = lhs.string as NSString
        for index in 0..<ns.length {
            let left = comparable(lhs.attributes(at: index, effectiveRange: nil))
            let right = comparable(rhs.attributes(at: index, effectiveRange: nil))
            if !left.isEqual(right) {
                let line = ns.lineRange(for: NSRange(location: index, length: 0))
                return "offset \(index) in line \(ns.substring(with: line).debugDescription): \(left) vs \(right)"
            }
        }
        return nil
    }

    private static func expectMatchesFullPass(_ live: Live, _ context: String) {
        let reference = NSTextStorage(string: live.storage.string)
        MarkdownStyler(baseSize: 13).style(reference)
        let difference = firstDifference(live.storage, reference)
        #expect(difference == nil, "\(context): \(difference ?? "")")
    }

    private static func range(of needle: String, in live: Live) -> NSRange {
        (live.storage.string as NSString).range(of: needle)
    }

    @Test("Typing in prose restyles only the edited line")
    func proseEditIsLocal() {
        let long = Array(repeating: Self.fixture, count: 20).joined(separator: "\n\n")
        let live = Live(long)
        let target = Self.range(of: "Quoted line", in: live)

        live.replace(NSRange(location: target.location, length: 0), with: "**new** ")

        let pass = live.styler.lastPass
        #expect(!pass.isFullPass)
        #expect(pass.regionCount == 1)
        #expect(pass.styledLength < 200)
        #expect(pass.documentLength == (live.storage.string as NSString).length)
        Self.expectMatchesFullPass(live, "prose insert")
    }

    @Test("Edits to dependent constructs match a full pass")
    func dependentConstructs() {
        typealias Edit = (name: String, apply: (Live) -> Void)
        let edits: [Edit] = [
            ("open a fence above others", { live in
                let at = Self.range(of: "> Quoted", in: live).location
                live.replace(NSRange(location: at, length: 0), with: "```\n")
            }),
            ("remove it again", { live in
                let at = Self.range(of: "```\n> Quoted", in: live).location
                live.replace(NSRange(location: at, length: 4), with: "")
            }),
            ("type inside the fence", { live in
                let at = Self.range(of: "let x", in: live).location
                live.replace(NSRange(location: at, length: 0), with: "**y** ")
            }),
            ("delete the closing fence", { live in
                let block = Self.range(of: "\"**not bold**\"\n```", in: live)
                live.replace(NSRange(location: NSMaxRange(block) - 3, length: 3), with: "")
            }),
            ("restore the closing fence", { live in
                let at = NSMaxRange(Self.range(of: "\"**not bold**\"\n", in: live))
                live.replace(NSRange(location: at, length: 0), with: "```")
            }),
            ("split a heading line", { live in
                let at = Self.range(of: "Release notes", in: live).location + 7
                live.replace(NSRange(location: at, length: 0), with: "\n")
            }),
            ("join it back", { live in
                let at = Self.range(of: "Release\n", in: live).location + 7
                live.replace(NSRange(location: at, length: 1), with: "")
            }),
            ("break an image", { live in
                let at = Self.range(of: "](https://example.com/diagram", in: live).location
                live.replace(NSRange(location: at, length: 1), with: "")
            }),
            ("repair the image", { live in
                let at = Self.range(of: "(https://example.com/diagram", in: live).location
                live.replace(NSRange(location: at, length: 0), with: "]")
            }),
            ("break a link label", { live in
                let at = Self.range(of: "[link]", in: live).location
                live.replace(NSRange(location: at, length: 1), with: "")
            }),
            ("edit a secret value", { live in
                let at = Self.range(of: "secret*value*", in: live).location
                live.replace(NSRange(location: at, length: 6), with: "s")
            }),
            ("lowercase a secret key", { live in
                let at = Self.range(of: "OTHER_KEY", in: live).location
                live.replace(NSRange(location: at, length: 5), with: "other")
            }),
            ("edit a table cell", { live in
                let at = Self.range(of: "| a    |", in: live).location + 2
                live.replace(NSRange(location: at, length: 0), with: "wide cell")
            }),
            ("nest a task", { live in
                let at = Self.range(of: "- [x] done task", in: live).location
                live.replace(NSRange(location: at, length: 0), with: "    ")
            }),
            ("insert inline code spanning a backtick", { live in
                let at = Self.range(of: "Café", in: live).location
                live.replace(NSRange(location: at, length: 0), with: "`")
            }),
            ("remove the trailing line break structure", { live in
                let at = Self.range(of: "\nLast line", in: live).location
                live.replace(NSRange(location: at, length: 1), with: " ")
            }),
            ("paste a multi-line block", { live in
                let at = Self.range(of: "1. numbered", in: live).location
                live.replace(NSRange(location: at, length: 0), with: "## Pasted\n```\ncode\n```\n![x](https://e.com/x.png)\n")
            }),
            ("delete everything", { live in
                live.replace(NSRange(location: 0, length: (live.storage.string as NSString).length), with: "")
            }),
            ("type into the empty note", { live in
                live.replace(NSRange(location: 0, length: 0), with: Self.fixture)
            }),
        ]

        let live = Live(Self.fixture)
        for edit in edits {
            edit.apply(live)
            Self.expectMatchesFullPass(live, edit.name)
        }
    }

    @Test("Line separators other than LF keep regional styling exact")
    func unusualLineBreaks() {
        let text = "# Title\r\n**bold\rstill bold** and `code`\u{2028}API_KEY=v\r\n```\r\nfence\r\n```\r\ntail"
        let live = Live(text)
        let edits: [(NSRange, String)] = [
            (NSRange(location: 2, length: 0), "x"),
            (NSRange(location: 12, length: 1), ""),
            (NSRange(location: 20, length: 0), "\u{2029}"),
            (NSRange(location: 0, length: 0), "```\n"),
        ]
        for (index, edit) in edits.enumerated() {
            let length = (live.storage.string as NSString).length
            let range = NSRange(location: min(edit.0.location, length), length: min(edit.0.length, length - min(edit.0.location, length)))
            live.replace(range, with: edit.1)
            Self.expectMatchesFullPass(live, "edit \(index)")
        }
    }

    @Test("Image source broken across an escaped line break stays one styled unit")
    func multiLineImage() {
        let live = Live("before\n![alt\\\ntext](https://example.com/a.png)\nafter")
        live.replace(NSRange(location: 7, length: 0), with: "x ")
        Self.expectMatchesFullPass(live, "edit before image")
        let tail = Self.range(of: "after", in: live)
        live.replace(NSRange(location: tail.location, length: 0), with: "**z** ")
        Self.expectMatchesFullPass(live, "edit after image")
    }

    @Test("Randomized edits always match a full pass")
    func randomizedEdits() {
        let snippets = [
            "a", " ", "\n", "#", "# ", "*", "**", "_", "~~", "`", "```", "```\n", "[", "]", "(", ")",
            "![i](https://e.com/i.png)", "[l](https://e.com)", "https://e.com/x.", "KEY=v", "API_KEY=\"x\"",
            "- [ ] t", "- [x] d", "  ", "| c |", "| - |", "> ", "---", "`#fff`", "\\", "é", "東",
        ]
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(max(bound, 1)))
        }

        let live = Live(Self.fixture)
        for step in 0..<400 {
            let length = (live.storage.string as NSString).length
            let location = next(length + 1)
            if next(3) == 0, length > 0 {
                let deleteLength = min(1 + next(12), length - location)
                live.replace(NSRange(location: location, length: deleteLength), with: "")
            } else {
                live.replace(NSRange(location: location, length: 0), with: snippets[next(snippets.count)])
            }
            Self.expectMatchesFullPass(live, "step \(step)")
            if live.storage.string.isEmpty {
                live.replace(NSRange(location: 0, length: 0), with: Self.fixture)
            }
        }
    }

    @Test("Changed-range diff maps unaffected ranges through the edit")
    func changedRangeMapping() {
        let old = [NSRange(location: 0, length: 5), NSRange(location: 20, length: 5), NSRange(location: 40, length: 5)]
        // Insert 3 characters at 10: the later ranges shift and are unchanged.
        let shifted = [NSRange(location: 0, length: 5), NSRange(location: 23, length: 5), NSRange(location: 43, length: 5)]
        #expect(MarkdownStyler.changedRanges(old, shifted, editedRange: NSRange(location: 10, length: 3), delta: 3).isEmpty)

        // A fence that grows by typing inside it is not "changed".
        let grown = [NSRange(location: 0, length: 5), NSRange(location: 20, length: 8), NSRange(location: 43, length: 5)]
        #expect(MarkdownStyler.changedRanges(old, grown, editedRange: NSRange(location: 22, length: 3), delta: 3).isEmpty)

        // Re-pairing produces both the vanished and the new ranges.
        let repaired = [NSRange(location: 0, length: 23)]
        let changed = MarkdownStyler.changedRanges(old, repaired, editedRange: NSRange(location: 10, length: 3), delta: 3)
        #expect(changed.count == 4)
    }
}
