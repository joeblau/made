import Foundation
import SwiftData
import Testing
@testable import Pilot

/// Pinning appends to the end of the pinned section; unpinning jumps to the
/// top of the unpinned section. The two directions are deliberately not
/// symmetric, so both are covered here.
@Suite("Workspace pin ordering", .serialized)
@MainActor
struct WorkspacePinOrderingTests {

    @Test("Pinning appends to the bottom of the pinned section")
    func pinningAppendsToPinnedSection() throws {
        let fixture = try makeFixture(names: ["Alpha", "Beta", "Gamma"])
        let store = fixture.store

        store.togglePin(fixture.workspaces[0]) // Alpha
        store.togglePin(fixture.workspaces[1]) // Beta

        // Alpha was pinned first and keeps the top slot; Beta lands beneath it
        // rather than displacing it.
        #expect(names(ofPinned: true, in: store) == ["Alpha", "Beta"])

        store.togglePin(fixture.workspaces[2]) // Gamma
        #expect(names(ofPinned: true, in: store) == ["Alpha", "Beta", "Gamma"])
    }

    @Test("Unpinning moves to the top of the unpinned section")
    func unpinningPrependsToUnpinnedSection() throws {
        let fixture = try makeFixture(names: ["Alpha", "Beta", "Gamma"])
        let store = fixture.store

        store.togglePin(fixture.workspaces[0]) // Alpha pinned
        store.togglePin(fixture.workspaces[0]) // Alpha unpinned again

        // Alpha returns above Beta and Gamma, which were never pinned.
        #expect(names(ofPinned: false, in: store) == ["Alpha", "Beta", "Gamma"])
        #expect(names(ofPinned: true, in: store).isEmpty)
    }

    @Test("Pinned workspaces sort ahead of unpinned ones")
    func pinnedSectionLeadsTheList() throws {
        let fixture = try makeFixture(names: ["Alpha", "Beta", "Gamma"])
        let store = fixture.store

        store.togglePin(fixture.workspaces[2]) // Gamma

        #expect(store.workspaces.map(\.name) == ["Gamma", "Alpha", "Beta"])
    }

    @Test("Moving groups never moves them above Pinned and unpinning returns to the top")
    func groupsStayBelowPinned() throws {
        let fixture = try makeFixture(names: ["Alpha", "Beta", "Gamma"])
        let suite = "WorkspacePinOrderingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let groups = WorkspaceGroups(defaults: defaults)
        let store = WorkspaceStore(modelContext: fixture.container.mainContext, workspaceGroups: groups)
        let group = groups.add(name: "Project", workspaceIDs: store.unpinnedWorkspaceIDs)
        store.moveWorkspace(fixture.workspaces[1], toGroup: group)
        store.togglePin(fixture.workspaces[2])
        groups.moveItems(workspaceIDs: store.unpinnedWorkspaceIDs, fromOffsets: [1], toOffset: 0)
        #expect(store.workspaces.map(\.name) == ["Gamma", "Beta", "Alpha"])
        store.togglePin(fixture.workspaces[2])
        #expect(store.workspaces.map(\.name) == ["Gamma", "Beta", "Alpha"])
        #expect(groups.items(workspaceIDs: store.unpinnedWorkspaceIDs).first == .workspace(fixture.workspaces[2].id))
        store.togglePin(fixture.workspaces[1])
        #expect(groups.group(group)?.workspaceIDs.isEmpty == true)
        #expect(store.workspaces.first?.name == "Beta")
        store.moveWorkspace(fixture.workspaces[1], toGroup: group)
        #expect(!fixture.workspaces[1].isPinned)
        #expect(groups.group(group)?.workspaceIDs == [fixture.workspaces[1].id])
    }

    @Test("Sidebar drops move pinned workspaces into groups, between groups, and back out")
    func sidebarDrops() throws {
        let fixture = try makeFixture(names: ["Alpha", "Beta"])
        let suite = "WorkspacePinOrderingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let groups = WorkspaceGroups(defaults: defaults)
        let store = WorkspaceStore(modelContext: fixture.container.mainContext, workspaceGroups: groups)
        let first = groups.add(name: "First", workspaceIDs: store.unpinnedWorkspaceIDs)
        let second = groups.add(name: "Second", workspaceIDs: store.unpinnedWorkspaceIDs)
        let workspace = fixture.workspaces[0]
        let payload = [WorkspaceSidebarDragPayload(workspaceID: workspace.id)]
        store.togglePin(workspace)

        #expect(!store.acceptWorkspaceDrop(payload, toGroup: UUID()))
        #expect(workspace.isPinned)
        #expect(!store.acceptWorkspaceDrop([WorkspaceSidebarDragPayload(workspaceID: UUID())], toGroup: first))
        #expect(!store.acceptWorkspaceDrop([], toGroup: first))
        #expect(groups.group(first)?.workspaceIDs.isEmpty == true)

        #expect(store.acceptWorkspaceDrop(payload, toGroup: first))
        #expect(!workspace.isPinned)
        #expect(groups.group(first)?.workspaceIDs == [workspace.id])
        #expect(store.acceptWorkspaceDrop(payload, toGroup: second))
        #expect(groups.group(first)?.workspaceIDs.isEmpty == true)
        #expect(groups.group(second)?.workspaceIDs == [workspace.id])
        #expect(store.acceptWorkspaceDrop(payload, toGroup: nil))
        #expect(groups.group(second)?.workspaceIDs.isEmpty == true)
        #expect(groups.items(workspaceIDs: store.unpinnedWorkspaceIDs).contains(.workspace(workspace.id)))
    }

