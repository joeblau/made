import Foundation
import SwiftData
import Testing
import AppKit
@testable import Pilot

@Suite("Extension window workspace sync", .serialized)
@MainActor
struct ExtensionWindowSyncTests {
    @Test("Extendo monitor routes only its window-local shortcut")
    func shortcutRouting() {
        #expect(ExtensionWindowShortcut.match(
            modifierFlags: [.command, .shift],
            characters: "d"
        ) == .toggleDrawing)
    }

    @Test("Extendo shortcuts reject conflicting modifiers")
    func shortcutRoutingRejectsConflicts() {
        #expect(ExtensionWindowShortcut.match(modifierFlags: .command, characters: "t") == nil)
        #expect(ExtensionWindowShortcut.match(modifierFlags: .command, characters: "w") == nil)
        #expect(ExtensionWindowShortcut.match(modifierFlags: .command, characters: "b") == nil)
        #expect(ExtensionWindowShortcut.match(
            modifierFlags: [.command, .option],
            characters: "e"
        ) == nil)
    }

    private enum InjectedFailure: Error {
        case unavailable
    }

    @Test("Close-menu installer finds only stock performClose items")
    func closeMenuInstallerScan() {
        let menu = NSMenu()
        let closeItem = NSMenuItem(
            title: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        // Same shortcut but a different action — the main window's own ⌘W
        // pane/note command must never be stripped.
        let otherAction = NSMenuItem(title: "Close Pane", action: nil, keyEquivalent: "w")
        let otherShortcut = NSMenuItem(
            title: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        let nestedClose = NSMenuItem(
            title: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        let submenu = NSMenu()
        submenu.addItem(nestedClose)
        let parent = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        parent.submenu = submenu

        for item in [closeItem, otherAction, otherShortcut, parent] {
            menu.addItem(item)
        }

        let found = PilotWindowCloseMenuInstaller.stockCloseMenuItems(in: menu)
        #expect(Set(found) == Set([closeItem, nestedClose]))
    }

    @Test("Extension launch always restores the singleton main window")
    func extensionLaunchRequiresMainWindow() {
        #expect(PilotWindowID.main != PilotWindowID.extendo)
        #expect(PilotWindowID.extendo == "pilot-extendo")
        #expect(PilotWindowID.extendoTitle == "Extendo")
        #expect(PilotWindowLaunchPolicy.opensByDefault(PilotWindowID.main))
        #expect(PilotWindowLaunchPolicy.opensByDefault(PilotWindowID.extendo))
        #expect(
            PilotWindowLaunchPolicy.requiredCompanion(for: PilotWindowID.extendo)
                == PilotWindowID.main
        )
        #expect(PilotWindowLaunchPolicy.requiredCompanion(for: PilotWindowID.main) == nil)
    }

    @Test("Remote input follows the active Cockpit window")
    func remoteInputWindowRouting() {
        let mainWindowID: CGWindowID = 41
        let extensionWindowID: CGWindowID = 82

        #expect(PilotRemoteInputRoutingPolicy.surface(
            activeWindowID: mainWindowID,
            mainWindowID: mainWindowID,
            extensionWindowID: extensionWindowID
        ) == .main)
        #expect(PilotRemoteInputRoutingPolicy.surface(
            activeWindowID: extensionWindowID,
            mainWindowID: mainWindowID,
            extensionWindowID: extensionWindowID
        ) == .extension)
        #expect(PilotRemoteInputRoutingPolicy.surface(
            activeWindowID: 123,
            mainWindowID: mainWindowID,
            extensionWindowID: extensionWindowID
        ) == nil)
        #expect(PilotRemoteInputRoutingPolicy.surface(
            activeWindowID: nil,
            mainWindowID: mainWindowID,
            extensionWindowID: extensionWindowID
        ) == nil)
    }

    @Test("Remote input selects the active window's selected terminal pane")
    func remoteInputPaneRouting() throws {
        let mainWorkspace = Workspace(name: "Main")
        let mainTerminal = try #require(mainWorkspace.frontmostTerminalPane)

        let extensionWorkspace = Workspace(name: "Extendo")
        let previousExtensionTerminal = try #require(extensionWorkspace.frontmostTerminalPane)
        let selectedExtensionTerminal = extensionWorkspace.addPane(kind: .terminal, side: .right)
        // Model a selection change that reached the pane model before AppKit's
        // first-responder callback updated the remembered terminal.
        extensionWorkspace.frontmostTerminalPaneID = previousExtensionTerminal.id
        extensionWorkspace.selectedPaneID = selectedExtensionTerminal.id

        #expect(PilotRemoteInputRoutingPolicy.terminalPane(
            on: .main,
            mainWorkspace: mainWorkspace,
            extensionWorkspace: extensionWorkspace
        )?.id == mainTerminal.id)
        #expect(PilotRemoteInputRoutingPolicy.terminalPane(
            on: .extension,
            mainWorkspace: mainWorkspace,
            extensionWorkspace: extensionWorkspace
        )?.id == selectedExtensionTerminal.id)
        // Never cross-fall back into Main when Extendo is active but has no
        // corresponding workspace/terminal surface.
        #expect(PilotRemoteInputRoutingPolicy.terminalPane(
            on: .extension,
            mainWorkspace: mainWorkspace,
            extensionWorkspace: nil
        ) == nil)
    }

    @Test("Main workspace selection is immediately visible to extension")
    func mainSelectionDrivesExtension() throws {
        let defaults = DefaultsSnapshot()
        defer { defaults.restore() }
        let fixture = try makeFixture()

        // These aliases model the references injected into the two sibling
        // SwiftUI scenes. There must be one canonical store, not two stores
        // synchronized after the fact.
        let mainWindowStore = fixture.store
        let extensionWindowStore = fixture.store

        mainWindowStore.selectWorkspace(fixture.alpha.id)
        #expect(extensionWindowStore.selectedWorkspace?.id == fixture.alpha.id)

        mainWindowStore.selectWorkspace(fixture.beta.id)
        #expect(extensionWindowStore.selectedWorkspace?.id == fixture.beta.id)
    }

    @Test("⌘1 through ⌘9 use the shared visible workspace order")
    func numberedWorkspaceShortcuts() {
        let workspaceIDs = (0..<10).map { _ in UUID() }
        let shortcuts = WorkspaceNumberShortcuts.shortcuts(for: workspaceIDs)

        #expect(shortcuts.map(\.number) == Array(1...9))
        #expect(shortcuts.map(\.workspaceID) == Array(workspaceIDs.prefix(9)))
        #expect(WorkspaceNumberShortcuts.shortcuts(for: []).isEmpty)
        #expect(WorkspaceNumberShortcuts.shortcuts(for: [workspaceIDs[0]]).map(\.number) == [1])
    }

    @Test("Browser toolbar resolves the selected window's own browser state")
    func browserToolbarSelectionIsPaneLocal() throws {
        let mainBrowser = Pane(kind: .browser)
        let extensionBrowser = Pane(kind: .browser)
        let mainState = try #require(mainBrowser.browserState)
        let extensionState = try #require(extensionBrowser.browserState)

        #expect(BrowserToolbarSelection.state(for: mainBrowser) === mainState)
        #expect(BrowserToolbarSelection.state(for: extensionBrowser) === extensionState)
        #expect(BrowserToolbarSelection.state(for: extensionBrowser) !== mainState)

        extensionBrowser.isCollapsed = true
        #expect(BrowserToolbarSelection.state(for: extensionBrowser) == nil)

        for kind in PaneKind.allCases where kind != .browser {
            #expect(BrowserToolbarSelection.state(for: Pane(kind: kind)) == nil)
        }
        #expect(BrowserToolbarSelection.state(for: nil) == nil)
    }

    @Test("⌘L reveals a collapsed browser and preserves focused-pane mode")
    func browserAddressCommandRevealsBrowser() throws {
        let workspace = Workspace(name: "Browser Command")
        let terminal = try #require(workspace.selectedPane)
        workspace.addPane(kind: .browser, side: .right)
        let browser = try #require(workspace.selectedPane)
        let browserState = try #require(browser.browserState)
        workspace.collapsePane(browser)
        workspace.focusPane(terminal)

        #expect(browser.isCollapsed)
        #expect(workspace.focusedPaneID == terminal.id)
        #expect(BrowserCommandSelection.revealBrowser(in: workspace) === browserState)
        #expect(!browser.isCollapsed)
        #expect(workspace.selectedPaneID == browser.id)
        #expect(workspace.focusedPaneID == browser.id)

        // Repeating ⌘L must not toggle focused-pane mode back off.
        #expect(BrowserCommandSelection.revealBrowser(in: workspace) === browserState)
        #expect(workspace.focusedPaneID == browser.id)

        let terminalOnly = Workspace(name: "No Browser")
        #expect(!BrowserCommandSelection.hasBrowser(in: terminalOnly))
        #expect(BrowserCommandSelection.revealBrowser(in: terminalOnly) == nil)
    }

    @Test("Extension panes inherit source metadata without reusing main pane IDs")
    func extensionPanesAreIsolatedFromMainWorkspace() throws {
        let defaults = DefaultsSnapshot()
        defer { defaults.restore() }
        let fixture = try makeFixture()
        fixture.alpha.setRootPath("/tmp/alpha")
        let mainPaneIDs = Set(fixture.alpha.panes.map(\.id))
        let mainPaneCount = fixture.alpha.panes.count
        let controller = ExtensionWorkspaceController(modelContext: fixture.container.mainContext)

        controller.synchronize(with: fixture.alpha)
        let extensionWorkspace = try #require(controller.selectedWorkspace)
        #expect(extensionWorkspace !== fixture.alpha)
        #expect(extensionWorkspace.name == fixture.alpha.name)
        #expect(extensionWorkspace.effectiveRootPath == fixture.alpha.effectiveRootPath)
        #expect(extensionWorkspace.sortedPanes.first?.currentDirectory == "/tmp/alpha")
        #expect(mainPaneIDs.isDisjoint(with: extensionWorkspace.panes.map(\.id)))

        for kind in PaneKind.allCases {
            extensionWorkspace.addPane(kind: kind, side: .right)
        }

        #expect(fixture.alpha.panes.count == mainPaneCount)
        #expect(Set(extensionWorkspace.panes.map(\.kind)).isSuperset(of: PaneKind.allCases))
        #expect(mainPaneIDs.isDisjoint(with: extensionWorkspace.panes.map(\.id)))
    }

    @Test("Extension follows main selection and preserves a separate layout per source")
    func extensionSelectionSwitchesSourceProjection() throws {
        let defaults = DefaultsSnapshot()
        defer { defaults.restore() }
        let fixture = try makeFixture()
        let controller = ExtensionWorkspaceController(modelContext: fixture.container.mainContext)

        controller.synchronize(with: fixture.alpha)
        let alphaExtension = try #require(controller.selectedWorkspace)
        alphaExtension.addPane(kind: .browser, side: .right)
        alphaExtension.setInspectorPresented(true)
        alphaExtension.setInspectorTab(.filesystem)
        #expect(!fixture.alpha.isInspectorPresented)

        controller.synchronize(with: fixture.beta)
        let betaExtension = try #require(controller.selectedWorkspace)
        #expect(betaExtension !== alphaExtension)
        #expect(betaExtension.name == "Beta")
        #expect(!betaExtension.isInspectorPresented)
        #expect(betaExtension.inspectorTab == .actions)

        controller.synchronize(with: fixture.alpha)
        #expect(controller.selectedWorkspace === alphaExtension)
        #expect(alphaExtension.sortedPanes.map(\.kind) == [.terminal, .browser])
        #expect(alphaExtension.isInspectorPresented)
        #expect(alphaExtension.inspectorTab == .filesystem)
    }

    @Test("Extension companion panes persist and stay hidden from Main")
    func extensionCompanionPersistsOutsideCanonicalWorkspaceList() throws {
        let defaults = DefaultsSnapshot()
        defer { defaults.restore() }
        let fixture = try makeFixture()
        let controller = ExtensionWorkspaceController(modelContext: fixture.container.mainContext)

        controller.synchronize(with: fixture.alpha)
        let extensionWorkspace = try #require(controller.selectedWorkspace)
        extensionWorkspace.axis = .horizontal
        extensionWorkspace.addPane(kind: .browser, side: .right)
        let browser = try #require(extensionWorkspace.selectedPane)
        browser.browserState?.urlText = "https://example.com/persisted"
        browser.sizeFraction = 0.42
        extensionWorkspace.addPane(kind: .editor, side: .right)
        let editor = try #require(extensionWorkspace.selectedPane)
        editor.editorState?.filePath = "/tmp/persisted.swift"
        editor.isCollapsed = true
        extensionWorkspace.setInspectorPresented(true)
        extensionWorkspace.setInspectorTab(.filesystem)
        try fixture.container.mainContext.save()

        let persistedWorkspaceID = extensionWorkspace.id
        let persistedPaneIDs = extensionWorkspace.sortedPanes.map(\.id)
        let canonicalIDs = Set([fixture.alpha.id, fixture.beta.id])
        #expect(Set(fixture.store.workspaces.map(\.id)) == canonicalIDs)
        #expect(Set(fixture.store.summaries.map(\.id)) == canonicalIDs)

        let reloadedContext = ModelContext(fixture.container)
        let reloadedSource = try #require(
            try reloadedContext.fetch(FetchDescriptor<Workspace>()).first { $0.id == fixture.alpha.id }
        )
        let reloadedController = ExtensionWorkspaceController(modelContext: reloadedContext)
        reloadedController.synchronize(with: reloadedSource)
        let restored = try #require(reloadedController.selectedWorkspace)

        #expect(restored.id == persistedWorkspaceID)
        #expect(restored.sortedPanes.map(\.id) == persistedPaneIDs)
        #expect(restored.axis == .horizontal)
        #expect(restored.sortedPanes.first(where: { $0.kind == .browser })?.browserState?.urlText
            == "https://example.com/persisted")
        #expect(restored.sortedPanes.first(where: { $0.kind == .browser })?.sizeFraction == 0.42)
        #expect(restored.sortedPanes.first(where: { $0.kind == .editor })?.editorState?.filePath
            == "/tmp/persisted.swift")
        #expect(restored.sortedPanes.first(where: { $0.kind == .editor })?.isCollapsed == true)
        #expect(restored.isInspectorPresented)
        #expect(restored.inspectorTab == .filesystem)
    }

    @Test("Pruning an orphaned companion invalidates Main's workspace cache")
    func orphanCleanupCannotExposeACompanionInMain() throws {
        let defaults = DefaultsSnapshot()
        defer { defaults.restore() }
        let fixture = try makeFixture()
        let orphan = Workspace(name: "Hidden Orphan")
        let orphanDevice = Pane(kind: .device)
        orphan.panes = [orphanDevice]
        orphanDevice.workspace = orphan
        let orphanLink = ExtensionWorkspaceLink(sourceWorkspaceID: UUID(), workspace: orphan)
        fixture.container.mainContext.insert(orphan)
        fixture.container.mainContext.insert(orphanLink)
        try fixture.container.mainContext.save()
        let preferenceKey = DeviceCaptureSession.preferenceKey(for: orphanDevice.id)
        let preferenceNameKey = DeviceCaptureSession.preferenceNameKey(for: orphanDevice.id)
        UserDefaults.standard.set("orphan-device", forKey: preferenceKey)
        UserDefaults.standard.set("Orphan iPhone", forKey: preferenceNameKey)
        defer { DeviceCaptureRegistry.shared.remove(paneID: orphanDevice.id) }
        _ = DeviceCaptureRegistry.shared.session(for: orphanDevice.id)

        fixture.store.extensionWorkspaceMembershipDidChange()
        #expect(Set(fixture.store.workspaces.map(\.id)) == Set([fixture.alpha.id, fixture.beta.id]))

        let controller = ExtensionWorkspaceController(
            modelContext: fixture.container.mainContext,
            onMembershipChange: { fixture.store.extensionWorkspaceMembershipDidChange() }
        )
        controller.reconcile(validSourceIDs: Set([fixture.alpha.id, fixture.beta.id]))

        #expect(Set(fixture.store.workspaces.map(\.id)) == Set([fixture.alpha.id, fixture.beta.id]))
        #expect(!fixture.store.workspaces.contains(where: { $0.name == "Hidden Orphan" }))
        let persistedIDs = Set(try fixture.container.mainContext.fetch(FetchDescriptor<Workspace>()).map(\.id))
        #expect(persistedIDs == Set([fixture.alpha.id, fixture.beta.id]))
        #expect(UserDefaults.standard.object(forKey: preferenceKey) == nil)
        #expect(UserDefaults.standard.object(forKey: preferenceNameKey) == nil)
    }

    @Test("Failed orphan cleanup preserves its device choice")
    func failedOrphanCleanupPreservesDevicePreference() throws {
        let defaults = DefaultsSnapshot()
        defer { defaults.restore() }
        let fixture = try makeFixture()
        let orphan = Workspace(name: "Failed Orphan")
        let device = Pane(kind: .device)
        orphan.panes = [device]
        device.workspace = orphan
        let link = ExtensionWorkspaceLink(sourceWorkspaceID: UUID(), workspace: orphan)
        fixture.container.mainContext.insert(orphan)
        fixture.container.mainContext.insert(link)
        try fixture.container.mainContext.save()

        let preferenceKey = DeviceCaptureSession.preferenceKey(for: device.id)
        let preferenceNameKey = DeviceCaptureSession.preferenceNameKey(for: device.id)
        UserDefaults.standard.set("failed-orphan-device", forKey: preferenceKey)
        UserDefaults.standard.set("Failed Orphan iPhone", forKey: preferenceNameKey)
        defer { DeviceCaptureRegistry.shared.remove(paneID: device.id) }
        let originalSession = DeviceCaptureRegistry.shared.session(for: device.id)

        let controller = ExtensionWorkspaceController(
            modelContext: fixture.container.mainContext,
            performSave: { _ in
                #expect(UserDefaults.standard.string(forKey: preferenceKey) == "failed-orphan-device")
                throw InjectedFailure.unavailable
            }
        )
        controller.reconcile(validSourceIDs: Set([fixture.alpha.id, fixture.beta.id]))

        #expect(UserDefaults.standard.string(forKey: preferenceKey) == "failed-orphan-device")
        #expect(UserDefaults.standard.string(forKey: preferenceNameKey) == "Failed Orphan iPhone")
        #expect(try fixture.container.mainContext.fetch(FetchDescriptor<Workspace>()).contains { $0.id == orphan.id })
        #expect(try fixture.container.mainContext.fetch(FetchDescriptor<ExtensionWorkspaceLink>()).contains {
            $0.sourceWorkspaceID == link.sourceWorkspaceID
        })
        let restoredSession = try #require(DeviceCaptureRegistry.shared.existingSession(for: device.id))
        #expect(restoredSession === originalSession)
        #expect(restoredSession.preferredDeviceUniqueID == "failed-orphan-device")
    }

    @Test("Failed duplicate cleanup preserves every device choice")
    func failedDuplicateCleanupPreservesDevicePreferences() throws {
        let defaults = DefaultsSnapshot()
        defer { defaults.restore() }
        let fixture = try makeFixture()
        let firstWorkspace = Workspace(name: "First duplicate")
        let firstDevice = Pane(kind: .device)
        firstWorkspace.panes = [firstDevice]
        firstDevice.workspace = firstWorkspace
        let secondWorkspace = Workspace(name: "Second duplicate")
        let secondDevice = Pane(kind: .device)
        secondWorkspace.panes = [secondDevice]
        secondDevice.workspace = secondWorkspace
        let firstLink = ExtensionWorkspaceLink(sourceWorkspaceID: fixture.alpha.id, workspace: firstWorkspace)
        let secondLink = ExtensionWorkspaceLink(sourceWorkspaceID: fixture.alpha.id, workspace: secondWorkspace)
        fixture.container.mainContext.insert(firstWorkspace)
        fixture.container.mainContext.insert(secondWorkspace)
        fixture.container.mainContext.insert(firstLink)
        fixture.container.mainContext.insert(secondLink)
        try fixture.container.mainContext.save()

        let deviceIDs = [firstDevice.id, secondDevice.id]
        defer { deviceIDs.forEach { DeviceCaptureRegistry.shared.remove(paneID: $0) } }
        for (index, paneID) in deviceIDs.enumerated() {
            UserDefaults.standard.set("duplicate-device-\(index)", forKey: DeviceCaptureSession.preferenceKey(for: paneID))
            UserDefaults.standard.set("Duplicate iPhone \(index)", forKey: DeviceCaptureSession.preferenceNameKey(for: paneID))
            _ = DeviceCaptureRegistry.shared.session(for: paneID)
        }

        let controller = ExtensionWorkspaceController(
            modelContext: fixture.container.mainContext,
            performSave: { _ in throw InjectedFailure.unavailable }
        )
        controller.synchronize(with: fixture.alpha)

        for (index, paneID) in deviceIDs.enumerated() {
            #expect(
                UserDefaults.standard.string(forKey: DeviceCaptureSession.preferenceKey(for: paneID))
                    == "duplicate-device-\(index)"
            )
            #expect(
                UserDefaults.standard.string(forKey: DeviceCaptureSession.preferenceNameKey(for: paneID))
                    == "Duplicate iPhone \(index)"
            )
        }
        let matchingLinks = try fixture.container.mainContext.fetch(FetchDescriptor<ExtensionWorkspaceLink>())
            .filter { $0.sourceWorkspaceID == fixture.alpha.id }
        #expect(matchingLinks.count == 2)
    }

    @Test("Pane drag moves exact state between Main and Extension in both directions")
    func paneDragMovesPersistedIdentityBetweenWindows() throws {
        let defaults = DefaultsSnapshot()
        defer { defaults.restore() }
        let fixture = try makeFixture()
        let controller = ExtensionWorkspaceController(modelContext: fixture.container.mainContext)
        controller.synchronize(with: fixture.alpha)
        let extensionWorkspace = try #require(controller.selectedWorkspace)
        let extensionTarget = try #require(extensionWorkspace.sortedPanes.first)

        fixture.alpha.addPane(kind: .browser, side: .right)
        let browser = try #require(fixture.alpha.selectedPane)
        let browserState = try #require(browser.browserState)
        browserState.urlText = "https://example.com/dragged"
        let mainPayload = WorkspacePaneDragPayload(
            paneID: browser.id,
            sourceWorkspaceID: fixture.alpha.id,
            projectID: fixture.alpha.id,
            sourceSurface: .main
        )

        #expect(fixture.store.movePane(mainPayload, to: extensionWorkspace, onto: extensionTarget))
        #expect(!fixture.alpha.panes.contains(where: { $0.id == browser.id }))
        #expect(extensionWorkspace.panes.contains(where: { $0 === browser }))
        #expect(browser.workspace === extensionWorkspace)
        #expect(browser.browserState === browserState)
        #expect(browser.browserState?.urlText == "https://example.com/dragged")

        let soleMainPane = try #require(fixture.alpha.sortedPanes.first)
        let solePanePayload = WorkspacePaneDragPayload(
            paneID: soleMainPane.id,
            sourceWorkspaceID: fixture.alpha.id,
            projectID: fixture.alpha.id,
            sourceSurface: .main
        )
        #expect(!fixture.store.movePane(solePanePayload, to: extensionWorkspace, onto: extensionTarget))

        let extensionPayload = WorkspacePaneDragPayload(
            paneID: browser.id,
            sourceWorkspaceID: extensionWorkspace.id,
            projectID: fixture.alpha.id,
            sourceSurface: .extension
        )
        #expect(fixture.store.movePane(extensionPayload, to: fixture.alpha, onto: soleMainPane))
        #expect(fixture.alpha.panes.contains(where: { $0 === browser }))
        #expect(!extensionWorkspace.panes.contains(where: { $0.id == browser.id }))
        #expect(browser.workspace === fixture.alpha)
        #expect(browser.browserState === browserState)
    }

    @Test("Pane drops reorder adjacent panes in both directions")
    func localPaneReorderWorksInBothDirections() throws {
        let defaults = DefaultsSnapshot()
        defer { defaults.restore() }
        let fixture = try makeFixture()

        let terminal = try #require(fixture.alpha.sortedPanes.first)
        fixture.alpha.addPane(kind: .browser, side: .right)
        let browser = try #require(fixture.alpha.selectedPane)
        fixture.alpha.addPane(kind: .editor, side: .right)
        let editor = try #require(fixture.alpha.selectedPane)

        let terminalPayload = WorkspacePaneDragPayload(
            paneID: terminal.id,
            sourceWorkspaceID: fixture.alpha.id,
            projectID: fixture.alpha.id,
            sourceSurface: .main
        )

        #expect(fixture.store.movePane(terminalPayload, to: fixture.alpha, onto: browser))
        #expect(fixture.alpha.sortedPanes.map(\.id) == [browser.id, terminal.id, editor.id])
        #expect(fixture.alpha.sortedPanes.map(\.sortOrder) == [0, 1, 2])

        let editorPayload = WorkspacePaneDragPayload(
            paneID: editor.id,
            sourceWorkspaceID: fixture.alpha.id,
            projectID: fixture.alpha.id,
            sourceSurface: .main
        )

        #expect(fixture.store.movePane(editorPayload, to: fixture.alpha, onto: terminal))
        #expect(fixture.alpha.sortedPanes.map(\.id) == [browser.id, editor.id, terminal.id])
        #expect(fixture.alpha.sortedPanes.map(\.sortOrder) == [0, 1, 2])
    }

    @Test("Pane transfer selects an expanded survivor and reveals one when necessary")
    func paneTransferRepairsCollapsedSourceSelection() throws {
        let defaults = DefaultsSnapshot()
        defer { defaults.restore() }
        let fixture = try makeFixture()
        let controller = ExtensionWorkspaceController(modelContext: fixture.container.mainContext)
        controller.synchronize(with: fixture.alpha)
        let extensionWorkspace = try #require(controller.selectedWorkspace)
        let extensionTarget = try #require(extensionWorkspace.sortedPanes.first)

        let terminal = try #require(fixture.alpha.sortedPanes.first)
        fixture.alpha.addPane(kind: .browser, side: .right)
        let collapsedBrowser = try #require(fixture.alpha.selectedPane)
        collapsedBrowser.isCollapsed = true
        fixture.alpha.addPane(kind: .editor, side: .right)
        let editor = try #require(fixture.alpha.selectedPane)
        fixture.alpha.selectedPaneID = terminal.id

        let terminalPayload = WorkspacePaneDragPayload(
            paneID: terminal.id,
            sourceWorkspaceID: fixture.alpha.id,
            projectID: fixture.alpha.id,
            sourceSurface: .main
        )
        #expect(fixture.store.movePane(terminalPayload, to: extensionWorkspace, onto: extensionTarget))
        #expect(fixture.alpha.selectedPaneID == editor.id)
        #expect(!editor.isCollapsed)

        let editorPayload = WorkspacePaneDragPayload(
            paneID: editor.id,
            sourceWorkspaceID: fixture.alpha.id,
            projectID: fixture.alpha.id,
            sourceSurface: .main
        )
        #expect(fixture.store.movePane(editorPayload, to: extensionWorkspace, onto: extensionTarget))
        #expect(fixture.alpha.selectedPaneID == collapsedBrowser.id)
        #expect(!collapsedBrowser.isCollapsed)
        #expect(collapsedBrowser.sizeFraction == 1)
    }

    @Test("Moving a nonselected frontmost terminal refreshes the automatic root")
    func paneTransferRefreshesAutomaticRootTracking() throws {
        let defaults = DefaultsSnapshot()
        defer { defaults.restore() }
        let fixture = try makeFixture()
        let nonRepoDirectory = try makeNonRepoDirectory()
        defer { try? FileManager.default.removeItem(at: nonRepoDirectory) }

        let repositoryDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
        let repositoryRoot = try #require(RepositoryStore.findGitRoot(from: repositoryDirectory))
        let movedTerminal = try #require(fixture.alpha.sortedPanes.first)
        movedTerminal.currentDirectory = repositoryDirectory
        fixture.alpha.addPane(kind: .terminal, side: .right)
        let survivingTerminal = try #require(fixture.alpha.selectedPane)
        survivingTerminal.currentDirectory = nonRepoDirectory.path
        fixture.alpha.addPane(kind: .browser, side: .right)
        let selectedBrowser = try #require(fixture.alpha.selectedPane)
        fixture.alpha.rootPathSource = .automatic
        fixture.alpha.rootPath = repositoryRoot
        fixture.alpha.selectedPaneID = selectedBrowser.id
        fixture.alpha.frontmostTerminalPaneID = movedTerminal.id

        let controller = ExtensionWorkspaceController(modelContext: fixture.container.mainContext)
        controller.synchronize(with: fixture.alpha)
        let extensionWorkspace = try #require(controller.selectedWorkspace)
        let extensionTarget = try #require(extensionWorkspace.sortedPanes.first)
        let payload = WorkspacePaneDragPayload(
            paneID: movedTerminal.id,
            sourceWorkspaceID: fixture.alpha.id,
            projectID: fixture.alpha.id,
            sourceSurface: .main
        )

        #expect(fixture.store.movePane(payload, to: extensionWorkspace, onto: extensionTarget))
        #expect(fixture.alpha.selectedPaneID == selectedBrowser.id)
        #expect(fixture.alpha.frontmostTerminalPaneID == survivingTerminal.id)
        #expect(fixture.alpha.rootPath.isEmpty)
    }

    @Test("Deleting a source prunes its extension projection and runtime sessions")
    func deletedSourcePrunesProjection() throws {
        let defaults = DefaultsSnapshot()
        defer { defaults.restore() }
        let fixture = try makeFixture()
        let controller = ExtensionWorkspaceController(modelContext: fixture.container.mainContext)

        controller.synchronize(with: fixture.alpha)
        let alphaExtension = try #require(controller.selectedWorkspace)

        fixture.store.selectWorkspace(fixture.beta.id)
        controller.synchronize(with: fixture.beta)
        let betaExtension = try #require(controller.selectedWorkspace)
        betaExtension.addPane(kind: .device, side: .right)
        let devicePane = try #require(betaExtension.panes.first { $0.kind == .device })
        _ = DeviceCaptureRegistry.shared.session(for: devicePane.id)
        #expect(DeviceCaptureRegistry.shared.existingSession(for: devicePane.id) != nil)

        fixture.store.deleteWorkspace(fixture.beta)
        let survivingSource = try #require(fixture.store.selectedWorkspace)
        let validSourceIDs = Set(fixture.store.workspaces.map(\.id))
        controller.update(with: survivingSource, validSourceIDs: validSourceIDs)

        #expect(controller.workspace(forSourceID: fixture.alpha.id) === alphaExtension)
        #expect(controller.workspace(forSourceID: fixture.beta.id) == nil)
        #expect(controller.selectedSourceID == fixture.alpha.id)
        #expect(controller.selectedWorkspace === alphaExtension)
        #expect(DeviceCaptureRegistry.shared.existingSession(for: devicePane.id) == nil)
    }

    @Test("Source metadata refresh keeps an explicitly changed terminal directory")
    func sourceMetadataRefreshesProjection() throws {
        let defaults = DefaultsSnapshot()
        defer { defaults.restore() }
        let fixture = try makeFixture()
        let controller = ExtensionWorkspaceController(modelContext: fixture.container.mainContext)

        fixture.alpha.setRootPath("/tmp/alpha-old")
        controller.synchronize(with: fixture.alpha)
        let extensionWorkspace = try #require(controller.selectedWorkspace)
        let inheritedTerminal = try #require(extensionWorkspace.sortedPanes.first)
        extensionWorkspace.addPane(kind: .terminal, side: .right)
        let customTerminal = try #require(extensionWorkspace.sortedPanes.last)
        customTerminal.currentDirectory = "/tmp/custom"

        fixture.alpha.name = "Alpha Renamed"
        fixture.alpha.setRootPath("/tmp/alpha-new")
        controller.synchronize(with: fixture.alpha)

        #expect(extensionWorkspace.name == "Alpha Renamed")
        #expect(extensionWorkspace.effectiveRootPath == "/tmp/alpha-new")
        #expect(inheritedTerminal.currentDirectory == "/tmp/alpha-new")
        #expect(customTerminal.currentDirectory == "/tmp/custom")
    }

    private func makeFixture() throws -> (
        container: ModelContainer,
        store: WorkspaceStore,
        alpha: Workspace,
        beta: Workspace
    ) {
        let schema = Schema([
            Workspace.self,
            Pane.self,
            BrowserState.self,
            EditorState.self,
            Note.self,
            RemoteDesktopConnection.self,
            ExtensionWorkspaceLink.self,
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let alpha = Workspace(name: "Alpha")
        let beta = Workspace(name: "Beta")
        alpha.workspaceSortOrder = 0
        beta.workspaceSortOrder = 1
        container.mainContext.insert(alpha)
        container.mainContext.insert(beta)
        try container.mainContext.save()

        let store = WorkspaceStore(modelContext: container.mainContext)
        store.isNotesMode = false
        store.isRemoteDesktopMode = false
        return (container, store, alpha, beta)
    }

    private func makeNonRepoDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("blau-pane-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@MainActor
private struct DefaultsSnapshot {
    private static let keys = [
        "selectedWorkspaceID",
        "selectedNoteID",
        "notesMode",
        "selectedRemoteConnectionID",
        "remoteDesktopMode",
    ]

    private let values: [String: Any]
    private let missingKeys: Set<String>

    init(defaults: UserDefaults = .standard) {
        var values: [String: Any] = [:]
        var missingKeys: Set<String> = []
        for key in Self.keys {
            if let value = defaults.object(forKey: key) {
                values[key] = value
            } else {
                missingKeys.insert(key)
            }
        }
        self.values = values
        self.missingKeys = missingKeys
    }

    func restore(defaults: UserDefaults = .standard) {
        for key in Self.keys {
            if missingKeys.contains(key) {
                defaults.removeObject(forKey: key)
            } else if let value = values[key] {
                defaults.set(value, forKey: key)
            }
        }
    }
}
