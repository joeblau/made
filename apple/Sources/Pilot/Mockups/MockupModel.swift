import AppKit
import Observation

/// The two studios under Mock-ups: flat device frames for stills, and a 3D
/// stage that animates a device for video.
enum MockupKind: String, CaseIterable, Identifiable {
    case photo
    case video

    var id: String { rawValue }
    var title: String { self == .photo ? "Photo" : "Video" }
}

/// A canvas shape. `nil` dimensions mean "Auto": the canvas hugs the device.
struct MockupAspectRatio: Hashable, Identifiable {
    let id: String
    let name: String
    let group: String
    let width: CGFloat
    let height: CGFloat

    var label: String {
        let format: (CGFloat) -> String = { $0.rounded() == $0 ? String(Int($0)) : String(format: "%.3g", $0) }
        return "\(format(width)):\(format(height))"
    }
    var ratio: CGFloat { width / height }

    /// Union of the PostSpark and Screen Studio presets, grouped the way the
    /// picker shows them.
    static let presets: [MockupAspectRatio] = [
        .init(id: "square", name: "Square", group: "General", width: 1, height: 1),
        .init(id: "standard", name: "Standard", group: "General", width: 4, height: 3),
        .init(id: "classic", name: "Classic", group: "General", width: 3, height: 2),
        .init(id: "golden", name: "Golden", group: "General", width: 1.618, height: 1),
        .init(id: "photo", name: "Photo", group: "General", width: 5, height: 4),
        .init(id: "wide", name: "Widescreen", group: "General", width: 16, height: 9),
        .init(id: "vertical", name: "Vertical", group: "General", width: 9, height: 16),
        .init(id: "tall", name: "Tall", group: "General", width: 3, height: 4),
        .init(id: "portrait", name: "Portrait", group: "General", width: 4, height: 5),
        .init(id: "x-post", name: "Post Image", group: "X", width: 16, height: 9),
        .init(id: "x-header", name: "Header Photo", group: "X", width: 3, height: 1),
        .init(id: "ig-post", name: "Post", group: "Instagram", width: 4, height: 5),
        .init(id: "ig-story", name: "Story / Reel", group: "Instagram", width: 9, height: 16),
        .init(id: "app-store-iphone", name: "iPhone 6.9″", group: "App Store", width: 1320, height: 2868),
        .init(id: "app-store-ipad", name: "iPad 13″", group: "App Store", width: 2064, height: 2752),
    ]

    static let `default` = presets[0]
    static func preset(id: String) -> MockupAspectRatio? { presets.first { $0.id == id } }

    /// Largest rect of this ratio centered inside `bounds` after `inset`.
    static func fit(ratio: CGFloat, in bounds: CGRect, inset: CGFloat = 0) -> CGRect {
        let available = bounds.insetBy(dx: inset, dy: inset)
        guard ratio > 0, available.width > 0, available.height > 0 else { return .zero }
        var size = CGSize(width: available.width, height: available.width / ratio)
        if size.height > available.height { size = CGSize(width: available.height * ratio, height: available.height) }
        return CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                      width: size.width, height: size.height).integral
    }
}

/// sRGB color stored as components so documents stay value types.
struct MockupColor: Hashable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat

    init(red: CGFloat, green: CGFloat, blue: CGFloat) {
        self.red = red; self.green = green; self.blue = blue
    }
    init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255)
    }
    init(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
        let color = NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        self.init(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
    }

    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

    /// PostSpark-style swatch grid: pastels, neutrals, then saturated hues.
    static let palette: [MockupColor] = {
        var colors: [MockupColor] = []
        for hue in stride(from: 0.0, to: 1.0, by: 1.0 / 12) {
            colors.append(MockupColor(hue: hue, saturation: 0.12, brightness: 0.98))
        }
        for gray in [1.0, 0.86, 0.62, 0.36, 0.18, 0.04] {
            colors.append(MockupColor(red: gray, green: gray, blue: gray))
        }
        for hue in stride(from: 0.0, to: 1.0, by: 1.0 / 24) {
            colors.append(MockupColor(hue: hue, saturation: 0.62, brightness: 0.92))
        }
        for hue in stride(from: 0.0, to: 1.0, by: 1.0 / 12) {
            colors.append(MockupColor(hue: hue, saturation: 0.78, brightness: 0.55))
        }
        return colors
    }()
}

