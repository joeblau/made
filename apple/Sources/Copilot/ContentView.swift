import SwiftUI

enum CopilotVolumeHoldAction: Equatable, Sendable {
    case record(workspaceID: UUID?)
    case send(workspaceID: UUID?)

    init?(direction: VolumeDirection, selectedWorkspaceID: UUID?) {
        switch direction {
        case .down:
            self = .record(workspaceID: selectedWorkspaceID)
        case .up:
            self = .send(workspaceID: selectedWorkspaceID)
        case .none:
            return nil
        }
    }
}

struct ContentView: View {
    let syncService: PeerSyncService
    let watchDelegate: PhoneSessionDelegate
    let buildMonitor: BuildActivityController
    @ObservedObject var dashboardActivities: DashboardActivityController
    @State private var dashboard: CopilotDashboardModel
    @State private var showBuildMonitor = false
    @State private var showDashboard = false
    @State private var dashboardFamily = DashboardFamily.actions
    /// When true, the view seeds representative fixture content and skips
    /// the live sync/transcription setup so screenshots render without a
    /// Pilot peer. Defaults to the launch-arg-driven UserDefaults flag.
    var demoMode: Bool = UserDefaults.standard.bool(forKey: "demoMode")

    @State private var workspaces: [WorkspaceSummary] = []
    @State private var selectedID: UUID?
    @State private var selectionState = CopilotWorkspaceSelectionState()
    @State private var transcription: TranscriptionService
    @State private var walkie: CopilotWalkieTalkie
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showModelDownloadConfirmation = false
    @State private var showSpeechStorage = false
    @AppStorage("transcription.allowRestrictedNetwork") private var allowRestrictedNetwork = false
    /// Auto-generated identity key, auto-exchanged with Pilot over the
    /// encrypted channel (issue #51). Drives the Settings "Identity & Keys".
    @State private var secureIdentity = SecureIdentity(role: .copilot)
    #if DEBUG
    /// Screenshot fixture for the pairing alert (`-demoScenario pairAlert`).
    @State private var demoPairingRequest: PeerSyncPairingRequest?
    #endif

    init(syncService: PeerSyncService, watchDelegate: PhoneSessionDelegate,
         buildMonitor: BuildActivityController = BuildActivityController(),
         dashboardActivities: DashboardActivityController,
         demoMode: Bool = UserDefaults.standard.bool(forKey: "demoMode")) {
        self.syncService = syncService
        self.watchDelegate = watchDelegate
        self.buildMonitor = buildMonitor
        self.dashboardActivities = dashboardActivities
        self.demoMode = demoMode
        _dashboard = State(initialValue: CopilotDashboardModel(activities: dashboardActivities))
        let transcription = TranscriptionService()
        _transcription = State(initialValue: transcription)
        _walkie = State(initialValue: CopilotWalkieTalkie(
            start: { await transcription.start(allowRestrictedNetwork: $0) },
            finish: {
                await transcription.stop()
                return transcription.combinedText
            },
            send: { await syncService.sendReliably($0) },
            isConnected: { syncService.isConnected }
        ))
    }

    /// In demo mode we treat the peer as connected so the populated
    /// workspace list and trackpad inset render. The live `isConnected`
    /// is untouched on the normal path.
    private var isPeerConnected: Bool {
        (demoMode && !CopilotDemoScenario.forcesDisconnected) || syncService.isConnected
    }

    /// The pending pairing approval: the live request, or in DEBUG demo
    /// builds a fixture request so the alert can be reviewed without a peer.
    private var pairingRequest: PeerSyncPairingRequest? {
        #if DEBUG
        if let demoPairingRequest { return demoPairingRequest }
        #endif
        return syncService.pairingRequest
    }

    private func resolvePairingRequest(approved: Bool) {
        #if DEBUG
        // A fixture prompt only dismisses itself. It must never resolve a
        // live request whose fingerprint it was hiding (as in Cockpit).
        if demoPairingRequest != nil { demoPairingRequest = nil; return }
        #endif
        syncService.resolvePairingRequest(approved: approved)
    }

