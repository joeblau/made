import AppKit
import Sparkle
import SwiftData
import SwiftUI

@main
struct PilotApp: App {
    let modelContainer: ModelContainer
    /// Sparkle's standard updater controller. Starting it here schedules the
    /// automatic background checks (per the user's Sparkle preference) and
    /// powers the Settings → General "Check for Updates…" button.
    private let updaterController: SPUStandardUpdaterController

    @State private var store: WorkspaceStore
    @State private var extensionWorkspaceController: ExtensionWorkspaceController
    @State private var peerDeviceStatus = DeviceStatus()
    @State private var headphoneDetector = HeadphoneDetector()
    @State private var syncService = PeerSyncService(
        role: .advertiser,
        displayName: Host.current().localizedName ?? "Mac"
    )
    /// High-bandwidth frame channel that live-mirrors Pilot's window to Plotter.
    @State private var frameSender = FrameSender()
    @State private var screenMirror: ScreenMirror
    @State private var plotterClientCount = 0
    @State private var plotterPairingRequest: FrameLinkPairingRequest?
    @State private var remoteInkModel = RemoteInkModel()
    @State private var walkieInput = PilotWalkieInputState()
    @State private var mainWindowID: CGWindowID?
    @State private var extensionWindowID: CGWindowID?
    /// `NSApp.keyWindow` is nil while Cockpit is in the background. Retain the
    /// last active Cockpit surface so Walkie still targets the window the user
    /// most recently worked in instead of falling back to Main.
    @State private var lastRemoteInputSurface: WorkspacePaneSurface = .main
    @State private var didSetupSync = false
    /// Badges background workspaces when their GitHub Actions complete.
    @State private var actionWatcher = WorkspaceActionWatcher()
    /// Auto-generated identity key, auto-exchanged with Copilot over the
    /// encrypted channel (issue #51).
    @State private var secureIdentity = SecureIdentity(role: .pilot)

    @AppStorage("ui.zoom") private var uiZoom: Double = UIZoomLadder.default