struct MockupGradient: Hashable {
    var start: MockupColor
    var end: MockupColor
    /// Degrees, 0 = left→right, 90 = bottom→top.
    var angle: CGFloat

    static let presets: [MockupGradient] = [
        .init(start: .init(hex: 0x1E1B4B), end: .init(hex: 0x7C3AED), angle: 120),
        .init(start: .init(hex: 0xF97316), end: .init(hex: 0xDB2777), angle: 45),
        .init(start: .init(hex: 0x0EA5E9), end: .init(hex: 0x22C55E), angle: 135),
        .init(start: .init(hex: 0x111827), end: .init(hex: 0x4B5563), angle: 90),
        .init(start: .init(hex: 0xFDE68A), end: .init(hex: 0xF472B6), angle: 60),
        .init(start: .init(hex: 0x2563EB), end: .init(hex: 0x06B6D4), angle: 30),
        .init(start: .init(hex: 0x14532D), end: .init(hex: 0x84CC16), angle: 100),
        .init(start: .init(hex: 0x0F172A), end: .init(hex: 0x1D4ED8), angle: 160),
    ]
}

enum MockupBackground: Equatable {
    case none
    case solid(MockupColor)
    case gradient(MockupGradient)
    case image(NSImage)

    enum Style: String, CaseIterable { case none = "None", solid = "Solid", gradient = "Gradient", image = "Image" }

    var style: Style {
        switch self {
        case .none: .none
        case .solid: .solid
        case .gradient: .gradient
        case .image: .image
        }
    }
}

/// One shippable look of a device: which bundled Apple AR model to load and
/// which USD variants to select inside it.
struct MockupFinish: Hashable {
    let name: String
    /// Swatch for the finish picker.
    let swatch: MockupColor
    /// Bundled `.usdz` basename (see apple/bin/fetch-mockup-models.sh).
    let resource: String
    /// USD variantSet selections, applied through a generated wrapper layer.
    var variants: [String: String] = [:]
}

/// Devices the studios can frame (Apple's lineup as of 2026-11), each backed
/// by Apple's public AR Quick Look model. Provenance is in docs/mockups.md.
enum MockupDevice: String, CaseIterable, Identifiable {
    case iPhone18Pro
    case iPhone18ProMax
    case iPhoneDuo
    case iPhoneAir
    case iPhone17
    case iPhone17e
    case iPadPro13
    case macBookPro14

    /// Which part of a multi-device file to keep.
    enum Selection {
        case whole
        /// Files that hold two phones: keep the one with the larger/smaller screen.
        case largestScreen
        case smallestScreen
        /// iPad on Magic Keyboard: keep only the tablet.
        case screenBody
    }

    enum Hinge {
        case none
        /// MacBook lid: rotate the lid node about its authored pivot.
        case lid
        /// iPhone Duo: two halves about a vertical axis.
        case fold
    }

    var id: String { rawValue }

    var name: String {
        switch self {
        case .iPhone18Pro: "iPhone 18 Pro"
        case .iPhone18ProMax: "iPhone 18 Pro Max"
        case .iPhoneDuo: "iPhone Duo"
        case .iPhoneAir: "iPhone Air"
        case .iPhone17: "iPhone 17"
        case .iPhone17e: "iPhone 17e"
        case .iPadPro13: "iPad Pro 13″ + Keyboard"
        case .macBookPro14: "MacBook Pro 14″"
        }
    }

    var group: String {
        switch self {
        case .iPadPro13: "iPad"
        case .macBookPro14: "Mac"
        default: "iPhone"
        }
    }

    var symbol: String {
        switch self {
        case .iPadPro13: "ipad"
        case .macBookPro14: "laptopcomputer"
        default: "iphone"
        }
    }

    /// Native panel pixels (portrait for phones/iPad, landscape for Mac); the
    /// Duo's is its unfolded inner display.
    var screenPixels: CGSize {
        switch self {
        case .iPhone18Pro, .iPhone17: CGSize(width: 1206, height: 2622)
        case .iPhone18ProMax: CGSize(width: 1320, height: 2868)
        case .iPhoneDuo: CGSize(width: 2560, height: 1800)
        case .iPhoneAir: CGSize(width: 1260, height: 2736)
        case .iPhone17e: CGSize(width: 1170, height: 2532)
        case .iPadPro13: CGSize(width: 2752, height: 2064)
        case .macBookPro14: CGSize(width: 3024, height: 1964)
        }
    }

