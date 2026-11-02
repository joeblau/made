import AppKit
import Metal
import SceneKit
import SwiftUI

struct RunnerFleetItem: Equatable, Identifiable {
    let id: Int
    let name: String
    let state: GitHubRunner.State
    let hardware: RunnerHardware
}

/// Apple's public Mac mini AR model, merged once into a shared template so
/// each runner costs one draw call per material. Provenance and the
/// regeneration path are in docs/runner-fleet-model.md.
@MainActor
enum MacMiniModel {
    struct Template {
        let body: SCNNode
        let statusLight: SCNNode
    }

    static let template: Template? = Bundle.main.url(forResource: "MacMini", withExtension: "usdz").flatMap { load($0) }

    static func load(_ url: URL) -> Template? {
        guard let scene = try? SCNScene(url: url) else { return nil }
        let lights = statusLights(in: scene.rootNode)
        guard lights.count == 1, let light = lights.first else { return nil }
        let statusLight = light.clone()
        light.removeFromParentNode()
        guard let body = merged(scene.rootNode) else { return nil }
        polishAluminum(body)
        return Template(body: SCNNode(geometry: body), statusLight: statusLight)
    }

    /// Apple's AR file is tuned for neutral AR lighting; under the fleet's dark
    /// studio it reads flat gray. A warmer, smoother finish catches the key and
    /// rim lights the way the mockup's champagne-silver cases do.
    private static func polishAluminum(_ geometry: SCNGeometry) {
        for material in geometry.materials {
            guard let color = (material.diffuse.contents as? NSColor)?.usingColorSpace(.deviceRGB),
                  abs(color.redComponent - 0.66) < 0.05, abs(color.blueComponent - 0.69) < 0.05 else { continue }
            material.diffuse.contents = NSColor(red: 0.92, green: 0.9, blue: 0.88, alpha: 1)
            // Mostly metal, with enough diffuse response for the overhead key to light the lid.
            material.metalness.contents = 0.7
            material.roughness.contents = 0.3
        }
    }

    /// The status light is the only tiny flat disc on the front face. Apple's
    /// export scrambles node names, so it is found by geometry instead.
    static func statusLights(in root: SCNNode) -> [SCNNode] {
        let front = root.boundingBox.max.z
        return root.childNodes { node, _ in
            guard node.geometry != nil else { return false }
            let (low, high) = node.boundingBox
            let min = node.convertPosition(low, to: root), max = node.convertPosition(high, to: root)
            return abs(max.z - min.z) < 0.05 && abs(max.x - min.x) < 0.3 && max.z > front - 0.05
        }
    }

