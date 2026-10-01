import AppKit

/// `NSTextView` subclass behind the Notes editor. It adds ⇧⌘L "split
/// selection into lines" — the Sublime/VS Code multi-cursor gesture, where
/// each line touched by the selection gets a collapsed insertion point at the
/// end of its selected content and `NSTextView` then types into all of them —
/// plus click handling for links, masked secrets, and task checkboxes, and the
/// automatic task/table reflows. Floating gutter buttons, color swatches, and
/// image previews are owned by `NoteEditorOverlays`.
final class MultiCursorTextView: NSTextView, NSViewToolTipOwner {
    weak var maskController: EnvMaskController?
    var onCopySecret: (() -> Void)?
    /// Set while a reflow replaces the text, so the `textDidChange` it emits
    /// cannot start another reflow.
    private var isReflowing = false
    private lazy var overlays = NoteEditorOverlays(textView: self)

    /// Keep the editable storage plaintext while exposing the controller's
    /// redacted presentation to assistive technologies. Calling
    /// `setAccessibilityValue` on NSTextView edits the document and emits
    /// `textDidChange`, so masking must be implemented as a getter only.
    override func accessibilityValue() -> String? {
        maskController?.accessibilityText ?? super.accessibilityValue()
    }

    override func didChangeText() {
        super.didChangeText()
        overlays.invalidateTextScans()
    }

    override var string: String {
        get { super.string }
        set {
            super.string = newValue
            overlays.invalidateTextScans()
        }
    }

