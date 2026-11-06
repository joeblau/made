import AppKit
import Testing
@testable import Pilot

@MainActor
@Suite("Native analytics presentation", .serialized)
struct AgenticUseNativePresentationTests {
    @Test("Numeric text rolls changed digits, retains punctuation, and retargets from its visible glyphs")
    func numericTextTransitions() throws {
        let field = AgenticUseNumericTextField(labelWithString: "")
        field.font = CockpitTypography.font(.metric)
        field.prepareTransition(to: "$188,919.28", countsDown: false)
        field.prepareTransition(to: "$288,919.38", countsDown: false)
        #expect(field.stringValue == "$288,919.38", "Accessibility exposes the exact new amount throughout the transition")
        field.setTransitionProgress(0.5)
        #expect(field.isTransitioning)
        let stable = field.renderedGlyphs.filter { $0.key == "integer:0" || $0.text == "$" || $0.text == "," || $0.text == "." }
        #expect(stable.count == 4)
        #expect(stable.allSatisfy { $0.y == 0 && $0.opacity == 1 })
        #expect(field.renderedGlyphs.contains { $0.key == "integer:5" && $0.text == "2" && $0.y > 0 && $0.opacity == 0.5 })
        #expect(field.renderedGlyphs.contains { $0.key == "integer:5" && $0.text == "1" && $0.y < 0 && $0.opacity == 0.5 })
        let visible = field.renderedGlyphs.filter { $0.opacity > 0 }
        field.prepareTransition(to: "$9.28", countsDown: true)
        #expect(visible.allSatisfy { field.renderedGlyphs.contains($0) }, "An interrupted roll starts from the currently visible digits")
        field.setTransitionProgress(1)
        #expect(!field.isTransitioning)
        #expect(field.renderedGlyphs.map(\.text).joined() == "$9.28")
        #expect(field.renderedGlyphs.allSatisfy { $0.y == 0 && $0.opacity == 1 })
        field.prepareTransition(to: "$9.28", countsDown: true)
        #expect(!field.isTransitioning)
    }

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

    @Test("Provider popovers fit every visible row without scrolling and keep long lists accessible", arguments: [0.85, 1.0, 2.0])
    func providerPopoverFits(zoom: Double) throws {
        let oldZoom = CockpitUIZoomController.shared.factor
        CockpitUIZoomController.shared.factor = zoom
        defer { CockpitUIZoomController.shared.factor = oldZoom }
        for count in [10, 60] {
            let models = snapshot(count: count).modelTotals.filter { $0.provider == .claude }
            let controller = AgenticUseProviderModelsController(provider: .claude, models: models,
                                                                maximumSize: NSSize(width: 900, height: 600))
            let root = controller.view
            #expect(!descendants(root).contains { $0 is NSScrollView || $0 is NSScroller })
            #expect(root.bounds.height <= 600)
            let table = try #require(descendants(root).compactMap { $0 as? NSTableView }.first)
            let next = descendants(root).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Next models" }
            var seen = Set<String>()
            repeat {
                root.layoutSubtreeIfNeeded()
                for row in 0..<table.numberOfRows {
                    #expect(table.bounds.contains(table.rect(ofRow: row)))
                    let cell = try #require(table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)
                    cell.layoutSubtreeIfNeeded()
                    seen.insert(try #require(cell.textField).stringValue)
                    for label in cell.subviews.compactMap({ $0 as? NSTextField }) {
                        #expect(cell.bounds.contains(label.frame))
                        if label.alignment == .right {
                            let font = try #require(label.font)
                            #expect(label.bounds.width >= (label.stringValue as NSString).size(withAttributes: [.font: font]).width)
                        }
                    }
                }
                guard next?.isEnabled == true else { break }
                next?.performClick(nil)
            } while seen.count < models.count
            #expect(seen.count == models.count)
            if count == 10 { #expect(next == nil) }
        }
    }

    @Test("Token Flow fits its card at narrow widths and all supported zoom levels", arguments: [0.85, 1.0, 2.0])
    func tokenFlowHasNoNestedScrolling(zoom: Double) throws {
        let oldZoom = CockpitUIZoomController.shared.factor
        CockpitUIZoomController.shared.factor = zoom
        defer { CockpitUIZoomController.shared.factor = oldZoom }
        let panel = AgenticUseTokenFlowPanel(snapshot: snapshot(count: 150))
        for width in [320.0, 520.0, 650.0, 1200.0] {
            panel.frame = NSRect(x: 0, y: 0, width: width, height: panel.preferredHeight(for: width))
            panel.needsLayout = true
            panel.layoutSubtreeIfNeeded()
            #expect(!descendants(panel).contains { $0 is NSScrollView || $0 is NSScroller })
            let diagram = try #require(descendants(panel).first {
                $0.accessibilityLabel() == "Token flow from provider through model to token type"
            })
            let nodes = diagram.subviews.compactMap { $0 as? NSButton }
            #expect(!nodes.isEmpty)
            #expect(panel.bounds.contains(diagram.frame))
            #expect(nodes.allSatisfy { diagram.bounds.contains($0.frame) })
            #expect(nodes.allSatisfy { $0.frame.width > 0 && $0.frame.height > 0 })
        }
    }

