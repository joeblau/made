import AppKit
import Observation
import Sparkle
import SwiftData
import Testing
@testable import Pilot

/// Settings > Sidebar hides global modes. Hidden modes lose their sidebar row
/// and View menu toggle, cannot be entered, and are left the moment they hide.
@Suite("Sidebar feature visibility", .serialized)
@MainActor
struct SidebarFeatureVisibilityTests {
    // MARK: - Visibility store

    @Test("Every feature is visible by default and the table is the single source")
    func defaultsToVisible() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let visibility = SidebarFeatureVisibility(defaults: fixture.defaults)
        #expect(visibility.hidden.isEmpty)
        #expect(visibility.visibleFeatures == SidebarFeature.allCases)
        #expect(SidebarFeature.allCases.map(\.title) == ["Notes", "Remote Desktop", "Docker", "Agentic Use", "Runners", "Mock-ups"])
        for feature in SidebarFeature.allCases {
            #expect(SidebarFeature(feature.selection) == feature)
            #expect(NSImage(systemSymbolName: feature.symbolName, accessibilityDescription: nil) != nil)
        }
        #expect(SidebarFeature(.workspace(UUID())) == nil)
    }

    @Test("Hidden features persist as raw values and reload")
    func persistsHiddenFeatures() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let visibility = SidebarFeatureVisibility(defaults: fixture.defaults)
        visibility.setVisible(false, for: .runners)
        visibility.setVisible(false, for: .notes)
        #expect(fixture.defaults.stringArray(forKey: SidebarFeatureVisibility.defaultsKey) == ["notes", "runners"])
        let reloaded = SidebarFeatureVisibility(defaults: fixture.defaults)
        #expect(reloaded.hidden == [.notes, .runners])
        #expect(reloaded.visibleFeatures == [.remoteDesktop, .docker, .agenticUse, .mockups])
        reloaded.setVisible(true, for: .notes)
        reloaded.setVisible(true, for: .runners)
        #expect(fixture.defaults.object(forKey: SidebarFeatureVisibility.defaultsKey) == nil)
    }

    @Test("Unknown and malformed stored values are ignored and preserved")
    func toleratesUnknownValues() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(["hologram", "docker", 42, "retired"], forKey: SidebarFeatureVisibility.defaultsKey)
        let visibility = SidebarFeatureVisibility(defaults: fixture.defaults)
        #expect(visibility.hidden == [.docker])
        visibility.setVisible(false, for: .notes)
        #expect(fixture.defaults.stringArray(forKey: SidebarFeatureVisibility.defaultsKey) == ["notes", "docker", "hologram", "retired"])
        fixture.defaults.set("docker", forKey: SidebarFeatureVisibility.defaultsKey)
        #expect(SidebarFeatureVisibility(defaults: fixture.defaults).hidden.isEmpty)
    }

    @Test("Changes are observable and redundant writes are not")
    func changesAreObservable() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let visibility = SidebarFeatureVisibility(defaults: fixture.defaults)
        var callbacks: [Set<SidebarFeature>] = []
        visibility.onHiddenChange = { callbacks.append($0) }
        let changed = ObservationFlag()
        withObservationTracking { _ = visibility.hidden } onChange: { changed.set() }
        visibility.setVisible(true, for: .docker)
        #expect(!changed.value)
        #expect(callbacks.isEmpty)
        visibility.setVisible(false, for: .docker)
        #expect(changed.value)
        #expect(callbacks == [[.docker]])
    }

    // MARK: - Store modes

    @Test("Hiding the active mode leaves it for the selected workspace")
    func hidingActiveModeExitsIt() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store
        store.addWorkspace()
        let workspace = try #require(store.selectedWorkspace)
        for feature in SidebarFeature.allCases {
            #expect(store.enterMode(feature))
            #expect(store.activeSidebarFeature == feature)
            store.sidebarVisibility.setVisible(false, for: feature)
            #expect(!store.isModeActive(feature))
            #expect(store.isWorkspaceDetailVisible)
            #expect(store.selectedWorkspace?.id == workspace.id)
            store.sidebarVisibility.setVisible(true, for: feature)
            #expect(store.activeSidebarFeature == nil, "Showing a mode never enters it")
        }
    }

    @Test("Hiding an inactive mode leaves the active one alone")
    func hidingInactiveModeKeepsActiveMode() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.store.enterDockerMode()
        fixture.store.sidebarVisibility.setVisible(false, for: .notes)
        #expect(fixture.store.isDockerMode)
    }

    @Test("A persisted active mode that is hidden does not reopen at launch")
    func hiddenModeIsLeftAtLaunch() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "runnersMode")
        fixture.defaults.set(["runners"], forKey: SidebarFeatureVisibility.defaultsKey)
        let relaunched = WorkspaceStore(modelContext: fixture.container.mainContext,
                                        workspaceGroups: WorkspaceGroups(defaults: fixture.defaults), defaults: fixture.defaults)
        #expect(!relaunched.isRunnersMode)
        #expect(!fixture.defaults.bool(forKey: "runnersMode"))
        fixture.defaults.set(true, forKey: "dockerMode")
        let visibleRelaunch = WorkspaceStore(modelContext: fixture.container.mainContext,
                                             workspaceGroups: WorkspaceGroups(defaults: fixture.defaults), defaults: fixture.defaults)
        #expect(visibleRelaunch.isDockerMode)
    }

    @Test("Every programmatic entry point refuses a hidden mode")
    func hiddenModesCannotBeEntered() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store
        let connection = store.addRemoteConnection(host: "studio.local")
        #expect(store.syncSummaries.contains { $0.id == WorkspaceStore.remoteDesktopWorkspaceID })
        for feature in SidebarFeature.allCases { store.sidebarVisibility.setVisible(false, for: feature) }
        for feature in SidebarFeature.allCases {
            #expect(!store.enterMode(feature))
            store.toggleMode(feature)
            #expect(!store.isModeActive(feature))
        }
        store.toggleNotesMode(); store.toggleRemoteDesktopMode(); store.toggleDockerMode()
        store.toggleAgenticUseMode(); store.toggleRunnersMode()
        #expect(store.activeSidebarFeature == nil)
        #expect(!store.selectRemoteDesktopTab(connection.id))
        #expect(!store.syncSummaries.contains { $0.id == WorkspaceStore.remoteDesktopWorkspaceID })
        #expect(DashboardDeepLink.open(try #require(URL(string: "cockpit://runners")), store: store))
        #expect(DashboardDeepLink.open(try #require(URL(string: "cockpit://usage")), store: store))
        #expect(store.activeSidebarFeature == nil)
        let window = fixture.window()
        window.select(.docker)
        #expect(store.activeSidebarFeature == nil)
    }

    // MARK: - Sidebar and menu

    @Test("Sidebar rows follow visibility live")
    func sidebarRowsFollowVisibility() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.store.sidebarVisibility.setVisible(false, for: .agenticUse)
        let sidebar = WorkspaceSidebarViewController(store: fixture.store, defaults: fixture.defaults, isLive: false)
        let table = try #require(descendants(sidebar.view).compactMap { $0 as? NSTableView }.first)
        sidebar.startMonitoring()
        defer { sidebar.stopMonitoring() }
        func modeRows() -> [String] {
            (0..<table.numberOfRows).compactMap {
                sidebar.tableView(table, viewFor: table.tableColumns[0], row: $0)?.accessibilityIdentifier()
            }.filter { $0.hasPrefix("sidebar.mode.") }
        }
        #expect(modeRows() == ["sidebar.mode.notes", "sidebar.mode.remoteDesktop", "sidebar.mode.docker", "sidebar.mode.runners", "sidebar.mode.mockups"])
        fixture.store.sidebarVisibility.setVisible(false, for: .notes)
        #expect(await eventually { modeRows() == ["sidebar.mode.remoteDesktop", "sidebar.mode.docker", "sidebar.mode.runners", "sidebar.mode.mockups"] })
        fixture.store.sidebarVisibility.setVisible(true, for: .agenticUse)
        #expect(await eventually { modeRows().count == 5 && modeRows()[2] == "sidebar.mode.agenticUse" })
        #expect(fixture.store.activeSidebarFeature == nil)
    }

    @Test("View menu hides the toggle and shortcut of a hidden mode")
    func menuHidesHiddenModeCommands() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let oldMainMenu = NSApp.mainMenu
        let oldWindowsMenu = NSApp.windowsMenu
        let oldServicesMenu = NSApp.servicesMenu
        defer { NSApp.mainMenu = oldMainMenu; NSApp.windowsMenu = oldWindowsMenu; NSApp.servicesMenu = oldServicesMenu }
        let menus = CockpitMenuController(windowProvider: { nil }, showMain: {}, toggleExtendo: {}, showSettings: {},
                                           showSetup: {}, checkForUpdates: {}, sidebarVisibility: fixture.store.sidebarVisibility)
        menus.install()
        let view = try #require(NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu)
        func item(_ feature: SidebarFeature) throws -> NSMenuItem {
            try #require(view.items.first { $0.title == "Toggle " + feature.title })
        }
        #expect(try item(.notes).keyEquivalent == "0")
        #expect(try item(.docker).keyEquivalentModifierMask == [.command, .control])
        #expect(try SidebarFeature.allCases.allSatisfy { try !item($0).isHidden })
        fixture.store.sidebarVisibility.setVisible(false, for: .notes)
        fixture.store.sidebarVisibility.setVisible(false, for: .runners)
        #expect(await eventually { (try? item(.notes).isHidden) == true && (try? item(.runners).isHidden) == true })
        #expect(try !item(.docker).isHidden)
        fixture.store.sidebarVisibility.setVisible(true, for: .notes)
        #expect(await eventually { (try? item(.notes).isHidden) == false })
    }

    // MARK: - Settings

    @Test("Sidebar settings list every feature with a switch that persists")
    func settingsSwitchesPersist() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let visibility = fixture.store.sidebarVisibility
        visibility.setVisible(false, for: .runners)
        let controller = SidebarSettingsViewController(visibility: visibility)
        let root = controller.view
        let labels = descendants(root).compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(labels.prefix(2) == ["Sidebar", "Show in Sidebar"])
        #expect(Array(labels.dropFirst(2)) == SidebarFeature.allCases.map(\.title), "No explanatory text beyond the rows")
        let switches = descendants(root).compactMap { $0 as? NSSwitch }
        #expect(switches.map { $0.identifier?.rawValue } == SidebarFeature.allCases.map { "sidebar.visibility.\($0.rawValue)" })
        #expect(switches.map { $0.accessibilityLabel() } == SidebarFeature.allCases.map { "Show \($0.title) in Sidebar" })
        #expect(switches.map(\.state) == [.on, .on, .on, .on, .off, .on])
        #expect(descendants(root).compactMap { $0 as? NSImageView }.count == SidebarFeature.allCases.count)
        fixture.store.enterDockerMode()
        switches[2].performClick(nil)
        #expect(!visibility.isVisible(.docker))
        #expect(!fixture.store.isDockerMode)
        #expect(fixture.defaults.stringArray(forKey: SidebarFeatureVisibility.defaultsKey) == ["docker", "runners"])
        switches[4].performClick(nil)
        #expect(visibility.isVisible(.runners))
        #expect(!fixture.store.isRunnersMode)
    }

    @Test("Settings window opens the Sidebar page from search and renders in both appearances")
    func settingsWindowShowsSidebarPage() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let output = ProcessInfo.processInfo.environment["MADE_TOOL_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        fixture.store.sidebarVisibility.setVisible(false, for: .remoteDesktop)
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let controller = PilotSettingsViewController(
                updater: updater.updater, droneStore: .isolated(), identity: SecureIdentity(role: .pilot, isolated: true),
                onOpenSetup: {}, onOpenMessaging: {}, defaults: fixture.defaults,
                sidebarVisibility: fixture.store.sidebarVisibility, runsLiveChecks: false)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 680),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Settings"
            window.appearance = NSAppearance(named: appearance)
            window.contentViewController = controller
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil); window.close() }
            let search = try #require(descendants(controller.view).compactMap { $0 as? NSSearchField }.first)
            let sections = try #require(descendants(controller.view).compactMap { $0 as? NSTableView }.first)
            #expect(sections.numberOfRows == 4)
            search.stringValue = "agentic"
            controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
            #expect(sections.numberOfRows == 1)
            sections.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            #expect(fixture.defaults.string(forKey: SettingsTab.storageKey) == SettingsTab.sidebar)
            let page = try #require(descendants(controller.view).compactMap { $0 as? NSSwitch }
                .first { $0.identifier?.rawValue == "sidebar.visibility.remoteDesktop" })
            #expect(page.state == .off)
            search.stringValue = ""
            controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
            #expect(sections.numberOfRows == 4)
            guard let output else { continue }
            // The frame view also draws the window background and title bar.
            let frame = try #require(window.contentView?.superview)
            frame.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            frame.displayIfNeeded()
            let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
            frame.effectiveAppearance.performAsCurrentDrawingAppearance { frame.cacheDisplay(in: frame.bounds, to: bitmap) }
            let name = appearance == .darkAqua ? "sidebar-settings-dark.png" : "sidebar-settings-light.png"
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name))
        }
    }

    // MARK: - Helpers

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

private final class ObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

@MainActor
private final class Fixture {
    let defaultsName = "app.blau.pilot.sidebar-visibility-test.\(UUID().uuidString)"
    let defaults: UserDefaults
    let container: ModelContainer
    let store: WorkspaceStore
    let cache = CockpitPaneControllerCache()

    init() throws {
        defaults = UserDefaults(suiteName: defaultsName)!
        let schema = Schema([Workspace.self, Pane.self, BrowserState.self, EditorState.self,
                             Note.self, RemoteDesktopConnection.self, ExtensionWorkspaceLink.self])
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        store = WorkspaceStore(modelContext: container.mainContext, workspaceGroups: WorkspaceGroups(defaults: defaults), defaults: defaults)
    }

    func window() -> CockpitWindowController {
        CockpitWindowController(store: store, extensionController: ExtensionWorkspaceController(modelContext: container.mainContext),
                                surface: .main, defaults: defaults, isLive: false, paneCache: cache,
                                paneFactory: { _, _ in NSViewController() }, globalFactory: { _ in nil })
    }

    func cleanUp() { cache.closeAll(); defaults.removePersistentDomain(forName: defaultsName) }
}
