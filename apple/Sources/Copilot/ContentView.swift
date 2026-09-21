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
    @State private var showModelDownloadConfirmation = false
    @State private var showSpeechStorage = false
    @AppStorage("transcription.allowRestrictedNetwork") private var allowRestrictedNetwork = false
    /// Auto-generated identity key, auto-exchanged with Pilot over the
    /// encrypted channel (issue #51). Drives the Settings "Identity & Keys".
    @State private var secureIdentity = SecureIdentity(role: .copilot)

    init(syncService: PeerSyncService, watchDelegate: PhoneSessionDelegate,
         demoMode: Bool = UserDefaults.standard.bool(forKey: "demoMode")) {
        self.syncService = syncService
        self.watchDelegate = watchDelegate
        self.demoMode = demoMode
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
        demoMode || syncService.isConnected
    }

    var body: some View {
        NavigationStack {
            mainContent
            .toolbar {
                deviceToolbar
            }
            .safeAreaInset(edge: .bottom) {
                trackpadInset
            }
            .safeAreaInset(edge: .top) {
                walkieStatus
            }
        }
        .environment(secureIdentity)
        .task {
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
            secureIdentity.refreshPeer()
            // Confirm the already-approved pin to the authenticated peer.
            secureIdentity.announce()
        }
        .onChange(of: scenePhase) {
            if scenePhase != .active { walkie.interrupt() }
        }
        .onDisappear { walkie.interrupt() }
        .overlay(alignment: .top) {
            if transcription.isModelLoading {
                HStack(spacing: 10) {
                    if let fraction = transcription.modelLoadingFraction {
                        ProgressView(value: fraction)
                            .frame(width: 70)
                    } else {
                        ProgressView()
                    }
                    Text(transcription.modelLoadingProgress)
                        .font(.footnote)
                    Spacer()
                    Button("Cancel") {
                        transcription.cancelModelLoad()
                        walkie.interrupt()
                    }
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding()
            }
        }
        .alert("Download Speech Model?", isPresented: $showModelDownloadConfirmation) {
            Button("Not Now", role: .cancel) {
            }
            Button("Download on Wi-Fi") {
                prepareSpeechModel(allowRestrictedNetwork: false)
            }
            Button("Use Cellular") {
                allowRestrictedNetwork = true
                prepareSpeechModel(allowRestrictedNetwork: true)
            }
        } message: {
            Text("On-device transcription requires an approximately 150 MB model. It is downloaded only once and cached on this iPhone. After it finishes, hold Volume Down again to record.")
        }
        .alert("Transcription unavailable", isPresented: Binding(
            get: { transcription.modelErrorMessage != nil },
            set: { if !$0 { transcription.modelErrorMessage = nil } }
        )) {
            Button("Retry") {
                transcription.modelErrorMessage = nil
                prepareSpeechModel(allowRestrictedNetwork: allowRestrictedNetwork)
            }
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
            syncService.pairingRequest?.isKeyChange == true
                ? "Trust New made Identity?"
                : "Pair with made?",
            isPresented: Binding(
                get: { syncService.pairingRequest != nil },
                set: { if !$0 { syncService.resolvePairingRequest(approved: false) } }
            )
        ) {
            Button("Reject", role: .cancel) {
                syncService.resolvePairingRequest(approved: false)
            }
            Button(syncService.pairingRequest?.isKeyChange == true ? "Trust New Key" : "Pair") {
                syncService.resolvePairingRequest(approved: true)
            }
        } message: {
            let request = syncService.pairingRequest
            Text("Verify this fingerprint on \(request?.displayName ?? "the other device") before approving:\n\n\(request?.fingerprint ?? "")")
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if !isPeerConnected && workspaces.isEmpty {
            ContentUnavailableView {
                Label("Looking for made...", systemImage: "antenna.radiowaves.left.and.right")
            } description: {
                Text("Make sure made is running on your Mac.")
            } actions: {
                ProgressView()
            }
        } else if workspaces.isEmpty {
            ContentUnavailableView(
                "No Workspaces",
                systemImage: "rectangle.on.rectangle.slash",
                description: Text("Create a workspace in made.")
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
        if !demoMode, walkie.phase != .idle || walkie.statusMessage != nil {
            VStack(alignment: .leading, spacing: 6) {
                switch walkie.phase {
                case .preparing:
                    Label("Preparing microphone…", systemImage: "mic")
                case .recording:
                    Label("Recording — release Volume Down to send", systemImage: "mic.fill")
                        .foregroundStyle(.red)
                case .finishing:
                    Label("Finishing transcription…", systemImage: "waveform")
                case .idle:
                    if let message = walkie.statusMessage { Text(message) }
                }
                if walkie.phase == .idle, !walkie.transcript.isEmpty {
                    Text(walkie.transcript)
                        .font(.caption)
                        .lineLimit(3)
                        .textSelection(.enabled)
                    ShareLink("Copy or Share Transcript", item: walkie.transcript)
                        .font(.caption)
                }
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.regularMaterial)
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
            if workspace.badgeCount > 0 {
                Text("\(workspace.badgeCount)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.red, in: Capsule())
            }
            Spacer()
        }
        .padding(.vertical, 4)
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
            Button {
                showSpeechStorage = true
            } label: {
                Image(systemName: "waveform.badge.magnifyingglass")
            }
            .accessibilityLabel("Speech Model Storage")
        }
        // Device connection status, top-right.
        ToolbarItemGroup(placement: .topBarTrailing) {
            ForEach(connectedDevices) { device in
                deviceIcon(device)
            }
        }
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
            VStack(spacing: 10) {
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
        secureIdentity.send = { syncService.send($0) }
        syncService.onReceive = { message in
            switch message {
            case .workspaceState(let state):
                workspaces = state.workspaces
                selectedID = selectionState.receive(state)
            case .deviceKey(let announce):
                secureIdentity.receive(announce)
            case .selectWorkspace, .selectTab, .deviceStatus, .mouseMove, .mouseClick,
                 .voiceRecord, .transcribedSpeech, .terminalInput, .executeTranscript:
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
    }

    private func sendDeviceStatus() {
        guard !demoMode else { return }
        syncService.send(.deviceStatus(localDeviceStatus))
    }
}

private struct SpeechModelStorageView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var transcription: TranscriptionService

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Model", value: "Whisper base")
                    LabeledContent("Download size", value: "About 150 MB")
                    LabeledContent("Stored", value: transcription.cachedModelSize)
                    if transcription.hasCachedModel || transcription.isModelLoaded {
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
                half(systemImage: "chevron.left", delta: -1, alignment: .leading)
                half(systemImage: "chevron.right", delta: 1, alignment: .trailing)
            }
            // Centered label sits on top but passes touches through to the
            // halves below.
            centerLabel
                .padding(.horizontal, 56)
                .allowsHitTesting(false)
        }
        .frame(height: 64)
        // Match the trackpad's material and horizontal insets so the
        // two controls line up as a pair.
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal)
    }

    @ViewBuilder
    private var centerLabel: some View {
        if let current {
            HStack(spacing: 6) {
                Image(systemName: current.systemImageName)
                    .font(.system(size: 15))
                Text(current.title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
            }
        } else {
            Text("No tabs")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func half(systemImage: String, delta: Int, alignment: Alignment) -> some View {
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
                        .font(.system(size: 17, weight: .semibold))
                        .padding(.horizontal, 22)
                        .foregroundStyle(enabled ? Color.accentColor : Color.secondary.opacity(0.4))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

#Preview {
    ContentView(syncService: PeerSyncService(role: .browser, displayName: "Preview"),
               watchDelegate: PhoneSessionDelegate())
}