    @Test("A decoded sidebar drag payload moves a workspace into an empty group")
    func dragProviderDelivery() async throws {
        let fixture = try makeFixture(names: ["Alpha", "Beta"])
        let suite = "WorkspaceDragProvider.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let groups = WorkspaceGroups(defaults: defaults)
        let store = WorkspaceStore(modelContext: fixture.container.mainContext, workspaceGroups: groups)
        let groupID = groups.add(name: "Test Group", workspaceIDs: store.unpinnedWorkspaceIDs)
        let payload = WorkspaceSidebarDragPayload(workspaceID: fixture.workspaces[0].id)
        let provider = NSItemProvider(item: try JSONEncoder().encode(payload) as NSData,
                                      typeIdentifier: "app.blau.pilot.workspace")
        let delivered = await withCheckedContinuation { continuation in
            let accepted = WorkspaceSidebarDragPayload.load([provider]) { item in
                continuation.resume(returning: store.acceptWorkspaceDrop([item], toGroup: groupID))
            }
            if !accepted { continuation.resume(returning: false) }
        }
        #expect(delivered)
        #expect(groups.group(groupID)?.workspaceIDs == [fixture.workspaces[0].id])
        #expect(WorkspaceGroups(defaults: defaults).group(groupID)?.workspaceIDs == [fixture.workspaces[0].id])
    }

    @Test("Explicit sidebar drags preserve pinned ordering and move groups as a unit")
    func explicitDragOrdering() throws {
        let fixture = try makeFixture(names: ["Alpha", "Beta", "Gamma"])
        let suite = "WorkspaceDragOrdering.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let groups = WorkspaceGroups(defaults: defaults)
        let store = WorkspaceStore(modelContext: fixture.container.mainContext, workspaceGroups: groups)
        let ids = fixture.workspaces.map(\.id)
        let groupID = groups.add(name: "Test Group", workspaceIDs: store.unpinnedWorkspaceIDs)
        store.moveWorkspace(fixture.workspaces[1], toGroup: groupID)
        #expect(store.acceptTopLevelWorkspaceDrop(.init(groupID: groupID), at: 0))
        #expect(groups.items(workspaceIDs: store.unpinnedWorkspaceIDs).first == .group(groupID))
        #expect(groups.group(groupID)?.workspaceIDs == [ids[1]])
        #expect(!store.acceptPinnedWorkspaceDrop(.init(groupID: groupID), at: 0))
        #expect(store.acceptPinnedWorkspaceDrop(.init(workspaceID: ids[1]), at: 0))
        #expect(groups.group(groupID)?.workspaceIDs.isEmpty == true)
        #expect(store.acceptPinnedWorkspaceDrop(.init(workspaceID: ids[2]), at: 0))
        #expect(store.workspaces.filter(\.isPinned).map(\.id) == [ids[2], ids[1]])
        #expect(store.acceptTopLevelWorkspaceDrop(.init(workspaceID: ids[1]), at: 0))
        #expect(!fixture.workspaces[1].isPinned)
        #expect(groups.items(workspaceIDs: store.unpinnedWorkspaceIDs).first == .workspace(ids[1]))
        #expect(store.acceptSidebarDrop(.init(workspaceID: ids[0]), before: .emptyGroup(groupID)))
        #expect(store.acceptSidebarDrop(.init(workspaceID: ids[1]), before: .workspace(ids[0], groupID: groupID)))
        #expect(groups.group(groupID)?.workspaceIDs == [ids[1], ids[0]])
        #expect(store.acceptSidebarDrop(.init(workspaceID: ids[1]), before: .group(groupID)))
        #expect(groups.group(groupID)?.workspaceIDs == [ids[0]])
    }

    private func names(ofPinned pinned: Bool, in store: WorkspaceStore) -> [String] {
        store.workspaces.filter { $0.isPinned == pinned }.map(\.name)
    }

    private func makeFixture(names: [String]) throws -> (
        container: ModelContainer,
        store: WorkspaceStore,
        workspaces: [Workspace]
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
        let workspaces = names.enumerated().map { index, name -> Workspace in
            let workspace = Workspace(name: name)
            workspace.workspaceSortOrder = index
            container.mainContext.insert(workspace)
            return workspace
        }
        try container.mainContext.save()

        let store = WorkspaceStore(modelContext: container.mainContext)
        store.isNotesMode = false
        store.isRemoteDesktopMode = false
        store.isDockerMode = false
        return (container, store, workspaces)
    }
}
