import AppKit
import ImageIO

/// Shared geometry between Markdown styling (which reserves the space) and the
/// text-view overlays (which draw the decoded image inside that space).
enum MarkdownImagePresentation {
    static let previewHeight: CGFloat = 220
    static let gap: CGFloat = 8
    static let stride = previewHeight + gap
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

        // A quiet surface-color shift frames the preview instead of a border
        // (LAY-2), on the shared card radius with continuous corners.
        wantsLayer = true
        layer?.cornerRadius = LiquidGlassMetrics.Radius.card
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        applySurfaceColor()

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
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        addSubview(statusLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Layer colors are resolved `CGColor` snapshots, so re-resolve the
    /// dynamic fill whenever light/dark mode changes (COL-2).
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySurfaceColor()
    }

    private func applySurfaceColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
        }
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds.insetBy(
            dx: LiquidGlassMetrics.Spacing.xSmall,
            dy: LiquidGlassMetrics.Spacing.xSmall
        )
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
        if newSuperview == nil { cancelLoading() }
        super.viewWillMove(toSuperview: newSuperview)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { cancelLoading() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startLoading() }
    }

    private func cancelLoading() {
        loadTask?.cancel()
        loadTask = nil
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

extension MultiCursorTextView {
    /// Places a fixed-height, aspect-fit preview below every Markdown image
    /// line. `MarkdownStyler` reserves the matching paragraph space, so these
    /// subviews never cover editable source or surrounding text.
    func layoutMarkdownImages() {
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

    func markdownImages() -> [MarkdownImage.Match] {
        if let cachedMarkdownImageMatches { return cachedMarkdownImageMatches }
        let matches = MarkdownImage.matches(in: string)
        cachedMarkdownImageMatches = matches
        return matches
    }
}
