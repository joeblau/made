import AppKit
import CryptoKit
import SceneKit
import simd

/// A loaded, normalised device: centred at the origin, facing +Z, its largest
/// dimension `MockupDeviceModel.span` units, with handles for the screens and
/// the hinge.
@MainActor
final class MockupDeviceModel {
    static let span: Float = 20

    struct Display {
        let material: SCNMaterial
        /// Width ÷ height of the physical panel as authored.
        let aspect: CGFloat
        /// Quarter turns clockwise to apply to upright content (iPad Pro's
        /// texture is stored portrait on a landscape panel).
        let quarterTurns: Int
    }

    let node: SCNNode
    let displays: [Display]
    private let defaultContents: [Any?]
    private let hingeDriver: ((Double) -> Void)?

    var hasHinge: Bool { hingeDriver != nil }
    var screens: [SCNMaterial] { displays.map(\.material) }

    fileprivate init(node: SCNNode, displays: [Display], hinge: ((Double) -> Void)?) {
        self.node = node
        self.displays = displays
        defaultContents = displays.map { $0.material.emission.contents }
        hingeDriver = hinge
    }

    /// Shows `image` (aspect-filled to each panel) or Apple's default wallpaper.
    func setScreen(_ image: NSImage?) {
        for (index, display) in displays.enumerated() {
            display.material.emission.contents = image.map { Self.fitted($0, display: display) } ?? defaultContents[index]
        }
    }

    /// Video or other live contents, set as-is.
    func setScreenContents(_ contents: Any) {
        for display in displays { display.material.emission.contents = contents }
    }

    /// 0 closed … 1 open; a no-op for slab devices.
    func setOpen(_ amount: Double) { hingeDriver?(min(max(amount, 0), 1)) }

    /// Crops `image` to the panel's aspect (centred) and applies the panel's
    /// quarter turns, so UVs that span the whole panel show it undistorted.
    static func fitted(_ image: NSImage, display: Display) -> NSImage {
        let turns = ((display.quarterTurns % 4) + 4) % 4
        // Crop to what the viewer sees, then turn to match the texture layout.
        let target = display.aspect
        let source = image.size
        guard source.width > 0, source.height > 0, target > 0 else { return image }
        var crop = CGRect(origin: .zero, size: source)
        if source.width / source.height > target {
            crop.size.width = source.height * target
            crop.origin.x = (source.width - crop.width) / 2
        } else {
            crop.size.height = source.width / target
            crop.origin.y = (source.height - crop.height) / 2
        }
        let outputSize = turns % 2 == 0 ? crop.size : CGSize(width: crop.height, height: crop.width)
        return NSImage(size: outputSize, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.translateBy(x: rect.midX, y: rect.midY)
            context.rotate(by: -CGFloat(turns) * .pi / 2)
            let drawn = CGRect(x: -crop.width / 2, y: -crop.height / 2, width: crop.width, height: crop.height)
            image.draw(in: drawn, from: crop, operation: .copy, fraction: 1)
            return true
        }
    }
}

/// Loads Apple's AR Quick Look models from the app bundle. Node and material
/// names in these files are scrambled, so everything is found by geometry:
/// screens are the materials whose emission is an image over a black diffuse.
@MainActor
enum MockupDeviceLibrary {
    enum Failure: Error, Equatable {
        case missingResource(String)
        case unreadable(String)
        case noScreen(String)
    }

    private static var templates: [MockupFinishKey: SCNScene] = [:]

    struct MockupFinishKey: Hashable {
        let device: MockupDevice
        let finish: MockupFinish
    }

    static func model(for device: MockupDevice, finish: MockupFinish, bundle: Bundle = .main) throws -> MockupDeviceModel {
        if device.hinge == .fold, let rig = try? DuoRig.model(finish: finish) { return rig }
        let key = MockupFinishKey(device: device, finish: finish)
        let scene: SCNScene
        if let cached = templates[key] {
            scene = cached
        } else {
            scene = try loadScene(finish, bundle: bundle)
            templates[key] = scene
        }
        // Clone so each stage owns its node graph; materials are copied so
        // screen content never leaks between clones.
        let root = scene.rootNode.clone()
        deepCopyMaterials(root)
        return try normalise(root, device: device, name: finish.resource)
    }

