import Foundation
import simd
import Testing
@testable import Pilot

@Suite("3D runner fleet layout and model")
struct RunnerFleetTests {
    @Test("Columns follow the view width within readable bounds")
    func columnsForWidth() {
        #expect(RunnerFleetLayout.columns(forWidth: 0) == 2)
        #expect(RunnerFleetLayout.columns(forWidth: 1_200) == 6)
        #expect(RunnerFleetLayout.columns(forWidth: 5_000) == 8)
        #expect(RunnerFleetLayout(count: 3, columns: 6).columns == 3)
        #expect(RunnerFleetLayout(count: 0, columns: 6).rows == 0)
    }

    @Test("Runners fill rows left to right and step toward the viewer")
    func positions() {
        let layout = RunnerFleetLayout(count: 14, columns: 6)
        #expect(layout.rows == 3)
        #expect(layout.slot(13) == (column: 1, row: 2))
        #expect(layout.position(0).x == -layout.position(5).x)
        #expect(layout.position(6).z == RunnerFleetLayout.rowSpacing)
        #expect(layout.position(0).z == layout.position(5).z)
    }

    @Test("Every cable leaves the hub and ends at the back of its runner", arguments: [1, 6, 7, 34])
    func cablesConnectHubToRunners(count: Int) throws {
        let layout = RunnerFleetLayout(count: count, columns: 6)
        let hub = RunnerFleetLayout.hubBottom
        for index in 0..<count {
            let cable = layout.cable(to: index)
            let first = try #require(cable.first), last = try #require(cable.last)
            let runner = layout.position(index)
            #expect(abs(first.y - hub.y) < 1 && abs(first.z - hub.z) < 1)
            #expect(abs(first.x) <= RunnerFleetLayout.hubSize.x / 2)
            #expect(abs(last.x - runner.x) < 0.001)
            #expect(abs(last.z - (runner.z - RunnerFleetLayout.miniHalfDepth)) < 0.001)
            // Zero-length segments would give the tube a NaN tangent.
            #expect(zip(cable, cable.dropFirst()).allSatisfy { simd_distance($0, $1) > 0.0001 })
            #expect(cable.allSatisfy { !$0.x.isNaN && !$0.y.isNaN && !$0.z.isNaN })
        }
    }

    @Test("Floor lanes run in the gutter between columns, clear of every runner")
    func lanesAvoidRunners() {
        let layout = RunnerFleetLayout(count: 30, columns: 6)
        let positions = (0..<30).map(layout.position)
        for index in 6..<30 {
            for point in layout.cable(to: index) where point.y < 0.5 {
                for (other, runner) in positions.enumerated() where other != index {
                    let inside = abs(point.x - runner.x) < 6.35 && abs(point.z - runner.z) < RunnerFleetLayout.miniHalfDepth
                    #expect(!inside, "cable \(index) crosses runner \(other)")
                }
            }
        }
    }

    @Test("Rounded corners keep the endpoints and stay near the original polyline")
    func roundedCorners() {
        let points: [SIMD3<Float>] = [[0, 0, 0], [0, 0, 10], [10, 0, 10]]
        let rounded = RunnerFleetLayout.rounded(points)
        #expect(rounded.first == points.first)
        #expect(rounded.last == points.last)
        #expect(rounded.allSatisfy { $0.x >= 0 && $0.x <= 10 && $0.z >= 0 && $0.z <= 10 })
        #expect(!rounded.contains(points[1]))
    }

    @Test("Framing keeps every requested point inside the viewport")
    func framingFits() {
        let layout = RunnerFleetLayout(count: 34, columns: 6)
        let bounds = layout.bounds
        let points = layout.hubCorners + [SIMD3(bounds.min.x, 0, bounds.max.z), SIMD3(bounds.max.x, 0, bounds.max.z)]
        for aspect: Float in [0.8, 1.6, 2.4] {
            let (target, distance) = RunnerFleetLayout.framing(points, aspect: aspect, fieldOfView: 32)
            let pitch = RunnerFleetLayout.pitch
            let back = SIMD3<Float>(0, sin(pitch), cos(pitch)), up = SIMD3<Float>(0, cos(pitch), -sin(pitch))
            let camera = target + back * distance
            let tanHalf = tan(Float(16) * .pi / 180)
            for point in points {
                let offset = point - camera, depth = -simd_dot(offset, back)
                #expect(depth > 0)
                #expect(abs(offset.x / (depth * tanHalf * aspect)) <= 0.91)
                #expect(abs(simd_dot(offset, up) / (depth * tanHalf)) <= 0.91)
            }
        }
    }

    @MainActor
    @Test("The bundled Mac mini loads with exactly one status light at Apple's dimensions")
    func bundledModel() throws {
        let url = try #require(Bundle.main.url(forResource: "MacMini", withExtension: "usdz"))
        let template = try #require(MacMiniModel.load(url))
        let (low, high) = template.body.boundingBox
        #expect(abs((high.x - low.x) - 12.7) < 0.1)
        #expect(abs((high.z - low.z) - 12.7) < 0.1)
        #expect(abs((high.y - low.y) - 5.0) < 0.1)
        let light = template.statusLight.boundingSphere.center
        #expect(light.z > 6.3 && light.y > 1 && light.y < 4)
    }
}
