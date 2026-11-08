import AppKit
import Sparkle
import Testing
@testable import Pilot

/// Settings follows Xcode's layout: a full-height page sidebar, a toolbar row
/// with a back/forward capsule and the page title, and centered grouped cards.
/// Set `MADE_SETTINGS_REVIEW_OUTPUT` to a directory to write review PNGs.
@Suite("Settings layout", .serialized)
@MainActor
struct PilotSettingsLayoutTests {
    @Test("Back and forward walk the pages visited in the window")
    func historyNavigation() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let (controller, window) = fixture.present()
        defer { window.orderOut(nil); window.close() }
        let back = try #require(view("settings.back", in: controller.view) as? NSButton)
        let forward = try #require(view("settings.forward", in: controller.view) as? NSButton)
        let title = try #require(view("settings.pageTitle", in: controller.view) as? NSTextField)
        let sections = try #require(descendants(controller.view).compactMap { $0 as? NSTableView }.first)
        #expect(title.stringValue == "General")
        #expect(!back.isEnabled && !forward.isEnabled)
        #expect(back.keyEquivalent == "[" && forward.keyEquivalent == "]")
        sections.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        sections.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        #expect(title.stringValue == "Usage")
        #expect(back.isEnabled && !forward.isEnabled)
        back.performClick(nil)
        #expect(title.stringValue == "Sidebar")
        #expect(sections.selectedRow == 1)
        #expect(fixture.defaults.string(forKey: SettingsTab.storageKey) == SettingsTab.sidebar)
        #expect(back.isEnabled && forward.isEnabled)
        back.performClick(nil)
        #expect(title.stringValue == "General" && !back.isEnabled)
        forward.performClick(nil)
        #expect(title.stringValue == "Sidebar")
        // Visiting a new page drops the forward history.
        sections.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        #expect(title.stringValue == "Drones")
        #expect(!forward.isEnabled)
        #expect(controller.history == [SettingsTab.general, SettingsTab.sidebar, SettingsTab.drones])
    }

    @Test("Chrome: sidebar under the traffic lights, title in the toolbar row, clickable controls")
    func windowChrome() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let (controller, window) = fixture.present()
        defer { window.orderOut(nil); window.close() }
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titleVisibility == .hidden)
        controller.view.layoutSubtreeIfNeeded()
        let sections = try #require(descendants(controller.view).compactMap { $0 as? NSTableView }.first)
        let sidebar = try #require(sections.enclosingScrollView?.superview as? NSVisualEffectView)
        let sidebarTop = sidebar.convert(sidebar.bounds, to: nil).maxY
        let frameHeight = try #require(window.contentView?.superview).bounds.height
        #expect(abs(sidebarTop - frameHeight) < 0.5, "Sidebar reaches the top edge: \(sidebarTop) vs \(frameHeight) content \(String(describing: window.contentView?.frame)) view \(controller.view.frame) layout \(window.contentLayoutRect) frame \(window.frame)")
        // The page list and the page content both start below the title bar.
        let titlebar = frameHeight - window.contentLayoutRect.height
        let list = try #require(sections.enclosingScrollView).convert(try #require(sections.enclosingScrollView).bounds, to: nil)
        #expect(abs(frameHeight - list.maxY - titlebar) < 0.5, "List top \(list.maxY), title bar \(titlebar)")
        // Only the toolbar row carries the page title; pages have no big heading.
        for index in 0..<4 {
            sections.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            controller.view.layoutSubtreeIfNeeded()
            let headings = descendants(controller.view).compactMap { $0 as? NSTextField }
                .filter { ($0.font?.pointSize ?? 0) > 18 && !$0.isHidden }
            #expect(headings.isEmpty, "Page \(index) still shows a large heading")
        }
        // The back button, page title and search share the traffic lights' line.
        let back = try #require(view("settings.back", in: controller.view) as? NSButton)
        let title = try #require(view("settings.pageTitle", in: controller.view) as? NSTextField)
        let search = try #require(descendants(controller.view).compactMap { $0 as? NSSearchField }.first)
        let backFrame = back.convert(back.bounds, to: nil)
        let close = try #require(window.standardWindowButton(.closeButton))
        let closeFrame = close.convert(close.bounds, to: nil)
        for frame in [title.convert(title.bounds, to: nil), search.convert(search.bounds, to: nil), closeFrame] {
            #expect(abs(frame.midY - backFrame.midY) < 2.5, "\(frame.midY) vs \(backFrame.midY)")
        }
        #expect(backFrame.minX > sidebar.convert(sidebar.bounds, to: nil).maxX)
        // Controls under the transparent title bar still receive clicks.
        let frameView = try #require(window.contentView?.superview)
        for control in [back as NSView, search] {
            let point = frameView.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), from: control)
            let hit = try #require(frameView.hitTest(point))
            #expect(hit === control || hit.isDescendant(of: control), "Hit \(hit) instead of \(control)")
        }
    }

    @Test("Grouped rows have an icon column, card styling and minimum height")
    func groupedRows() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let (controller, window) = fixture.present()
        defer { window.orderOut(nil); window.close() }
        controller.view.layoutSubtreeIfNeeded()
        let groups = descendants(controller.view).compactMap { $0 as? NativeSettingsGroupView }
        #expect(groups.count == 4, "About, Setup, Identity & Keys, Chromium")
        let icons = descendants(controller.view).compactMap { $0 as? NativeSettingsIconView }
        #expect(icons.count >= 12)
        #expect(icons.allSatisfy { $0.image != nil && $0.contentTintColor == .controlAccentColor })
        let iconMinX = Set(icons.map { round($0.convert($0.bounds, to: nil).minX) })
        #expect(iconMinX.count == 1, "Icons share one column: \(iconMinX)")
        for group in groups {
            #expect(group.frame.width <= NativeSettingsUI.pageMaxWidth + 0.5)
        }
        let page = try #require(groups.first?.enclosingScrollView?.documentView)
        let headers = descendants(page).compactMap { $0 as? NSTextField }
            .filter { $0.font?.fontDescriptor.symbolicTraits.contains(.bold) == true }
            .map(\.stringValue)
        #expect(headers == ["About", "Setup", "Identity & Keys", "Chromium"])
    }

    @Test("Review screenshots", .enabled(if: ProcessInfo.processInfo.environment["MADE_SETTINGS_REVIEW_OUTPUT"] != nil))
    func reviewScreenshots() async throws {
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MADE_SETTINGS_REVIEW_OUTPUT"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let fixture = Fixture()
            defer { fixture.cleanUp() }
            let (controller, window) = fixture.present(appearance: appearance, size: NSSize(width: 1000, height: 720))
            defer { window.orderOut(nil); window.close() }
            window.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 720), display: true)
            let sections = try #require(descendants(controller.view).compactMap { $0 as? NSTableView }.first)
            for (index, name) in ["general", "sidebar", "drones", "usage"].enumerated() {
                sections.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                let frame = try #require(window.contentView?.superview)
                frame.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(250))
                frame.displayIfNeeded()
                let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
                frame.effectiveAppearance.performAsCurrentDrawingAppearance { frame.cacheDisplay(in: frame.bounds, to: bitmap) }
                let suffix = appearance == .darkAqua ? "dark" : "light"
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: output.appendingPathComponent("settings-\(name)-\(suffix).png"))
            }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func view(_ identifier: String, in root: NSView) -> NSView? {
        descendants(root).first { $0.identifier?.rawValue == identifier }
    }
}

@MainActor
private final class Fixture {
    let defaultsName = "app.blau.pilot.settings-layout-test.\(UUID().uuidString)"
    let defaults: UserDefaults
    let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

    init() { defaults = UserDefaults(suiteName: defaultsName)! }

    func present(appearance: NSAppearance.Name = .darkAqua, size: NSSize = NSSize(width: 920, height: 680))
        -> (PilotSettingsViewController, NSWindow) {
        let controller = PilotSettingsViewController(
            updater: updater.updater, droneStore: .isolated(), identity: SecureIdentity(role: .pilot, isolated: true),
            onOpenSetup: {}, onOpenMessaging: {}, defaults: defaults,
            sidebarVisibility: SidebarFeatureVisibility(defaults: defaults), runsLiveChecks: false)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Settings"
        window.appearance = NSAppearance(named: appearance)
        controller.preferredContentSize = size
        window.contentViewController = controller
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
        return (controller, window)
    }

    func cleanUp() { defaults.removePersistentDomain(forName: defaultsName) }
}
