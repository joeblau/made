import AppKit
import SwiftData
import SwiftUI

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

    static func defaultBehavior(for windowID: String) -> SceneLaunchBehavior {
        opensByDefault(windowID) ? .presented : .automatic
    }

    /// The extension can be restored by macOS without the main scene. Requiring
    /// Main on every fresh extension appearance repairs that restoration state
    /// while a singleton `Window` keeps the call idempotent.
    static func requiredCompanion(for windowID: String) -> String? {
        windowID == PilotWindowID.extendo ? PilotWindowID.main : nil
    }
}

/// Resolves remote terminal input without baking Main-window ownership into the
/// transport protocol. Walkie knows the canonical project ID, while made is
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

/// Reports the concrete AppKit window that owns a Pilot surface. Main uses the
/// ID to pin screen mirroring; both Main and Extendo use it to route remote
/// keyboard input to whichever made window was active most recently.
@MainActor
struct PilotWindowReader: NSViewRepresentable {
    var onWindowChange: @MainActor (CGWindowID?) -> Void
    var onWindowActivate: @MainActor () -> Void

    init(
        onWindowChange: @escaping @MainActor (CGWindowID?) -> Void,
        onWindowActivate: @escaping @MainActor () -> Void = {}
    ) {
        self.onWindowChange = onWindowChange
        self.onWindowActivate = onWindowActivate
    }

    func makeNSView(context: Context) -> WindowReaderView {
        WindowReaderView(
            onWindowChange: onWindowChange,
            onWindowActivate: onWindowActivate
        )
    }

    func updateNSView(_ nsView: WindowReaderView, context: Context) {
        nsView.onWindowChange = onWindowChange
        nsView.onWindowActivate = onWindowActivate
    }

    @MainActor
    final class WindowReaderView: NSView {
        var onWindowChange: @MainActor (CGWindowID?) -> Void
        var onWindowActivate: @MainActor () -> Void

        init(
            onWindowChange: @escaping @MainActor (CGWindowID?) -> Void,
            onWindowActivate: @escaping @MainActor () -> Void
        ) {
            self.onWindowChange = onWindowChange
            self.onWindowActivate = onWindowActivate
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didBecomeKeyNotification,
                object: nil
            )
            onWindowChange(window.map { CGWindowID($0.windowNumber) })
            guard let window else { return }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidBecomeKey(_:)),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
            if window.isKeyWindow {
                onWindowActivate()
            }
        }

        @objc private func windowDidBecomeKey(_: Notification) {
            onWindowActivate()
        }
    }
}

/// Tracks whether the Extension window is currently presented, so the Window
/// menu command can toggle between Show and Hide. Maintained by
/// `ExtensionWindowView`'s appear/disappear.
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

private struct ExtensionWindowShortcutMonitor: NSViewRepresentable {
    let onToggleDrawing: @MainActor () -> Void

    func makeNSView(context: Context) -> MonitorView {
        MonitorView(onToggleDrawing: onToggleDrawing)
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onToggleDrawing = onToggleDrawing
    }

    @MainActor
    final class MonitorView: NSView {
        var onToggleDrawing: @MainActor () -> Void
        private var monitor: Any?

        init(onToggleDrawing: @escaping @MainActor () -> Void) {
            self.onToggleDrawing = onToggleDrawing
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else {
                installMonitor()
            }
        }

        override func removeFromSuperview() {
            removeMonitor()
            super.removeFromSuperview()
        }

        private func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        private func removeMonitor() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            // Key-equivalent events do not always retain their originating
            // window by the time local monitors run. Scope by the owning
            // window's key state so ⌘W is still swallowed before AppKit can
            // route it to the default Close Window menu item.
            guard window?.isKeyWindow == true,
                  let shortcut = ExtensionWindowShortcut.match(
                      modifierFlags: event.modifierFlags,
                      characters: event.charactersIgnoringModifiers
                  ) else {
                return event
            }

            switch shortcut {
            case .toggleDrawing: onToggleDrawing()
            }
            return nil
        }
    }
}

