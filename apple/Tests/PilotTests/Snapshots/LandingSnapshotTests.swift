import AppKit
import XCTest
@testable import Pilot

final class LandingSnapshotTests: XCTestCase {
    func testCatalogOptions() throws {
        let defaults = try SnapshotOptions(environment: [:])
        XCTAssertEqual(defaults.scenes.count, 13)
        XCTAssertEqual(defaults.appearances, ["light", "dark"])
        XCTAssertEqual(defaults.scale, 2)
        let filtered = try SnapshotOptions(environment: ["MADE_SNAPSHOT_SCENES": "notes,actions", "MADE_SNAPSHOT_APPEARANCE": "dark"])
        XCTAssertEqual(filtered.scenes, [.notes, .actions])
        XCTAssertEqual(filtered.appearances, ["dark"])
        for options in [["MADE_SNAPSHOT_SCENES": "notes,typo"], ["MADE_SNAPSHOT_SCENES": "notes,notes"],
                        ["MADE_SNAPSHOT_SCENES": ""], ["MADE_SNAPSHOT_APPEARANCE": "sepia"],
                        ["MADE_SNAPSHOT_WIDTH": "0"], ["MADE_SNAPSHOT_SCALE": "3"]] {
            XCTAssertThrowsError(try SnapshotOptions(environment: options))
        }
    }

    @MainActor
    func testFixturesArePopulatedAndIsolated() async throws {
        let original = UserDefaults.standard.object(forKey: "selectedNoteID") as? String
        let fixtures = try SnapshotFixtures()
        defer { fixtures.close() }
        try await fixtures.prepare()
        XCTAssertEqual(fixtures.workspace.workspaces.count, 7)
        XCTAssertEqual(fixtures.workspace.notes.count, 4)
        XCTAssertEqual(fixtures.docker.containers.count, 8)
        XCTAssertEqual(fixtures.runners.snapshot.runners.count, 8)
        XCTAssertEqual(Set(fixtures.runners.snapshot.runners.map(\.state)), [.idle, .busy, .offline])
        XCTAssertFalse(fixtures.tasks.tasks.isEmpty)
        XCTAssertFalse(fixtures.repository.actions.isEmpty)
        XCTAssertFalse(fixtures.repository.pullRequests.isEmpty)
        XCTAssertFalse(fixtures.history.isEmpty)
        XCTAssertEqual(fixtures.history.dayTotals.count, 30)
        XCTAssertEqual(fixtures.history.totalCostUSD, fixtures.history.modelTotals.reduce(0) { $0 + $1.cost }, accuracy: 0.001)
        guard case .usage = fixtures.usage.openAI else { return XCTFail("Missing plan fixture") }
        XCTAssertEqual(UserDefaults.standard.object(forKey: "selectedNoteID") as? String, original)
    }

