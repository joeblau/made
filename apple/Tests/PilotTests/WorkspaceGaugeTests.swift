import AppKit
import Testing
@testable import Pilot

@Suite("Workspace sidebar gauge")
struct WorkspaceGaugeTests {
    private let bounds = CGRect(x: 0, y: 0, width: 26, height: 26)

    @Test("Zero progress has no detached marker")
    func zeroProgressIsAnEmptyPath() {
        #expect(WorkspaceGaugeArc(fraction: 0).path(in: bounds).isEmpty)
        #expect(WorkspaceGaugeArc(fraction: -1).path(in: bounds).isEmpty)
    }

    @Test("Positive progress draws an arc")
    func positiveProgressDrawsAnArc() {
        #expect(!WorkspaceGaugeArc(fraction: 1.0 / 3.0).path(in: bounds).isEmpty)
        #expect(!WorkspaceGaugeArc(fraction: 1).path(in: bounds).isEmpty)
    }

    @Test("Progress is exposed to SwiftUI's animation engine")
    func progressIsAnimatable() {
        var arc = WorkspaceGaugeArc(fraction: 0)
        arc.animatableData = 0.5
        #expect(arc.fraction == 0.5)
    }
}
