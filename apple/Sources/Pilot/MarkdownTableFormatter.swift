import Foundation

/// Reflows GitHub-flavored markdown tables so every column is padded to the
/// width of its widest cell and the pipes line up (issue #79). Pure and
/// idempotent: running it on already-formatted text returns `nil` (no change),
/// which is what keeps the editor's on-edit reflow from churning.
enum MarkdownTableFormatter {

    /// Returns the text with every GFM table block reflowed, or `nil` if nothing
    /// changed. Blocks containing any line index in `skipLines` are left as-is
    /// (used to avoid reformatting the table the caret is inside while typing).
    static func reflow(_ text: String, skipLines: Set<Int> = []) -> String? {
        reflowReportingSkipped(text, skipLines: skipLines).text
    }

    /// `reflow`, plus whether a block left alone because of `skipLines` still
    /// needs formatting. The editor keeps such a table pending so it aligns
    /// on the next edit once the caret has left it.
    static func reflowReportingSkipped(
        _ text: String,
        skipLines: Set<Int> = []
    ) -> (text: String?, skippedBlockNeedsFormatting: Bool) {
        // A table needs a pipe somewhere, so skip the full line-split for the
        // common case of a note with none.
        guard text.contains("|") else { return (nil, false) }
        var lines = text.components(separatedBy: "\n")
        var changed = false
        var skippedBlockNeedsFormatting = false
        var i = 0
        while i < lines.count {
            guard let block = tableBlock(in: lines, startingAt: i) else {
                i += 1
                continue
            }
            let original = Array(lines[block])
            let formatted = formatBlock(original)
            if formatted != original {
                if block.contains(where: { skipLines.contains($0) }) {
                    skippedBlockNeedsFormatting = true
                } else {
                    lines.replaceSubrange(block, with: formatted)
                    changed = true
                }
            }
            i = block.upperBound
        }
        return (changed ? lines.joined(separator: "\n") : nil, skippedBlockNeedsFormatting)
    }

    // MARK: - Block detection

    /// A GFM table is a pipe row immediately followed by a delimiter row, then
    /// zero or more pipe (body) rows. Returns the half-open line range, or nil.
    private static func tableBlock(in lines: [String], startingAt i: Int) -> Range<Int>? {
        guard i + 1 < lines.count,
              isPipeRow(lines[i]),
              !isDelimiterRow(lines[i]),
              isDelimiterRow(lines[i + 1]) else { return nil }
        var end = i + 2
        while end < lines.count, isPipeRow(lines[end]), !isDelimiterRow(lines[end]) {
            end += 1
        }
        return i..<end
    }

    private static func isPipeRow(_ line: String) -> Bool {
        line.contains("|")
    }

