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

/// The studio stage: a composition of Apple's models under a soft studio rig.
/// Photo mode holds the user's pose; Video mode plays a motion preset. Both
/// render through the same scene so the preview is the export.
@MainActor
final class MockupStageView: NSView {
    private let document: MockupDocument
    private let scnView = SCNView(frame: .zero, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
    private let scene = SCNScene()
    private let cameraNode = SCNNode()
    private struct DeviceEntry {
        let key: MockupDeviceLibrary.MockupFinishKey
        let model: MockupDeviceModel
        let pivot: SCNNode
        let size: CGSize
        var screenshot: NSImage?
    }
    private var entries: [DeviceEntry] = []
    var models: [MockupDeviceModel] { entries.map(\.model) }
    var model: MockupDeviceModel? { entries.indices.contains(document.selectedScreen) ? entries[document.selectedScreen].model : nil }
    private var canvasSize = CGSize(width: 20, height: 20)
    private var currentPose = MockupPose()
    private var displayLink: CADisplayLink?
    private var playStart: CFTimeInterval = 0
    var onImportFailure: ((MockupImageLoader.Failure) -> Void)?
    var onLoadFailure: ((String) -> Void)?
    var onTimeUpdate: ((Double) -> Void)?

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
        scnView.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(selectScreen(_:))))
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

    @objc private func selectScreen(_ gesture: NSClickGestureRecognizer) {
        window?.makeFirstResponder(self)
        for hit in scnView.hitTest(gesture.location(in: scnView)) {
            var node: SCNNode? = hit.node
            while let ancestor = node {
                if let index = entries.firstIndex(where: { ancestor === $0.pivot }) {
                    document.selectedScreen = index
                    return
                }
                node = ancestor.parent
            }
        }
    }

    override func layout() {
        super.layout()
        scnView.frame = bounds
        frameCamera(aspect: bounds.height > 0 ? bounds.width / bounds.height : 1)
        apply(currentPose)
        updateBackdrop()
    }

    private func buildRig() {
        let camera = SCNCamera()
        camera.fieldOfView = 24
        // Parallel projection keeps layout positions and deliberate crops
        // stable as depth ordering changes between overlapping devices.
        camera.usesOrthographicProjection = true
        camera.zNear = 1
        camera.zFar = 400
        camera.wantsHDR = true
        camera.bloomIntensity = 0.08
        camera.wantsExposureAdaptation = false
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 100)
        scnView.pointOfView = cameraNode
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
    }

    /// One scene unit system for thumbnails, preview, and every export aspect.
    private func frameCamera(aspect: CGFloat) {
        let ratio = max(aspect, 0.01)
        let span = CGFloat(MockupDeviceModel.span)
        canvasSize = CGSize(width: span * max(1, ratio), height: span * max(1, 1 / ratio))
        cameraNode.camera?.orthographicScale = Double(canvasSize.height / 2)
    }

    // MARK: - Document → scene

    /// Re-applies document state; cheap when nothing structural changed.
    func update() {
        let keys = document.devices.map { MockupDeviceLibrary.MockupFinishKey(device: $0, finish: document.finish(for: $0)) }
        if entries.map(\.key) != keys { loadModels(keys) }
        for index in entries.indices {
            let screenshot = document.screenshot(at: index)
            if entries[index].screenshot !== screenshot {
                entries[index].model.setScreen(screenshot)
                entries[index].screenshot = screenshot
            }
        }
        updateBackdrop()
        updatePlayback()
        if displayLink == nil { apply(document.basePose) }
    }

    private func loadModels(_ keys: [MockupDeviceLibrary.MockupFinishKey]) {
        for entry in entries { entry.pivot.removeFromParentNode() }
        entries = []
        do {
            for (index, key) in keys.enumerated() {
                let model = try MockupDeviceLibrary.model(for: key.device, finish: key.finish)
                let screenshot = document.screenshot(at: index)
                model.setScreen(screenshot)
                let bounds = MockupDeviceLibrary.visibleBounds(model.node)
                let size = bounds.max - bounds.min
                let pivot = SCNNode()
                pivot.addChildNode(model.node)
                scene.rootNode.addChildNode(pivot)
                entries.append(DeviceEntry(key: key, model: model, pivot: pivot,
                                           size: CGSize(width: CGFloat(size.x / MockupDeviceModel.span),
                                                        height: CGFloat(size.y / MockupDeviceModel.span)),
                                           screenshot: screenshot))
            }
        } catch {
            for entry in entries { entry.pivot.removeFromParentNode() }
            entries = []
            onLoadFailure?("The device layout could not be loaded (\(error)).")
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
            playStart = CACurrentMediaTime() - document.playhead
            let link = displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else if !wantsLink, let link = displayLink {
            link.invalidate()
            displayLink = nil
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let duration = document.timeline.duration
        guard duration > 0 else { return }
        let elapsed = link.timestamp - playStart
        document.playhead = elapsed.truncatingRemainder(dividingBy: duration)
        apply(document.timeline.pose(at: document.playhead))
        onTimeUpdate?(document.playhead)
    }

    func apply(_ pose: MockupPose) {
        currentPose = pose
        let placements = document.layout.placements(for: document.device, in: canvasSize, sizes: entries.map(\.size))
        for (entry, placement) in zip(entries, placements) {
            let scale = Double(placement.scale) / Double(MockupDeviceModel.span) * pose.scale
            entry.pivot.eulerAngles = SCNVector3(pose.pitch, pose.yaw, pose.roll + Double(placement.rotation) * .pi / 180)
            entry.pivot.position = SCNVector3(
                Double(placement.center.x - canvasSize.width / 2) * pose.scale + pose.pan * Double(canvasSize.width),
                Double(placement.center.y - canvasSize.height / 2) * pose.scale + pose.lift * Double(canvasSize.height),
                Double(placement.layer) * 5)
            entry.pivot.scale = SCNVector3(scale, scale, scale)
            entry.model.setOpen(pose.open)
        }
    }

    // MARK: - Offscreen rendering (export)

    /// Renders one frame at `size`. Video passes a time; photo passes nil and
    /// gets the static pose. A `.none` background renders transparent.
    func render(size: CGSize, time: Double?) -> NSImage? {
        guard entries.count == document.devices.count, size.width > 0, size.height > 0,
              let device = MTLCreateSystemDefaultDevice() else { return nil }
        let renderer = SCNRenderer(device: device, options: nil)
        let previous = scene.background.contents
        let previousPose = currentPose
        let previousCanvas = canvasSize
        defer {
            scene.background.contents = previous
            frameCamera(aspect: previousCanvas.width / previousCanvas.height)
            apply(previousPose)
        }
        scene.background.contents = MockupRenderer.backgroundImage(document.background, size: size, transparentWhenNone: true)
            ?? NSColor.clear
        frameCamera(aspect: size.width / max(size.height, 1))
        apply(time.map { document.timeline.pose(at: $0) } ?? document.basePose)
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
