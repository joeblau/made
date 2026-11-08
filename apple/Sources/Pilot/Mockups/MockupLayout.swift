import AppKit

/// Device-specific compositions observed in PostSpark's layout rail.
/// Geometry is expressed in device dimensions. No third-party artwork is bundled.
enum MockupLayout: String, CaseIterable, Identifiable {
    case centered, angled, top, topCloseUp, bottom, bottomCloseUp
    case pair, pairStaggered, pairOverlap, pairAngled, pairFan, pairSplit
    case triple, tripleStaggered, tripleFan, tripleCascade, tripleOverlap, tripleHero, tripleAngled
    case responsive
    case topAligned, bottomAligned, leftCloseUp, rightCloseUp, left, right

    static func referenceLayouts(for device: MockupDevice) -> [MockupLayout] {
        switch device {
        case .macBookPro14:
            [.centered, .leftCloseUp, .rightCloseUp, .left, .right, .bottomAligned, .pair]
        case .iPadPro13:
            [.centered, .angled, .topAligned, .bottomAligned, .pair, .pairOverlap, .pairAngled, .pairFan]
        case .iPhone18Pro, .iPhone18ProMax, .iPhoneDuo, .iPhoneAir, .iPhone17, .iPhone17e:
            [.centered, .angled, .top, .topCloseUp, .bottom, .bottomCloseUp,
             .pair, .pairStaggered, .pairOverlap, .pairAngled, .pairFan, .pairSplit,
             .triple, .tripleStaggered, .tripleFan, .tripleCascade, .tripleOverlap, .tripleHero, .tripleAngled]
        }
    }

    static func available(for device: MockupDevice) -> [MockupLayout] {
        referenceLayouts(for: device) + [.responsive]
    }

    var screenCount: Int {
        switch self {
        case .pair, .pairStaggered, .pairOverlap, .pairAngled, .pairFan, .pairSplit, .responsive: 2
        case .triple, .tripleStaggered, .tripleFan, .tripleCascade, .tripleOverlap, .tripleHero, .tripleAngled: 3
        default: 1
        }
    }

    var id: String { rawValue }
    var title: String {
        switch self {
        case .centered: "Centered"
        case .angled: "Angled"
        case .top: "Top Detail"
        case .topCloseUp: "Top Close-up"
        case .bottom: "Bottom Detail"
        case .bottomCloseUp: "Bottom Close-up"
        case .pair: "Side by Side"
        case .pairStaggered: "Staggered Pair"
        case .pairOverlap: "Overlapping Pair"
        case .pairAngled: "Angled Pair"
        case .pairFan: "Fanned Pair"
        case .pairSplit: "Split Pair"
        case .triple: "Three Across"
        case .tripleStaggered: "Staggered Trio"
        case .tripleFan: "Fanned Trio"
        case .tripleCascade: "Cascading Trio"
        case .tripleOverlap: "Overlapping Trio"
        case .tripleHero: "Center Hero"
        case .tripleAngled: "Angled Trio"
        case .responsive: "Responsive Design"
        case .topAligned: "Top Aligned"
        case .bottomAligned: "Bottom Aligned"
        case .leftCloseUp: "Left Close-up"
        case .rightCloseUp: "Right Close-up"
        case .left: "Left Edge"
        case .right: "Right Edge"
        }
    }

    struct Slot {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var scale: CGFloat = 1
        var rotation: CGFloat = 0
        var layer: Int = 0
    }

    func slots(for device: MockupDevice) -> [Slot] {
        if device == .iPadPro13 {
            switch self {
            case .centered: return [.init()]
            case .angled: return [.init(scale: 0.9, rotation: 8)]
            case .topAligned: return [.init(y: 0.22)]
            case .bottomAligned: return [.init(y: -0.22)]
            case .pair: return [.init(), .init()]
            case .pairOverlap: return [.init(x: 0.2, y: 0.15), .init(x: -0.2, y: -0.15, layer: 1)]
            case .pairAngled: return [.init(x: 0.24, y: 0.1, rotation: 15), .init(x: -0.24, y: -0.1, rotation: 15, layer: 1)]
            case .pairFan: return [.init(x: 0.15, y: 0.15, rotation: 15), .init(x: -0.15, y: -0.15, rotation: -10, layer: 1)]
            default: break
            }
        } else if device == .macBookPro14 {
            switch self {
            case .centered: return [.init()]
            case .pair: return [.init(), .init()]
            default: break
            }
        }
        return defaultSlots
    }

