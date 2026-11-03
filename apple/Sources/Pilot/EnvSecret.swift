import AppKit

/// Recognizes `.env`-style assignments in a note — `KEY="value"`,
/// `export KEY=value`, etc. — so their values can be masked in the editor and
/// copied on click. Keys are required to be uppercase (the env convention) so
/// ordinary prose like `a = b` isn't mistaken for a secret.
enum EnvSecret {
    static let mask = "••••••••"

    private static let line = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:export[ \t]+)?([A-Z_][A-Z0-9_]*)[ \t]*=[ \t]*(\S.*?)[ \t]*$"#,
        options: .anchorsMatchLines
    )

    struct Match {
        /// The key name (e.g. `JOE_PLAYER_ONE`) — stable identity for the
        /// per-secret reveal toggle, since char ranges shift as you edit.
        let key: String
        let keyRange: NSRange
        /// The secret content range — inside the quotes when the value is quoted.
        let valueRange: NSRange
        /// The string to place on the pasteboard.
        let value: String
    }

    static func matches(in string: String, range: NSRange? = nil) -> [Match] {
        let ns = string as NSString
        let scanRange = range ?? NSRange(location: 0, length: ns.length)
        var result: [Match] = []

        line.enumerateMatches(
            in: string, options: [.withTransparentBounds, .withoutAnchoringBounds], range: scanRange
        ) { match, _, _ in
            guard let match else { return }
            let keyRange = match.range(at: 1)
            var valueRange = match.range(at: 2)
            guard valueRange.location != NSNotFound, valueRange.length > 0 else { return }

            // Strip a matching pair of surrounding quotes from what we mask/copy.
            let raw = ns.substring(with: valueRange)
            if raw.count >= 2, let first = raw.first, let last = raw.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                valueRange = NSRange(location: valueRange.location + 1, length: valueRange.length - 2)
            }
            guard valueRange.length > 0 else { return }

            result.append(Match(key: ns.substring(with: keyRange),
                                keyRange: keyRange,
                                valueRange: valueRange,
                                value: ns.substring(with: valueRange)))
        }
        return result
    }

    /// Returns a presentation-safe copy of a note. Notes deliberately remain
    /// plaintext in SwiftData; this helper prevents that plaintext from leaking
    /// into secondary UI such as tab titles and accessibility values.
    static func redacted(_ string: String, revealing revealedKeys: Set<String> = []) -> String {
        let mutable = NSMutableString(string: string)
        for match in matches(in: string).reversed() where !revealedKeys.contains(match.key) {
            mutable.replaceCharacters(in: match.valueRange, with: mask)
        }
        return mutable as String
    }
}

/// Masks `.env` secret values in an `NSTextView` by substituting bullet glyphs
/// at the layout-manager level — the real characters stay in the text storage
/// (so the note still persists as plain text), only the rendered glyphs change.
/// Values stay masked until the user unlocks them with the per-line lock; the
/// caret never reveals them.
@MainActor
final class EnvMaskController: NSObject, @preconcurrency NSLayoutManagerDelegate {
    weak var textView: MultiCursorTextView?
    private(set) var maskedRanges: [NSRange] = []
    /// All secrets currently in the document (for hover/lock hit-testing).
    private(set) var secrets: [EnvSecret.Match] = []
    /// Keys the user has explicitly unlocked via the per-line lock toggle.
    private var revealedKeys: Set<String> = []

    func isRevealed(_ key: String) -> Bool { revealedKeys.contains(key) }

    var accessibilityText: String? {
        textView.map { EnvSecret.redacted($0.string, revealing: revealedKeys) }
    }

    func toggleReveal(_ key: String) {
        if revealedKeys.contains(key) {
            revealedKeys.remove(key)
        } else {
            revealedKeys.insert(key)
        }
        refresh()
        if let textView {
            NSAccessibility.post(element: textView, notification: .valueChanged)
        }
    }

    /// The secret whose value sits on the same line as `charIndex`, if any.
    func secret(atLine charIndex: Int) -> EnvSecret.Match? {
        guard let textView else { return nil }
        let ns = textView.string as NSString
        guard charIndex <= ns.length else { return nil }
        let line = ns.lineRange(for: NSRange(location: min(charIndex, max(0, ns.length - 1)), length: 0))
        return secrets.first { NSIntersectionRange(line, $0.valueRange).length > 0 || NSLocationInRange($0.keyRange.location, line) }
    }

    /// Recompute which secret values should be masked and re-lay-out if that
    /// set changed. The editor supplies the styler's index on text changes;
    /// standalone reveal toggles can still request a fresh parse.
    func refresh(secretMatches: [EnvSecret.Match]? = nil) {
        guard let textView, let layoutManager = textView.layoutManager else { return }
        let matches = secretMatches ?? EnvSecret.matches(in: textView.string)
        secrets = matches

        // Locked by default: a value is only visible when the user explicitly
        // unlocks its key. Caret position / hover never reveal it, so clicking
        // into or mousing over a secret line keeps the value hidden.
        let newMasked = matches
            .filter { !revealedKeys.contains($0.key) }
            .map(\.valueRange)

        // Affordance rects (lock/tooltip) may move even when the masked set is
        // unchanged, so refresh them before the early-out.
        textView.updateSecretAffordances()

        guard newMasked != maskedRanges else { return }
        var invalidated = IndexSet()
        let length = (textView.string as NSString).length
        for range in maskedRanges + newMasked {
            let start = min(range.location, length)
            let end = min(NSMaxRange(range), length)
            if end > start { invalidated.insert(integersIn: start..<end) }
        }
        maskedRanges = newMasked

        for range in invalidated.rangeView {
            let characters = NSRange(location: range.lowerBound, length: range.count)
            layoutManager.invalidateGlyphs(
                forCharacterRange: characters, changeInLength: 0, actualCharacterRange: nil
            )
            layoutManager.invalidateLayout(forCharacterRange: characters, actualCharacterRange: nil)
        }
        textView.needsDisplay = true
        textView.updateSecretAffordances()
    }

    private func isMasked(_ charIndex: Int) -> Bool {
        maskedRanges.contains { NSLocationInRange(charIndex, $0) }
    }

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>,
                       font: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard !maskedRanges.isEmpty else { return 0 }

        let count = glyphRange.length
        var anyMasked = false
        for i in 0..<count where isMasked(charIndexes[i]) { anyMasked = true; break }
        guard anyMasked else { return 0 }

        let bullet = Self.glyph(for: "•", font: font)
        let substituted = UnsafeMutablePointer<CGGlyph>.allocate(capacity: count)
        defer { substituted.deallocate() }
        for i in 0..<count {
            substituted[i] = isMasked(charIndexes[i]) ? bullet : glyphs[i]
        }
        layoutManager.setGlyphs(substituted, properties: props, characterIndexes: charIndexes,
                                font: font, forGlyphRange: glyphRange)
        return count
    }

    private static func glyph(for character: Character, font: NSFont) -> CGGlyph {
        var chars = Array(String(character).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        CTFontGetGlyphsForCharacters(font as CTFont, &chars, &glyphs, chars.count)
        return glyphs.first ?? 0
    }
}
