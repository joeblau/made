import AppKit
import SwiftData
import XCTest
@testable import Pilot

final class NativeCockpitWindowTests: XCTestCase {
    @MainActor
    func testGlobalPageControlsUseTheCenteredToolbarAndRetainFiltersAcrossPages() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let docker = DockerViewController(store: DockerStore(defaults: fixture.defaults), isLive: false)
        let runners = RunnersViewController(store: RunnersStore(defaults: fixture.defaults), defaults: fixture.defaults, isLive: false)
        let controller = CockpitWindowController(store: fixture.store, extensionController: fixture.extensionController,
            surface: .main, defaults: fixture.defaults, isLive: false, paneCache: fixture.cache,
            paneFactory: { _, _ in FixturePaneController() }, globalFactory: { mode in
                switch mode {
                case .docker: docker
                case .runners: runners
                default: FixturePaneController()
                }
            })
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        defer { window.orderOut(nil); controller.windowWillClose(Notification(name: NSWindow.willCloseNotification)) }
        controller.select(.docker)
        let toolbar = try XCTUnwrap(window.toolbar)
        let item = try XCTUnwrap(toolbar.items.first { $0.view === docker.pageToolbarView })
        XCTAssertTrue(toolbar.centeredItemIdentifiers.contains(item.itemIdentifier))
        XCTAssertFalse(item.isHidden)
        XCTAssertFalse(toolbar.items.contains { $0.itemIdentifier.rawValue == "cockpit.launcher" })
        XCTAssertFalse(docker.pageToolbarView.isDescendant(of: docker.view))
        let search = try XCTUnwrap(descendants(docker.pageToolbarView).compactMap { $0 as? NSSearchField }.first)
        let stopped = try XCTUnwrap(descendants(docker.pageToolbarView).compactMap { $0 as? NSSwitch }.first { $0.accessibilityLabel() == "Show stopped" })
        if let destination = ProcessInfo.processInfo.environment["MADE_TOOL_REVIEW_OUTPUT"] {
            let output = URL(fileURLWithPath: destination)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            window.makeFirstResponder(search)
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            let controls = docker.pageToolbarView
            let bitmap = try XCTUnwrap(controls.bitmapImageRepForCachingDisplay(in: controls.bounds))
            controls.effectiveAppearance.performAsCurrentDrawingAppearance { controls.cacheDisplay(in: controls.bounds, to: bitmap) }
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("docker-toolbar.png"))
        }
        search.stringValue = "redis"
        docker.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        stopped.performClick(nil)
        let showsStopped = docker.store.showsStopped
        controller.select(.notes)
        XCTAssertTrue(item.isHidden)
        controller.select(.docker)
        XCTAssertTrue(item.view === docker.pageToolbarView)
        XCTAssertFalse(item.isHidden)
        XCTAssertEqual(search.stringValue, "redis")
        XCTAssertEqual(docker.store.showsStopped, showsStopped)
        controller.select(.runners)
        XCTAssertTrue(item.view === runners.pageToolbarView)
        XCTAssertFalse(item.isHidden)
        XCTAssertFalse(runners.pageToolbarView.isDescendant(of: runners.view))
        let layout = try XCTUnwrap(descendants(runners.pageToolbarView).compactMap { $0 as? NSSegmentedControl }.first)
        layout.selectedSegment = 2
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(layout.action), to: layout.target, from: layout))
        controller.select(.docker)
        controller.select(.runners)
        XCTAssertTrue(item.view === runners.pageToolbarView)
        XCTAssertEqual(layout.selectedSegment, 2)
        window.setContentSize(NSSize(width: 1000, height: 800))
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        XCTAssertTrue(toolbar.visibleItems?.contains { $0 === item } == true, "Primary page controls must fit in a smaller window")
    }

    @MainActor
    func testSidebarSectionHeadersAlwaysShowTheirRowsAndCannotBeSelected() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(false, forKey: "sidebar.pinnedExpanded")
        fixture.defaults.set(false, forKey: "sidebar.workspacesExpanded")
        fixture.store.addWorkspace()
        fixture.store.selectedWorkspace?.isPinned = true
        fixture.store.addWorkspace()
        let sidebar = WorkspaceSidebarViewController(store: fixture.store, defaults: fixture.defaults, isLive: false)
        let table = try XCTUnwrap(descendants(sidebar.view).compactMap { $0 as? NSTableView }.first)
        XCTAssertEqual(table.numberOfRows, 9, "Both sections remain expanded even with old collapsed preferences")
        for row in [5, 7] {
            XCTAssertTrue(sidebar.tableView(table, isGroupRow: row))
            XCTAssertFalse(sidebar.tableView(table, shouldSelectRow: row))
            let view = try XCTUnwrap(sidebar.tableView(table, viewFor: table.tableColumns[0], row: row))
            XCTAssertTrue(view.accessibilityIdentifier().hasPrefix("sidebar.section."))
            XCTAssertFalse(descendants(view).contains { $0 is NSButton })
        }
    }

    @MainActor
    func testCachedGlobalPageKeepsItsViewAndRelinquishesKeyboardFocusWhileHidden() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.store.enterNotesMode()
        let controller = fixture.window()
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        defer { window.orderOut(nil); controller.windowWillClose(Notification(name: NSWindow.willCloseNotification)) }
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(descendants(root).compactMap { $0 as? NoteTextView }.first)
        let parent = try XCTUnwrap(editor.superview)
        XCTAssertTrue(window.makeFirstResponder(editor.textView))
        editor.textView.insertText("Keep this draft", replacementRange: NSRange(location: 0, length: 0))
        let selection = NSRange(location: 2, length: 4)
        editor.textView.setSelectedRange(selection)
        controller.select(.remoteDesktop)
        XCTAssertTrue(editor.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(editor.superview === parent)
        XCTAssertTrue(editor.window === window)
        XCTAssertFalse(window.firstResponder === editor.textView)
        controller.select(.notes)
        root.layoutSubtreeIfNeeded()
        XCTAssertFalse(editor.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(editor.superview === parent)
        XCTAssertEqual(editor.textView.string, "Keep this draft")
        XCTAssertEqual(editor.textView.selectedRange(), selection)
    }

    @MainActor
    func testNavigationRetainsUnchangedSidebarRowsAndUpdatesRenamedWorkspaces() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.store.addWorkspace()
        let workspace = try XCTUnwrap(fixture.store.selectedWorkspace)
        workspace.name = "Before"
        let controller = fixture.window()
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        defer { window.orderOut(nil); controller.windowWillClose(Notification(name: NSWindow.willCloseNotification)) }
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        let sidebar = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTableView }.first {
            $0.accessibilityLabel() == "Cockpit navigation"
        })
        let notesRow = try XCTUnwrap(sidebar.view(atColumn: 0, row: 0, makeIfNecessary: true))
        for selection in [SidebarSelection.notes, .remoteDesktop, .workspace(workspace.id)] {
            controller.select(selection)
            root.layoutSubtreeIfNeeded()
            XCTAssertTrue(sidebar.view(atColumn: 0, row: 0, makeIfNecessary: true) === notesRow)
        }
        workspace.name = "After"
        controller.refresh()
        root.layoutSubtreeIfNeeded()
        XCTAssertTrue(descendants(sidebar).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "After" })
        XCTAssertFalse(descendants(sidebar).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Before" })
    }

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
    func testGlassColumnsKeepContentClearOfToolbarAndInspector() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.store.addWorkspace()
        let workspace = try XCTUnwrap(fixture.store.selectedWorkspace)
        let paneController = FixturePaneController()
        let controller = fixture.window(paneFactory: { _, _ in paneController })
        controller.inspectorFactory = { workspace in
            InspectorViewController(workspace: workspace, usageStore: UsageStore(defaults: fixture.defaults),
                                    defaults: fixture.defaults, isLive: false)
        }
        let window = try XCTUnwrap(controller.window)
        controller.showWindow(nil)
        defer { window.orderOut(nil); controller.windowWillClose(Notification(name: NSWindow.willCloseNotification)) }
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let toolbar = try XCTUnwrap(window.toolbar)
        let inspectorToggle = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier == .toggleInspector })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(inspectorToggle.action), to: inspectorToggle.target, from: inspectorToggle))
        let split = try XCTUnwrap(window.contentViewController as? NSSplitViewController)
        XCTAssertTrue(workspace.isInspectorPresented)
        XCTAssertFalse(split.splitViewItems[2].isCollapsed)
        let inspector = try XCTUnwrap(split.splitViewItems[2].viewController.children.first)

        for width in [1440.0, 1000.0] {
            window.setContentSize(NSSize(width: width, height: 820))
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            window.contentView?.layoutSubtreeIfNeeded()
            let bodyRect = paneController.view.convert(paneController.view.bounds, to: nil)
            let inspectorRect = inspector.view.convert(inspector.view.bounds, to: nil)
            XCTAssertGreaterThan(bodyRect.width, 250)
            XCTAssertGreaterThan(inspectorRect.width, 200)
            XCTAssertLessThanOrEqual(bodyRect.maxY, window.contentLayoutRect.maxY + 1)
            XCTAssertLessThanOrEqual(inspectorRect.maxY, window.contentLayoutRect.maxY + 1)
            XCTAssertLessThanOrEqual(bodyRect.maxX, inspectorRect.minX + 1)
        }

        window.setContentSize(NSSize(width: 1440, height: 920))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            let frame = try XCTUnwrap(window.contentView?.superview)
            frame.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let visibleItems = toolbar.visibleItems?.map(\.itemIdentifier) ?? []
            XCTAssertTrue(visibleItems.contains(.init("cockpit.launcher")), "The launchers must fit above the inspector")
            XCTAssertTrue(visibleItems.contains(.init("cockpit.draw")), "Annotate must remain visible beside the launchers")
            frame.displayIfNeeded()
            let bitmap = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "cockpit-glass-\(appearance.rawValue).png"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(inspectorToggle.action), to: inspectorToggle.target, from: inspectorToggle))
        XCTAssertFalse(workspace.isInspectorPresented)
        XCTAssertTrue(split.splitViewItems[2].isCollapsed)
        let sidebarToggle = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier == .toggleSidebar })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(sidebarToggle.action), to: sidebarToggle.target, from: sidebarToggle))
        try await Task.sleep(for: .milliseconds(500))
        window.contentView?.layoutSubtreeIfNeeded()
        let expandedContent = try XCTUnwrap(split.splitViewItems[1].viewController.children.first)
        let expandedRect = expandedContent.view.convert(expandedContent.view.bounds, to: nil)
        XCTAssertEqual(expandedRect.minX, window.contentLayoutRect.minX, accuracy: 1,
                       "Hiding the sidebar must expand content without needing a window resize")
        XCTAssertEqual(expandedRect.maxX, window.contentLayoutRect.maxX, accuracy: 1)
        for width in [1000.0, 1440.0] {
            window.setContentSize(NSSize(width: width, height: 820))
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            window.contentView?.layoutSubtreeIfNeeded()
            let content = try XCTUnwrap(split.splitViewItems[1].viewController.children.first)
            let rect = content.view.convert(content.view.bounds, to: nil)
            XCTAssertEqual(rect.minX, window.contentLayoutRect.minX, accuracy: 1)
            XCTAssertEqual(rect.maxX, window.contentLayoutRect.maxX, accuracy: 1)
        }
        controller.select(.remoteDesktop)
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        window.contentView?.layoutSubtreeIfNeeded()
        let remote = try XCTUnwrap(split.splitViewItems[1].viewController.children.first as? RemoteDesktopViewController)
        let emptyLabel = try XCTUnwrap(descendants(remote.view).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Empty Screen" })
        let emptySurface = try XCTUnwrap(emptyLabel.superview?.superview)
        for appearance in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .aqua] {
            window.appearance = NSAppearance(named: appearance)
            window.contentView?.layoutSubtreeIfNeeded()
            var expected: CGColor?
            emptySurface.effectiveAppearance.performAsCurrentDrawingAppearance { expected = NSColor.controlBackgroundColor.cgColor }
            XCTAssertEqual(emptySurface.layer?.backgroundColor, expected)
        }
        let remoteRect = remote.view.convert(remote.view.bounds, to: nil)
        XCTAssertEqual(remoteRect.minX, window.contentLayoutRect.minX, accuracy: 1)
        XCTAssertEqual(remoteRect.maxX, window.contentLayoutRect.maxX, accuracy: 1)
        controller.select(.notes)
        XCTAssertFalse(toolbar.items.contains { $0.itemIdentifier == .toggleInspector })
        controller.select(.workspace(workspace.id))
        XCTAssertTrue(toolbar.items.first { $0.itemIdentifier == .toggleInspector }?.isEnabled == true)
    }

    @MainActor
    func testInspectorAnimatesBothDirectionsAcrossObservationRefreshes() async throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                      "Native inspector motion is disabled by the accessibility preference")
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.store.addWorkspace()
        let workspace = try XCTUnwrap(fixture.store.selectedWorkspace)
        let controller = fixture.window()
        var inspectorCreations = 0
        controller.inspectorFactory = { _ in
            inspectorCreations += 1
            return FixturePaneController()
        }
        let window = try XCTUnwrap(controller.window)
        controller.showWindow(nil)
        defer { window.orderOut(nil); controller.windowWillClose(Notification(name: NSWindow.willCloseNotification)) }
        window.contentView?.layoutSubtreeIfNeeded()
        let split = try XCTUnwrap(window.contentViewController as? NSSplitViewController)
        let body = split.splitViewItems[1].viewController.view
        let initialWidth = body.bounds.width
        let samples = SplitWidthSamples()
        body.postsFrameChangedNotifications = true
        let observer = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: body, queue: .main
        ) { _ in
            MainActor.assumeIsolated { samples.widths.append(body.bounds.width) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        for presented in [true, false] {
            samples.widths.removeAll()
            let before = body.bounds.width
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.4
                    controller.toggleInspector()
                    // Model observation and window activation can refresh while moving.
                    controller.refresh()
                } completionHandler: {
                    continuation.resume()
                }
            }
            window.contentView?.layoutSubtreeIfNeeded()
            let after = body.bounds.width
            XCTAssertEqual(workspace.isInspectorPresented, presented)
            XCTAssertEqual(split.splitViewItems[2].isCollapsed, !presented)
            XCTAssertGreaterThan(abs(after - before), 300)
            XCTAssertTrue(samples.widths.contains { $0 > min(before, after) + 2 && $0 < max(before, after) - 2 },
                          "The content must pass through intermediate widths when the inspector \(presented ? "opens" : "closes"): \(samples.widths)")
        }
        XCTAssertEqual(body.bounds.width, initialWidth, accuracy: 1)
        XCTAssertEqual(inspectorCreations, 1, "The transition must reuse the inspector controller")
    }

    @MainActor
    func testDrawingCanvasCoversWindowChromeAndResizesWithIt() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.store.addWorkspace()
        let controller = fixture.window()
        controller.inspectorFactory = { _ in FixturePaneController() }
        var overlay: InkOverlayViewController?
        controller.overlayFactory = { [weak controller] in
            let canvas = InkOverlayViewController { controller?.setDrawingActive(false) }
            overlay = canvas
            return canvas
        }
        let window = try XCTUnwrap(controller.window)
        controller.showWindow(nil)
        defer { window.orderOut(nil); controller.windowWillClose(Notification(name: NSWindow.willCloseNotification)) }
        controller.toggleInspector()
        controller.setDrawingActive(true)
        let canvas = try XCTUnwrap(overlay)
        let frame = try XCTUnwrap(window.contentView?.superview)
        for size in [NSSize(width: 1440, height: 920), NSSize(width: 1100, height: 800)] {
            window.setContentSize(size)
            frame.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            frame.layoutSubtreeIfNeeded()
            XCTAssertTrue(canvas.view.superview === frame)
            XCTAssertEqual(canvas.view.frame, frame.bounds)
            XCTAssertEqual(canvas.markupController.markup?.bounds.size, frame.bounds.size)
            for point in [NSPoint(x: 30, y: frame.bounds.midY),
                          NSPoint(x: frame.bounds.maxX - 30, y: frame.bounds.midY),
                          NSPoint(x: frame.bounds.midX, y: frame.bounds.maxY - 20)] {
                let hit = try XCTUnwrap(frame.hitTest(point))
                XCTAssertTrue(hit === canvas.view || hit.isDescendant(of: canvas.view),
                              "Drawing must intercept sidebar, inspector, and toolbar clicks")
            }
        }
        canvas.cancelOperation(nil)
        XCTAssertFalse(controller.isDrawingActive)
        XCTAssertNil(canvas.view.superview)
        controller.setDrawingActive(true)
        XCTAssertTrue(controller.isDrawingActive)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertFalse(controller.isDrawingActive)
        XCTAssertNil(overlay?.view.superview)
    }

    @MainActor
    func testTerminalOpeningShortcutsStayWithTheFocusedChooser() throws {
        try assertOpeningShortcuts(tool: "Terminal", letters: ["a", "r", "A", "R"])
    }

    @MainActor
    func testMobileOpeningShortcutsStayWithTheFocusedChooser() throws {
        for tool in ["Apple", "Android"] {
            try assertOpeningShortcuts(tool: tool, letters: ["s", "d", "S", "D"])
        }
    }

    @MainActor
    private func assertOpeningShortcuts(tool: String, letters: [String]) throws {
        let typing = Array(letters.prefix(2))
        for letter in letters {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            fixture.store.addWorkspace()
            var created: [UUID: NSTextView] = [:]
            let controller = fixture.window(paneFactory: { pane, _ in
                let child = NSViewController()
                let input = NSTextView()
                child.view = input
                created[pane.id] = input
                return child
            })
            controller.showWindow(nil)
            let window = try XCTUnwrap(controller.window)
            defer { window.orderOut(nil); controller.windowWillClose(Notification(name: NSWindow.willCloseNotification)) }
            let workspace = try XCTUnwrap(controller.selectedWorkspace)
            let originalInput = try XCTUnwrap(created.values.first)
            let launcher = try XCTUnwrap(window.toolbar?.items.compactMap { $0 as? NSToolbarItemGroup }.first {
                $0.itemIdentifier.rawValue == "cockpit.launcher"
            })
            let item = try XCTUnwrap(launcher.subitems.first { $0.label == tool })
            func openPane() throws {
                XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
                XCTAssertTrue(window.firstResponder is CockpitPaneModePicker)
            }
            func key(_ text: String, flags: NSEvent.ModifierFlags = [], repeatKey: Bool = false) throws -> NSEvent {
                try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
                    isARepeat: repeatKey, keyCode: ["a": 0, "r": 15, "c": 8, "s": 1, "d": 2][text.lowercased()]!))
            }
            let initialCount = created.count
            try openPane()
            let backgroundPane = try XCTUnwrap(workspace.selectedPane)
            try openPane()
            let pane = try XCTUnwrap(workspace.selectedPane)
            XCTAssertEqual(created.count, initialCount, "Opening a chooser must not start a session")

            // A pending chooser must not intercept typing elsewhere in the window.
            XCTAssertTrue(window.makeFirstResponder(originalInput))
            for text in typing { window.sendEvent(try key(text)) }
            XCTAssertEqual(originalInput.string, typing.joined())
            XCTAssertTrue(pane.isChoosingMode && backgroundPane.isChoosingMode)
            controller.focusSelectedPane()
            let picker = try XCTUnwrap(window.firstResponder as? CockpitPaneModePicker)
            XCTAssertEqual(picker.pane.id, pane.id)
            for flags: NSEvent.ModifierFlags in [.command, .control, .option] {
                picker.keyDown(with: try key(letter, flags: flags))
            }
            picker.keyDown(with: try key(letter, repeatKey: true))
            picker.keyDown(with: try key(tool == "Terminal" ? "c" : "a"))
            XCTAssertTrue(pane.isChoosingMode)

            window.sendEvent(try key(letter, flags: letter == letter.uppercased() ? .shift : []))
            if tool == "Terminal" {
                XCTAssertEqual(pane.kind, letter.lowercased() == "a" ? .agentChat : .terminal)
            } else if tool == "Apple" {
                XCTAssertEqual(pane.kind, letter.lowercased() == "s" ? .simulator : .device)
            } else {
                XCTAssertEqual(pane.kind, .android)
                XCTAssertEqual(pane.androidTarget, letter.lowercased() == "s" ? .simulator : .device)
            }
            XCTAssertFalse(pane.isChoosingMode)
            XCTAssertTrue(backgroundPane.isChoosingMode)
            XCTAssertEqual(created.count, initialCount + 1)
            let input = try XCTUnwrap(created[pane.id])
            XCTAssertTrue(window.firstResponder === input, "The selected pane receives focus immediately")
            for text in typing { window.sendEvent(try key(text)) }
            XCTAssertEqual(input.string, typing.joined(), "The shortcut stops handling letters after the choice")
        }
    }

    @MainActor
    func testCommandTAndCommandBOpenTheSameNativeChoicesAsTheToolbar() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.store.addWorkspace()
        let controller = fixture.window(paneFactory: { pane, _ in
            pane.kind == .browser ? BrowserPaneViewController(pane: pane) : FixturePaneController()
        })
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        defer { window.orderOut(nil); controller.windowWillClose(Notification(name: NSWindow.willCloseNotification)) }
        // Let the fixture window become visible before invoking commands, as it
        // already is when a user opens panes from its menu or toolbar.
        try await Task.sleep(for: .milliseconds(100))
        controller.refresh()
        let original = (NSApp.mainMenu, NSApp.windowsMenu, NSApp.servicesMenu)
        defer { NSApp.mainMenu = original.0; NSApp.windowsMenu = original.1; NSApp.servicesMenu = original.2 }
        let menus = CockpitMenuController(windowProvider: { controller }, showMain: {}, toggleExtendo: {},
                                         showSettings: {}, showSetup: {}, checkForUpdates: {})
        menus.install()
        let items = flattened(try XCTUnwrap(NSApp.mainMenu))
        let terminal = try XCTUnwrap(items.first { $0.title == "New Terminal" } as? ShellMenuItem)
        XCTAssertEqual(terminal.keyEquivalent, "t")
        XCTAssertEqual(terminal.keyEquivalentModifierMask, .command)
        terminal.perform()
        let picker = try XCTUnwrap(window.firstResponder as? CockpitPaneModePicker)
        XCTAssertTrue(picker.pane.isChoosingMode)
        XCTAssertEqual(picker.pane.kind, .terminal)
        let browser = try XCTUnwrap(items.first { $0.title == "New Browser" } as? ShellMenuItem)
        XCTAssertEqual(browser.keyEquivalent, "b")
        XCTAssertEqual(browser.keyEquivalentModifierMask, .command)
        browser.perform()
        let pane = try XCTUnwrap(controller.selectedPane)
        XCTAssertEqual(pane.browserState?.engine, .webKit)
        XCTAssertFalse(pane.isChoosingMode)
        let presentation = try XCTUnwrap(controller.paneController(for: pane) as? BrowserPaneViewController)
        XCTAssertTrue(presentation.children.first is BrowserStartPageViewController)
        let list = try XCTUnwrap(window.firstResponder as? NSTableView,
                                "Browser list should own focus; responder: \(String(describing: window.firstResponder))")
        XCTAssertEqual(list.accessibilityLabel(), "Local development servers")
        XCTAssertFalse(pane.browserState?.needsAddressFocus ?? true)
    }

    @MainActor
    func testLauncherMenusUseCurrentWorkspaceAndDisableRootDependentActions() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.store.addWorkspace()
        let first = try XCTUnwrap(fixture.store.selectedWorkspace)
        let launcher = WorkspacePaneLauncher(workspace: first)
        let group = launcher.makeToolbarItem(identifier: .init("fixture.launcher"))
        let terminal = try XCTUnwrap(group.subitems.first { $0.label == "Terminal" })
        XCTAssertFalse(group.subitems.contains { $0 is NSMenuToolbarItem })
        let editor = try XCTUnwrap(group.subitems.first { $0.label == "Editor" })
        XCTAssertFalse(editor.isEnabled)
        fixture.store.addWorkspace(directory: URL(fileURLWithPath: "/tmp"))
        let second = try XCTUnwrap(fixture.store.selectedWorkspace)
        second.rootPath = "/tmp"
        launcher.workspace = second
        XCTAssertTrue(editor.isEnabled)
        let firstCount = first.panes.count
        let secondCount = second.panes.count
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(terminal.action), to: terminal.target, from: terminal))
        XCTAssertEqual(first.panes.count, firstCount)
        XCTAssertEqual(second.panes.count, secondCount + 1)
        XCTAssertFalse(group.subitems.contains { $0.label == "Agent Chat" })
        XCTAssertEqual(second.selectedPane?.kind, .terminal)
        XCTAssertTrue(second.selectedPane?.isChoosingMode == true)
        for (title, kind) in [("Browser", PaneKind.browser), ("Apple", .simulator), ("Android", .android)] {
            let item = try XCTUnwrap(group.subitems.first { $0.label == title })
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
            XCTAssertEqual(second.selectedPane?.kind, kind)
            XCTAssertEqual(second.selectedPane?.isChoosingMode, kind != .browser)
        }
        let terminalMenu = try XCTUnwrap(launcher.makeMenu().items.first { $0.title == "Terminal" }?.submenu)
        XCTAssertTrue(terminalMenu.items.contains { $0.title == "Agentic Terminal" })
        launcher.workspace = nil
        XCTAssertFalse(group.isEnabled)
        XCTAssertTrue(group.subitems.allSatisfy { !$0.isEnabled })
        XCTAssertTrue(launcher.makeMenu().items.isEmpty)
    }

    @MainActor
    func testToolPaneLayoutsAndCompactWorkspaceSheet() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cockpit-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (index, name) in ["app", "pro", "docs", "analytics", "a-project-with-a-long-name"].enumerated() {
            let folder = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: ["name": name, "scripts": ["dev": "vite --port \(55_000 + index)"]])
            try data.write(to: folder.appendingPathComponent("package.json"))
        }
        fixture.store.addWorkspace(directory: directory)
        let workspace = try XCTUnwrap(fixture.store.selectedWorkspace)
        workspace.name = "Design Preview"
        workspace.setRootPath(directory.path)
        let browser = try XCTUnwrap(workspace.selectedPane)
        browser.kind = .browser
        browser.browserState = BrowserState()
        workspace.addPane(kind: .simulator, side: .right)
        workspace.addPane(kind: .android, side: .right)
        var browserController: BrowserPaneViewController?
        let controller = fixture.window { pane, _ in
            if pane.kind == .browser {
                let controller = BrowserPaneViewController(pane: pane)
                browserController = controller
                return controller
            }
            let view = CaptureDevicePicker()
            view.update(title: pane.kind == .android ? "Android Devices" : "Apple Devices", refreshing: false,
                        refresh: {}, actions: pane.kind == .android ? [] : [CapturePaneAction(title: "Share Wirelessly…", symbol: "airplay.video", perform: {})],
                        items: [CapturePickerItem(id: "fixture", title: "Development Device", detail: "Ready to connect", symbol: "iphone")])
            let child = NSViewController()
            child.view = view
            return child
        }
        let window = try XCTUnwrap(controller.window)
        controller.showWindow(nil)
        defer { window.orderOut(nil); controller.windowWillClose(Notification(name: NSWindow.willCloseNotification)) }
        func capture(_ view: NSView, _ name: String) throws {
            guard let destination = ProcessInfo.processInfo.environment["MADE_TOOL_REVIEW_OUTPUT"] else { return }
            let output = URL(fileURLWithPath: destination)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
        }
        try await Task.sleep(for: .milliseconds(250))
        for width in [1000.0, 1440.0] {
            window.setContentSize(NSSize(width: width, height: 800))
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let root = try XCTUnwrap(window.contentView)
            let pickers = descendants(root).compactMap { $0 as? CockpitPaneModePicker }
            XCTAssertTrue(pickers.isEmpty, "Existing panes must use their saved mode without a permanent selector")
            let local = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTableView }.first { $0.accessibilityLabel() == "Local development servers" })
            // Drive this fixture's visibility explicitly: a hosted test must
            // not require the user to leave the test application frontmost.
            browserController?.updatePresentation(isActive: true, isSelected: false)
            let scanDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            while local.numberOfRows != 5, ContinuousClock.now < scanDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(local.numberOfRows, 5)
            let viewportWidth = local.enclosingScrollView?.contentSize.width ?? 0
            XCTAssertGreaterThan(local.tableColumns[0].width, viewportWidth - 24,
                                 "The single column should fill the viewport, allowing native row insets")
            XCTAssertLessThanOrEqual(local.tableColumns[0].width, viewportWidth)
            try capture(try XCTUnwrap(root.superview), "tool-panes-\(Int(width))")
        }
        var created: [URL?] = []
        let sheet = NewWorkspaceSheet(finder: DirectoryFinder(root: directory.path)) { created.append($0) }
        sheet.present(on: window)
        let sheetWindow = try XCTUnwrap(sheet.window)
        let content = try XCTUnwrap(sheetWindow.contentView)
        content.layoutSubtreeIfNeeded()
        XCTAssertLessThan(content.bounds.height, 400)
        let compactHeight = content.bounds.height
        let selectedCard = try XCTUnwrap(descendants(content).first { $0.accessibilityIdentifier() == "workspace.selected-folder" })
        let folderName = try XCTUnwrap(descendants(selectedCard).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Home Folder" })
        XCTAssertGreaterThan(folderName.bounds.width, 150)
        let search = try XCTUnwrap(descendants(content).compactMap { $0 as? NSSearchField }.first)
        let originalZoom = CockpitUIZoomController.shared.factor
        defer { CockpitUIZoomController.shared.factor = originalZoom }
        for zoom in [0.85, 1.0, 2.0, 1.0] {
            CockpitUIZoomController.shared.factor = zoom
            let zoomDeadline = ContinuousClock.now.advanced(by: .seconds(1))
            while search.font?.pointSize != 13 * zoom, ContinuousClock.now < zoomDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            content.layoutSubtreeIfNeeded()
            XCTAssertEqual(folderName.font?.pointSize, 13 * zoom)
            for control in descendants(content).compactMap({ $0 as? NSControl }).filter({ !$0.isHiddenOrHasHiddenAncestor }) {
                XCTAssertTrue(content.bounds.contains(control.convert(control.bounds, to: content)),
                              "Visible controls must fit at \(zoom) zoom: \(control)")
                if let label = control as? CockpitLabel {
                    let font = try XCTUnwrap(label.font)
                    let textHeight = (label.stringValue as NSString).size(withAttributes: [.font: font]).height
                    XCTAssertGreaterThanOrEqual(label.bounds.height + 1, textHeight)
                }
            }
            try capture(content, "new-workspace-zoom-\(zoom)")
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            sheetWindow.appearance = NSAppearance(named: appearance)
            content.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(folderName.bounds.width, 150)
            for button in descendants(content).compactMap({ $0 as? NSButton }).filter({ !$0.isHiddenOrHasHiddenAncestor }) {
                XCTAssertTrue(content.bounds.contains(button.convert(button.bounds, to: content)))
            }
            try capture(content, "new-workspace-\(appearance.rawValue)")
        }
        search.stringValue = "app"
        sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        let results = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while results.numberOfRows == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        content.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(results.numberOfRows, 0)
        XCTAssertGreaterThan(content.bounds.height, compactHeight)
        // Typing pauses fire the search field's action; that must only filter.
        _ = search.sendAction(search.action, to: search.target)
        XCTAssertTrue(created.isEmpty, "Typing a query must not create a workspace")
        XCTAssertNotNil(sheet.window?.sheetParent, "The sheet stays open while searching")
        try capture(content, "new-workspace-results")
        CockpitUIZoomController.shared.factor = 2
        let expandedDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while results.rowHeight != 88, ContinuousClock.now < expandedDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(search.stringValue, "app")
        XCTAssertGreaterThanOrEqual(results.selectedRow, 0)
        try capture(content, "new-workspace-results-zoom-2")
        let create = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }.first { $0.title == "Create" })
        XCTAssertTrue(content.bounds.contains(create.convert(create.bounds, to: content)))
        create.performClick(nil)
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(try XCTUnwrap(created.first ?? nil).lastPathComponent, "app")
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
            switch mode {
            case .notes: NotesViewController(store: store, defaults: defaults)
            case .remoteDesktop: RemoteDesktopViewController(store: store, isLive: false)
            default: nil
            }
        })
    }
    func cleanUp() { cache.closeAll(); defaults.removePersistentDomain(forName: defaultsName) }
}

@MainActor
private final class SplitWidthSamples {
    var widths: [CGFloat] = []
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
