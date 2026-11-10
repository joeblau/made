import AppKit
import SwiftData
import Observation

enum PilotWindowID {
    static let main = "pilot-main"
    static let extendo = "pilot-extendo"
    static let extendoTitle = "Extendo"
}

/// Durable ownership record for the hidden Workspace rendered by Extension.
/// Keeping the marker in a new V2-only model leaves the shipped Workspace/Pane
/// V1 schema untouched while letting SwiftData persist every pane property,
/// relationship, layout fraction, browser URL, and editor selection natively.
@Model
final class ExtensionWorkspaceLink {
    var sourceWorkspaceID: UUID = UUID()

    @Relationship(deleteRule: .cascade)
    var workspace: Workspace?

    init(sourceWorkspaceID: UUID, workspace: Workspace) {
        self.sourceWorkspaceID = sourceWorkspaceID
        self.workspace = workspace
    }
}

enum PilotWindowLaunchPolicy {
    static func opensByDefault(_ windowID: String) -> Bool {
        windowID == PilotWindowID.main || windowID == PilotWindowID.extendo
    }

    /// The extension can be restored by macOS without the main scene. Requiring
    /// Main on every fresh extension appearance repairs that restoration state
    /// while a singleton `Window` keeps the call idempotent.
    static func requiredCompanion(for windowID: String) -> String? {
        windowID == PilotWindowID.extendo ? PilotWindowID.main : nil
    }
}

/// Resolves remote terminal input without baking Main-window ownership into the
/// transport protocol. Walkie knows the canonical project ID, while Cockpit is
/// the only process that knows which local window and pane are active.
@MainActor
enum PilotRemoteInputRoutingPolicy {
    static func surface(
        activeWindowID: CGWindowID?,
        mainWindowID: CGWindowID?,
        extensionWindowID: CGWindowID?
    ) -> WorkspacePaneSurface? {
        guard let activeWindowID else { return nil }
        if activeWindowID == extensionWindowID { return .extension }
        if activeWindowID == mainWindowID { return .main }
        return nil
    }

    static func terminalPane(
        on surface: WorkspacePaneSurface,
        mainWorkspace: Workspace?,
        extensionWorkspace: Workspace?
    ) -> Pane? {
        let workspace = surface == .main ? mainWorkspace : extensionWorkspace
        guard let workspace else { return nil }

        // Prefer the visibly selected terminal. `frontmostTerminalPane` remains
        // the intentional fallback when a browser/editor is selected because
        // remote speech is a voice-to-terminal feature.
        if let selectedPane = workspace.selectedPane,
           selectedPane.kind == .terminal,
           !selectedPane.isCollapsed {
            return selectedPane
        }
        return workspace.frontmostTerminalPane
    }
}

@MainActor
@Observable
final class ExtensionWindowVisibility {
    static let shared = ExtensionWindowVisibility()
    var isVisible = false
}

enum ExtensionWindowShortcut: Equatable {
    case toggleDrawing

    static func match(modifierFlags: NSEvent.ModifierFlags, characters: String?) -> Self? {
        let routingFlags = modifierFlags.intersection([.command, .control, .option, .shift])
        let key = characters?.lowercased()

        switch (routingFlags, key) {
        case ([.command, .shift], "d"): return .toggleDrawing
        default: return nil
        }
    }
}

enum PilotWindowCloseMenuInstaller {
    @MainActor static func stockCloseMenuItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item -> [NSMenuItem] in
            if let submenu = item.submenu { return stockCloseMenuItems(in: submenu) }
            return item.action == #selector(NSWindow.performClose(_:)) && item.keyEquivalent == "w" ? [item] : []
        }
    }
}

@MainActor
@Observable
final class ExtensionWorkspaceController {
    private let modelContext: ModelContext
    private let onMembershipChange: @MainActor () -> Void
    private let performSave: (ModelContext) throws -> Void
    private var workspacesBySourceID: [UUID: Workspace] = [:]
    private(set) var selectedSourceID: UUID?

    init(
        modelContext: ModelContext,
        onMembershipChange: @escaping @MainActor () -> Void = {},
        performSave: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.modelContext = modelContext
        self.onMembershipChange = onMembershipChange
        self.performSave = performSave
    }

    var selectedWorkspace: Workspace? {
        guard let selectedSourceID else { return nil }
        return workspacesBySourceID[selectedSourceID]
    }

    /// Every live companion workspace in a stable order. Extendo mounts all of
    /// them and toggles visibility (main-window style) so terminals, browsers,
    /// and editors keep their runtime state across workspace switches instead
    /// of re-bootstrapping on every tab change.
    var mountedWorkspaces: [(sourceID: UUID, workspace: Workspace)] {
        workspacesBySourceID
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .map { (sourceID: $0.key, workspace: $0.value) }
    }

    func closeSelectedPane() {
        guard let workspace = selectedWorkspace,
              let pane = workspace.selectedPane else { return }
        workspace.requestClosePane(pane)
    }

    func synchronize(with source: Workspace?) {
        guard let source else {
            selectedSourceID = nil
            return
        }

        let workspace: Workspace
        var runtimeTeardowns: [PaneRuntimeTeardown] = []
        if let existing = workspacesBySourceID[source.id] {
            workspace = existing
        } else {
            let persisted = persistedWorkspace(for: source.id)
            runtimeTeardowns = persisted.runtimeTeardowns
            workspace = persisted.workspace ?? makePersistedWorkspace(from: source)
            workspacesBySourceID[source.id] = workspace
        }

        synchronizeMetadata(from: source, to: workspace)
        // An Extendo workspace whose panes were all closed earlier shows New Tab.
        workspace.ensureNewTabWhenEmpty()
        selectedSourceID = source.id
        guard modelContext.saveReporting(
            operation: "Saving Extendo workspace",
            rollbackOnFailure: !runtimeTeardowns.isEmpty,
            performSave: performSave
        ) else { return }
        performRuntimeTeardowns(runtimeTeardowns)
    }

