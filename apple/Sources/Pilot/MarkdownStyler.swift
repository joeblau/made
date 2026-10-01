import AppKit

/// Shared geometry between Markdown styling (which reserves the space) and the
/// text-view overlays (which draw the decoded image inside that space).
enum MarkdownImagePresentation {
    static let previewHeight: CGFloat = 220
    static let gap: CGFloat = 8
    static let stride = previewHeight + gap
}

/// Live GitHub-Flavored-Markdown styling for an `NSTextView`. The raw
/// markdown stays in the text storage (and is what we persist) — this only
/// layers visual attributes on top, in place, so `# Hello` renders at H1
/// size, `**bold**` goes bold, etc., all in a single editable view.
///
/// Hooked in as the text storage's delegate. A character edit restyles only
/// the dirty region: the `\n`-delimited lines the edit touched, plus the lines
/// of any fenced block or image whose extent changed (an opening fence typed
/// at the top re-pairs every fence below it, so that edit falls back to a
/// large region or a full pass). Every rule other than fences and images is
/// confined to one line, so restyling whole lines reproduces exactly what a
/// full pass would produce. Because we only ever change *attributes*, the
/// follow-up edit pass carries `.editedAttributes` rather than
/// `.editedCharacters`, so re-styling never recurses.
final class MarkdownStyler: NSObject, NSTextStorageDelegate {
    /// What the most recent pass restyled, for tests and latency profiling.
    struct PassReport: Equatable {
        var isFullPass: Bool
        var styledLength: Int
        var documentLength: Int
        var regionCount: Int
    }

    var baseSize: CGFloat
    private var isStyling = false
    /// Document-wide structure from the last pass, in that pass's coordinates.
    /// `nil` forces the next edit to take a full pass.
    private var structure: DocumentStructure?
    private(set) var lastPass = PassReport(isFullPass: true, styledLength: 0, documentLength: 0, regionCount: 0)

    /// Above this share of the document, one full pass is cheaper than
    /// several regional ones and produces the same attributes.
    private static let fullPassFraction = 0.5

    init(baseSize: CGFloat) {
        self.baseSize = baseSize
    }