    init() {
        let isRunningTests = ProcessInfo.processInfo.environment.keys.contains("XCTestConfigurationFilePath")
        updaterController = SPUStandardUpdaterController(
            startingUpdater: !isRunningTests,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // Single-instance enforcement, legacy-store rescue, and the pre-open
        // backup all run inside `PilotPersistentStore` before the store opens.
        let container = PilotPersistentStore.makeContainer(isRunningTests: isRunningTests)
        self.modelContainer = container
        let store = WorkspaceStore(modelContext: container.mainContext)
        // Demo mode (screenshots/UITests): launch arg pair ["-demoMode", "YES"]
        // sets the "demoMode" UserDefaults bool. When on, seed representative
        // workspaces so the sidebar/layout looks intentional with no live peer.
        // Guarded so a normal launch (no arg) is completely unchanged — the
        // seed is also a no-op whenever real workspaces already exist.
        if UserDefaults.standard.bool(forKey: "demoMode") {
            store.seedDemoWorkspacesIfNeeded()
        }
        self._store = State(initialValue: store)
        self._extensionWorkspaceController = State(
            initialValue: ExtensionWorkspaceController(
                modelContext: container.mainContext,
                onMembershipChange: { store.extensionWorkspaceMembershipDidChange() }
            )
        )
        let sender = FrameSender()
        self._frameSender = State(initialValue: sender)
        self._screenMirror = State(initialValue: ScreenMirror(sender: sender))
    }

    var body: some Scene {
        Window("Cockpit", id: PilotWindowID.main) {
            ContentView(
                store: store,
                syncService: syncService,
                peerDeviceStatus: peerDeviceStatus,
                localAudioOutput: headphoneDetector.audioOutput,
                isPlotterConnected: plotterClientCount > 0,
                remoteInkModel: remoteInkModel,
                isPeerRecording: walkieInput.isRecording
            )
                .environment(\.uiZoom, uiZoom)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                // Report Pilot's light/dark appearance to connected Plotters so
                // they can match it; fires on connect and whenever the Mac's
                // appearance changes.
                .background {
                    PilotAppearanceReporter(isConnected: plotterClientCount > 0) { isDark in
                        frameSender.send(.appearance(isDark: isDark))
                    }
                }
                .onChange(of: uiZoom) { _, newValue in
                    GhosttyRuntime.shared.userZoomFactor = newValue
                }
                .task {
                    GhosttyRuntime.shared.userZoomFactor = uiZoom
                    // Skip services that prompt for permissions when XCTest is host-running us.
                    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
                    RepositoryPollingEnvironmentMonitor.shared.start()
                    _ = MouseBridge.shared.ensurePermissions()
                    headphoneDetector.start()
                    setupSync()
                    actionWatcher.start(store: store)
                    frameSender.onClientCountChanged = { clientCount in
                        Task { @MainActor in
                            let wasConnected = plotterClientCount > 0
                            plotterClientCount = clientCount
                            // Only capture the screen — which lights up the macOS
                            // "your screen is being shared" indicator — while a
                            // Plotter is actually connected. Start on the first
                            // client, stop when the last one disconnects.
                            if clientCount > 0 && !wasConnected {
                                screenMirror.start()
                            } else if clientCount == 0 && wasConnected {
                                screenMirror.stop()
                            }
                        }
                    }
                    frameSender.onPairingRequestChanged = { request in
                        Task { @MainActor in
                            plotterPairingRequest = request
                        }
                    }
                    frameSender.onAnnotationMessage = { seq, message in
                        Task { @MainActor in
                            remoteInkModel.handle(message)
                            // Confirm acceptance so Plotter can stop drawing
                            // its now-redundant local copy and defer to the
                            // mirrored render.
                            frameSender.sendAnnotationAck(seq)
                        }
                    }
                    // Undo/clear performed on Pilot are forwarded to the iPad,
                    // which owns the authoritative PencilKit drawing and echoes
                    // the corrected drawing back via onAnnotationMessage.
                    remoteInkModel.onLocalEdit = { message in
                        frameSender.sendAnnotation(message)
                    }
                    // Advertise the frame channel immediately so a Plotter can
                    // discover and connect, but DON'T start screen capture yet —
                    // capture begins on the first connected client (see
                    // onClientCountChanged) so the macOS screen-sharing indicator
                    // isn't lit whenever Pilot is merely running.
                    frameSender.start()
                }
                .onChange(of: headphoneDetector.audioOutput) {
                    sendLocalDeviceStatus()
                }
                .onChange(of: syncService.isConnected) {
                    guard syncService.isConnected else {
                        walkieInput.reset()
                        return
                    }
                    sendLocalDeviceStatus()
                    secureIdentity.refreshPeer()
                    // Confirm the already-approved pin to the authenticated peer.
                    secureIdentity.announce()
                }
                .alert(
                    syncService.pairingRequest?.isKeyChange == true
                        ? "Trust New Walkie Identity?"
                        : "Pair with Walkie?",
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
                .alert(
                    plotterPairingRequest?.isKeyChange == true
                        ? "Trust New Kneeboard Identity?"
                        : "Pair with Kneeboard?",
                    isPresented: Binding(
                        get: { plotterPairingRequest != nil },
                        set: { if !$0 { frameSender.resolvePairingRequest(approved: false) } }
                    )
                ) {
                    Button("Reject", role: .cancel) {
                        frameSender.resolvePairingRequest(approved: false)
                    }
                    Button(plotterPairingRequest?.isKeyChange == true ? "Trust New Key" : "Pair") {
                        frameSender.resolvePairingRequest(approved: true)
                    }
                } message: {
                    Text("Verify this fingerprint on Kneeboard before approving:\n\n\(plotterPairingRequest?.fingerprint ?? "")")
                }
                .environment(secureIdentity)
                .background {
                    PilotWindowReader(
                        onWindowChange: { windowID in
                            mainWindowID = windowID
                            screenMirror.setMainWindowID(windowID)
                        },
                        onWindowActivate: {
                            lastRemoteInputSurface = .main
                        }
                    )
                }
                .onReceive(NotificationCenter.default.publisher(for: .pilotSendIssuePrompt)) { note in
                    // Issues inspector / Browser Annotate → paste a prompt into
                    // the intended terminal and submit it so the agent starts
                    // working on the task. Browser Annotate captures a concrete
                    // pane before its async snapshot; legacy issue notifications
                    // without routing metadata retain active-terminal behavior.
                    guard let prompt = note.userInfo?[BrowserAnnotate.promptUserInfoKey] as? String else { return }
                    let terminal: GhosttyMetalView?
                    if BrowserAnnotate.hasCapturedTarget(in: note.userInfo) {
                        terminal = terminalView(for: BrowserAnnotate.targetPaneID(in: note.userInfo))
                    } else {
                        terminal = activeTerminalView()
                    }
                    guard let terminal else {
                        // No terminal to receive it — beep rather than silently
                        // swallowing the request the user just dispatched.
                        NSSound.beep()
                        return
                    }
                    terminal.pasteText(prompt)
                    terminal.sendEnter()
                }
        }
        .modelContainer(modelContainer)
        // A roomier default for the sidebar + panes + inspector layout. Only
        // applies to a fresh window; a restored window keeps its saved frame.
        .defaultSize(width: 1440, height: 920)
        .defaultLaunchBehavior(PilotWindowLaunchPolicy.defaultBehavior(for: PilotWindowID.main))
        .commands {
            PilotWindowCommands()
            PilotCloseCommands()
            PilotPaneNavigationCommands()
            PilotSoftwareUpdateCommands(updater: updaterController.updater)

            // New Terminal / New Browser as real main-menu commands. As toolbar
            // ControlGroup button shortcuts they were swallowed by a focused
            // WKWebView; menu key-equivalents take precedence over the web view.
            // They follow the key scene's focused Workspace so they work in the
            // Extension window too (see PilotPaneCreationCommands).
            PilotPaneCreationCommands()
            PilotPasteboardCommands(store: store)
            PilotViewCommands(store: store)
            PilotTextSizeCommands(uiZoom: $uiZoom)
            PilotBrowserCommands(isMobileDeviceConnected: syncService.isConnected)
        }

        Window(PilotWindowID.extendoTitle, id: PilotWindowID.extendo) {
            ExtensionWindowView(store: store, controller: extensionWorkspaceController)
                .environment(\.uiZoom, uiZoom)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .background {
                    PilotWindowReader(
                        onWindowChange: { windowID in
                            extensionWindowID = windowID
                            if windowID == nil, lastRemoteInputSurface == .extension {
                                lastRemoteInputSurface = .main
                            }
                        },
                        onWindowActivate: {
                            lastRemoteInputSurface = .extension
                        }
                    )
                }
        }
        .modelContainer(modelContainer)
        .defaultSize(width: 820, height: 760)
        .defaultLaunchBehavior(PilotWindowLaunchPolicy.defaultBehavior(for: PilotWindowID.extendo))
        .commands {
            // PilotWindowCommands is registered on the main scene only —
            // scene commands merge into one menu bar, and registering them
            // here too duplicated the Window-menu entries.
            PilotExtensionWorkspaceCommands(store: store)
        }

        // Standard macOS Settings window (⌘,). A thin, extensible shell; the
        // first real use is peer key sharing (#51), which drops into the
        // shared Identity & Keys section.
        Settings {
            PilotSettingsView(updater: updaterController.updater)
                .environment(secureIdentity)
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .windowResizability(.contentMinSize)
    }

    private func remoteInputSurface() -> WorkspacePaneSurface {
        // A sheet or Settings can be key while its parent workspace window is
        // still AppKit's main window, so consult both while Cockpit is active.
        // Once the phone takes focus, rely on activation events remembered by
        // `PilotWindowReader`; AppKit may no longer expose a key window.
        var activeWindows = [NSApp.keyWindow].compactMap { $0 }
        if NSApp.isActive, let mainWindow = NSApp.mainWindow {
            activeWindows.append(mainWindow)
        }
        for window in activeWindows {
            let windowID = CGWindowID(window.windowNumber)
            if let surface = PilotRemoteInputRoutingPolicy.surface(
                activeWindowID: windowID,
                mainWindowID: mainWindowID,
                extensionWindowID: extensionWindowID
            ) {
                lastRemoteInputSurface = surface
                return surface
            }
        }
        return lastRemoteInputSurface
    }

    private func activeTerminalPane(
        in workspaceID: UUID?,
        on surface: WorkspacePaneSurface
    ) -> Pane? {
        guard let workspaceID,
              let mainWorkspace = store.workspaces.first(where: { $0.id == workspaceID }) else {
            return nil
        }

        var extensionWorkspace: Workspace?
        if surface == .extension {
            if extensionWorkspaceController.selectedSourceID != workspaceID
                || extensionWorkspaceController.workspace(forSourceID: workspaceID) == nil {
                // Keep Extendo's companion selection in lockstep before capturing
                // the target. Its SwiftUI `.task(id:)` would otherwise update one
                // run-loop later and speech could land in the previous project.
                extensionWorkspaceController.synchronize(with: mainWorkspace)
            }
            extensionWorkspace = extensionWorkspaceController.workspace(forSourceID: workspaceID)
        }

        return PilotRemoteInputRoutingPolicy.terminalPane(
            on: surface,
            mainWorkspace: mainWorkspace,
            extensionWorkspace: extensionWorkspace
        )
    }

    private func terminalView(for paneID: UUID?) -> GhosttyMetalView? {
        guard let paneID else { return nil }
        return GhosttyMetalView.view(for: paneID)
    }

    private func activeTerminalView() -> GhosttyMetalView? {
        let surface = remoteInputSurface()
        return terminalView(for: activeTerminalPane(
            in: store.selectedWorkspaceID,
            on: surface
        )?.id)
    }

    private var walkieDelivery: PilotWalkieDelivery {
        PilotWalkieDelivery(store: store, terminalPaneID: { workspaceID in
            activeTerminalPane(in: workspaceID, on: remoteInputSurface())?.id
        })
    }

    private func selectRemoteWorkspace(_ workspaceID: UUID, on surface: WorkspacePaneSurface) {
        if workspaceID == WorkspaceStore.remoteDesktopWorkspaceID {
            store.enterRemoteDesktopMode()
            return
        }
        store.selectWorkspace(workspaceID)
        guard let terminalPane = activeTerminalPane(in: workspaceID, on: surface) else { return }
        terminalPane.workspace?.selectedPaneID = terminalPane.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Rapid volume taps can select another workspace before SwiftUI
            // installs this view. An older delayed focus must not undo them.
            guard store.selectedWorkspaceID == workspaceID,
                  terminalPane.workspace?.selectedPaneID == terminalPane.id,
                  remoteInputSurface() == surface else { return }
            _ = GhosttyMetalView.focus(paneID: terminalPane.id)
        }
    }

    private func setupSync() {
        guard !didSetupSync else { return }
        didSetupSync = true

        secureIdentity.send = { syncService.send($0) }
        syncService.onReceive = { (message: SyncMessage) in
            switch message {
            case .selectWorkspace(let sel):
                // Workspace selection follows the active Cockpit window.
                selectRemoteWorkspace(sel.workspaceID, on: remoteInputSurface())
            case .selectTab(let sel):
                if sel.workspaceID == WorkspaceStore.remoteDesktopWorkspaceID {
                    _ = store.selectRemoteDesktopTab(sel.tabID)
                    return
                }
                // Focus the workspace and tab selected on Copilot.
                store.selectWorkspace(sel.workspaceID)
                if let workspace = store.workspaces.first(where: { $0.id == sel.workspaceID }),
                   workspace.panes.contains(where: { $0.id == sel.tabID }) {
                    workspace.selectedPaneID = sel.tabID
                    // Ghostty focus is a no-op for browser/device panes.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        guard store.selectedWorkspaceID == sel.workspaceID,
                              workspace.selectedPaneID == sel.tabID else { return }
                        _ = GhosttyMetalView.focus(paneID: sel.tabID)
                    }
                }
            case .workspaceState:
                break
            case .deviceStatus(let status):
                peerDeviceStatus = status
            case .mouseMove(let m):
                MouseBridge.shared.move(dx: m.dx, dy: m.dy)
            case .mouseClick:
                MouseBridge.shared.click()
            case .voiceRecord(let command):
                switch command.control {
                case .start:
                    walkieDelivery.start(command, state: &walkieInput)
                case .stop:
                    walkieInput.stop(recordingID: command.recordingID, workspaceID: command.workspaceID)
                }
            case .transcribedSpeech(let speech):
                if !walkieDelivery.receive(speech, state: &walkieInput), !speech.text.isEmpty {
                    NSSound.beep()
                }
            case .executeTranscript(let command):
                walkieDelivery.execute(command, state: &walkieInput)
            case .terminalInput(.enter):
                walkieDelivery.enterSelection()
            case .deviceKey(let announce):
                // Auto-exchange device keys with Copilot (issue #51).
                secureIdentity.receive(announce)
            }
        }
        syncService.start()

        // Re-broadcast workspace state only when it actually changed; the 1s
        // tick otherwise encoded + sent an identical payload to Copilot every
        // second for the whole session. Reset on disconnect so a reconnecting
        // peer always gets a fresh snapshot.
        @MainActor final class LastBroadcast {
            var summaries: [WorkspaceSummary]?
            var selectedID: UUID?
        }
        let lastBroadcast = LastBroadcast()
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                guard syncService.isConnected else {
                    lastBroadcast.summaries = nil
                    return
                }
                let summaries = store.syncSummaries
                let selectedID = store.selectedSyncWorkspaceID
                guard summaries != lastBroadcast.summaries
                        || selectedID != lastBroadcast.selectedID else { return }
                lastBroadcast.summaries = summaries
                lastBroadcast.selectedID = selectedID
                let state = WorkspaceState(
                    workspaces: summaries,
                    selectedWorkspaceID: selectedID
                )
                syncService.send(.workspaceState(state), reliable: false)
            }
        }
    }

    private func sendLocalDeviceStatus() {
        let status = DeviceStatus(audioOutput: headphoneDetector.audioOutput)
        syncService.send(.deviceStatus(status))
    }
}
