import AppKit
import Testing
@testable import Pilot

@Suite("Workspace sidebar accessories")
@MainActor
struct WorkspaceSidebarAccessoryTests {
    private let bounds = CGRect(x: 0, y: 0, width: 26, height: 26)

    private func endpoints(_ path: NSBezierPath) -> (start: NSPoint, end: NSPoint) {
        var points = [NSPoint](repeating: .zero, count: 3)
        _ = path.element(at: 0, associatedPoints: &points)
        return (points[0], path.currentPoint)
    }

    @Test("Gauge draws y-up so the arc's gap is at the bottom")
    func gaugeIsUnflipped() {
        #expect(!WorkspaceGaugeView(frame: bounds).isFlipped)
    }

    @Test("Full arc runs from bottom-left to bottom-right over the top")
    func fullArcLeavesGapAtBottom() {
        let path = WorkspaceGaugeArc(fraction: 1).path(in: bounds)
        let (start, end) = endpoints(path)
        #expect(start.x < bounds.midX && start.y < bounds.midY, "starts bottom-left in y-up coordinates")
        #expect(end.x > bounds.midX && end.y < bounds.midY, "ends bottom-right in y-up coordinates")
        #expect(path.bounds.maxY > bounds.maxY - 1, "passes over the top")
        #expect(path.bounds.minY > bounds.minY + 2, "leaves the bottom open")
    }

    @Test("Partial progress fills clockwise from the bottom-left end")
    func partialProgressFillsClockwise() {
        let (start, end) = endpoints(WorkspaceGaugeArc(fraction: 1.0 / 3.0).path(in: bounds))
        #expect(start.x < bounds.midX && start.y < bounds.midY)
        // A third of 270° from 225° lands at 135°: upper-left.
        #expect(end.x < bounds.midX && end.y > bounds.midY)
    }

    @Test("Badge caps at 99+ and hides at zero")
    func badgeTextAndVisibility() {
        #expect(WorkspaceOpenTaskBadgeView.displayText(for: 7) == "7")
        #expect(WorkspaceOpenTaskBadgeView.displayText(for: 99) == "99")
        #expect(WorkspaceOpenTaskBadgeView.displayText(for: 100) == "99+")
        let badge = WorkspaceOpenTaskBadgeView(frame: .zero)
        #expect(badge.isHidden)
        badge.count = 1
        #expect(!badge.isHidden && badge.isEnabled)
        #expect(badge.accessibilityLabel() == "1 open task")
        #expect(badge.toolTip == "1 open task")
    }

    @Test("Badge is a circle for one or two digits and a capsule beyond")
    func badgeShape() {
        let badge = WorkspaceOpenTaskBadgeView(frame: .zero)
        badge.count = 42
        #expect(badge.intrinsicContentSize == NSSize(width: WorkspaceOpenTaskBadgeView.diameter, height: WorkspaceOpenTaskBadgeView.diameter))
        badge.count = 500
        #expect(badge.intrinsicContentSize.height == WorkspaceOpenTaskBadgeView.diameter)
        #expect(badge.intrinsicContentSize.width > WorkspaceOpenTaskBadgeView.diameter)
    }

    @Test("Badge still opens tasks when clicked")
    func badgeClickOpens() {
        let badge = WorkspaceOpenTaskBadgeView(frame: .zero)
        badge.count = 3
        var opened = false
        badge.onOpen = { opened = true }
        badge.performClick(nil)
        #expect(opened)
    }
}
