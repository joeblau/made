import AppKit
import SwiftData
import XCTest
@testable import Pilot

final class NativeCockpitWindowTests: XCTestCase {
    @MainActor
    func testInitialWindowKeepsRequestedSizeAndRendersNativeNotesHierarchy() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.store.enterNotesMode()
        fixture.store.selectedNote?.body = "# Cockpit native fixture\n\nNative window, sidebar and Notes editor.\n\n- [ ] Verify native editing\n- [x] Keep fixture data isolated"
        var paneCreations = 0
        let controller = fixture.window(paneFactory: { _, _ in
            paneCreations += 1
            return FixturePaneController()
        })
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.frame.width, 1440, accuracy: 1)
        XCTAssertGreaterThanOrEqual(window.frame.height, 920)
        XCTAssertEqual(window.frameAutosaveName, "", "An isolated window must not write the production frame preference")
        controller.showWindow(nil)
        defer { window.orderOut(nil); controller.windowWillClose(Notification(name: NSWindow.willCloseNotification)); fixture.cache.closeAll() }
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        root.layoutSubtreeIfNeeded()
        let split = try XCTUnwrap(window.contentViewController as? NSSplitViewController)
        XCTAssertEqual(split.splitViewItems.count, 3)
        XCTAssertTrue(split.splitViewItems[2].isCollapsed)
        let views = descendants(root)
        let table = try XCTUnwrap(views.compactMap { $0 as? NSTableView }.first)
        XCTAssertGreaterThanOrEqual(table.numberOfRows, 5, "The global navigation rows must be populated")
        XCTAssertGreaterThan(table.frame.width, 150)
        XCTAssertGreaterThan(table.visibleRect.width, 150)
        XCTAssertGreaterThan(table.visibleRect.height, 150)
        let notesRow = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: false), "Visible rows must have native cell views")
        XCTAssertTrue(descendants(notesRow).contains { ($0 as? NSTextField)?.stringValue == "Notes" })
        let noteTab = try XCTUnwrap(views.first { $0.accessibilityIdentifier().hasPrefix("notes.tab.") })
        let tabInWindow = noteTab.convert(noteTab.bounds, to: nil)
        XCTAssertTrue(window.contentLayoutRect.contains(tabInWindow), "The Notes tabs must be below the native window toolbar")
        XCTAssertTrue(views.contains { $0 is NoteTextView }, "Notes must mount the production native editor")
        XCTAssertFalse(views.contains { NSStringFromClass(type(of: $0)).contains("NSHostingView") })
        XCTAssertEqual(paneCreations, 0, "Opening Notes must not initialize terminal or browser engines")
        XCTAssertGreaterThan(split.splitViewItems[0].viewController.view.bounds.width, 150)
        XCTAssertGreaterThan(split.splitViewItems[1].viewController.view.bounds.width, 300)

        for view in views.reversed() { view.displayIfNeeded() }
        root.displayIfNeeded()
        let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 10_000)
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "cockpit-native-window-notes.png"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["COCKPIT_SHELL_SNAPSHOT_DIR"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try png.write(to: url.appendingPathComponent("cockpit-native-window-notes.png"), options: .atomic)
        }
    }

    @MainActor
    func testNotesCloseCommandCommitsMarkedTextBeforeDecidingWhetherToDelete() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.store.enterNotesMode()
        let note = try XCTUnwrap(fixture.store.selectedNote)
        let controller = fixture.window()
        controller.refresh()
        let window = try XCTUnwrap(controller.window)
        defer {
            window.orderOut(nil)
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        }
        let root = try XCTUnwrap(window.contentView)
        let editor = try XCTUnwrap(descendants(root).compactMap { $0 as? NoteTextView }.first)
        window.makeFirstResponder(editor.textView)
        editor.textView.setMarkedText("日本語", selectedRange: NSRange(location: 3, length: 0),
                                      replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.textView.hasMarkedText())
        XCTAssertTrue(note.body.isEmpty)

        controller.closeSelectedPane()

        XCTAssertFalse(editor.textView.hasMarkedText())
        XCTAssertEqual(note.body, "日本語")
        XCTAssertTrue(fixture.store.notes.contains { $0.id == note.id })
        XCTAssertEqual(fixture.store.notePendingClose?.id, note.id)
    }

    @MainActor
    func testWindowRestoresItsOwnFrameAfterContentAndToolbarAreInstalled() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let savedController = fixture.window()
        let saved = try XCTUnwrap(savedController.window)
        saved.setFrame(NSRect(x: 100, y: 100, width: 1120, height: 752), display: false)
        let size = saved.frame.size
        fixture.defaults.set(saved.frameDescriptor, forKey: "NSWindow Frame " + PilotWindowID.main)
        saved.orderOut(nil)
        let controller = fixture.window()
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.frame.width, size.width, accuracy: 1)
        XCTAssertEqual(window.frame.height, size.height, accuracy: 1)
        XCTAssertEqual(window.frameAutosaveName, "")
        let extensionWindow = fixture.window(surface: .extension)
        XCTAssertEqual(extensionWindow.window?.frame.width, 1000, "Main geometry must not leak into Extendo")
        window.orderOut(nil)
        extensionWindow.window?.orderOut(nil)
    }

    @MainActor
    func testRevealVetoedEditorSelectsItsSourceAndOnlyItsOwningWindow() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.store.addWorkspace()
        let source = try XCTUnwrap(fixture.store.selectedWorkspace)
        let mainPane = Pane(kind: .editor, sortOrder: 0)
        source.panes = [mainPane]
        mainPane.workspace = source
        source.selectedPaneID = mainPane.id
        fixture.extensionController.update(with: source, validSourceIDs: [source.id])
        let companion = try XCTUnwrap(fixture.extensionController.selectedWorkspace)
        let extensionPane = Pane(kind: .editor, sortOrder: 0)
        companion.panes = [extensionPane]
        extensionPane.workspace = companion
        companion.selectedPaneID = extensionPane.id
        extensionPane.isCollapsed = true
        let main = fixture.window()
        let extendo = fixture.window(surface: .extension)
        XCTAssertFalse(main.revealPane(withID: extensionPane.id))
        XCTAssertTrue(extendo.revealPane(withID: extensionPane.id))
        defer {
            extendo.window?.orderOut(nil)
            extendo.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        }
        XCTAssertEqual(fixture.store.selectedWorkspaceID, source.id)
        XCTAssertTrue(extendo.selectedWorkspace === companion)
        XCTAssertTrue(extendo.selectedPane === extensionPane)
        XCTAssertFalse(extensionPane.isCollapsed)
        XCTAssertFalse(main.window?.isVisible ?? true)
        XCTAssertTrue(extendo.window?.isVisible == true)
    }

    @MainActor
    func testMenuDisablesPaneCommandsWithoutAKeyCockpitAndClosesAuxiliaryWindow() throws {
        let oldMainMenu = NSApp.mainMenu
        let oldWindowsMenu = NSApp.windowsMenu
        let oldServicesMenu = NSApp.servicesMenu
        defer { NSApp.mainMenu = oldMainMenu; NSApp.windowsMenu = oldWindowsMenu; NSApp.servicesMenu = oldServicesMenu }
        let auxiliary = AuxiliaryFixtureWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        auxiliary.isReleasedWhenClosed = false
        defer { auxiliary.orderOut(nil) }
        let menus = CockpitMenuController(windowProvider: { nil }, showMain: {}, toggleExtendo: {},
                                           showSettings: {}, showSetup: {}, checkForUpdates: {}, keyWindowProvider: { auxiliary })
        menus.canCheckForUpdates = { false }
        menus.install()
        let items = flattened(try XCTUnwrap(NSApp.mainMenu))
        for title in ["New Terminal", "New Browser", "Focus Address Bar", "Check for Updates…", "Focus or Restore Selected Pane", "Hide Selected Pane", "Arrange Panes Horizontally", "Stack Panes Vertically", "Reset Pane Sizes"] {
            let item = try XCTUnwrap(items.first { $0.title == title } as? ShellMenuItem)
            XCTAssertFalse(item.validateMenuItem(item), title)
        }
        let close = try XCTUnwrap(items.first { $0.title == "Close Tab" } as? ShellMenuItem)
        XCTAssertTrue(close.validateMenuItem(close))
        close.perform()
        XCTAssertEqual(auxiliary.closeRequests, 1)
    }

    @MainActor
    func testSidebarDisclosureSelectionIsPureAndKeyboardChangesExpandedState() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.store.addWorkspace()
        let workspace = try XCTUnwrap(fixture.store.selectedWorkspace)
        let groupID = fixture.store.workspaceGroups.add(name: "Projects", workspaceIDs: fixture.store.unpinnedWorkspaceIDs)
        fixture.store.moveWorkspace(workspace, toGroup: groupID)
        let sidebar = WorkspaceSidebarViewController(store: fixture.store, defaults: fixture.defaults, isLive: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = sidebar
        window.setContentSize(NSSize(width: 320, height: 600))
        defer { window.close() }
        sidebar.view.layoutSubtreeIfNeeded()
        sidebar.refresh()
        let table = try XCTUnwrap(descendants(sidebar.view).compactMap { $0 as? NSTableView }.first)
        let groupRow = try XCTUnwrap((0..<table.numberOfRows).first { row in
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) else { return false }
            return descendants(cell).contains { $0.accessibilityIdentifier() == "sidebar.group." + groupID.uuidString }
        })
        XCTAssertTrue(sidebar.tableView(table, shouldSelectRow: groupRow))
        XCTAssertTrue(fixture.store.workspaceGroups.group(groupID)?.isExpanded == true, "Selection must not collapse a group")
        table.selectRowIndexes(IndexSet(integer: groupRow), byExtendingSelection: false)
        let expandedRowCount = table.numberOfRows
        table.keyDown(with: keyEvent(code: 123, window: window))
        XCTAssertFalse(fixture.store.workspaceGroups.group(groupID)?.isExpanded ?? true)
        XCTAssertLessThan(table.numberOfRows, expandedRowCount)
        table.keyDown(with: keyEvent(code: 36, window: window))
        XCTAssertTrue(fixture.store.workspaceGroups.group(groupID)?.isExpanded == true)
        XCTAssertEqual(table.numberOfRows, expandedRowCount)
        let groupCell = try XCTUnwrap(table.view(atColumn: 0, row: groupRow, makeIfNecessary: true))
        let disclosure = try XCTUnwrap(descendants(groupCell).compactMap { $0 as? NSButton }.first)
        XCTAssertEqual(disclosure.accessibilityRole(), .disclosureTriangle)
        XCTAssertEqual(disclosure.state, .on)
        disclosure.performClick(nil)
        XCTAssertFalse(fixture.store.workspaceGroups.group(groupID)?.isExpanded ?? true)
        table.keyDown(with: keyEvent(code: 124, window: window))
        XCTAssertTrue(fixture.store.workspaceGroups.group(groupID)?.isExpanded == true)

        let oldZoom = CockpitUIZoomController.shared.factor
        defer { CockpitUIZoomController.shared.factor = oldZoom }
        CockpitUIZoomController.shared.factor = 2
        sidebar.refresh()
        XCTAssertEqual(table.rect(ofRow: groupRow).height, 56, accuracy: 1)
        XCTAssertEqual(table.rect(ofRow: groupRow + 1).height, 88, accuracy: 1)
    }

    @MainActor
    func testLayoutMenuChangesSelectedWorkspaceAndRestoresFocusedLayout() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.store.addWorkspace()
        let workspace = try XCTUnwrap(fixture.store.selectedWorkspace)
        let first = Pane(kind: .editor, sortOrder: 0)
        let second = Pane(kind: .editor, sortOrder: 1)
        workspace.panes = [first, second]
        first.workspace = workspace; second.workspace = workspace
        workspace.selectedPaneID = first.id
        let controller = fixture.window()
        let oldMain = NSApp.mainMenu, oldWindows = NSApp.windowsMenu, oldServices = NSApp.servicesMenu
        defer { NSApp.mainMenu = oldMain; NSApp.windowsMenu = oldWindows; NSApp.servicesMenu = oldServices }
        let menus = CockpitMenuController(windowProvider: { controller }, showMain: {}, toggleExtendo: {}, showSettings: {}, showSetup: {}, checkForUpdates: {})
        menus.install()
        let items = flattened(try XCTUnwrap(NSApp.mainMenu))
        func invoke(_ title: String) throws {
            let item = try XCTUnwrap(items.first { $0.title == title } as? ShellMenuItem)
            XCTAssertTrue(item.validateMenuItem(item))
            item.perform()
        }
        try invoke("Stack Panes Vertically")
        XCTAssertEqual(workspace.axis, .horizontal)
        try invoke("Arrange Panes Horizontally")
        XCTAssertEqual(workspace.axis, .vertical)
        try invoke("Focus or Restore Selected Pane")
        XCTAssertEqual(workspace.focusedPaneID, first.id)
        XCTAssertTrue(second.isCollapsed)
        try invoke("Focus or Restore Selected Pane")
        XCTAssertNil(workspace.focusedPaneID)
        XCTAssertFalse(second.isCollapsed)
        first.sizeFraction = 0.9; second.sizeFraction = 0.1
        try invoke("Reset Pane Sizes")
        XCTAssertEqual(first.sizeFraction, second.sizeFraction, accuracy: 0.001)
    }

    @MainActor
    func testMicrophoneStatusRemainsAnAccessibleNativeAction() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.store.enterNotesMode()
        let controller = fixture.window()
        controller.refresh()
        let root = try XCTUnwrap(controller.window?.contentView)
        let idle = try XCTUnwrap(descendants(root).first { $0.accessibilityIdentifier() == "sidebar.microphone-status" } as? NSButton)
        XCTAssertEqual(idle.accessibilityLabel(), "Microphone idle")
        XCTAssertNotNil(idle.target)
        XCTAssertNotNil(idle.action)
        controller.isPeerRecording = true
        let recording = try XCTUnwrap(descendants(root).first { $0.accessibilityIdentifier() == "sidebar.microphone-status" } as? NSButton)
        XCTAssertEqual(recording.accessibilityLabel(), "Microphone recording")
        XCTAssertNotNil(recording.target)
        XCTAssertNotNil(recording.action)
    }

    @MainActor
    func testExplicitPaneInputFocusWinsOverGenericDescendantSearch() {
        let cache = CockpitPaneControllerCache()
        defer { cache.closeAll() }
        let pane = Pane(kind: .editor, sortOrder: 0)
        let workspace = Workspace(name: "Focus")
        workspace.panes = [pane]; pane.workspace = workspace; workspace.selectedPaneID = pane.id
        let target = FocusFixturePaneController()
        let presentation = CockpitWorkspaceViewController(workspace: workspace, projectID: workspace.id, surface: .main,
            cache: cache, factory: { _, _ in target }, onDrop: { _, _ in false })
        presentation.refresh(isActive: true)
        presentation.focusSelectedPane()
        XCTAssertEqual(target.focusRequests, 1)
    }

    @MainActor
    private func keyEvent(code: UInt16, window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                        isARepeat: false, keyCode: code)!
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor
    private func flattened(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(flattened) ?? []) }
    }
}

