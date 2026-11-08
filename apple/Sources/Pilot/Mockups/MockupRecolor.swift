import AppKit
import ImageIO
import SceneKit

/// Retints a model Apple publishes in one color only (the iPhone Air's AR file
/// is Sky Blue) to another finish. Flat materials and textures whose color
/// carries the authored body tone's cast are scaled channel by channel by
/// `target / source`, which keeps highlights and shadows in proportion; screens,
/// glass, lenses, and neutral grays keep Apple's values.
///
/// Self-contained (no studio types) so a preview renderer can compile it alone.
struct MockupRecolor: Hashable {
    /// The model's authored body tone, sRGB hex.
    let source: UInt32
    /// The finish's body tone at the same shading level, sRGB hex.
    let target: UInt32

    /// Upper bound on one embedded texture read from the bundled archive.
    static let maxTextureBytes = 16 * 1_024 * 1_024

    // MARK: Color rule

    typealias RGB = (red: CGFloat, green: CGFloat, blue: CGFloat)

    static func components(_ hex: UInt32) -> RGB {
        (CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255)
    }

    /// Per-channel factors that carry the source tone onto the target tone.
    var factors: RGB {
        let from = Self.components(source), to = Self.components(target)
        return (to.red / max(from.red, 0.001), to.green / max(from.green, 0.001), to.blue / max(from.blue, 0.001))
    }

    /// Whether a color belongs to the tinted shell: not near-black, and its
    /// strongest-in-source channel exceeds the weakest by a visible margin.
    func isShell(_ color: RGB) -> Bool {
        guard color.red + color.green + color.blue > 0.3 else { return false }
        let reference = Self.components(source)
        let values = [color.red, color.green, color.blue]
        let order = [reference.red, reference.green, reference.blue]
        guard let strong = order.indices.max(by: { order[$0] < order[$1] }),
              let weak = order.indices.min(by: { order[$0] < order[$1] }) else { return false }
        return values[strong] - values[weak] > 0.02
    }

    /// The retinted color, or nil when it isn't part of the shell.
    func retint(_ color: RGB) -> RGB? {
        guard isShell(color) else { return nil }
        let k = factors
        return (min(1, color.red * k.red), min(1, color.green * k.green), min(1, color.blue * k.blue))
    }

    // MARK: Scene

    func apply(to root: SCNNode) {
        var textures: [String: CGImage?] = [:]
        root.enumerateHierarchy { node, _ in
            for material in node.geometry?.materials ?? [] where !Self.isScreen(material) {
                let contents = material.diffuse.contents
                if let color = (contents as? NSColor)?.usingColorSpace(.sRGB) {
                    guard let tinted = retint((color.redComponent, color.greenComponent, color.blueComponent)) else { continue }
                    material.diffuse.contents = NSColor(srgbRed: tinted.red, green: tinted.green, blue: tinted.blue,
                                                        alpha: color.alphaComponent)
                } else if let key = Self.textureKey(contents) {
                    if textures[key] == nil { textures[key] = Self.textureImage(contents).flatMap(retinted) }
                    if let image = textures[key] ?? nil { material.diffuse.contents = image }
                }
            }
        }
    }

    /// Screens carry an image in emission; they are never shell.
    private static func isScreen(_ material: SCNMaterial) -> Bool {
        guard let emission = material.emission.contents else { return false }
        return !(emission is NSColor) && !(emission is NSNumber)
    }

    // MARK: Textures

    private static func textureKey(_ contents: Any?) -> String? {
        if let url = contents as? URL { return url.absoluteString }
        if let path = contents as? String { return path }
        return nil
    }

    /// Decodes a diffuse texture. SceneKit addresses `.usdz` members as
    /// `file:///…/model.usdz?offset=N&size=M`; that byte range is read with a
    /// size bound rather than trusting the archive.
    static func textureImage(_ contents: Any?) -> CGImage? {
        let url: URL
        if let value = contents as? URL { url = value } else if let path = contents as? String {
            url = URL(fileURLWithPath: path)
        } else { return nil }
        let data: Data
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let items = components.queryItems,
           let offset = items.first(where: { $0.name == "offset" })?.value.flatMap(UInt64.init),
           let size = items.first(where: { $0.name == "size" })?.value.flatMap(Int.init) {
            guard size > 0, size <= maxTextureBytes,
                  let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: components.path)) else { return nil }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let bytes = try? handle.read(upToCount: size), bytes.count == size else { return nil }
            data = bytes
        } else {
            guard url.isFileURL, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= maxTextureBytes, let bytes = try? Data(contentsOf: url) else { return nil }
            data = bytes
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The texture scaled into the target tone when its average color is
    /// shell; nil (keep the original) otherwise.
    func retinted(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width * height <= 8_192 * 8_192,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let base = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = base.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var sum: (Double, Double, Double, Double) = (0, 0, 0, 0)
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            let alpha = Double(pixels[index + 3])
            sum.0 += Double(pixels[index]); sum.1 += Double(pixels[index + 1]); sum.2 += Double(pixels[index + 2])
            sum.3 += alpha
        }
        // Premultiplied sums divided by total alpha give the coverage-weighted mean.
        guard sum.3 > 0 else { return nil }
        let average: RGB = (CGFloat(sum.0 / sum.3), CGFloat(sum.1 / sum.3), CGFloat(sum.2 / sum.3))
        guard isShell(average) else { return nil }
        let k = factors
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            let alpha = CGFloat(pixels[index + 3])
            pixels[index] = UInt8(min(alpha, CGFloat(pixels[index]) * k.red).rounded())
            pixels[index + 1] = UInt8(min(alpha, CGFloat(pixels[index + 1]) * k.green).rounded())
            pixels[index + 2] = UInt8(min(alpha, CGFloat(pixels[index + 2]) * k.blue).rounded())
        }
        return context.makeImage()
    }
}
