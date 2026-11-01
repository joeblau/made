import CoreGraphics
import simd

/// Positions for the 3D runner fleet, in the bundled Mac mini model's native
/// centimetres. Columns run along x, rows step toward the viewer along z, and
/// the GitHub hub floats behind the first row tilted to face the camera.
struct RunnerFleetLayout: Equatable {
    static let columnSpacing: Float = 20
    static let rowSpacing: Float = 31
    static let miniHalfDepth: Float = 6.4
    /// Where a runner's name card hangs from, just in front of its case.
    static let labelDepth: Float = 6.9
    static let hubCenter = SIMD3<Float>(0, 14, -40)
    /// Matches the 3:2 hub card image.
    static let hubSize = SIMD2<Float>(22.5, 15)
    /// The camera's downward pitch; flat cards tilt by the same angle so they face it.
    /// Low enough that the minis' fronts face the viewer, as in a product shot.
    static let pitch: Float = 30 * .pi / 180

    let count: Int
    let columns: Int

    init(count: Int, columns: Int) {
        self.count = max(0, count)
        self.columns = max(1, min(columns, max(count, 1)))
    }

    /// Roughly one column per 200 points of width so names stay readable.
    static func columns(forWidth width: CGFloat) -> Int {
        min(8, max(2, Int(width / 200)))
    }

    var rows: Int { (count + columns - 1) / columns }

    func slot(_ index: Int) -> (column: Int, row: Int) { (index % columns, index / columns) }

    /// Centre of a runner's footprint on the floor.
    func position(_ index: Int) -> SIMD3<Float> {
        let (column, row) = slot(index)
        return SIMD3(columnX(column), 0, Float(row) * Self.rowSpacing)
    }