    @Test("Filter changes morph existing chart data and numbers without wiping or replacing the dashboard")
    func chartSelectionsTransition() async throws {
        let dashboard = AgenticUseDashboard(snapshot: snapshot(), pricingStatus: "Fixture")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 960),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = dashboard
        window.orderFront(nil)
        defer { window.close() }
        dashboard.layoutSubtreeIfNeeded()
        let chart = try #require(descendants(dashboard).compactMap { $0 as? AgenticUseDailyChartPanel }.first)
        let plot = try #require(descendants(chart).compactMap { $0 as? AgenticUseStackedPlot }.first)
        let diagram = try #require(descendants(dashboard).compactMap { $0 as? AgenticUseTokenFlowDiagram }.first)
        let metric = try #require(descendants(chart).compactMap { $0 as? NSSegmentedControl }.first)
        let provider = try #require(descendants(chart).compactMap { $0 as? NSButton }.first { $0.title.hasPrefix("Claude ") })
        let tokens = try #require(descendants(dashboard).compactMap { $0 as? AgenticUseKPICard }.first {
            $0.titleLabel.stringValue == "Processed Tokens"
        })
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let original = plot.renderedBands
        let originalMaximum = plot.renderedMaximum
        let flowGeometry = diagram.geometry
        metric.selectedSegment = 1
        #expect(NSApp.sendAction(try #require(metric.action), to: metric.target, from: metric))
        if !reduced {
            #expect(plot.transition.isRunning)
            #expect(plot.renderedBands == original, "The first frame must retain the previous chart")
            plot.transition.advance(to: 0.5)
            let halfway = plot.renderedBands
            #expect(halfway != original || plot.renderedMaximum != originalMaximum)
            metric.selectedSegment = 2
            #expect(NSApp.sendAction(try #require(metric.action), to: metric.target, from: metric))
            #expect(plot.renderedBands == halfway, "Rapid filter changes continue from the visible shape")
        }
        plot.transition.finish()
        #expect(!diagram.transition.isRunning && diagram.geometry == flowGeometry,
                "Changing the daily metric must not replay the unchanged token-flow diagram")
        provider.performClick(nil)
        plot.transition.finish()
        provider.performClick(nil)
        plot.transition.finish()
        let previousTokens = tokens.displayedNumber
        dashboard.update(snapshot: snapshot(range: .week, count: 26), pricingStatus: "Fixture")
        dashboard.layoutSubtreeIfNeeded()
        if !reduced {
            #expect(tokens.transition.isRunning && tokens.displayedNumber == previousTokens)
            tokens.transition.advance(to: 0.5)
            #expect(tokens.displayedNumber > previousTokens)
            #expect(tokens.displayedNumber < Double(dashboard.snapshot.stats.processedTokens))
            let halfway = tokens.displayedNumber
            dashboard.update(snapshot: snapshot(range: .day, count: 40), pricingStatus: "Fixture")
            dashboard.layoutSubtreeIfNeeded()
            #expect(tokens.displayedNumber == halfway, "Numbers also retarget from their displayed values")
        }
        window.setContentSize(NSSize(width: 900, height: 960))
        dashboard.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(550))
        #expect(!plot.transition.isRunning && !diagram.transition.isRunning && !tokens.transition.isRunning)
        #expect(tokens.displayedNumber == Double(dashboard.snapshot.stats.processedTokens))
        #expect(descendants(chart).contains { $0 === metric } && descendants(chart).contains { $0 === provider })
        #expect(descendants(dashboard).allSatisfy { $0.layer?.mask == nil }, "Data transitions never hide the page behind a reveal mask")
        #expect(plot.alphaValue == 1 && diagram.alphaValue == 1 && !dashboard.isHidden)
        dashboard.update(snapshot: dashboard.snapshot, pricingStatus: "Updated pricing text")
        #expect(!plot.transition.isRunning && !diagram.transition.isRunning && !tokens.transition.isRunning)
    }

    @Test("Compact metrics remain readable and model columns fit whenever the dashboard splits",
           arguments: [0.85, 1.0, 2.0], [NSScroller.Style.legacy, .overlay])
    func dashboardDensity(zoom: Double, style: NSScroller.Style) throws {
        let oldZoom = CockpitUIZoomController.shared.factor
        CockpitUIZoomController.shared.factor = zoom
        defer { CockpitUIZoomController.shared.factor = oldZoom }
        let dashboard = AgenticUseDashboard(snapshot: snapshot(), pricingStatus: "Fixture")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 960),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = dashboard
        defer { window.close() }
        let kpis = try #require(dashboard.subviews.compactMap { $0 as? AgenticUseKPICards }.first)
        let models = try #require(dashboard.subviews.compactMap { $0 as? AgenticUseTopModels }.first)
        let scroll = try #require(models.subviews.compactMap { $0 as? NSScrollView }.first)
        let table = try #require(scroll.documentView as? NSTableView)
        scroll.scrollerStyle = style
        for width in [650.0, 1080.0, 1200.0, 1440.0] {
            if width == 1440 { dashboard.update(snapshot: snapshot(count: 150), pricingStatus: "Updated fixture") }
            window.setContentSize(NSSize(width: width, height: dashboard.contentHeight(for: width)))
            dashboard.needsLayout = true
            dashboard.layoutSubtreeIfNeeded()
            dashboard.layoutSubtreeIfNeeded()
            for card in kpis.subviews {
                #expect(abs(card.frame.height - 96 * zoom) < 0.01)
                let value = try #require(card.subviews.compactMap { $0 as? NSTextField }.first { $0.font?.pointSize == 22 * zoom })
                let font = try #require(value.font)
                let textWidth = (value.stringValue as NSString).size(withAttributes: [.font: font]).width
                #expect(value.bounds.width >= textWidth + 4)
                for label in card.subviews.compactMap({ $0 as? NSTextField }) {
                    #expect(card.bounds.contains(label.frame))
                }
            }
            if models.frame.minX > 8 {
                let columns = table.tableColumns.reduce(CGFloat(0)) { $0 + $1.width }
                    + CGFloat(table.numberOfColumns) * table.intercellSpacing.width
                #expect(columns <= scroll.contentSize.width + 1)
                #expect(table.frame.width <= scroll.contentSize.width + 1)
                // Overlay scrollbars may still be fading from the previous
                // viewport. Their scrollable range must already be gone.
                if style == .legacy { #expect(scroll.horizontalScroller?.isHidden != false) }
            }
        }
    }

    @Test("Provider updates retain controls and semantic text colors")
    func providerUpdateRetainsControls() throws {
        let panel = AgenticUseProviderBreakdown(snapshot: snapshot())
        let before = panel.subviews.compactMap { $0 as? NSButton }
        #expect(before.count == 2)
        panel.update(snapshot: snapshot(count: 14))
        let after = panel.subviews.compactMap { $0 as? NSButton }
        #expect(after.count == before.count)
        #expect(before.allSatisfy { button in after.contains { $0 === button } })
        #expect(after.allSatisfy { $0.contentTintColor == .labelColor })
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
