import Foundation

/// A caret position expressed as "column N on the line whose text is L", so
/// the caret can follow its line when a whole-document reflow (task sorting,
/// table alignment) moves or rewrites lines around it.
struct NoteCaretAnchor: Equatable {
    /// Text of the caret's line, without its line terminator.
    let lineText: String
    /// UTF-16 offset of the caret from the start of that line.
    let column: Int
    /// The original UTF-16 caret location, used when the line disappears.
    let location: Int

    init(selection: NSRange, in text: NSString) {
        let lineRange = text.lineRange(for: NSRange(location: min(selection.location, text.length), length: 0))
        lineText = text.substring(with: lineRange).trimmingCharacters(in: .newlines)
        column = selection.location - lineRange.location
        location = selection.location
    }

    /// Caret location in `newText`: the same column on the first line whose
    /// text matches (clamped to that line's end), otherwise the original
    /// location clamped to the new length.
    func location(in newText: String) -> Int {
        let newLength = (newText as NSString).length
        var restored = min(location, newLength)
        var offset = 0
        for line in newText.components(separatedBy: "\n") {
            let length = (line as NSString).length
            if line == lineText {
                restored = min(offset + column, offset + length)
                break
            }
            offset += length + 1
        }
        return min(restored, newLength)
    }
}

/// Maps selected segments through a line-preserving rewrite or permutation.
/// Exclusive ends belong to the last selected line, not the following line.
/// A permutation can split a selection; never enclose unrelated moved content.
enum NoteSelectionMapping {
    static func ranges(_ selections: [NSRange], from oldText: String, to newText: String,
                       originalLineIndices: [Int]? = nil) -> [NSRange] {
        func lineRanges(_ text: String) -> [NSRange] {
            let lines = text.components(separatedBy: "\n")
            var offset = 0
            return lines.enumerated().map { index, line in
                let length = (line as NSString).length + (index < lines.count - 1 ? 1 : 0)
                defer { offset += length }
                return NSRange(location: offset, length: length)
            }
        }
        let oldLines = lineRanges(oldText)
        let newLines = lineRanges(newText)
        let origins = originalLineIndices ?? Array(newLines.indices)
        var destinations = Array(repeating: NSRange(), count: oldLines.count)
        for (index, origin) in origins.enumerated() {
            destinations[origin] = newLines[index]
        }
        let oldLength = (oldText as NSString).length
        let newLength = (newText as NSString).length
        var mapped: [NSRange] = []
        for selection in selections {
            if selection.location == 0, selection.length == oldLength, oldLength > 0 {
                return [NSRange(location: 0, length: newLength)]
            }
            for (index, line) in oldLines.enumerated() {
                let destination = destinations[index]
                if selection.length == 0 {
                    guard NSLocationInRange(selection.location, line)
                            || (index == oldLines.count - 1 && selection.location == oldLength) else { continue }
                    let column = min(selection.location - line.location, destination.length)
                    mapped.append(NSRange(location: destination.location + column, length: 0))
                    break
                }
                let segment = NSIntersectionRange(selection, line)
                guard segment.length > 0 else { continue }
                let start = min(segment.location - line.location, destination.length)
                let end = min(NSMaxRange(segment) - line.location, destination.length)
                mapped.append(NSRange(location: destination.location + start, length: end - start))
            }
        }
        // Adjacent segments may become contiguous again. Merge their union,
        // while retaining separate ranges wherever unselected text intervenes.
        var merged: [NSRange] = []
        for range in mapped.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
