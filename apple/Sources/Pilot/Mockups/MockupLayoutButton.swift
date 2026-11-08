import AppKit

/// Lightweight, native previews. The same layout geometry drives the stage;
/// thumbnails use drawn device silhouettes instead of loading 60 USD scenes.
@MainActor
final class MockupLayoutButton: NSButton {
    let layout: MockupLayout
    private let document: MockupDocument
    private let perform: () -> Void

    init(layout: MockupLayout, document: MockupDocument, action: @escaping () -> Void) {
        self.layout = layout
        self.document = document
        perform = action
        super.init(frame: .zero)
        title = layout.title
        isBordered = false
        setButtonType(.toggle)
        target = self
        self.action = #selector(selectLayout)
        toolTip = "\(layout.title) · \(layout.screenCount) \(layout.screenCount == 1 ? "device" : "devices")"
        setAccessibilityLabel(toolTip)
        setAccessibilityIdentifier("mockups.layout." + layout.id)
        heightAnchor.constraint(equalToConstant: 124).isActive = true
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { false }

    @objc private func selectLayout() { perform() }

    override func draw(_ dirtyRect: NSRect) {
        let card = bounds.insetBy(dx: 2, dy: 2)
        let previewBounds = CGRect(x: card.minX + 3, y: card.minY + 24, width: card.width - 6, height: card.height - 27)
        let preview = MockupAspectRatio.fit(ratio: document.aspect.ratio, in: previewBounds)
        let selected = document.layout == layout
        NSColor(white: selected ? 0.18 : 0.11, alpha: 1).setFill()
        NSBezierPath(roundedRect: card, xRadius: 9, yRadius: 9).fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: preview, xRadius: 6, yRadius: 6).addClip()
        MockupRenderer.drawBackground(document.background, in: preview)
        let devices = layout.devices(for: document.device)
        let sizes = devices.map(Self.silhouetteSize)
        let placements = layout.placements(for: document.device, in: preview.size, sizes: sizes)
        for index in placements.indices.sorted(by: { placements[$0].layer < placements[$1].layer }) {
            let placement = placements[index]
            let size = CGSize(width: sizes[index].width * placement.scale, height: sizes[index].height * placement.scale)
            NSGraphicsContext.saveGraphicsState()
            let transform = AffineTransform(translationByX: preview.minX + placement.center.x,
                                            byY: preview.minY + placement.center.y)
            (transform as NSAffineTransform).concat()
            let rotation = NSAffineTransform()
            rotation.rotate(byDegrees: placement.rotation)
            rotation.concat()
            Self.drawDevice(devices[index], size: size, image: document.screenshot(at: index))
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: selected ? .semibold : .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        let label = NSAttributedString(string: layout.title, attributes: attributes)
        label.draw(at: CGPoint(x: card.midX - label.size().width / 2, y: card.minY + 5))
        if selected || isHighlighted {
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(roundedRect: card, xRadius: 9, yRadius: 9)
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    static func silhouetteSize(_ device: MockupDevice) -> CGSize {
        // Approximate the bundled models' front silhouettes, including the
        // thin keyboard base and the iPad's Pencil.
        if device.keepsBaseLevel { return CGSize(width: 1, height: device == .macBookPro14 ? 0.68 : 0.78) }
        let ratio = device.screenPixels.width / device.screenPixels.height
        return ratio > 1 ? CGSize(width: 1, height: 1 / ratio) : CGSize(width: ratio, height: 1)
    }

    private static func drawDevice(_ device: MockupDevice, size: CGSize, image: NSImage?) {
        var body = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
        if device.keepsBaseLevel {
            body.origin.y += size.height * 0.04
            body.size.height *= 0.96
        }
        let radius = min(body.width, body.height) * (device.keepsBaseLevel ? 0.05 : 0.13)
        NSColor(white: 0.12, alpha: 1).setFill()
        let frame = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
        frame.fill()
        NSColor(white: 0.65, alpha: 1).setStroke()
        frame.lineWidth = 0.8
        frame.stroke()
        let screen = body.insetBy(dx: 1.8, dy: 1.8)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: screen, xRadius: radius * 0.7, yRadius: radius * 0.7).addClip()
        if let image {
            let scale = max(screen.width / max(image.size.width, 1), screen.height / max(image.size.height, 1))
            let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: screen.midX - target.width / 2, y: screen.midY - target.height / 2,
                                  width: target.width, height: target.height))
        } else {
            NSGradient(starting: NSColor(white: 0.32, alpha: 1), ending: NSColor(white: 0.08, alpha: 1))?.draw(in: screen, angle: 90)
        }
        NSGraphicsContext.restoreGraphicsState()
        if device.keepsBaseLevel {
            NSColor(white: 0.55, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(x: -size.width / 2 - 2, y: -size.height / 2,
                                            width: size.width + 4, height: size.height * 0.035), xRadius: 2, yRadius: 2).fill()
        } else if device != .iPhoneDuo {
            NSColor.black.setFill()
            NSBezierPath(roundedRect: CGRect(x: -body.width * 0.14, y: body.maxY - 5,
                                            width: body.width * 0.28, height: 2.5), xRadius: 1.2, yRadius: 1.2).fill()
        }
    }
}
