import AppKit

/// Owns the AppKit subviews the Notes editor floats over its text: left-gutter
/// buttons (secret locks, code-block copy, rendered-image URL copy), inline
/// color swatches, and Markdown image previews. All three live in the text
/// view's flipped coordinate space, so they scroll with the content.
///
/// `layout()` runs on every display pass. Rebuilding subviews each time
/// (removeFromSuperview + addSubview) re-dirties Auto Layout and makes the
/// window perpetually "need another Update Constraints pass", which AppKit
/// eventually aborts with an NSGenericException. Each group therefore keeps a
/// signature of what it installed and only touches the subview tree when that
/// signature changes.
@MainActor
final class NoteEditorOverlays {
    private weak var textView: MultiCursorTextView?
    private let iconSize: CGFloat = 16

    /// Installed gutter buttons by spec key plus occurrence, so a change to
    /// one affordance (e.g. typing inside one code block) replaces only that
    /// button rather than every button in the gutter.
    private var gutterButtons: [String: GutterButton] = [:]
    private var gutterSignature = ""
    private var colorChips: [NSButton] = []
    private var colorChipSignature = ""
    /// Inline previews keyed by URL occurrence, so layout changes can move an
    /// in-flight view without cancelling and restarting its download.
    private var imagePreviews: [String: MarkdownImagePreviewView] = [:]
    private var imagePreviewSignature = ""
    /// URLs that have decoded into a real image. A gutter copy button is only
    /// offered after that point, so broken/loading previews don't imply a
    /// successful render.
    private var renderedImageURLs: Set<String> = []

    /// Layout-pass scan caches. The scans depend only on the text, so they
    /// hold until it changes — typing and the programmatic reflows both funnel
    /// through `didChangeText()`, and SwiftUI's binding pushes via `string`.
    private var cachedFencedBlocks: [(range: NSRange, content: String)]?
    private var cachedColorChipMatches: [ColorChip.Match]?
    private var cachedMarkdownImageMatches: [MarkdownImage.Match]?

    init(textView: MultiCursorTextView) {
        self.textView = textView
    }

    func invalidateTextScans() {
        cachedFencedBlocks = nil
        cachedColorChipMatches = nil
        cachedMarkdownImageMatches = nil
    }

    /// Full overlay pass for `NSView.layout()`.
    func layout() {
        layoutMarkdownImages()
        layoutGutterIcons()
        layoutColorChips()
    }

    /// Secret locks and swatches move when the mask set changes, without a
    /// layout pass of their own.
    func refreshGutterAndColorChips() {
        layoutGutterIcons()
        layoutColorChips()
    }

    // MARK: - Image previews

    /// Places a fixed-height, aspect-fit preview below every Markdown image
    /// line. `MarkdownStyler` reserves the matching paragraph space, so these
    /// subviews never cover editable source or surrounding text.
    private func layoutMarkdownImages() {
        guard let textView, let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        let ns = textView.string as NSString
        let matches = markdownImages()
        renderedImageURLs.formIntersection(Set(matches.map(\.urlString)))

        let origin = textView.textContainerOrigin
        let padding = textContainer.lineFragmentPadding
        let availableWidth = max(80, textContainer.containerSize.width - padding * 2)
        let previewWidth = min(720, availableWidth)
        var indicesByLine: [Int: Int] = [:]
        var occurrencesByURL: [String: Int] = [:]

        struct Spec {
            let key: String
            let match: MarkdownImage.Match
            let frame: NSRect
        }
        var specs: [Spec] = []
        for match in matches {
            guard NSMaxRange(match.range) <= ns.length else { continue }
            let lineRange = ns.lineRange(for: NSRange(location: match.range.location, length: 0))
            let lineIndex = indicesByLine[lineRange.location, default: 0]
            indicesByLine[lineRange.location] = lineIndex + 1

            let glyphs = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let lineRect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            let frame = NSRect(
                x: origin.x + padding,
                y: lineRect.maxY + origin.y + MarkdownImagePresentation.gap
                    + CGFloat(lineIndex) * MarkdownImagePresentation.stride,
                width: previewWidth,
                height: MarkdownImagePresentation.previewHeight
            )
            let occurrence = occurrencesByURL[match.urlString, default: 0]
            occurrencesByURL[match.urlString] = occurrence + 1
            specs.append(Spec(
                key: "\(match.urlString)|\(occurrence)",
                match: match,
                frame: frame
            ))
        }

        let signature = specs.map {
            "\($0.key)|\($0.match.altText)@\(NSStringFromRect($0.frame))"
        }.joined(separator: ";")
        guard signature != imagePreviewSignature else { return }
        imagePreviewSignature = signature

        let liveKeys = Set(specs.map(\.key))
        for key in Array(imagePreviews.keys) where !liveKeys.contains(key) {
            imagePreviews.removeValue(forKey: key)?.removeFromSuperview()
        }
        for spec in specs {
            if let preview = imagePreviews[spec.key] {
                preview.update(frame: spec.frame, altText: spec.match.altText)
                continue
            }
            let preview = MarkdownImagePreviewView(
                frame: spec.frame,
                match: spec.match
            ) { [weak self] renderedURL in
                guard let self,
                      self.imagePreviews[spec.key] != nil,
                      self.markdownImages().contains(where: { $0.urlString == renderedURL }) else { return }
                self.renderedImageURLs.insert(renderedURL)
                self.textView?.needsLayout = true
            }
            textView.addSubview(preview)
            imagePreviews[spec.key] = preview
            preview.startLoading()
        }
    }

