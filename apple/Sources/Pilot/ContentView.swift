import AppKit
import SwiftData
import Observation

struct WorkspaceNumberShortcut: Identifiable, Equatable {
    let number: Int
    let workspaceID: UUID
    var id: UUID { workspaceID }
}

enum WorkspaceNumberShortcuts {
    static func shortcuts(for workspaceIDs: [UUID]) -> [WorkspaceNumberShortcut] {
        Array(workspaceIDs.prefix(9).enumerated()).map { WorkspaceNumberShortcut(number: $0.offset + 1, workspaceID: $0.element) }
    }
}

/// A small value adapter retains the stale-selection guards used by the
/// inspector without coupling the application model to SwiftUI.Binding.
struct CockpitValueBinding<Value> {
    let get: () -> Value
    let set: (Value) -> Void
    var wrappedValue: Value {
        get { get() }
        nonmutating set { set(newValue) }
    }
}

enum ContentView {
    @MainActor
    static func makeInspectorPresentedBinding(for workspace: Workspace?, in store: WorkspaceStore) -> CockpitValueBinding<Bool> {
        let allowsPresentation = store.isWorkspaceDetailVisible
        return CockpitValueBinding(get: {
            guard allowsPresentation, store.isWorkspaceDetailVisible, let workspace,
                  store.selectedWorkspace === workspace else { return false }
            return workspace.isInspectorPresented
        }, set: { isPresented in
            guard allowsPresentation, store.isWorkspaceDetailVisible, let workspace,
                  store.selectedWorkspace === workspace else { return }
            workspace.setInspectorPresented(isPresented)
        })
    }
}

struct CockpitConnectionStatus: Equatable {
    let name: String
    let symbol: String
    let isConnected: Bool
    var detail: String? = nil
}

