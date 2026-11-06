import AppKit

// The NSTextView layer of the Notes editor, independent of its window and tab
// controllers.

/// A small color swatch placed just after an inline-code color (e.g. `#00FF3F`).
/// Clicking it copies the color string to the pasteboard.
final class ColorChipButton: NSButton {
    var onClick: (() -> Void)?
    var swatch: NSColor = .clear { didSet { needsDisplay = true } }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    /// The click is handled in `mouseDown` with no target/action, so a
    /// VoiceOver press would otherwise do nothing.
    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        // A round swatch, matching the ink palette and the system color well.
        let path = NSBezierPath(ovalIn: rect)
        swatch.setFill()
        path.fill()
        // A hairline border keeps light/white swatches visible against the page.
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// `NSTextView` subclass that adds ⇧⌘L "split selection into lines" — the
/// Sublime/VS Code multi-cursor gesture, which requests a collapsed insertion
/// point at the end of the selected content on each line the selection touches
/// (see `lineEndCarets(for:in:)`). `NSTextView` decides how many of those
/// zero-length ranges it keeps; current AppKit keeps only the first, so typing
/// lands at that caret.
final class MultiCursorTextView: NSTextView, NSViewToolTipOwner {
    weak var maskController: EnvMaskController?
    var onCopySecret: (() -> Void)?
    let lockSize: CGFloat = 16
    /// Set while a reflow replaces the text, so the `textDidChange` it emits
    /// cannot start another reflow.
    var isReflowing = false
    /// Reflows the edits since the last pass could affect, as recorded by
    /// `shouldChangeText`. `nil` means no edit was recorded (an edit path that
    /// bypassed it), so the next pass checks everything.
    var pendingReflowScope: ReflowScope?
    /// Post-edit UTF-16 ranges corresponding to `pendingReflowScope`; `nil`
    /// requests a conservative whole-document formatting pass.
    var pendingReflowRanges: [NSRange]?
    /// Reflows owed wherever the next edit lands: a table left unaligned
    /// because the caret was inside it, or text replaced wholesale.
    var carriedReflowScope: ReflowScope = .all
    /// Installed gutter buttons by spec key plus occurrence, so a change to
    /// one affordance (e.g. typing inside one code block) replaces only that
    /// button rather than every button in the gutter.
    var gutterButtons: [String: GutterButton] = [:]
    /// Signature of the gutter buttons currently installed. `layout()` runs on
    /// every display pass; rebuilding the gutter subviews each time
    /// (removeFromSuperview + addSubview) re-dirties Auto Layout and makes the
    /// window perpetually "need another Update Constraints pass", which AppKit
    /// eventually aborts with an NSGenericException. We only touch the subview
    /// tree when this signature actually changes.
    var gutterSignature = ""
    /// Color swatches placed after inline-code colors, with their own
    /// churn-guard signature (same rationale as `gutterSignature`).
    private var colorChips: [NSButton] = []
    private var colorChipSignature = ""
    /// Inline previews keyed by URL occurrence, so layout changes can move an
    /// in-flight view without cancelling and restarting its download.
    var imagePreviews: [String: MarkdownImagePreviewView] = [:]
    var imagePreviewSignature = ""
    /// URLs that have decoded into a real image. A gutter copy button is only
    /// offered after that point, so broken/loading previews don't imply a
    /// successful render.
    var renderedImageURLs: Set<String> = []
    /// Layout-pass scan caches: `layout()` runs on every scroll/resize pass
    /// and previously re-ran the fenced-block and color-chip regexes over the
    /// whole document each time. The scans depend only on the text, so they
    /// hold until it changes — typing and the programmatic reflows both funnel
    /// through `didChangeText()`, and external model updates push via `string`.
    var cachedFencedBlocks: [(range: NSRange, content: String)]?
    private var cachedColorChipMatches: [ColorChip.Match]?
    var cachedMarkdownImageMatches: [MarkdownImage.Match]?

    /// Keep the editable storage plaintext while exposing the controller's
    /// redacted presentation to assistive technologies. Calling
    /// `setAccessibilityValue` on NSTextView edits the document and emits
    /// `textDidChange`, so masking must be implemented as a getter only.
    override func accessibilityValue() -> String? {
        maskController?.accessibilityText ?? super.accessibilityValue()
    }

    private func invalidateTextScanCaches() {
        cachedFencedBlocks = nil
        cachedColorChipMatches = nil
        cachedMarkdownImageMatches = nil
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateTextScanCaches()
    }

    override var string: String {
        get { super.string }
        set {
            super.string = newValue
            invalidateTextScanCaches()
            // Programmatic replacement bypasses `shouldChangeText`; settle
            // everything on the next edit.
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

    /// Single-click on a link (bare URL or markdown link) opens it in the
    /// user's default browser via NSWorkspace.
    private func openLink(at event: NSEvent) -> Bool {
        guard event.clickCount == 1, let layoutManager, let textContainer, let textStorage else { return false }
        let ns = string as NSString
        guard ns.length > 0 else { return false }

        let viewPoint = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        let containerPoint = NSPoint(x: viewPoint.x - origin.x, y: viewPoint.y - origin.y)

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

    override func layout() {
        super.layout()
        layoutMarkdownImages()
        layoutGutterIcons()
        layoutColorChips()
    }

    /// Places a clickable color swatch just after each inline-code span whose
    /// content is a color (e.g. `#00FF3F`, `rgb(...)`, `oklch(...)`, `cmyk(...)`).
    /// Clicking the swatch copies the color string. Same signature-guard
    /// discipline as the gutter icons so repeated layout passes don't churn the
    /// subview tree.
    private func layoutColorChips() {
        guard let layoutManager, let textContainer else { return }
        let ns = string as NSString
        let chipSize: CGFloat = 12
        let origin = textContainerOrigin

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
            chip.setAccessibilityLabel("Copy \(spec.value)")
            let value = spec.value
            chip.onClick = { [weak self] in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(value, forType: .string)
                self?.onCopySecret?()
            }
            addSubview(chip)
            colorChips.append(chip)
        }
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
        layoutGutterIcons()
        layoutColorChips()
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
        let viewPoint = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        let containerPoint = NSPoint(x: viewPoint.x - origin.x, y: viewPoint.y - origin.y)

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

    private static let taskCheckbox = try! NSRegularExpression(
        pattern: #"^[ \t]*[-*+][ \t]+(\[[ xX]\])"#
    )

    private func toggleTaskCheckbox(at event: NSEvent) -> Bool {
        guard let layoutManager, let textContainer, let textStorage else { return false }
        let ns = string as NSString
        guard ns.length > 0 else { return false }

        let viewPoint = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        let containerPoint = NSPoint(x: viewPoint.x - origin.x, y: viewPoint.y - origin.y)

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
