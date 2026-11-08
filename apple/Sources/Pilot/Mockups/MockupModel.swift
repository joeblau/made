import AppKit
import Observation

/// Photo and Video share the same device composition and 3D stage.
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

/// A color stored as components in its own space so documents stay value
/// types. Backdrops default to Display P3; device finishes are sRGB paint.
struct MockupColor: Hashable {
    enum Space: Hashable { case sRGB, displayP3 }

    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var space: Space

    init(red: CGFloat, green: CGFloat, blue: CGFloat, space: Space = .displayP3) {
        self.red = red; self.green = green; self.blue = blue; self.space = space
    }
    init(hex: UInt32, space: Space = .sRGB) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, space: space)
    }
    /// HSV in the given space (P3 by default, so saturated hues use the wide gamut).
    init(hue: CGFloat, saturation: CGFloat, brightness: CGFloat, space: Space = .displayP3) {
        let (red, green, blue) = MockupColorFormat.rgb(hue: hue, saturation: saturation, value: brightness)
        self.init(red: red, green: green, blue: blue, space: space)
    }

    var nsColor: NSColor {
        switch space {
        case .sRGB: NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        case .displayP3: NSColor(displayP3Red: red, green: green, blue: blue, alpha: 1)
        }
    }

    /// The same component values interpreted in another space: `#7CF866`
    /// stays `#7CF866` but renders in that gamut.
    func interpreted(in space: Space) -> MockupColor {
        MockupColor(red: red, green: green, blue: blue, space: space)
    }

    /// The swatch grid in the chosen backdrop space.
    static func palette(in space: Space) -> [MockupColor] { palette.map { $0.interpreted(in: space) } }

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
        .init(start: .init(hex: 0x1E1B4B, space: .displayP3), end: .init(hex: 0x7C3AED, space: .displayP3), angle: 120),
        .init(start: .init(hex: 0xF97316, space: .displayP3), end: .init(hex: 0xDB2777, space: .displayP3), angle: 45),
        .init(start: .init(hex: 0x0EA5E9, space: .displayP3), end: .init(hex: 0x22C55E, space: .displayP3), angle: 135),
        .init(start: .init(hex: 0x111827, space: .displayP3), end: .init(hex: 0x4B5563, space: .displayP3), angle: 90),
        .init(start: .init(hex: 0xFDE68A, space: .displayP3), end: .init(hex: 0xF472B6, space: .displayP3), angle: 60),
        .init(start: .init(hex: 0x2563EB, space: .displayP3), end: .init(hex: 0x06B6D4, space: .displayP3), angle: 30),
        .init(start: .init(hex: 0x14532D, space: .displayP3), end: .init(hex: 0x84CC16, space: .displayP3), angle: 100),
        .init(start: .init(hex: 0x0F172A, space: .displayP3), end: .init(hex: 0x1D4ED8, space: .displayP3), angle: 160),
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
    /// For a model Apple publishes in one color only: retints its flat-colored
    /// shell materials from the authored body tone to this finish's.
    var recolor: MockupRecolor?
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

    /// The Sky Blue model's authored frame tone, rgb(0.68, 0.76, 0.81).
    static let iPhoneAirBodyTone: UInt32 = 0xADC2CF

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
        case .iPhoneAir:
            // Apple publishes the Air's AR model in Sky Blue only; the other
            // finishes retint its flat shell materials.
            [("Sky Blue", 0xC9D9E6, nil), ("Light Gold", 0xE6D9C1, 0xD9CCB4),
             ("Cloud White", 0xF0EFEB, 0xE0DFDA), ("Space Black", 0x2F2F31, 0x2C2C2E)].map { (name: String, swatch: UInt32, body: UInt32?) in
                MockupFinish(name: name, swatch: .init(hex: swatch), resource: "iphone-air",
                             recolor: body.map { MockupRecolor(source: Self.iPhoneAirBodyTone, target: $0) })
            }
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
    var background: MockupBackground = .solid(MockupColor(hex: 0x7CF866, space: .displayP3))
    var device: MockupDevice = .iPhone18Pro {
        didSet {
            if oldValue != device { finishIndex = 0 }
            if !availableLayouts.contains(layout) { selectLayout(.centered) }
        }
    }
    var layout: MockupLayout = .centered {
        didSet {
            if !availableLayouts.contains(layout) { layout = .centered }
            selectedScreen = min(selectedScreen, layout.screenCount - 1)
        }
    }
    var selectedScreen = 0
    /// Stable slots retain their content when a smaller layout hides them.
    private var screenshots: [NSImage?] = [nil, nil, nil]
    /// Static framing and the values captured by a keyframe (angles in radians).
    var tiltX: CGFloat = 0
    var tiltY: CGFloat = 0
    var positionX: CGFloat = 0
    var positionY: CGFloat = 0
    /// 0 closed … 1 open, for the Duo and MacBook.
    var openAmount: CGFloat = 1
    var finishIndex = 0
    var screenshot: NSImage? {
        get { screenshot(at: selectedScreen) }
        set { setScreenshot(newValue, at: selectedScreen) }
    }
    /// Degrees of in-plane rotation for photo mode.
    var rotation: CGFloat = 0
    /// Device height as a fraction of the canvas height.
    var scale: CGFloat = 0.82
    var motion: MockupMotion = .turntable
    var timeline = MockupTimeline.preset(.turntable, base: MockupPose())
    var playhead: Double = 0
    var selectedKeyframeID: MockupKeyframe.ID?
    var isPlaying = true

    var finish: MockupFinish {
        let finishes = device.finishes
        return finishes[min(max(finishIndex, 0), finishes.count - 1)]
    }

    var devices: [MockupDevice] { layout.devices(for: device) }
    var availableLayouts: [MockupLayout] { MockupLayout.available(for: device) }
    var selectedKeyframe: MockupKeyframe? { timeline.keyframes.first { $0.id == selectedKeyframeID } }
    var selectedKeyframeStart: Double? {
        selectedKeyframeID.flatMap { timeline.startTime(for: $0) }
    }
    var canEditSelectedKeyframe: Bool {
        kind == .video && selectedKeyframeStart.map { abs($0 - playhead) < 0.001 } == true
    }

    func finish(for device: MockupDevice) -> MockupFinish {
        device == self.device ? finish : device.finishes[0]
    }

    func screenshot(at index: Int) -> NSImage? {
        screenshots.indices.contains(index) ? screenshots[index] : nil
    }

    func setScreenshot(_ image: NSImage?, at index: Int) {
        guard screenshots.indices.contains(index) else { return }
        screenshots[index] = image
    }

    func selectLayout(_ layout: MockupLayout) {
        self.layout = layout
        tiltX = 0; tiltY = 0; rotation = 0; scale = 0.82
        positionX = 0; positionY = 0
    }

    /// The inspector's current pose, or the pose being written into a keyframe.
    var basePose: MockupPose {
        MockupPose(yaw: Double(tiltY), pitch: Double(tiltX), roll: Double(rotation * .pi / 180),
                   pan: Double(positionX), lift: Double(positionY),
                   scale: Double(scale / 0.82), open: Double(openAmount))
    }

    func applyMotion(_ motion: MockupMotion) {
        guard motion != .custom else { return }
        self.motion = motion
        timeline = MockupTimeline.preset(motion, base: basePose)
        playhead = 0
        selectedKeyframeID = timeline.keyframes.first?.id
        if let pose = timeline.keyframes.first?.pose { setStaticPose(pose) }
        isPlaying = true
    }

    func togglePlayback() {
        if isPlaying {
            isPlaying = false
            setStaticPose(timeline.pose(at: playhead))
        } else {
            if playhead >= timeline.duration { playhead = 0 }
            selectedKeyframeID = nil
            isPlaying = true
        }
    }

    func seek(to time: Double) {
        isPlaying = false
        selectedKeyframeID = nil
        playhead = min(max(time, 0), timeline.duration)
        setStaticPose(timeline.pose(at: playhead))
    }

    func selectKeyframe(_ id: MockupKeyframe.ID) {
        guard let keyframe = timeline.keyframes.first(where: { $0.id == id }), let start = timeline.startTime(for: id) else { return }
        isPlaying = false
        selectedKeyframeID = id
        playhead = start
        setStaticPose(keyframe.pose)
    }

    func stepKeyframe(_ direction: Int) {
        let times = timeline.keyframes.indices.map { timeline.startTime(at: $0) }
        let index: Int?
        if direction < 0 {
            index = times.indices.last(where: { times[$0] < playhead - 0.001 })
        } else {
            index = times.indices.first(where: { times[$0] > playhead + 0.001 })
        }
        if let index { selectKeyframe(timeline.keyframes[index].id) }
    }

    func addKeyframe() {
        let pose = isPlaying ? timeline.pose(at: playhead) : basePose
        guard let id = timeline.addKeyframe(at: playhead, pose: pose) else { return }
        motion = .custom
        selectKeyframe(id)
    }

    func deleteSelectedKeyframe() {
        guard let id = selectedKeyframeID,
              let index = timeline.keyframes.firstIndex(where: { $0.id == id }) else { return }
        timeline.removeKeyframe(id)
        motion = .custom
        let next = min(index, timeline.keyframes.count - 1)
        if timeline.keyframes.indices.contains(next) { selectKeyframe(timeline.keyframes[next].id) }
    }

    func moveSelectedKeyframe(to time: Double) {
        guard let id = selectedKeyframeID else { return }
        let previous = timeline
        timeline.moveKeyframe(id, to: time)
        guard timeline != previous else { return }
        motion = .custom
        playhead = timeline.startTime(for: id) ?? playhead
        isPlaying = false
    }

    func setSelectedDuration(_ duration: Double) {
        guard let id = selectedKeyframeID else { return }
        timeline.setDuration(duration, for: id)
        motion = .custom
        isPlaying = false
    }

    func setSelectedEasing(_ easing: MockupEasing) {
        guard let id = selectedKeyframeID else { return }
        timeline.setEasing(easing, for: id)
        motion = .custom
        isPlaying = false
    }

    func updateSelectedPose() {
        guard canEditSelectedKeyframe, let id = selectedKeyframeID else { return }
        timeline.updatePose(basePose, for: id)
        motion = .custom
    }

    private func setStaticPose(_ pose: MockupPose) {
        tiltX = CGFloat(pose.pitch)
        tiltY = CGFloat(pose.yaw)
        rotation = CGFloat(pose.roll * 180 / .pi)
        positionX = CGFloat(pose.pan)
        positionY = CGFloat(pose.lift)
        scale = CGFloat(pose.scale * 0.82)
        openAmount = CGFloat(pose.open)
    }
}

