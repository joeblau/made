import SwiftData
import SwiftUI

@Observable
@MainActor
final class WorkspaceStore {
    let modelContext: ModelContext
    var changeCount: Int = 0
    var selectedWorkspaceID: UUID? {
        didSet {
            if let id = selectedWorkspaceID {
                UserDefaults.standard.set(id.uuidString, forKey: "selectedWorkspaceID")
                // Looking at a workspace clears its "Action completed" badge,
                // mirroring how selecting clears terminal bells.
                if let workspace = workspaces.first(where: { $0.id == id }),
                   workspace.actionBadgeCount != 0 {
                    workspace.resetActionBadge()
                    _ = modelContext.saveReporting()
                    changeCount += 1
                }
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedWorkspaceID")
            }
        }
    }

    /// True while the global Notes mode is showing in the detail area
    /// (toggled with ⌘0). Independent of `selectedWorkspaceID` so toggling
    /// out of Notes returns to whatever workspace was selected.
    var isNotesMode: Bool = false {
        didSet {
            UserDefaults.standard.set(isNotesMode, forKey: "notesMode")
            // Notes, Remote Desktop, Docker, and Agentic Use are all
            // full-detail global modes; entering one exits the others.
            if isNotesMode {
                isRemoteDesktopMode = false
                isDockerMode = false
                isAgenticUseMode = false
            }
        }
    }

    /// True while the global Remote Desktop mode is showing in the detail area
    /// (toggled with ⇧⌘0). Mutually exclusive with the other global modes.
    var isRemoteDesktopMode: Bool = false {
        didSet {
            UserDefaults.standard.set(isRemoteDesktopMode, forKey: "remoteDesktopMode")
            if isRemoteDesktopMode {
                isNotesMode = false
                isDockerMode = false
                isAgenticUseMode = false
            }
        }
    }

    /// True while the global Docker mode is showing in the detail area (toggled
    /// with ⌃⌘0). Mutually exclusive with the other global modes.
    var isDockerMode: Bool = false {
        didSet {
            UserDefaults.standard.set(isDockerMode, forKey: "dockerMode")
            if isDockerMode {
                isNotesMode = false
                isRemoteDesktopMode = false
                isAgenticUseMode = false
            }
        }
    }

    /// True while the global Agentic Use mode is showing in the detail area.
    /// Mutually exclusive with the other global modes.
    var isAgenticUseMode: Bool = false {
        didSet {
            UserDefaults.standard.set(isAgenticUseMode, forKey: "agenticUseMode")
            if isAgenticUseMode {
                isNotesMode = false
                isRemoteDesktopMode = false
                isDockerMode = false
            }
        }
    }

    /// True when the detail area belongs to the selected workspace rather than
    /// to one of the full-detail global modes. Every workspace-scoped surface
    /// (pane activation, the ink overlay, ⌘W) keys off this rather than
    /// re-listing the modes.
    var isWorkspaceDetailVisible: Bool {
        !isNotesMode && !isRemoteDesktopMode && !isDockerMode && !isAgenticUseMode
    }

    var selectedRemoteConnectionID: UUID? {
        didSet {
            if let id = selectedRemoteConnectionID {
                UserDefaults.standard.set(id.uuidString, forKey: "selectedRemoteConnectionID")
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedRemoteConnectionID")
            }
        }
    }

    var selectedNoteID: UUID? {
        didSet {
            if let id = selectedNoteID {
                UserDefaults.standard.set(id.uuidString, forKey: "selectedNoteID")
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedNoteID")
            }
        }
    }

    /// Fetch caches: `workspaces`/`notes` are read many times per view render
    /// (sidebar, selection lookups, summaries), and a SwiftData fetch hits the
    /// store every time. Membership only changes through this class's mutating
    /// funcs — each bumps `changeCount` — so the raw fetch is cached against
    /// it. Sorting stays per-access: it reads live model properties (name,
    /// isPinned, sortOrder), which keeps observation of those properties
    /// intact for views that depend on the order. `@ObservationIgnored` keeps
    /// the cache writes from invalidating views mid-render.
    @ObservationIgnored private var fetchedWorkspaces: [Workspace]?
    @ObservationIgnored private var workspacesFetchVersion = -1
    @ObservationIgnored private var fetchedNotes: [Note]?
    @ObservationIgnored private var notesFetchVersion = -1
    @ObservationIgnored private var fetchedRemoteConnections: [RemoteDesktopConnection]?
    @ObservationIgnored private var remoteConnectionsFetchVersion = -1

