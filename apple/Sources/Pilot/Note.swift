import Foundation
import SwiftData

/// A global, app-level scratchpad note. Notes are not tied to a workspace —
/// they live above the Pinned section in the sidebar and surface as a tab
/// bar of text editors in the detail area, toggled with ⌘0.
@Model
final class Note {
    #Unique([\Note.id])

    var id: UUID = UUID()
    var body: String = ""
    var sortOrder: Int = 0
    var createdAt: Date = Date()

    init(body: String = "", sortOrder: Int = 0) {
        self.id = UUID()
        self.body = body
        self.sortOrder = sortOrder
        self.createdAt = Date()
    }

    /// Tab label derived from the first non-empty line of the note body,
    /// truncated so tabs stay compact. Falls back to "New Note" while empty.
    ///
    /// Recomputed by the tab bar on every render (so on every keystroke while
    /// editing), which is why only the first non-empty line is redacted:
    /// `EnvSecret.redacted` regex-scans and copies its whole input, and running
    /// it over the full body made each render O(body) per note. The redaction
    /// regex is line-anchored and never empties a line, so per-line redaction
    /// is observably identical.
    var displayTitle: String {
        var lineStart = body.startIndex
        while lineStart < body.endIndex {
            let lineEnd = body[lineStart...].firstIndex(where: \.isNewline) ?? body.endIndex
            let line = body[lineStart..<lineEnd]
            if !line.allSatisfy(\.isWhitespace) {
                let trimmed = EnvSecret.redacted(String(line))
                    .trimmingCharacters(in: .whitespaces)
                return trimmed.count > 24 ? String(trimmed.prefix(24)) + "…" : trimmed
            }
            if lineEnd == body.endIndex { break }
            lineStart = body.index(after: lineEnd)
        }
        return "New Note"
    }
}