    // MARK: - Loading

    private static func loadScene(_ finish: MockupFinish, bundle: Bundle) throws -> SCNScene {
        guard let url = bundle.url(forResource: finish.resource, withExtension: "usdz") else {
            throw Failure.missingResource(finish.resource)
        }
        let source = finish.variants.isEmpty ? url : try variantWrapper(for: url, variants: finish.variants)
        do {
            return try SCNScene(url: source, options: [.checkConsistency: false])
        } catch {
            throw Failure.unreadable(finish.resource)
        }
    }

    /// SceneKit has no variant API, but it honours selections authored in a
    /// referencing layer. Variant names come from the compiled-in catalog,
    /// never from user input.
    static func variantWrapper(for url: URL, variants: [String: String]) throws -> URL {
        let selections = variants.sorted { $0.key < $1.key }
            .map { "string \($0.key) = \"\($0.value)\"" }
            .joined(separator: "\n        ")
        let text = """
        #usda 1.0
        (
            defaultPrim = "Root"
            metersPerUnit = 0.01
            upAxis = "Y"
        )

        def Xform "Root" (
            prepend references = @\(url.path)@
            variants = {
                \(selections)
            }
        )
        {
        }

        """
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CockpitMockups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = url.deletingPathExtension().lastPathComponent + "-" +
            variants.sorted { $0.key < $1.key }.map { "\($0.key)_\($0.value)" }.joined(separator: "-") + ".usda"
        let wrapper = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: wrapper, options: .atomic)
        return wrapper
    }

    private static func deepCopyMaterials(_ node: SCNNode) {
        if let geometry = node.geometry?.copy() as? SCNGeometry {
            geometry.materials = geometry.materials.map { ($0.copy() as? SCNMaterial) ?? $0 }
            node.geometry = geometry
        }
        for child in node.childNodes { deepCopyMaterials(child) }
    }

    // MARK: - Screens

    struct Screen {
        let node: SCNNode
        let material: SCNMaterial
        let area: Float
    }

    static func screens(in root: SCNNode) -> [Screen] {
        var found: [Screen] = []
        root.enumerateHierarchy { node, _ in
            guard !node.isHidden, let geometry = node.geometry else { return }
            for material in geometry.materials where isScreen(material) {
                let (lo, hi) = node.boundingBox
                let size = simd_float3(Float(hi.x - lo.x), Float(hi.y - lo.y), Float(hi.z - lo.z))
                let sorted = [size.x, size.y, size.z].sorted()
                found.append(Screen(node: node, material: material, area: sorted[1] * sorted[2]))
            }
        }
        return found
    }

    static func isScreen(_ material: SCNMaterial) -> Bool {
        guard let contents = material.emission.contents, !(contents is NSColor), !(contents is NSNumber) else { return false }
        if let diffuse = material.diffuse.contents as? NSColor, let rgb = diffuse.usingColorSpace(.sRGB) {
            return rgb.redComponent + rgb.greenComponent + rgb.blueComponent < 0.15
        }
        return material.diffuse.contents == nil
    }

    // MARK: - Normalisation

    /// Centres `oriented` (already facing +Z, upright) and scales it to the span.
    fileprivate static func fit(_ oriented: SCNNode) -> SCNNode {
        let container = SCNNode()
        container.addChildNode(oriented)
        let bounds = visibleBounds(container)
        let size = bounds.max - bounds.min
        let scale = MockupDeviceModel.span / max(size.x, size.y, size.z, 0.0001)
        container.simdScale = simd_float3(repeating: scale)
        container.simdPosition = -(bounds.min + bounds.max) / 2 * scale
        let outer = SCNNode()
        outer.addChildNode(container)
        return outer
    }

    fileprivate static func prepare(_ material: SCNMaterial) {
        prepareScreen(Screen(node: SCNNode(), material: material, area: 0))
    }

    private static func normalise(_ root: SCNNode, device: MockupDevice, name: String) throws -> MockupDeviceModel {
        var all = screens(in: root)
        guard !all.isEmpty else { throw Failure.noScreen(name) }

        // Keep only the requested device out of multi-device files.
        switch device.selection {
        case .whole:
            break
        case .largestScreen, .smallestScreen:
            let sorted = all.sorted { $0.area < $1.area }
            let keep = device.selection == .largestScreen ? sorted.last! : sorted.first!
            isolate(keep.node, in: root)
            all = [keep]
        case .screenBody:
            let keep = all.max { $0.area < $1.area }!
            isolate(keep.node, in: root)
            all = [keep]
        }

        // Orient so the (largest) screen faces +Z, upright.
        let primary = all.max { $0.area < $1.area }!
        guard let frame = screenFrame(primary.node) else { throw Failure.noScreen(name) }
        let container = SCNNode()
        container.addChildNode(root)
        if device.keepsBaseLevel {
            // Laptops and the iPad on its keyboard: only yaw to face the camera.
            let forward = simd_normalize(simd_float3(frame.normal.x, 0, frame.normal.z))
            root.simdOrientation = yaw(from: forward)
        } else {
            let basis = simd_float3x3(columns: (frame.right, frame.up, frame.normal))
            root.simdOrientation = simd_quatf(basis.transpose)
        }

        // Centre and scale on visible geometry only (AR bounds proxies are hidden).
        let bounds = visibleBounds(container)
        let size = bounds.max - bounds.min
        let scale = MockupDeviceModel.span / max(size.x, size.y, size.z, 0.0001)
        let centre = (bounds.min + bounds.max) / 2
        container.simdScale = simd_float3(repeating: scale)
        container.simdPosition = -centre * scale
        let outer = SCNNode()
        outer.addChildNode(container)

        for screen in all { prepareScreen(screen) }
        let hinge: ((Double) -> Void)?
        switch device.hinge {
        case .none: hinge = nil
        case .lid: hinge = lidDriver(for: primary.node, in: root)
        case .fold: hinge = nil
        }
        let displays = all.map { screen in
            let frame = screenFrame(screen.node)
            let aspect = frame.map { $0.width / max($0.height, 0.0001) } ?? 1
            return MockupDeviceModel.Display(material: screen.material, aspect: CGFloat(aspect),
                                             quarterTurns: device.screenQuarterTurns)
        }
        return MockupDeviceModel(node: outer, displays: displays, hinge: hinge)
    }

    /// Removes every sibling branch that does not lead to `keep`, at the
    /// level where the devices split.
    private static func isolate(_ keep: SCNNode, in root: SCNNode) {
        var node = keep
        while let parent = node.parent {
            let leads = parent.childNodes.filter { child in child === node }
            if parent.childNodes.count > 1, leads.count == 1 {
                let siblings = parent.childNodes.filter { $0 !== node }
                // Siblings with their own screens are other devices; others
                // (keyboards, stands) belong to the accessory we drop too.
                for sibling in siblings where !screens(in: sibling).isEmpty || isAccessory(sibling, comparedTo: node) {
                    sibling.removeFromParentNode()
                }
            }
            if parent === root { break }
            node = parent
        }
    }

    /// Big sibling geometry outside the screen body (e.g. a keyboard).
    private static func isAccessory(_ sibling: SCNNode, comparedTo body: SCNNode) -> Bool {
        let a = worldBounds(sibling), b = worldBounds(body)
        let aSize = a.max - a.min, bSize = b.max - b.min
        return aSize.x * aSize.z > 0.25 * bSize.x * max(bSize.y, bSize.z) && !overlaps(a, b, inset: 0.5)
    }

    private static func overlaps(_ a: (min: simd_float3, max: simd_float3), _ b: (min: simd_float3, max: simd_float3), inset: Float) -> Bool {
        all(a.min .< b.max - inset) && all(b.min .< a.max - inset)
    }

    struct Frame {
        let right: simd_float3
        let up: simd_float3
        let normal: simd_float3
        let width: Float
        let height: Float
    }

    /// The screen's plane from its vertices (UVs are indexed separately from
    /// positions in these files, so geometry alone is used). Apple authors
    /// every model upright, so "up" is the in-plane axis nearest world +Y, and
    /// the screen faces away from the housing it is mounted in.
    static func screenFrame(_ node: SCNNode) -> Frame? {
        guard let positions = node.geometry?.sources(for: .vertex).first else { return nil }
        let points = floats(positions).map { node.simdConvertPosition($0, to: nil) }
        guard points.count >= 3 else { return nil }
        let centre = points.reduce(simd_float3.zero, +) / Float(points.count)
        var covariance = simd_float3x3()
        for point in points {
            let d = point - centre
            covariance += simd_float3x3(rows: [d * d.x, d * d.y, d * d.z])
        }
        let axes = principalAxes(covariance)
        var normal = axes[2]
        // Vertex density is uneven (rounded corners, camera cut-outs), so align
        // to the minimum-area bounding rectangle rather than the principal axes.
        let inPlane = minimumAreaAxes(points, centre: centre, a: axes[0], b: axes[1])
        var up = inPlane.max { abs($0.y) < abs($1.y) }!
        if up.y < 0 { up = -up }
        if let housing = housingCentre(of: node, centre: centre, normal: normal), simd_dot(centre - housing, normal) < 0 {
            normal = -normal
        }
        let right = simd_normalize(simd_cross(up, normal))
        up = simd_normalize(simd_cross(normal, right))
        func extent(_ axis: simd_float3) -> Float {
            let values = points.map { simd_dot($0 - centre, axis) }
            return (values.max() ?? 0) - (values.min() ?? 0)
        }
        return Frame(right: right, up: up, normal: normal, width: extent(right), height: extent(up))
    }

    static func minimumAreaAxes(_ points: [simd_float3], centre: simd_float3, a: simd_float3, b: simd_float3) -> [simd_float3] {
        let flat = points.map { simd_float2(simd_dot($0 - centre, a), simd_dot($0 - centre, b)) }
        func area(_ angle: Float) -> Float {
            let c = cos(angle), s = sin(angle)
            var lo = simd_float2(repeating: .greatestFiniteMagnitude), hi = -lo
            for p in flat {
                let r = simd_float2(c * p.x + s * p.y, -s * p.x + c * p.y)
                lo = simd_min(lo, r)
                hi = simd_max(hi, r)
            }
            return (hi.x - lo.x) * (hi.y - lo.y)
        }
        var best: Float = 0
        var bestArea = area(0)
        for step in 1..<180 {
            let angle = Float(step) * .pi / 180
            let value = area(angle)
            if value < bestArea { (best, bestArea) = (angle, value) }
        }
        for step in -10...10 {
            let angle = best + Float(step) * .pi / 1800
            let value = area(angle)
            if value < bestArea { (best, bestArea) = (angle, value) }
        }
        let c = cos(best), s = sin(best)
        return [simd_normalize(c * a + s * b), simd_normalize(-s * a + c * b)]
    }

    /// Centre of the nearest ancestor that has real thickness behind the
    /// screen (a phone body, a laptop lid).
    private static func housingCentre(of screen: SCNNode, centre: simd_float3, normal: simd_float3) -> simd_float3? {
        let (lo, hi) = screen.boundingBox
        let screenSize = Float(max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z))
        var node = screen.parent
        while let current = node {
            let bounds = visibleBounds(current)
            let corners = (0..<8).map { i in
                simd_float3(i & 1 == 0 ? bounds.min.x : bounds.max.x, i & 2 == 0 ? bounds.min.y : bounds.max.y,
                            i & 4 == 0 ? bounds.min.z : bounds.max.z)
            }
            let depths = corners.map { simd_dot($0 - centre, normal) }
            if (depths.max()! - depths.min()!) > screenSize * 0.03 { return (bounds.min + bounds.max) / 2 }
            node = current.parent
        }
        return nil
    }

    /// Eigenvectors of a symmetric 3×3 matrix, largest eigenvalue first (Jacobi).
    static func principalAxes(_ matrix: simd_float3x3) -> [simd_float3] {
        var a = [[Double]](repeating: [0, 0, 0], count: 3)
        for r in 0..<3 { for c in 0..<3 { a[r][c] = Double(matrix[c][r]) } }
        var v: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        for _ in 0..<32 {
            var p = 0, q = 1
            for (r, c) in [(0, 2), (1, 2)] where abs(a[r][c]) > abs(a[p][q]) { (p, q) = (r, c) }
            if abs(a[p][q]) < 1e-12 { break }
            let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
            let t = (theta >= 0 ? 1 : -1) / (abs(theta) + (theta * theta + 1).squareRoot())
            let c = 1 / (t * t + 1).squareRoot(), s = t * c
            for k in 0..<3 {
                let akp = a[k][p], akq = a[k][q]
                a[k][p] = c * akp - s * akq
                a[k][q] = s * akp + c * akq
            }
            for k in 0..<3 {
                let apk = a[p][k], aqk = a[q][k]
                a[p][k] = c * apk - s * aqk
                a[q][k] = s * apk + c * aqk
            }
            for k in 0..<3 {
                let vkp = v[k][p], vkq = v[k][q]
                v[k][p] = c * vkp - s * vkq
                v[k][q] = s * vkp + c * vkq
            }
        }
        return (0..<3).sorted { a[$0][$0] > a[$1][$1] }
            .map { simd_normalize(simd_float3(Float(v[0][$0]), Float(v[1][$0]), Float(v[2][$0]))) }
    }

    private static func floats(_ source: SCNGeometrySource) -> [simd_float3] {
        guard source.usesFloatComponents, source.bytesPerComponent == 4 else { return [] }
        let components = source.componentsPerVector
        return source.data.withUnsafeBytes { raw in
            (0..<source.vectorCount).map { index in
                let base = source.dataOffset + index * source.dataStride
                func value(_ c: Int) -> Float {
                    c < components ? raw.loadUnaligned(fromByteOffset: base + c * 4, as: Float.self) : 0
                }
                return simd_float3(value(0), value(1), value(2))
            }
        }
    }

    private static func prepareScreen(_ screen: Screen) {
        let material = screen.material
        material.diffuse.contents = NSColor.black
        // Apple authors a 1.75× boost SceneKit drops; restore part of it.
        material.emission.intensity = 1.25
        material.emission.wrapS = .clamp
        material.emission.wrapT = .clamp
    }

    // MARK: - Bounds

    /// Bounds of the visible vertices. Node bounding boxes are axis-aligned
    /// in each mesh's authored frame, so a rotated lid would inflate them.
    static func visibleBounds(_ root: SCNNode, in space: SCNNode? = nil) -> (min: simd_float3, max: simd_float3) {
        var lo = simd_float3(repeating: .greatestFiniteMagnitude), hi = -lo
        root.enumerateHierarchy { node, _ in
            if node.isHidden || node.opacity < 0.01 { return }
            guard let geometry = node.geometry else { return }
            var points = geometry.sources(for: .vertex).first.map(floats) ?? []
            if points.isEmpty {
                let (a, b) = node.boundingBox
                points = (0..<8).map { corner in
                    simd_float3(Float(corner & 1 == 0 ? a.x : b.x), Float(corner & 2 == 0 ? a.y : b.y),
                                Float(corner & 4 == 0 ? a.z : b.z))
                }
            }
            let transform = space.map { node.simdConvertTransform(matrix_identity_float4x4, to: $0) } ?? node.simdWorldTransform
            for point in points {
                let world = transform * simd_float4(point, 1)
                lo = simd_min(lo, simd_float3(world.x, world.y, world.z))
                hi = simd_max(hi, simd_float3(world.x, world.y, world.z))
            }
        }
        return lo.x > hi.x ? (.zero, .zero) : (lo, hi)
    }

    /// Rotation about +Y taking a horizontal `forward` to +Z (no roll even
    /// when `forward` is exactly −Z).
    private static func yaw(from forward: simd_float3) -> simd_quatf {
        simd_quatf(angle: atan2(-forward.x, forward.z), axis: simd_float3(0, 1, 0))
    }

    private static func worldBounds(_ node: SCNNode) -> (min: simd_float3, max: simd_float3) { visibleBounds(node) }

    private static func hiddenAncestor(_ node: SCNNode) -> Bool {
        var current: SCNNode? = node
        while let n = current { if n.isHidden { return true }; current = n.parent }
        return false
    }

    // MARK: - Hinges

    /// MacBook lids. Files with a real hinge author the lid node with an X
    /// rotation of about −110°; scaling it opens and closes about the
    /// authored pivot. Files with the lid baked open (MacBook Pro M4/M5) get a
    /// hinge node inserted at the measured pivot (docs/mockups.md).
    private static func lidDriver(for screen: SCNNode, in root: SCNNode) -> ((Double) -> Void)? {
        var node = screen.parent
        while let current = node, current !== root {
            let angle = current.eulerAngles.x
            if abs(angle) > 1.2, abs(angle) < 2.4 {
                let open = Float(angle)
                return { [weak current] amount in current?.eulerAngles.x = CGFloat(open * Float(amount)) }
            }
            node = current.parent
        }
        // Baked: the lid is the highest ancestor lying entirely behind the
        // hinge line (z < 0 in Apple's file space, base toward +z).
        var lid: SCNNode?
        node = screen.parent
        while let current = node, current !== root {
            if visibleBounds(current, in: root).max.z < 0.5 { lid = current }
            node = current.parent
        }
        guard let lid, let parent = lid.parent else { return nil }
        let pivot = simd_float3(0, -0.09, -10.78)
        let hinge = SCNNode()
        hinge.simdPosition = pivot
        parent.replaceChildNode(lid, with: hinge)
        lid.simdTransform = simd_float4x4(translation: -pivot) * lid.simdTransform
        hinge.addChildNode(lid)
        let shipped = Float(110 * Double.pi / 180)
        return { [weak hinge] amount in hinge?.eulerAngles.x = CGFloat(shipped * (1 - Float(amount))) }
    }
}