    @MainActor
    func testNativeDesignReviewScreenshots() async throws {
        guard let destination = ProcessInfo.processInfo.environment["MADE_NATIVE_REVIEW_OUTPUT"] else {
            throw XCTSkip("Set MADE_NATIVE_REVIEW_OUTPUT to capture the production window for design review")
        }
        let directory = URL(fileURLWithPath: destination, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixtures = try SnapshotFixtures()
        defer { fixtures.close() }
        try await fixtures.prepare()
        // The CPU bitmap capture cannot include SceneKit's Metal surface.
        fixtures.defaults.set("compact", forKey: "runners.layout")
        for index in 1...3 {
            fixtures.container.mainContext.insert(RemoteDesktopConnection(
                host: "mini-m4-0\(index).example.test", nickname: "Build Mac \(index)", username: "developer", sortOrder: index))
        }
        let cache = CockpitPaneControllerCache()
        defer { cache.closeAll() }
        let shell = CockpitWindowController(
            store: fixtures.workspace, extensionController: ExtensionWorkspaceController(modelContext: fixtures.container.mainContext),
            surface: .main, defaults: fixtures.defaults, isLive: false, paneCache: cache,
            paneFactory: { _, _ in
                let controller = NSViewController()
                controller.view = SnapshotTerminal(variant: .agent)
                return controller
            }, globalFactory: { mode in
                switch mode {
                case .notes: return NotesViewController(store: fixtures.workspace, defaults: fixtures.defaults)
                case .remoteDesktop: return RemoteDesktopViewController(store: fixtures.workspace, isLive: false)
                case .docker: return DockerViewController(store: fixtures.docker)
                case .runners: return RunnersViewController(store: fixtures.runners, defaults: fixtures.defaults, isLive: false)
                case .agenticUse:
                    let controller = NSViewController()
                    controller.view = SnapshotDashboardScrollView(dashboard: AgenticUseDashboard(
                        snapshot: fixtures.history, pricingStatus: "Fixture pricing — Oct 23, 2026"))
                    return controller
                default: return nil
                }
            })
        let workspace = try XCTUnwrap(fixtures.workspace.workspaces.first)
        shell.inspectorFactory = { workspace in
            InspectorViewController(workspace: workspace, usageStore: fixtures.usage,
                                    gitStore: fixtures.repository, tasksStore: fixtures.tasks,
                                    defaults: fixtures.defaults, isLive: false)
        }
        let scenes: [(String, SidebarSelection)] = [
            ("workspace", .workspace(workspace.id)), ("notes", .notes), ("remote-desktop", .remoteDesktop),
            ("docker", .docker), ("agentic-use", .agenticUse), ("runners", .runners),
        ]
        let window = try XCTUnwrap(shell.window)
        shell.showWindow(nil)
        defer { window.orderOut(nil); shell.windowWillClose(Notification(name: NSWindow.willCloseNotification)) }
        func capture(_ frame: NSView, name: String) throws {
            frame.layoutSubtreeIfNeeded()
            frame.displayIfNeeded()
            let bitmap = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
            frame.effectiveAppearance.performAsCurrentDrawingAppearance {
                frame.cacheDisplay(in: frame.bounds, to: bitmap)
            }
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for (scene, selection) in scenes {
            shell.select(selection)
            if scene == "workspace" {
                shell.toggleInspector()
                for tab in descendants(try XCTUnwrap(window.contentView)).compactMap({ $0 as? CockpitPaneTab }) {
                    tab.updateStatus(agentName: nil, isDirty: true)
                }
            }
            for width in [1000, 1440] {
                for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                    window.appearance = NSAppearance(named: appearance)
                    window.setContentSize(NSSize(width: width, height: 960))
                    let frame = try XCTUnwrap(window.contentView?.superview)
                    frame.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(180))
                    try capture(frame, name: "\(scene)-\(width)-\(name)")
                }
            }
        }
        // Production toolbar views and collapsed panes, with inert fixture actions.
        shell.select(.workspace(workspace.id))
        workspace.inspectorTab = .tasks
        shell.refresh()
        try await Task.sleep(for: .milliseconds(100))
        try capture(try XCTUnwrap(window.contentView?.superview), name: "inspector-task-cards")
        shell.featureToolbarFactory = { pane in
            if pane.kind == .browser, let state = pane.browserState { return BrowserToolbarView(state: state) }
            let toolbar = CaptureToolbarView()
            toolbar.update([
                CapturePaneAction(title: "Record", symbol: "record.circle", perform: {}),
                CapturePaneAction(title: "Screenshot", symbol: "camera", perform: {}),
                CapturePaneAction(title: "Clipboard", symbol: "clipboard", perform: {}),
                CapturePaneAction(title: "Devices", symbol: "list.bullet", perform: {}),
                CapturePaneAction(title: "Share", symbol: "airplayvideo", perform: {}),
                CapturePaneAction(title: "Build", symbol: "hammer", perform: {})
            ])
            return toolbar
        }
        let collapsed = try XCTUnwrap(workspace.sortedPanes.first)
        for kind: PaneKind in [.device, .browser] {
            let pane = workspace.addPane(kind: kind, side: .right)
            workspace.collapsePane(collapsed)
            shell.refresh()
            window.appearance = NSAppearance(named: .darkAqua)
            window.setContentSize(NSSize(width: 1800, height: 960))
            let frame = try XCTUnwrap(window.contentView?.superview)
            frame.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(180))
            try capture(frame, name: "toolbar-\(kind.rawValue)-collapsed-pane")
            _ = workspace.removePane(pane)
            shell.refresh()
        }
        shell.featureToolbarFactory = nil
        let opening = workspace.addPane(kind: .terminal, side: .right, chooseModeOnOpen: true)
        shell.refresh()
        let picker = try XCTUnwrap(descendants(try XCTUnwrap(window.contentView)).compactMap { $0 as? CockpitNewTabView }.first)
        try capture(picker, name: "new-tab-placeholder")
        _ = workspace.removePane(opening)
        shell.refresh()