    private func markdownImages() -> [MarkdownImage.Match] {
        if let cachedMarkdownImageMatches { return cachedMarkdownImageMatches }
        let matches = MarkdownImage.matches(in: textView?.string ?? "")
        cachedMarkdownImageMatches = matches
        return matches
    }

    // MARK: - Color swatches

    /// Places a clickable color swatch just after each inline-code span whose
    /// content is a color (e.g. `#00FF3F`, `rgb(...)`, `oklch(...)`, `cmyk(...)`).
    /// Clicking the swatch copies the color string.
    private func layoutColorChips() {
        guard let textView, let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        let ns = textView.string as NSString
        let chipSize: CGFloat = 12
        let origin = textView.textContainerOrigin

        struct Spec { let value: String; let color: NSColor; let frame: NSRect }
        var specs: [Spec] = []
        let matches: [ColorChip.Match]
        if let cachedColorChipMatches {
            matches = cachedColorChipMatches
        } else {
            matches = ColorChip.matches(in: ns as String)
            cachedColorChipMatches = matches
        }
        for match in matches {
            guard NSMaxRange(match.range) <= ns.length else { continue }
            let glyphs = layoutManager.glyphRange(forCharacterRange: match.range, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            // Sit the swatch just past the end of the code span, vertically centered.
            let frame = NSRect(x: rect.maxX + origin.x + 6,
                               y: rect.midY + origin.y - chipSize / 2,
                               width: chipSize, height: chipSize)
            specs.append(Spec(value: match.value, color: match.color, frame: frame))
        }

        let signature = specs.map { "\($0.value)@\(NSStringFromRect($0.frame))" }
            .joined(separator: ";")
        guard signature != colorChipSignature else { return }
        colorChipSignature = signature

        colorChips.forEach { $0.removeFromSuperview() }
        colorChips.removeAll()
        for spec in specs {
            let chip = ColorChipButton(frame: spec.frame)
            chip.swatch = spec.color
            chip.toolTip = "Copy \(spec.value)"
            let value = spec.value
            chip.onClick = { [weak textView] in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(value, forType: .string)
                textView?.onCopySecret?()
            }
            textView.addSubview(chip)
            colorChips.append(chip)
        }
    }

    // MARK: - Gutter buttons

    /// Gutter affordances are real buttons (custom drawing in `NSTextView.draw`
    /// doesn't composite reliably): a lock per secret line, a copy button per
    /// fenced code block, and a URL copy button per rendered image.
    private func layoutGutterIcons() {
        guard let textView else { return }
        // Build the desired button specs first, derive a signature, and bail
        // before touching the subview tree if nothing changed since the last
        // pass.
        struct Spec {
            let symbol: String
            let tint: NSColor
            let frame: NSRect
            let help: String
            let key: String
            let action: () -> Void
        }
        var specs: [Spec] = []

        if let maskController = textView.maskController {
            for secret in maskController.secrets {
                guard let rect = gutterIconRect(forLineAt: secret.keyRange, in: textView) else { continue }
                let revealed = maskController.isRevealed(secret.key)
                let key = secret.key
                specs.append(Spec(
                    symbol: revealed ? "lock.open.fill" : "lock.fill",
                    tint: revealed ? .controlAccentColor : .secondaryLabelColor,
                    frame: rect,
                    help: revealed ? "Hide value" : "Reveal value",
                    key: "S|\(key)|\(revealed)"
                ) { [weak textView] in
                    textView?.maskController?.toggleReveal(key)
                })
            }
        }

        for block in fencedBlocks() {
            guard let rect = copyIconRect(for: block.range, in: textView) else { continue }
            let content = block.content
            specs.append(Spec(
                symbol: "doc.on.doc",
                tint: .secondaryLabelColor,
                frame: rect,
                help: "Copy code block",
                key: "C|\(content.hashValue)"
            ) { [weak textView] in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(content, forType: .string)
                textView?.onCopySecret?()
            })
        }

        var imageIndicesByLine: [Int: Int] = [:]
        let noteText = textView.string as NSString
        for image in markdownImages() where renderedImageURLs.contains(image.urlString) {
            let lineRange = noteText.lineRange(for: NSRange(location: image.range.location, length: 0))
            let imageIndex = imageIndicesByLine[lineRange.location, default: 0]
            imageIndicesByLine[lineRange.location] = imageIndex + 1
            guard let rect = imageCopyIconRect(for: image.range, indexOnLine: imageIndex, in: textView) else {
                continue
            }
            let urlString = image.urlString
            specs.append(Spec(
                symbol: "link",
                tint: .secondaryLabelColor,
                frame: rect,
                help: "Copy image URL",
                key: "I|\(image.range.location)|\(urlString)"
            ) { [weak textView] in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(urlString, forType: .string)
                textView?.onCopySecret?()
            })
        }

        let signature = specs.map { "\($0.key)@\(NSStringFromRect($0.frame))" }
            .joined(separator: ";")
        guard signature != gutterSignature else { return }
        gutterSignature = signature

        // A key fixes the symbol, tint, and help text, so a button with the
        // same key only needs its frame and action refreshed.
        var occurrences: [String: Int] = [:]
        var installed: [String: GutterButton] = [:]
        for spec in specs {
            let occurrence = occurrences[spec.key, default: 0]
            occurrences[spec.key] = occurrence + 1
            let id = "\(spec.key)#\(occurrence)"
            let button: GutterButton
            if let existing = gutterButtons.removeValue(forKey: id) {
                button = existing
                if button.frame != spec.frame { button.frame = spec.frame }
            } else {
                button = GutterButton(symbol: spec.symbol, tint: spec.tint, frame: spec.frame, help: spec.help)
                textView.addSubview(button)
            }
            button.onClick = spec.action
            installed[id] = button
        }
        gutterButtons.values.forEach { $0.removeFromSuperview() }
        gutterButtons = installed
    }

    // MARK: - Geometry

    private func gutterX(in textView: MultiCursorTextView) -> CGFloat {
        max(4, (textView.textContainerOrigin.x - iconSize) / 2)
    }

    /// Centered in the left gutter (the area left of the text), on the line
    /// holding `characterRange` — a secret's key.
    private func gutterIconRect(forLineAt characterRange: NSRange, in textView: MultiCursorTextView) -> NSRect? {
        guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        let y = rect.midY + textView.textContainerOrigin.y - iconSize / 2
        return NSRect(x: gutterX(in: textView), y: y, width: iconSize, height: iconSize)
    }

    private func copyIconRect(for blockRange: NSRange, in textView: MultiCursorTextView) -> NSRect? {
        let firstLine = (textView.string as NSString).lineRange(for: NSRange(location: blockRange.location, length: 0))
        return gutterIconRect(forLineAt: firstLine, in: textView)
    }

    private func imageCopyIconRect(
        for imageRange: NSRange,
        indexOnLine: Int,
        in textView: MultiCursorTextView
    ) -> NSRect? {
        guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return nil }
        let line = (textView.string as NSString).lineRange(for: NSRange(location: imageRange.location, length: 0))
        let glyphs = layoutManager.glyphRange(forCharacterRange: line, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        let y = rect.maxY + textView.textContainerOrigin.y + MarkdownImagePresentation.gap + 4
            + CGFloat(indexOnLine) * MarkdownImagePresentation.stride
        return NSRect(x: gutterX(in: textView), y: y, width: iconSize, height: iconSize)
    }

    // MARK: - Fenced code block copy

    private static let fencedCodeBlock = try! NSRegularExpression(pattern: #"```[\s\S]*?```"#)

    /// Each fenced code block's full range plus its inner code (fences stripped).
    private func fencedBlocks() -> [(range: NSRange, content: String)] {
        if let cachedFencedBlocks { return cachedFencedBlocks }
        let ns = (textView?.string ?? "") as NSString
        guard ns.length > 0 else { return [] }
        var result: [(NSRange, String)] = []
        Self.fencedCodeBlock.enumerateMatches(in: ns as String,
                                              range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let range = match?.range else { return }
            var content = ns.substring(with: range)
            // Drop the opening ```lang line.
            if let firstNewline = content.firstIndex(of: "\n") {
                content = String(content[content.index(after: firstNewline)...])
            } else {
                content = ""
            }
            // Drop the closing fence (and the newline before it).
            if let close = content.range(of: "```", options: .backwards) {
                content = String(content[..<close.lowerBound])
            }
            if content.hasSuffix("\n") { content.removeLast() }
            result.append((range, content))
        }
        cachedFencedBlocks = result
        return result
    }
}

/// Borderless SF Symbol button used for the editor's gutter affordances.
final class GutterButton: NSButton {
    var onClick: (() -> Void)?

    convenience init(symbol: String, tint: NSColor, frame: NSRect, help: String) {
        self.init(frame: frame)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        title = ""
        toolTip = help
        contentTintColor = tint
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
            .withSymbolConfiguration(config) {
            image.isTemplate = true
            self.image = image
        }
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// A small color swatch placed just after an inline-code color (e.g. `#00FF3F`).
/// Clicking it copies the color string to the pasteboard.
final class ColorChipButton: NSButton {
    var onClick: (() -> Void)?
    var swatch: NSColor = .clear { didSet { needsDisplay = true } }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        swatch.setFill()
        path.fill()
        // A hairline border keeps light/white swatches visible against the page.
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
