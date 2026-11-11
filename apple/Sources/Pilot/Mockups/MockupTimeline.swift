import Foundation

/// Rotato-style cubic-Bézier interpolation between two device poses.
enum MockupEasing: String, Codable, CaseIterable, Identifiable {
    case easeInOut = "Ease In & Out"
    case linear = "Linear"
    case easeIn = "Ease In"
    case easeOut = "Ease Out"

    var id: String { rawValue }

    private var controlPoints: (x1: Double, y1: Double, x2: Double, y2: Double) {
        switch self {
        case .easeInOut: (0.25, 0.1, 0.25, 1)
        case .linear: (0, 0, 1, 1)
        case .easeIn: (0.42, 0, 1, 1)
        case .easeOut: (0, 0, 0.58, 1)
        }
    }

    func value(at time: Double) -> Double {
        let target = min(max(time, 0), 1)
        guard self != .linear else { return target }
        let points = controlPoints
        func sample(_ t: Double, _ a: Double, _ b: Double) -> Double {
            let inverse = 1 - t
            return 3 * inverse * inverse * t * a + 3 * inverse * t * t * b + t * t * t
        }
        var parameter = target
        for _ in 0..<8 {
            let error = sample(parameter, points.x1, points.x2) - target
            if abs(error) < 0.000001 { break }
            let inverse = 1 - parameter
            let derivative = 3 * inverse * inverse * points.x1
                + 6 * inverse * parameter * (points.x2 - points.x1)
                + 3 * parameter * parameter * (1 - points.x2)
            guard abs(derivative) > 0.000001 else { break }
            parameter = min(max(parameter - error / derivative, 0), 1)
        }
        return sample(parameter, points.y1, points.y2)
    }
}

struct MockupKeyframe: Codable, Equatable, Identifiable {
    var id = UUID()
    var pose: MockupPose
    /// Seconds from this keyframe to the next; the last value is its end hold.
    var duration: Double
    var easing: MockupEasing = .easeInOut
}

/// Ordered keyframes use cumulative durations, matching Rotato's preset files.
struct MockupTimeline: Codable, Equatable {
    static let minimumDuration = 0.1
    static let maximumKeyframeDuration = 30.0
    /// Total-length cap enforced by every editing operation, so a saved timeline always reloads (#435).
    static let maximumTotalDuration = 120.0
    static let maximumKeyframes = 256
    /// Edits derive durations by subtracting cumulative start times, so a value clamped onto a bound can
    /// land one ulp past it; isValid accepts that rounding so a bound-pinned edit still saves (#435).
    static let durationTolerance = 1e-9

    var keyframes: [MockupKeyframe]

    var duration: Double { keyframes.reduce(0) { $0 + $1.duration } }

    var isValid: Bool {
        let tolerance = Self.durationTolerance
        guard !keyframes.isEmpty, keyframes.count <= Self.maximumKeyframes,
              duration <= Self.maximumTotalDuration + tolerance else { return false }
        return keyframes.allSatisfy {
            $0.duration.isFinite && $0.duration >= Self.minimumDuration - tolerance
                && $0.duration <= Self.maximumKeyframeDuration + tolerance && $0.pose.isFinite
        }
    }

    func startTime(at index: Int) -> Double {
        guard keyframes.indices.contains(index) else { return duration }
        return keyframes[..<index].reduce(0) { $0 + $1.duration }
    }

    func startTime(for id: MockupKeyframe.ID) -> Double? {
        keyframes.firstIndex { $0.id == id }.map(startTime)
    }

    func pose(at time: Double) -> MockupPose {
        guard let first = keyframes.first else { return MockupPose() }
        guard time > 0 else { return first.pose }
        var start = 0.0
        for (index, keyframe) in keyframes.enumerated() {
            let end = start + keyframe.duration
            if time < end, index + 1 < keyframes.count {
                let progress = keyframe.easing.value(at: (time - start) / keyframe.duration)
                return MockupPose.lerp(keyframe.pose, keyframes[index + 1].pose, progress)
            }
            if time < end { return keyframe.pose }
            start = end
        }
        return keyframes[keyframes.count - 1].pose
    }

    @discardableResult
    mutating func addKeyframe(at time: Double, pose: MockupPose) -> MockupKeyframe.ID? {
        if let index = keyframes.indices.first(where: { abs(startTime(at: $0) - time) < 0.001 }) {
            keyframes[index].pose = pose
            return keyframes[index].id
        }
        guard keyframes.count < Self.maximumKeyframes else { return nil }
        if time >= duration {
            // Appending lengthens the timeline, so it may only use what is left of the total cap.
            let remaining = Self.maximumTotalDuration - duration
            guard remaining >= Self.minimumDuration else { return nil }
            let keyframe = MockupKeyframe(pose: pose, duration: min(2, remaining))
            keyframes.append(keyframe)
            return keyframe.id
        }
        var start = 0.0
        for index in keyframes.indices {
            let end = start + keyframes[index].duration
            if time > start, time < end {
                // Splitting keeps the total but must not leave a segment shorter than the minimum.
                guard time - start >= Self.minimumDuration, end - time >= Self.minimumDuration else { return nil }
                let oldDuration = keyframes[index].duration
                let oldEasing = keyframes[index].easing
                keyframes[index].duration = time - start
                let keyframe = MockupKeyframe(pose: pose, duration: oldDuration - keyframes[index].duration, easing: oldEasing)
                keyframes.insert(keyframe, at: index + 1)
                return keyframe.id
            }
            start = end
        }
        return nil
    }