@MainActor
final class CockpitWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let store: WorkspaceStore
    let extensionController: ExtensionWorkspaceController
    let surface: WorkspacePaneSurface
    let paneCache: CockpitPaneControllerCache
    var onWindowActivate: (() -> Void)?
    var onWindowIDChange: ((CGWindowID?) -> Void)?
    var onSelectionChange: ((Workspace?, Pane?) -> Void)?
    var featureToolbarFactory: ((Pane) -> NSView?)? { didSet { lastToolbarPaneID = nil; refreshToolbar() } }
    var inspectorFactory: ((Workspace) -> NSViewController?)? { didSet { refreshInspector() } }
    var overlayFactory: (() -> NSViewController?)?
    var remoteOverlayController: NSViewController? { didSet { bodyController.setRemoteOverlay(remoteOverlayController) } }
    var statusItems: [CockpitConnectionStatus] = [] { didSet { sidebarContainer.statusBar.statusItems = statusItems } }
    var isPeerRecording = false { didSet { sidebarContainer.statusBar.isRecording = isPeerRecording } }
    private(set) var isDrawingActive = false
    private let paneFactory: (Pane, String?) -> NSViewController
    private let globalFactory: (SidebarSelection) -> NSViewController?
    private let splitController = NSSplitViewController()
    private let bodyController = CockpitWindowBodyController()
    private let inspectorContainer = NSViewController()
    private let sidebarContainer: CockpitSidebarContainer
    private var sidebarItem: NSSplitViewItem?
    private var inspectorItem: NSSplitViewItem!
    private var workspaceController: CockpitWorkspaceViewController?
    private var globalControllers: [SidebarSelection: NSViewController] = [:]
    private var inspectorController: NSViewController?
    private var lastInspectorWorkspaceID: UUID?
    private var lastToolbarPaneID: UUID?
    private var lastToolbarKind: PaneKind?
    private var lastExtensionState: ExtensionWorkspaceSyncState?
    private var observedGeneration = 0
    private var refreshScheduled = false
    private var closeApproved = false
    private var closePending = false
    private var isRefreshing = false
    private var newWorkspaceSheet: NewWorkspaceSheet?
    private var observers: [NSObjectProtocol] = []
    private var notesKeyMonitor: Any?
    private var toolbarFeature: NSToolbarItem?
    private var launcher: WorkspacePaneLauncher?
    private var windowVisible = false

    var selectedWorkspace: Workspace? {
        if surface == .extension { return extensionController.selectedWorkspace }
        return store.isWorkspaceDetailVisible ? store.selectedWorkspace : nil
    }
    var selectedPane: Pane? { selectedWorkspace?.selectedPane }
    var allPaneControllers: [NSViewController] { paneCache.allControllers }

    init(store: WorkspaceStore, extensionController: ExtensionWorkspaceController,
         surface: WorkspacePaneSurface, defaults: UserDefaults = .standard, isLive: Bool = true, paneCache: CockpitPaneControllerCache = .shared,
         paneFactory: @escaping (Pane, String?) -> NSViewController,
         globalFactory: @escaping (SidebarSelection) -> NSViewController?) {
        self.store = store
        self.extensionController = extensionController
        self.surface = surface
        self.paneCache = paneCache
        self.paneFactory = paneFactory
        self.globalFactory = globalFactory
        sidebarContainer = CockpitSidebarContainer(store: store, defaults: defaults, isLive: isLive)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: surface == .main ? 1440 : 1000, height: 920),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        let requestedFrame = window.frame
        window.title = surface == .main ? "Cockpit" : PilotWindowID.extendoTitle
        window.identifier = NSUserInterfaceItemIdentifier(surface == .main ? PilotWindowID.main : PilotWindowID.extendo)
        window.minSize = NSSize(width: surface == .main ? 760 : 560, height: 480)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        splitController.splitView.isVertical = true
        if isLive { splitController.splitView.autosaveName = surface == .main ? "cockpit-main-columns" : "cockpit-extendo-columns" }
        if surface == .main {
            let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarContainer)
            sidebar.minimumThickness = 180
            sidebar.maximumThickness = 420
            sidebar.canCollapse = true
            splitController.addSplitViewItem(sidebar)
            sidebarItem = sidebar
        }
        let content = NSSplitViewItem(viewController: bodyController)
        content.minimumThickness = 260
        splitController.addSplitViewItem(content)
        inspectorContainer.view = NSView()
        inspectorItem = NSSplitViewItem(viewController: inspectorContainer)
        inspectorItem.minimumThickness = 220
        inspectorItem.maximumThickness = 600
        inspectorItem.canCollapse = true
        inspectorItem.isCollapsed = true
        splitController.addSplitViewItem(inspectorItem)
        splitController.view.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
        window.contentViewController = splitController
        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("cockpit.toolbar.\(surface.rawValue)"))
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.setFrame(requestedFrame, display: false)
        let frameName = surface == .main ? PilotWindowID.main : PilotWindowID.extendo
        if let savedFrame = defaults.string(forKey: "NSWindow Frame " + frameName), !savedFrame.isEmpty {
            window.setFrame(from: savedFrame)
        } else if isLive {
            if !window.setFrameUsingName(frameName) { window.center() }
        } else { window.center() }
        if isLive { window.setFrameAutosaveName(frameName) }
        sidebarContainer.sidebar.onSelect = { [weak self] in self?.select($0) }
        sidebarContainer.sidebar.onNewWorkspace = { [weak self] in self?.presentNewWorkspace(groupID: $0) }
        sidebarContainer.sidebar.onDeleteWorkspace = { [weak self] in self?.deleteWorkspace($0) }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .cockpitUIZoomDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })

    }
    required init?(coder: NSCoder) { nil }
    isolated deinit {
        for token in observers { NotificationCenter.default.removeObserver(token) }
        if let notesKeyMonitor { NSEvent.removeMonitor(notesKeyMonitor) }
        workspaceController?.deactivate()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        windowVisible = true
        closeApproved = false
        if surface == .extension { ExtensionWindowVisibility.shared.isVisible = true }
        refresh()
        observe()
        installNotesKeyMonitor()
        sidebarContainer.sidebar.startMonitoring()
        sidebarContainer.statusBar.start()
        window?.makeKeyAndOrderFront(sender)
        onWindowIDChange?(window.map { CGWindowID($0.windowNumber) })
    }

    func windowDidBecomeKey(_ notification: Notification) { onWindowActivate?(); refresh() }
    func windowDidChangeOcclusionState(_ notification: Notification) { refresh() }
    func windowDidResize(_ notification: Notification) { bodyController.view.needsLayout = true }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeApproved { return true }
        guard !closePending else { return false }
        closePending = true
        let workspaces = surface == .main ? store.workspaces : extensionController.mountedWorkspaces.map(\.workspace)
        let ids = Set(workspaces.flatMap { $0.panes.map(\.id) })
        paneCache.prepareToClose(ids: ids) { [weak self] allowed in
            guard let self else { return }
            self.closePending = false
            if allowed { self.closeApproved = true; DispatchQueue.main.async { sender.performClose(nil) } }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        windowVisible = false
        observedGeneration += 1
        workspaceController?.deactivate()
        for controller in globalControllers.values { (controller as? CockpitPanePresenting)?.updatePresentation(isActive: false, isSelected: false) }
        (inspectorController as? InspectorViewController)?.setPresentationActive(false)
        sidebarContainer.sidebar.stopMonitoring()
        sidebarContainer.statusBar.stop()
        if let notesKeyMonitor { NSEvent.removeMonitor(notesKeyMonitor); self.notesKeyMonitor = nil }
        if surface == .extension { ExtensionWindowVisibility.shared.isVisible = false }
        onWindowIDChange?(nil)
    }

    func select(_ selection: SidebarSelection) {
        switch selection {
        case .notes: store.enterNotesMode()
        case .remoteDesktop: store.enterRemoteDesktopMode()
        case .docker: store.enterDockerMode()
        case .agenticUse: store.enterAgenticUseMode()
        case .runners: store.enterRunnersMode()
        case .workspace(let id): store.selectWorkspace(id)
        }
        refresh()
        observe()
        focusSelectedPane()
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let sources = store.workspaces
        let sync = ExtensionWorkspaceSyncState(source: ExtensionWorkspaceSource(store.selectedWorkspace), sourceWorkspaceIDs: sources.map(\.id))
        if lastExtensionState != sync {
            lastExtensionState = sync
            extensionController.update(with: store.selectedWorkspace, validSourceIDs: Set(sources.map(\.id)))
        }
        // A removed pane can remain a detached SwiftData object. Membership,
        // rather than a fetch of every Pane record, defines session ownership.
        let liveWorkspaces = sources + extensionController.mountedWorkspaces.map(\.workspace)
        paneCache.retainOnly(Set(liveWorkspaces.flatMap { $0.panes.map(\.id) }))
        let active = windowVisible && window?.occlusionState.contains(.visible) == true
        if let workspace = selectedWorkspace {
            if workspaceController?.workspace !== workspace {
                workspaceController?.deactivate()
                workspaceController = CockpitWorkspaceViewController(workspace: workspace,
                    projectID: surface == .extension ? (store.selectedWorkspaceID ?? workspace.id) : workspace.id,
                    surface: surface, cache: paneCache, factory: paneFactory,
                    onDrop: { [weak self, weak workspace] payload, target in
                        guard let self, let workspace else { return false }
                        return self.store.movePane(payload, to: workspace, onto: target)
                    })
                workspaceController?.onSelectionChange = { [weak self] in self?.scheduleRefresh() }
                workspaceController?.onClosePane = { [weak self] pane in self?.closePane(pane) }
                setDrawingActive(false)
            }
            for controller in globalControllers.values { (controller as? CockpitPanePresenting)?.updatePresentation(isActive: false, isSelected: false) }
            if let workspaceController {
                bodyController.setContent(workspaceController)
                workspaceController.refresh(isActive: active)
            }
            window?.title = surface == .main ? workspace.name + " — Cockpit" : workspace.name + " — Extendo"
        } else {
            workspaceController?.deactivate()
            workspaceController = nil
            setDrawingActive(false)
            if surface == .main, let mode = selectedGlobalMode {
                let controller = globalControllers[mode] ?? globalFactory(mode)
                if let controller {
                    globalControllers[mode] = controller
                    for (key, value) in globalControllers { (value as? CockpitPanePresenting)?.updatePresentation(isActive: active && key == mode, isSelected: key == mode) }
                    bodyController.setContent(controller)
                }
            } else {
                let empty = NSViewController()
                let heading = shellLabel(store.workspaces.isEmpty ? "No Workspaces" : "No Workspace Selected")
                heading.font = CockpitTypography.font(size: 20, weight: .semibold)
                var controls: [NSView] = [heading, shellLabel("Select a workspace in the sidebar.", secondary: true)]
                if store.workspaces.isEmpty { controls.append(ShellActionButton("New Workspace…") { [weak self] in self?.presentNewWorkspace() }) }
                for target in PinnedQuickJumpTarget.targets(in: store.workspaces) {
                    controls.append(ShellActionButton(target.name + "  ⌘\(target.shortcutNumber)") { [weak self] in self?.select(.workspace(target.id)) })
                }
                let stack = shellStack(controls, spacing: 12)
                stack.alignment = .centerX
                empty.view = NSView()
                empty.view.addSubview(stack)
                stack.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: empty.view.centerXAnchor), stack.centerYAnchor.constraint(equalTo: empty.view.centerYAnchor)])
                bodyController.setContent(empty)
            }
            window?.title = surface == .main ? "Cockpit" : PilotWindowID.extendoTitle
        }
        sidebarContainer.sidebar.refresh()
        refreshInspector()
        refreshToolbar()
        onSelectionChange?(selectedWorkspace, selectedPane)
    }

    private var selectedGlobalMode: SidebarSelection? {
        if store.isNotesMode { return .notes }
        if store.isRemoteDesktopMode { return .remoteDesktop }
        if store.isDockerMode { return .docker }
        if store.isAgenticUseMode { return .agenticUse }
        if store.isRunnersMode { return .runners }
        return nil
    }

    private func observe() {
        guard windowVisible else { return }
        observedGeneration += 1
        let generation = observedGeneration
        withObservationTracking {
            _ = store.changeCount; _ = store.selectedWorkspaceID
            _ = store.isNotesMode; _ = store.isRemoteDesktopMode; _ = store.isDockerMode; _ = store.isAgenticUseMode; _ = store.isRunnersMode
            _ = extensionController.selectedSourceID
            _ = CockpitUIZoomController.shared.factor
            for workspace in store.workspaces + extensionController.mountedWorkspaces.map(\.workspace) {
                _ = workspace.name; _ = workspace.effectiveRootPath; _ = workspace.selectedPaneID
                _ = workspace.isInspectorPresented; _ = workspace.inspectorTab; _ = workspace.axis
                for pane in workspace.panes { _ = pane.id; _ = pane.isCollapsed; _ = pane.sizeFraction; _ = pane.sortOrder; _ = pane.displayTitle }
            }
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observedGeneration == generation else { return }
                self.scheduleRefresh()
            }
        }
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
            self.observe()
        }
    }

    /// Makes a rejected close actionable even when that editor was cached in
    /// a different workspace or its window had previously been closed.
    @discardableResult
    func revealPane(withID id: UUID) -> Bool {
        let sources: [(UUID, Workspace)] = surface == .main
            ? store.workspaces.map { ($0.id, $0) }
            : extensionController.mountedWorkspaces.map { ($0.sourceID, $0.workspace) }
        guard let (sourceID, workspace) = sources.first(where: { $0.1.panes.contains(where: { $0.id == id }) }),
              let pane = workspace.panes.first(where: { $0.id == id }) else { return false }
        store.selectWorkspace(sourceID)
        if pane.isCollapsed { workspace.expandPane(pane) }
        workspace.selectedPaneID = id
        showWindow(nil)
        refresh()
        focusSelectedPane()
        return true
    }

    func paneController(for pane: Pane) -> NSViewController {
        paneCache.controller(for: pane, rootPath: pane.workspace?.effectiveRootPath, factory: paneFactory)
    }

    var canCloseSelectedPane: Bool {
        if surface == .main, store.isNotesMode { return store.selectedNote != nil }
        if surface == .main, store.isRemoteDesktopMode { return store.selectedRemoteConnection != nil }
        return selectedPane != nil && ((selectedWorkspace?.panes.count ?? 0) > 1 || surface == .extension)
    }

    func closeSelectedPane() {
        if surface == .main, store.isNotesMode {
            if let notes = globalControllers[.notes] as? NotesViewController {
                notes.closeSelectedNote()
            } else if let note = store.selectedNote {
                store.requestCloseNote(note)
            }
            return
        }
        if surface == .main, store.isRemoteDesktopMode {
            if let connection = store.selectedRemoteConnection { store.requestCloseRemoteConnection(connection) }
            return
        }
        if let pane = selectedPane { closePane(pane) }
    }

    func closePane(_ pane: Pane) {
        guard let workspace = pane.workspace,
              workspace.panes.count > 1 || surface == .extension else { return }
        paneCache.prepareToClose(ids: [pane.id]) { [weak self, weak pane, weak workspace] allowed in
            guard allowed, let self, let pane, let workspace, workspace.panes.contains(where: { $0 === pane }) else { return }
            workspace.requestRemovePane(pane, allowEmpty: self.surface == .extension) { [weak self] in
                self?.paneCache.validateCloseReadiness(ids: [pane.id]) ?? false
            }
            self.scheduleRefresh()
        }
    }

    func deleteWorkspace(_ workspace: Workspace) {
        let linked = extensionController.workspace(forSourceID: workspace.id)?.panes ?? []
        let ids = Set((workspace.panes + linked).map(\.id))
        paneCache.prepareToClose(ids: ids) { [weak self, weak workspace] allowed in
            guard allowed, let self, let workspace, self.store.workspaces.contains(where: { $0 === workspace }) else { return }
            self.store.requestDeleteWorkspace(workspace) { [weak self] in
                self?.paneCache.validateCloseReadiness(ids: ids) ?? false
            }
        }
    }

    func prepareForTermination(completion: @escaping @MainActor (Bool) -> Void) { paneCache.prepareToClose(completion: completion) }

    func presentNewWorkspace(groupID: UUID? = nil) {
        guard newWorkspaceSheet == nil, let window, window.attachedSheet == nil else { return }
        let sheet = NewWorkspaceSheet { [weak self] directory in
            guard let self else { return }
            self.store.addWorkspace(directory: directory)
            if let groupID, let workspace = self.store.selectedWorkspace { self.store.moveWorkspace(workspace, toGroup: groupID) }
            self.refresh()
        }
        sheet.onDismiss = { [weak self] in self?.newWorkspaceSheet = nil }
        newWorkspaceSheet = sheet
        sheet.present(on: window)
    }

    func presentNewGroup() {
        TextPromptSheet.present(on: window, title: "New Workspace Group", label: "Group name", value: "", confirmTitle: "Create") { [weak self] name in
            guard let self else { return }
            self.store.workspaceGroups.add(name: name, workspaceIDs: self.store.unpinnedWorkspaceIDs)
            self.refresh()
        }
    }

    func toggleInspector() {
        guard let workspace = selectedWorkspace else { return }
        workspace.setInspectorPresented(!workspace.isInspectorPresented)
        refreshInspector()
    }
    func toggleSidebar() { if let sidebarItem { sidebarItem.animator().isCollapsed.toggle() } }
    func toggleDrawing() { setDrawingActive(!isDrawingActive) }
    func setDrawingActive(_ enabled: Bool) {
        let enabled = enabled && selectedWorkspace != nil
        guard enabled != isDrawingActive else { return }
        isDrawingActive = enabled
        bodyController.setDrawingOverlay(enabled ? overlayFactory?() : nil)
        if !enabled { focusSelectedPane() }
    }
    func focusSelectedPane() { workspaceController?.focusSelectedPane() }
    func cyclePane(by delta: Int) {
        guard let workspace = selectedWorkspace else { return }
        if delta > 0 { workspace.selectNextPane() } else { workspace.selectPreviousPane() }
        refresh(); focusSelectedPane()
    }

    private func refreshInspector() {
        guard isWindowLoaded else { return }
        let workspace = selectedWorkspace
        let presented = workspace?.isInspectorPresented == true
        if let workspace, presented {
            if lastInspectorWorkspaceID != workspace.id || inspectorController == nil {
                (inspectorController as? InspectorViewController)?.setPresentationActive(false)
                inspectorController?.view.removeFromSuperview(); inspectorController?.removeFromParent()
                inspectorController = inspectorFactory?(workspace)
                lastInspectorWorkspaceID = workspace.id
                if let controller = inspectorController {
                    controller.view.removeFromSuperview(); controller.removeFromParent()
                    inspectorContainer.addChild(controller)
                    shellPin(controller.view, to: inspectorContainer.view)
                }
            }
            (inspectorController as? InspectorViewController)?.update(workspace: workspace)
        }
        inspectorItem.isCollapsed = !presented || inspectorController == nil
        (inspectorController as? InspectorViewController)?.setPresentationActive(presented && windowVisible && window?.occlusionState.contains(.visible) == true)
    }

    private enum ToolbarID {
        static let sidebar = NSToolbarItem.Identifier("cockpit.sidebar")
        static let newWorkspace = NSToolbarItem.Identifier("cockpit.new-workspace")
        static let feature = NSToolbarItem.Identifier("cockpit.feature")
        static let launcher = NSToolbarItem.Identifier("cockpit.launcher")
        static let draw = NSToolbarItem.Identifier("cockpit.draw")
        static let inspector = NSToolbarItem.Identifier("cockpit.inspector")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        let leading: [NSToolbarItem.Identifier] = surface == .main ? [ToolbarID.sidebar, ToolbarID.newWorkspace] : []
        return leading + [.flexibleSpace, ToolbarID.feature, .flexibleSpace, ToolbarID.launcher, ToolbarID.draw, ToolbarID.inspector]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
        case ToolbarID.feature:
            toolbarFeature = item
            item.label = "Pane Controls"
            item.view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 28))
        case ToolbarID.launcher:
            let launcher = WorkspacePaneLauncher(workspace: selectedWorkspace)
            launcher.onCreate = { [weak self] in self?.scheduleRefresh() }
            self.launcher = launcher
            item.view = launcher; item.label = "New Pane"
        case ToolbarID.sidebar: item.view = ShellActionButton("Sidebar", symbol: "sidebar.left") { [weak self] in self?.toggleSidebar() }; item.label = "Sidebar"
        case ToolbarID.newWorkspace: item.view = ShellActionButton("Workspace", symbol: "plus") { [weak self] in self?.presentNewWorkspace() }; item.label = "New Workspace"
        case ToolbarID.draw: item.view = ShellActionButton("Annotate", symbol: "pencil.tip.crop.circle") { [weak self] in self?.toggleDrawing() }; item.label = "Annotate"
        case ToolbarID.inspector: item.view = ShellActionButton("Inspector", symbol: "sidebar.trailing") { [weak self] in self?.toggleInspector() }; item.label = "Inspector"
        default: return nil
        }
        return item
    }

    private func refreshToolbar() {
        guard isWindowLoaded else { return }
        launcher?.workspace = selectedWorkspace
        let pane = selectedPane.flatMap { $0.isCollapsed ? nil : $0 }
        if pane?.id != lastToolbarPaneID || pane?.kind != lastToolbarKind {
            lastToolbarPaneID = pane?.id; lastToolbarKind = pane?.kind
            let feature = pane.flatMap { featureToolbarFactory?($0) }
            toolbarFeature?.view = feature ?? NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 28))
            toolbarFeature?.isEnabled = feature != nil
        }
        for item in window?.toolbar?.items ?? [] where item.itemIdentifier == ToolbarID.draw || item.itemIdentifier == ToolbarID.inspector {
            (item.view as? NSControl)?.isEnabled = selectedWorkspace != nil
        }
    }

    private func installNotesKeyMonitor() {
        guard surface == .main, notesKeyMonitor == nil else { return }
        notesKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
                  event.charactersIgnoringModifiers == "0" else { return event }
            self.store.toggleNotesMode(); self.refresh(); return nil
        }
    }

}

