import AppKit
import SwiftData
import SwiftUI

/// Shared ⌘1…⌘9 workspace-number mapping plus Main-window key
/// equivalents. Extension uses the same visible ordering from a scene menu so
/// focused AppKit panes cannot swallow its shortcuts.
struct WorkspaceNumberShortcut: Identifiable, Equatable {
    let number: Int
    let workspaceID: UUID

    var id: UUID { workspaceID }
}

struct WorkspaceNumberShortcuts: View {
    let workspaceIDs: [UUID]
    let onSelect: (UUID) -> Void

    var body: some View {
        Group {
            ForEach(Self.shortcuts(for: workspaceIDs)) { shortcut in
                Button("") {
                    onSelect(shortcut.workspaceID)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(shortcut.number)")), modifiers: .command)
                .hidden()
            }
        }
        .id(workspaceIDs)
    }

    static func shortcuts(for workspaceIDs: [UUID]) -> [WorkspaceNumberShortcut] {
        Array(workspaceIDs.prefix(9).enumerated()).map { index, workspaceID in
            WorkspaceNumberShortcut(number: index + 1, workspaceID: workspaceID)
        }
    }
}

/// Resolves the browser toolbar from the pane that owns it. Main and Extension
/// both use this gate so a collapsed/non-browser pane cannot leave stale
/// controls behind, and Extension always binds to its own persisted
/// `BrowserState` rather than the similarly selected pane in Main.
enum BrowserToolbarSelection {
    static func state(for pane: Pane?) -> BrowserState? {
        guard let pane,
              !pane.isCollapsed,
              pane.kind == .browser else { return nil }
        return pane.browserState
    }
}

struct BrowserBackForwardToolbarControls: View {
    let state: BrowserState

    var body: some View {
        ControlGroup {
            Button { state.perform(.back) } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .disabled(!state.supports(.navigation) || !state.canGoBack)
            .accessibilityIdentifier("browser.back")

            Button { state.perform(.forward) } label: {
                Label("Forward", systemImage: "chevron.right")
            }
            .disabled(!state.supports(.navigation) || !state.canGoForward)
            .accessibilityIdentifier("browser.forward")
        }
        .controlGroupStyle(.navigation)
    }
}

/// The principal browser location field. A state-backed focus request lets ⌘L
/// reveal a collapsed browser first and focus this field when it actually
/// appears, instead of racing SwiftUI's toolbar installation.
struct BrowserAddressToolbarControl: View {
    let state: BrowserState
    let addressMinWidth: CGFloat
    let addressIdealWidth: CGFloat
    let addressMaxWidth: CGFloat

    @FocusState private var isAddressFocused: Bool

    init(
        state: BrowserState,
        addressMinWidth: CGFloat = 240,
        addressIdealWidth: CGFloat = 420,
        addressMaxWidth: CGFloat = 560
    ) {
        self.state = state
        self.addressMinWidth = addressMinWidth
        self.addressIdealWidth = addressIdealWidth
        self.addressMaxWidth = addressMaxWidth
    }

    var body: some View {

        TextField("URL", text: Bindable(state).urlText)
            .textFieldStyle(.plain)
            .scaledFont(size: 13, weight: .medium)
            .focused($isAddressFocused)
            .onSubmit { state.navigate() }
            .onChange(of: isAddressFocused) { _, isFocused in
                state.isAddressEditing = isFocused
            }
            .padding(.leading, 12)
            .padding(.trailing, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) {
                browserReloadButton
                    .padding(.trailing, 10)
            }
            .frame(
                minWidth: addressMinWidth,
                idealWidth: addressIdealWidth,
                maxWidth: addressMaxWidth
            )
            .layoutPriority(1)
            .accessibilityIdentifier("browser.address")
            .onAppear(perform: fulfillFocusRequestIfNeeded)
            .onChange(of: state.needsAddressFocus) {
                fulfillFocusRequestIfNeeded()
            }
    }

    private func fulfillFocusRequestIfNeeded() {
        guard state.needsAddressFocus else { return }
        state.needsAddressFocus = false
        isAddressFocused = true
        BrowserAddressFocus.selectAddressFieldInKeyWindow()
    }

