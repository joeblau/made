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
