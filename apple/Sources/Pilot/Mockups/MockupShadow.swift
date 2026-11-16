import AppKit

/// The drop shadow the devices cast on the backdrop. It is a 2D effect laid
/// under the rendered device layer, not a 3D light: a light in the scene would
/// also change how the device and its screen are shaded.
struct MockupShadow: Equatable, Codable {
    enum Style: String, CaseIterable, Codable {
        case none, spread, hug

        var title: String {
            switch self {
            case .none: "None"
            case .spread: "Spread"
            case .hug: "Hug"
            }
        }
    }

    enum Intensity: String, CaseIterable, Codable {
        case low, medium, high

        var title: String { rawValue.capitalized }

        var opacity: CGFloat {
            switch self {
            case .low: 0.28
            case .medium: 0.5
            case .high: 0.78
            }
        }
    }

    var style: Style = .spread
    var intensity: Intensity = .medium
    /// Where the light sits over the canvas, in unit coordinates with the
    /// origin at the bottom-left. The shadow falls away from it.
    var lightX: CGFloat = 0.5
    var lightY: CGFloat = 0.78

    var isVisible: Bool { style != .none }

    /// Blur as a fraction of the canvas's shorter side.
    var blur: CGFloat {
        switch style {
        case .none: 0
        case .spread: 0.09
        case .hug: 0.03
        }
    }

    /// Offset as a fraction of the canvas's shorter side. A light over the
    /// centre casts an even halo; moving it pushes the shadow the other way.
    var offset: CGVector {
        let reach: CGFloat = switch style {
        case .none: 0
        case .spread: 0.2
        case .hug: 0.07
        }
        return CGVector(dx: (0.5 - lightX) * reach, dy: (0.5 - lightY) * reach)
    }

    mutating func setLight(x: CGFloat, y: CGFloat) {
        lightX = min(max(x, 0), 1)
        lightY = min(max(y, 0), 1)
    }

    /// Arms `context` so the next thing drawn casts this shadow. `shift`
    /// moves the shadow without moving its caster, for drawing a shadow alone.
    func apply(to context: CGContext, canvas: CGSize, shift: CGFloat = 0) {
        let side = min(canvas.width, canvas.height)
        context.setShadow(offset: CGSize(width: offset.dx * side + shift, height: offset.dy * side), blur: blur * side,
                          color: CGColor(gray: 0, alpha: intensity.opacity))
    }
}

extension MockupRenderer {
    /// Only the shadow `devices` casts, for the live stage, where the devices
    /// themselves are drawn by the 3D view above it.
    static func shadowImage(of devices: CGImage, shadow: MockupShadow, size: CGSize) -> NSImage? {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard shadow.isVisible, width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // The caster is drawn off-canvas and its shadow shifted back on.
        let shift = CGFloat(width) * 2
        shadow.apply(to: context, canvas: size, shift: shift)
        context.draw(devices, in: CGRect(x: -shift, y: 0, width: CGFloat(width), height: CGFloat(height)))
        return context.makeImage().map { NSImage(cgImage: $0, size: size) }
    }
}