    mutating func updatePose(_ pose: MockupPose, for id: MockupKeyframe.ID) {
        guard let index = keyframes.firstIndex(where: { $0.id == id }) else { return }
        keyframes[index].pose = pose
    }

    mutating func setDuration(_ duration: Double, for id: MockupKeyframe.ID) {
        guard let index = keyframes.firstIndex(where: { $0.id == id }), duration.isFinite else { return }
        let others = self.duration - keyframes[index].duration
        let ceiling = min(Self.maximumKeyframeDuration, Self.maximumTotalDuration - others)
        keyframes[index].duration = max(min(duration, ceiling), Self.minimumDuration)
    }

    mutating func setEasing(_ easing: MockupEasing, for id: MockupKeyframe.ID) {
        guard let index = keyframes.firstIndex(where: { $0.id == id }) else { return }
        keyframes[index].easing = easing
    }

    /// Moves a diamond while keeping its neighbours and the total length fixed.
    mutating func moveKeyframe(_ id: MockupKeyframe.ID, to time: Double) {
        guard let index = keyframes.firstIndex(where: { $0.id == id }), index > 0 else { return }
        let previousStart = startTime(at: index - 1)
        let nextStart = index + 1 < keyframes.count ? startTime(at: index + 1) : duration
        // Both neighbouring segments must stay within the per-keyframe bounds.
        let earliest = max(previousStart + Self.minimumDuration, nextStart - Self.maximumKeyframeDuration)
        let latest = min(nextStart - Self.minimumDuration, previousStart + Self.maximumKeyframeDuration)
        guard earliest <= latest, time.isFinite else { return }
        let destination = min(max(time, earliest), latest)
        keyframes[index - 1].duration = destination - previousStart
        keyframes[index].duration = nextStart - destination
    }

    mutating func removeKeyframe(_ id: MockupKeyframe.ID) {
        guard keyframes.count > 1, let index = keyframes.firstIndex(where: { $0.id == id }) else { return }
        if index > 0 {
            // The merged segment keeps the removed span up to the per-keyframe cap; any excess is dropped.
            keyframes[index - 1].duration = min(
                keyframes[index - 1].duration + keyframes[index].duration, Self.maximumKeyframeDuration
            )
        }
        keyframes.remove(at: index)
    }

    static func preset(_ motion: MockupMotion, base: MockupPose) -> MockupTimeline {
        func frame(_ pose: MockupPose, _ duration: Double, _ easing: MockupEasing = .easeInOut) -> MockupKeyframe {
            MockupKeyframe(pose: pose, duration: duration, easing: easing)
        }
        var turned = base
        turned.yaw += 2 * .pi
        var tilted = base
        tilted.pitch += 0.12
        var right = tilted
        right.yaw += 0.5
        var left = tilted
        left.yaw -= 0.5
        var frames: [MockupKeyframe]
        switch motion {
        case .turntable:
            frames = [frame(base, 6), frame(turned, 2)]
        case .heroTilt:
            frames = [frame(left, 1.5), frame(right, 1.5), frame(left, 1.5), frame(tilted, 1.5)]
        case .float:
            var high = base
            high.lift += 0.03
            high.yaw -= 0.29
            high.pitch += 0.1
            high.roll += 0.04
            var low = high
            low.lift -= 0.06
            frames = [frame(high, 1), frame(low, 1), frame(high, 1), frame(low, 1)]
        case .openReveal:
            var closed = base
            closed.open = 0
            closed.yaw -= 0.9
            closed.pitch += 0.15
            closed.scale *= 0.88
            frames = [frame(closed, 0.5), frame(closed, 2.5), frame(base, 2)]
        case .flipIn:
            var flipped = base
            flipped.yaw += .pi
            flipped.scale *= 0.7
            frames = [frame(flipped, 2.1, .easeOut), frame(base, 0.9)]
        case .slideUp:
            var lowered = base
            lowered.lift -= 1.2
            lowered.pitch += 0.4
            frames = [frame(lowered, 1.95), frame(base, 1.05)]
        case .still, .custom:
            frames = [frame(base, 3)]
        }
        return MockupTimeline(keyframes: frames)
    }
}