    /// Combines every mesh into one geometry with an element per material name.
    /// `flattenedClone()` returns an empty geometry for this file's
    /// multi-channel polygon elements, and a plain clone costs over 70 draw
    /// calls per runner.
    static func merged(_ root: SCNNode) -> SCNGeometry? {
        var positions: [SCNVector3] = [], normals: [SCNVector3] = []
        var uv0: [CGPoint] = [], uv1: [CGPoint] = []
        var groups: [(name: String, material: SCNMaterial, indices: [UInt32])] = []
        root.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry, !geometry.materials.isEmpty else { return }
            let sources = geometry.sources
            guard let vertexSlot = sources.firstIndex(where: { $0.semantic == .vertex }) else { return }
            let normalSlot = sources.firstIndex { $0.semantic == .normal }
            let uvSlots = sources.indices.filter { sources[$0].semantic == .texcoord }
            let values = sources.map(floats)
            let transform = node.simdConvertTransform(matrix_identity_float4x4, to: root)
            let rotation = simd_float3x3(transform.columns.0.xyz, transform.columns.1.xyz, transform.columns.2.xyz)
            for (index, element) in geometry.elements.enumerated() {
                let channels = max(element.indicesChannelCount, 1)
                // Index channels follow source order; single-channel elements share one index.
                func value(_ slot: Int?, _ corner: [UInt32]) -> SIMD3<Float> {
                    guard let slot else { return .zero }
                    let position = Int(corner[channels > 1 ? min(slot, corner.count - 1) : 0])
                    return position < values[slot].count ? values[slot][position] : .zero
                }
                let start = UInt32(positions.count)
                for corner in triangleCorners(element) {
                    positions.append(SCNVector3((transform * SIMD4(value(vertexSlot, corner), 1)).xyz))
                    let normal = rotation * value(normalSlot, corner)
                    normals.append(SCNVector3(simd_length(normal) > 0 ? simd_normalize(normal) : SIMD3(0, 1, 0)))
                    let first = value(uvSlots.first, corner), second = uvSlots.count > 1 ? value(uvSlots[1], corner) : first
                    uv0.append(CGPoint(x: CGFloat(first.x), y: CGFloat(first.y)))
                    uv1.append(CGPoint(x: CGFloat(second.x), y: CGFloat(second.y)))
                }
                let indices = Array(start..<UInt32(positions.count))
                let material = geometry.materials[index % geometry.materials.count]
                let name = material.name ?? "\(ObjectIdentifier(material))"
                if let group = groups.firstIndex(where: { $0.name == name }) {
                    groups[group].indices += indices
                } else {
                    groups.append((name, material, indices))
                }
            }
        }
        guard !positions.isEmpty, !groups.isEmpty else { return nil }
        let geometry = SCNGeometry(
            sources: [
                SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals),
                SCNGeometrySource(textureCoordinates: uv0), SCNGeometrySource(textureCoordinates: uv1),
            ],
            elements: groups.map { SCNGeometryElement(indices: $0.indices, primitiveType: .triangles) }
        )
        geometry.materials = groups.map(\.material)
        return geometry
    }

    /// Reads a float source as 3-vectors; 2-component sources leave z at zero.
    private static func floats(_ source: SCNGeometrySource) -> [SIMD3<Float>] {
        guard source.usesFloatComponents, source.bytesPerComponent == 4 else {
            return Array(repeating: .zero, count: source.vectorCount)
        }
        let components = min(source.componentsPerVector, 3)
        return source.data.withUnsafeBytes { raw in
            (0..<source.vectorCount).map { vector in
                var value = SIMD3<Float>.zero
                for component in 0..<components {
                    let offset = source.dataOffset + vector * source.dataStride + component * 4
                    guard offset + 4 <= raw.count else { break }
                    value[component] = raw.loadUnaligned(fromByteOffset: offset, as: Float.self)
                }
                return value
            }
        }
    }

    /// Each triangle corner's per-channel indices; polygons are fanned. Polygon
    /// data lists every face's corner count first, then the corner indices.
    private static func triangleCorners(_ element: SCNGeometryElement) -> [[UInt32]] {
        let width = element.bytesPerIndex
        guard [2, 4].contains(width), [.triangles, .polygon].contains(element.primitiveType) else { return [] }
        let values: [UInt32] = element.data.withUnsafeBytes { raw in
            (0..<(raw.count / width)).map { index in
                width == 4
                    ? raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
                    : UInt32(raw.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self))
            }
        }
        let faces = element.primitiveCount
        let isPolygon = element.primitiveType == .polygon
        let header = isPolygon ? faces : 0
        guard values.count >= header else { return [] }
        let counts = isPolygon ? values[0..<faces].map(Int.init) : Array(repeating: 3, count: faces)
        let channels = max(element.indicesChannelCount, 1)
        let total = counts.reduce(0, +)
        guard values.count >= header + total * channels else { return [] }
        func corner(_ position: Int) -> [UInt32] {
            (0..<channels).map { channel in
                element.hasInterleavedIndicesChannels || channels == 1
                    ? values[header + position * channels + channel]
                    : values[header + channel * total + position]
            }
        }
        var result: [[UInt32]] = []
        var cursor = 0
        for count in counts {
            if count >= 3 {
                for offset in 1..<(count - 1) {
                    result += [corner(cursor), corner(cursor + offset), corner(cursor + offset + 1)]
                }
            }
            cursor += count
        }
        return result
    }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}

/// Builds and animates the 3D fleet. Owned by the view on the main actor;
/// SceneKit renders it on its own thread.
@MainActor
final class RunnerFleetScene {
    /// Narrow, like a long lens, so far rows stay close to the size of near ones.
    static let fieldOfView: Float = 18
    /// Hit tests use this category so floor glows don't widen a runner's hover area.
    static let pickableCategory = 1 << 1
    static let background = NSColor(red: 0.03, green: 0.035, blue: 0.06, alpha: 1)
    /// SceneKit's multi-pass bloom builds per-mip texture views that the
    /// macOS virtual-machine GPU driver cannot back: the first frame aborts
    /// the app with `Assertion failed: (texture.resourceID)` in
    /// AppleParavirtTexture. A single pass renders there; real GPUs keep the
    /// two-pass glow.
    static let bloomIterationCount: Int = {
        let isParavirtual = MTLCreateSystemDefaultDevice()?.name.localizedCaseInsensitiveContains("paravirtual") ?? false
        return isParavirtual ? 1 : 2
    }()

    let scene = SCNScene()
    let cameraNode = SCNNode()
    private let fleetNode = SCNNode()
    private let hubNode = SCNNode()
    private let hubCard = SCNNode()
    private var runners: [Int: RunnerNode] = [:]
    private(set) var items: [RunnerFleetItem] = []
    private(set) var layout = RunnerFleetLayout(count: 0, columns: 6)
    private var hubTitle: String?
    private var animatesData = true

    private(set) var target = SIMD3<Float>(0, 0, 0)
    private(set) var distance: Float = 260
    private var aspect: Float = 1.6
    /// The source whose fleet was last framed, so switching tabs starts back at GitHub.
    private var framedSource: String?

