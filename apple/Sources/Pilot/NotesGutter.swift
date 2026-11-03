import AppKit

final class GutterButton: NSButton {
    var onClick: (() -> Void)?

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
}

extension MultiCursorTextView {
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

    /// Gutter affordances are real buttons (custom drawing in `NSTextView.draw`
    /// doesn't composite reliably): a lock per secret line and a copy button per
    /// fenced code block, positioned in the left gutter. They live in the text
    /// view's flipped coordinate space, so they scroll with the content.
    func layoutGutterIcons() {
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
}