    /// A delimiter row is all cells of the form `:?-+:?` (e.g. `---`, `:--`,
    /// `:-:`, `--:`) with at least one dash overall. It must contain a pipe:
    /// a bare `---` is a thematic break (horizontal rule), not a table delimiter,
    /// and treating it as one would swallow the line above and overwrite the rule
    /// itself when the block is reflowed (issue: notes lines vanish after Return).
    private static func isDelimiterRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") else {
            return false
        }
        let cells = cells(of: line)
        guard !cells.isEmpty else { return false }
        for cell in cells {
            let c = cell.trimmingCharacters(in: .whitespaces)
            guard !c.isEmpty, c.contains("-") else { return false }
            if !c.allSatisfy({ $0 == "-" || $0 == ":" }) { return false }
        }
        return true
    }

    // MARK: - Formatting

    private enum Alignment { case none, left, center, right }

    private static func formatBlock(_ rows: [String]) -> [String] {
        guard rows.count >= 2 else { return rows }

        let header = cells(of: rows[0])
        let delimiterCells = cells(of: rows[1])
        let body = rows.dropFirst(2).map { cells(of: $0) }

        let columnCount = max(header.count, delimiterCells.count,
                              body.map(\.count).max() ?? 0)

        let alignments: [Alignment] = (0..<columnCount).map { c in
            c < delimiterCells.count ? alignment(of: delimiterCells[c]) : .none
        }

        // Column width = widest content cell, but at least 3 so the delimiter
        // (and its alignment colons) renders sanely.
        var widths = [Int](repeating: 3, count: columnCount)
        for row in [header] + Array(body) {
            for c in 0..<columnCount {
                let cell = c < row.count ? row[c] : ""
                widths[c] = max(widths[c], displayWidth(cell))
            }
        }

        var out: [String] = []
        out.append(render(header, widths: widths, alignments: alignments))
        out.append(renderDelimiter(widths: widths, alignments: alignments))
        for row in body {
            out.append(render(row, widths: widths, alignments: alignments))
        }
        return out
    }

    private static func alignment(of delimiterCell: String) -> Alignment {
        let c = delimiterCell.trimmingCharacters(in: .whitespaces)
        let left = c.hasPrefix(":")
        let right = c.hasSuffix(":")
        switch (left, right) {
        case (true, true): return .center
        case (true, false): return .left
        case (false, true): return .right
        case (false, false): return .none
        }
    }

    private static func render(_ row: [String], widths: [Int], alignments: [Alignment]) -> String {
        var cells: [String] = []
        for c in 0..<widths.count {
            let text = c < row.count ? row[c] : ""
            cells.append(pad(text, to: widths[c], alignment: alignments[c]))
        }
        return "| " + cells.joined(separator: " | ") + " |"
    }

    private static func renderDelimiter(widths: [Int], alignments: [Alignment]) -> String {
        let cells = widths.indices.map { c -> String in
            let w = widths[c]
            switch alignments[c] {
            case .none: return String(repeating: "-", count: w)
            case .left: return ":" + String(repeating: "-", count: w - 1)
            case .right: return String(repeating: "-", count: w - 1) + ":"
            case .center: return ":" + String(repeating: "-", count: w - 2) + ":"
            }
        }
        return "| " + cells.joined(separator: " | ") + " |"
    }

    private static func pad(_ text: String, to width: Int, alignment: Alignment) -> String {
        let deficit = max(0, width - displayWidth(text))
        switch alignment {
        case .none, .left:
            return text + String(repeating: " ", count: deficit)
        case .right:
            return String(repeating: " ", count: deficit) + text
        case .center:
            let leftPad = deficit / 2
            return String(repeating: " ", count: leftPad) + text
                + String(repeating: " ", count: deficit - leftPad)
        }
    }

    // MARK: - Cell parsing

    /// Splits a row into trimmed cells, dropping one optional leading/trailing
    /// pipe and respecting `\|` escapes (the backslash is kept so the escape
    /// survives a round-trip).
    private static func cells(of row: String) -> [String] {
        var trimmed = row.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }

        var result: [String] = []
        var current = ""
        var escaped = false
        for ch in trimmed {
            if escaped {
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                current.append(ch)
                escaped = true
            } else if ch == "|" {
                result.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        result.append(current)
        return result.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Display width

    /// Monospaced display width: East Asian wide characters and emoji occupy two
    /// cells, everything else one. Approximate but covers the cases that throw
    /// off pipe alignment in the editor.
    private static func displayWidth(_ s: String) -> Int {
        s.reduce(0) { $0 + ($1.unicodeScalars.contains(where: isWide) ? 2 : 1) }
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F,    // Hangul Jamo
             0x2E80...0x303E,    // CJK radicals, Kangxi
             0x3041...0x33FF,    // Hiragana, Katakana, CJK symbols/punctuation
             0x3400...0x4DBF,    // CJK Unified Ext A
             0x4E00...0x9FFF,    // CJK Unified
             0xA000...0xA4CF,    // Yi
             0xAC00...0xD7A3,    // Hangul Syllables
             0xF900...0xFAFF,    // CJK Compatibility Ideographs
             0xFE30...0xFE4F,    // CJK Compatibility Forms
             0xFF00...0xFF60,    // Fullwidth Forms
             0xFFE0...0xFFE6,    // Fullwidth signs
             0x1F300...0x1FAFF,  // Emoji & pictographs
             0x20000...0x3FFFD:  // CJK Unified Ext B+
            return true
        default:
            return false
        }
    }
}

/// Stable-sorts root checklist items by completion while treating every
/// indented descendant as part of its root item. This keeps nested checklists
/// structurally intact when the editor reflows completed work.
enum MarkdownTaskFormatter {
    private struct TaskLine {
        let text: String
        let indentation: Int
        let isDone: Bool
    }

    private static let taskLine = try! NSRegularExpression(
        pattern: #"^([ \t]*)[-*+][ \t]+\[([ xX])\]"#
    )

    /// Returns reordered text, or `nil` when the checklist is already settled.
    static func reflow(_ text: String) -> String? {
        // Runs on every keystroke, so avoid splitting ordinary notes.
        guard text.contains("[x]") || text.contains("[X]") else { return nil }

        var lines = text.components(separatedBy: "\n")
        var changed = false
        var index = 0

        while index < lines.count {
            guard parse(lines[index]) != nil else {
                index += 1
                continue
            }

            var end = index
            var group: [TaskLine] = []
            while end < lines.count, let task = parse(lines[end]) {
                group.append(task)
                end += 1
            }

            let baseline = group.map(\.indentation).min() ?? 0
            var blocks: [[TaskLine]] = []
            for task in group {
                if task.indentation == baseline || blocks.isEmpty {
                    blocks.append([task])
                } else {
                    blocks[blocks.endIndex - 1].append(task)
                }
            }

            let sortedBlocks = blocks.filter { !$0[0].isDone } + blocks.filter { $0[0].isDone }
            let sortedLines = sortedBlocks.flatMap { $0.map(\.text) }
            if sortedLines != Array(lines[index..<end]) {
                lines.replaceSubrange(index..<end, with: sortedLines)
                changed = true
            }
            index = end
        }

        return changed ? lines.joined(separator: "\n") : nil
    }

    private static func parse(_ line: String) -> TaskLine? {
        let range = NSRange(location: 0, length: (line as NSString).length)
        guard let match = taskLine.firstMatch(in: line, range: range) else { return nil }
        let markerRange = match.range(at: 2)
        guard markerRange.location != NSNotFound else { return nil }
        let marker = (line as NSString).substring(with: markerRange)
        return TaskLine(
            text: line,
            indentation: match.range(at: 1).length,
            isDone: marker.lowercased() == "x"
        )
    }
}