@MainActor
private final class CockpitWindowBodyController: NSViewController {
    private weak var content: NSViewController?
    private var drawing: NSViewController?
    private var remote: NSViewController?
    override func loadView() { view = NSView() }
    func setContent(_ controller: NSViewController) {
        loadViewIfNeeded()
        guard content !== controller else { return }
        content?.view.removeFromSuperview(); content?.removeFromParent()
        controller.view.removeFromSuperview(); controller.removeFromParent()
        addChild(controller)
        view.addSubview(controller.view, positioned: .below, relativeTo: nil)
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.width, .height]
        content = controller
    }
    func setDrawingOverlay(_ controller: NSViewController?) { replaceOverlay(drawing, with: controller); drawing = controller }
    func setRemoteOverlay(_ controller: NSViewController?) { replaceOverlay(remote, with: controller); remote = controller }
    private func replaceOverlay(_ old: NSViewController?, with next: NSViewController?) {
        loadViewIfNeeded()
        old?.view.removeFromSuperview(); old?.removeFromParent()
        if let next {
            next.view.removeFromSuperview(); next.removeFromParent(); addChild(next)
            view.addSubview(next.view)
            next.view.frame = view.bounds; next.view.autoresizingMask = [.width, .height]
        }
    }
}

@MainActor
private final class CockpitSidebarContainer: NSViewController {
    let sidebar: WorkspaceSidebarViewController
    let statusBar: CockpitStatusBar
    init(store: WorkspaceStore, defaults: UserDefaults, isLive: Bool) {
        sidebar = WorkspaceSidebarViewController(store: store, defaults: defaults, isLive: isLive)
        statusBar = CockpitStatusBar(isLive: isLive)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        view = NSView()
        addChild(sidebar)
        let stack = shellStack([sidebar.view, statusBar], spacing: 0)
        stack.alignment = .leading
        shellPin(stack, to: view)
        sidebar.view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        statusBar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        statusBar.heightAnchor.constraint(equalToConstant: 42).isActive = true
    }
}