/// Inspector section: shadow style, intensity, and a pad for the light.
@MainActor
final class MockupShadowPanel: NSStackView {
    private let document: MockupDocument
    private let styleControl = NSSegmentedControl(labels: MockupShadow.Style.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let intensityControl = NSSegmentedControl(labels: MockupShadow.Intensity.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let intensityLabel = RRUI.label("Intensity", size: 12, color: .secondaryLabelColor)
    private let lightLabel = RRUI.label("Light Source", size: 12, color: .secondaryLabelColor)
    let lightPad: MockupLightPad
    private lazy var resetButton = RRButton("Reset Shadow", symbol: "arrow.uturn.backward") { [weak self] in
        self?.document.shadow = MockupShadow()
    }

    init(document: MockupDocument) {
        self.document = document
        lightPad = MockupLightPad(document: document)
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        for (control, label, action) in [(styleControl, "Shadow style", #selector(changeStyle)),
                                         (intensityControl, "Shadow intensity", #selector(changeIntensity))] {
            control.controlSize = .large
            control.applyCockpitGlassStyle()
            control.target = self
            control.action = action
            control.setAccessibilityLabel(label)
        }
        styleControl.setAccessibilityIdentifier("mockups.shadow-style")
        intensityControl.setAccessibilityIdentifier("mockups.shadow-intensity")
        let views: [NSView] = [RRUI.label("Shadow", size: 15, weight: .semibold), styleControl, intensityLabel,
                               intensityControl, lightLabel, lightPad, resetButton]
        for view in views { addArrangedSubview(view) }
        for view in [styleControl, intensityControl, lightPad] as [NSView] {
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        lightPad.heightAnchor.constraint(equalToConstant: 150).isActive = true
        resetButton.applyCockpitGlassStyle()
        refresh()
    }
    required init?(coder: NSCoder) { nil }

    func refresh() {
        let shadow = document.shadow
        styleControl.selectedSegment = MockupShadow.Style.allCases.firstIndex(of: shadow.style) ?? 0
        intensityControl.selectedSegment = MockupShadow.Intensity.allCases.firstIndex(of: shadow.intensity) ?? 0
        intensityControl.isEnabled = shadow.isVisible
        for view in [intensityLabel, intensityControl, lightLabel, lightPad] as [NSView] { view.alphaValue = shadow.isVisible ? 1 : 0.4 }
        resetButton.isEnabled = shadow != MockupShadow()
        lightPad.needsDisplay = true
    }

    @objc private func changeStyle() {
        let styles = MockupShadow.Style.allCases
        if styles.indices.contains(styleControl.selectedSegment) { document.shadow.style = styles[styleControl.selectedSegment] }
    }

    @objc private func changeIntensity() {
        let levels = MockupShadow.Intensity.allCases
        if levels.indices.contains(intensityControl.selectedSegment) { document.shadow.intensity = levels[intensityControl.selectedSegment] }
    }
}

/// A small canvas stand-in: drag the sun to move the light. It previews the
/// shadow on the current backdrop with the same math the export uses.
@MainActor
final class MockupLightPad: NSView {
    private let document: MockupDocument
    private static let knob: CGFloat = 26

    init(document: MockupDocument) {
        self.document = document
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Light source")
        setAccessibilityIdentifier("mockups.shadow-light")
    }
    required init?(coder: NSCoder) { nil }

    override func accessibilityValue() -> Any? {
        "\(Int((document.shadow.lightX * 100).rounded()))% across, \(Int((document.shadow.lightY * 100).rounded()))% up"
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        MockupRenderer.drawBackground(document.background, in: bounds)
        let shadow = document.shadow
        let height = bounds.height * 0.72, width = height * 0.49
        let device = CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
        context.saveGState()
        if shadow.isVisible {
            // Shadow offsets are in device pixels, which the backing scale multiplies.
            let scale = window?.backingScaleFactor ?? 1
            shadow.apply(to: context, canvas: CGSize(width: bounds.width * scale, height: bounds.height * scale))
        }
        NSColor(white: 0.08, alpha: 1).setFill()
        NSBezierPath(roundedRect: device, xRadius: width * 0.16, yRadius: width * 0.16).fill()
        context.restoreGState()
        guard shadow.isVisible else { return }
        let centre = CGPoint(x: bounds.minX + shadow.lightX * bounds.width, y: bounds.minY + shadow.lightY * bounds.height)
        let knob = CGRect(x: centre.x - Self.knob / 2, y: centre.y - Self.knob / 2, width: Self.knob, height: Self.knob)
        NSColor(white: 1, alpha: 0.92).setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSColor(white: 0, alpha: 0.25).setStroke()
        NSBezierPath(ovalIn: knob.insetBy(dx: 0.5, dy: 0.5)).stroke()
        if let sun = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold).applying(.init(paletteColors: [.black]))) {
            sun.draw(in: CGRect(x: centre.x - sun.size.width / 2, y: centre.y - sun.size.height / 2,
                                width: sun.size.width, height: sun.size.height))
        }
    }

    override func mouseDown(with event: NSEvent) { moveLight(event) }
    override func mouseDragged(with event: NSEvent) { moveLight(event) }

    private func moveLight(_ event: NSEvent) {
        guard document.shadow.isVisible, bounds.width > 0, bounds.height > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        setLight(x: (point.x - bounds.minX) / bounds.width, y: (point.y - bounds.minY) / bounds.height)
    }

    func setLight(x: CGFloat, y: CGFloat) {
        document.shadow.setLight(x: x, y: y)
        needsDisplay = true
    }
}