    func workspace(forSourceID sourceID: UUID) -> Workspace? {
        workspacesBySourceID[sourceID]
    }

    func update(with source: Workspace?, validSourceIDs: Set<UUID>) {
        reconcile(validSourceIDs: validSourceIDs)
        guard let source, validSourceIDs.contains(source.id) else {
            selectedSourceID = nil
            return
        }
        synchronize(with: source)
    }

    func reconcile(validSourceIDs: Set<UUID>) {
        let removedSourceIDs = workspacesBySourceID.keys.filter { !validSourceIDs.contains($0) }
        for sourceID in removedSourceIDs {
            // WorkspaceStore owns canonical deletion and its cascade. Discard
            // the potentially invalidated cached model without touching it.
            workspacesBySourceID.removeValue(forKey: sourceID)
        }
        deleteOrphanedLinks(excluding: validSourceIDs)
        if let selectedSourceID, !validSourceIDs.contains(selectedSourceID) {
            self.selectedSourceID = nil
        }
    }

    /// Releases expensive window-bound sessions while retaining terminal tmux
    /// identities and every persisted pane model for the next presentation.
    func suspend() {
        for workspace in workspacesBySourceID.values {
            for pane in workspace.panes {
                pane.suspendRuntimeResources()
            }
        }
        _ = modelContext.saveReporting(operation: "Saving Extendo workspaces")
    }

    private func makePersistedWorkspace(from source: Workspace) -> Workspace {
        let workspace = Workspace(name: source.name)
        let rootPath = source.effectiveRootPath ?? ""
        workspace.rootPath = rootPath
        // The extension inherits its source root; an extension terminal's `cd`
        // must not silently detach browser/editor panes from that source.
        workspace.rootPathSource = .manual
        workspace.sortedPanes.first?.currentDirectory = rootPath
        workspace.startOnNewTab()
        let link = ExtensionWorkspaceLink(sourceWorkspaceID: source.id, workspace: workspace)
        modelContext.insert(workspace)
        modelContext.insert(link)
        onMembershipChange()
        return workspace
    }

    private func persistedWorkspace(
        for sourceWorkspaceID: UUID
    ) -> (workspace: Workspace?, runtimeTeardowns: [PaneRuntimeTeardown]) {
        let matchingLinks = links().filter { $0.sourceWorkspaceID == sourceWorkspaceID }
        let retainedLink = matchingLinks.first { $0.workspace != nil }
        var runtimeTeardowns: [PaneRuntimeTeardown] = []
        for duplicate in matchingLinks where duplicate !== retainedLink {
            if let workspace = duplicate.workspace {
                runtimeTeardowns += prepareForDeletion(workspace)
            }
            modelContext.delete(duplicate)
        }
        if matchingLinks.count > 1 {
            onMembershipChange()
        }
        return (retainedLink?.workspace, runtimeTeardowns)
    }

    private func links() -> [ExtensionWorkspaceLink] {
        (try? modelContext.fetch(FetchDescriptor<ExtensionWorkspaceLink>())) ?? []
    }

    private func deleteOrphanedLinks(excluding validSourceIDs: Set<UUID>) {
        var deletedLink = false
        var runtimeTeardowns: [PaneRuntimeTeardown] = []
        for link in links() where !validSourceIDs.contains(link.sourceWorkspaceID) {
            if let workspace = link.workspace {
                runtimeTeardowns += prepareForDeletion(workspace)
            }
            modelContext.delete(link)
            deletedLink = true
        }
        if deletedLink {
            guard modelContext.saveReporting(
                operation: "Deleting orphaned Extendo workspaces",
                rollbackOnFailure: true,
                performSave: performSave
            ) else {
                onMembershipChange()
                return
            }
            performRuntimeTeardowns(runtimeTeardowns)
            onMembershipChange()
        }
    }

    private func synchronizeMetadata(from source: Workspace, to workspace: Workspace) {
        workspace.name = source.name

        let previousRootPath = workspace.rootPath
        let nextRootPath = source.effectiveRootPath ?? ""
        guard previousRootPath != nextRootPath else { return }

        workspace.rootPath = nextRootPath
        workspace.rootPathSource = .manual
        for pane in workspace.panes where pane.kind == .terminal {
            let currentDirectory = pane.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            if currentDirectory.isEmpty || currentDirectory == previousRootPath {
                pane.currentDirectory = nextRootPath
            }
        }
    }

    /// Captures, without destroying, the runtime of every pane in a workspace
    /// about to be deleted. The caller performs it only after the save (#438).
    private func prepareForDeletion(_ workspace: Workspace) -> [PaneRuntimeTeardown] {
        workspace.panes.map { $0.prepareRuntimeTeardown() }
    }

    private func performRuntimeTeardowns(_ teardowns: [PaneRuntimeTeardown]) {
        for teardown in teardowns {
            teardown.perform()
        }
    }
}

struct ExtensionWorkspaceSource: Hashable {
    let id: UUID
    let name: String
    let rootPath: String?

    init?(_ workspace: Workspace?) {
        guard let workspace else { return nil }
        self.id = workspace.id
        self.name = workspace.name
        self.rootPath = workspace.effectiveRootPath
    }
}

struct ExtensionWorkspaceSyncState: Hashable {
    let source: ExtensionWorkspaceSource?
    let sourceWorkspaceIDs: [UUID]
}