    init() {
        scene.background.contents = Self.background
        scene.lightingEnvironment.contents = FleetTextures.environment()
        scene.lightingEnvironment.intensity = 1.2
        // Navy haze so the back rows recede.
        scene.fogColor = NSColor(red: 0.025, green: 0.035, blue: 0.07, alpha: 1)
        scene.fogStartDistance = 900
        scene.fogEndDistance = 2_600
        scene.fogDensityExponent = 1.5

        let camera = SCNCamera()
        camera.fieldOfView = CGFloat(Self.fieldOfView)
        camera.zNear = 1
        camera.zFar = 6_000
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.bloomIntensity = 2.2
        camera.bloomThreshold = 1.2
        camera.bloomIterationCount = Self.bloomIterationCount
        camera.bloomBlurRadius = 14
        // Contact darkening where cases meet the floor.
        camera.screenSpaceAmbientOcclusionIntensity = 1.4
        camera.screenSpaceAmbientOcclusionRadius = 3
        camera.screenSpaceAmbientOcclusionNormalThreshold = 0.3
        camera.screenSpaceAmbientOcclusionDepthThreshold = 2
        // Deeper contrast for the cinematic grade; the cool cast comes from the
        // lighting itself rather than a lookup table.
        camera.contrast = 0.2
        camera.saturation = 1.1
        camera.vignettingIntensity = 0.7
        camera.vignettingPower = 1.4
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        // Lit like a product shot: a strong overhead key from slightly behind
        // brightens the lids while the sides stay charcoal; its mirror highlight
        // points away from the camera, so no hot spot (a low backlight left one).
        // The environment's horizon line rims the edges, and a weak cool fill
        // keeps the fronts legible.
        scene.rootNode.addChildNode(Self.light(.directional, intensity: 1_200, color: NSColor(red: 1, green: 0.97, blue: 0.93, alpha: 1), angles: SIMD3(-1.3, .pi, 0)))
        // Warm-left, cool-right side contrast: a low pale-gold light from the
        // front left lights the left panels and corners, and a cool blue fill
        // from the right keeps the far sides from going flat black.
        scene.rootNode.addChildNode(Self.light(.directional, intensity: 1_400, color: NSColor(red: 1, green: 0.8, blue: 0.5, alpha: 1), from: SIMD3(-100, 24, 16)))
        scene.rootNode.addChildNode(Self.light(.directional, intensity: 380, color: NSColor(red: 0.4, green: 0.55, blue: 1, alpha: 1), from: SIMD3(100, 22, 10)))
        scene.rootNode.addChildNode(Self.light(.ambient, intensity: 60, color: NSColor(red: 0.25, green: 0.32, blue: 0.6, alpha: 1), angles: .zero))

        scene.rootNode.addChildNode(makeFloor())
        scene.rootNode.addChildNode(fleetNode)
        buildHub()
        applyCamera()
    }

    /// A directional light shining from `from` toward the origin.
    private static func light(_ type: SCNLight.LightType, intensity: CGFloat, color: NSColor, from: SIMD3<Float>) -> SCNNode {
        let node = light(type, intensity: intensity, color: color, angles: .zero)
        node.simdPosition = from
        node.simdLook(at: .zero)
        return node
    }

    private static func light(_ type: SCNLight.LightType, intensity: CGFloat, color: NSColor, angles: SIMD3<Float>) -> SCNNode {
        let node = SCNNode()
        node.light = SCNLight()
        node.light?.type = type
        node.light?.intensity = intensity
        node.light?.color = color
        node.simdEulerAngles = angles
        return node
    }

    // MARK: Fleet

    func update(_ items: [RunnerFleetItem], columns: Int, hubTitle: String, animatesData: Bool) {
        let layout = RunnerFleetLayout(count: items.count, columns: columns)
        let restructured = layout != self.layout || items.map(\.id) != self.items.map(\.id)
            || animatesData != self.animatesData
        self.layout = layout
        self.items = items
        self.animatesData = animatesData

        if hubTitle != self.hubTitle {
            self.hubTitle = hubTitle
            Self.setLabel(hubCard, image: FleetLabels.hub(title: hubTitle), width: Self.hubWidth, anchor: .center)
        }
        let ids = Set(items.map(\.id))
        for (id, node) in runners where !ids.contains(id) {
            node.remove()
            runners[id] = nil
        }
        for (index, item) in items.enumerated() {
            let node = runners[item.id] ?? {
                let node = RunnerNode(id: item.id)
                fleetNode.addChildNode(node.root)
                fleetNode.addChildNode(node.cable)
                runners[item.id] = node
                return node
            }()
            if restructured {
                node.place(at: layout.position(index), cable: layout.cable(to: index), color: Self.cableColor(index))
            }
            if restructured || node.item != item { node.apply(item, animates: animatesData) }
        }
        if framedSource != hubTitle, !items.isEmpty {
            framedSource = hubTitle
            frameTop(animated: false)
        } else {
            clampCamera()
            applyCamera()
        }
    }

    /// The runner whose model or label contains a hit-tested node.
    func runnerID(for node: SCNNode) -> Int? {
        var current: SCNNode? = node
        while let candidate = current {
            if let name = candidate.name, name.hasPrefix(RunnerNode.namePrefix) {
                return Int(name.dropFirst(RunnerNode.namePrefix.count))
            }
            current = candidate.parent
        }
        return nil
    }

    /// Where a hover popover should point for a runner: just above its lid.
    func anchor(for id: Int) -> SCNVector3? {
        runners[id].map { SCNVector3($0.root.simdPosition + SIMD3(0, 5.4, 0)) }
    }

    private static let hubWidth = CGFloat(RunnerFleetLayout.hubSize.x)