private extension simd_float4x4 {
    init(translation t: simd_float3) {
        self.init(columns: (simd_float4(1, 0, 0, 0), simd_float4(0, 1, 0, 0), simd_float4(0, 0, 1, 0), simd_float4(t.x, t.y, t.z, 1)))
    }
}

/// Apple's rigged iPhone Duo (`V68.usdz`) from the user's own Xcode install.
/// It folds through a 31-joint skeleton whose authored animation includes a
/// symmetric fold (frames 260 flat → 380 closed, 24 fps). Cockpit never ships
/// or copies the file: it loads it in place, only when the bytes match the
/// pinned version (node names are version-specific), and otherwise falls back
/// to the bundled AR model with its fixed Landscape pose.
@MainActor
enum DuoRig {
    static let sha256 = "fd315e57c38fde5666d50de6e19b444e3d145450008126e85838119b682b7940"
    static let relativePath = "Contents/SharedFrameworks/DeviceKit.framework/Versions/A/PlugIns/" +
        "CoreDevicePopDeviceKitExtension.devicekitplugin/Contents/Resources/V68.usdz"
    static let innerMaterial = "CvyXbAGXoolRUYl"
    static let coverMaterial = "YqugYDOqMSOpqyA"
    static let maxBytes = 32 * 1024 * 1024