    private var browserReloadButton: some View {
        Button {
            if state.isLoading {
                state.perform(.stop)
            } else {
                state.perform(.reload)
            }
        } label: {
            ZStack {
                Image(systemName: "arrow.clockwise")
                    .scaledFont(size: 12, weight: .medium)
                    .opacity(state.isLoading ? 0 : 1)

                if state.isLoading {
                    if state.engine == .chromium,
                       state.estimatedProgress > 0 {
                        ProgressView(value: state.estimatedProgress)
                            .controlSize(.small)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
        .disabled(!state.supports(.navigation))
        .help(state.isLoading ? "Stop" : "Reload")
        .accessibilityIdentifier("browser.reload")
    }
}

/// Complete navigation/location composition used by Main. Extension installs
/// these as separate navigation and principal toolbar items.
struct BrowserNavigationToolbarControls: View {
    let state: BrowserState

    var body: some View {
        // Wallets lead, separated from the navigation ControlGroup so they read
        // as their own affordance rather than a third arrow.
        BrowserWalletToolbarControls(state: state)
        BrowserBackForwardToolbarControls(state: state)
        BrowserAddressToolbarControl(state: state)
    }
}

/// Lower-priority browser actions are split from navigation so AppKit can move
/// them into toolbar overflow without also removing the address field.
struct BrowserToolsToolbarControls: View {
    let state: BrowserState

    @State private var isConfirmingWebsiteDataReset = false
    @State private var isClearingWebsiteData = false
    @State private var isShowingFind = false
    @State private var findText = ""

    var body: some View {

        Menu {
            Button("Default Profile") {}
            Divider()
            Button("Manage Profiles...") {}
            Divider()
            Button("Clear All Browser Data…", role: .destructive) {
                isConfirmingWebsiteDataReset = true
            }
            .disabled(isClearingWebsiteData)
            .accessibilityIdentifier("browser.clear-data")
        } label: {
            Label("Profile", systemImage: "person.circle")
        }
        .disabled(!state.supports(.websiteDataReset))
        .accessibilityIdentifier("browser.profile")
        .alert("Clear All Browser Data?", isPresented: $isConfirmingWebsiteDataReset) {
            Button("Cancel", role: .cancel) {}
            Button("Clear and Reload", role: .destructive) {
                clearWebsiteData()
            }
        } message: {
            Text(
                "This clears caches, cookies, local and session storage, IndexedDB, "
                    + "service workers, and other website data for every browser pane. "
                    + "The current page will reload in a clean browser."
            )
        }

        if state.engine == .chromium {
            ControlGroup {
                Button {
                    findText = state.findQuery
                    isShowingFind = true
                } label: {
                    Label("Find in Page", systemImage: "magnifyingglass")
                }
                .disabled(!hasLoadedPage)
                .help("Find in Page")
                .accessibilityIdentifier("browser.find")
                .popover(isPresented: $isShowingFind, arrowEdge: .bottom) {
                    chromiumFindPopover
                }

                Button {
                    state.requestPrint()
                } label: {
                    Label("Print", systemImage: "printer")
                }
                .disabled(!hasLoadedPage)
                .help("Print Page")
                .accessibilityIdentifier("browser.print")

                Button {
                    state.requestSavePage()
                } label: {
                    Label("Save Page", systemImage: "square.and.arrow.down")
                }
                .disabled(!hasLoadedPage)
                .help("Save Page")
                .accessibilityIdentifier("browser.save-page")
            }
            .controlGroupStyle(.navigation)

            if let progress = state.downloadProgress {
                ProgressView(value: progress)
                    .frame(width: 44)
                    .help(state.downloadStatusText)
                    .accessibilityIdentifier("browser.download-progress")
            }
        }

        ControlGroup {
            Menu {
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    Button {
                        state.appearanceMode = mode
                    } label: {
                        HStack {
                            Text(mode.rawValue)
                            if state.appearanceMode == mode {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label("Appearance", systemImage: appearanceIcon)
            }
            .disabled(!state.supports(.appearanceOverride))
            .help("Browser appearance: System, Light, or Dark")
            .accessibilityIdentifier("browser.appearance")

            // A plain Button, not a Toggle: toggles inside a `.navigation`
            // ControlGroup vanish from the toolbar while in the on state.
            Button {
                state.perform(.toggleAnnotation)
            } label: {
                Label("Lasso", systemImage: "lasso")
            }
            .disabled(!state.supports(.annotation))
            .foregroundStyle(state.annotateMode ? Color.accentColor : Color.primary)
            .help(state.annotateMode
                  ? "Turn off Lasso (⇧⌘A)"
                  : "Select a web element and tell an agent what to fix (⇧⌘A)")
            .accessibilityIdentifier("browser.lasso")

            Button {
                state.perform(.toggleDeveloperTools)
            } label: {
                Label("Developer Tools", systemImage: "hammer")
            }
            .disabled(!state.supports(.developerTools))
            .help(state.showDevTools ? "Close Developer Tools" : "Open Developer Tools")
            .accessibilityIdentifier("browser.developer-tools")
        }
        .controlGroupStyle(.navigation)
        .accessibilityIdentifier("browser.tools")
    }

    private var chromiumFindPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Find", text: $findText)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    state.requestFind(findText)
                }
                .accessibilityIdentifier("browser.find-field")

            HStack {
                Text(findResultSummary)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    state.requestFind(findText, forward: false, findNext: true)
                } label: {
                    Label("Previous Match", systemImage: "chevron.up")
                }
                .labelStyle(.iconOnly)
                .disabled(findText.isEmpty)
                .accessibilityIdentifier("browser.find-previous")

                Button {
                    state.requestFind(findText, forward: true, findNext: true)
                } label: {
                    Label("Next Match", systemImage: "chevron.down")
                }
                .labelStyle(.iconOnly)
                .disabled(findText.isEmpty)
                .accessibilityIdentifier("browser.find-next")

                Button("Done") {
                    isShowingFind = false
                }
            }
        }
        .padding(12)
        .frame(width: 320)
        .onDisappear {
            state.stopFinding()
        }
    }

    private var findResultSummary: String {
        guard state.findMatchCount > 0 else { return "No matches" }
        return "\(state.activeFindMatchOrdinal) of \(state.findMatchCount)"
    }

    private var hasLoadedPage: Bool {
        !state.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var appearanceIcon: String {
        switch state.appearanceMode {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    private func clearWebsiteData() {
        guard state.supports(.websiteDataReset) else { return }
        isClearingWebsiteData = true
        Task { @MainActor in
            await BrowserWebsiteData.clearAll()
            state.requestWebsiteDataReset()
            isClearingWebsiteData = false
        }
    }
}

/// Complete browser toolbar shared by Main and Extendo.
struct BrowserToolbarControls: View {
    let state: BrowserState

    var body: some View {
        BrowserNavigationToolbarControls(state: state)
        BrowserToolsToolbarControls(state: state)
    }
}

/// Keeps every pane-specific toolbar identical between Main and Extendo.
/// Both windows install this view in the same toolbar placement, so control
/// order, overflow behavior, and future additions stay synchronized.
struct PaneToolbarControls: View {
    let pane: Pane

    @ViewBuilder
    var body: some View {
        if !pane.isCollapsed {
            switch pane.kind {
            case .browser:
                if let state = BrowserToolbarSelection.state(for: pane) {
                    BrowserToolbarControls(state: state)
                }
            case .device:
                DeviceToolbarControls(paneID: pane.id)
            case .simulator:
                SimulatorToolbarControls(paneID: pane.id)
            case .android:
                AndroidToolbarControls(paneID: pane.id)
            case .terminal, .editor:
                EmptyView()
            }
        }
    }
}

struct SimulatorToolbarControls: View {
    let paneID: UUID

    var body: some View {
        let session = SimulatorRegistry.shared.session(for: paneID)
        let isStreaming = session.status == .streaming

        Button {
            session.toggleRecording()
        } label: {
            Label(
                session.isRecording ? "Stop Recording" : "Record Screen",
                systemImage: session.isRecording ? "stop.circle.fill" : "record.circle"
            )
            .foregroundStyle(session.isRecording ? .red : .primary)
        }
        .disabled(!isStreaming)
        .help(session.isRecording ? "Stop recording" : "Record the simulator screen")

        Button {
            session.goHome()
        } label: {
            Label("Home", systemImage: "square.grid.3x3.fill")
        }
        .disabled(!isStreaming)
        .help("Go to the simulator Home screen")

        Button {
            session.takeScreenshot()
        } label: {
            Label("Take Screenshot", systemImage: "camera.viewfinder")
        }
        .disabled(!isStreaming)
        .help("Save a screenshot of the simulator screen to the Desktop")

        Button {
            session.copyScreenshotToClipboard()
        } label: {
            Label("Copy Screenshot", systemImage: "clipboard")
        }
        .disabled(!isStreaming)
        .help("Copy a screenshot of the simulator screen to the clipboard")

        Button {
            session.chooseAnotherDevice()
        } label: {
            Label("Choose Device", systemImage: "list.bullet")
        }
        .help("Pick a different simulator")

        Button {
            session.shutdownSimulator()
        } label: {
            Label("Shutdown Simulator", systemImage: "power")
        }
        .disabled(session.bootedUDID == nil)
        .help("Power off the booted simulator")
    }
}

struct AndroidToolbarControls: View {
    let paneID: UUID

    var body: some View {
        let session = AndroidDeviceRegistry.shared.session(for: paneID)
        let isStreaming = session.status == .streaming

        Button {
            session.toggleRecording()
        } label: {
            Label(
                session.isRecording ? "Stop Recording" : "Record Screen",
                systemImage: session.isRecording ? "stop.circle.fill" : "record.circle"
            )
            .foregroundStyle(session.isRecording ? .red : .primary)
        }
        .disabled(!isStreaming && !session.isRecording)
        .help(session.isRecording ? "Stop recording" : "Record the Android screen")

        Button {
            session.takeScreenshot()
        } label: {
            Label("Take Screenshot", systemImage: "camera.viewfinder")
        }
        .disabled(!isStreaming)
        .help("Save a screenshot of the Android screen to the Desktop")

        Button {
            session.copyScreenshotToClipboard()
        } label: {
            Label("Copy Screenshot", systemImage: "clipboard")
        }
        .disabled(!isStreaming)
        .help("Copy a screenshot of the Android screen to the clipboard")

        Button {
            session.sendKeycode(AndroidKeyMap.Keycode.back)
        } label: {
            Label("Back", systemImage: "arrow.uturn.backward")
        }
        .disabled(!isStreaming)
        .help("Android Back")

        Button {
            session.sendKeycode(AndroidKeyMap.Keycode.home)
        } label: {
            Label("Home", systemImage: "square.grid.3x3.fill")
        }
        .disabled(!isStreaming)
        .help("Android Home")

        Button {
            session.sendKeycode(AndroidKeyMap.Keycode.appSwitch)
        } label: {
            Label("App Switch", systemImage: "square.on.square")
        }
        .disabled(!isStreaming)
        .help("Android recent apps")

        Button {
            session.chooseAnotherDevice()
        } label: {
            Label("Choose Device", systemImage: "list.bullet")
        }
        .help("Pick a different Android device")
    }
}

/// AppKit bridge for Safari-style ⌘L behavior. Restricting the lookup to the
/// key window is what lets Main and Extension expose simultaneous address
/// fields without one window stealing focus from the other.
@MainActor
enum BrowserAddressFocus {
    static func selectAddressFieldInKeyWindow() {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow,
                  let field = findAddressTextField(in: window.contentView)
                    ?? findAddressTextField(in: window.contentView?.superview) else { return }
            field.selectText(nil)
        }
    }

    private static func findAddressTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField,
           field.placeholderString == "URL" {
            return field
        }
        for subview in view.subviews {
            if let found = findAddressTextField(in: subview) {
                return found
            }
        }
        return nil
    }
}

struct ContentView: View {
    @Bindable var store: WorkspaceStore
    var syncService: PeerSyncService
    var peerDeviceStatus: DeviceStatus
    var localAudioOutput: AudioOutputDevice?
    var isPlotterConnected: Bool
    var remoteInkModel: RemoteInkModel
    /// Reflects whether a Copilot peer is currently push-to-talking. The
    /// transcription itself runs on the iPhone now — Pilot only paints
    /// the "listening" indicator and pastes the finished text.
    var isPeerRecording: Bool
    @State private var gitStore = RepositoryStore()
    @State private var tasksStore = GitHubTasksStore()
    @State private var usageStore = UsageStore()
    @State private var dockerStore = DockerStore()
    @State private var agenticUseStore = AgenticUsageStore()
    @State private var branchStore = WorkspaceBranchStore()
    @State private var isDrawingActive = false
    @AppStorage("sidebar.pinnedExpanded") private var pinnedSectionExpanded = true
    @AppStorage("sidebar.workspacesExpanded") private var workspacesSectionExpanded = true
    /// Persisted inspector column width. SwiftUI's `.inspector` resets to its
    /// `ideal` every time it re-presents (e.g. toggling Notes/Remote Desktop),
    /// so we remember the user's chosen width and feed it back as the ideal.
    @AppStorage("inspector.width") private var inspectorWidth = 280.0
    @State private var notesToggleMonitor: Any?
    @State private var persistenceFailure: PersistenceFailure?
    @FocusState private var renamingWorkspaceID: UUID?
    @State private var isGroupNamePresented = false
    @State private var editingGroupID: UUID?
    @State private var groupName = ""

    var body: some View {
        let activeInspectorRepoPath = isInspectorPresentedForSelectedWorkspace ? selectedWorkspaceRootPath : nil
        let _ = store.changeCount  // observation dependency for pin/unpin re-sort
        let workspaces = store.workspaces
        let workspaceShortcutIDs = workspaces.prefix(9).map(\.id)

        NavigationSplitView {
            List(selection: sidebarSelectionBinding) {
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
                    Section(isExpanded: $pinnedSectionExpanded) {
                        ForEach(pinned) { workspace in
                            workspaceRow(workspace)
                        }
                        .onMove(perform: store.movePinnedWorkspaces)
                    } header: {
                        Text("Pinned")
                    }
                }

                Section(isExpanded: $workspacesSectionExpanded) {
                    ForEach(store.workspaceGroups.items(workspaceIDs: store.unpinnedWorkspaceIDs)) { item in
                        switch item {
                        case .workspace(let id):
                            if let workspace = workspaces.first(where: { $0.id == id }) {
                                workspaceRow(workspace)
                            }
                        case .group(let id):
                            if let group = store.workspaceGroups.group(id) {
                                WorkspaceGroupSidebarRow(group: group, store: store) {
                                    editingGroupID = group.id
                                    groupName = group.name
                                    isGroupNamePresented = true
                                } workspaceRow: { workspace in
                                    workspaceRow(workspace)
                                }
                            }
                        }
                    }
                    .onMove { offsets, destination in
                        store.workspaceGroups.moveItems(
                            workspaceIDs: store.unpinnedWorkspaceIDs,
                            fromOffsets: offsets, toOffset: destination
                        )
                    }
                } header: {
                    Text("Workspaces")
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    RecordingStatusIndicator(isRecording: isPeerRecording)
                    AwakeStatusButton()

                    Spacer(minLength: 0)

                    HStack(spacing: 12) {
                        ForEach(connectedDevices) { device in
                            DeviceStatusButton(
                                device: device,
                                connectionDetail: connectionDetail(for: device)
                            )
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .alert(editingGroupID == nil ? "New Workspace Group" : "Rename Workspace Group",
                   isPresented: $isGroupNamePresented) {
                TextField("Group name", text: $groupName)
                Button("Cancel", role: .cancel) {}
                Button(editingGroupID == nil ? "Create" : "Save") {
                    if let editingGroupID {
                        store.workspaceGroups.rename(editingGroupID, to: groupName)
                    } else {
                        store.workspaceGroups.add(name: groupName, workspaceIDs: store.unpinnedWorkspaceIDs)
                        workspacesSectionExpanded = true
                    }
                }
                .disabled(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Menu {
                        Button(action: store.addWorkspace) {
                            Label("New Workspace", systemImage: "rectangle.on.rectangle")
                        }
                        Button {
                            editingGroupID = nil
                            groupName = ""
                            isGroupNamePresented = true
                        } label: {
                            Label("New Workspace Group", systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Label("New Workspace", systemImage: "plus")
                    }
                    .menuIndicator(.hidden)
                    .help("New workspace or workspace group")
                }
            }
        } detail: {
            ZStack {
                if workspaces.isEmpty {
                    ContentUnavailableView("No Workspace Selected",
                                           systemImage: "rectangle.on.rectangle.slash",
                                           description: Text("Create a workspace with the + button."))
                } else {
                    // The workspace stack stays mounted at all times — even in
                    // Notes mode — so entering Notes never tears down live
                    // terminals/browsers. Notes just deactivates every
                    // workspace, exactly like switching between workspaces does.
                    ZStack {
                        ForEach(workspaces) { workspace in
                            let isActive = store.isWorkspaceDetailVisible
                                && workspace.id == store.selectedWorkspaceID
                            WorkspaceView(
                                workspace: workspace,
                                isActive: isActive,
                                projectID: workspace.id,
                                surface: .main,
                                onPaneDrop: { payload, targetPane in
                                    store.movePane(payload, to: workspace, onto: targetPane)
                                }
                            )
                                .zIndex(isActive ? 1 : 0)
                                .opacity(isActive ? 1 : 0)
                                .allowsHitTesting(isActive)
                                .accessibilityHidden(!isActive)
                        }
                    }
                    // Same hardening as the pane slots inside WorkspaceView:
                    // workspace frames are pure layout for AppKit surfaces and
                    // must apply instantly, never via an ambient animation.
                    .transaction { $0.animation = nil }

                    if store.isWorkspaceDetailVisible && !hasSelectedWorkspace {
                        ContentUnavailableView {
                            Label("No Workspace Selected", systemImage: "rectangle.on.rectangle.slash")
                        } description: {
                            Text("Select a workspace from the sidebar.")
                        } actions: {
                            PinnedQuickJumpRow(
                                workspaces: workspaces,
                                onSelect: store.selectWorkspace
                            )
                        }
                    }
                }

                if store.isNotesMode {
                    NotesView(store: store)
                        .zIndex(100)
                }

                if store.isRemoteDesktopMode {
                    RemoteDesktopView(store: store)
                        .zIndex(100)
                }

                if store.isDockerMode {
                    DockerView(store: dockerStore)
                        .zIndex(100)
                }

                if store.isAgenticUseMode {
                    AgenticUseView(store: agenticUseStore)
                        .zIndex(100)
                }

                if isDrawingActive && store.isWorkspaceDetailVisible && !workspaces.isEmpty {
                    InkOverlay(isActive: $isDrawingActive)
                        .zIndex(60)
                }
            }
            .navigationTitle(navigationTitle)
        }
        .inspector(isPresented: selectedWorkspaceInspectorPresentedBinding) {
            InspectorPanelView(
                gitStore: gitStore,
                tasksStore: tasksStore,
                usageStore: usageStore,
                selectedTab: selectedWorkspaceInspectorTabBinding
            )
                // Capture the user's resize so the width survives re-presentation.
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    let clamped = min(max(Double(width), 220), 600)
                    if abs(clamped - inspectorWidth) > 1 { inspectorWidth = clamped }
                }
                .inspectorColumnWidth(min: 220, ideal: CGFloat(inspectorWidth), max: 600)
        }
        .onChange(of: activeInspectorRepoPath) {
            syncInspectorRepo(activeInspectorRepoPath)
        }
        .onChange(of: store.selectedWorkspaceID) {
            syncSelectedWorkspaceRootPath()
            if let workspace = store.selectedWorkspace {
                for pane in workspace.panes where pane.kind == .terminal {
                    pane.resetBellCount()
                }
            }
            focusSelectedWorkspaceTerminal()
        }
        .onChange(of: remoteInkModel.changeID) {
            guard remoteInkModel.hasInk,
                  !store.isNotesMode,
                  !workspaces.isEmpty else { return }
            isDrawingActive = true
        }
        .task {
            syncSelectedWorkspaceRootPath()
            syncInspectorRepo(activeInspectorRepoPath)
            focusSelectedWorkspaceTerminal()
            usageStore.start()
            branchStore.refresh(branchTargets(in: workspaces), force: true)
        }
        // A checkout happens in a terminal pane, so re-read when the workspace
        // set or the selection changes; the store itself rate-limits the rest.
        .onChange(of: store.changeCount) {
            branchStore.refresh(branchTargets(in: store.workspaces))
        }
        .onChange(of: store.selectedWorkspaceID) {
            branchStore.refresh(branchTargets(in: store.workspaces))
        }
        // Refetch usage the moment the inspector switches to the Usage tab, so a
        // key just saved in Settings shows results without waiting for the poll.
        .onChange(of: store.selectedWorkspace?.inspectorTab) { _, tab in
            if tab == .usage { usageStore.reload() }
        }
        .onAppear { installNotesToggleMonitor() }
        .onDisappear {
            removeNotesToggleMonitor()
            usageStore.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pilotPersistenceSaveFailed)) { notification in
            let operation = notification.userInfo?["operation"] as? String ?? "Saving made data"
            let message = notification.userInfo?["message"] as? String ?? "Unknown persistence error"
            persistenceFailure = PersistenceFailure(operation: operation, message: message)
        }
        .onReceive(NotificationCenter.default.publisher(for: UsageConsent.changedNotification)) { _ in
            usageStore.reload()
        }
        .alert(item: $persistenceFailure) { failure in
            Alert(
                title: Text("Changes could not be saved"),
                message: Text("\(failure.operation) failed: \(failure.message)\n\nYour non-destructive edits remain in memory. Free disk space or fix permissions, then retry."),
                primaryButton: .default(Text("Retry")) {
                    _ = store.modelContext.saveReporting(operation: "Retrying made data save")
                },
                secondaryButton: .cancel()
            )
        }
        .focusedSceneValue(
            store.isWorkspaceDetailVisible ? store.selectedWorkspace : nil
        )
        .focusedSceneValue(
            \.pilotCloseTabAction,
            PilotCloseTabAction(
                isEnabled: canCloseActiveTab,
                perform: closeActiveTab
            )
        )
        .toolbar {
            ToolbarItem(placement: .principal) {
                if store.isWorkspaceDetailVisible,
                   let pane = TerminalToolbarSelection.pane(
                       for: store.selectedWorkspace?.selectedPane
                   ) {
                    TerminalFastCommandToolbarField(pane: pane)
                        .id(pane.id)
                }
            }
            ToolbarItem(placement: .principal) {
                if store.isWorkspaceDetailVisible,
                   let pane = TerminalToolbarSelection.pane(
                       for: store.selectedWorkspace?.selectedPane
                   ) {
                    TerminalFastCommandToolbarActions(pane: pane)
                        .id(pane.id)
                }
            }
            ToolbarItemGroup(placement: .secondaryAction) {
                if store.isWorkspaceDetailVisible,
                   let pane = store.selectedWorkspace?.selectedPane {
                    PaneToolbarControls(pane: pane)
                }
            }
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .primaryAction) {
                    // ⌘T / ⌘B live as main-menu commands (see PilotApp.commands)
                    // so a focused browser web view can't swallow them.
                    WorkspacePaneLauncher(workspace: store.selectedWorkspace)
                        .disabled(store.isNotesMode)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.fixed, placement: .primaryAction)
            } else {
                ToolbarItem(placement: .primaryAction) {
                    WorkspacePaneLauncher(workspace: store.selectedWorkspace)
                        .disabled(store.isNotesMode)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isDrawingActive.toggle()
                } label: {
                    Label("Annotate",
                          systemImage: isDrawingActive ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                }
                .disabled(store.selectedWorkspace == nil || store.isNotesMode)
                .help("Draw over the active pane (⇧⌘D)")
                Button {
                    guard let workspace = store.selectedWorkspace else { return }
                    workspace.setInspectorPresented(!workspace.isInspectorPresented)
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .disabled(store.selectedWorkspace == nil || !store.isWorkspaceDetailVisible)
            }
        }
        .background(LeadingWorkspaceToolbarItem())
        .background(PilotWindowCloseMenuInstaller())
        .background {
            WorkspaceNumberShortcuts(
                workspaceIDs: workspaceShortcutIDs,
                onSelect: store.selectWorkspace
            )
            Button("") {
                guard store.selectedWorkspace != nil, !store.isNotesMode else { return }
                isDrawingActive.toggle()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .hidden()
            Button("") {
                store.selectedWorkspace?.selectNextPane()
                focusSelectedPaneIfTerminal()
            }
            .keyboardShortcut(.tab, modifiers: .control)
            .hidden()
            Button("") {
                store.selectedWorkspace?.selectPreviousPane()
                focusSelectedPaneIfTerminal()
            }
            .keyboardShortcut(.tab, modifiers: [.control, .shift])
            .hidden()
        }
        // Remote ink (from Plotter) overlays the entire Pilot window — sidebar
        // and detail — so its strokes line up with what Plotter mirrors, which
        // is the whole window. It's non-interactive, so the UI beneath stays
        // fully usable.
        .overlay {
            if remoteInkModel.hasInk {
                RemoteInkOverlay(model: remoteInkModel)
                    .ignoresSafeArea()
            }
        }
        // Undo / clear controls for the Plotter-drawn ink. Interactive (unlike
        // the render-only overlay above); commands round-trip to the iPad.
        .overlay(alignment: .bottomTrailing) {
            if remoteInkModel.hasInk {
                RemoteInkControls(model: remoteInkModel)
                    .padding(16)
            }
        }
    }

    private var canCloseActiveTab: Bool {
        if store.isNotesMode {
            return store.selectedNote != nil
        }
        guard store.isWorkspaceDetailVisible else { return false }
        return store.selectedWorkspace?.selectedPane != nil
    }

    private func closeActiveTab() {
        if store.isNotesMode {
            guard let note = store.selectedNote else { return }
            store.requestCloseNote(note)
            return
        }
        guard store.isWorkspaceDetailVisible,
              let workspace = store.selectedWorkspace,
              let pane = workspace.selectedPane else { return }
        workspace.requestRemovePane(pane)
    }

    /// Bridges the single-typed `List` selection to the store's split state:
    /// Notes mode lives in `isNotesMode`, workspace selection in
    /// `selectedWorkspaceID`. Selecting a workspace row (even the one already
    /// backing `selectedWorkspaceID`) flips out of Notes mode, because the
    /// selection value changes from `.notes` to `.workspace`.
    private var navigationTitle: String {
        if store.isNotesMode { return "Notes" }
        if store.isRemoteDesktopMode { return "Remote Desktop" }
        if store.isDockerMode { return "Docker" }
        if store.isAgenticUseMode { return "Agentic Use" }
        return store.selectedWorkspace?.name ?? ""
    }

    private var sidebarSelectionBinding: Binding<SidebarSelection?> {
        Binding(
            get: {
                if store.isNotesMode { return .notes }
                if store.isRemoteDesktopMode { return .remoteDesktop }
                if store.isDockerMode { return .docker }
                if store.isAgenticUseMode { return .agenticUse }
                if let id = store.selectedWorkspaceID { return .workspace(id) }
                return nil
            },
            set: { newValue in
                switch newValue {
                case .notes:
                    store.enterNotesMode()
                case .remoteDesktop:
                    store.enterRemoteDesktopMode()
                case .docker:
                    store.enterDockerMode()
                case .agenticUse:
                    store.enterAgenticUseMode()
                case .workspace(let id):
                    store.selectWorkspace(id)
                case nil:
                    break
                }
            }
        )
    }

    /// ⌘0 toggles Notes ↔ the current workspace from anywhere. We use a local
    /// `NSEvent` monitor rather than only a menu shortcut because monitors run
    /// before key-equivalent dispatch and before the focused view — so it beats
    /// both Ghostty (which binds ⌘0 to reset-font-size) and the notes editor's
    /// field editor. `⌥⌘0` (Actual Size) is excluded by the exact-flags check.
    private func installNotesToggleMonitor() {
        guard notesToggleMonitor == nil else { return }
        notesToggleMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command,
                  event.charactersIgnoringModifiers == "0" else {
                return event
            }
            store.toggleNotesMode()
            return nil
        }
    }

    private func removeNotesToggleMonitor() {
        if let monitor = notesToggleMonitor {
            NSEvent.removeMonitor(monitor)
            notesToggleMonitor = nil
        }
    }

    private func focusSelectedPaneIfTerminal() {
        guard let pane = store.selectedWorkspace?.selectedPane,
              pane.kind == .terminal else { return }
        DispatchQueue.main.async {
            _ = GhosttyMetalView.focus(paneID: pane.id)
        }
    }

    private var connectedDevices: [ConnectedDevice] {
        let audioDevice = ConnectedDevice(
            kind: localAudioOutput?.kind ?? .headphonesBluetooth,
            isConnected: localAudioOutput != nil,
            name: localAudioOutput?.name
        )
        return [
            ConnectedDevice(kind: .iphone, isConnected: syncService.isConnected),
            ConnectedDevice(kind: .ipad, isConnected: isPlotterConnected),
            ConnectedDevice(kind: .appleWatch, isConnected: peerDeviceStatus.isWatchConnected),
            audioDevice
        ]
    }

    private func connectionDetail(for device: ConnectedDevice) -> String? {
        switch device.kind {
        case .iphone:
            syncService.statusText
        case .ipad:
            isPlotterConnected ? "Kneeboard connected" : nil
        case .appleWatch:
            peerDeviceStatus.isWatchConnected ? "Companion watch connected" : nil
        case .airpods, .airpodsPro, .airpodsMax, .beats, .headphonesWired,
             .headphonesBluetooth, .usb, .speaker, .unknown:
            nil
        case .computer:
            nil
        }
    }

    private func workspaceRow(_ workspace: Workspace) -> some View {
        WorkspaceSidebarRow(
            workspace: workspace,
            branch: branchStore.branches[workspace.id],
            renamingWorkspaceID: $renamingWorkspaceID,
            store: store,
            onUpdateRootPath: { presentRootPathPicker(for: workspace) }
        )
    }

    private var selectedWorkspaceInspectorTabBinding: Binding<InspectorTab> {
        Binding(
            get: { self.store.selectedWorkspace?.inspectorTab ?? .actions },
            set: { tab in
                self.store.selectedWorkspace?.setInspectorTab(tab)
            }
        )
    }

    private var selectedWorkspaceInspectorPresentedBinding: Binding<Bool> {
        Binding(
            get: { isInspectorPresentedForSelectedWorkspace },
            set: { isPresented in
                // The global modes transiently hide the inspector by forcing
                // `get` to false. SwiftUI echoes that back through this setter,
                // which would otherwise persist `false` into the workspace and
                // lose its real state. Ignore writes while a global mode is
                // showing; only genuine in-workspace toggles persist — so the
                // panel restores to what it was on return.
                guard store.isWorkspaceDetailVisible else { return }
                store.selectedWorkspace?.setInspectorPresented(isPresented)
            }
        )
    }

    private var isInspectorPresentedForSelectedWorkspace: Bool {
        store.isWorkspaceDetailVisible
            && (store.selectedWorkspace?.isInspectorPresented ?? false)
    }

    /// Workspaces that could have a branch — one without a root path has no
    /// work tree to read, so it is never handed to a `git` lookup.
    private func branchTargets(in workspaces: [Workspace]) -> [WorkspaceBranchStore.Target] {
        workspaces.compactMap { workspace in
            guard let path = workspace.effectiveRootPath else { return nil }
            return WorkspaceBranchStore.Target(id: workspace.id, rootPath: path)
        }
    }

    private var hasSelectedWorkspace: Bool {
        guard let id = store.selectedWorkspaceID else { return false }
        return store.workspaces.contains { $0.id == id }
    }

    private func focusSelectedWorkspaceTerminal() {
        guard let workspace = store.selectedWorkspace,
              let pane = workspace.frontmostTerminalPane else { return }
        workspace.setFrontmostTerminalPaneID(pane.id)
        DispatchQueue.main.async {
            _ = GhosttyMetalView.focus(paneID: pane.id)
        }
    }

    private var selectedWorkspaceRootPath: String? {
        store.selectedWorkspace?.effectiveRootPath
    }

    private func syncSelectedWorkspaceRootPath() {
        store.selectedWorkspace?.syncDefaultRootPathIfNeeded()
    }

    /// Browse to and pick the workspace's root directory with AppKit's native
    /// folder panel (issue #65). The panel only returns directories that exist,
    /// so we get validation for free; cancelling leaves the path unchanged.
    /// Pilot ships unsandboxed, so the returned path is usable directly with no
    /// security-scoped bookmark.
    private func presentRootPathPicker(for workspace: Workspace) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Set Root Path"
        panel.message = "Choose the root directory for “\(workspace.name)”."
        // Seed the browser at the current root when one is set.
        if let current = workspace.effectiveRootPath {
            panel.directoryURL = URL(fileURLWithPath: current)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspace.setRootPath(url.path)
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

/// SwiftUI inserts a flexible toolbar spacer before sidebar-scoped navigation
/// items on macOS, pushing New Workspace to the sidebar divider. Keep the
/// native sidebar toggle/tracking separator, but move only New Workspace ahead
/// of that spacer so it sits immediately after the traffic lights.
private struct LeadingWorkspaceToolbarItem: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        InstallerView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class InstallerView: NSView {
        private var toolbarObservers: [NSObjectProtocol] = []
        private weak var observedToolbar: NSToolbar?
        private var isReordering = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installToolbarObserversIfNeeded()
            scheduleReordering()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                toolbarObservers.forEach(NotificationCenter.default.removeObserver)
                toolbarObservers.removeAll()
                observedToolbar = nil
            }
            super.viewWillMove(toWindow: newWindow)
        }

        private func installToolbarObserversIfNeeded() {
            guard let toolbar = window?.toolbar, toolbar !== observedToolbar else { return }
            toolbarObservers.forEach(NotificationCenter.default.removeObserver)
            toolbarObservers.removeAll()
            observedToolbar = toolbar

            for name in [NSToolbar.willAddItemNotification, NSToolbar.didRemoveItemNotification] {
                toolbarObservers.append(
                    NotificationCenter.default.addObserver(
                        forName: name,
                        object: toolbar,
                        queue: .main
                    ) { [weak self] _ in
                        Task { @MainActor in
                            self?.scheduleReordering()
                        }
                    }
                )
            }
        }

        private func scheduleReordering() {
            DispatchQueue.main.async { [weak self] in
                self?.moveWorkspaceButtonToLeadingEdge()
            }
        }

        private func moveWorkspaceButtonToLeadingEdge() {
            guard !isReordering, let toolbar = window?.toolbar else { return }
            installToolbarObserversIfNeeded()
            guard let currentIndex = toolbar.items.firstIndex(where: {
                $0.label == "New Workspace"
            }), currentIndex > 0 else { return }

            isReordering = true
            let identifier = toolbar.items[currentIndex].itemIdentifier
            toolbar.removeItem(at: currentIndex)
            toolbar.insertItem(withItemIdentifier: identifier, at: 0)
            isReordering = false
        }
    }
}

private struct RecordingStatusIndicator: View {
    let isRecording: Bool
    @State private var isPopoverPresented = false

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            Image(systemName: isRecording ? "waveform.circle.fill" : "waveform.circle")
                .foregroundStyle(isRecording ? .red : .secondary)
        }
        .buttonStyle(.plain)
        .statusButtonHitTarget()
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            StatusPopoverContent(
                title: "Microphone",
                status: isRecording ? "Recording" : "Idle",
                systemImage: isRecording ? "waveform.circle.fill" : "waveform.circle",
                tint: isRecording ? .red : .secondary
            )
        }
        .help(isRecording ? "Microphone recording" : "Microphone idle")
        .accessibilityLabel(isRecording ? "Microphone recording" : "Microphone idle")
        .accessibilityIdentifier("sidebar.microphone-status")
    }
}

private struct AwakeStatusButton: View {
    @State private var controller = AwakeSessionController.shared
    @State private var isPopoverPresented = false

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            Image(systemName: "cup.and.heat.waves")
                .foregroundStyle(controller.isEnabled ? Color.green : .secondary)
        }
        .buttonStyle(.plain)
        .statusButtonHitTarget()
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            AwakeSessionDetailsView(controller: controller)
        }
        .help(controller.isEnabled ? "Keep Awake active" : "Keep Awake off")
        .accessibilityLabel(controller.isEnabled ? "Keep Awake active" : "Keep Awake off")
        .accessibilityIdentifier("sidebar.keep-awake-status")
    }
}

private struct AwakeSessionDetailsView: View {
    @Bindable var controller: AwakeSessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $controller.isEnabled) {
                HStack(spacing: 8) {
                    Image(systemName: "cup.and.heat.waves")
                    Text("Keep Awake")
                        .fontWeight(.semibold)
                    Spacer(minLength: 12)
                    Circle()
                        .fill(controller.isEnabled ? Color.green : Color.secondary.opacity(0.6))
                        .frame(width: 7, height: 7)
                }
            }
            .toggleStyle(.checkbox)