    private static func cableColor(_ index: Int) -> NSColor {
        let palette: [NSColor] = [
            NSColor(red: 0.24, green: 0.52, blue: 1, alpha: 1),
            NSColor(red: 0.2, green: 0.78, blue: 1, alpha: 1),
            NSColor(red: 0.55, green: 0.42, blue: 1, alpha: 1),
            NSColor(red: 0.93, green: 0.42, blue: 0.86, alpha: 1),
        ]
        return palette[index % palette.count]
    }

    /// A flat card facing the camera: SwiftUI draws the rounded glass smoothly,
    /// where a chamfered box showed faceted edges and stretched side textures.
    private func buildHub() {
        let size = RunnerFleetLayout.hubSize
        hubNode.simdPosition = RunnerFleetLayout.hubCenter
        hubNode.simdEulerAngles = SIMD3(-RunnerFleetLayout.pitch, 0, 0)
        hubCard.renderingOrder = 5
        hubNode.addChildNode(hubCard)

        let halo = SCNNode(geometry: SCNPlane(width: CGFloat(size.x) * 2.4, height: CGFloat(size.y) * 2.6))
        halo.geometry?.firstMaterial = FleetTextures.additive(color: NSColor(red: 0.2, green: 0.45, blue: 1, alpha: 1))
        halo.opacity = 0.5
        halo.simdPosition = SIMD3(0, 0, -0.5)
        halo.renderingOrder = -1
        hubNode.addChildNode(halo)
        scene.rootNode.addChildNode(hubNode)
    }

    /// Dark navy floor. A reflective SCNFloor mirrored the depth-test-free
    /// captions regardless of category masks, so the floor stays matte.
    private func makeFloor() -> SCNNode {
        let plane = SCNPlane(width: 6_000, height: 6_000)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor(red: 0.018, green: 0.024, blue: 0.045, alpha: 1)
        material.emission.contents = FleetTextures.dotGrid()
        material.emission.wrapS = .repeat
        material.emission.wrapT = .repeat
        material.emission.contentsTransform = SCNMatrix4MakeScale(6_000 / 6, 6_000 / 6, 1)
        // Barely there: enough texture to read as a floor without competing with the fleet.
        material.emission.intensity = 0.3
        plane.materials = [material]
        let floor = SCNNode(geometry: plane)
        floor.simdEulerAngles = SIMD3(-.pi / 2, 0, 0)
        floor.simdPosition = SIMD3(0, -0.05, 0)
        return floor
    }

    // MARK: Camera

    func resize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        aspect = Float(size.width / size.height)
        clampCamera()
        applyCamera()
    }

    /// Pans by a fraction of the visible floor so the speed feels the same at any zoom.
    func pan(dx: Float, dz: Float) {
        let span = visibleFloorDepth(at: distance)
        target += SIMD3(dx * span, 0, dz * span)
        clampCamera()
        applyCamera()
    }

    func zoom(by factor: Float, animated: Bool = false) {
        distance /= factor
        clampCamera()
        applyCamera(animated: animated)
    }

    /// Fits the hub and every row.
    func fitAll(animated: Bool = true) {
        let bounds = layout.bounds
        frame(layout.hubCorners + [
            SIMD3(bounds.min.x, 0, bounds.max.z), SIMD3(bounds.max.x, 0, bounds.max.z),
            SIMD3(bounds.min.x, 0, 0), SIMD3(bounds.max.x, 0, 0),
        ], animated: animated)
    }

    /// Fits the fleet's width with the hub and first row in view, leaving later
    /// rows below for scrolling.
    func frameTop(animated: Bool = true) {
        let bounds = layout.bounds
        let firstRow = min(bounds.max.z, 16)
        let points = layout.hubCorners + [SIMD3(bounds.min.x, 0, firstRow), SIMD3(bounds.max.x, 0, firstRow)]
        frame(points, alignTop: true, animated: animated)
    }

    private func frame(_ points: [SIMD3<Float>], alignTop: Bool = false, animated: Bool) {
        (target, distance) = RunnerFleetLayout.framing(points, aspect: aspect, fieldOfView: Self.fieldOfView, alignTop: alignTop)
        clampCamera()
        applyCamera(animated: animated)
    }

    private var tanHalfFOV: Float { tan(Self.fieldOfView * .pi / 360) }

    private func distance(forHalfWidth halfWidth: Float) -> Float {
        halfWidth / (tanHalfFOV * aspect)
    }

    private func visibleFloorDepth(at distance: Float) -> Float {
        2 * distance * tanHalfFOV / sin(RunnerFleetLayout.pitch)
    }

    private func clampCamera() {
        let bounds = layout.bounds
        distance = min(max(distance, 80), max(3_000, distance(forHalfWidth: bounds.max.x + 20)))
        target.x = min(max(target.x, bounds.min.x), bounds.max.x)
        target.z = min(max(target.z, RunnerFleetLayout.hubCenter.z), max(bounds.max.z - 10, RunnerFleetLayout.hubCenter.z))
    }

    private func applyCamera(animated: Bool = false) {
        let pitch = RunnerFleetLayout.pitch
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.35 : 0
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        cameraNode.simdPosition = target + SIMD3(0, sin(pitch), cos(pitch)) * distance
        cameraNode.simdEulerAngles = SIMD3(-pitch, 0, 0)
        SCNTransaction.commit()
    }
}

