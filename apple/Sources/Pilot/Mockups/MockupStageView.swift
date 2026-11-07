import AppKit
import SceneKit

/// Draws mock-up backgrounds. Shared by the live stage and every export so
/// they agree pixel-for-pixel.
@MainActor
enum MockupRenderer {
    static func drawBackground(_ background: MockupBackground, in rect: CGRect) {
        switch background {
        case .none:
            drawCheckerboard(in: rect)
        case .solid(let color):
            color.nsColor.setFill()
            rect.fill()
        case .gradient(let gradient):
            NSGradient(starting: gradient.start.nsColor, ending: gradient.end.nsColor)?.draw(in: rect, angle: gradient.angle)
        case .image(let image):
            NSColor.black.setFill()
            rect.fill()
            let scale = max(rect.width / max(image.size.width, 1), rect.height / max(image.size.height, 1))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
        }
    }

    /// Background as an image, or nil for transparent output.
    static func backgroundImage(_ background: MockupBackground, size: CGSize, transparentWhenNone: Bool) -> NSImage? {
        if transparentWhenNone, background == .none { return nil }
        return NSImage(size: size, flipped: false) { rect in
            MainActor.assumeIsolated { drawBackground(background, in: rect) }
            return true
        }
    }

    private static func drawCheckerboard(in rect: CGRect) {
        NSColor(white: 0.9, alpha: 1).setFill()
        rect.fill()
        NSColor(white: 0.78, alpha: 1).setFill()
        let cell: CGFloat = 12
        var y = rect.minY, row = 0
        while y < rect.maxY {
            var x = rect.minX + (row.isMultiple(of: 2) ? 0 : cell)
            while x < rect.maxX {
                CGRect(x: x, y: y, width: cell, height: cell).intersection(rect).fill()
                x += cell * 2
            }
            y += cell
            row += 1
        }
    }
}