/// How the backdrop color is shown and typed. Values are the color's own
/// components in the backdrop space (the separate Display P3 setting).
enum MockupColorFormat: String, CaseIterable {
    case hex = "HEX", rgb = "RGB", hsl = "HSL", hsv = "HSV"

    static let defaultsKey = "mockups.colorFormat"
    /// Backdrop colors use Display P3 unless this is set to false.
    static let displayP3DefaultsKey = "mockups.displayP3"

    var placeholder: String {
        switch self {
        case .hex: "#7CF866"
        case .rgb: "124, 248, 102"
        case .hsl: "111°, 91%, 69%"
        case .hsv: "111°, 59%, 97%"
        }
    }

    func string(for color: MockupColor) -> String {
        let byte = { (value: CGFloat) in Int((min(max(value, 0), 1) * 255).rounded()) }
        switch self {
        case .hex:
            return String(format: "#%02X%02X%02X", byte(color.red), byte(color.green), byte(color.blue))
        case .rgb:
            return "\(byte(color.red)), \(byte(color.green)), \(byte(color.blue))"
        case .hsl:
            let (hue, saturation, lightness) = Self.hsl(color)
            return "\(Int((hue * 360).rounded()) % 360)°, \(Int((saturation * 100).rounded()))%, \(Int((lightness * 100).rounded()))%"
        case .hsv:
            let (hue, saturation, value) = Self.hsv(color)
            return "\(Int((hue * 360).rounded()) % 360)°, \(Int((saturation * 100).rounded()))%, \(Int((value * 100).rounded()))%"
        }
    }