    override func layout() {
        super.layout()
        overlays.layout()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "l" {
            splitSelectionIntoLines()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Clicking the hover lock toggles a secret's visibility; clicking a masked
    /// `.env` value copies it; clicking a `[ ]` / `[x]` toggles it. Any other
    /// click behaves normally.
    override func mouseDown(with event: NSEvent) {
        if openLink(at: event) { return }
        if copySecret(at: event) { return }
        if toggleTaskCheckbox(at: event) { return }
        super.mouseDown(with: event)
    }

    private func containerPoint(for event: NSEvent) -> NSPoint {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        return NSPoint(x: viewPoint.x - origin.x, y: viewPoint.y - origin.y)
    }

    /// Single-click on a link (bare URL or markdown link) opens it in the
    /// user's default browser via NSWorkspace.
    private func openLink(at event: NSEvent) -> Bool {
        guard event.clickCount == 1, let layoutManager, let textContainer, let textStorage else { return false }
        let ns = string as NSString
        guard ns.length > 0 else { return false }

        let containerPoint = containerPoint(for: event)
        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(
            for: containerPoint, in: textContainer, fractionOfDistanceThroughGlyph: &fraction
        )
        // Ignore clicks past the end of the line's text (in the trailing margin).
        let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        guard containerPoint.x <= used.maxX else { return false }

        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < ns.length,
              let value = textStorage.attribute(.link, at: charIndex, effectiveRange: nil) else { return false }
        let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
        guard let url else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    // MARK: - Env secret copy + hover affordances

    /// View-space rects of the currently masked secret values.
    private func secretRects() -> [NSRect] {
        guard let maskController, let layoutManager, let textContainer else { return [] }
        let origin = textContainerOrigin
        return maskController.maskedRanges.compactMap { range in
            guard NSMaxRange(range) <= (string as NSString).length else { return nil }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            rect.origin.x += origin.x
            rect.origin.y += origin.y
            return rect
        }
    }

    /// Refresh the pointing-hand cursor rects and "Click to copy" tooltips over
    /// the masked secrets. Called by `EnvMaskController` when the set changes.
    func updateSecretAffordances() {
        removeAllToolTips()
        for rect in secretRects() {
            addToolTip(rect, owner: self, userData: nil)
        }
        window?.invalidateCursorRects(for: self)
        overlays.refreshGutterAndColorChips()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for rect in secretRects() {
            addCursorRect(rect, cursor: .pointingHand)
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
              point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        "Click to copy"
    }

    private func copySecret(at event: NSEvent) -> Bool {
        guard let maskController, !maskController.maskedRanges.isEmpty,
              let layoutManager, let textContainer else { return false }
        let ns = string as NSString
        let containerPoint = containerPoint(for: event)

        for range in maskController.maskedRanges {
            guard NSMaxRange(range) <= ns.length else { continue }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
                .insetBy(dx: -3, dy: -2)
            guard rect.contains(containerPoint) else { continue }

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(ns.substring(with: range), forType: .string)
            onCopySecret?()
            return true
        }
        return false
    }

    // MARK: - Task checkboxes

    private static let taskCheckbox = try! NSRegularExpression(
        pattern: #"^[ \t]*[-*+][ \t]+(\[[ xX]\])"#
    )

    private func toggleTaskCheckbox(at event: NSEvent) -> Bool {
        guard let layoutManager, let textContainer, let textStorage else { return false }
        let ns = string as NSString
        guard ns.length > 0 else { return false }

        let containerPoint = containerPoint(for: event)
        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(
            for: containerPoint, in: textContainer, fractionOfDistanceThroughGlyph: &fraction
        )
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < ns.length else { return false }

        // Find a checkbox on the clicked line.
        let lineRange = ns.lineRange(for: NSRange(location: charIndex, length: 0))
        let line = ns.substring(with: lineRange)
        let lineNSRange = NSRange(location: 0, length: (line as NSString).length)
        guard let match = Self.taskCheckbox.firstMatch(in: line, range: lineNSRange) else {
            return false
        }
        let boxInLine = match.range(at: 1)
        guard boxInLine.location != NSNotFound else { return false }
        let boxRange = NSRange(location: lineRange.location + boxInLine.location, length: boxInLine.length)

        // Only toggle if the click actually landed on the checkbox glyphs.
        let boxGlyphs = layoutManager.glyphRange(forCharacterRange: boxRange, actualCharacterRange: nil)
        let boxRect = layoutManager.boundingRect(forGlyphRange: boxGlyphs, in: textContainer)
            .insetBy(dx: -4, dy: -2)
        guard boxRect.contains(containerPoint) else { return false }

        // Flip the mark character ([ ] <-> [x]) through the normal edit path
        // so undo, re-styling, and the binding/save all fire.
        let markRange = NSRange(location: boxRange.location + 1, length: 1)
        let current = ns.substring(with: markRange)
        let replacement = current.lowercased() == "x" ? " " : "x"
        guard shouldChangeText(in: markRange, replacementString: replacement) else { return false }
        textStorage.replaceCharacters(in: markRange, with: replacement)
        didChangeText()
        return true
    }

    // MARK: - Automatic reflows

    /// Runs the per-edit automatic formatting: completed tasks sink, then
    /// tables align (skipping the table under the caret).
    func applyAutomaticReflows() {
        reorderCompletedTasks()
        formatMarkdownTables()
    }

    /// Auto-sort every contiguous task group so incomplete root tasks stay on
    /// top and completed roots sink to the bottom. Indented subtasks move with
    /// their root as one block, so checking a child never detaches or reorders
    /// it. A no-op unless some group is actually out of order.
    @discardableResult
    func reorderCompletedTasks() -> Bool {
        applyReflow { MarkdownTaskFormatter.reflow($0) }
    }

    /// Align markdown tables to fit their content (issue #79). When
    /// `protectingCaret` is true the table block the caret sits in is left
    /// alone, so alignment never fights the cursor while you're typing inside
    /// a cell.
    @discardableResult
    func formatMarkdownTables(protectingCaret: Bool = true) -> Bool {
        applyReflow { text in
            let skip: Set<Int> = protectingCaret ? caretLineIndices() : []
            return MarkdownTableFormatter.reflow(text, skipLines: skip)
        }
    }

    /// The one application path for whole-document reflows. `transform` is a
    /// pure formatter returning `nil` when the text is already settled. A
    /// change goes through `shouldChangeText`/`didChangeText`, so it is
    /// registered for undo, restyled, and pushed to the binding like any edit;
    /// `isReflowing` keeps the resulting `textDidChange` from re-entering, and
    /// the caret follows its line to the new position.
    ///
    /// Undo and redo replay recorded edits one at a time, each posting
    /// `textDidChange`. Reflowing in between would rewrite the text under the
    /// remaining recorded edits (whose ranges then land on the wrong lines),
    /// so reflows stand down until the replay finishes. The replayed state is
    /// one the user already saw, already formatted.
    private func applyReflow(_ transform: (String) -> String?) -> Bool {
        guard !isReflowing, let textStorage else { return false }
        if let undoManager, undoManager.isUndoing || undoManager.isRedoing { return false }
        let ns = string as NSString
        guard ns.length > 0, let newText = transform(string) else { return false }

        let anchor = NoteCaretAnchor(selection: selectedRange(), in: ns)
        let full = NSRange(location: 0, length: ns.length)
        isReflowing = true
        let applied = shouldChangeText(in: full, replacementString: newText)
        if applied {
            textStorage.replaceCharacters(in: full, with: newText)
            didChangeText()
        }
        isReflowing = false
        guard applied else { return false }

        setSelectedRange(NSRange(location: anchor.location(in: newText), length: 0))
        return true
    }

    /// 0-based line indices touched by any selection/caret, so the table block
    /// the user is editing can be skipped during reflow.
    private func caretLineIndices() -> Set<Int> {
        let ns = string as NSString
        var indices: Set<Int> = []
        for value in selectedRanges {
            let r = value.rangeValue
            let start = lineIndex(at: min(r.location, ns.length), in: ns)
            let end = lineIndex(at: min(r.location + r.length, ns.length), in: ns)
            for i in start...end { indices.insert(i) }
        }
        return indices
    }

    private func lineIndex(at location: Int, in ns: NSString) -> Int {
        guard location > 0 else { return 0 }
        return ns.substring(to: min(location, ns.length)).reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
    }

    // MARK: - Multi-cursor

    private func splitSelectionIntoLines() {
        let ns = string as NSString
        var cursors: [NSRange] = []

        for value in selectedRanges {
            let selection = value.rangeValue

            // A bare caret (no selected text) stays as-is — there's nothing
            // to split, but we preserve any pre-existing multi-cursor state.
            guard selection.length > 0 else {
                cursors.append(selection)
                continue
            }

            let selectionEnd = selection.location + selection.length
            var lineStart = selection.location
            while lineStart < selectionEnd {
                let searchRange = NSRange(location: lineStart, length: selectionEnd - lineStart)
                let newline = ns.rangeOfCharacter(from: .newlines, options: [], range: searchRange)
                let lineEnd = newline.location == NSNotFound ? selectionEnd : newline.location
                cursors.append(NSRange(location: lineEnd, length: 0))
                if newline.location == NSNotFound { break }
                lineStart = newline.location + newline.length
            }
        }

        // `NSTextView` requires sorted, de-duplicated ranges.
        let sorted = cursors
            .sorted { $0.location < $1.location }
            .reduce(into: [NSRange]()) { result, range in
                if result.last?.location != range.location { result.append(range) }
            }

        guard !sorted.isEmpty else { return }
        selectedRanges = sorted.map { NSValue(range: $0) }
    }
}