/// One runner: its model, status light, floor glow, label, and cable.
@MainActor
private final class RunnerNode {
    static let namePrefix = "runner:"

    let root = SCNNode()
    let cable = SCNNode()
    private(set) var item: RunnerFleetItem?
    private let model = SCNNode()
    private let label = SCNNode()
    private let glow = SCNNode(geometry: SCNPlane(width: 30, height: 30))
    /// The busy cable's colour spilling onto the case, as a real neon tube would.
    private let spill = SCNNode()
    private let lightMaterial = SCNMaterial()
    private let lightHalo: SCNMaterial = {
        let material = FleetTextures.additive(color: .white)
        material.readsFromDepthBuffer = false
        return material
    }()
    private let cableMaterial = SCNMaterial()
    /// A wide additive tube around a busy cable: the soft glow of a lit fibre.
    private let sleeve = SCNNode()
    private let sleeveMaterial: SCNMaterial = {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.black
        material.blendMode = .add
        material.writesToDepthBuffer = false
        return material
    }()
    /// Holds the moving packets so they can be cleared without touching the sleeve.
    private let packets = SCNNode()
    private let glowMaterial = FleetTextures.additive(color: .systemBlue)
    private var path: [SIMD3<Float>] = []
    private var color = NSColor.systemBlue
    private var hardware: RunnerHardware?

    init(id: Int) {
        root.name = Self.namePrefix + String(id)
        lightMaterial.lightingModel = .constant
        cableMaterial.lightingModel = .constant
        cableMaterial.diffuse.contents = NSColor.black
        glow.geometry?.firstMaterial = glowMaterial
        glow.simdEulerAngles = SIMD3(-.pi / 2, 0, 0)
        glow.simdPosition = SIMD3(0, 0.02, 0)
        glow.renderingOrder = -1

        let spillLight = SCNLight()
        spillLight.type = .omni
        spillLight.intensity = 0
        spillLight.attenuationStartDistance = 2
        spillLight.attenuationEndDistance = 11
        spillLight.attenuationFalloffExponent = 2
        spill.light = spillLight
        // Just above and behind the lid's back edge where the cable plugs in, so
        // the tint fades across the lid toward the front; the short range
        // keeps it off the neighbouring runners.
        spill.simdPosition = SIMD3(0, 6, -RunnerFleetLayout.miniHalfDepth - 1.5)

        let shadow = SCNNode(geometry: SCNPlane(width: 16, height: 16))
        let shadowMaterial = SCNMaterial()
        shadowMaterial.lightingModel = .constant
        shadowMaterial.diffuse.contents = FleetTextures.contactShadow()
        shadowMaterial.blendMode = .multiply
        shadowMaterial.writesToDepthBuffer = false
        shadow.geometry?.firstMaterial = shadowMaterial
        shadow.simdEulerAngles = SIMD3(-.pi / 2, 0, 0)
        shadow.simdPosition = SIMD3(0, 0.04, 0)

        // Faces the camera and hangs from the case's front edge; it is drawn
        // over the floor (see setLabel) so it reads like a caption beneath the mini.
        label.simdEulerAngles = SIMD3(-RunnerFleetLayout.pitch, 0, 0)
        label.simdPosition = SIMD3(0, 0, RunnerFleetLayout.labelDepth)
        label.renderingOrder = 10
        label.categoryBitMask = RunnerFleetScene.pickableCategory
        for node in [glow, shadow, model, label, spill] { root.addChildNode(node) }
        sleeve.renderingOrder = 2
        cable.addChildNode(sleeve)
        cable.addChildNode(packets)
    }

    func remove() {
        root.removeFromParentNode()
        cable.removeFromParentNode()
    }

    func place(at position: SIMD3<Float>, cable path: [SIMD3<Float>], color: NSColor) {
        root.simdPosition = position
        self.path = path
        self.color = color
        cable.geometry = FleetGeometry.tube(along: path, radius: 0.22)
        cable.geometry?.firstMaterial = cableMaterial
        sleeve.geometry = FleetGeometry.tube(along: path, radius: 0.75, sides: 10)
        sleeve.geometry?.firstMaterial = sleeveMaterial
    }

    func apply(_ item: RunnerFleetItem, animates: Bool) {
        if item.hardware != hardware { rebuildModel(for: item.hardware) }
        let online = item.state != .offline
        lightMaterial.diffuse.contents = online ? NSColor.white : NSColor(white: 0.08, alpha: 1)
        lightMaterial.diffuse.intensity = online ? 6 : 1
        lightHalo.transparency = online ? 1 : 0

        // Cables stay dark gray until data flows, so the lit ones are the working ones.
        switch item.state {
        case .busy:
            // Well past the bloom threshold so the fibre itself glows.
            cableMaterial.emission.contents = color
            cableMaterial.emission.intensity = 5
            sleeveMaterial.emission.contents = color
            sleeve.opacity = 0.26
            glowMaterial.multiply.contents = color
            glow.opacity = 0.7
            spill.light?.color = color
            spill.light?.intensity = 60
        case .idle:
            cableMaterial.emission.contents = NSColor(white: 0.24, alpha: 1)
            cableMaterial.emission.intensity = 1
            sleeve.opacity = 0
            glow.opacity = 0
            spill.light?.intensity = 0
        case .offline:
            cableMaterial.emission.contents = NSColor(white: 0.12, alpha: 1)
            cableMaterial.emission.intensity = 1
            sleeve.opacity = 0
            glow.opacity = 0
            spill.light?.intensity = 0
        }

        packets.childNodes.forEach { $0.removeFromParentNode() }
        if item.state == .busy, animates { addPackets() }

        if item.name != self.item?.name || item.state != self.item?.state {
            RunnerFleetScene.setLabel(label, image: FleetLabels.runner(name: item.name, state: item.state), width: 18, anchor: .top)
        }
        self.item = item
    }

