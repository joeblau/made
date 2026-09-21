import SwiftUI

struct WorkspaceGroup: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var workspaceIDs: [UUID] = []
    var isExpanded = true
}

enum WorkspaceSidebarItem: Codable, Hashable, Identifiable {
    case workspace(UUID)
    case group(UUID)

    var id: Self { self }
}

/// Sidebar organization is local presentation state, like RemoteDesktopGroups.
/// Workspace content stays in SwiftData; this layout only stores references.
@MainActor
@Observable
final class WorkspaceGroups {
    private(set) var groups: [WorkspaceGroup] = []
    private var order: [WorkspaceSidebarItem] = []
    @ObservationIgnored private let defaults: UserDefaults
    private static let storageKey = "workspaceGroups.v1"

    private struct Layout: Codable {
        var groups: [WorkspaceGroup]
        var order: [WorkspaceSidebarItem]
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let layout = try? JSONDecoder().decode(Layout.self, from: data) {
            _groups = layout.groups
            _order = layout.order
        }
    }

    func items(workspaceIDs: [UUID]) -> [WorkspaceSidebarItem] {
        let grouped = Set(groups.flatMap(\.workspaceIDs))
        let available = Set(workspaceIDs.filter { !grouped.contains($0) }.map(WorkspaceSidebarItem.workspace)
            + groups.map { .group($0.id) })
        var seen = Set<WorkspaceSidebarItem>()
        return (order + workspaceIDs.map(WorkspaceSidebarItem.workspace) + groups.map { .group($0.id) })
            .filter { available.contains($0) && seen.insert($0).inserted }
    }

    func orderedWorkspaceIDs(_ workspaceIDs: [UUID]) -> [UUID] {
        let available = Set(workspaceIDs)
        return items(workspaceIDs: workspaceIDs).flatMap { item -> [UUID] in
            switch item {
            case .workspace(let id): [id]
            case .group(let id): (group(id)?.workspaceIDs ?? []).filter { available.contains($0) }
            }
        }
    }

    func group(_ id: UUID) -> WorkspaceGroup? { groups.first { $0.id == id } }

    @discardableResult
    func add(name: String, workspaceIDs: [UUID]) -> UUID {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = WorkspaceGroup(name: name.isEmpty ? "New Group" : name)
        order = items(workspaceIDs: workspaceIDs)
        groups.append(group)
        order.append(.group(group.id))
        save()
        return group.id
    }

    func rename(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = name
        save()
    }

    func setExpanded(_ id: UUID, _ expanded: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].isExpanded = expanded
        save()
    }

    func moveItems(workspaceIDs: [UUID], fromOffsets: IndexSet, toOffset: Int) {
        order = items(workspaceIDs: workspaceIDs)
        order.move(fromOffsets: fromOffsets, toOffset: toOffset)
        save()
    }

    func moveMembers(_ id: UUID, workspaceIDs: [UUID], fromOffsets: IndexSet, toOffset: Int) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        let available = Set(workspaceIDs)
        var members = groups[index].workspaceIDs.filter { available.contains($0) }
        members.move(fromOffsets: fromOffsets, toOffset: toOffset)
        groups[index].workspaceIDs = members
        save()
    }

    func place(_ workspaceID: UUID, in groupID: UUID?, workspaceIDs: [UUID], atTop: Bool = false) {
        guard groupID == nil || groupID.flatMap(group) != nil else { return }
        order = items(workspaceIDs: workspaceIDs).filter { $0 != .workspace(workspaceID) }
        for index in groups.indices {
            groups[index].workspaceIDs.removeAll { $0 == workspaceID }
        }
        if let index = groups.firstIndex(where: { $0.id == groupID }) {
            groups[index].workspaceIDs.append(workspaceID)
            groups[index].isExpanded = true
        } else {
            order.insert(.workspace(workspaceID), at: atTop ? 0 : order.count)
        }
        save()
    }

    /// Removing a group releases its workspaces at the group's former position.
    func remove(_ id: UUID, workspaceIDs: [UUID]) {
        guard let group = group(id) else { return }
        order = items(workspaceIDs: workspaceIDs)
        if let index = order.firstIndex(of: .group(id)) {
            order.remove(at: index)
            order.insert(contentsOf: group.workspaceIDs.filter { workspaceIDs.contains($0) }
                .map(WorkspaceSidebarItem.workspace), at: index)
        }
        groups.removeAll { $0.id == id }
        save()
    }

    func forget(_ id: UUID) {
        order.removeAll { $0 == .workspace(id) }
        for index in groups.indices { groups[index].workspaceIDs.removeAll { $0 == id } }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Layout(groups: groups, order: order)) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
