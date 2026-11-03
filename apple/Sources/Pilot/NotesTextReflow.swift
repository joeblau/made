import AppKit

extension MultiCursorTextView {
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

    func recordReflowScope(for ranges: [NSRange], replacements: [String]?) {
        guard !isReflowing else { return }
        let ns = string as NSString
        var scope = pendingReflowScope ?? []
        var editedRanges = pendingReflowScope == nil ? [] : pendingReflowRanges
        var offset = 0
        for (index, range) in ranges.enumerated() {
            guard NSMaxRange(range) <= ns.length else {
                scope = .all
                editedRanges = nil
                break
            }
            let replacement = replacements.flatMap { index < $0.count ? $0[index] : nil } ?? ""
            if editedRanges != nil {
                editedRanges?.append(NSRange(
                    location: range.location + offset,
                    length: (replacement as NSString).length
                ))
            }
            offset += (replacement as NSString).length - range.length
            scope.formUnion(Self.reflowScope(of: range, replacement: replacement, in: ns))
        }
        pendingReflowScope = scope
        pendingReflowRanges = editedRanges
    }

    /// Runs the per-edit automatic formatting: completed tasks sink, then
    /// tables align (skipping the table under the caret). Only the groups the
    /// recorded edits could affect are formatted. Unknown edit paths, carried
    /// deferred work, and task movement conservatively use a whole-note pass.
    func applyAutomaticReflows() {
        guard !isReflowing else { return }
        // Undo/redo replay, or an IME composition still in progress: rewriting
        // the text now would land under the replayed edits or break the marked
        // text. The recorded scope stays pending for the next edit.
        if let undoManager, undoManager.isUndoing || undoManager.isRedoing { return }
        if hasMarkedText() { return }

        let scope = (pendingReflowScope ?? .all).union(carriedReflowScope)
        let editedRanges = carriedReflowScope.isEmpty ? pendingReflowRanges : nil
        pendingReflowScope = nil
        pendingReflowRanges = nil
        carriedReflowScope = []
        var tasksChanged = false
        if scope.contains(.tasks) {
            tasksChanged = reorderCompletedTasks(touching: editedRanges)
        }
        if scope.contains(.tables) || tasksChanged {
            formatMarkdownTables(touching: tasksChanged ? nil : editedRanges)
        }
    }

    /// Settles all initial content and clears the whole-document fallback set
    /// by assigning `string`, so the first keystroke can use regional reflows.
    func settleAutomaticReflows() {
        reorderCompletedTasks()
        formatMarkdownTables(protectingCaret: false)
        pendingReflowScope = nil
        pendingReflowRanges = nil
        carriedReflowScope = []
    }

    /// Auto-sort every contiguous task group so incomplete root tasks stay on
    /// top and completed roots sink to the bottom. Indented subtasks move with
    /// their root as one block, so checking a child never detaches or reorders
    /// it. A no-op unless some group is actually out of order.
    @discardableResult
    func reorderCompletedTasks(touching ranges: [NSRange]? = nil) -> Bool {
        applyReflow { MarkdownTaskFormatter.reflow($0, touching: ranges) }
    }

    /// Align markdown tables to fit their content (issue #79). When
    /// `protectingCaret` is true the table block the caret sits in is left
    /// alone, so alignment never fights the cursor while you're typing inside
    /// a cell. Optional ranges limit the pass to touched table blocks.
    @discardableResult
    func formatMarkdownTables(protectingCaret: Bool = true, touching ranges: [NSRange]? = nil) -> Bool {
        // A table needs a pipe somewhere; checking before the caret-line scan
        // (not just inside `reflow`) keeps pipe-free notes allocation-free on
        // every keystroke.
        guard string.contains("|") else { return false }

        var skippedTableNeedsFormatting = false
        let changed = applyReflow { text in
            let skip: Set<Int> = protectingCaret ? caretLineIndices() : []
            let result = MarkdownTableFormatter.reflowReportingSkipped(
                text, skipLines: skip, touching: ranges
            )
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
            let end = r.length == 0
                ? start
                : lineIndex(at: min(r.location + r.length, ns.length), in: ns)
            for i in start...end { indices.insert(i) }
        }
        return indices
    }

    /// Newlines before `location`, counted over the raw UTF-16 units. This runs
    /// per keystroke (via `formatMarkdownTables`), so it must not materialize a
    /// prefix substring and walk it grapheme-by-grapheme like
    /// `substring(to:).reduce` did — O(doc) allocation per call.
    private func lineIndex(at location: Int, in ns: NSString) -> Int {
        let length = min(location, ns.length)
        guard length > 0 else { return 0 }
        var buffer = [unichar](repeating: 0, count: length)
        ns.getCharacters(&buffer, range: NSRange(location: 0, length: length))
        var newlines = 0
        for unit in buffer where unit == 0x0A { newlines += 1 }
        return newlines
    }
}
