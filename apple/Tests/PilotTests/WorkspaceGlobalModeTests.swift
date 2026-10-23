import Foundation
import SwiftData
import Testing
@testable import Pilot

/// Notes, Remote Desktop, and Docker each take over the whole detail area, so at
/// most one may be live at a time. The invariant is enforced in the setters
/// themselves — every entry point (sidebar, menu, keyboard) goes through them.
@Suite("Workspace global modes", .serialized)
@MainActor
struct WorkspaceGlobalModeTests {
    @Test("Entering one global mode leaves the others")
    func modesAreMutuallyExclusive() throws {
        let fixture = try makeFixture()
        let store = fixture.store
        defer { clearModes(store) }

        store.enterNotesMode()
        #expect(store.isNotesMode)
        #expect(!store.isRemoteDesktopMode)
        #expect(!store.isDockerMode)

        store.enterDockerMode()
        #expect(store.isDockerMode)
        #expect(!store.isNotesMode)
        #expect(!store.isRemoteDesktopMode)

        store.enterRemoteDesktopMode()
        #expect(store.isRemoteDesktopMode)
        #expect(!store.isDockerMode)
        #expect(!store.isNotesMode)

        store.enterRunnersMode()
        #expect(store.isRunnersMode)
        #expect(!store.isAgenticUseMode)
        #expect(!store.isRemoteDesktopMode)
        #expect(!store.isWorkspaceDetailVisible)

        store.enterAgenticUseMode()
        #expect(store.isAgenticUseMode)
        #expect(!store.isRunnersMode)

        store.enterRunnersMode()
        store.enterNotesMode()
        #expect(store.isNotesMode)
        #expect(!store.isRunnersMode)
    }

    @Test("Toggling Docker returns to the workspace it came from")
    func togglingDockerRestoresTheWorkspace() throws {
        let fixture = try makeFixture()
        let store = fixture.store
        defer { clearModes(store) }
        // Created through the store, not by inserting into the context directly:
        // the store caches its workspace fetch against `changeCount`, which only
        // its own mutators bump.
        store.addWorkspace()
        let workspace = try #require(store.workspaces.first)
        store.selectWorkspace(workspace.id)

        store.toggleDockerMode()
        #expect(store.isDockerMode)
        #expect(!store.isWorkspaceDetailVisible)
        // The workspace stays selected underneath, so leaving Docker lands back
        // on it rather than on an empty detail area.
        #expect(store.selectedWorkspaceID == workspace.id)

        store.toggleDockerMode()
        #expect(!store.isDockerMode)
        #expect(store.isWorkspaceDetailVisible)
        #expect(store.selectedWorkspace?.id == workspace.id)
    }

    @Test("Selecting a workspace exits whichever global mode was showing")
    func selectingAWorkspaceExitsGlobalModes() throws {
        let fixture = try makeFixture()
        let store = fixture.store
        defer { clearModes(store) }
        // Created through the store, not by inserting into the context directly:
        // the store caches its workspace fetch against `changeCount`, which only
        // its own mutators bump.
        store.addWorkspace()
        let workspace = try #require(store.workspaces.first)

        store.enterDockerMode()
        store.selectWorkspace(workspace.id)
        #expect(!store.isDockerMode)
        #expect(store.isWorkspaceDetailVisible)
    }

    @Test("Selecting a workspace exits Runners")
    func selectingAWorkspaceExitsRunners() throws {
        let fixture = try makeFixture()
        let store = fixture.store
        defer { clearModes(store) }
        store.addWorkspace()
        let workspace = try #require(store.workspaces.first)
        store.enterRunnersMode()
        store.selectWorkspace(workspace.id)
        #expect(!store.isRunnersMode)
        #expect(store.isWorkspaceDetailVisible)
    }

    @Test("The workspace detail area is hidden by every global mode")
    func workspaceDetailVisibilityTracksAllModes() throws {
        let fixture = try makeFixture()
        let store = fixture.store
        defer { clearModes(store) }
        #expect(store.isWorkspaceDetailVisible)

        store.isNotesMode = true
        #expect(!store.isWorkspaceDetailVisible)
        store.isNotesMode = false

        store.isRemoteDesktopMode = true
        #expect(!store.isWorkspaceDetailVisible)
        store.isRemoteDesktopMode = false

        store.isDockerMode = true
        #expect(!store.isWorkspaceDetailVisible)
    }

    /// The container is returned alongside the store, not dropped: `ModelContext`
    /// does not keep its container alive, and a context whose container has been
    /// deallocated takes the process down on the next insert.
    private func makeFixture() throws -> (container: ModelContainer, store: WorkspaceStore) {
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
        let store = WorkspaceStore(modelContext: container.mainContext)
        clearModes(store)
        return (container, store)
    }

    /// The mode setters persist to the standard defaults domain, which the test
    /// host shares with the app. Clear them on both sides of every case so a
    /// test can neither inherit nor leave behind a live global mode.
    private func clearModes(_ store: WorkspaceStore) {
        store.isNotesMode = false
        store.isRemoteDesktopMode = false
        store.isDockerMode = false
        store.isAgenticUseMode = false
        store.isRunnersMode = false
    }
}