/// SwiftUI supplies its own `performClose:` File-menu item with ⌘W. Pilot owns
/// the three close commands instead, so hide only that stock item whenever the
/// merged app menu is rebuilt.
struct PilotWindowCloseMenuInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> GuardView {
        GuardView()
    }

    func updateNSView(_ nsView: GuardView, context: Context) {}

    /// Finds only SwiftUI's auto-generated Close items. Pilot's replacement
    /// commands use closure-backed actions and are therefore excluded.
    static func stockCloseMenuItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item -> [NSMenuItem] in
            if let submenu = item.submenu {
                return stockCloseMenuItems(in: submenu)
            }
            let isClose = item.action == #selector(NSWindow.performClose(_:))
                && item.keyEquivalent == "w"
            return isClose ? [item] : []
        }
    }

    @MainActor
    final class GuardView: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            guard window != nil else { return }

            // SwiftUI can rebuild the merged menu bar on scene state changes,
            // minting fresh Close items; hide them whenever any menu mutates.
            observers.append(
                NotificationCenter.default.addObserver(forName: NSMenu.didAddItemNotification, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        self?.apply()
                    }
                }
            )
            apply()
        }

        override func removeFromSuperview() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            super.removeFromSuperview()
        }

        private func apply() {
            guard let menu = NSApp.mainMenu else { return }
            for item in PilotWindowCloseMenuInstaller.stockCloseMenuItems(in: menu) {
                item.isHidden = true
                item.keyEquivalent = ""
            }
        }
    }
}

@MainActor
struct PilotCloseTabAction {
    let isEnabled: Bool
    let perform: () -> Void
}

private struct PilotCloseTabActionKey: FocusedValueKey {
    typealias Value = PilotCloseTabAction
}

extension FocusedValues {
    var pilotCloseTabAction: PilotCloseTabAction? {
        get { self[PilotCloseTabActionKey.self] }
        set { self[PilotCloseTabActionKey.self] = newValue }
    }
}

/// File-menu close behavior follows standard tabbed macOS apps:
/// ⌘W closes content, ⇧⌘W closes one window, and ⌥⇧⌘W closes all windows.
struct PilotCloseCommands: Commands {
    @FocusedValue(\.pilotCloseTabAction) private var closeTabAction

    var body: some Commands {
        CommandGroup(before: .saveItem) {
            Button("Close Window") {
                NSApp.keyWindow?.performClose(nil)
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])

            Button("Close All Windows") {
                let windows = NSApp.windows.filter {
                    $0.isVisible && $0.styleMask.contains(.closable)
                }
                for window in windows {
                    window.performClose(nil)
                }
            }
            .keyboardShortcut("w", modifiers: [.command, .option, .shift])

            Button("Close Tab") {
                closeTabAction?.perform()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(closeTabAction?.isEnabled != true)
        }
    }
}

/// Window-menu entries for restoring either singleton Pilot window. `Window`,
/// rather than `WindowGroup`, guarantees these actions focus existing windows
/// instead of mounting duplicate terminal/browser/device runtime surfaces.
///
/// Register these commands on exactly ONE scene: SwiftUI merges every scene's
/// `.commands` into the single app menu bar, so attaching them to both the
/// main and extension scenes duplicates every entry in the Window menu.
struct PilotWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Show Main Window") {
                openWindow(id: PilotWindowID.main)
            }
            .keyboardShortcut("n", modifiers: .command)

            let isExtensionVisible = ExtensionWindowVisibility.shared.isVisible
            let extendoCommand = isExtensionVisible
                ? "Hide \(PilotWindowID.extendoTitle)"
                : "Show \(PilotWindowID.extendoTitle)"
            Button(extendoCommand) {
                if isExtensionVisible {
                    dismissWindow(id: PilotWindowID.extendo)
                } else {
                    openWindow(id: PilotWindowID.extendo)
                }
            }
            .keyboardShortcut("e", modifiers: [.command, .option])
        }
    }
}

/// Menu-backed workspace shortcuts for the Extension scene. Menu key
/// equivalents take precedence over focused AppKit surfaces such as Ghostty
/// and WKWebView, making ⌘1…⌘9 reliable from every extension pane.
struct PilotExtensionWorkspaceCommands: Commands {
    let store: WorkspaceStore

