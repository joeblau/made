import AppKit

/// `NSTextView` subclass behind the Notes editor. It adds ⇧⌘L "split
/// selection into lines" — the Sublime/VS Code multi-cursor gesture, which
/// requests a collapsed insertion point at the end of the selected content on
/// each line the selection touches (see `lineEndCarets(for:in:)`). `NSTextView`
/// decides how many of those zero-length ranges it keeps; current AppKit keeps
/// only the first, so typing lands at that caret — plus click handling for
/// links, masked secrets, and task checkboxes, and the automatic task/table
/// reflows. Floating gutter buttons, color swatches, and image previews are
/// owned by `NoteEditorOverlays`.
final class MultiCursorTextView: NSTextView, NSViewToolTipOwner {
    weak var maskController: EnvMaskController?
    var onCopySecret: (() -> Void)?
    /// Set while a reflow replaces the text, so the `textDidChange` it emits
    /// cannot start another reflow.
    private var isReflowing = false
    private lazy var overlays = NoteEditorOverlays(textView: self)
    /// Reflows the edits since the last pass could affect, as recorded by
    /// `shouldChangeText`. `nil` means no edit was recorded (an edit path that
    /// bypassed it), so the next pass checks everything.
    private var pendingReflowScope: ReflowScope?
    /// Reflows owed wherever the next edit lands: a table left unaligned
    /// because the caret was inside it, or text replaced wholesale.
    private var carriedReflowScope: ReflowScope = .all

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
            carriedReflowScope = .all
        }
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) else {
            return false
        }
        recordReflowScope(for: [affectedCharRange], replacements: replacementString.map { [$0] })
        return true
    }

    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        guard super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings) else {
            return false
        }
        recordReflowScope(for: affectedRanges.map(\.rangeValue), replacements: replacementStrings)
        return true
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

    struct ReflowScope: OptionSet, Sendable {
        let rawValue: Int
        static let tasks = ReflowScope(rawValue: 1 << 0)
        static let tables = ReflowScope(rawValue: 1 << 1)
        static let all: ReflowScope = [.tasks, .tables]
    }

    /// Which reflows replacing `range` of `text` with `replacement` could
    /// change. Task groups and table blocks are runs of adjacent lines, so an
    /// edit can only alter the runs it touches or borders: the edited lines
    /// plus one neighbor on each side. A task line needs `[` and a table row
    /// needs `|`; if neither the old context nor the replacement has one,
    /// neither does the new context.
    nonisolated static func reflowScope(of range: NSRange, replacement: String, in text: NSString) -> ReflowScope {
        var context = text.newlineDelimitedLines(covering: range)
        if context.location > 0 {
            context = NSUnionRange(
                context,
                text.newlineDelimitedLines(covering: NSRange(location: context.location - 1, length: 0))
            )
        }
        if NSMaxRange(context) < text.length {
            context = NSUnionRange(
                context,
                text.newlineDelimitedLines(covering: NSRange(location: NSMaxRange(context), length: 0))
            )
        }
        func mentions(_ marker: String) -> Bool {
            replacement.contains(marker)
                || text.range(of: marker, options: .literal, range: context).location != NSNotFound
        }
        var scope: ReflowScope = []
        if mentions("[") { scope.insert(.tasks) }
        if mentions("|") { scope.insert(.tables) }
        return scope
    }

    private func recordReflowScope(for ranges: [NSRange], replacements: [String]?) {
        guard !isReflowing else { return }
        let ns = string as NSString
        var scope = pendingReflowScope ?? []
        for (index, range) in ranges.enumerated() where scope != .all {
            guard NSMaxRange(range) <= ns.length else {
                scope = .all
                break
            }
            let replacement = replacements.flatMap { index < $0.count ? $0[index] : nil } ?? ""
            scope.formUnion(Self.reflowScope(of: range, replacement: replacement, in: ns))
        }
        pendingReflowScope = scope
    }

    /// Runs the per-edit automatic formatting: completed tasks sink, then
    /// tables align (skipping the table under the caret). Only the reflows
    /// the recorded edits could affect run, so ordinary typing away from
    /// tasks and tables doesn't re-scan the note.
    func applyAutomaticReflows() {
        guard !isReflowing else { return }
        // Undo/redo replay, or an IME composition still in progress: rewriting
        // the text now would land under the replayed edits or break the marked
        // text. The recorded scope stays pending for the next edit.
        if let undoManager, undoManager.isUndoing || undoManager.isRedoing { return }
        if hasMarkedText() { return }

        let scope = (pendingReflowScope ?? .all).union(carriedReflowScope)
        pendingReflowScope = nil
        carriedReflowScope = []
        var tasksChanged = false
        if scope.contains(.tasks) {
            tasksChanged = reorderCompletedTasks()
        }
        if scope.contains(.tables) || tasksChanged {
            formatMarkdownTables()
        }
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
        var skippedTableNeedsFormatting = false
        let changed = applyReflow { text in
            let skip: Set<Int> = protectingCaret ? caretLineIndices() : []
            let result = MarkdownTableFormatter.reflowReportingSkipped(text, skipLines: skip)
            skippedTableNeedsFormatting = result.skippedBlockNeedsFormatting
            return result.text
        }
        if skippedTableNeedsFormatting { carriedReflowScope.insert(.tables) }
        // A reformatted row can stop being a task line; re-check tasks next edit.
        if changed { carriedReflowScope.insert(.tasks) }
        return changed
    }

    /// The one application path for whole-document reflows. `transform` is a
    /// pure formatter returning `nil` when the text is already settled. Only
    /// the span that differs is replaced, through `shouldChangeText` /
    /// `didChangeText`, so it is registered for undo, restyled, and pushed to
    /// the binding like any edit while the styler and undo record cover just
    /// that span. `isReflowing` keeps the resulting `textDidChange` from
    /// re-entering, and the caret follows its line to the new position.
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
        let span = Self.changedSpan(from: ns, to: newText as NSString)
        let replacement = (newText as NSString).substring(with: span.new)
        isReflowing = true
        let applied = shouldChangeText(in: span.old, replacementString: replacement)
        if applied {
            textStorage.replaceCharacters(in: span.old, with: replacement)
            didChangeText()
        }
        isReflowing = false
        guard applied else { return false }

        setSelectedRange(NSRange(location: anchor.location(in: newText), length: 0))
        return true
    }

    /// The smallest differing span between two texts: the range to replace
    /// in `old` and the matching range of `new`, never splitting a UTF-16
    /// surrogate pair.
    nonisolated static func changedSpan(from old: NSString, to new: NSString) -> (old: NSRange, new: NSRange) {
        let oldLength = old.length
        let newLength = new.length
        var oldUnits = [unichar](repeating: 0, count: oldLength)
        var newUnits = [unichar](repeating: 0, count: newLength)
        old.getCharacters(&oldUnits, range: NSRange(location: 0, length: oldLength))
        new.getCharacters(&newUnits, range: NSRange(location: 0, length: newLength))

        let limit = min(oldLength, newLength)
        var prefix = 0
        while prefix < limit, oldUnits[prefix] == newUnits[prefix] { prefix += 1 }
        if prefix > 0, UTF16.isLeadSurrogate(oldUnits[prefix - 1]) {
            prefix -= 1
        }
        var suffix = 0
        while suffix < limit - prefix,
              oldUnits[oldLength - 1 - suffix] == newUnits[newLength - 1 - suffix] {
            suffix += 1
        }
        if suffix > 0, UTF16.isTrailSurrogate(oldUnits[oldLength - suffix]) {
            suffix -= 1
        }
        return (
            NSRange(location: prefix, length: oldLength - prefix - suffix),
            NSRange(location: prefix, length: newLength - prefix - suffix)
        )
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

    /// Number of `\n` before `location` — the formatter's line numbering.
    private func lineIndex(at location: Int, in ns: NSString) -> Int {
        let end = min(location, ns.length)
        var count = 0
        var searchStart = 0
        while searchStart < end {
            let newline = ns.range(of: "\n", options: .literal,
                                   range: NSRange(location: searchStart, length: end - searchStart))
            guard newline.location != NSNotFound else { break }
            count += 1
            searchStart = newline.location + 1
        }
        return count
    }

    // MARK: - Multi-cursor

    private func splitSelectionIntoLines() {
        let carets = Self.lineEndCarets(for: selectedRanges.map(\.rangeValue), in: string as NSString)
        guard !carets.isEmpty else { return }
        selectedRanges = carets.map { NSValue(range: $0) }
    }

    /// The carets ⇧⌘L requests: one collapsed insertion point at the end of
    /// the selected content on every line each selection touches, sorted and
    /// de-duplicated as `NSTextView` requires. A bare caret is kept as-is so
    /// pre-existing multi-cursor state survives. Lines end at any line
    /// terminator, and CRLF counts as one terminator.
    nonisolated static func lineEndCarets(for selections: [NSRange], in text: NSString) -> [NSRange] {
        var cursors: [NSRange] = []
        for selection in selections {
            guard selection.length > 0 else {
                cursors.append(selection)
                continue
            }
            let selectionEnd = min(NSMaxRange(selection), text.length)
            var lineStart = min(selection.location, text.length)
            while lineStart < selectionEnd {
                var lineEnd = 0
                var contentsEnd = 0
                text.getLineStart(
                    nil, end: &lineEnd, contentsEnd: &contentsEnd,
                    for: NSRange(location: lineStart, length: 0)
                )
                cursors.append(NSRange(location: min(max(contentsEnd, lineStart), selectionEnd), length: 0))
                guard lineEnd > lineStart else { break }
                lineStart = lineEnd
            }
        }
        return cursors
            .sorted { $0.location < $1.location }
            .reduce(into: [NSRange]()) { result, range in
                if result.last?.location != range.location { result.append(range) }
            }
    }
}
