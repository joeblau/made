import AppKit
import Testing
@testable import Pilot

@Suite("Cockpit refresh button")
@MainActor
struct CockpitRefreshButtonTests {
    @Test("Refreshing swaps the glass circle for a spinner in the same slot")
    func refreshingSwapsButtonAndSpinner() {
        let control = CockpitRefreshButton(help: "Refresh pull requests", action: {})
        #expect(!control.isRefreshing)
        #expect(!control.button.isHidden)
        #expect(control.spinner.isHidden)
        #expect(control.button.bezelStyle == .glass)
        #expect(control.button.borderShape == .circle)
        #expect(control.button.imagePosition == .imageOnly)
        #expect(control.button.title.isEmpty)

        control.isRefreshing = true
        #expect(control.button.isHidden)
        #expect(!control.spinner.isHidden)
        #expect(control.spinner.accessibilityLabel() == CockpitRefreshButton.refreshingLabel)

        control.isRefreshing = false
        #expect(!control.button.isHidden)
        #expect(control.spinner.isHidden)
    }

    @Test("The slot keeps a constant square size across refresh states")
    func slotSizeIsConstant() {
        let control = CockpitRefreshButton(help: "Refresh", action: {})
        let side = (CockpitRefreshButton.defaultDiameter * CGFloat(CockpitUIZoomController.shared.factor)).rounded()
        let idle = control.intrinsicContentSize
        #expect(idle == NSSize(width: side, height: side))
        control.isRefreshing = true
        #expect(control.intrinsicContentSize == idle)
        control.isRefreshing = false
        #expect(control.intrinsicContentSize == idle)

        let fixed = CockpitRefreshButton(help: "Refresh", diameter: 32, scalesWithZoom: false, action: {})
        #expect(fixed.intrinsicContentSize == NSSize(width: 32, height: 32))
    }

    @Test("Labels and tooltips pass through to the inner button")
    func labelsPassThrough() {
        let control = CockpitRefreshButton(help: "Refresh containers", action: {})
        #expect(control.button.toolTip == "Refresh containers")
        #expect(control.button.accessibilityLabel() == "Refresh containers")
        control.help = "Refresh usage"
        #expect(control.toolTip == "Refresh usage")
        #expect(control.button.accessibilityLabel() == "Refresh usage")
        control.isRefreshing = true
        // Existing lookups by label/tooltip still find the (hidden) button.
        #expect(control.button.toolTip == "Refresh usage")
    }

    @Test("Clicking performs the action only while idle and enabled")
    func clickPerformsActionWhenIdle() {
        let counter = RefreshCounter()
        let control = CockpitRefreshButton(help: "Refresh", action: { counter.calls += 1 })
        control.button.performClick(nil)
        #expect(counter.calls == 1)
        control.isEnabled = false
        #expect(!control.button.isEnabled)
        control.button.performClick(nil)
        #expect(counter.calls == 1)
        control.isEnabled = true
        control.isRefreshing = true
        control.button.performClick(nil)
        #expect(counter.calls == 1)
    }
}

@MainActor
private final class RefreshCounter {
    var calls = 0
}
