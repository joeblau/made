import AppKit
import Observation
import Testing
@testable import Pilot

@Suite("Native design and observation", .serialized)
@MainActor
struct AppKitDesignTests {
    @Test("Content transitions keep controls interactive and do not accumulate animations")
    func nativeContentMotion() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try #require(window.contentView)
        var clicks = 0
        let button = CockpitActionButton(title: "Select") { clicks += 1 }
        content.addSubview(button)
        button.frame = NSRect(x: 20, y: 20, width: 100, height: 30)
        CockpitMotion.reveal(content)
        #expect(content.layer?.animation(forKey: CockpitMotion.contentAnimationKey) == nil)
        window.orderFront(nil)
        for _ in 0..<5 { CockpitMotion.reveal(content) }
        #expect(content.alphaValue == 1)
        #expect(content.hitTest(NSPoint(x: 30, y: 30)) === button)
        button.performClick(nil)
        #expect(clicks == 1)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            #expect(content.layer?.animationKeys()?.filter { $0 == CockpitMotion.contentAnimationKey }.count == 1)
        }
        CockpitMotion.reveal(content, animated: false)
        #expect(content.layer?.animation(forKey: CockpitMotion.contentAnimationKey) == nil)
        #expect(content.alphaValue == 1)
    }

    @Observable
    final class Model {
        var value = 0
    }

    private final class Owner {
        let model: Model
        var renderedValues: [Int] = []
        init(model: Model) { self.model = model }
    }

    @Test("Detached observation ignores queued callbacks and reattaches to current state")
    func observationFencesDetachedGeneration() async throws {
        let model = Model()
        let owner = Owner(model: model)
        let observation = CockpitObservation(owner: owner) {
            $0.renderedValues.append($0.model.value)
        }
        observation.start()
        #expect(owner.renderedValues == [0])
        model.value = 1
        observation.stop()
        try await Task.sleep(for: .milliseconds(10))
        #expect(owner.renderedValues == [0])

        observation.start()
        #expect(owner.renderedValues == [0, 1])
        model.value = 2
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while owner.renderedValues.last != 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(owner.renderedValues == [0, 1, 2])
        observation.stop()
    }

    @Test("Observation does not retain its controller owner")
    func observationReleasesOwner() {
        let model = Model()
        var owner: Owner? = Owner(model: model)
        weak let releasedOwner = owner
        let observation = CockpitObservation(owner: owner!) {
            $0.renderedValues.append($0.model.value)
        }
        observation.start()
        owner = nil
        #expect(releasedOwner == nil)
        model.value = 1
        observation.stop()
    }

    @Test("Zoom normalizes stored values and preserves its preference key")
    func zoomPreferences() throws {
        let name = "app.blau.pilot.appkit-design-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(1.29, forKey: "ui.zoom")
        let zoom = CockpitUIZoomController(defaults: defaults)
        #expect(zoom.factor == 1.3)
        zoom.increase()
        #expect(zoom.factor == 1.5)
        #expect(defaults.double(forKey: "ui.zoom") == 1.5)
        zoom.factor = .infinity
        #expect(zoom.factor == 1)
        zoom.decrease()
        #expect(zoom.factor == 0.85)
        zoom.decrease()
        #expect(zoom.factor == 0.85)
        zoom.reset()
        #expect(zoom.factor == UIZoomLadder.default)
        #expect(CockpitTypography.font(size: 12, zoom: 1.5).pointSize == 18)
    }

    @Test("Native segmented controls dispatch typed selection once")
    func segmentedSelection() {
        var selections: [String] = []
        let view = PilotSegmentedControl(
            "Inspector", selection: "files", options: ["files", "actions"],
            title: { $0.capitalized }, onSelectionChanged: { selections.append($0) }
        )
        #expect(view.control.selectedSegment == 0)
        view.control.selectedSegment = 1
        view.control.sendAction(view.control.action, to: view.control.target)
        #expect(view.selection == "actions")
        #expect(selections == ["actions"])
        view.selection = "files"
        #expect(view.control.selectedSegment == 0)
        #expect(selections.count == 1)
        #expect(view.control.accessibilityLabel() == "Inspector")
    }

    @Test("Appearance reporting follows connection and window override")
    func appearanceReporting() {
        var values: [Bool] = []
        let reporter = AppearanceReporter { values.append($0) }
        reporter.appearance = NSAppearance(named: .darkAqua)
        reporter.isConnected = true
        #expect(values.last == true)
        reporter.report()
        #expect(values.count == 1)
        reporter.isConnected = false
        reporter.appearance = NSAppearance(named: .aqua)
        reporter.report()
        #expect(values.count == 1)
        reporter.isConnected = true
        #expect(values == [true, false])
    }

    @Test("Tab rows hide idle scrollbars and retain full-height controls when overflowing",
           arguments: [NSScroller.Style.legacy, .overlay])
    func tabStripOverflow(style: NSScroller.Style) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1800, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let buttons = (1...8).map { CockpitActionButton(title: "Development source \($0)", action: {}) }
        let stack = CockpitUI.hStack(buttons)
        let strip = CockpitTabStrip(stack: stack)
        strip.scrollView.scrollerStyle = style
        let root = try #require(window.contentView)
        root.addSubview(strip)
        strip.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            strip.topAnchor.constraint(equalTo: root.topAnchor),
        ])
        for width in [1800.0, 320.0, 1800.0] {
            window.setContentSize(NSSize(width: width, height: 200))
            strip.needsLayout = true
            root.layoutSubtreeIfNeeded()
            root.layoutSubtreeIfNeeded()
            let scroll = strip.scrollView
            let document = try #require(scroll.documentView)
            let fits = width == 1800
            #expect((document.bounds.width <= scroll.contentSize.width + 1) == fits)
            #expect(scroll.contentSize.height >= document.bounds.height - 1,
                    "A legacy scrollbar must not take height away from the tab controls")
            if fits { #expect(scroll.horizontalScroller?.isHidden == true) }
            for button in buttons {
                let rect = button.convert(button.bounds, to: document)
                #expect(rect.minY >= 0 && rect.maxY <= scroll.contentSize.height + 1)
            }
            let last = try #require(buttons.last)
            last.scrollToVisible(last.bounds)
            let lastRect = last.convert(last.bounds, to: document)
            #expect(document.visibleRect.intersects(lastRect), "Overflowed actions must remain reachable")
        }
    }

    @Test("Pane title and status share one line, and narrow panes preserve their actions",
           arguments: [0.85, 1.0, 2.0])
    func compactPaneHeader(zoom: Double) throws {
        let previousZoom = CockpitUIZoomController.shared.factor
        CockpitUIZoomController.shared.factor = zoom
        defer { CockpitUIZoomController.shared.factor = previousZoom }
        let pane = Pane(kind: .terminal)
        let tab = CockpitPaneTab(pane: pane, payload: WorkspacePaneDragPayload(
            paneID: pane.id, sourceWorkspaceID: UUID(), projectID: UUID(), sourceSurface: .main))
        tab.updateStatus(agentName: "Claude", isDirty: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(tab)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let title = try #require(descendants(tab).first { $0.accessibilityIdentifier() == "pane.title" })
        let status = try #require(descendants(tab).first { $0.accessibilityIdentifier() == "pane.status" })
        var closed = 0, hidden = 0
        tab.onClose = { closed += 1 }
        tab.onHide = { hidden += 1 }
        for width in [600.0, 160.0, 600.0] {
            tab.frame = NSRect(x: 0, y: 0, width: width, height: CockpitPaneTab.preferredHeight)
            tab.needsLayout = true
            tab.layoutSubtreeIfNeeded()
            tab.layoutSubtreeIfNeeded()
            let titleRect = title.convert(title.bounds, to: tab)
            #expect(titleRect.height > 0 && titleRect.width > 20)
            #expect(titleRect.minY >= 0 && titleRect.maxY <= tab.bounds.height)
            #expect(status.isHidden == (width == 160))
            if !status.isHidden {
                #expect(abs(status.convert(status.bounds, to: tab).midY - titleRect.midY) <= 1)
            }
            for button in descendants(tab).compactMap({ $0 as? NSButton }) {
                #expect(tab.bounds.contains(button.convert(button.bounds, to: tab)))
            }
        }
        #expect(tab.accessibilityHelp()?.contains("Dirty") == true)
        for button in descendants(tab).compactMap({ $0 as? NSButton }) { button.performClick(nil) }
        #expect(closed == 1 && hidden == 1)
    }

    @Test("Opening choices fit narrow and wide panes and dismiss after one selection", arguments: [PaneKind.terminal, .browser, .device, .android])
    func paneModeLayout(kind: PaneKind) throws {
        let pane = Pane(kind: kind)
        pane.isChoosingMode = true
        let picker = CockpitPaneModePicker(pane: pane)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(picker)
        var changes = 0
        picker.onChange = { changes += 1 }
        for width in [600.0, 160.0, 600.0] {
            picker.frame = NSRect(x: 0, y: 0, width: width, height: 300)
            picker.needsLayout = true
            picker.layoutSubtreeIfNeeded()
            let buttons = picker.subviews.compactMap { $0 as? NSButton }
            #expect(buttons.count == 2)
            #expect(buttons.allSatisfy { picker.bounds.contains($0.frame) })
            #expect(!picker.subviews.contains { $0 is NSSegmentedControl || $0 is NSPopUpButton })
        }
        if kind == .browser {
            picker.selectMode(at: 1)
            if ChromiumBrowserCreationPolicy.isCreationEnabled {
                #expect(pane.browserState?.engine == .chromium)
            } else {
                #expect(changes == 0 && pane.isChoosingMode)
                picker.selectMode(at: 0)
                #expect(pane.browserState?.engine == .webKit)
            }
        } else {
            picker.selectMode(at: 1)
            if kind == .terminal { #expect(pane.kind == .agentChat) }
            if kind == .device { #expect(pane.kind == .device) }
            if kind == .android { #expect(pane.androidTarget == .device) }
        }
        #expect(changes == 1 && !pane.isChoosingMode)
        picker.selectMode(at: 0)
        #expect(changes == 1, "A completed opening choice cannot change the running pane")
    }
}
