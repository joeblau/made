import SwiftUI

/// Use one explicit item provider for both reordering and group membership,
/// so every row exports the format handled by the sidebar's insertion targets.
struct WorkspaceSidebarList<WorkspaceRow: View>: View {
    let store: WorkspaceStore
    @Binding var selection: SidebarSelection?
    @Binding var pinnedExpanded: Bool
    @Binding var workspacesExpanded: Bool
    let onRenameGroup: (WorkspaceGroup) -> Void
    @ViewBuilder var workspaceRow: (Workspace) -> WorkspaceRow

    var body: some View {
        let workspaces = store.workspaces
        List(selection: $selection) {
            let pinned = workspaces.filter(\.isPinned)

            Section {
                Label("Notes", systemImage: "note.text")
                    .tag(SidebarSelection.notes)
                Label("Remote Desktop", systemImage: "macbook.and.iphone")
                    .tag(SidebarSelection.remoteDesktop)
                Label("Docker", systemImage: "shippingbox")
                    .tag(SidebarSelection.docker)
                Label("Agentic Use", systemImage: "chart.bar.xaxis")
                    .tag(SidebarSelection.agenticUse)
            }

            if !pinned.isEmpty {
                Section(isExpanded: $pinnedExpanded) {
                    ForEach(pinned) { workspace in
                        workspaceRow(workspace)
                    }
                    .onInsert(of: [.pilotWorkspace]) { index, providers in
                        WorkspaceSidebarDragPayload.load(providers) { item in
                            store.acceptPinnedWorkspaceDrop(item, at: index)
                        }
                    }
                } header: {
                    WorkspaceSidebarHeading(title: "Pinned")
                }
            }

            Section(isExpanded: $workspacesExpanded) {
                let rows = store.workspaceGroups.visibleRows(workspaceIDs: store.unpinnedWorkspaceIDs)
                ForEach(rows) { row in
                    switch row {
                    case .workspace(let id, let groupID):
                        if let workspace = workspaces.first(where: { $0.id == id }) {
                            workspaceRow(workspace)
                                .padding(.leading, groupID == nil ? 0 : 16)
                                .onDrop(of: [.pilotWorkspace], isTargeted: nil) { providers in
                                    WorkspaceSidebarDragPayload.load(providers) { item in
                                        store.acceptSidebarDrop(item, before: row)
                                    }
                                }
                        }
                    case .group(let id):
                        if let group = store.workspaceGroups.group(id) {
                            WorkspaceGroupSidebarRow(group: group, store: store) { onRenameGroup(group) }
                        }
                    case .emptyGroup(let id):
                        Text("Drop workspaces here")
                            .scaledFont(size: 11)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 16)
                            .contentShape(Rectangle())
                            .onDrop(of: [.pilotWorkspace], isTargeted: nil) { providers in
                                WorkspaceSidebarDragPayload.load(providers) { item in
                                    store.acceptWorkspaceDrop([item], toGroup: id)
                                }
                            }
                    }
                }
                .onInsert(of: [.pilotWorkspace]) { index, providers in
                    guard (0...rows.count).contains(index) else { return }
                    let target = index < rows.count ? rows[index] : nil
                    WorkspaceSidebarDragPayload.load(providers) { item in
                        store.acceptSidebarDrop(item, before: target)
                    }
                }
            } header: {
                WorkspaceSidebarHeading(title: "Workspaces")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onDrop(of: [.pilotWorkspace], isTargeted: nil) { providers in
                        WorkspaceSidebarDragPayload.load(providers) { item in
                            store.acceptWorkspaceDrop([item], toGroup: nil)
                        }
                    }
            }
        }
    }
}