    func textStorage(_ textStorage: NSTextStorage,
                     didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange,
                     changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), !isStyling else { return }
        isStyling = true
        styleEdit(textStorage, editedRange: editedRange, changeInLength: delta)
        isStyling = false
    }

    /// Full pass over the whole document. Also resets the structure index.
    func style(_ storage: NSTextStorage) {
        let string = storage.string
        let current = DocumentStructure(string)
        structure = current
        let full = NSRange(location: 0, length: current.length)
        lastPass = PassReport(isFullPass: true, styledLength: full.length,
                              documentLength: full.length, regionCount: 1)
        guard full.length > 0 else { return }
        storage.beginEditing()
        style(storage, region: full, string: string, structure: current)
        storage.endEditing()
    }

    /// Restyles what a character edit invalidated. `editedRange` is in
    /// post-edit coordinates and `delta` is the change in length, exactly as
    /// `NSTextStorage` reports them.
    func styleEdit(_ storage: NSTextStorage, editedRange: NSRange, changeInLength delta: Int) {
        let string = storage.string
        let ns = string as NSString
        guard let previous = structure,
              previous.length + delta == ns.length,
              editedRange.location != NSNotFound,
              NSMaxRange(editedRange) <= ns.length,
              NSMaxRange(editedRange) - delta >= editedRange.location else {
            style(storage)
            return
        }
        let current = DocumentStructure(string)

        var dirty = IndexSet()
        func markLines(_ range: NSRange) {
            let lines = ns.newlineDelimitedLines(covering: range)
            if lines.length > 0 { dirty.insert(integersIn: lines.location..<NSMaxRange(lines)) }
        }
        markLines(editedRange)
        // A fence or image whose extent differs from its pre-edit extent
        // changes how its every line is styled, wherever those lines are.
        for range in Self.changedRanges(previous.fences, current.fences, editedRange: editedRange, delta: delta) {
            markLines(range)
        }
        for range in Self.changedRanges(previous.images.map(\.range), current.images.map(\.range),
                                        editedRange: editedRange, delta: delta) {
            markLines(range)
        }
        // An image is styled as a unit (protection + its line's reserved
        // preview space), so a region must contain all of any image it touches.
        var expanded = true
        while expanded {
            expanded = false
            for image in current.images where image.range.length > 0 {
                let span = image.range.location..<NSMaxRange(image.range)
                if dirty.intersects(integersIn: span), !dirty.contains(integersIn: span) {
                    markLines(image.range)
                    expanded = true
                }
            }
        }

        let styledLength = dirty.count
        if Double(styledLength) > Double(ns.length) * Self.fullPassFraction {
            style(storage)
            return
        }
        structure = current
        let regions = dirty.rangeView.map { NSRange(location: $0.lowerBound, length: $0.count) }
        lastPass = PassReport(isFullPass: false, styledLength: styledLength,
                              documentLength: ns.length, regionCount: regions.count)
        guard !regions.isEmpty else { return }
        storage.beginEditing()
        for region in regions {
            style(storage, region: region, string: string, structure: current)
        }
        storage.endEditing()
    }

    // MARK: - Dirty-region bookkeeping

    /// Ranges present before or after the edit but not both, with pre-edit
    /// ranges mapped into post-edit coordinates. A range overlapping the edit
    /// is stretched over the edited span (which is restyled regardless).
    static func changedRanges(_ old: [NSRange], _ new: [NSRange],
                              editedRange: NSRange, delta: Int) -> [NSRange] {
        guard !old.isEmpty || !new.isEmpty else { return [] }
        let editStart = editedRange.location
        let newEditEnd = NSMaxRange(editedRange)
        let oldEditEnd = newEditEnd - delta

        struct Key: Hashable { let location: Int; let length: Int }
        func key(_ range: NSRange) -> Key { Key(location: range.location, length: range.length) }

        let mapped = old.map { range -> NSRange in
            if NSMaxRange(range) <= editStart { return range }
            if range.location >= oldEditEnd {
                return NSRange(location: range.location + delta, length: range.length)
            }
            let start = min(range.location, editStart)
            let end = NSMaxRange(range) > oldEditEnd ? NSMaxRange(range) + delta : newEditEnd
            return NSRange(location: start, length: max(0, end - start))
        }
        let before = Set(mapped.map(key))
        let after = Set(new.map(key))
        return mapped.filter { !after.contains(key($0)) } + new.filter { !before.contains(key($0)) }
    }

    /// The parts of styling that depend on more than one line. Rebuilt per
    /// edit (two linear scans) and diffed against the previous pass to find
    /// what an edit invalidated beyond its own lines.
    private struct DocumentStructure {
        let length: Int
        let fences: [NSRange]
        let images: [MarkdownImage.Match]

        init(_ string: String) {
            let ns = string as NSString
            length = ns.length
            var fences: [NSRange] = []
            if ns.range(of: "```", options: .literal).location != NSNotFound {
                MarkdownStyler.fencedCode.enumerateMatches(
                    in: string, range: NSRange(location: 0, length: ns.length)
                ) { match, _, _ in
                    if let match { fences.append(match.range) }
                }
            }
            self.fences = fences
            images = MarkdownImage.matches(in: string)
        }
    }

    // MARK: - Styling a region

    /// Styles `region`, which must start at a line start and end at a line end
    /// (after its `\n`, or at the end of the document). Matching runs against
    /// the whole string with transparent bounds, so lookarounds and anchors
    /// see the same context they would in a full pass.
    private func style(_ storage: NSTextStorage, region: NSRange, string: String, structure: DocumentStructure) {
        let ns = string as NSString

        // Clean slate: body font + label color across the region, dropping
        // any background/underline/strikethrough/paragraph spacing.
        storage.setAttributes(
            [.font: NSFont.monospacedSystemFont(ofSize: baseSize, weight: .regular),
             .foregroundColor: NSColor.labelColor],
            range: region
        )

        // Code regions are recorded so inline/heading rules don't fire inside
        // them (e.g. a `#` in a fenced block is not a heading).
        var protectedIndexes = IndexSet()
        func isProtected(_ range: NSRange) -> Bool {
            range.length > 0 && protectedIndexes.intersects(integersIn: range.location..<NSMaxRange(range))
        }
        func protect(_ range: NSRange) {
            guard range.length > 0 else { return }
            protectedIndexes.insert(integersIn: range.location..<NSMaxRange(range))
        }
        func eachMatch(_ regex: NSRegularExpression, _ handle: (NSTextCheckingResult) -> Void) {
            regex.enumerateMatches(in: string, options: Self.regionMatchingOptions, range: region) { match, _, _ in
                if let match { handle(match) }
            }
        }

        let codeFont = NSFont.monospacedSystemFont(ofSize: baseSize, weight: .regular)

        // --- Code (claim ranges first) ---------------------------------------
        for fence in structure.fences {
            let visible = NSIntersectionRange(fence, region)
            guard visible.length > 0 else { continue }
            storage.addAttributes([.font: codeFont, .backgroundColor: Self.codeBackground], range: visible)
            protect(fence)
        }
        eachMatch(Self.inlineCode) { match in
            guard !isProtected(match.range) else { return }
            storage.addAttributes([.font: codeFont, .backgroundColor: Self.codeBackground], range: match.range)
            dim(storage, NSRange(location: match.range.location, length: 1))
            dim(storage, NSRange(location: NSMaxRange(match.range) - 1, length: 1))
            protect(match.range)
        }

        // --- Images ----------------------------------------------------------
        // Keep the raw `![alt](url)` source editable, but reserve an inline
        // preview area below its line. MultiCursorTextView renders the image in
        // that space and supplies the gutter copy affordance.
        var imagesByLine: [Int: (range: NSRange, count: Int)] = [:]
        for image in structure.images where NSLocationInRange(image.range.location, region) {
            guard !isProtected(image.range) else { continue }
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: image.range)
            protect(image.range)

            let lineRange = ns.lineRange(for: NSRange(location: image.range.location, length: 0))
            if var entry = imagesByLine[lineRange.location] {
                entry.count += 1
                imagesByLine[lineRange.location] = entry
            } else {
                imagesByLine[lineRange.location] = (lineRange, 1)
            }
        }
        for entry in imagesByLine.values {
            addParagraphSpacing(
                CGFloat(entry.count) * MarkdownImagePresentation.stride,
                to: entry.range,
                in: storage
            )
        }

        // --- Env-style secrets (KEY="value") ---------------------------------
        // Tint the key and give the value a pill background; protect the value
        // so inline markdown (e.g. `*` in a secret) doesn't restyle it. The
        // bullet masking itself is handled by EnvMaskController at layout time.
        for secret in EnvSecret.matches(in: string, range: region) {
            guard !isProtected(secret.valueRange), !isProtected(secret.keyRange) else { continue }
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: secret.keyRange)
            storage.addAttribute(.backgroundColor, value: Self.secretBackground, range: secret.valueRange)
            protect(secret.valueRange)
        }

        // --- Block level ------------------------------------------------------
        eachMatch(Self.heading) { match in
            guard !isProtected(match.range) else { return }
            let level = match.range(at: 1).length
            storage.addAttribute(.font, value: headingFont(level: level), range: match.range)
            // Dim the leading "#"s and the space(s) before the content.
            let contentStart = match.range(at: 2).location
            dim(storage, NSRange(location: match.range.location, length: contentStart - match.range.location))
        }
        eachMatch(Self.blockquote) { match in
            guard !isProtected(match.range) else { return }
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: match.range)
        }
        eachMatch(Self.listMarker) { match in
            guard !isProtected(match.range) else { return }
            let marker = match.range(at: 2)
            if marker.location != NSNotFound {
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: marker)
            }
        }
        eachMatch(Self.taskMarker) { match in
            guard !isProtected(match.range) else { return }
            let box = match.range(at: 1)
            if box.location != NSNotFound {
                storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: box)
            }
        }
        // Completed tasks ([x]) get a subtle strikethrough + dimmed text.
        eachMatch(Self.completedTask) { match in
            guard !isProtected(match.range) else { return }
            let content = match.range(at: 1)
            guard content.location != NSNotFound, content.length > 0 else { return }
            storage.addAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: NSColor.tertiaryLabelColor,
                .foregroundColor: NSColor.secondaryLabelColor,
            ], range: content)
        }
        eachMatch(Self.horizontalRule) { match in
            guard !isProtected(match.range) else { return }
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: match.range)
        }

        // --- Inline spans -----------------------------------------------------
        eachMatch(Self.bold) { match in
            guard !isProtected(match.range) else { return }
            addTrait(.bold, over: match.range, in: storage)
            dimDelimiters(storage, span: match.range, markerLength: match.range(at: 1).length)
        }
        for regex in [Self.italicStar, Self.italicUnderscore] {
            eachMatch(regex) { match in
                guard !isProtected(match.range) else { return }
                addTrait(.italic, over: match.range, in: storage)
                dimDelimiters(storage, span: match.range, markerLength: 1)
            }
        }
        eachMatch(Self.strikethrough) { match in
            guard !isProtected(match.range) else { return }
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: match.range)
            dimDelimiters(storage, span: match.range, markerLength: 2)
        }
        eachMatch(Self.link) { match in
            guard !isProtected(match.range) else { return }
            let label = match.range(at: 1)
            var attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
            let target = ns.substring(with: match.range(at: 2))
            if let url = URL(string: target.hasPrefix("www.") ? "https://\(target)" : target) {
                attrs[.link] = url
            }
            storage.addAttributes(attrs, range: label)
            // Dim the brackets and the (url) tail surrounding the label.
            dim(storage, NSRange(location: match.range.location, length: label.location - match.range.location))
            dim(storage, NSRange(location: NSMaxRange(label), length: NSMaxRange(match.range) - NSMaxRange(label)))
        }

        // Bare URLs (https://…, www.…) become clickable links.
        eachMatch(Self.bareURL) { match in
            var range = match.range(at: 1)
            guard !isProtected(range) else { return }
            // Trim trailing sentence punctuation that isn't part of the URL.
            while range.length > 0 {
                let last = ns.substring(with: NSRange(location: NSMaxRange(range) - 1, length: 1))
                guard ".,;:!?".contains(last) else { break }
                range.length -= 1
            }
            guard range.length > 0 else { return }
            var urlString = ns.substring(with: range)
            if urlString.hasPrefix("www.") { urlString = "https://\(urlString)" }
            guard let url = URL(string: urlString) else { return }
            storage.addAttributes([
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .link: url,
            ], range: range)
            protect(range)
        }

        // A line whose code span is a color gets a little breathing room below,
        // so its swatch isn't cramped against the next line.
        for match in ColorChip.matches(in: string, range: region) {
            let lineRange = ns.lineRange(for: NSRange(location: match.range.location, length: 0))
            addParagraphSpacing(baseSize, to: lineRange, in: storage)
        }

        // Attribute changes made from the storage delegate are not queued for
        // the storage's lazy fixing, so apply font fallback (e.g. CJK in the
        // monospaced font) here, matching what a top-level pass produces.
        storage.fixAttributes(in: region)
    }

    // MARK: - Attribute helpers

    private func headingFont(level: Int) -> NSFont {
        let scale: CGFloat
        switch level {
        case 1: scale = 1.8
        case 2: scale = 1.5
        case 3: scale = 1.3
        case 4: scale = 1.15
        case 5: scale = 1.05
        default: scale = 1.0
        }
        return NSFont.monospacedSystemFont(ofSize: baseSize * scale, weight: .bold)
    }

    /// Adds a symbolic trait (bold/italic) to the *existing* font at each run,
    /// so e.g. bold inside an H1 keeps the H1 size and just gains weight.
    private func addTrait(_ trait: NSFontDescriptor.SymbolicTraits, over range: NSRange, in storage: NSTextStorage) {
        storage.enumerateAttribute(.font, in: range) { value, subRange, _ in
            let current = (value as? NSFont) ?? NSFont.monospacedSystemFont(ofSize: baseSize, weight: .regular)
            var traits = current.fontDescriptor.symbolicTraits
            traits.insert(trait)
            let descriptor = current.fontDescriptor.withSymbolicTraits(traits)
            if let font = NSFont(descriptor: descriptor, size: current.pointSize) {
                storage.addAttribute(.font, value: font, range: subRange)
            }
        }
    }

    private func dim(_ storage: NSTextStorage, _ range: NSRange) {
        guard range.length > 0 else { return }
        storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
    }

    private func dimDelimiters(_ storage: NSTextStorage, span: NSRange, markerLength: Int) {
        guard span.length >= markerLength * 2 else { return }
        dim(storage, NSRange(location: span.location, length: markerLength))
        dim(storage, NSRange(location: NSMaxRange(span) - markerLength, length: markerLength))
    }

    private func addParagraphSpacing(_ amount: CGFloat, to lineRange: NSRange, in storage: NSTextStorage) {
        guard lineRange.length > 0 else { return }
        let existing = storage.attribute(.paragraphStyle, at: lineRange.location, effectiveRange: nil)
            as? NSParagraphStyle
        let style = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.paragraphSpacing += amount
        storage.addAttribute(.paragraphStyle, value: style, range: lineRange)
    }

    private static let codeBackground = NSColor.systemGray.withAlphaComponent(0.28)
    private static let secretBackground = NSColor.systemGray.withAlphaComponent(0.22)

    // MARK: - GFM patterns

    /// Transparent, non-anchoring bounds make a regional match behave exactly
    /// like the same match found during a whole-document enumeration.
    static let regionMatchingOptions: NSRegularExpression.MatchingOptions = [
        .withTransparentBounds, .withoutAnchoringBounds,
    ]

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let heading = regex(#"^(#{1,6})[ \t]+(.+)$"#, .anchorsMatchLines)
    private static let blockquote = regex(#"^[ \t]*>[ \t]?.*$"#, .anchorsMatchLines)
    private static let listMarker = regex(#"^([ \t]*)([-*+]|\d+[.)])[ \t]+"#, .anchorsMatchLines)
    private static let taskMarker = regex(#"^[ \t]*[-*+][ \t]+(\[[ xX]\])"#, .anchorsMatchLines)
    private static let completedTask = regex(#"^[ \t]*[-*+][ \t]+\[[xX]\][ \t]*(.*)$"#, .anchorsMatchLines)
    private static let horizontalRule = regex(#"^[ \t]*([-*_])(?:[ \t]*\1){2,}[ \t]*$"#, .anchorsMatchLines)
    private static let fencedCode = regex(#"```[\s\S]*?```"#)
    private static let inlineCode = regex(#"`[^`\n]+`"#)
    private static let bold = regex(#"(\*\*|__)([^\n]+?)\1"#)
    private static let italicStar = regex(#"(?<![*\w])\*(?!\s)([^*\n]+?)(?<!\s)\*(?![*\w])"#)
    private static let italicUnderscore = regex(#"(?<![_\w])_(?!\s)([^_\n]+?)(?<!\s)_(?![_\w])"#)
    private static let strikethrough = regex(#"~~([^\n]+?)~~"#)
    private static let link = regex(#"(?<!!)\[([^\]\n]+)\]\(([^)\n]+)\)"#)
    private static let bareURL = regex(#"(?<![\w@./])((?:https?://|www\.)[^\s<>"')\]]+)"#)
}

extension NSString {
    /// The `\n`-delimited lines touching `range`, including the line that holds
    /// the position just past it (an inserted newline splits that line, and a
    /// deletion joins it). The result starts at a line start and ends after a
    /// `\n` or at the end of the string. Only `\n` counts as a line break,
    /// matching the formatters and the single-line Markdown patterns, which
    /// do not stop at `\r` or Unicode separators.
    func newlineDelimitedLines(covering range: NSRange) -> NSRange {
        let start = min(range.location, length)
        let end = min(NSMaxRange(range), length)
        var lineStart = 0
        if start > 0 {
            let previous = self.range(of: "\n", options: [.backwards, .literal],
                                      range: NSRange(location: 0, length: start))
            if previous.location != NSNotFound { lineStart = previous.location + 1 }
        }
        var lineEnd = length
        if end < length {
            let next = self.range(of: "\n", options: .literal,
                                  range: NSRange(location: end, length: length - end))
            if next.location != NSNotFound { lineEnd = next.location + 1 }
        }
        return NSRange(location: lineStart, length: lineEnd - lineStart)
    }
}
