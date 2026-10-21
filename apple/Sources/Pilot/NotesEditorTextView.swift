import AppKit
import ImageIO
import SwiftUI

// The NSTextView layer of the Notes editor: gutter affordances, inline image
// previews, and the multi-cursor text view. Split from NotesView.swift so the
// SwiftUI composition and the AppKit text machinery each have one owner.

final class GutterButton: NSButton {
    var onClick: (() -> Void)?

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

/// Streams and downsamples image data away from the main actor. The byte cap
/// applies while reading, not after allocation, and preview-sized decoding
/// avoids expanding a large source image at full resolution.
private enum MarkdownImagePayload: @unchecked Sendable {
    case raster(CGImage)
    case svg(Data)
}

private actor MarkdownImageLoader {
    static let shared = MarkdownImageLoader()

    private let maximumDownloadBytes = 25 * 1_024 * 1_024
    private let streamChunkBytes = 64 * 1_024
    private let maximumPreviewPixels = 1_440
    private let maximumSVGBytes = 5 * 1_024 * 1_024

    func image(from url: URL) async throws -> MarkdownImagePayload {
        let data = url.isFileURL
            ? try boundedFileData(from: url)
            : try await boundedRemoteData(from: url)
        try Task.checkCancellation()

        if let source = CGImageSourceCreateWithData(data as CFData, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPreviewPixels,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return .raster(image)
            }
        }

        // AppKit supports SVG even though ImageIO doesn't expose it as a
        // raster source. Keep this fallback narrower than the general byte cap
        // because parsing vector markup happens when NSImage is constructed.
        guard data.count <= maximumSVGBytes, Self.looksLikeSVG(data) else {
            throw URLError(.cannotDecodeContentData)
        }
        return .svg(data)
    }

    private nonisolated static func looksLikeSVG(_ data: Data) -> Bool {
        let prefix = data.prefix(64 * 1_024)
        guard let text = String(data: prefix, encoding: .utf8)?.lowercased() else { return false }
        return text.contains("<svg")
    }

    private func boundedRemoteData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .returnCacheDataElseLoad
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        if response.expectedContentLength > Int64(maximumDownloadBytes) {
            throw URLError(.dataLengthExceedsMaximum)
        }

        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(response.expectedContentLength), maximumDownloadBytes))
        }
        var chunk: [UInt8] = []
        chunk.reserveCapacity(streamChunkBytes)
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count + chunk.count < maximumDownloadBytes else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            chunk.append(byte)
            if chunk.count == streamChunkBytes {
                data.append(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        data.append(contentsOf: chunk)
        return data
    }

    private func boundedFileData(from url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values.fileSize, size > maximumDownloadBytes {
            throw URLError(.dataLengthExceedsMaximum)
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        if let size = values.fileSize { data.reserveCapacity(size) }
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: streamChunkBytes) ?? Data()
            guard data.count + chunk.count <= maximumDownloadBytes else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            if chunk.isEmpty { return data }
            data.append(chunk)
        }
    }
}

/// Async image preview used by the live Markdown editor. Loading and failure
/// states stay visible in the reserved area; only a successful decode calls
/// `onRender`, which enables the matching gutter copy button.
final class MarkdownImagePreviewView: NSView {
    private static let cache = NSCache<NSURL, NSImage>()

    private let imageView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var loadTask: Task<Void, Never>?
    private let sourceURL: URL
    private let sourceURLString: String
    private let onRender: (String) -> Void

