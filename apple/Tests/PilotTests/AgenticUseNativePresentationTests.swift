import AppKit
import Testing
@testable import Pilot

@MainActor
@Suite("Native analytics presentation", .serialized)
struct AgenticUseNativePresentationTests {
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func snapshot(range: AgenticUseRange = .month, count: Int = 13) -> AgenticUseSnapshot {
        let now = Date(timeIntervalSince1970: 1_792_756_800)
        let records = (0..<count).map { index in
            AgenticUsageRecord(
                provider: index.isMultiple(of: 2) ? .claude : .codex,
                dedupKey: "native-\(index)", model: "native-model-\(index)",
                timestamp: now.addingTimeInterval(-Double(index % 5) * 3_600),
                inputTokens: 1_000 + index, cacheWriteTokens: 100,
                cacheWrite1hTokens: 0, cacheReadTokens: 4_000, outputTokens: 200,
                thinkingTokens: nil, isFast: false, nativeCostUSD: Double(index + 1)
            )
        }
        return AgenticUsageStore.makeSnapshot(records: records, range: range, now: now, calendar: Calendar(identifier: .gregorian))
    }

    @Test("Expanding models survives a snapshot update and keeps the native table")
    func modelExpansionPersists() throws {
        _ = NSApplication.shared
        let panel = AgenticUseTopModels(snapshot: snapshot())
        panel.frame = NSRect(x: 0, y: 0, width: 650, height: 500)
        panel.layoutSubtreeIfNeeded()
        let table = try #require(descendants(panel).compactMap { $0 as? NSTableView }.first)
        let button = try #require(descendants(panel).compactMap { $0 as? NSButton }.first { $0.title.hasPrefix("View All") })
        #expect(table.numberOfRows == 10)
        button.performClick(nil)
        #expect(table.numberOfRows == 13)
        panel.update(snapshot: snapshot(count: 14))
        #expect(table.numberOfRows == 14)
        #expect(descendants(panel).compactMap { $0 as? NSTableView }.first === table)
        button.performClick(nil)
        #expect(table.numberOfRows == 10)
    }

    @Test("Provider isolation retains native controls and keyboard chart data")
    func providerIsolationPreservesControls() throws {
        _ = NSApplication.shared
        let panel = AgenticUseDailyChartPanel(snapshot: snapshot())
        panel.frame = NSRect(x: 0, y: 0, width: 900, height: panel.preferredHeight(for: 900))
        panel.layoutSubtreeIfNeeded()
        let legend = try #require(descendants(panel).compactMap { $0 as? NSButton }.first { $0.title.hasPrefix("Claude ") })
        let plot = try #require(descendants(panel).first { $0.accessibilityHelp()?.contains("Use Left and Right Arrow") == true })
        let right = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                                 isARepeat: false, keyCode: 124))
        plot.keyDown(with: right)
        #expect((plot.accessibilityValue() as? String)?.contains("Codex:") == true)
        legend.performClick(nil)
        #expect(descendants(panel).contains { $0 === legend })
        plot.keyDown(with: right)
        #expect((plot.accessibilityValue() as? String)?.contains("Claude:") == true)
        #expect((plot.accessibilityValue() as? String)?.contains("Codex:") == false)
        legend.performClick(nil)
        plot.keyDown(with: right)
        #expect((plot.accessibilityValue() as? String)?.contains("Codex:") == true)
    }

    @Test("Daily range hides weekly grouping and retains every native data panel")
    func rangeAndNativeHierarchy() throws {
        _ = NSApplication.shared
        let dashboard = AgenticUseDashboard(snapshot: snapshot(), pricingStatus: "Fixture pricing")
        dashboard.frame = NSRect(x: 0, y: 0, width: 650, height: dashboard.contentHeight(for: 650))
        dashboard.layoutSubtreeIfNeeded()
        let grouping = try #require(descendants(dashboard).compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains("Weekly") })
        #expect(!grouping.isHidden)
        dashboard.update(snapshot: snapshot(range: .day), pricingStatus: "Fixture pricing")
        dashboard.layoutSubtreeIfNeeded()
        #expect(grouping.isHidden)
        #expect(descendants(dashboard).contains { $0 is NSTableView })
        // AppKit itself uses _NSCoreHostingView for native Tahoe controls.
        // Reject app-owned SwiftUI hosting, not those implementation details.
        #expect(!descendants(dashboard).contains { NSStringFromClass(type(of: $0)).contains("NSHostingView") })
        #expect(dashboard.contentHeight(for: 650).isFinite)
    }
}