    private func rebuildModel(for hardware: RunnerHardware) {
        self.hardware = hardware
        model.childNodes.forEach { $0.removeFromParentNode() }
        defer {
            // Category masks aren't inherited, so tag every enclosure node for hit testing.
            model.enumerateHierarchy { node, _ in
                if node.geometry?.firstMaterial !== lightHalo { node.categoryBitMask = RunnerFleetScene.pickableCategory }
            }
        }
        if [.macMini, .mac].contains(hardware), let template = MacMiniModel.template {
            model.addChildNode(template.body.clone())
            let light = template.statusLight.clone()
            light.geometry = template.statusLight.geometry?.copy() as? SCNGeometry
            light.geometry?.materials = [lightMaterial]
            model.addChildNode(light)
            addHalo(at: light.boundingSphere.center)
        } else {
            // Other hardware gets a neutral enclosure rather than a misleading Mac mini.
            let isMac = [.macStudio, .macBook, .imac, .macProTower, .macProCylinder].contains(hardware)
            let box = SCNBox(width: 12.7, height: isMac ? 8 : 5, length: 12.7, chamferRadius: 1.4)
            let shell = SCNMaterial()
            shell.lightingModel = .physicallyBased
            shell.diffuse.contents = isMac ? NSColor(white: 0.72, alpha: 1) : NSColor(white: 0.18, alpha: 1)
            shell.metalness.contents = isMac ? 1 : 0.2
            shell.roughness.contents = 0.35
            box.materials = [shell]
            let enclosure = SCNNode(geometry: box)
            enclosure.simdPosition = SIMD3(0, Float(box.height) / 2, 0)
            model.addChildNode(enclosure)
            let light = SCNNode(geometry: SCNCylinder(radius: 0.12, height: 0.05))
            light.geometry?.materials = [lightMaterial]
            light.simdEulerAngles = SIMD3(.pi / 2, 0, 0)
            light.simdPosition = SIMD3(2.4, Float(box.height) * 0.45, 6.36)
            model.addChildNode(light)
            addHalo(at: light.position)
        }
    }

    /// The real light is a 1.6 mm dot, so a soft halo makes on and off legible at fleet scale.
    private func addHalo(at position: SCNVector3) {
        // Small: a crisp dot with a hint of bloom, like the real light.
        let halo = SCNNode(geometry: SCNPlane(width: 0.7, height: 0.7))
        halo.geometry?.firstMaterial = lightHalo
        // Centred on the light and drawn without a depth test: offsetting it in
        // front of the case to avoid clipping shifted it off the light by parallax.
        halo.position = position
        halo.simdEulerAngles = SIMD3(-RunnerFleetLayout.pitch, 0, 0)
        halo.renderingOrder = 6
        model.addChildNode(halo)
    }

    /// Job traffic flows down from GitHub; one return packet carries logs back up.
    /// Each packet glows in its colour and carries a short-range light, so its
    /// glow plays across the cases it passes and arrives at.
    private func addPackets() {
        guard path.count > 1 else { return }
        var keyTimes: [NSNumber] = [0]
        var length: Float = 0
        for index in 1..<path.count {
            length += simd_distance(path[index - 1], path[index])
            keyTimes.append(NSNumber(value: length))
        }
        guard length > 0 else { return }
        keyTimes = keyTimes.map { NSNumber(value: $0.floatValue / length) }
        let duration = Double(length / 26)
        let down = path.map { NSValue(scnVector3: SCNVector3($0)) }
        let up = Array(down.reversed())
        let upTimes = keyTimes.reversed().map { NSNumber(value: 1 - $0.floatValue) }
        let flows: [(values: [NSValue], times: [NSNumber], color: NSColor, phase: Double)] = [
            (down, keyTimes, color, 0), (down, keyTimes, color, 0.34),
            // A pale tint of the cable colour rather than pure white, so its light reflects in colour.
            (down, keyTimes, color.blended(withFraction: 0.6, of: .white) ?? .white, 0.67),
            (up, upTimes, NSColor(red: 0.85, green: 0.4, blue: 1, alpha: 1), 0.5),
        ]
        for flow in flows {
            let packet = SCNNode(geometry: SCNBox(width: 0.9, height: 0.9, length: 0.9, chamferRadius: 0.15))
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = NSColor.black
            material.emission.contents = flow.color
            material.emission.intensity = 6
            packet.geometry?.materials = [material]

            let halo = SCNNode(geometry: SCNPlane(width: 3.4, height: 3.4))
            halo.geometry?.firstMaterial = FleetTextures.additive(color: flow.color)
            halo.simdEulerAngles = SIMD3(-RunnerFleetLayout.pitch, 0, 0)
            halo.opacity = 0.85
            packet.addChildNode(halo)

            let light = SCNLight()
            light.type = .omni
            light.color = flow.color
            light.intensity = 130
            light.attenuationStartDistance = 0.5
            light.attenuationEndDistance = 9
            light.attenuationFalloffExponent = 2
            packet.light = light
            let animation = CAKeyframeAnimation(keyPath: "position")
            animation.values = flow.values
            animation.keyTimes = flow.times
            animation.duration = duration
            animation.repeatCount = .infinity
            animation.timeOffset = duration * flow.phase
            packet.addAnimation(SCNAnimation(caAnimation: animation), forKey: "flow")
            packets.addChildNode(packet)
        }
    }
}