@MainActor
private final class Fixture {
    let defaultsName = "app.blau.pilot.native-window-test.\(UUID().uuidString)"
    let defaults: UserDefaults
    let container: ModelContainer
    let store: WorkspaceStore
    let extensionController: ExtensionWorkspaceController
    let cache = CockpitPaneControllerCache()

    init() throws {
        defaults = UserDefaults(suiteName: defaultsName)!
        let schema = Schema([Workspace.self, Pane.self, BrowserState.self, EditorState.self,
                             Note.self, RemoteDesktopConnection.self, ExtensionWorkspaceLink.self])
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        store = WorkspaceStore(modelContext: container.mainContext, workspaceGroups: WorkspaceGroups(defaults: defaults), defaults: defaults)
        extensionController = ExtensionWorkspaceController(modelContext: container.mainContext)
    }
    func window(surface: WorkspacePaneSurface = .main,
                paneFactory: @escaping (Pane, String?) -> NSViewController = { _, _ in FixturePaneController() }) -> CockpitWindowController {
        CockpitWindowController(store: store, extensionController: extensionController, surface: surface,
                                defaults: defaults, isLive: false, paneCache: cache, paneFactory: paneFactory,
                                globalFactory: { [store, defaults] mode in
            mode == .notes ? NotesViewController(store: store, defaults: defaults) : nil
        })
    }
    func cleanUp() { cache.closeAll(); defaults.removePersistentDomain(forName: defaultsName) }
}

@MainActor
private final class FixturePaneController: NSViewController {
    init() { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }
    override func loadView() { view = NSView() }
}

@MainActor
private final class AuxiliaryFixtureWindow: NSWindow {
    var closeRequests = 0
    override func performClose(_ sender: Any?) { closeRequests += 1 }
}

@MainActor
private final class FocusFixturePaneController: NSViewController, CockpitPaneInputFocusing {
    var focusRequests = 0
    init() { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        view = NSView()
        let hiddenField = NSTextField()
        hiddenField.isHidden = true
        view.addSubview(hiddenField)
    }
    func focusPaneInput() { focusRequests += 1 }
}