        let number = AgenticUseNumericTextField(labelWithString: "")
        number.font = CockpitTypography.font(.metric)
        number.frame = NSRect(x: 20, y: 30, width: 360, height: 32)
        let numberWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        numberWindow.isReleasedWhenClosed = false
        numberWindow.appearance = NSAppearance(named: .darkAqua)
        let numberRoot = try XCTUnwrap(numberWindow.contentView)
        numberRoot.addSubview(number)
        number.prepareTransition(to: "$188,919.28", countsDown: false)
        try capture(numberRoot, name: "numeric-text-before")
        number.prepareTransition(to: "$288,919.38", countsDown: false)
        for progress in [0.0, 0.5, 1.0] {
            number.setTransitionProgress(progress)
            try capture(numberRoot, name: "numeric-text-\(progress)")
        }
        numberWindow.close()
        // Walk the edit -> delete -> cancel/confirm flow using only fixture data.
        // Keep the edit fixture independent of application activation and the
        // shell's occlusion handling while the user works in another window.
        let notes = NotesViewController(store: fixtures.workspace, defaults: fixtures.defaults)
        let notesWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        notesWindow.isReleasedWhenClosed = false
        notesWindow.contentViewController = notes
        notesWindow.orderFront(nil)
        notes.updatePresentation(isActive: true, isSelected: true)
        defer { notes.updatePresentation(isActive: false, isSelected: false); notesWindow.close() }
        let note = fixtures.workspace.addNote()
        fixtures.workspace.selectedNoteID = note.id
        notes.refresh()
        let editor = try XCTUnwrap(descendants(notes.view).compactMap { $0 as? NoteTextView }.first)
        editor.textView.insertText("Design review fixture note", replacementRange: NSRange(location: 0, length: 0))
        notes.flushPendingSave()
        XCTAssertEqual(note.body, "Design review fixture note")
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            notesWindow.appearance = NSAppearance(named: appearance)
            notes.closeSelectedNote()
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while notesWindow.attachedSheet == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let sheet = try XCTUnwrap(notesWindow.attachedSheet)
            try capture(try XCTUnwrap(sheet.contentView?.superview), name: "notes-delete-\(name)")
            XCTAssertTrue(descendants(try XCTUnwrap(sheet.contentView)).compactMap { $0 as? NSButton }.contains { $0.title == "Delete Note" })
            notesWindow.endSheet(sheet, returnCode: .alertSecondButtonReturn)
            let dismissalDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while fixtures.workspace.notePendingClose != nil, ContinuousClock.now < dismissalDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(fixtures.workspace.notes.contains { $0.id == note.id })
        }
        notes.closeSelectedNote()
        let sheet = try XCTUnwrap(notesWindow.attachedSheet)
        notesWindow.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        let deletionDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while fixtures.workspace.notes.contains(where: { $0.id == note.id }), ContinuousClock.now < deletionDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(fixtures.workspace.notes.contains { $0.id == note.id })
    }

    @MainActor
    func testCaptureCatalog() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let destination = environment["MADE_SNAPSHOT_OUTPUT"] else {
            throw XCTSkip("Run apple/bin/capture-pilot-scenes.py to export landing-page scenes")
        }
        let options = try SnapshotOptions(environment: environment)
        let directory = URL(fileURLWithPath: destination, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixtures = try SnapshotFixtures()
        defer { fixtures.close() }
        try await fixtures.prepare()
        var assets: [SnapshotAsset] = []
        for scene in options.scenes {
            for appearance in options.appearances {
                let name = "cockpit-\(scene.rawValue)-\(appearance).png"
                let data = try await render(scene, appearance: appearance, fixtures: fixtures, options: options)
                try data.write(to: directory.appendingPathComponent(name), options: .atomic)
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
                assets.append(SnapshotAsset(scene: scene.rawValue, appearance: appearance, file: name,
                                            width: options.width * options.scale, height: options.height * options.scale,
                                            scale: options.scale, alt: "Cockpit — \(scene.caption.lowercased()) (\(appearance) mode)"))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifest = SnapshotManifest(version: 1, fixtureDate: "2026-10-23", assets: assets)
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        XCTAssertEqual(assets.count, options.scenes.count * options.appearances.count)
    }

    @MainActor
    private func render(
        _ scene: SnapshotScene, appearance: String, fixtures: SnapshotFixtures, options: SnapshotOptions
    ) async throws -> Data {
        let size = NSSize(width: options.width, height: options.height)
        let controller = SnapshotWorkbench(scene: scene, fixtures: fixtures)
        let host = controller.view
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        let priorAppearance = NSApp.appearance
        NSApp.appearance = window.appearance
        defer {
            window.close()
            NSApp.appearance = priorAppearance
        }
        host.layoutSubtreeIfNeeded()
        // Let native controllers and scroll views finish their first layout.
        // Data readiness was checked separately; this is not a network timeout.
        try await Task.sleep(for: .milliseconds(180))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.bounds.width, size.width, accuracy: 1)
        XCTAssertEqual(host.bounds.height, size.height, accuracy: 1)
        host.displayIfNeeded()
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: options.width * options.scale,
            pixelsHigh: options.height * options.scale, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw SnapshotError.renderFailed("Could not allocate \(scene.rawValue)") }
        bitmap.size = size
        window.appearance?.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        guard let png = bitmap.representation(using: .png, properties: [:]), png.count > 10_000 else {
            throw SnapshotError.renderFailed("Empty capture: \(scene.rawValue)")
        }
        XCTAssertEqual(bitmap.pixelsWide, options.width * options.scale)
        XCTAssertEqual(bitmap.pixelsHigh, options.height * options.scale)
        return png
    }
}

private struct SnapshotManifest: Encodable {
    let version: Int
    let fixtureDate: String
    let assets: [SnapshotAsset]
}

private struct SnapshotAsset: Encodable {
    let scene: String
    let appearance: String
    let file: String
    let width: Int
    let height: Int
    let scale: Int
    let alt: String
}
