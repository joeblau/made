import Foundation

/// Where the device is at one instant. Angles in radians; `open` is 0 (closed)
/// to 1 (fully open) for hinged devices and ignored by slabs.
struct MockupPose: Equatable {
    var yaw: Double = 0
    var pitch: Double = 0
    var roll: Double = 0
    var lift: Double = 0
    var scale: Double = 1
    var open: Double = 1

    static func lerp(_ a: MockupPose, _ b: MockupPose, _ t: Double) -> MockupPose {
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        return MockupPose(yaw: mix(a.yaw, b.yaw), pitch: mix(a.pitch, b.pitch), roll: mix(a.roll, b.roll),
                          lift: mix(a.lift, b.lift), scale: mix(a.scale, b.scale), open: mix(a.open, b.open))
    }
}

/// Camera/animation presets for the video studio, modelled on Rotato's set.
/// Each is a pure function of time so the live preview and the exporter
/// render identical frames.
enum MockupMotion: String, CaseIterable, Identifiable {
    case turntable = "Turntable"
    case heroTilt = "Hero Tilt"
    case float = "Float"
    case openReveal = "Open & Reveal"
    case flipIn = "Flip In"
    case slideUp = "Slide Up"
    case still = "Still"

    var id: String { rawValue }

    /// Natural loop length in seconds.
    var duration: Double {
        switch self {
        case .turntable: 8
        case .heroTilt: 6
        case .float: 4
        case .openReveal: 5
        case .flipIn, .slideUp: 3
        case .still: 3
        }
    }

    /// Pose at `time` seconds. `base` carries the user's static tilt so the
    /// presets play around the framing they chose.
    func pose(at time: Double, base: MockupPose = MockupPose()) -> MockupPose {
        let t = duration > 0 ? (time.truncatingRemainder(dividingBy: duration)) / duration : 0
        var pose = base
        switch self {
        case .turntable:
            pose.yaw += t * 2 * .pi
        case .heroTilt:
            pose.yaw += 0.5 * sin(t * 2 * .pi)
            pose.pitch += 0.12
        case .float:
            pose.lift += 0.03 * sin(t * 2 * .pi)
            pose.yaw += -0.35 + 0.06 * sin(t * 2 * .pi)
            pose.pitch += 0.1
            pose.roll += 0.04 * cos(t * 2 * .pi)
        case .openReveal:
            // Hold closed, open with ease, turn to face the camera, hold.
            let open = Self.ease(Self.segment(t, from: 0.1, to: 0.6))
            let turn = Self.ease(Self.segment(t, from: 0.25, to: 0.85))
            pose.open = open
            pose.yaw += (1 - turn) * -0.9
            pose.pitch += 0.15 * (1 - turn)
            pose.scale *= 0.88 + 0.12 * turn
        case .flipIn:
            let k = Self.easeOutBack(Self.segment(t, from: 0, to: 0.7))
            pose.yaw += (1 - k) * .pi
            pose.scale *= 0.7 + 0.3 * min(k, 1)
        case .slideUp:
            let k = Self.ease(Self.segment(t, from: 0, to: 0.65))
            pose.lift += (1 - k) * -1.2
            pose.pitch += (1 - k) * 0.4
        case .still:
            break
        }
        return pose
    }

    private static func segment(_ t: Double, from start: Double, to end: Double) -> Double {
        min(max((t - start) / (end - start), 0), 1)
    }

    static func ease(_ t: Double) -> Double { t * t * (3 - 2 * t) }

    static func easeOutBack(_ t: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
    }
}
