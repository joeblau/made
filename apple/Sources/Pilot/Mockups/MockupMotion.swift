import Foundation

/// Where the device is at one instant. Angles in radians; `open` is 0 (closed)
/// to 1 (fully open) for hinged devices and ignored by slabs.
struct MockupPose: Codable, Equatable {
    var yaw: Double = 0
    var pitch: Double = 0
    var roll: Double = 0
    var pan: Double = 0
    var lift: Double = 0
    var scale: Double = 1
    var open: Double = 1

    var isFinite: Bool {
        [yaw, pitch, roll, pan, lift, scale, open].allSatisfy(\.isFinite) && scale > 0
    }

    static func lerp(_ a: MockupPose, _ b: MockupPose, _ t: Double) -> MockupPose {
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        return MockupPose(yaw: mix(a.yaw, b.yaw), pitch: mix(a.pitch, b.pitch), roll: mix(a.roll, b.roll),
                          pan: mix(a.pan, b.pan), lift: mix(a.lift, b.lift),
                          scale: mix(a.scale, b.scale), open: mix(a.open, b.open))
    }
}

/// Animation presets that generate editable keyframe timelines.
enum MockupMotion: String, CaseIterable, Identifiable {
    case turntable = "Turntable"
    case heroTilt = "Hero Tilt"
    case float = "Float"
    case openReveal = "Open & Reveal"
    case flipIn = "Flip In"
    case slideUp = "Slide Up"
    case still = "Still"
    case custom = "Custom"

    var id: String { rawValue }
}