    private static var located: URL??

    /// Newest Xcode in /Applications or ~/Applications holding the pinned rig.
    static func locate(searching roots: [URL]? = nil) -> URL? {
        if roots == nil, let located { return located }
        let fileManager = FileManager.default
        let directories = roots ?? [URL(fileURLWithPath: "/Applications"),
                                    fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        let candidates = directories.flatMap { directory in
            ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("Xcode") && $0.pathExtension == "app" }
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
        let found = candidates.lazy.map { $0.appendingPathComponent(relativePath) }.first(where: matchesPin)
        if roots == nil { located = .some(found) }
        return found
    }

    static func matchesPin(_ url: URL) -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxBytes,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == sha256
    }

    /// Hinge degrees (180 flat … 0 closed) → time on the symmetric fold clip.
    static func time(open amount: Double) -> Double {
        let degrees = 180 * min(max(amount, 0), 1)
        return (260 + (180 - degrees) / 1.5) / 24
    }

    static func model(finish: MockupFinish) throws -> MockupDeviceModel {
        guard let url = locate() else { throw MockupDeviceLibrary.Failure.missingResource("V68.usdz") }
        let variant = finish.variants["Color"] == "Night_Sky" ? "Dark" : "Light"
        let source = try MockupDeviceLibrary.variantWrapper(for: url, variants: ["color": variant])
        let scene = try SCNScene(url: source, options: [.checkConsistency: false])
        var displays: [MockupDeviceModel.Display] = []
        var tracks: [JointTrack] = []
        scene.rootNode.enumerateHierarchy { node, _ in
            for key in node.animationKeys {
                if let player = node.animationPlayer(forKey: key),
                   let group = CAAnimation(scnAnimation: player.animation) as? CAAnimationGroup {
                    tracks += JointTrack.tracks(in: group, relativeTo: node)
                }
                // Joints are posed directly; SceneKit's player would fight it.
                node.removeAnimation(forKey: key)
            }
            for material in node.geometry?.materials ?? [] {
                switch material.name {
                case innerMaterial?:
                    MockupDeviceLibrary.prepare(material)
                    displays.append(.init(material: material, aspect: 15.80 / 11.08, quarterTurns: 0))
                case coverMaterial?:
                    MockupDeviceLibrary.prepare(material)
                    displays.append(.init(material: material, aspect: 7.74 / 11.23, quarterTurns: 0))
                default: break
                }
            }
        }
        guard displays.contains(where: { $0.aspect > 1 }) else { throw MockupDeviceLibrary.Failure.noScreen("V68.usdz") }
        // Inner display first: it is the one users see unfolded.
        displays.sort { $0.aspect > $1.aspect }
        // The rig lies flat, screen up (+Y), top edge toward −Z: stand it up.
        guard tracks.count > 30 else { throw MockupDeviceLibrary.Failure.unreadable("V68.usdz animation") }
        let oriented = SCNNode()
        for child in scene.rootNode.childNodes { oriented.addChildNode(child) }
        oriented.simdOrientation = simd_quatf(angle: .pi / 2, axis: simd_float3(1, 0, 0))
        // Frame the flat-open pose, then hand the fold to the slider/presets.
        for track in tracks { track.apply(at: time(open: 1)) }
        let fitted = MockupDeviceLibrary.fit(oriented)
        return MockupDeviceModel(node: fitted, displays: displays, hinge: { amount in
            let t = time(open: amount)
            for track in tracks { track.apply(at: t) }
        })
    }
}