    var selection: Selection {
        switch self {
        case .iPhone18ProMax: .largestScreen
        case .iPhone18Pro: .smallestScreen
        default: .whole
        }
    }

    /// Laptops and the iPad on its keyboard sit on a surface; only yaw them.
    var keepsBaseLevel: Bool { self == .macBookPro14 || self == .iPadPro13 }

    /// Apple stores the iPad Pro screen texture portrait on a landscape panel.
    var screenQuarterTurns: Int { self == .iPadPro13 ? 1 : 0 }

    var hinge: Hinge {
        switch self {
        case .macBookPro14: .lid
        case .iPhoneDuo: .fold
        default: .none
        }
    }

    var finishes: [MockupFinish] {
        switch self {
        case .iPhone18Pro, .iPhone18ProMax:
            [("Burgundy", 0x5E2430), ("Black", 0x2A2A2C), ("Glacier", 0xC9D6DE), ("Silver", 0xD9D9DB)].map {
                MockupFinish(name: $0.0, swatch: .init(hex: $0.1), resource: "iphone-18-pro", variants: ["Color": $0.0])
            }
        case .iPhoneDuo:
            [("Star White", "Star_White", 0xEDEAE3), ("Night Sky", "Night_Sky", 0x1F2633)].map {
                MockupFinish(name: $0.0, swatch: .init(hex: $0.2), resource: "iphone-duo", variants: ["Color": $0.1, "Pose": "Landscape"])
            }
        case .iPhoneAir: [MockupFinish(name: "Sky Blue", swatch: .init(hex: 0xC9D9E6), resource: "iphone-air")]
        case .iPhone17: [MockupFinish(name: "Lavender", swatch: .init(hex: 0xC9BCE0), resource: "iphone-17")]
        case .iPhone17e:
            [MockupFinish(name: "Soft Pink", swatch: .init(hex: 0xEBCFCF), resource: "iphone-17e-soft-pink"),
             MockupFinish(name: "White", swatch: .init(hex: 0xF2F2F0), resource: "iphone-17e-white"),
             MockupFinish(name: "Black", swatch: .init(hex: 0x2A2A2C), resource: "iphone-17e-black")]
        case .iPadPro13:
            [MockupFinish(name: "Space Black", swatch: .init(hex: 0x2B2B2D), resource: "ipad-pro-space-black"),
             MockupFinish(name: "Silver", swatch: .init(hex: 0xD9D9DB), resource: "ipad-pro-silver")]
        case .macBookPro14:
            [MockupFinish(name: "Space Black", swatch: .init(hex: 0x2B2B2D), resource: "macbook-pro-14-space-black"),
             MockupFinish(name: "Silver", swatch: .init(hex: 0xD9D9DB), resource: "macbook-pro-14-silver")]
        }
    }
}

/// Everything one mock-up needs to render. Owned by the studio controller and
/// shared by the photo canvas and the video stage.
@Observable
@MainActor
final class MockupDocument {
    var kind: MockupKind = .photo
    var aspect: MockupAspectRatio = .default
    var background: MockupBackground = .solid(MockupColor(hex: 0x7CF866))
    var device: MockupDevice = .iPhone18Pro { didSet { if oldValue != device { finishIndex = 0 } } }
    /// Static framing the motion presets play around (radians).
    var tiltX: CGFloat = 0
    var tiltY: CGFloat = 0
    /// 0 closed … 1 open, for the Duo and MacBook.
    var openAmount: CGFloat = 1
    var finishIndex = 0
    var screenshot: NSImage?
    /// Degrees of in-plane rotation for photo mode.
    var rotation: CGFloat = 0
    /// Device height as a fraction of the canvas height.
    var scale: CGFloat = 0.82
    var motion: MockupMotion = .turntable
    var isPlaying = true

    var finish: MockupFinish {
        let finishes = device.finishes
        return finishes[min(max(finishIndex, 0), finishes.count - 1)]
    }

    /// The user's static pose; presets add their motion on top.
    var basePose: MockupPose {
        MockupPose(yaw: Double(tiltY), pitch: Double(tiltX), roll: Double(rotation * .pi / 180),
                   scale: Double(scale / 0.82), open: Double(openAmount))
    }
}