@MainActor
private final class CockpitStatusBar: NSView {
    var statusItems: [CockpitConnectionStatus] = [] { didSet { if oldValue != statusItems { rebuild() } } }
    var isRecording = false { didSet { if oldValue != isRecording { rebuild() } } }
    private var stack: NSStackView?
    private var popover: NSPopover?
    private var awakeObservation: CockpitObservation?
    private let isLive: Bool
    private var awakeController: AwakeSessionController? { isLive ? .shared : nil }

    init(isLive: Bool) { self.isLive = isLive; super.init(frame: .zero); rebuild() }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            if awakeObservation == nil { awakeObservation = CockpitObservation(owner: self) { owner in _ = owner.awakeController?.isEnabled; owner.rebuild() } }
            awakeObservation?.start()
        } else { stop() }
    }
    func start() { awakeObservation?.start() }
    func stop() { awakeObservation?.stop(); popover?.close() }
    private func rebuild() {
        stack?.removeFromSuperview()
        let microphoneLabel = isRecording ? "Microphone recording" : "Microphone idle"
        let mic = ShellActionButton("", symbol: isRecording ? "waveform.circle.fill" : "waveform", perform: {})
        mic.perform = { [weak self, weak mic] in
            guard let self, let mic else { return }
            let controller = NSViewController()
            let content = shellStack([shellLabel("Microphone"), shellLabel(self.isRecording ? "Recording" : "Idle", secondary: true)])
            content.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
            content.setAccessibilityIdentifier("sidebar.microphone-popover")
            controller.view = content
            controller.preferredContentSize = NSSize(width: 220, height: 90)
            self.showPopover(from: mic, controller: controller)
        }
        mic.isBordered = false
        mic.contentTintColor = isRecording ? .systemRed : .secondaryLabelColor
        mic.toolTip = microphoneLabel
        mic.setAccessibilityLabel(microphoneLabel)
        mic.setAccessibilityIdentifier("sidebar.microphone-status")
        let awake = ShellActionButton("", symbol: "cup.and.heat.waves") { [weak self] in self?.showAwake() }
        awake.isEnabled = isLive
        awake.contentTintColor = awakeController?.isEnabled == true ? .systemGreen : .secondaryLabelColor
        awake.toolTip = "Keep Awake"
        awake.setAccessibilityLabel("Keep Awake")
        awake.setAccessibilityIdentifier("sidebar.keep-awake-status")
        var controls: [NSView] = [mic, awake]
        for item in statusItems {
            let button = ShellActionButton("", symbol: item.symbol, perform: {})
            button.perform = { [weak self, weak button] in
                guard let self, let button else { return }
                self.showPopover(from: button, controller: self.statusController(item))
            }
            button.contentTintColor = item.isConnected ? .systemGreen : .secondaryLabelColor
            button.isBordered = false
            button.toolTip = item.name
            button.setAccessibilityLabel(item.name + ", " + (item.isConnected ? "connected" : "not connected"))
            controls.append(button)
        }
        for control in controls { control.widthAnchor.constraint(equalToConstant: 22).isActive = true }
        let stack = shellStack(controls, orientation: .horizontal, spacing: 3)
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        self.stack = stack
        shellPin(stack, to: self)
    }
    private func statusController(_ item: CockpitConnectionStatus) -> NSViewController {
        let controller = NSViewController()
        let stack = shellStack([shellLabel(item.name), shellLabel(item.isConnected ? "Connected" : "Not connected", secondary: true), shellLabel(item.detail ?? "", secondary: true)])
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        controller.view = stack
        controller.preferredContentSize = NSSize(width: 280, height: 100)
        return controller
    }
    private func showAwake() {
        guard isLive, let button = stack?.arrangedSubviews.dropFirst().first else { return }
        showPopover(from: button, controller: AwakeSessionDetailsViewController())
    }
    private func showPopover(from view: NSView, controller: NSViewController) {
        popover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        self.popover = popover
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }
}