extension RunnerFleetScene {
    /// Shows a rendered label on a flat card, sized from the image's aspect ratio.
    enum LabelAnchor { case center, top }

    static func setLabel(_ node: SCNNode, image: CGImage?, width: CGFloat, anchor: LabelAnchor) {
        guard let image else { node.geometry = nil; return }
        let plane = SCNPlane(width: width, height: width * CGFloat(image.height) / CGFloat(image.width))
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = image
        material.diffuse.intensity = 0.92
        material.writesToDepthBuffer = false
        // Top-anchored captions hang below the floor plane, so they skip the depth test.
        material.readsFromDepthBuffer = anchor != .top
        plane.materials = [material]
        node.geometry = plane
        // A top anchor pins the card's top edge at the node so the text hangs beneath it.
        node.pivot = anchor == .top ? SCNMatrix4MakeTranslation(0, plane.height / 2, 0) : SCNMatrix4Identity
    }
}

/// SwiftUI-rendered text for the scene; SceneKit's own text meshes look soft.
@MainActor
private enum FleetLabels {
    static func runner(name: String, state: GitHubRunner.State) -> CGImage? {
        render(width: 180) {
            VStack(alignment: .center, spacing: 4) {
                Text(name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    Circle().fill(state.fleetColor).frame(width: 7, height: 7)
                    Text(state.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(white: 0.72))
                }
            }
            // A back row's caption hangs over the lids of the row in front;
            // without a scrim its light-gray state text vanishes against a
            // silver case (COL-6). The padding keeps the halo inside the image.
            .shadow(color: .black.opacity(0.9), radius: 1.5)
            .shadow(color: .black.opacity(0.6), radius: 4)
            .padding(.vertical, 4)
        }
    }

    static func hub(title: String) -> CGImage? {
        let shape = RoundedRectangle(cornerRadius: 34, style: .continuous)
        return render(width: 300) {
            VStack(spacing: 6) {
                Image("GitHubMark")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 58, height: 58)
                    .foregroundStyle(.white)
                Text("GitHub").font(.system(size: 28, weight: .semibold)).foregroundStyle(.white)
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color(red: 0.72, green: 0.84, blue: 1))
                        .lineLimit(1)
                }
            }
            .frame(width: 284, height: 184)
            .background {
                shape.fill(LinearGradient(
                    colors: [Color(red: 0.17, green: 0.38, blue: 0.98), Color(red: 0.05, green: 0.13, blue: 0.45)],
                    startPoint: .top, endPoint: .bottom
                ))
                shape.fill(RadialGradient(
                    colors: [Color.white.opacity(0.28), .clear], center: UnitPoint(x: 0.5, y: 0.15),
                    startRadius: 0, endRadius: 170
                ))
            }
            .overlay {
                shape.strokeBorder(LinearGradient(
                    colors: [Color(red: 0.7, green: 0.86, blue: 1), Color(red: 0.32, green: 0.55, blue: 1).opacity(0.7)],
                    startPoint: .top, endPoint: .bottom
                ), lineWidth: 2.5)
            }
            .frame(width: 300, height: 200)
        }
    }

    private static func render<Content: View>(width: CGFloat, @ViewBuilder _ content: () -> Content) -> CGImage? {
        let renderer = ImageRenderer(content: content().frame(width: width).environment(\.colorScheme, .dark))
        renderer.scale = 3
        return renderer.cgImage
    }
}

extension GitHubRunner.State {
    var fleetColor: Color {
        switch self {
        case .idle: .green
        case .busy: .orange
        case .offline: Color(white: 0.45)
        }
    }
}

enum FleetGeometry {
    /// A round tube swept along a path using parallel-transported frames so it never twists.
    static func tube(along path: [SIMD3<Float>], radius: Float, sides: Int = 6) -> SCNGeometry? {
        guard path.count > 1 else { return nil }
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var indices: [UInt32] = []
        let tangents = path.indices.map { index -> SIMD3<Float> in
            let a = path[max(index - 1, 0)], b = path[min(index + 1, path.count - 1)]
            return simd_normalize(b - a)
        }
        var normal = simd_normalize(simd_cross(tangents[0], abs(tangents[0].y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)))
        for (index, point) in path.enumerated() {
            if index > 0 {
                let previous = tangents[index - 1], current = tangents[index]
                let axis = simd_cross(previous, current)
                if simd_length(axis) > 1e-5 {
                    let angle = acos(min(max(simd_dot(previous, current), -1), 1))
                    normal = simd_act(simd_quatf(angle: angle, axis: simd_normalize(axis)), normal)
                }
            }
            let binormal = simd_cross(tangents[index], normal)
            for side in 0..<sides {
                let angle = Float(side) / Float(sides) * 2 * .pi
                let direction = cos(angle) * normal + sin(angle) * binormal
                vertices.append(SCNVector3(point + direction * radius))
                normals.append(SCNVector3(direction))
            }
        }
        for ring in 0..<(path.count - 1) {
            for side in 0..<sides {
                let a = UInt32(ring * sides + side), b = UInt32(ring * sides + (side + 1) % sides)
                let c = a + UInt32(sides), d = b + UInt32(sides)
                indices += [a, c, b, b, c, d]
            }
        }
        return SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
        )
    }
}