/// The studio stage: one of Apple's device models under a soft studio rig.
/// Photo mode holds the user's pose; Video mode plays a motion preset. Both
/// render through the same scene so the preview is the export.
@MainActor
final class MockupStageView: NSView {
    private let document: MockupDocument
    private let scnView = SCNView(frame: .zero, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
    private let scene = SCNScene()
    private let cameraNode = SCNNode()
    private let pivot = SCNNode()
    private(set) var model: MockupDeviceModel?
    private var loaded: (MockupDevice, MockupFinish)?
    private var shownScreenshot: NSImage?
    private var displayLink: CADisplayLink?
    private var playStart: CFTimeInterval = 0
    var onImportFailure: ((MockupImageLoader.Failure) -> Void)?
    var onLoadFailure: ((String) -> Void)?

    init(document: MockupDocument) {
        self.document = document
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        scnView.scene = scene
        scnView.antialiasingMode = .multisampling4X
        scnView.backgroundColor = .clear
        scnView.setAccessibilityIdentifier("mockups.stage")
        addSubview(scnView)
        registerForDraggedTypes(MockupImageLoader.pasteboardTypes)
        setAccessibilityIdentifier("mockups.canvas")
        setAccessibilityLabel("Mock-up canvas")
        buildRig()
    }
    required init?(coder: NSCoder) { nil }

    isolated deinit { displayLink?.invalidate() }

    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    override func layout() {
        super.layout()
        scnView.frame = bounds
        frameCamera(aspect: bounds.height > 0 ? bounds.width / bounds.height : 1)
        updateBackdrop()
    }

    private func buildRig() {
        let camera = SCNCamera()
        camera.fieldOfView = 24
        camera.zNear = 1
        camera.zFar = 400
        camera.wantsHDR = true
        camera.bloomIntensity = 0.08
        camera.wantsExposureAdaptation = false
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        func light(_ type: SCNLight.LightType, intensity: CGFloat, euler: SCNVector3 = SCNVector3Zero, position: SCNVector3 = SCNVector3Zero) {
            let light = SCNLight()
            light.type = type
            light.intensity = intensity
            let node = SCNNode()
            node.light = light
            node.eulerAngles = euler
            node.position = position
            scene.rootNode.addChildNode(node)
        }
        light(.directional, intensity: 900, euler: SCNVector3(-0.7, 0.5, 0))
        light(.directional, intensity: 350, euler: SCNVector3(-0.2, -1.4, 0))
        light(.ambient, intensity: 420)
        light(.omni, intensity: 500, position: SCNVector3(-30, 25, -30))
        scene.lightingEnvironment.contents = Self.studioEnvironment
        scene.lightingEnvironment.intensity = 1.2
        scene.rootNode.addChildNode(pivot)
    }

    /// Fits the device's span into the frame with a margin, whatever the aspect.
    private func frameCamera(aspect: CGFloat) {
        let vertical = Double(cameraNode.camera?.fieldOfView ?? 24) * .pi / 180
        let half = Double(MockupDeviceModel.span) / 2 * 1.18
        let byHeight = half / tan(vertical / 2)
        let byWidth = half / (tan(vertical / 2) * Double(max(aspect, 0.01)))
        cameraNode.position = SCNVector3(0, 0, max(byHeight, byWidth) + Double(MockupDeviceModel.span) / 2)
    }

    // MARK: - Document → scene

    /// Re-applies document state; cheap when nothing structural changed.
    func update() {
        if loaded.map({ $0.0 != document.device || $0.1 != document.finish }) ?? true { loadModel() }
        if shownScreenshot !== document.screenshot {
            model?.setScreen(document.screenshot)
            shownScreenshot = document.screenshot
        }
        updateBackdrop()
        updatePlayback()
        if displayLink == nil { apply(document.basePose) }
    }

    private func loadModel() {
        model?.node.removeFromParentNode()
        model = nil
        loaded = (document.device, document.finish)
        do {
            let model = try MockupDeviceLibrary.model(for: document.device, finish: document.finish)
            model.setScreen(document.screenshot)
            pivot.addChildNode(model.node)
            self.model = model
            shownScreenshot = document.screenshot
        } catch {
            onLoadFailure?("\(document.device.name) could not be loaded (\(error)).")
        }
    }

    private func updateBackdrop() {
        let size = bounds.size
        guard size.width > 1, size.height > 1 else { return }
        scene.background.contents = MockupRenderer.backgroundImage(document.background, size: size, transparentWhenNone: false)
    }

    private func updatePlayback() {
        let wantsLink = document.kind == .video && document.isPlaying
        if wantsLink, displayLink == nil {
            playStart = CACurrentMediaTime()
            let link = displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else if !wantsLink, let link = displayLink {
            link.invalidate()
            displayLink = nil
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        apply(document.motion.pose(at: link.timestamp - playStart, base: document.basePose))
    }

    func apply(_ pose: MockupPose) {
        pivot.eulerAngles = SCNVector3(pose.pitch, pose.yaw, pose.roll)
        pivot.position = SCNVector3(0, pose.lift * Double(MockupDeviceModel.span), 0)
        pivot.scale = SCNVector3(pose.scale, pose.scale, pose.scale)
        model?.setOpen(pose.open)
    }

    // MARK: - Offscreen rendering (export)

    /// Renders one frame at `size`. Video passes a time; photo passes nil and
    /// gets the static pose. A `.none` background renders transparent.
    func render(size: CGSize, time: Double?) -> NSImage? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let renderer = SCNRenderer(device: device, options: nil)
        let previous = scene.background.contents
        defer {
            scene.background.contents = previous
            if displayLink == nil { apply(document.basePose) }
        }
        scene.background.contents = MockupRenderer.backgroundImage(document.background, size: size, transparentWhenNone: true)
            ?? NSColor.clear
        frameCamera(aspect: size.width / max(size.height, 1))
        defer { frameCamera(aspect: bounds.height > 0 ? bounds.width / bounds.height : 1) }
        apply(time.map { document.motion.pose(at: $0, base: document.basePose) } ?? document.basePose)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        return renderer.snapshot(atTime: time ?? 0, with: size, antialiasingMode: .multisampling4X)
    }

    // MARK: - Screenshot import

    @objc func paste(_ sender: Any?) { importImage(from: .general) }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { importImage(from: sender.draggingPasteboard) }

    @discardableResult
    func importImage(from pasteboard: NSPasteboard) -> Bool {
        guard let result = MockupImageLoader.load(from: pasteboard) else { return false }
        switch result {
        case .success(let image):
            document.screenshot = image
            return true
        case .failure(let failure):
            onImportFailure?(failure)
            return false
        }
    }

    /// Soft gradient environment so glass and aluminium have something to reflect.
    private static let studioEnvironment: NSImage = NSImage(size: NSSize(width: 512, height: 256), flipped: false) { rect in
        NSGradient(colors: [NSColor(white: 0.12, alpha: 1), NSColor(white: 0.55, alpha: 1), NSColor(white: 0.95, alpha: 1)])?
            .draw(in: rect, angle: 90)
        return true
    }
}