@MainActor
private final class AwakeSessionDetailsViewController: NSViewController {
    private let controller = AwakeSessionController.shared
    private var observation: CockpitObservation?
    private let status = shellLabel("", secondary: true)
    private let error = shellLabel("", secondary: true)
    private var checks: [NSButton] = []
    override func loadView() {
        let titles = ["Keep Awake", "Allow display sleep", "Allow system sleep when display is closed", "Allow screen saver after 45m of inactivity"]
        checks = titles.enumerated().map { index, title in
            let checkbox = NSButton(checkboxWithTitle: title, target: self, action: #selector(change(_:)))
            checkbox.tag = index
            return checkbox
        }
        let stack = shellStack([checks[0], status] + Array(checks.dropFirst()) + [error], spacing: 12)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        view = stack
        preferredContentSize = NSSize(width: 370, height: 220)
        observation = CockpitObservation(owner: self) { owner in owner.refresh() }
    }
    override func viewDidAppear() { super.viewDidAppear(); observation?.start() }
    override func viewDidDisappear() { super.viewDidDisappear(); observation?.stop() }
    private func refresh() {
        let values = [controller.isEnabled, controller.allowDisplaySleep, controller.allowSystemSleepWhenDisplayClosed, controller.allowScreenSaverAfter45Minutes]
        for (index, value) in values.enumerated() { checks[index].state = value ? .on : .off }
        status.stringValue = controller.sessionStatus
        error.stringValue = controller.assertionError ?? ""
        error.isHidden = controller.assertionError == nil
    }
    @objc private func change(_ sender: NSButton) {
        let value = sender.state == .on
        switch sender.tag {
        case 0: controller.isEnabled = value
        case 1: controller.allowDisplaySleep = value
        case 2: controller.allowSystemSleepWhenDisplayClosed = value
        default: controller.allowScreenSaverAfter45Minutes = value
        }
    }
}