    /// Floor extent from behind the hub to the labels in front of the last row.
    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        let halfWidth = max(Self.hubSize.x / 2, Float(columns) * Self.columnSpacing / 2)
        let lastRow = Float(max(rows - 1, 0)) * Self.rowSpacing
        return (SIMD3(-halfWidth, 0, Self.hubCenter.z - 6), SIMD3(halfWidth, 0, lastRow + Self.labelDepth + 10))
    }

    /// The hub's lower edge, where every cable leaves it.
    static var hubBottom: SIMD3<Float> {
        let half = hubSize.y / 2
        return hubCenter + SIMD3(0, -half * cos(pitch), half * sin(pitch))
    }

    /// Cable from the hub to the back of a runner. First-row cables arc
    /// straight in; later rows drop to a floor lane in the gutter left of their
    /// column, run forward, and turn in just behind their runner, clear of the
    /// name card in front of the previous row.
    func cable(to index: Int) -> [SIMD3<Float>] {
        let (column, row) = slot(index)
        let x = columnX(column)
        // Ordering starts by column so cables leave the hub without crossing.
        let key = Float(column * rows + row) + 0.5
        let bottom = Self.hubBottom
        let start = SIMD3(Self.hubSize.x * 0.6 * (key / Float(columns * rows) - 0.5), bottom.y + 0.4, bottom.z - 0.6)
        let drop = start + SIMD3(0, -7, 6)
        let back = Float(row) * Self.rowSpacing - Self.miniHalfDepth
        if row == 0 {
            return Self.bezier(start, drop, SIMD3(x, 2.4, back - 16), SIMD3(x, 2.4, back))
        }
        let lane = x - Self.columnSpacing / 2 + laneOffset(row)
        let landing = SIMD3<Float>(lane, 0.25, -Self.miniHalfDepth - 10)
        let cross = back - 2.5
        let aerial = Self.bezier(start, drop, SIMD3(lane, 0.25, landing.z - 14), landing)
        let floor = Self.rounded([landing, SIMD3(lane, 0.25, cross), SIMD3(x, 0.25, cross), SIMD3(x, 1.6, back)])
        return aerial + floor.dropFirst()
    }

    /// The hub's four corners, for framing.
    var hubCorners: [SIMD3<Float>] {
        let half = Self.hubSize / 2
        let up = SIMD3<Float>(0, cos(Self.pitch), -sin(Self.pitch))
        return [-1, 1].flatMap { x in [-1, 1].map { y in
            Self.hubCenter + SIMD3(x * half.x, 0, 0) + up * (y * half.y)
        } }
    }

    /// A floor target and camera distance that fit `points` inside `margin` of
    /// the viewport for a camera at `pitch` with a vertical field of view in
    /// degrees. `alignTop` pins the content to the top edge instead of centring it.
    static func framing(
        _ points: [SIMD3<Float>], aspect: Float, fieldOfView: Float, margin: Float = 0.9, alignTop: Bool = false
    ) -> (target: SIMD3<Float>, distance: Float) {
        guard !points.isEmpty, aspect > 0 else { return (.zero, 200) }
        let tanHalf = tan(fieldOfView * .pi / 360)
        let back = SIMD3<Float>(0, sin(pitch), cos(pitch))
        let up = SIMD3<Float>(0, cos(pitch), -sin(pitch))
        func extent(_ target: SIMD3<Float>, _ distance: Float) -> (x: Float, low: Float, high: Float, depth: Float)? {
            let camera = target + back * distance
            var x: Float = 0, low = Float.infinity, high = -Float.infinity, depth: Float = 0
            for point in points {
                let offset = point - camera
                let z = -simd_dot(offset, back)
                guard z > 1 else { return nil }
                x = max(x, abs(offset.x) / (z * tanHalf * aspect))
                let y = simd_dot(offset, up) / (z * tanHalf)
                low = min(low, y)
                high = max(high, y)
                depth += z / Float(points.count)
            }
            return (x, low, high, depth)
        }
        let xs = points.map(\.x), zs = points.map(\.z)
        var target = SIMD3<Float>((xs.min()! + xs.max()!) / 2, 0, (zs.min()! + zs.max()!) / 2)
        func fittingDistance() -> Float {
            var near: Float = 10, far: Float = 10_000
            for _ in 0..<40 {
                let mid = (near + far) / 2
                if let e = extent(target, mid), max(e.x, e.high, -e.low) <= margin { far = mid } else { near = mid }
            }
            return far
        }
        for _ in 0..<5 {
            guard let e = extent(target, fittingDistance()) else { break }
            // Moving the target along z shifts every point along screen y.
            let shift = alignTop ? margin - e.high : -(e.low + e.high) / 2
            target.z += shift * e.depth * tanHalf / sin(pitch)
        }
        let distance = fittingDistance()
        return (target, distance)
    }

    private func columnX(_ column: Int) -> Float {
        (Float(column) - Float(columns - 1) / 2) * Self.columnSpacing
    }

    /// Spreads a column's floor lanes across the gutter so they stay distinct.
    private func laneOffset(_ row: Int) -> Float {
        rows > 2 ? (Float(row - 1) / Float(rows - 2) - 0.5) * (Self.columnSpacing - 12.7) * 0.6 : 0
    }

    static func bezier(
        _ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>, _ p3: SIMD3<Float>, steps: Int = 24
    ) -> [SIMD3<Float>] {
        (0...steps).map { step in
            let t = Float(step) / Float(steps), u = 1 - t
            return u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3
        }
    }

    /// Replaces each interior corner with a short curve.
    static func rounded(_ points: [SIMD3<Float>], radius: Float = 3, steps: Int = 6) -> [SIMD3<Float>] {
        guard points.count > 2 else { return points }
        var result = [points[0]]
        for index in 1..<(points.count - 1) {
            let previous = points[index - 1], corner = points[index], next = points[index + 1]
            let inLength = simd_distance(previous, corner), outLength = simd_distance(corner, next)
            let r = min(radius, inLength / 2, outLength / 2)
            guard r > 0.001 else { continue }
            let a = corner + (previous - corner) / inLength * r
            let b = corner + (next - corner) / outLength * r
            for step in 0...steps {
                let t = Float(step) / Float(steps), u = 1 - t
                append(u * u * a + 2 * u * t * corner + t * t * b)
            }
        }
        append(points[points.count - 1])
        return result

        // Adjacent corners can share an end point; zero-length segments would break tube tangents.
        func append(_ point: SIMD3<Float>) {
            if let last = result.last, simd_distance(last, point) < 0.0001 { return }
            result.append(point)
        }
    }
}