    var workspaces: [Workspace] {
        let version = changeCount // access to establish observation dependency
        let items: [Workspace]
        if let cached = fetchedWorkspaces, workspacesFetchVersion == version {
            items = cached
        } else {
            let descriptor = FetchDescriptor<Workspace>()
            items = (try? modelContext.fetch(descriptor)) ?? []
            fetchedWorkspaces = items
            workspacesFetchVersion = version
        }

        let extensionWorkspaceIDs = Set(extensionWorkspaceLinks.compactMap { $0.workspace?.id })
        return items.filter { !extensionWorkspaceIDs.contains($0.id) }.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }

            if lhs.workspaceSortOrder != rhs.workspaceSortOrder {
                return lhs.workspaceSortOrder < rhs.workspaceSortOrder
            }

            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Extension companion workspaces are created and pruned by a sibling
    /// controller that shares this context. Invalidate the canonical-workspace
    /// fetch cache whenever that hidden membership changes so a deleted
    /// companion can never briefly surface in Main from a stale cache entry.
    func extensionWorkspaceMembershipDidChange() {
        fetchedWorkspaces = nil
        workspacesFetchVersion = -1
        changeCount += 1
    }

    /// Called by `WorkspaceActionWatcher` when a GitHub Action run completes
    /// for a background workspace. Bumps its badge and refreshes observers +
    /// the Copilot summaries.
    func badgeActionCompletion(workspaceID: UUID) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
        workspace.incrementActionBadge()
        _ = modelContext.saveReporting(operation: "Saving workspace action badge")
        changeCount += 1
    }

    func togglePin(_ workspace: Workspace) {
        let remaining = workspaces.filter { $0.id != workspace.id }

        workspace.isPinned.toggle()

        var pinned = remaining.filter(\.isPinned)
        var unpinned = remaining.filter { !$0.isPinned }

        if workspace.isPinned {
            // Joins the end of the pinned section: pinning is an additive act,
            // and displacing the workspace the user pinned first would reorder
            // a list they arranged deliberately.
            pinned.append(workspace)
        } else {
            // Unpinning surfaces it at the top of the unpinned section, where
            // it stays in easy reach right after leaving the pinned group.
            unpinned.insert(workspace, at: 0)
        }

        normalizeWorkspaceSortOrder(pinned + unpinned)
        _ = modelContext.saveReporting()
        changeCount += 1
    }

    func movePinnedWorkspaces(fromOffsets: IndexSet, toOffset: Int) {
        moveWorkspaces(inPinnedSection: true, fromOffsets: fromOffsets, toOffset: toOffset)
    }

    func moveUnpinnedWorkspaces(fromOffsets: IndexSet, toOffset: Int) {
        moveWorkspaces(inPinnedSection: false, fromOffsets: fromOffsets, toOffset: toOffset)
    }

    var selectedWorkspace: Workspace? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    /// Make a workspace the active global surface. Both Pilot windows use this
    /// entry point so selecting a workspace in either one also brings the main
    /// window out of a full-detail Notes or Remote Desktop mode.
    func selectWorkspace(_ workspaceID: UUID) {
        guard workspaces.contains(where: { $0.id == workspaceID }) else { return }
        if isNotesMode { isNotesMode = false }
        if isRemoteDesktopMode { isRemoteDesktopMode = false }
        if isDockerMode { isDockerMode = false }
        if isAgenticUseMode { isAgenticUseMode = false }
        if selectedWorkspaceID != workspaceID {
            selectedWorkspaceID = workspaceID
        }
    }

    var notes: [Note] {
        let version = changeCount // access to establish observation dependency
        if let cached = fetchedNotes, notesFetchVersion == version {
            return cached
        }
        let descriptor = FetchDescriptor<Note>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]
        )
        let items = (try? modelContext.fetch(descriptor)) ?? []
        fetchedNotes = items
        notesFetchVersion = version
        return items
    }

    var selectedNote: Note? {
        notes.first { $0.id == selectedNoteID }
    }

    /// Set when a close was requested for a note that still has content, so
    /// the Notes UI can confirm before the (undo-free) delete. Transient —
    /// not persisted.
    var notePendingClose: Note?

    /// Closing a note tab deletes the note. Confirm first when there's content
    /// to lose; close empty notes immediately so creating + dismissing a blank
    /// note doesn't nag. Shared by the tab's ✕ button and ⌘W.
    func requestCloseNote(_ note: Note) {
        if note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            deleteNote(note)
        } else {
            notePendingClose = note
        }
    }

    /// ⌘0: flip into Notes mode (ensuring there's a note to show) or back
    /// out to the previously selected workspace.
    func toggleNotesMode() {
        if isNotesMode {
            isNotesMode = false
        } else {
            enterNotesMode()
        }
    }

    func enterNotesMode() {
        ensureAtLeastOneNote()
        isNotesMode = true
    }

    @discardableResult
    func addNote() -> Note {
        let maxOrder = notes.map(\.sortOrder).max() ?? -1
        let note = Note(sortOrder: maxOrder + 1)
        modelContext.insert(note)
        _ = modelContext.saveReporting()
        changeCount += 1
        selectedNoteID = note.id
        return note
    }

    func deleteNote(_ note: Note) {
        let wasSelected = selectedNoteID == note.id
        let remaining = notes.filter { $0.id != note.id }
        modelContext.delete(note)
        for (index, remainingNote) in remaining.enumerated() {
            remainingNote.sortOrder = index
        }
        guard modelContext.saveReporting(operation: "Deleting note", rollbackOnFailure: true) else {
            changeCount += 1
            return
        }
        changeCount += 1
        if wasSelected {
            selectedNoteID = remaining.first?.id
        }
    }

    /// Drag-to-reorder a note tab (issue #67): place the dragged note just
    /// before the drop-target note and renumber every note's `sortOrder` so the
    /// new order persists across launches.
    func moveNote(_ draggedID: UUID, before targetID: UUID) {
        guard draggedID != targetID else { return }
        var ordered = notes
        guard let from = ordered.firstIndex(where: { $0.id == draggedID }),
              let to = ordered.firstIndex(where: { $0.id == targetID }) else { return }
        ordered.move(fromOffsets: IndexSet(integer: from), toOffset: to)
        normalizeNoteSortOrder(ordered)
    }

    /// Drop a dragged note past the last tab to send it to the end.
    func moveNoteToEnd(_ draggedID: UUID) {
        var ordered = notes
        guard let from = ordered.firstIndex(where: { $0.id == draggedID }),
              from != ordered.count - 1 else { return }
        ordered.move(fromOffsets: IndexSet(integer: from), toOffset: ordered.count)
        normalizeNoteSortOrder(ordered)
    }

    private func normalizeNoteSortOrder(_ ordered: [Note]) {
        for (index, note) in ordered.enumerated() {
            note.sortOrder = index
        }
        _ = modelContext.saveReporting()
        changeCount += 1
    }

    private func ensureAtLeastOneNote() {
        if notes.isEmpty {
            addNote()
        } else if selectedNote == nil {
            selectedNoteID = notes.first?.id
        }
    }

    // MARK: - Remote Desktop connections

    var remoteConnections: [RemoteDesktopConnection] {
        let version = changeCount // access to establish observation dependency
        if let cached = fetchedRemoteConnections, remoteConnectionsFetchVersion == version {
            return cached
        }
        let descriptor = FetchDescriptor<RemoteDesktopConnection>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]
        )
        let items = (try? modelContext.fetch(descriptor)) ?? []
        fetchedRemoteConnections = items
        remoteConnectionsFetchVersion = version
        return items
    }

    var selectedRemoteConnection: RemoteDesktopConnection? {
        remoteConnections.first { $0.id == selectedRemoteConnectionID }
    }

    /// Set when closing a connection tab so the UI can confirm before the
    /// (undo-free) delete. Transient — not persisted.
    var remoteConnectionPendingClose: RemoteDesktopConnection?

    /// ⇧⌘0: flip into Remote Desktop mode (selecting a connection if one
    /// exists) or back out to the previously selected workspace.
    func toggleRemoteDesktopMode() {
        if isRemoteDesktopMode {
            isRemoteDesktopMode = false
        } else {
            enterRemoteDesktopMode()
        }
    }

    func enterRemoteDesktopMode() {
        if selectedRemoteConnection == nil {
            selectedRemoteConnectionID = remoteConnections.first?.id
        }
        isRemoteDesktopMode = true
    }

    // MARK: - Docker

    /// ⌃⌘0: flip into Docker mode or back out to the selected workspace. Unlike
    /// Notes and Remote Desktop there is nothing to seed first — the container
    /// list is live daemon state, owned by `DockerStore`, not persisted here.
    func toggleDockerMode() {
        isDockerMode.toggle()
    }

    func enterDockerMode() {
        isDockerMode = true
    }

    // MARK: - Agentic Use

    /// Flip into Agentic Use mode or back out to the selected workspace. Like
    /// Docker there is nothing to seed first — the usage analytics are derived
    /// state, owned by `AgenticUsageStore`, not persisted here.
    func toggleAgenticUseMode() {
        isAgenticUseMode.toggle()
    }

    func enterAgenticUseMode() {
        isAgenticUseMode = true
    }

    @discardableResult
    func addRemoteConnection(host: String, port: Int = 5900, nickname: String = "", username: String = "") -> RemoteDesktopConnection {
        let maxOrder = remoteConnections.map(\.sortOrder).max() ?? -1
        let connection = RemoteDesktopConnection(
            host: host, port: port, nickname: nickname, username: username, sortOrder: maxOrder + 1
        )
        modelContext.insert(connection)
        _ = modelContext.saveReporting()
        changeCount += 1
        selectedRemoteConnectionID = connection.id
        return connection
    }

    func requestCloseRemoteConnection(_ connection: RemoteDesktopConnection) {
        remoteConnectionPendingClose = connection
    }

    func deleteRemoteConnection(_ connection: RemoteDesktopConnection) {
        let wasSelected = selectedRemoteConnectionID == connection.id
        let remaining = remoteConnections.filter { $0.id != connection.id }
        modelContext.delete(connection)
        for (index, item) in remaining.enumerated() {
            item.sortOrder = index
        }
        guard modelContext.saveReporting(operation: "Deleting remote desktop connection", rollbackOnFailure: true) else {
            changeCount += 1
            return
        }
        VNCKeychain.delete(id: connection.id)
        VNCPreferences.remove(id: connection.id)
        changeCount += 1
        if wasSelected {
            selectedRemoteConnectionID = remaining.first?.id
        }
    }

    func moveRemoteConnection(_ draggedID: UUID, before targetID: UUID) {
        guard draggedID != targetID else { return }
        var ordered = remoteConnections
        guard let from = ordered.firstIndex(where: { $0.id == draggedID }),
              let to = ordered.firstIndex(where: { $0.id == targetID }) else { return }
        ordered.move(fromOffsets: IndexSet(integer: from), toOffset: to)
        normalizeRemoteConnectionSortOrder(ordered)
    }

    func moveRemoteConnectionToEnd(_ draggedID: UUID) {
        var ordered = remoteConnections
        guard let from = ordered.firstIndex(where: { $0.id == draggedID }),
              from != ordered.count - 1 else { return }
        ordered.move(fromOffsets: IndexSet(integer: from), toOffset: ordered.count)
        normalizeRemoteConnectionSortOrder(ordered)
    }

    private func normalizeRemoteConnectionSortOrder(_ ordered: [RemoteDesktopConnection]) {
        for (index, item) in ordered.enumerated() {
            item.sortOrder = index
        }
        _ = modelContext.saveReporting(operation: "Reordering remote desktop connections")
        changeCount += 1
    }

    var summaries: [WorkspaceSummary] {
        workspaces.map { workspace in
            WorkspaceSummary(
                id: workspace.id,
                name: workspace.name,
                isPinned: workspace.isPinned,
                badgeCount: workspace.badgeCount,
                tabs: Self.tabSummaries(for: workspace),
                selectedTabID: workspace.selectedPaneID
            )
        }
    }

    /// Map a workspace's panes to Copilot tab summaries, numbering panes of
    /// the same kind ("Terminal 1", "Terminal 2") so duplicates are tellable
    /// apart on the phone.
    private static func tabSummaries(for workspace: Workspace) -> [TabSummary] {
        let panes = workspace.sortedPanes
        let totals = Dictionary(grouping: panes, by: \.kind).mapValues(\.count)
        var seen: [PaneKind: Int] = [:]
        return panes.map { pane in
            seen[pane.kind, default: 0] += 1
            let title = (totals[pane.kind] ?? 1) > 1
                ? "\(pane.kind.displayName) \(seen[pane.kind]!)"
                : pane.kind.displayName
            return TabSummary(id: pane.id, title: title, systemImageName: pane.kind.systemImageName)
        }
    }

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        if let stored = UserDefaults.standard.string(forKey: "selectedWorkspaceID") {
            self.selectedWorkspaceID = UUID(uuidString: stored)
        }
        if let storedNote = UserDefaults.standard.string(forKey: "selectedNoteID") {
            self.selectedNoteID = UUID(uuidString: storedNote)
        }
        self.isNotesMode = UserDefaults.standard.bool(forKey: "notesMode")
        if let storedRemote = UserDefaults.standard.string(forKey: "selectedRemoteConnectionID") {
            self.selectedRemoteConnectionID = UUID(uuidString: storedRemote)
        }
        self.isRemoteDesktopMode = UserDefaults.standard.bool(forKey: "remoteDesktopMode")
        self.isDockerMode = UserDefaults.standard.bool(forKey: "dockerMode")
        self.isAgenticUseMode = UserDefaults.standard.bool(forKey: "agenticUseMode")
        cleanupBadDirectories()
        if let selectedWorkspaceID, !workspaces.contains(where: { $0.id == selectedWorkspaceID }) {
            self.selectedWorkspaceID = workspaces.first?.id
        }
    }

    private func cleanupBadDirectories() {
        let home = NSHomeDirectory()
        let descriptor = FetchDescriptor<Pane>()
        guard let allPanes = try? modelContext.fetch(descriptor) else { return }
        for pane in allPanes {
            let dir = pane.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            if dir == "/" || dir == home {
                pane.currentDirectory = ""
            }
        }
    }

    /// Demo-mode only: seed a couple of representative workspaces so the
    /// sidebar/layout looks intentional for a screenshot when there is no live
    /// peer and no real data. Guarded by the caller on the `demoMode`
    /// UserDefaults bool; additionally a no-op if any workspaces already exist
    /// so a normal launch (with real saved workspaces) is never touched.
    func seedDemoWorkspacesIfNeeded() {
        guard workspaces.isEmpty else { return }

        for workspace in Self.makeDemoWorkspaces() {
            modelContext.insert(workspace)
        }
        _ = modelContext.saveReporting()
        changeCount += 1
        if let workspaceID = workspaces.first?.id {
            selectWorkspace(workspaceID)
        }
    }

    /// Deterministic, offline-only screenshot state. In particular, the
    /// Chromium pane stays blank so demo capture never depends on a public
    /// website or mutable network response.
    static func makeDemoWorkspaces() -> [Workspace] {
        let names = ["made", "web", "infra"]
        return names.enumerated().map { index, name in
            let workspace = Workspace(name: name)
            workspace.workspaceSortOrder = index
            if index == 0 {
                workspace.isPinned = true
            }
            if name == "web" {
                workspace.addBrowserPane(engine: .chromium, side: .right)
            }
            return workspace
        }
    }

    func addWorkspace() {
        let workspace = Workspace(name: "Workspace \(workspaces.count + 1)")
        workspace.workspaceSortOrder = workspaces.count
        modelContext.insert(workspace)
        _ = modelContext.saveReporting()
        changeCount += 1
        selectWorkspace(workspace.id)
    }

    @discardableResult
    func deleteWorkspace(
        _ workspace: Workspace,
        performSave: (ModelContext) throws -> Void = { try $0.save() }
    ) -> Bool {
        let wasSelected = selectedWorkspaceID == workspace.id
        let deletedLinks = extensionWorkspaceLinks.filter { $0.sourceWorkspaceID == workspace.id }
        let deletedPanes = deletedLinks.compactMap(\.workspace).flatMap(\.panes) + workspace.panes
        let deletedDevicePaneIDs = Set(deletedPanes.filter { $0.kind == .device }.map(\.id))
        for pane in deletedPanes {
            pane.tearDownRuntimeResources(preservingDevicePreference: true)
        }
        for link in deletedLinks {
            modelContext.delete(link)
        }
        modelContext.delete(workspace)
        normalizeWorkspaceSortOrder(workspaces.filter { $0.id != workspace.id })
        guard modelContext.saveReporting(
            operation: "Deleting workspace",
            rollbackOnFailure: true,
            performSave: performSave
        ) else {
            changeCount += 1
            return false
        }
        for paneID in deletedDevicePaneIDs {
            DeviceCaptureRegistry.shared.clearPreference(paneID: paneID)
        }
        changeCount += 1
        if wasSelected {
            selectedWorkspaceID = workspaces.first?.id
        }
        return true
    }

    /// Reorders a pane locally or reparents the exact persisted Pane model
    /// between Main and Extension. Keeping the Pane identity preserves tmux and
    /// capture-session registry keys; no runtime teardown occurs during a move.
    @discardableResult
    func movePane(_ payload: WorkspacePaneDragPayload, to destination: Workspace, onto target: Pane) -> Bool {
        let allWorkspaces = (try? modelContext.fetch(FetchDescriptor<Workspace>())) ?? []
        let links = extensionWorkspaceLinks
        guard let source = allWorkspaces.first(where: { $0.id == payload.sourceWorkspaceID }),
              let pane = source.panes.first(where: { $0.id == payload.paneID }),
              allWorkspaces.contains(where: { $0 === destination }),
              destination.panes.contains(where: { $0 === target }),
              let sourceIdentity = paneSurfaceIdentity(for: source, links: links),
              let destinationIdentity = paneSurfaceIdentity(for: destination, links: links),
              sourceIdentity.projectID == payload.projectID,
              sourceIdentity.surface == payload.sourceSurface,
              destinationIdentity.projectID == payload.projectID else { return false }

        if source === destination {
            guard pane !== target else { return false }
            var ordered = source.sortedPanes
            guard let sourceIndex = ordered.firstIndex(where: { $0 === pane }),
                  let targetIndex = ordered.firstIndex(where: { $0 === target }) else { return false }
            ordered.remove(at: sourceIndex)
            // Put the dragged pane in the target's original slot. This places
            // it after the target when moving right and before the target when
            // moving left, so adjacent drops work in both directions.
            ordered.insert(pane, at: min(targetIndex, ordered.endIndex))
            renumberPanes(ordered)
            if !pane.isCollapsed { source.selectedPaneID = pane.id }
            guard modelContext.saveReporting(
                operation: "Reordering pane",
                rollbackOnFailure: true
            ) else { return false }
            changeCount += 1
            return true
        }

        guard sourceIdentity.surface != destinationIdentity.surface,
              source.panes.count > 1,
              !destination.panes.contains(where: { $0.id == pane.id }) else { return false }

        source.prepareForPaneTransfer()
        destination.prepareForPaneTransfer()
        let sourceOrder = source.sortedPanes
        let destinationOrderBeforeMove = destination.sortedPanes
        guard let removedIndex = sourceOrder.firstIndex(where: { $0 === pane }) else { return false }
        guard let targetIndex = destinationOrderBeforeMove.firstIndex(where: { $0 === target }) else { return false }

        source.panes.removeAll { $0 === pane }
        destination.panes.append(pane)
        pane.workspace = destination

        let remainingSourcePanes = source.sortedPanes
        renumberPanes(remainingSourcePanes)
        var selectedFallback: Pane?
        if source.selectedPaneID == pane.id || !remainingSourcePanes.contains(where: { $0.id == source.selectedPaneID }) {
            selectedFallback = nearestPane(
                in: remainingSourcePanes,
                to: removedIndex,
                matching: { !$0.isCollapsed }
            ) ?? nearestPane(in: remainingSourcePanes, to: removedIndex, matching: { _ in true })

            // A focused pane may have been the only expanded pane. Keep the
            // source usable by revealing the nearest survivor instead of
            // leaving every pane collapsed behind slits.
            if let selectedFallback, selectedFallback.isCollapsed {
                selectedFallback.isCollapsed = false
                selectedFallback.wasCollapsedBeforeFocus = false
                selectedFallback.sizeFraction = 1
            }
            source.selectedPaneID = selectedFallback?.id
        }
        if source.frontmostTerminalPaneID == pane.id {
            source.frontmostTerminalPaneID = remainingSourcePanes.first(where: {
                $0.kind == .terminal && !$0.isCollapsed
            })?.id ?? remainingSourcePanes.first(where: { $0.kind == .terminal })?.id
        }
        if selectedFallback?.kind == .terminal {
            source.frontmostTerminalPaneID = selectedFallback?.id
        }

        pane.isCollapsed = false
        pane.wasCollapsedBeforeFocus = false
        pane.sizeFraction = 0
        pane.restoredSizeFraction = 0
        var destinationOrder = destination.sortedPanes.filter { $0 !== pane }
        destinationOrder.insert(pane, at: targetIndex)
        renumberPanes(destinationOrder)
        destination.selectedPaneID = pane.id
        if pane.kind == .terminal {
            destination.frontmostTerminalPaneID = pane.id
        }

        // Selection/frontmost ownership may have changed without a SwiftUI
        // selected-pane notification (for example, a Browser is selected while
        // its frontmost Terminal moves). Keep automatic roots correct inside
        // this same save/rollback transaction.
        source.syncDefaultRootPathForPaneTransfer()
        destination.syncDefaultRootPathForPaneTransfer()

        guard modelContext.saveReporting(
            operation: "Moving pane between Main and Extendo",
            rollbackOnFailure: true
        ) else { return false }
        changeCount += 1
        return true
    }

    private func normalizeWorkspaceSortOrder(_ orderedWorkspaces: [Workspace]) {
        for (index, workspace) in orderedWorkspaces.enumerated() {
            workspace.workspaceSortOrder = index
        }
    }

    private var extensionWorkspaceLinks: [ExtensionWorkspaceLink] {
        (try? modelContext.fetch(FetchDescriptor<ExtensionWorkspaceLink>())) ?? []
    }

    private func paneSurfaceIdentity(
        for workspace: Workspace,
        links: [ExtensionWorkspaceLink]
    ) -> (projectID: UUID, surface: WorkspacePaneSurface)? {
        if let link = links.first(where: { $0.workspace?.id == workspace.id }) {
            guard workspaces.contains(where: { $0.id == link.sourceWorkspaceID }) else { return nil }
            return (link.sourceWorkspaceID, .extension)
        }
        guard workspaces.contains(where: { $0.id == workspace.id }) else { return nil }
        return (workspace.id, .main)
    }

    private func renumberPanes(_ panes: [Pane]) {
        for (index, pane) in panes.enumerated() {
            pane.sortOrder = index
        }
    }

    private func nearestPane(
        in panes: [Pane],
        to index: Int,
        matching predicate: (Pane) -> Bool
    ) -> Pane? {
        panes.enumerated()
            .filter { predicate($0.element) }
            .min { lhs, rhs in
                let lhsDistance = abs(lhs.offset - index)
                let rhsDistance = abs(rhs.offset - index)
                if lhsDistance != rhsDistance {
                    return lhsDistance < rhsDistance
                }
                return lhs.offset < rhs.offset
            }?
            .element
    }

    private func moveWorkspaces(inPinnedSection isPinned: Bool, fromOffsets: IndexSet, toOffset: Int) {
        var pinned = workspaces.filter(\.isPinned)
        var unpinned = workspaces.filter { !$0.isPinned }

        if isPinned {
            pinned.move(fromOffsets: fromOffsets, toOffset: toOffset)
        } else {
            unpinned.move(fromOffsets: fromOffsets, toOffset: toOffset)
        }

        normalizeWorkspaceSortOrder(pinned + unpinned)
        _ = modelContext.saveReporting()
        changeCount += 1
    }
}