/// One linearly keyed joint channel from SceneKit's import of a USD
/// SkelAnimation, sampled by hand so it works wherever the node ends up.
@MainActor
struct JointTrack {
    enum Channel { case position, orientation, scale }

    let node: SCNNode
    let channel: Channel
    let times: [Double]
    let values: [simd_float4]

    static func tracks(in group: CAAnimationGroup, relativeTo root: SCNNode) -> [JointTrack] {
        (group.animations ?? []).compactMap { animation in
            guard let keyframes = animation as? CAKeyframeAnimation, let path = keyframes.keyPath,
                  let values = keyframes.values as? [NSValue], !values.isEmpty else { return nil }
            let parts = path.split(separator: ".")
            guard parts.count == 2 else { return nil }
            let name = String(parts[0].drop { $0 == "/" })
            let channel: Channel
            switch parts[1] {
            case "position": channel = .position
            case "orientation": channel = .orientation
            case "scale": channel = .scale
            default: return nil
            }
            guard let node = root.name == name ? root : root.childNode(withName: name, recursively: true) else { return nil }
            let keyTimes = keyframes.keyTimes?.map(\.doubleValue) ?? values.indices.map { Double($0) / Double(max(values.count - 1, 1)) }
            guard keyTimes.count == values.count else { return nil }
            let times = keyTimes.map { keyframes.beginTime + $0 * keyframes.duration }
            let vectors = values.map { value -> simd_float4 in
                let r = value.rectValue
                return simd_float4(Float(r.origin.x), Float(r.origin.y), Float(r.size.width), Float(r.size.height))
            }
            return JointTrack(node: node, channel: channel, times: times, values: vectors)
        }
    }

    func apply(at time: Double) {
        let value = sample(time)
        switch channel {
        case .position: node.simdPosition = simd_float3(value.x, value.y, value.z)
        case .scale: node.simdScale = simd_float3(value.x, value.y, value.z)
        case .orientation: node.simdOrientation = simd_quatf(ix: value.x, iy: value.y, iz: value.z, r: value.w)
        }
    }

    private func sample(_ time: Double) -> simd_float4 {
        guard let first = times.first, time > first else { return values[0] }
        guard let upper = times.firstIndex(where: { $0 >= time }) else { return values[values.count - 1] }
        let lower = upper - 1
        let span = times[upper] - times[lower]
        let t = Float(span > 0 ? (time - times[lower]) / span : 0)
        if channel == .orientation {
            let a = simd_quatf(vector: values[lower]), b = simd_quatf(vector: values[upper])
            return simd_slerp(a, b, t).vector
        }
        return values[lower] + (values[upper] - values[lower]) * t
    }
}
