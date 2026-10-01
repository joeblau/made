import AppKit
import Foundation

// Main-thread edit-latency profile for the Notes editor. Built by
// apple/bin/benchmark-notes-editing.sh together with the editor's own sources
// (MarkdownStyler, MultiCursorTextView, EnvMaskController, formatters), so it
// measures the real edit path: insertText, the styler's storage delegate, the
// secret-mask refresh with its gutter/tooltip updates, and the automatic
// task/table reflows, optionally followed by a full layout pass. The view is
// not on screen, so drawing is excluded.
//
// Arguments: [label] [workload name]. A workload name limits the run to the
// long note and that workload.

_ = NSApplication.shared

@MainActor
final class Editor: NSObject, NSTextViewDelegate {
    let styler = MarkdownStyler(baseSize: 13)
    let mask = EnvMaskController()
    let undo = UndoManager()
    let scrollView = MultiCursorTextView.scrollableTextView()
    let textView: MultiCursorTextView

    init(_ text: String) {
        textView = scrollView.documentView as! MultiCursorTextView
        super.init()
        undo.groupsByEvent = false
        scrollView.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        textView.delegate = self
        textView.isRichText = true
        textView.textStorage?.delegate = styler
        mask.textView = textView
        textView.maskController = mask
        textView.layoutManager?.delegate = mask
        textView.string = text
        if let storage = textView.textStorage { styler.style(storage) }
        mask.refresh()
        textView.reorderCompletedTasks()
        textView.formatMarkdownTables(protectingCaret: false)
        // Undo starts with the first measured keystroke, as in a fresh editor.
        textView.allowsUndo = true
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    func textDidChange(_ notification: Notification) {
        mask.refresh()
        textView.applyAutomaticReflows()
    }
}

struct Workload {
    let name: String
    let anchor: String
    let offset: Int
    let typed: String
}

func section(_ index: Int) -> String {
    """
    ## Section \(index)

    Prose with **bold**, *italic*, ~~strike~~, `inline code`, a [link](https://example.com/\(index)) and https://example.org/\(index).
    > A quoted line for section \(index).
    API_TOKEN_\(index)="secret-value-\(index)"
    Accent color `#00FF3F` for section \(index).

    - [ ] open task \(index)
      - [x] finished child \(index)
    - [x] finished task \(index)

    | name | value |
    | --- | --- |
    | row \(index) | \(index) |

    ```swift
    let value\(index) = \(index) // # not a heading
    ```

    ![Diagram \(index)](file:///nonexistent/diagram-\(index).png)

    """
}

func note(sections: Int) -> String {
    (1...sections).map(section).joined(separator: "\n")
}

let workloads = [
    Workload(name: "prose", anchor: "A quoted line for section", offset: 0, typed: "typing in prose "),
    Workload(name: "table cell", anchor: "| row ", offset: 5, typed: "abcdefghijklmnop"),
    Workload(name: "task text", anchor: "open task", offset: 4, typed: "abcdefghijklmnop"),
    Workload(name: "fenced code", anchor: "let value", offset: 9, typed: "abcdefghijklmnop"),
    // Fallback case: a new fence delimiter re-pairs every fence below it.
    Workload(name: "fence delim", anchor: "A quoted line for section", offset: 0, typed: "```"),
]

struct Stats: CustomStringConvertible {
    let samples: [Double]
    var median: Double { samples.sorted()[samples.count / 2] }
    var mean: Double { samples.reduce(0, +) / Double(samples.count) }
    var p95: Double { samples.sorted()[min(samples.count - 1, Int(Double(samples.count) * 0.95))] }
    var description: String {
        String(format: "median %8.3f ms  mean %8.3f ms  p95 %8.3f ms  (n=%d)", median, mean, p95, samples.count)
    }
}

func milliseconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
}

@MainActor
func measure(_ workload: Workload, sections: Int, includeLayout: Bool) -> Stats {
    let editor = Editor(note(sections: sections))
    let ns = editor.textView.string as NSString
    let marker = "## Section \(max(1, sections / 2))\n"
    let sectionStart = ns.range(of: marker).location
    let searchStart = sectionStart == NSNotFound ? 0 : sectionStart
    let anchor = ns.range(of: workload.anchor, range: NSRange(location: searchStart, length: ns.length - searchStart))
    precondition(anchor.location != NSNotFound, "anchor \(workload.anchor) missing")
    var location = anchor.location + workload.offset
    let clock = ContinuousClock()
    if includeLayout, let container = editor.textView.textContainer {
        editor.textView.layoutManager?.ensureLayout(for: container)
    }
    var samples: [Double] = []
    for character in workload.typed {
        let typed = String(character)
        editor.undo.beginUndoGrouping()
        let elapsed = clock.measure {
            editor.textView.setSelectedRange(NSRange(location: location, length: 0))
            editor.textView.insertText(typed, replacementRange: NSRange(location: location, length: 0))
            if includeLayout, let container = editor.textView.textContainer {
                editor.textView.layoutManager?.ensureLayout(for: container)
            }
        }
        editor.undo.endUndoGrouping()
        samples.append(milliseconds(elapsed))
        location = editor.textView.selectedRange().location
    }
    return Stats(samples: samples)
}

/// The Markdown styler alone: a bare text storage with the styler as its
/// delegate, typing into the middle prose line. Isolates styling from the
/// text view, secret mask, overlays, and reflows.
@MainActor
func measureStylerOnly(sections: Int) -> Stats {
    let storage = NSTextStorage(string: note(sections: sections))
    let styler = MarkdownStyler(baseSize: 13)
    storage.delegate = styler
    styler.style(storage)
    let ns = storage.string as NSString
    let sectionStart = ns.range(of: "## Section \(max(1, sections / 2))\n").location
    var location = ns.range(
        of: "A quoted line for section",
        range: NSRange(location: sectionStart, length: ns.length - sectionStart)
    ).location
    let clock = ContinuousClock()
    var samples: [Double] = []
    for character in "typing in prose " {
        let elapsed = clock.measure {
            storage.replaceCharacters(in: NSRange(location: location, length: 0), with: String(character))
        }
        samples.append(milliseconds(elapsed))
        location += 1
    }
    return Stats(samples: samples)
}

@MainActor
func run() {
    let label = CommandLine.arguments.dropFirst().first ?? "build"
    print("Notes edit latency — \(label)")
    let only = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
    let notes = [("small (1 section)", 1), ("long (120 sections)", 120)]
    for (name, sections) in notes where only == nil || sections == 120 {
        let length = (note(sections: sections) as NSString).length
        print("\(name): \(length) UTF-16 units")
        if only == nil || only == "styler" {
            _ = measureStylerOnly(sections: sections)
            print("  styler only  prose        \(measureStylerOnly(sections: sections))")
        }
        for includeLayout in [false, true] {
            for workload in workloads where only == nil || workload.name == only {
                _ = measure(workload, sections: sections, includeLayout: includeLayout)
                let stats = measure(workload, sections: sections, includeLayout: includeLayout)
                let mode = includeLayout ? "edit+layout" : "edit       "
                print("  \(mode)  \(workload.name.padding(toLength: 12, withPad: " ", startingAt: 0)) \(stats)")
            }
        }
    }
}

MainActor.assumeIsolated { run() }