    var body: some View {
        NavigationStack {
            mainContent
            .toolbar {
                deviceToolbar
                // Settings/storage and the two dashboards are separate groups
                // on the shared glass toolbar background.
                ToolbarSpacer(.fixed, placement: .topBarLeading)
                ToolbarItem(placement: .topBarLeading) {
                    Button("Dashboard", systemImage: "square.grid.2x2") { showDashboard = true }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Builds", systemImage: "hammer") { showBuildMonitor = true }
                }
            }
            .safeAreaInset(edge: .bottom) {
                trackpadInset
            }
            .safeAreaInset(edge: .top) {
                // Below the toolbar, never over it: the download banner and
                // the walkie HUD push the list down instead of covering the
                // Settings/Dashboard glass groups (glass on glass).
                VStack(spacing: 0) {
                    if transcription.isModelLoading {
                        modelLoadingBanner
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    walkieStatus
                }
                .animation(LiquidGlassMetrics.spring, value: transcription.isModelLoading)
                .animation(LiquidGlassMetrics.spring, value: walkie.phase)
                // An idle status message alone also shows/hides the HUD.
                .animation(LiquidGlassMetrics.spring, value: walkie.statusMessage)
            }
        }
        .environment(secureIdentity)
        .sheet(isPresented: $showBuildMonitor) {
            BuildMonitorView(monitor: buildMonitor, connected: isPeerConnected)
        }
        .sheet(isPresented: $showDashboard) {
            CopilotDashboardView(
                model: dashboard,
                activities: dashboardActivities,
                connected: isPeerConnected,
                selectedFamily: $dashboardFamily
            )
        }
        .onOpenURL { url in
            switch CopilotDeepLink(url: url) {
            case .build:
                showDashboard = false
                showBuildMonitor = true
            case .dashboard(let family):
                dashboardFamily = family
                showBuildMonitor = false
                showDashboard = true
            case nil:
                break
            }
        }
        .task {
            dashboard.restoreActivities()
            guard !demoMode else {
                seedDemoState()
                return
            }
            setupSync()
        }
        .onChange(of: watchDelegate.isWatchReachable) {
            sendDeviceStatus()
        }
        .onChange(of: syncService.isConnected) {
            guard syncService.isConnected else {
                walkie.interrupt()
                return
            }
            sendDeviceStatus()
            buildMonitor.connected()
            secureIdentity.refreshPeer()
            // Confirm the already-approved pin to the authenticated peer.
            secureIdentity.announce()
        }
        .onChange(of: scenePhase) {
            if scenePhase != .active { walkie.interrupt() }
            if scenePhase == .active {
                buildMonitor.connected()
                dashboard.restoreActivities()
            }
        }
        .onDisappear { walkie.interrupt() }
        .alert("Download Speech Model?", isPresented: $showModelDownloadConfirmation) {
            Button("Not Now", role: .cancel) {
            }
            // The recommended path is the alert's one emphasized action (BTN-1).
            Button("Download on Wi-Fi", role: .confirm) {
                prepareSpeechModel(allowRestrictedNetwork: false)
            }
            .keyboardShortcut(.defaultAction)
            Button("Use Cellular") {
                allowRestrictedNetwork = true
                prepareSpeechModel(allowRestrictedNetwork: true)
            }
        } message: {
            Text("On-device transcription requires Parakeet v3 Ultra (about 630 MB). It is downloaded only once and cached on this iPhone. After it finishes, hold Volume Down again to record.")
        }
        .alert("Transcription Unavailable", isPresented: Binding(
            get: { transcription.modelErrorMessage != nil },
            set: { if !$0 { transcription.modelErrorMessage = nil } }
        )) {
            Button("Retry", role: .confirm) {
                transcription.modelErrorMessage = nil
                prepareSpeechModel(allowRestrictedNetwork: allowRestrictedNetwork)
            }
            .keyboardShortcut(.defaultAction)
            Button("Use Cellular") {
                transcription.modelErrorMessage = nil
                allowRestrictedNetwork = true
                prepareSpeechModel(allowRestrictedNetwork: true)
            }
            Button("Manage Storage") {
                transcription.modelErrorMessage = nil
                showSpeechStorage = true
            }
            Button("Not Now", role: .cancel) { transcription.modelErrorMessage = nil }
        } message: {
            Text(transcription.modelErrorMessage ?? "")
        }
        .sheet(isPresented: $showSpeechStorage) {
            SpeechModelStorageView(transcription: transcription)
        }
        .alert(
            pairingRequest?.isKeyChange == true
                ? "Trust New Cockpit Identity?"
                : "Pair with Cockpit?",
            isPresented: Binding(
                get: { pairingRequest != nil },
                set: { if !$0 { resolvePairingRequest(approved: false) } }
            )
        ) {
            Button("Reject", role: .cancel) {
                resolvePairingRequest(approved: false)
            }
            Button(pairingRequest?.isKeyChange == true ? "Trust New Key" : "Pair") {
                resolvePairingRequest(approved: true)
            }
        } message: {
            let request = pairingRequest
            Text("Verify this fingerprint on \(request?.displayName ?? "the other device") before approving:\n\n\(request?.fingerprint ?? "")")
        }
    }

    /// Floating download status with its Cancel control beside it: two
    /// sibling glass shapes in one container, never glass stacked on glass.
    private var modelLoadingBanner: some View {
        // Container spacing below the stack gap: the two shapes render
        // together but stay distinct instead of blending into one blob.
        GlassEffectContainer(spacing: LiquidGlassMetrics.Spacing.xSmall) {
            if dynamicTypeSize.isAccessibilitySize {
                // Accessibility sizes: one column, so the status wraps by
                // words at full width and Cancel never hyphenates (TYPE-4).
                VStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                    VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xSmall) {
                        modelLoadingProgressIndicator
                        modelLoadingStatusText
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(LiquidGlassMetrics.Spacing.medium)
                    .glassEffect(.regular, in: RoundedRectangle(
                        cornerRadius: LiquidGlassMetrics.Radius.panel, style: .continuous
                    ))
                    modelLoadingCancelButton(fullWidth: true)
                }
            } else {
                HStack(spacing: LiquidGlassMetrics.Spacing.small) {
                    HStack(spacing: LiquidGlassMetrics.Spacing.small) {
                        modelLoadingProgressIndicator
                            .frame(width: transcription.modelLoadingFraction == nil ? nil : 56)
                        modelLoadingStatusText
                        Spacer(minLength: 0)
                    }
                    // Capsule ends are half the height wide; the larger side
                    // inset keeps the progress bar off the curve.
                    .padding(.horizontal, LiquidGlassMetrics.Spacing.large)
                    .padding(.vertical, LiquidGlassMetrics.Spacing.xSmall)
                    .frame(maxHeight: .infinity)
                    .glassEffect(.regular, in: Capsule())

                    modelLoadingCancelButton(fullWidth: false)
                }
                // Both capsules take the taller one's height, so the status and
                // its Cancel read as one row of matching shapes (LAY-4).
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, LiquidGlassMetrics.Spacing.medium)
        .padding(.bottom, LiquidGlassMetrics.Spacing.xSmall)
    }

    @ViewBuilder
    private var modelLoadingProgressIndicator: some View {
        if let fraction = transcription.modelLoadingFraction {
            ProgressView(value: fraction)
        } else {
            ProgressView()
        }
    }

    private var modelLoadingStatusText: some View {
        Text(transcription.modelLoadingProgress)
            .font(.footnote)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func modelLoadingCancelButton(fullWidth: Bool) -> some View {
        Button {
            transcription.cancelModelLoad()
            walkie.interrupt()
        } label: {
            // Full width below the status at accessibility sizes; beside it,
            // the label stretches to the status capsule's height.
            Text("Cancel")
                .frame(maxWidth: fullWidth ? .infinity : nil, maxHeight: fullWidth ? nil : .infinity)
        }
        .liquidGlassButtonStyle()
        .buttonBorderShape(.capsule)
    }

    @ViewBuilder
    private var mainContent: some View {
        if !isPeerConnected && workspaces.isEmpty {
            ContentUnavailableView {
                Label("Looking for Cockpit…", systemImage: "antenna.radiowaves.left.and.right")
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            } description: {
                Text("Make sure Cockpit is running on your Mac.")
            }
            // The pulsing antenna is the one loading motion, as in
            // Kneeboard's Searching overlay; a spinner beside it competed
            // with it (MOT-3, MOT-5).
        } else if workspaces.isEmpty {
            ContentUnavailableView(
                "No Workspaces",
                systemImage: "rectangle.on.rectangle.slash",
                description: Text("Create a workspace in Cockpit.")
            )
        } else {
            workspaceList
        }
    }

    private var workspaceList: some View {
        VolumeScrollListView(
            sections: workspaceSections,
            selectedID: $selectedID,
            onHighlightChanged: { workspace in
                selectionState.select(workspace.id)
                syncService.send(.selectWorkspace(SelectWorkspace(workspaceID: workspace.id)))
            },
            onVolumeHoldStart: { direction in
                switch CopilotVolumeHoldAction(direction: direction, selectedWorkspaceID: selectedID) {
                case .record(let workspaceID):
                    if transcription.isModelLoaded || transcription.hasCachedModel {
                        walkie.beginRecording(workspaceID: workspaceID, allowRestrictedNetwork: allowRestrictedNetwork)
                    } else {
                        walkie.recordingUnavailable(workspaceID: workspaceID)
                        showModelDownloadConfirmation = true
                    }
                case .send(let workspaceID):
                    walkie.execute(workspaceID: workspaceID)
                case nil:
                    break
                }
            },
            onVolumeHoldEnd: { direction in
                guard direction == .down else { return }
                walkie.endRecording()
            },
            rearmToken: walkie.rearmToken
        ) { workspace, isHighlighted in
            workspaceRow(workspace, isHighlighted: isHighlighted)
        }
    }

    @ViewBuilder
    private var walkieStatus: some View {
        if !demoMode || CopilotDemoScenario.showsWalkieHUD, walkie.phase != .idle || walkie.statusMessage != nil {
            VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xSmall) {
                Group {
                switch walkie.phase {
                case .preparing:
                    Label("Preparing microphone…", systemImage: "mic")
                case .recording:
                    // The pulsing red glyph carries the recording signal
                    // (COL-4); the footnote copy stays primary so it keeps
                    // contrast on the glass HUD (TYPE-3).
                    Label {
                        Text("Recording — release Volume Down to send")
                    } icon: {
                        Image(systemName: "mic.fill")
                            .foregroundStyle(.red)
                            .symbolEffect(.pulse, options: .repeating)
                    }
                case .finishing:
                    Label("Finishing transcription…", systemImage: "waveform")
                case .idle:
                    if let message = walkie.statusMessage { Text(message) }
                }
                }
                // Status lines wrap rather than truncate; under pressure the
                // transcript below gives up height first (TYPE-4).
                .fixedSize(horizontal: false, vertical: true)
                let text = walkie.displayedTranscript(liveText: transcription.combinedText)
                if !text.isEmpty || walkie.phase == .recording {
                    WalkieTranscriptView(text: text, isRecording: walkie.phase == .recording)
                }
                if walkie.phase == .idle, !walkie.transcript.isEmpty {
                    ShareLink("Copy or Share Transcript", item: walkie.transcript)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(LiquidGlassMetrics.Spacing.medium)
            // Transient HUD floating over the list, not a full-bleed slab
            // under the (already glass) navigation bar.
            .glassEffect(.regular, in: RoundedRectangle(
                cornerRadius: LiquidGlassMetrics.Radius.panel, style: .continuous
            ))
            .padding(.horizontal, LiquidGlassMetrics.Spacing.medium)
            .padding(.bottom, LiquidGlassMetrics.Spacing.xSmall)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func prepareSpeechModel(allowRestrictedNetwork: Bool) {
        Task {
            _ = await transcription.loadModel(allowRestrictedNetwork: allowRestrictedNetwork)
        }
    }

    @ViewBuilder
    private func workspaceRow(_ workspace: WorkspaceSummary, isHighlighted: Bool) -> some View {
        HStack {
            Text(workspace.name)
                .fontWeight(isHighlighted ? .semibold : .regular)
            Spacer()
            // Count sits trailing, like system list badges, so names share
            // one leading edge and counts share one trailing edge.
            if workspace.badgeCount > 0 {
                Text("\(workspace.badgeCount)")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, LiquidGlassMetrics.Spacing.xSmall)
                    .padding(.vertical, 2)
                    .background(.red, in: Capsule())
            }
        }
        .padding(.vertical, LiquidGlassMetrics.Spacing.xxSmall)
    }

    private var workspaceSections: [VolumeScrollSection<WorkspaceSummary>] {
        let pinned = workspaces.filter(\.isPinned)
        let unpinned = workspaces.filter { !$0.isPinned }

        var sections: [VolumeScrollSection<WorkspaceSummary>] = []
        if !pinned.isEmpty {
            sections.append(VolumeScrollSection(id: "pinned", title: "Pinned", items: pinned))
        }
        if !unpinned.isEmpty {
            sections.append(VolumeScrollSection(id: "workspaces", title: "Workspaces", items: unpinned))
        }
        return sections
    }

    @ToolbarContentBuilder
    private var deviceToolbar: some ToolbarContent {
        // "•••" settings entry, top-left.
        ToolbarItem(placement: .topBarLeading) {
            SettingsButton()
        }
        ToolbarItem(placement: .topBarLeading) {
            // Titled like its neighbors; the toolbar shows the symbol only
            // and the title stays the VoiceOver name.
            Button("Speech Model Storage", systemImage: "waveform.badge.magnifyingglass") {
                showSpeechStorage = true
            }
        }
        // Device connection status, top-right.
        // Status glyphs, not controls: keep them off the glass control layer
        // so they don't read as tappable buttons.
        ToolbarItemGroup(placement: .topBarTrailing) {
            ForEach(connectedDevices) { device in
                deviceIcon(device)
            }
        }
        .sharedBackgroundVisibility(.hidden)
    }

    @ViewBuilder
    private func deviceIcon(_ device: ConnectedDevice) -> some View {
        Image(systemName: device.kind.systemImageName)
            .symbolVariant(device.kind.usesFillVariant ? .fill : .none)
            .foregroundStyle(device.isConnected ? .green : .secondary)
            .help(device.name ?? device.kind.displayName)
    }

    @ViewBuilder
    private var trackpadInset: some View {
        if isPeerConnected {
            GlassEffectContainer(spacing: LiquidGlassMetrics.Spacing.small) {
                VStack(spacing: LiquidGlassMetrics.Spacing.small) {
                    // Always rendered (fixed height) so the bottom doesn't flash
                    // in/out as workspace state syncs each second; degrades to a
                    // disabled state when the selection has no tabs.
                    TabSwitcherBar(workspace: selectedWorkspace) { workspaceID, tabID in
                        syncService.send(.selectTab(SelectTab(workspaceID: workspaceID, tabID: tabID)))
                    }
                    TrackpadView(syncService: syncService)
                }
            }
        }
    }

    private var selectedWorkspace: WorkspaceSummary? {
        workspaces.first { $0.id == selectedID }
    }

    private var localDeviceStatus: DeviceStatus {
        DeviceStatus(
            isWatchConnected: demoMode ? true : watchDelegate.isWatchReachable
        )
    }

    private var connectedDevices: [ConnectedDevice] {
        ConnectedDeviceCatalog.devices(
            for: .copilot,
            peerConnected: isPeerConnected,
            deviceStatus: localDeviceStatus
        )
    }

    private func setupSync() {
        buildMonitor.send = { syncService.send($0) }
        buildMonitor.restore()
        secureIdentity.send = { syncService.send($0) }
        syncService.onReceive = { message in
            switch message {
            case .workspaceState(let state):
                workspaces = state.workspaces
                selectedID = selectionState.receive(state)
                buildMonitor.receive(state.workflowRuns ?? [])
                dashboard.receive(
                    actions: state.actionsDashboard,
                    usage: state.usageDashboard,
                    runners: state.runnersDashboard
                )
            case .buildRunUpdate(let run):
                buildMonitor.receive(run)
            case .deviceKey(let announce):
                secureIdentity.receive(announce)
            case .selectWorkspace, .selectTab, .deviceStatus, .mouseMove, .mouseClick,
                 .voiceRecord, .transcribedSpeech, .terminalInput, .executeTranscript, .followBuild, .unfollowBuild:
                break
            }
        }
        syncService.start()
    }

    /// Populates the workspace list with representative fixture content
    /// for screenshots/UITests. No network, no transcription model load.
    private func seedDemoState() {
        let demoTabs: [TabSummary] = [
            TabSummary(id: UUID(), title: "Terminal 1", systemImageName: "terminal"),
            TabSummary(id: UUID(), title: "Terminal 2", systemImageName: "terminal"),
            TabSummary(id: UUID(), title: "Browser", systemImageName: "safari")
        ]
        let demo: [WorkspaceSummary] = [
            WorkspaceSummary(id: UUID(), name: "made", isPinned: true, badgeCount: 0,
                             tabs: demoTabs, selectedTabID: demoTabs.first?.id),
            WorkspaceSummary(id: UUID(), name: "web", badgeCount: 2),
            WorkspaceSummary(id: UUID(), name: "infra", badgeCount: 0),
            WorkspaceSummary(id: UUID(), name: "api", badgeCount: 5)
        ]
        workspaces = demo
        selectedID = demo.first?.id
        #if DEBUG
        if let scenario = CopilotDemoScenario.current { applyDemoScenario(scenario) }
        #endif
    }

    #if DEBUG
    /// Puts the real views into one fixture state for screenshot review.
    /// Reached only through `-demoMode YES -demoScenario <name>`.
    private func applyDemoScenario(_ scenario: CopilotDemoScenario) {
        let transcript = "Run the release checklist and open a pull request for the widget fixes"
        switch scenario {
        case .searching, .noWorkspaces:
            workspaces = []
            selectedID = nil
        case .disconnected:
            break
        case .preparing:
            walkie.applyDemoState(phase: .preparing)
        case .listening:
            walkie.applyDemoState(phase: .recording)
        case .recording:
            transcription.partialText = transcript
            walkie.applyDemoState(phase: .recording)
        case .finishing:
            transcription.partialText = transcript
            walkie.applyDemoState(phase: .finishing)
        case .sent:
            walkie.applyDemoState(
                phase: .idle,
                transcript: transcript,
                statusMessage: "Sent to Cockpit. Hold Volume Up to execute."
            )
        case .modelLoading:
            transcription.isModelLoading = true
            transcription.modelLoadingFraction = 0.42
            transcription.modelLoadingProgress = "Downloading speech model… 42%"
        case .modelLoadingCached:
            transcription.isModelLoading = true
            transcription.modelLoadingFraction = nil
            transcription.modelLoadingProgress = "Loading cached speech model…"
        case .downloadAlert:
            showModelDownloadConfirmation = true
        case .transcriptionError:
            transcription.modelErrorMessage = "The speech-model download stopped because the network became "
                + "unavailable or restricted. Connect to Wi-Fi or choose Use Cellular to retry."
        case .pairAlert, .keyChangeAlert:
            demoPairingRequest = PeerSyncPairingRequest(
                id: UUID(),
                displayName: "Studio Mac",
                fingerprint: "3F:A9:12:C7:5E:08:B4:D1",
                isKeyChange: scenario == .keyChangeAlert
            )
        case .storageError:
            dashboard.applyDemoPersistenceError()
        case .activityError:
            dashboardActivities.applyDemoActivitiesDisabledError()
        }
    }
    #endif

    private func sendDeviceStatus() {
        guard !demoMode else { return }
        syncService.send(.deviceStatus(localDeviceStatus))
    }
}

/// DEBUG-only fixture states for screenshot review. Honored only together
/// with `-demoMode YES` (`-demoScenario <name>`); release builds always see
/// `nil`, so their behavior is unchanged.
enum CopilotDemoScenario: String {
    case searching, noWorkspaces, disconnected
    case preparing, listening, recording, finishing, sent
    case modelLoading, modelLoadingCached
    case downloadAlert, transcriptionError, pairAlert, keyChangeAlert
    case storageError, activityError

    static var current: CopilotDemoScenario? {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "demoMode") else { return nil }
        return UserDefaults.standard.string(forKey: "demoScenario").flatMap(Self.init(rawValue:))
        #else
        return nil
        #endif
    }

    /// Demo mode normally fakes a connected Cockpit; these show the
    /// disconnected states instead.
    static var forcesDisconnected: Bool {
        current == .searching || current == .disconnected
    }

    /// Demo mode hides the walkie HUD unless a HUD fixture is selected.
    static var showsWalkieHUD: Bool {
        switch current {
        case .preparing, .listening, .recording, .finishing, .sent: true
        default: false
        }
    }
}

private struct SpeechModelStorageView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var transcription: TranscriptionService

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Model", value: SpeechModelCache.displayName)
                    LabeledContent("Download size", value: SpeechModelCache.downloadSize)
                    LabeledContent("Stored", value: transcription.cachedModelSize)
                    if transcription.isModelLoading {
                        // Designed loading state while the sheet covers the
                        // main screen's download banner (MOT-5).
                        HStack(spacing: LiquidGlassMetrics.Spacing.small) {
                            if let fraction = transcription.modelLoadingFraction {
                                ProgressView(value: fraction)
                                    .frame(width: 72)
                            } else {
                                ProgressView()
                            }
                            Text(transcription.modelLoadingProgress)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if transcription.hasStoredModel || transcription.isModelLoaded {
                        Button("Remove Download", role: .destructive) {
                            Task { await transcription.removeCachedModel() }
                        }
                        .disabled(transcription.isModelLoading)
                    } else {
                        Button("Download on Wi-Fi") {
                            Task { _ = await transcription.loadModel(allowRestrictedNetwork: false) }
                        }
                        Button("Use Cellular") {
                            Task { _ = await transcription.loadModel(allowRestrictedNetwork: true) }
                        }
                    }
                } header: {
                    Text("On-device Speech Model")
                } footer: {
                    Text("The model stays on this iPhone and transcription audio is processed on-device.")
                }
                Section("Model Credits") {
                    Text("Parakeet Ultra by Moondream, based on NVIDIA Parakeet v3. Core ML conversion and quantization by Fluid Inference.")
                    Link("Model and attribution", destination: URL(string: "https://huggingface.co/FluidInference/parakeet-ultra-coreml")!)
                    Link("CC BY 4.0 license", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
                }
            }
            .navigationTitle("Speech Storage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Tab switcher above the trackpad: the left half is "previous", the right
/// half is "next" (big tap targets), with the active tab's name floating in
/// the middle. Tracks Pilot's selection as state syncs back.
private struct TabSwitcherBar: View {
    let workspace: WorkspaceSummary?
    /// (workspaceID, tabID)
    let onSelectTab: (UUID, UUID) -> Void

    /// Same feel as volume up/down list navigation (VolumeObserver.tapHaptic).
    private let selectHaptic = UIImpactFeedbackGenerator(style: .medium)

    /// A capsule of this height has the trackpad's corner radius
    /// (height / 2 = 32) so the pair reads as one control group.
    private let barHeight: CGFloat = 64

    private var tabs: [TabSummary] { workspace?.tabs ?? [] }

    private var currentIndex: Int {
        if let id = workspace?.selectedTabID,
           let i = tabs.firstIndex(where: { $0.id == id }) {
            return i
        }
        return 0
    }

    private var current: TabSummary? {
        tabs.indices.contains(currentIndex) ? tabs[currentIndex] : tabs.first
    }

    var body: some View {
        ZStack {
            // Two full-height tap halves drive prev/next.
            HStack(spacing: 0) {
                half(title: "Previous Tab", systemImage: "chevron.left", delta: -1, alignment: .leading)
                half(title: "Next Tab", systemImage: "chevron.right", delta: 1, alignment: .trailing)
            }
            // Centered label sits on top but passes touches through to the
            // halves below.
            centerLabel
                .padding(.horizontal, 56)
                .allowsHitTesting(false)
        }
        .frame(height: barHeight)
        // The halves are full rectangles (every point of the bar stays a
        // tap target); clipping to the capsule makes each pressed wash
        // exactly one half of the glass shape (concentric by construction,
        // LAY-4).
        .clipShape(Capsule())
        // Floating control: interactive Liquid Glass capsule (height 64,
        // radius 32 — the trackpad's radius) sharing the trackpad's
        // horizontal insets so the two controls line up as a pair.
        .glassEffect(.regular.interactive(), in: Capsule())
        .padding(.horizontal, LiquidGlassMetrics.Spacing.medium)
        // A fixed-height control: past AX1 the tab name truncated to a few
        // letters ("Termi…"), so its text stops growing there (TYPE-4).
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    @ViewBuilder
    private var centerLabel: some View {
        if let current {
            HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                Image(systemName: current.systemImageName)
                    .font(.subheadline)
                Text(current.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
            }
        } else {
            // Regular weight (a tab title is semibold) but primary color:
            // secondary on the glass bar measured about 2.9:1 (TYPE-3).
            Text("No tabs")
                .font(.callout)
        }
    }

    @ViewBuilder
    private func half(title: LocalizedStringKey, systemImage: String, delta: Int, alignment: Alignment) -> some View {
        let target = currentIndex + delta
        let enabled = tabs.indices.contains(target)
        Button {
            guard let workspace, tabs.indices.contains(target) else { return }
            selectHaptic.impactOccurred()
            onSelectTab(workspace.id, tabs[target].id)
        } label: {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: alignment) {
                    Image(systemName: systemImage)
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, LiquidGlassMetrics.Spacing.xLarge)
                        // Monochrome on glass; tint is reserved for state (COL-4).
                        .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                }
        }
        // Each half is a segment of the glass capsule: a rectangular pressed
        // wash, clipped to the capsule by the bar, instead of a dead plain
        // style (BTN-5). A rounded wash here would also round the hit shape
        // and leave dead corners at the bar's center.
        .buttonStyle(.liquidGlassPressable(cornerRadius: 0))
        .disabled(!enabled)
        .accessibilityLabel(Text(title))
    }
}

#Preview {
    ContentView(
        syncService: PeerSyncService(role: .browser, displayName: "Preview"),
        watchDelegate: PhoneSessionDelegate(),
        dashboardActivities: DashboardActivityController(urlScheme: "walkie")
    )
}

/// Keeps the newest words visible without expanding the workspace list inset.
struct WalkieTranscriptView: View {
    let text: String
    let isRecording: Bool
    @ScaledMetric(relativeTo: .body) private var scaledTranscriptHeight = 96.0

    /// About four lines by default; at accessibility sizes it stops at
    /// 160pt (three lines at AX3) so the HUD never pushes the list and the
    /// trackpad off screen or slides under the toolbar.
    private var transcriptHeight: CGFloat { min(scaledTranscriptHeight, 160) }

    var body: some View {
        if isRecording {
            // A stable box while words stream in, so the HUD never jitters.
            scrollingTranscript
                .frame(height: transcriptHeight)
        } else {
            // A finished transcript takes only the height it needs, up to
            // the same cap, so a short result leaves no empty band between
            // it and Share (LAY-1); a long one scrolls.
            CappedHeightLayout(maxHeight: transcriptHeight) {
                scrollingTranscript
            }
        }
    }

    private var transcriptText: some View {
        VStack(alignment: .leading, spacing: 0) {
            if text.isEmpty && isRecording {
                // A glyph, not a dimmed color, marks the placeholder:
                // secondary text on the glass HUD measured 2.9:1 (TYPE-3).
                Label {
                    Text("Listening…")
                } icon: {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                }
            } else {
                Text(text)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("walkie.transcript")
            }
            Color.clear.frame(height: 1).id("transcriptEnd")
        }
        .font(.body)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var scrollingTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                transcriptText
            }
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.top, for: .alignment)
            // Earlier words scrolled past the top fade out over a 8pt band
            // instead of a half-clipped line butting against the status
            // above. The matching top margin keeps unscrolled text clear of
            // the fade.
            .contentMargins(.top, LiquidGlassMetrics.Spacing.xSmall, for: .scrollContent)
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: LiquidGlassMetrics.Spacing.xSmall)
                    Color.black
                }
            }
            // The fade band sits in the HUD's existing 8pt gap above, so
            // the status-to-transcript spacing stays 8pt (LAY-5).
            .padding(.top, -LiquidGlassMetrics.Spacing.xSmall)
            .onChange(of: text) {
                proxy.scrollTo("transcriptEnd", anchor: .bottom)
            }
        }
    }
}

/// Sizes its single child to the child's ideal height, capped at `maxHeight`
/// (a scroll view's ideal height is its content's), and fills the offered
/// width.
private struct CappedHeightLayout: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let ideal = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        let height = min(ideal.height, maxHeight, proposal.height ?? .infinity)
        return CGSize(width: proposal.width ?? ideal.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
