import Foundation
import CoreData
import SwiftData
import Testing
@testable import Pilot

@Suite("Pilot schema migration", .serialized)
@MainActor
struct PilotSchemaMigrationTests {
    @Test("Opening choices persist and restored panes skip the chooser")
    func openingChoicesSurviveReopening() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pilot-opening-choices-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("choices.store")
        let expected: [UUID: (PaneKind, BrowserEngine?, AndroidPaneTarget)] = try autoreleasepool {
            let container = try makeCurrentContainer(at: storeURL)
            let workspace = Workspace(name: "Opening choices")
            workspace.panes = []
            container.mainContext.insert(workspace)
            var saved: [UUID: (PaneKind, BrowserEngine?, AndroidPaneTarget)] = [:]
            var choices: [(PaneKind, NewTabChoice)] = [
                (.terminal, .terminal), (.terminal, .agenticTerminal), (.terminal, .browser(.webKit, nil)),
                (.simulator, .pane(.device, nil)), (.terminal, .pane(.android, .simulator)), (.terminal, .pane(.android, .device)),
            ]
            if ChromiumBrowserCreationPolicy.isCreationEnabled { choices.append((.terminal, .browser(.chromium, nil))) }
            for (start, choice) in choices {
                let pane = workspace.addPane(kind: start, side: .right, chooseModeOnOpen: true)
                #expect(workspace.selectedPane?.isChoosingMode == true)
                #expect(pane.applyOpeningChoice(choice))
                #expect(!pane.isChoosingMode)
                #expect(pane.kind == choice.kind)
                if case .pane(.android, let target?) = choice { #expect(pane.androidTarget == target) }
                if case .browser(let engine, _) = choice { #expect(pane.browserState?.engine == engine) }
                saved[pane.id] = (pane.kind, pane.browserState?.engine, pane.androidTarget)
                AndroidDeviceRegistry.shared.remove(paneID: pane.id)
            }
            try container.mainContext.save()
            return saved
        }
        try autoreleasepool {
            let container = try makeCurrentContainer(at: storeURL)
            let panes = try container.mainContext.fetch(FetchDescriptor<Pane>())
            #expect(panes.count == expected.count)
            for pane in panes {
                let saved = try #require(expected[pane.id])
                #expect(pane.kind == saved.0)
                #expect(pane.browserState?.engine == saved.1)
                #expect(pane.androidTarget == saved.2)
                #expect(!pane.isChoosingMode)
            }
        }
    }

    /// A plan that knows only V1 — how shipped builds stamped users' stores
    /// before `ExtensionWorkspaceLink` existed.
    private enum V1OnlyPlan: SchemaMigrationPlan {
        static var schemas: [any VersionedSchema.Type] { [PilotSchemaV1.self] }
        static var stages: [MigrationStage] { [] }
    }

    private enum V2OnlyPlan: SchemaMigrationPlan {
        static var schemas: [any VersionedSchema.Type] { [PilotSchemaV2.self] }
        static var stages: [MigrationStage] { [] }
    }

    private enum V3OnlyPlan: SchemaMigrationPlan {
        static var schemas: [any VersionedSchema.Type] { [PilotSchemaV3.self] }
        static var stages: [MigrationStage] { [] }
    }

    @Test("Shipped V3 workspaces migrate to Android target persistence without losing their state")
    func v3WorkspacesSurviveAndroidTargetMigration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pilot-v3-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Pilot.store")
        let paneID = UUID()
        let workspaceID = UUID()
        try autoreleasepool {
            let schema = Schema(versionedSchema: PilotSchemaV3.self)
            let container = try ModelContainer(for: schema, migrationPlan: V3OnlyPlan.self,
                configurations: ModelConfiguration(schema: schema, url: storeURL))
            let workspace = PilotSchemaV3.Workspace()
            workspace.id = workspaceID
            workspace.name = "Existing workspace"
            let pane = PilotSchemaV3.Pane()
            pane.id = paneID
            pane.currentDirectory = "/projects/existing"
            pane.terminalDestinationRaw = "drone"
            pane.terminalRemoteSessionIDRaw = "existing-session"
            pane.workspace = workspace
            workspace.panes = [pane]
            workspace.selectedPaneID = paneID
            let extensionWorkspace = PilotSchemaV3.Workspace()
            extensionWorkspace.name = "Existing extension"
            let link = PilotSchemaV3.ExtensionWorkspaceLink()
            link.sourceWorkspaceID = workspaceID
            link.workspace = extensionWorkspace
            let note = PilotSchemaV3.Note()
            note.body = "Keep the existing note"
            container.mainContext.insert(workspace)
            container.mainContext.insert(link)
            container.mainContext.insert(note)
            try container.mainContext.save()
        }

        // This is the Pane checksum from the shipped store, independent of the
        // current model. A fixture built from accidentally changed V3 types must fail.
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType, at: storeURL)
        let hashes = try #require(metadata[NSStoreModelVersionHashesKey] as? [String: Data])
        #expect(hashes["Pane"]?.map { String(format: "%02x", $0) }.joined()
            == "f6f412fb7a75bf3bbdaa4dbea51d886ae5fccc9b0cb261877e99583249c96cae")

        try autoreleasepool {
            let container = try makeCurrentContainer(at: storeURL)
            let context = container.mainContext
            let workspaces = try context.fetch(FetchDescriptor<Workspace>())
            #expect(workspaces.count == 2)
            let workspace = try #require(workspaces.first { $0.id == workspaceID })
            #expect(workspace.name == "Existing workspace")
            #expect(workspace.selectedPaneID == paneID)
            let pane = try #require(workspace.panes.first)
            #expect(pane.id == paneID)
            #expect(pane.currentDirectory == "/projects/existing")
            #expect(pane.terminalDestinationRaw == "drone")
            #expect(pane.terminalRemoteSessionIDRaw == "existing-session")
            #expect(pane.androidTargetRaw == nil)
            let links = try context.fetch(FetchDescriptor<ExtensionWorkspaceLink>())
            #expect(links.count == 1)
            #expect(links.first?.sourceWorkspaceID == workspaceID)
            #expect(links.first?.workspace?.name == "Existing extension")
            #expect(try context.fetch(FetchDescriptor<Note>()).first?.body == "Keep the existing note")
            pane.androidTargetRaw = "android-fixture"
            try context.save()
        }
        let reopened = try makeCurrentContainer(at: storeURL)
        #expect(try reopened.mainContext.fetch(FetchDescriptor<Pane>()).first?.androidTargetRaw == "android-fixture")
    }

    @Test("Notes written at V1 stay readable through the live class after migration")
    func v1NotesRemainReadableAfterMigration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pilot-schema-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Pilot.store")

        try autoreleasepool {
            let schema = Schema(versionedSchema: PilotSchemaV1.self)
            let container = try ModelContainer(
                for: schema,
                migrationPlan: V1OnlyPlan.self,
                configurations: ModelConfiguration(schema: schema, url: storeURL)
            )
            let context = container.mainContext
            let note = PilotSchemaV1.Note()
            note.body = "Keeps this note\nsecond line"
            note.sortOrder = 3
            context.insert(note)
            try context.save()
        }

        // The exact read path of the launch crash this guards: fetch through
        // the LIVE Note class (its frozen V1 twin also exists in the binary)
        // and pull `body` through the SwiftData getter.
        let container = try makeCurrentContainer(at: storeURL)
        let context = container.mainContext
        let notes = try context.fetch(FetchDescriptor<Note>())
        #expect(notes.count == 1)
        #expect(notes.first?.body == "Keeps this note\nsecond line")
        #expect(notes.first?.sortOrder == 3)
        #expect(notes.first?.displayTitle == "Keeps this note")
    }

    @Test("V2 browsers default to WebKit after migration and Chromium survives reopen")
    func v2BrowserEngineMigratesAndChromiumRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pilot-browser-engine-migration-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Pilot.store")

        let browserPaneID = try autoreleasepool {
            let schema = Schema(versionedSchema: PilotSchemaV2.self)
            let container = try ModelContainer(
                for: schema,
                migrationPlan: V2OnlyPlan.self,
                configurations: ModelConfiguration(schema: schema, url: storeURL)
            )
            let workspace = PilotSchemaV2.Workspace()
            workspace.name = "V2 Browser Workspace"
            let browser = PilotSchemaV2.Pane()
            browser.kindRaw = PaneKind.browser.rawValue
            browser.workspace = workspace
            let browserState = PilotSchemaV2.BrowserState()
            browserState.urlText = "https://example.com/restored"
            browser.browserState = browserState
            workspace.panes = [browser]
            workspace.selectedPaneID = browser.id
            container.mainContext.insert(workspace)
            try container.mainContext.save()
            return browser.id
        }

        try autoreleasepool {
            let container = try makeCurrentContainer(at: storeURL)
            let panes = try container.mainContext.fetch(FetchDescriptor<Pane>())
            let browser = try #require(panes.first { $0.id == browserPaneID })
            let state = try #require(browser.browserState)
            #expect(state.engine == .webKit)
            #expect(state.urlText == "https://example.com/restored")

            state.engine = .chromium
            try container.mainContext.save()
        }

        try autoreleasepool {
            let container = try makeCurrentContainer(at: storeURL)
            let panes = try container.mainContext.fetch(FetchDescriptor<Pane>())
            let browser = try #require(panes.first { $0.id == browserPaneID })
            #expect(browser.browserState?.engine == .chromium)
            #expect(
                browser.browserState?.urlText
                    == "https://example.com/restored"
            )
        }
    }

    @Test("V1 canonical workspace state survives migration and accepts extension links")
    func v1StoreMigratesWithoutLosingWorkspaceState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pilot-schema-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("Pilot.store")
        let fixture = try writeV1Fixture(to: storeURL)
        let extensionWorkspaceID = try migrateToCurrentSchemaAndInsertLink(
            at: storeURL,
            fixture: fixture
        )
        try verifyInsertedLinkAfterReopeningCurrentSchema(
            at: storeURL,
            fixture: fixture,
            extensionWorkspaceID: extensionWorkspaceID
        )
        try verifyPreMigrationBackup(in: directory, fixture: fixture)
    }

    /// Launch backs the store up before migrating. The oldest backup must be
    /// the untouched V1 store, still readable by a V1 build, so a migration
    /// that goes wrong can always be rolled back.
    private func verifyPreMigrationBackup(in directory: URL, fixture: FixtureIDs) throws {
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("Backups", isDirectory: true), includingPropertiesForKeys: nil
        ).filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let oldest = try #require(backups.first).appendingPathComponent("Pilot.store")
        try autoreleasepool {
            let schema = Schema(versionedSchema: PilotSchemaV1.self)
            let container = try ModelContainer(
                for: schema, migrationPlan: V1OnlyPlan.self,
                configurations: ModelConfiguration(schema: schema, url: oldest))
            let workspaces = try container.mainContext.fetch(FetchDescriptor<PilotSchemaV1.Workspace>())
            let workspace = try #require(workspaces.first { $0.id == fixture.workspaceID })
            #expect(workspace.name == "Canonical Workspace")
            #expect(workspace.panes.count == 2)
            #expect(try container.mainContext.fetchCount(FetchDescriptor<PilotSchemaV1.BrowserState>()) == 1)
        }
    }

    /// Writes the store exactly as a shipped V1 build would have: through the
    /// FROZEN `PilotSchemaV1` snapshot classes (a container built from the V1
    /// schema registers those, not the live types) and a V1-only plan, so the
    /// store carries V1's version stamp.
    private func writeV1Fixture(to storeURL: URL) throws -> FixtureIDs {
        try autoreleasepool {
            let schema = Schema(versionedSchema: PilotSchemaV1.self)
            let configuration = ModelConfiguration(schema: schema, url: storeURL)
            let container = try ModelContainer(
                for: schema,
                migrationPlan: V1OnlyPlan.self,
                configurations: configuration
            )
            let context = container.mainContext

            let workspace = PilotSchemaV1.Workspace()
            workspace.name = "Canonical Workspace"
            workspace.axisRaw = PaneAxis.horizontal.rawValue
            workspace.isInspectorPresented = true
            workspace.inspectorTabRaw = InspectorTab.pullRequests.rawValue
            workspace.isPinned = true
            workspace.workspaceSortOrder = 7
            workspace.rootPath = "/tmp/canonical-repository"
            workspace.rootPathSourceRaw = RootPathSource.manual.rawValue
            workspace.actionBadgeCount = 4

            let terminal = PilotSchemaV1.Pane()
            terminal.kindRaw = PaneKind.terminal.rawValue
            terminal.sortOrder = 0
            terminal.currentDirectory = "/tmp/canonical-repository/terminal"
            terminal.bellCount = 3
            terminal.sizeFraction = 0.35
            terminal.restoredSizeFraction = 0.4
            terminal.wasCollapsedBeforeFocus = true
            terminal.workspace = workspace

            let browser = PilotSchemaV1.Pane()
            browser.kindRaw = PaneKind.browser.rawValue
            browser.sortOrder = 1
            browser.workspace = workspace
            browser.currentDirectory = "/tmp/canonical-repository/browser"
            browser.bellCount = 2
            browser.sizeFraction = 0.65
            browser.isCollapsed = true
            browser.restoredSizeFraction = 0.6
            let browserState = PilotSchemaV1.BrowserState()
            browserState.urlText = "https://example.com/migration?pane=browser#state"
            browserState.appearanceModeRaw = AppearanceMode.dark.rawValue
            browserState.navigationRequestID = 12
            browserState.inspectorToggleRequestID = 5
            browser.browserState = browserState

            workspace.panes = [terminal, browser]
            workspace.selectedPaneID = browser.id
            workspace.frontmostTerminalPaneID = terminal.id
            workspace.focusedPaneID = browser.id

            context.insert(workspace)
            try context.save()

            return FixtureIDs(
                workspaceID: workspace.id,
                terminalPaneID: terminal.id,
                browserPaneID: browser.id
            )
        }
    }

    private func migrateToCurrentSchemaAndInsertLink(
        at storeURL: URL,
        fixture: FixtureIDs
    ) throws -> UUID {
        try autoreleasepool {
            let container = try makeCurrentContainer(at: storeURL)
            let context = container.mainContext
            let canonical = try canonicalWorkspace(in: context, id: fixture.workspaceID)

            try verifyCanonicalState(canonical, fixture: fixture)
            #expect(try context.fetch(FetchDescriptor<ExtensionWorkspaceLink>()).isEmpty)

            let extensionWorkspace = Workspace(name: "Extension Projection")
            extensionWorkspace.rootPath = "/tmp/canonical-repository"
            extensionWorkspace.rootPathSource = .manual
            let link = ExtensionWorkspaceLink(
                sourceWorkspaceID: fixture.workspaceID,
                workspace: extensionWorkspace
            )
            context.insert(extensionWorkspace)
            context.insert(link)
            try context.save()

            let insertedLinks = try context.fetch(FetchDescriptor<ExtensionWorkspaceLink>())
            let inserted = try #require(insertedLinks.first)
            #expect(insertedLinks.count == 1)
            #expect(inserted.sourceWorkspaceID == fixture.workspaceID)
            #expect(inserted.workspace?.id == extensionWorkspace.id)
            return extensionWorkspace.id
        }
    }

    private func verifyInsertedLinkAfterReopeningCurrentSchema(
        at storeURL: URL,
        fixture: FixtureIDs,
        extensionWorkspaceID: UUID
    ) throws {
        try autoreleasepool {
            let container = try makeCurrentContainer(at: storeURL)
            let context = container.mainContext

            let canonical = try canonicalWorkspace(in: context, id: fixture.workspaceID)
            try verifyCanonicalState(canonical, fixture: fixture)

            let links = try context.fetch(FetchDescriptor<ExtensionWorkspaceLink>())
            let link = try #require(links.first)
            #expect(links.count == 1)
            #expect(link.sourceWorkspaceID == fixture.workspaceID)
            #expect(link.workspace?.id == extensionWorkspaceID)
            #expect(link.workspace?.name == "Extension Projection")
        }
    }

    /// The launch path: backup, then the current schema with the full migration plan.
    private func makeCurrentContainer(at storeURL: URL) throws -> ModelContainer {
        try CockpitPersistence.openStore(at: storeURL)
    }

    private func canonicalWorkspace(in context: ModelContext, id: UUID) throws -> Workspace {
        let workspaces = try context.fetch(FetchDescriptor<Workspace>())
        return try #require(workspaces.first { $0.id == id })
    }

    private func verifyCanonicalState(_ workspace: Workspace, fixture: FixtureIDs) throws {
        #expect(workspace.name == "Canonical Workspace")
        #expect(workspace.axis == .horizontal)
        #expect(workspace.isInspectorPresented)
        #expect(workspace.inspectorTab == .pullRequests)
        #expect(workspace.isPinned)
        #expect(workspace.workspaceSortOrder == 7)
        #expect(workspace.rootPath == "/tmp/canonical-repository")
        #expect(workspace.rootPathSource == .manual)
        #expect(workspace.actionBadgeCount == 4)
        #expect(workspace.selectedPaneID == fixture.browserPaneID)
        #expect(workspace.frontmostTerminalPaneID == fixture.terminalPaneID)
        #expect(workspace.focusedPaneID == fixture.browserPaneID)

        let panes = workspace.sortedPanes
        #expect(panes.count == 2)
        let terminal = try #require(panes.first { $0.id == fixture.terminalPaneID })
        #expect(terminal.workspace?.id == fixture.workspaceID)
        #expect(terminal.kind == .terminal)
        #expect(terminal.sortOrder == 0)
        #expect(terminal.currentDirectory == "/tmp/canonical-repository/terminal")
        #expect(terminal.bellCount == 3)
        #expect(terminal.sizeFraction == 0.35)
        #expect(!terminal.isCollapsed)
        #expect(terminal.restoredSizeFraction == 0.4)
        #expect(terminal.wasCollapsedBeforeFocus)

        let browser = try #require(panes.first { $0.id == fixture.browserPaneID })
        #expect(browser.workspace?.id == fixture.workspaceID)
        #expect(browser.kind == .browser)
        #expect(browser.sortOrder == 1)
        #expect(browser.currentDirectory == "/tmp/canonical-repository/browser")
        #expect(browser.bellCount == 2)
        #expect(browser.sizeFraction == 0.65)
        #expect(browser.isCollapsed)
        #expect(browser.restoredSizeFraction == 0.6)

        let browserState = try #require(browser.browserState)
        #expect(browserState.urlText == "https://example.com/migration?pane=browser#state")
        #expect(browserState.appearanceMode == .dark)
        #expect(browserState.navigationRequestID == 12)
        #expect(browserState.inspectorToggleRequestID == 5)
    }
}

private struct FixtureIDs {
    let workspaceID: UUID
    let terminalPaneID: UUID
    let browserPaneID: UUID
}
