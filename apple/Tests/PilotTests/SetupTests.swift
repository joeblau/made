import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import Pilot

@Suite("First-run setup")
@MainActor
struct SetupTests {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "SetupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    @Test("A fresh installation waits for setup without enabling companion services")
    func freshInstall() {
        withDefaults { defaults in
            let progress = SetupProgress(defaults: defaults)
            #expect(progress.needsInitialSetup)
            #expect(progress.step == .welcome)
            #expect(!defaults.bool(forKey: SetupProgress.companionsKey))
        }
    }

    @Test("An interrupted setup resumes after a permission-required restart")
    func resume() {
        withDefaults { defaults in
            let progress = SetupProgress(defaults: defaults)
            progress.step = .permissions
            let relaunched = SetupProgress(defaults: defaults)
            #expect(relaunched.needsInitialSetup)
            #expect(relaunched.step == .permissions)
        }
    }

    @Test("Finishing with skipped permissions persists and leaves companions disabled")
    func skippedPermissions() {
        withDefaults { defaults in
            let progress = SetupProgress(defaults: defaults)
            progress.step = .ready
            progress.finish()
            #expect(!progress.needsInitialSetup)
            #expect(!SetupProgress(defaults: defaults).needsInitialSetup)
            #expect(!defaults.bool(forKey: SetupProgress.companionsKey))
        }
    }

    @Test("Tests and demo launches bypass setup without marking it complete")
    func bypass() {
        withDefaults { defaults in
            #expect(!SetupProgress(defaults: defaults, bypass: true).needsInitialSetup)
            #expect(SetupProgress(defaults: defaults).needsInitialSetup)
            #expect(defaults.object(forKey: SetupProgress.completionKey) == nil)
        }
    }

    @Test("Invalid stored navigation recovers to welcome")
    func invalidStep() {
        withDefaults { defaults in
            defaults.set(99, forKey: SetupProgress.stepKey)
            #expect(SetupProgress(defaults: defaults).step == .welcome)
        }
    }

    @Test("Reopening setup preserves completion and companion preference")
    func reopen() {
        withDefaults { defaults in
            defaults.set(true, forKey: SetupProgress.companionsKey)
            let progress = SetupProgress(defaults: defaults)
            progress.finish()
            progress.step = .permissions
            #expect(!SetupProgress(defaults: defaults).needsInitialSetup)
            #expect(defaults.bool(forKey: SetupProgress.companionsKey))
        }
    }

    @Test("Denied and restricted media access never appear as approved")
    func mediaPermissionStates() {
        #expect(SetupPermissions.mediaAccess(.authorized) == .allowed)
        #expect(SetupPermissions.mediaAccess(.notDetermined) == .notRequested)
        #expect(SetupPermissions.mediaAccess(.denied) == .needsSettings)
        #expect(SetupPermissions.mediaAccess(.restricted) == .restricted)
    }

    @Test("An unrequested network permission is never assumed to be approved")
    func unknownNetworkAccess() {
        let permissions = SetupPermissions()
        #expect(permissions.status(.localNetwork) == .notRequested)
        permissions.stopProbe()
        #expect(permissions.status(.localNetwork) == .notRequested)
    }

    @Test("A selected project opens a new workspace without changing existing workspaces")
    func projectWorkspace() throws {
        let schema = Schema(versionedSchema: PilotSchemaV3.self)
        let container = try ModelContainer(
            for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let store = WorkspaceStore(modelContext: container.mainContext)
        store.addWorkspace()
        let original = try #require(store.workspaces.first)
        let directory = URL(fileURLWithPath: "/tmp/My Project", isDirectory: true)
        store.addWorkspace(directory: directory)
        let selected = try #require(store.selectedWorkspace)
        #expect(store.workspaces.count == 2)
        #expect(selected.id != original.id)
        #expect(selected.name == "My Project")
        #expect(selected.panes.first?.currentDirectory == directory.path)
        #expect(original.panes.first?.currentDirectory.isEmpty == true)
    }
}