    /// Parses typed text into a color in `space`; nil when it doesn't fit the format.
    func color(from text: String, space: MockupColor.Space = .displayP3) -> MockupColor? {
        parse(text)?.interpreted(in: space)
    }

    private func parse(_ text: String) -> MockupColor? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= 64 else { return nil }
        if self == .hex {
            var digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
            if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
            guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
            return MockupColor(hex: value, space: .displayP3)
        }
        let numbers = trimmed.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
            .filter { !$0.isEmpty }.compactMap(Double.init).map { CGFloat($0) }
        guard numbers.count == 3 else { return nil }
        let (a, b, c) = (numbers[0], numbers[1], numbers[2])
        switch self {
        case .hex: return nil
        case .rgb:
            guard [a, b, c].allSatisfy({ $0 <= 255 }) else { return nil }
            return MockupColor(red: a / 255, green: b / 255, blue: c / 255)
        case .hsl, .hsv:
            guard a <= 360, b <= 100, c <= 100 else { return nil }
            let hue = a.truncatingRemainder(dividingBy: 360) / 360
            if self == .hsv { return MockupColor(hue: hue, saturation: b / 100, brightness: c / 100) }
            let lightness = c / 100, saturation = b / 100
            let value = lightness + saturation * min(lightness, 1 - lightness)
            return MockupColor(hue: hue, saturation: value == 0 ? 0 : 2 * (1 - lightness / value), brightness: value)
        }
    }

    static func rgb(hue: CGFloat, saturation: CGFloat, value: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let h = (hue - floor(hue)) * 6, chroma = value * saturation
        let x = chroma * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)), m = value - chroma
        let (r, g, b): (CGFloat, CGFloat, CGFloat) = switch Int(h) {
        case 0: (chroma, x, 0)
        case 1: (x, chroma, 0)
        case 2: (0, chroma, x)
        case 3: (0, x, chroma)
        case 4: (x, 0, chroma)
        default: (chroma, 0, x)
        }
        return (r + m, g + m, b + m)
    }

    static func hsv(_ color: MockupColor) -> (CGFloat, CGFloat, CGFloat) {
        let maximum = max(color.red, color.green, color.blue), minimum = min(color.red, color.green, color.blue)
        let delta = maximum - minimum
        return (hue(color, maximum: maximum, delta: delta), maximum == 0 ? 0 : delta / maximum, maximum)
    }

    static func hsl(_ color: MockupColor) -> (CGFloat, CGFloat, CGFloat) {
        let maximum = max(color.red, color.green, color.blue), minimum = min(color.red, color.green, color.blue)
        let delta = maximum - minimum, lightness = (maximum + minimum) / 2
        let saturation = delta == 0 ? 0 : delta / (1 - abs(2 * lightness - 1))
        return (hue(color, maximum: maximum, delta: delta), saturation, lightness)
    }

    private static func hue(_ color: MockupColor, maximum: CGFloat, delta: CGFloat) -> CGFloat {
        guard delta > 0 else { return 0 }
        let hue: CGFloat = if maximum == color.red {
            ((color.green - color.blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maximum == color.green {
            (color.blue - color.red) / delta + 2
        } else {
            (color.red - color.green) / delta + 4
        }
        let normalized = hue / 6
        return normalized < 0 ? normalized + 1 : normalized
    }
}