    var body: some Commands {
        let workspaces = store.workspaces
        let workspaceNamesByID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0.name) })
        let shortcuts = WorkspaceNumberShortcuts.shortcuts(for: workspaces.map(\.id))

        CommandMenu("Workspaces") {
            ForEach(shortcuts) { shortcut in
                Button(workspaceNamesByID[shortcut.workspaceID] ?? "Workspace \(shortcut.number)") {
                    store.selectWorkspace(shortcut.workspaceID)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(shortcut.number)")), modifiers: .command)
            }
        }
    }
}

/// Owns one durable companion workspace per canonical project. The hidden
/// companion persists Extension-only panes and layouts while distinct pane IDs
/// prevent runtime surfaces from being mounted in both windows at once.
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
        workspace.requestRemovePane(pane)
    }

    func synchronize(with source: Workspace?) {
        guard let source else {
            selectedSourceID = nil
            return
        }

        let workspace: Workspace
        var deletedDevicePaneIDs: Set<UUID> = []
        if let existing = workspacesBySourceID[source.id] {
            workspace = existing
        } else {
            let persisted = persistedWorkspace(for: source.id)
            deletedDevicePaneIDs = persisted.deletedDevicePaneIDs
            workspace = persisted.workspace ?? makePersistedWorkspace(from: source)
            workspacesBySourceID[source.id] = workspace
        }

        synchronizeMetadata(from: source, to: workspace)
        selectedSourceID = source.id
        guard modelContext.saveReporting(
            operation: "Saving Extendo workspace",
            rollbackOnFailure: !deletedDevicePaneIDs.isEmpty,
            performSave: performSave
        ) else { return }
        clearDevicePreferences(for: deletedDevicePaneIDs)
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
        let link = ExtensionWorkspaceLink(sourceWorkspaceID: source.id, workspace: workspace)
        modelContext.insert(workspace)
        modelContext.insert(link)
        onMembershipChange()
        return workspace
    }

    private func persistedWorkspace(
        for sourceWorkspaceID: UUID
    ) -> (workspace: Workspace?, deletedDevicePaneIDs: Set<UUID>) {
        let matchingLinks = links().filter { $0.sourceWorkspaceID == sourceWorkspaceID }
        let retainedLink = matchingLinks.first { $0.workspace != nil }
        var deletedDevicePaneIDs: Set<UUID> = []
        for duplicate in matchingLinks where duplicate !== retainedLink {
            if let workspace = duplicate.workspace {
                deletedDevicePaneIDs.formUnion(prepareForDeletion(workspace))
            }
            modelContext.delete(duplicate)
        }
        if matchingLinks.count > 1 {
            onMembershipChange()
        }
        return (retainedLink?.workspace, deletedDevicePaneIDs)
    }

    private func links() -> [ExtensionWorkspaceLink] {
        (try? modelContext.fetch(FetchDescriptor<ExtensionWorkspaceLink>())) ?? []
    }

    private func deleteOrphanedLinks(excluding validSourceIDs: Set<UUID>) {
        var deletedLink = false
        var deletedDevicePaneIDs: Set<UUID> = []
        for link in links() where !validSourceIDs.contains(link.sourceWorkspaceID) {
            if let workspace = link.workspace {
                deletedDevicePaneIDs.formUnion(prepareForDeletion(workspace))
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
            clearDevicePreferences(for: deletedDevicePaneIDs)
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

    private func prepareForDeletion(_ workspace: Workspace) -> Set<UUID> {
        let devicePaneIDs = Set(workspace.panes.filter { $0.kind == .device }.map(\.id))
        for pane in workspace.panes {
            pane.tearDownRuntimeResources(preservingDevicePreference: true)
        }
        return devicePaneIDs
    }

    private func clearDevicePreferences(for paneIDs: Set<UUID>) {
        for paneID in paneIDs {
            DeviceCaptureRegistry.shared.clearPreference(paneID: paneID)
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

/// A focused companion to Pilot's main workspace window. Selection comes from
/// the canonical `WorkspaceStore`; pane layout and runtime surfaces stay local
/// to Extension and inherit the selected source workspace's root directory.
struct ExtensionWindowView: View {
    @Bindable var store: WorkspaceStore
    @Bindable var controller: ExtensionWorkspaceController
    @Environment(\.openWindow) private var openWindow

    @State private var gitStore = RepositoryStore()
    @State private var tasksStore = GitHubTasksStore()
    @State private var usageStore = UsageStore()
    @State private var isDrawingActive = false
    @AppStorage("extension.inspector.width") private var inspectorWidth = 280.0

    var body: some View {
        let _ = store.changeCount // observe workspace membership changes
        let sourceWorkspace = store.selectedWorkspace
        let source = ExtensionWorkspaceSource(sourceWorkspace)
        let sourceWorkspaceIDs = store.workspaces.map(\.id)
        let syncState = ExtensionWorkspaceSyncState(source: source, sourceWorkspaceIDs: sourceWorkspaceIDs)
        let extensionWorkspace = controller.selectedSourceID == source?.id
            ? controller.selectedWorkspace
            : nil
        let activeInspectorRepoPath = extensionWorkspace?.isInspectorPresented == true
            ? source?.rootPath
            : nil
        let isUsagePresented = extensionWorkspace?.isInspectorPresented == true
            && extensionWorkspace?.inspectorTab == .usage
        let selectedTerminalPane = TerminalToolbarSelection.pane(for: extensionWorkspace?.selectedPane)

        NavigationStack {
            ZStack {
                // Keep every visited companion workspace mounted and toggle
                // visibility, exactly like the main window's workspace stack.
                // The previous single-surface `.id(source?.id)` recreated the
                // whole pane tree on each switch, re-bootstrapping terminals.
                ForEach(controller.mountedWorkspaces, id: \.sourceID) { mounted in
                    let isActive = mounted.workspace.id == extensionWorkspace?.id
                    WorkspaceView(
                        workspace: mounted.workspace,
                        isActive: isActive,
                        projectID: mounted.sourceID,
                        surface: .extension,
                        onPaneDrop: { payload, targetPane in
                            store.movePane(payload, to: mounted.workspace, onto: targetPane)
                        }
                    )
                        .zIndex(isActive ? 1 : 0)
                        .opacity(isActive ? 1 : 0)
                        .allowsHitTesting(isActive)
                        .accessibilityHidden(!isActive)
                        .accessibilityIdentifier("extension.workspace-surface")
                        // Layout-only surface: frame updates must be instant,
                        // never interpolated by an ambient animation.
                        .transaction { $0.animation = nil }
                }

                if extensionWorkspace == nil {
                    if sourceWorkspace != nil {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        ContentUnavailableView(
                            store.workspaces.isEmpty ? "No Workspaces" : "No Workspace Selected",
                            systemImage: "rectangle.on.rectangle.slash",
                            description: Text(
                                store.workspaces.isEmpty
                                    ? "Create a workspace in the main made window."
                                    : "Select a workspace in the main made window."
                            )
                        )
                        .accessibilityIdentifier("extension.empty")
                    }
                }

                if isDrawingActive, extensionWorkspace != nil {
                    InkOverlay(isActive: $isDrawingActive)
                        .id(source?.id)
                        .zIndex(60)
                }
            }
            .navigationTitle(source?.name ?? "")
        }
        .inspector(isPresented: inspectorPresentedBinding(for: extensionWorkspace)) {
            if let workspace = extensionWorkspace {
                InspectorPanelView(
                    gitStore: gitStore,
                    tasksStore: tasksStore,
                    usageStore: usageStore,
                    selectedTab: inspectorTabBinding(for: workspace)
                )
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    let clamped = min(max(Double(width), 220), 600)
                    if abs(clamped - inspectorWidth) > 1 { inspectorWidth = clamped }
                }
                .inspectorColumnWidth(min: 220, ideal: CGFloat(inspectorWidth), max: 600)
            }
        }
        .focusedSceneValue(extensionWorkspace)
        .focusedSceneValue(
            \.pilotCloseTabAction,
            PilotCloseTabAction(
                isEnabled: extensionWorkspace?.selectedPane != nil,
                perform: controller.closeSelectedPane
            )
        )
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let selectedTerminalPane {
                    TerminalFastCommandToolbarField(pane: selectedTerminalPane)
                        .id(selectedTerminalPane.id)
                }
            }
            ToolbarItem(placement: .principal) {
                if let selectedTerminalPane {
                    TerminalFastCommandToolbarActions(pane: selectedTerminalPane)
                        .id(selectedTerminalPane.id)
                }
            }
            ToolbarItemGroup(placement: .secondaryAction) {
                if let pane = extensionWorkspace?.selectedPane {
                    PaneToolbarControls(pane: pane)
                }
            }
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .primaryAction) {
                    WorkspacePaneLauncher(workspace: extensionWorkspace)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.fixed, placement: .primaryAction)
            } else {
                ToolbarItem(placement: .primaryAction) {
                    WorkspacePaneLauncher(workspace: extensionWorkspace)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isDrawingActive.toggle()
                } label: {
                    Label(
                        "Annotate",
                        systemImage: isDrawingActive ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle"
                    )
                }
                .disabled(extensionWorkspace == nil)
                .help("Draw over the active Extendo pane (⇧⌘D)")
                .accessibilityIdentifier("extension.annotate")

                Button {
                    guard let workspace = extensionWorkspace else { return }
                    workspace.setInspectorPresented(!workspace.isInspectorPresented)
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .disabled(extensionWorkspace == nil)
                .help("Show or hide the Extendo Inspector")
                .accessibilityIdentifier("extension.inspector-toggle")
            }
        }
        .background {
            // Pane creation and closing are owned by focused menu commands.
            // Keep only drawing here because its state is local to Extendo.
            ExtensionWindowShortcutMonitor(
                onToggleDrawing: {
                    guard extensionWorkspace != nil else { return }
                    isDrawingActive.toggle()
                }
            )
            .frame(width: 0, height: 0)
        }
        .background(PilotWindowCloseMenuInstaller())
        .frame(minWidth: 560, minHeight: 480)
        .task {
            if let windowID = PilotWindowLaunchPolicy.requiredCompanion(for: PilotWindowID.extendo) {
                openWindow(id: windowID)
            }
        }
        .task(id: syncState) {
            guard !Task.isCancelled else { return }
            controller.update(with: sourceWorkspace, validSourceIDs: Set(sourceWorkspaceIDs))
        }
        .task(id: activeInspectorRepoPath) {
            syncInspectorRepo(activeInspectorRepoPath)
        }
        .task(id: isUsagePresented) {
            if isUsagePresented {
                usageStore.start()
            } else {
                usageStore.stop()
            }
        }
        .onChange(of: source?.id) {
            isDrawingActive = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UsageConsent.changedNotification)) { _ in
            if isUsagePresented { usageStore.reload() }
        }
        .onAppear {
            ExtensionWindowVisibility.shared.isVisible = true
        }
        .onDisappear {
            ExtensionWindowVisibility.shared.isVisible = false
            gitStore.stopWatching()
            tasksStore.load(directory: nil)
            usageStore.stop()
            controller.suspend()
        }
    }

    private func inspectorPresentedBinding(for workspace: Workspace?) -> Binding<Bool> {
        Binding(
            get: {
                guard let workspace,
                      controller.selectedSourceID == store.selectedWorkspaceID,
                      controller.selectedWorkspace === workspace else { return false }
                return workspace.isInspectorPresented
            },
            set: { isPresented in
                guard let workspace,
                      controller.selectedSourceID == store.selectedWorkspaceID,
                      controller.selectedWorkspace === workspace else { return }
                workspace.setInspectorPresented(isPresented)
            }
        )
    }

    private func inspectorTabBinding(for workspace: Workspace) -> Binding<InspectorTab> {
        Binding(
            get: {
                guard controller.selectedSourceID == store.selectedWorkspaceID,
                      controller.selectedWorkspace === workspace else { return .actions }
                return workspace.inspectorTab
            },
            set: { tab in
                guard controller.selectedSourceID == store.selectedWorkspaceID,
                      controller.selectedWorkspace === workspace else { return }
                workspace.setInspectorTab(tab)
            }
        )
    }

    private func syncInspectorRepo(_ repoPath: String?) {
        guard let repoPath else {
            gitStore.stopWatching()
            tasksStore.load(directory: nil)
            return
        }

        gitStore.startWatching(directory: repoPath)
        tasksStore.load(directory: repoPath)
    }

}