/// Small procedural textures, generated once.
@MainActor
enum FleetTextures {
    /// A soft radial light pool tinted by `color`; fade it with the node's opacity.
    static func additive(color: NSColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = radialGlow()
        material.multiply.contents = color
        material.blendMode = .add
        material.writesToDepthBuffer = false
        return material
    }

    private static var cache: [String: CGImage] = [:]

    static func radialGlow() -> CGImage? {
        cached("glow", size: 128) { context, size in
            let colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0.35), CGColor(gray: 1, alpha: 0)] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 0.35, 1]) else { return }
            let center = CGPoint(x: size / 2, y: size / 2)
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: size / 2, options: [])
        }
    }

    static func contactShadow() -> CGImage? {
        // A tight, softened rounded square matching the case footprint, so the
        // minis sit on the floor instead of hovering over a wide blur.
        cached("shadow", size: 128) { context, size in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            let footprint = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: size * 0.13, dy: size * 0.13)
            context.setShadow(offset: .zero, blur: size * 0.09, color: CGColor(gray: 0, alpha: 1))
            context.setFillColor(CGColor(gray: 0.03, alpha: 1))
            context.addPath(CGPath(roundedRect: footprint, cornerWidth: size * 0.16, cornerHeight: size * 0.16, transform: nil))
            context.fillPath()
        }
    }

    static func dotGrid() -> CGImage? {
        cached("dots", size: 64) { context, size in
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            context.setFillColor(CGColor(gray: 0.22, alpha: 1))
            context.fillEllipse(in: CGRect(x: size / 2 - 2.5, y: size / 2 - 2.5, width: 5, height: 5))
        }
    }

    /// A near-black studio with one soft ring of light just above the horizon.
    /// Lids reflect the sky about 30° up and catch the ring's falling edge as a
    /// sheen; fronts reflect the dark floor; rounded edges sweep through the
    /// bright horizon line and read as rims. Azimuth-independent on purpose.
    static func environment() -> CGImage? {
        // Equirectangular (2:1), y up from the bottom; SceneKit ignores square images.
        cached("environment", width: 1_024, height: 512) { context, width, height in
            context.setFillColor(CGColor(red: 0.012, green: 0.016, blue: 0.03, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            func band(_ low: CGFloat, _ high: CGFloat, _ colors: [CGColor], _ locations: [CGFloat]) {
                guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: locations) else { return }
                context.saveGState()
                context.clip(to: CGRect(x: 0, y: height * low, width: width, height: height * (high - low)))
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height * low), end: CGPoint(x: 0, y: height * high), options: [])
                context.restoreGState()
            }
            // Fronts: a faint cool floor bounce.
            band(0.3, 0.5, [CGColor(red: 0.02, green: 0.025, blue: 0.05, alpha: 1), CGColor(red: 0.2, green: 0.21, blue: 0.26, alpha: 1)], [0, 1])
            // Lids: bright from the horizon through about 35°, fading out by 60°.
            band(0.5, 0.84, [
                CGColor(red: 0.95, green: 0.93, blue: 0.9, alpha: 1), CGColor(red: 0.82, green: 0.81, blue: 0.8, alpha: 1),
                CGColor(red: 0.1, green: 0.11, blue: 0.15, alpha: 1),
            ], [0, 0.55, 1])
            // Rim line on the horizon.
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: height * 0.497, width: width, height: height * 0.012))
            // Cool accents just below the horizon tint the case sides like the cables.
            let accents: [(CGFloat, CGFloat, CGFloat)] = [(0.25, 0.45, 1), (0.6, 0.35, 1), (0.2, 0.7, 1), (0.3, 0.5, 1)]
            for (index, color) in accents.enumerated() {
                context.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
                context.fill(CGRect(x: width * (CGFloat(index) / 4 + 0.04), y: height * 0.45, width: width * 0.17, height: height * 0.035))
            }
        }
    }

    private static func cached(_ key: String, size: CGFloat, draw: (CGContext, CGFloat) -> Void) -> CGImage? {
        cached(key, width: size, height: size) { context, size, _ in draw(context, size) }
    }

    private static func cached(_ key: String, width: CGFloat, height: CGFloat, draw: (CGContext, CGFloat, CGFloat) -> Void) -> CGImage? {
        if let image = cache[key] { return image }
        guard let context = CGContext(
            data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        draw(context, width, height)
        let image = context.makeImage()
        cache[key] = image
        return image
    }
}
