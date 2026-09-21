import Foundation
import Testing
@testable import Pilot

@Suite("Workspace groups")
@MainActor
struct WorkspaceGroupsTests {
    @Test("Groups move between loose workspaces as a unit")
    func mixedOrdering() throws {
        try withGroups { groups, _ in
            let ids = [UUID(), UUID(), UUID()]
            let group = groups.add(name: "Project", workspaceIDs: ids)
            groups.place(ids[1], in: group, workspaceIDs: ids)
            groups.moveItems(workspaceIDs: ids, fromOffsets: [2], toOffset: 1)
            #expect(groups.items(workspaceIDs: ids) == [.workspace(ids[0]), .group(group), .workspace(ids[2])])
            #expect(groups.orderedWorkspaceIDs(ids) == ids)
            groups.moveItems(workspaceIDs: ids, fromOffsets: [0], toOffset: 3)
            #expect(groups.orderedWorkspaceIDs(ids) == [ids[1], ids[2], ids[0]])
        }
    }

    @Test("Membership, order, names, and collapse state survive reopening")
    func persistence() throws {
        try withGroups { groups, defaults in
            let ids = [UUID(), UUID(), UUID()]
            let group = groups.add(name: "Project", workspaceIDs: ids)
            groups.place(ids[2], in: group, workspaceIDs: ids)
            groups.place(ids[0], in: group, workspaceIDs: ids)
            groups.moveMembers(group, workspaceIDs: ids, fromOffsets: [1], toOffset: 0)
            groups.moveItems(workspaceIDs: ids, fromOffsets: [1], toOffset: 0)
            groups.rename(group, to: "  Work  ")
            groups.setExpanded(group, false)
            let restored = WorkspaceGroups(defaults: defaults)
            #expect(restored.groups == groups.groups)
            #expect(restored.group(group)?.name == "Work")
            #expect(restored.group(group)?.isExpanded == false)
            #expect(restored.orderedWorkspaceIDs(ids) == [ids[0], ids[2], ids[1]])
        }
    }

    @Test("Removing a group keeps its workspaces at the same position")
    func ungrouping() throws {
        try withGroups { groups, _ in
            let ids = [UUID(), UUID(), UUID()]
            let group = groups.add(name: "Project", workspaceIDs: ids)
            groups.place(ids[1], in: group, workspaceIDs: ids)
            groups.moveItems(workspaceIDs: ids, fromOffsets: [2], toOffset: 1)
            groups.remove(group, workspaceIDs: ids)
            #expect(groups.groups.isEmpty)
            #expect(groups.items(workspaceIDs: ids) == ids.map(WorkspaceSidebarItem.workspace))
        }
    }

    @Test("Deleted and pinned IDs stay out of the movable list; new workspaces appear once")
    func missingAndNewWorkspaces() throws {
        try withGroups { groups, _ in
            let ids = [UUID(), UUID(), UUID()]
            let group = groups.add(name: "Project", workspaceIDs: ids)
            groups.place(ids[1], in: group, workspaceIDs: ids)
            let added = UUID()
            #expect(groups.orderedWorkspaceIDs([ids[2], added]) == [ids[2], added])
            #expect(groups.items(workspaceIDs: []).contains(.group(group)))
            groups.forget(ids[1])
            #expect(groups.group(group)?.workspaceIDs.isEmpty == true)
        }
    }

    @Test("Moving members between groups and out of groups preserves uniqueness")
    func membership() throws {
        try withGroups { groups, _ in
            let ids = [UUID(), UUID()]
            let first = groups.add(name: "First", workspaceIDs: ids)
            let second = groups.add(name: "Second", workspaceIDs: ids)
            groups.place(ids[0], in: first, workspaceIDs: ids)
            groups.place(ids[0], in: second, workspaceIDs: ids)
            #expect(groups.group(first)?.workspaceIDs.isEmpty == true)
            #expect(groups.group(second)?.workspaceIDs == [ids[0]])
            groups.place(ids[0], in: nil, workspaceIDs: ids, atTop: true)
            #expect(groups.items(workspaceIDs: ids).first == .workspace(ids[0]))
            #expect(groups.orderedWorkspaceIDs(ids) == ids)
        }
    }

    private func withGroups(_ body: (WorkspaceGroups, UserDefaults) throws -> Void) throws {
        let suite = "WorkspaceGroupsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(WorkspaceGroups(defaults: defaults), defaults)
    }
}