    init(frame: NSRect, match: MarkdownImage.Match, onRender: @escaping (String) -> Void) {
        sourceURL = match.url
        sourceURLString = match.urlString
        self.onRender = onRender
        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        layer?.borderWidth = 0.5
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        imageView.setAccessibilityLabel(match.altText.isEmpty ? "Markdown image" : match.altText)
        addSubview(imageView)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        addSubview(spinner)

        statusLabel.stringValue = match.altText.isEmpty ? "Loading image…" : "Loading \(match.altText)…"
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = .systemFont(ofSize: 11)
        addSubview(statusLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        imageView.frame = bounds.insetBy(dx: 10, dy: 10)
        spinner.frame = NSRect(x: bounds.midX - 8, y: bounds.midY - 18, width: 16, height: 16)
        statusLabel.frame = NSRect(x: 12, y: bounds.midY + 4, width: max(0, bounds.width - 24), height: 18)
    }

    func update(frame: NSRect, altText: String) {
        if self.frame != frame { self.frame = frame }
        imageView.setAccessibilityLabel(altText.isEmpty ? "Markdown image" : altText)
        if !spinner.isHidden {
            statusLabel.stringValue = altText.isEmpty ? "Loading image…" : "Loading \(altText)…"
        }
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil { loadTask?.cancel() }
        super.viewWillMove(toSuperview: newSuperview)
    }

    func startLoading() {
        guard loadTask == nil, imageView.image == nil else { return }
        loadImage()
    }

    private func loadImage() {
        if let cached = Self.cache.object(forKey: sourceURL as NSURL) {
            show(cached)
            return
        }

        let url = sourceURL
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let decoded = try await MarkdownImageLoader.shared.image(from: url)
                try Task.checkCancellation()
                let image: NSImage
                switch decoded {
                case .raster(let cgImage):
                    image = NSImage(cgImage: cgImage, size: .zero)
                case .svg(let data):
                    guard let svgImage = NSImage(data: data) else {
                        throw URLError(.cannotDecodeContentData)
                    }
                    image = svgImage
                }
                Self.cache.setObject(image, forKey: url as NSURL)
                show(image)
            } catch is CancellationError {
                return
            } catch {
                showFailure()
            }
        }
    }

    private func show(_ image: NSImage) {
        guard !Task.isCancelled else { return }
        imageView.image = image
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        statusLabel.isHidden = true
        onRender(sourceURLString)
    }

    private func showFailure() {
        guard !Task.isCancelled else { return }
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        imageView.image = NSImage(
            systemSymbolName: "photo.badge.exclamationmark",
            accessibilityDescription: "Image failed to load"
        )
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        statusLabel.stringValue = "Couldn’t load image"
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
    private let lockSize: CGFloat = 16
    /// Set while a reflow replaces the text, so the `textDidChange` it emits
    /// cannot start another reflow.
    private var isReflowing = false
    /// Reflows the edits since the last pass could affect, as recorded by
    /// `shouldChangeText`. `nil` means no edit was recorded (an edit path that
    /// bypassed it), so the next pass checks everything.
    private var pendingReflowScope: ReflowScope?
    /// Reflows owed wherever the next edit lands: a table left unaligned
    /// because the caret was inside it, or text replaced wholesale.
    private var carriedReflowScope: ReflowScope = .all
    /// Installed gutter buttons by spec key plus occurrence, so a change to
    /// one affordance (e.g. typing inside one code block) replaces only that
    /// button rather than every button in the gutter.
    private var gutterButtons: [String: GutterButton] = [:]
    /// Signature of the gutter buttons currently installed. `layout()` runs on
    /// every display pass; rebuilding the gutter subviews each time
    /// (removeFromSuperview + addSubview) re-dirties Auto Layout and makes the
    /// window perpetually "need another Update Constraints pass", which AppKit
    /// eventually aborts with an NSGenericException. We only touch the subview
    /// tree when this signature actually changes.
    private var gutterSignature = ""
    /// Color swatches placed after inline-code colors, with their own
    /// churn-guard signature (same rationale as `gutterSignature`).
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
    /// Layout-pass scan caches: `layout()` runs on every scroll/resize pass
    /// and previously re-ran the fenced-block and color-chip regexes over the
    /// whole document each time. The scans depend only on the text, so they
    /// hold until it changes — typing and the programmatic reflows both funnel
    /// through `didChangeText()`, and SwiftUI's binding pushes via `string`.
    private var cachedFencedBlocks: [(range: NSRange, content: String)]?
    private var cachedColorChipMatches: [ColorChip.Match]?
    private var cachedMarkdownImageMatches: [MarkdownImage.Match]?

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

    // MARK: - Per-line secret lock toggle (always shown in the left gutter)

    private func lockRect(for match: EnvSecret.Match) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: match.keyRange, actualCharacterRange: nil)
        let keyRect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        let origin = textContainerOrigin
        // Centered in the left gutter (the area left of the text), on the
        // secret's line.
        let x = max(4, (origin.x - lockSize) / 2)
        let y = keyRect.midY + origin.y - lockSize / 2
        return NSRect(x: x, y: y, width: lockSize, height: lockSize)
    }

    override func layout() {
        super.layout()
        layoutMarkdownImages()
        layoutGutterIcons()
        layoutColorChips()
    }

    /// Places a fixed-height, aspect-fit preview below every Markdown image
    /// line. `MarkdownStyler` reserves the matching paragraph space, so these
    /// subviews never cover editable source or surrounding text.
    private func layoutMarkdownImages() {
        guard let layoutManager, let textContainer else { return }
        let ns = string as NSString
        let matches = markdownImages()
        renderedImageURLs.formIntersection(Set(matches.map(\.urlString)))

        let origin = textContainerOrigin
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
                self.needsLayout = true
            }
            addSubview(preview)
            imagePreviews[spec.key] = preview
            preview.startLoading()
        }
    }

    private func markdownImages() -> [MarkdownImage.Match] {
        if let cachedMarkdownImageMatches { return cachedMarkdownImageMatches }
        let matches = MarkdownImage.matches(in: string)
        cachedMarkdownImageMatches = matches
        return matches
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

    /// Gutter affordances are real buttons (custom drawing in `NSTextView.draw`
    /// doesn't composite reliably): a lock per secret line and a copy button per
    /// fenced code block, positioned in the left gutter. They live in the text
    /// view's flipped coordinate space, so they scroll with the content.
    private func layoutGutterIcons() {
        // Build the desired button specs first, derive a signature, and bail
        // before touching the subview tree if nothing changed since the last
        // pass. Mutating subviews inside `layout()` on every pass is what trips
        // the window's Update-Constraints budget (see `gutterSignature`).
        struct Spec {
            let symbol: String
            let tint: NSColor
            let frame: NSRect
            let help: String
            let key: String
            let action: () -> Void
        }
        var specs: [Spec] = []

        if let maskController {
            for secret in maskController.secrets {
                guard let rect = lockRect(for: secret) else { continue }
                let revealed = maskController.isRevealed(secret.key)
                let key = secret.key
                specs.append(Spec(
                    symbol: revealed ? "lock.open.fill" : "lock.fill",
                    tint: revealed ? .controlAccentColor : .secondaryLabelColor,
                    frame: rect,
                    help: revealed ? "Hide value" : "Reveal value",
                    key: "S|\(key)|\(revealed)"
                ) { [weak self] in
                    self?.maskController?.toggleReveal(key)
                })
            }
        }

        for block in fencedBlocks() {
            guard let rect = copyIconRect(for: block.range) else { continue }
            let content = block.content
            specs.append(Spec(
                symbol: "doc.on.doc",
                tint: .secondaryLabelColor,
                frame: rect,
                help: "Copy code block",
                key: "C|\(content.hashValue)"
            ) { [weak self] in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(content, forType: .string)
                self?.onCopySecret?()
            })
        }

        var imageIndicesByLine: [Int: Int] = [:]
        let noteText = string as NSString
        for image in markdownImages() where renderedImageURLs.contains(image.urlString) {
            let lineRange = noteText.lineRange(for: NSRange(location: image.range.location, length: 0))
            let imageIndex = imageIndicesByLine[lineRange.location, default: 0]
            imageIndicesByLine[lineRange.location] = imageIndex + 1
            guard let rect = imageCopyIconRect(for: image.range, indexOnLine: imageIndex) else { continue }
            let urlString = image.urlString
            specs.append(Spec(
                symbol: "link",
                tint: .secondaryLabelColor,
                frame: rect,
                help: "Copy image URL",
                key: "I|\(image.range.location)|\(urlString)"
            ) { [weak self] in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(urlString, forType: .string)
                self?.onCopySecret?()
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
                button = makeGutterButton(symbol: spec.symbol, tint: spec.tint,
                                          frame: spec.frame, help: spec.help)
                addSubview(button)
            }
            button.onClick = spec.action
            installed[id] = button
        }
        gutterButtons.values.forEach { $0.removeFromSuperview() }
        gutterButtons = installed
    }

    private func makeGutterButton(symbol: String, tint: NSColor, frame: NSRect,
                                  help: String) -> GutterButton {
        let button = GutterButton(frame: frame)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = help
        button.contentTintColor = tint
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
            .withSymbolConfiguration(config) {
            image.isTemplate = true
            button.image = image
        }
        return button
    }

    // MARK: - Fenced code block copy

    private static let fencedCodeBlock = try! NSRegularExpression(pattern: #"```[\s\S]*?```"#)

    /// Each fenced code block's full range plus its inner code (fences stripped).
    /// Cached between text changes — see `cachedFencedBlocks`.
    private func fencedBlocks() -> [(range: NSRange, content: String)] {
        if let cachedFencedBlocks { return cachedFencedBlocks }
        let ns = string as NSString
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

    private func copyIconRect(for blockRange: NSRange) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let firstLine = (string as NSString).lineRange(for: NSRange(location: blockRange.location, length: 0))
        let glyphs = layoutManager.glyphRange(forCharacterRange: firstLine, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        let origin = textContainerOrigin
        let x = max(4, (origin.x - lockSize) / 2)
        return NSRect(x: x, y: rect.midY + origin.y - lockSize / 2, width: lockSize, height: lockSize)
    }

    private func imageCopyIconRect(for imageRange: NSRange, indexOnLine: Int) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let line = (string as NSString).lineRange(for: NSRange(location: imageRange.location, length: 0))
        let glyphs = layoutManager.glyphRange(forCharacterRange: line, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        let origin = textContainerOrigin
        let x = max(4, (origin.x - lockSize) / 2)
        let y = rect.maxY + origin.y + MarkdownImagePresentation.gap + 4
            + CGFloat(indexOnLine) * MarkdownImagePresentation.stride
        return NSRect(x: x, y: y, width: lockSize, height: lockSize)
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

    // MARK: - Automatic reflows

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

    private func recordReflowScope(for ranges: [NSRange], replacements: [String]?) {
        guard !isReflowing else { return }
        let ns = string as NSString
        var scope = pendingReflowScope ?? []
        for (index, range) in ranges.enumerated() where scope != .all {
            guard NSMaxRange(range) <= ns.length else {
                scope = .all
                break
            }
            let replacement = replacements.flatMap { index < $0.count ? $0[index] : nil } ?? ""
            scope.formUnion(Self.reflowScope(of: range, replacement: replacement, in: ns))
        }
        pendingReflowScope = scope
    }

    /// Runs the per-edit automatic formatting: completed tasks sink, then
    /// tables align (skipping the table under the caret). Only the reflows
    /// the recorded edits could affect run, so ordinary typing away from
    /// tasks and tables doesn't re-scan the note.
    func applyAutomaticReflows() {
        guard !isReflowing else { return }
        // Undo/redo replay, or an IME composition still in progress: rewriting
        // the text now would land under the replayed edits or break the marked
        // text. The recorded scope stays pending for the next edit.
        if let undoManager, undoManager.isUndoing || undoManager.isRedoing { return }
        if hasMarkedText() { return }

        let scope = (pendingReflowScope ?? .all).union(carriedReflowScope)
        pendingReflowScope = nil
        carriedReflowScope = []
        var tasksChanged = false
        if scope.contains(.tasks) {
            tasksChanged = reorderCompletedTasks()
        }
        if scope.contains(.tables) || tasksChanged {
            formatMarkdownTables()
        }
    }

    /// Auto-sort every contiguous task group so incomplete root tasks stay on
    /// top and completed roots sink to the bottom. Indented subtasks move with
    /// their root as one block, so checking a child never detaches or reorders
    /// it. A no-op unless some group is actually out of order.
    @discardableResult
    func reorderCompletedTasks() -> Bool {
        applyReflow { MarkdownTaskFormatter.reflow($0) }
    }

    /// Align markdown tables to fit their content (issue #79). When
    /// `protectingCaret` is true the table block the caret sits in is left
    /// alone, so alignment never fights the cursor while you're typing inside
    /// a cell.
    @discardableResult
    func formatMarkdownTables(protectingCaret: Bool = true) -> Bool {
        // A table needs a pipe somewhere; checking before the caret-line scan
        // (not just inside `reflow`) keeps pipe-free notes allocation-free on
        // every keystroke.
        guard string.contains("|") else { return false }

        var skippedTableNeedsFormatting = false
        let changed = applyReflow { text in
            let skip: Set<Int> = protectingCaret ? caretLineIndices() : []
            let result = MarkdownTableFormatter.reflowReportingSkipped(text, skipLines: skip)
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
