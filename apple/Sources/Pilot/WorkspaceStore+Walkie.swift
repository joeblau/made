import Foundation

extension WorkspaceStore {
    /// A transport-only workspace representing the Mac's remote desktop tabs.
    /// It never becomes a persisted Workspace or replaces the local selection.
    static let remoteDesktopWorkspaceID = UUID(uuid: (
        0x8E, 0xA1, 0x8C, 0xC4, 0xB4, 0xF0, 0x4E, 0xAF,
        0x89, 0x80, 0x94, 0x1B, 0xC8, 0x69, 0x99, 0x21
    ))

    var syncSummaries: [WorkspaceSummary] {
        let workspaceSummaries = summaries
        let connections = remoteConnections
        // A Remote Desktop hidden from the sidebar is not offered to Walkie either.
        guard isSidebarFeatureVisible(.remoteDesktop), !connections.isEmpty || isRemoteDesktopMode else { return workspaceSummaries }
        let remoteDesktop = WorkspaceSummary(
            id: Self.remoteDesktopWorkspaceID,
            name: "Remote Desktop",
            isPinned: true,
            tabs: connections.map {
                TabSummary(id: $0.id, title: $0.displayTitle, systemImageName: "display")
            },
            selectedTabID: selectedRemoteConnectionID
        )
        return [remoteDesktop] + workspaceSummaries
    }

    var selectedSyncWorkspaceID: UUID? {
        isRemoteDesktopMode ? Self.remoteDesktopWorkspaceID : selectedWorkspaceID
    }

    @discardableResult
    func selectRemoteDesktopTab(_ id: UUID) -> Bool {
        guard isSidebarFeatureVisible(.remoteDesktop), remoteConnections.contains(where: { $0.id == id }) else { return false }
        selectedRemoteConnectionID = id
        enterRemoteDesktopMode()
        return true
    }
}