            Text(controller.sessionStatus)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())

            VStack(alignment: .leading, spacing: 7) {
                Toggle("Allow display sleep", isOn: $controller.allowDisplaySleep)
                Toggle(
                    "Allow system sleep when display is closed",
                    isOn: $controller.allowSystemSleepWhenDisplayClosed
                )
                Toggle(
                    "Allow screen saver after 45m of inactivity",
                    isOn: $controller.allowScreenSaverAfter45Minutes
                )
            }
            .toggleStyle(.checkbox)

            if let assertionError = controller.assertionError {
                Text(assertionError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 350, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("keep-awake.popover")
    }
}

private struct DeviceStatusButton: View {
    let device: ConnectedDevice
    let connectionDetail: String?
    @State private var isPopoverPresented = false

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            Image(systemName: device.kind.systemImageName)
                .symbolVariant(device.kind.usesFillVariant ? .fill : .none)
                .foregroundStyle(device.isConnected ? .green : .secondary)
        }
        .buttonStyle(.plain)
        .statusButtonHitTarget()
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            StatusPopoverContent(
                title: device.name ?? device.kind.displayName,
                status: device.isConnected ? "Connected" : "Not connected",
                detail: connectionDetail,
                systemImage: device.kind.systemImageName,
                tint: device.isConnected ? .green : .secondary
            )
        }
        .help(device.name ?? device.kind.displayName)
        .accessibilityLabel(
            "\(device.name ?? device.kind.displayName), \(device.isConnected ? "connected" : "not connected")"
        )
        .accessibilityIdentifier("sidebar.device-status.\(device.kind.rawValue)")
    }
}

private struct StatusPopoverContent: View {
    let title: String
    let status: String
    var detail: String?
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .font(.title3)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(status)
                    .foregroundStyle(.secondary)
                if let detail, detail != status {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(width: 240, alignment: .leading)
    }
}

private extension View {
    func statusButtonHitTarget() -> some View {
        frame(width: 22, height: 22)
            .contentShape(Rectangle())
    }
}

@MainActor
private enum ContentViewPreviewData {
    static let container: ModelContainer = {
        let schema = Schema([
            Workspace.self,
            Pane.self,
            BrowserState.self,
            EditorState.self,
            Note.self,
            RemoteDesktopConnection.self,
            ExtensionWorkspaceLink.self,
        ])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: configuration)
    }()
}

#Preview {
    ContentView(
        store: WorkspaceStore(modelContext: ContentViewPreviewData.container.mainContext),
        syncService: PeerSyncService(role: .advertiser, displayName: "Preview"),
        peerDeviceStatus: DeviceStatus(),
        localAudioOutput: nil,
        isPlotterConnected: false,
        remoteInkModel: RemoteInkModel(),
        isPeerRecording: false
    )
    .modelContainer(ContentViewPreviewData.container)
}