    private var defaultSlots: [Slot] {
        switch self {
        case .centered: [.init(scale: 0.95)]
        case .angled: [.init(scale: 0.9, rotation: 10)]
        case .top: [.init(y: -0.25, scale: 1.25)]
        case .topCloseUp: [.init(y: -0.45, scale: 1.7)]
        case .bottom: [.init(y: 0.25, scale: 1.25)]
        case .bottomCloseUp: [.init(y: 0.45, scale: 1.7)]
        case .pair: [.init(x: 0.03, scale: 0.8), .init(x: -0.03, scale: 0.8)]
        case .pairStaggered: [.init(y: 0.08, scale: 0.85), .init(y: -0.08, scale: 0.85)]
        case .pairOverlap: [.init(x: 0.25, y: 0.08, scale: 0.75), .init(x: -0.25, y: -0.08, scale: 0.75, layer: 1)]
        case .pairAngled: [.init(x: 0.2, y: 0.05, scale: 0.8, rotation: 15), .init(x: -0.2, y: -0.05, scale: 0.8, rotation: 15, layer: 1)]
        case .pairFan: [.init(x: 0.16, y: 0.08, scale: 0.8, rotation: 10), .init(x: -0.16, y: -0.08, scale: 0.8, rotation: -9, layer: 1)]
        case .pairSplit: [.init(x: -0.03, y: 0.25, scale: 0.9), .init(x: 0.03, y: -0.25, scale: 0.9)]
        case .triple: [.init(x: 0.1, scale: 0.8), .init(scale: 0.8), .init(x: -0.1, scale: 0.8)]
        case .tripleStaggered: [.init(x: 0.1, y: -0.1, scale: 0.8), .init(scale: 0.8), .init(x: -0.1, y: 0.1, scale: 0.8)]
        case .tripleFan: [.init(x: 0.47, y: -0.04, scale: 0.83, rotation: 16), .init(scale: 0.91, rotation: 5, layer: 1), .init(x: -0.45, scale: 0.98, rotation: -5, layer: 2)]
        case .tripleCascade: [.init(x: 0.5, y: -0.12, scale: 0.78, rotation: -6), .init(scale: 0.78, rotation: 4, layer: 1), .init(x: -0.5, y: 0.13, scale: 0.78, rotation: 14, layer: 2)]
        case .tripleOverlap: [.init(x: 0.38, y: -0.02, scale: 0.9, rotation: 14), .init(y: 0.02, layer: 1), .init(x: -0.38, y: -0.02, scale: 0.9, rotation: -14)]
        case .tripleHero: [.init(x: 0.1, y: -0.075, scale: 0.75), .init(scale: 0.9), .init(x: -0.1, y: -0.075, scale: 0.75)]
        case .tripleAngled: [.init(x: 0.1, y: 0.08, scale: 0.8, rotation: 10), .init(scale: 0.8, rotation: 10), .init(x: -0.1, y: -0.08, scale: 0.8, rotation: 10)]
        case .responsive: [.init(y: -0.12, scale: 0.85, layer: 1), .init()]
        case .topAligned: [.init(y: 0.22)]
        case .bottomAligned: [.init(y: -0.25, scale: 1.2)]
        case .leftCloseUp: [.init(x: -0.15, y: -0.15, scale: 1.4)]
        case .rightCloseUp: [.init(x: 0.15, y: -0.15, scale: 1.4)]
        case .left: [.init(x: -0.2, scale: 1.1)]
        case .right: [.init(x: 0.2, scale: 1.1)]
        }
    }

    func devices(for device: MockupDevice) -> [MockupDevice] {
        if self == .responsive {
            return [device.group == "iPhone" ? device : .iPhone18Pro, .macBookPro14]
        }
        return Array(repeating: device, count: screenCount)
    }

    struct Placement {
        let center: CGPoint
        /// Multiplier applied to a model whose longest dimension is one unit.
        let scale: CGFloat
        let rotation: CGFloat
        let layer: Int
    }

    /// Shared by the native thumbnails and SceneKit. `sizes` are the models'
    /// front silhouettes, normalised to a longest dimension of one unit.
    func placements(for device: MockupDevice, in canvas: CGSize, sizes: [CGSize]) -> [Placement] {
        let slots = slots(for: device)
        guard sizes.count == slots.count, canvas.width > 0, canvas.height > 0,
              sizes.allSatisfy({ $0.width > 0 && $0.height > 0 }) else { return [] }
        let gap: CGFloat = 0.04
        let weights: [CGFloat] = self == .responsive ? [0.58, 1] : Array(repeating: 1, count: sizes.count)
        let widths = zip(sizes, weights).map { $0.width * $1 }
        let heights = zip(sizes, weights).map { $0.height * $1 }
        let width = widths.reduce(0, +) + CGFloat(sizes.count - 1) * gap
        let height = heights.max() ?? 1
        let groupScale: CGFloat = device.group == "iPhone" ? (self == .pairStaggered ? 0.9 : self == .pairFan ? 0.95 : 1) : 1
        // Wide-device rails keep padding in device units: about 83% canvas
        // width for a single device and 91% for a pair on a square artboard.
        let fit: CGFloat
        if device.keepsBaseLevel && self != .responsive {
            fit = min(canvas.width / (width + 0.2), canvas.height / (height + 0.2))
        } else {
            fit = min(canvas.width * 0.82 / width, canvas.height * 0.82 / height) * groupScale
        }
        var cursor = -width / 2
        return slots.indices.map { index in
            let slot = slots[index]
            let x = cursor + widths[index] / 2 + slot.x * widths[index]
            cursor += widths[index] + gap
            return Placement(center: CGPoint(x: canvas.width / 2 + x * fit,
                                             y: canvas.height / 2 + slot.y * heights[index] * fit),
                             scale: fit * weights[index] * slot.scale,
                             rotation: slot.rotation, layer: slot.layer)
        }
    }
}
