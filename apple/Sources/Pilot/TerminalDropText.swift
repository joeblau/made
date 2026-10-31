import AppKit

/// Converts a drop on a terminal into the text pasted at the prompt. Files
/// become shell-escaped paths, as when dragging from Finder, so agents such as
/// Claude Code recognize a dropped image path and attach it as an image.
enum TerminalDropText {
    /// Drag pasteboards are untrusted input; bound what one drop can paste.
    static let maxFileURLs = 64
    static let maxTextBytes = 1_024 * 1_024

    static func text(from pasteboard: NSPasteboard) -> String? {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        if let text = text(forFileURLs: urls) { return text }
        guard let string = pasteboard.string(forType: .string),
              !string.isEmpty,
              string.utf8.count <= maxTextBytes else { return nil }
        return string
    }

    static func text(forFileURLs urls: [URL]) -> String? {
        let paths = urls.lazy
            .filter(\.isFileURL)
            .prefix(maxFileURLs)
            .map { shellEscaped($0.path) }
        return paths.isEmpty ? nil : paths.joined(separator: " ")
    }

    /// Backslash-escapes characters a POSIX shell would otherwise interpret.
    static func shellEscaped(_ path: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(path.count)
        for character in path {
            if shellSpecialCharacters.contains(character) {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }

    private static let shellSpecialCharacters: Set<Character> = [
        "\\", " ", "\t", "(", ")", "[", "]", "{", "}", "<", ">",
        "\"", "'", "`", "!", "#", "$", "&", ";", "|", "*", "?", "~",
    ]
}

// Lives here rather than in GhosttyTerminal.swift, which is already past the
// file-length limit recorded in the SwiftLint baseline.
extension GhosttyMetalView {
    /// Registering is idempotent, so re-hosting the view is harmless.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        registerForDraggedTypes([.fileURL, .string])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        TerminalDropText.text(from: sender.draggingPasteboard) == nil ? [] : .copy
    }

    /// Pastes dropped files as shell-escaped paths (or dropped text as-is)
    /// through the surface's paste path, so bracketed paste is honored.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let text = TerminalDropText.text(from: sender.draggingPasteboard) else { return false }
        window?.makeFirstResponder(self)
        pasteText(text)
        return true
    }
}
