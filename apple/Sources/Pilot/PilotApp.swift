import AppKit
import Sparkle
import SwiftData
import SwiftUI

@main
struct PilotApp: App {
    #if BLAU_CHROMIUM_CEF_ENABLED
    @NSApplicationDelegateAdaptor(PilotAppDelegate.self) private var appDelegate
    #endif
    let modelContainer: ModelContainer
    /// Construct without starting so update UI cannot interrupt first-run
    /// setup. Starting after setup honors Sparkle's persisted preference.
    private let updaterController: SPUStandardUpdaterController

    @State private var setupProgress: SetupProgress
    @State private var didStartServices = false
    @AppStorage(SetupProgress.companionsKey) private var companionsEnabled = false
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
    #if DEBUG
    /// Review-only stand-ins for a peer's pairing prompt (`DemoReviewFixture`).
    @State private var demoWalkiePairing = DemoReviewFixture.walkiePairingRequest()
    @State private var demoPlotterPairing = DemoReviewFixture.plotterPairingRequest()
    #endif
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
    @State private var actionWatcher: WorkspaceActionWatcher
    @State private var usageStore: UsageStore
    @State private var agenticUseStore: AgenticUsageStore
    @State private var runnersStore: RunnersStore
    @State private var droneStore = DroneStore.shared
    @State private var dashboardPublisher: DashboardPublisher
    @State private var buildPush = BuildPushCoordinator()
    /// Auto-generated identity key, auto-exchanged with Copilot over the
    /// encrypted channel (issue #51).
    @State private var secureIdentity = SecureIdentity(role: .pilot)

    @AppStorage("ui.zoom") private var uiZoom: Double = UIZoomLadder.default

    init() {
        let isRunningTests = ProcessInfo.processInfo.environment.keys.contains("XCTestConfigurationFilePath")
        self._setupProgress = State(initialValue: SetupProgress(
            bypass: isRunningTests || UserDefaults.standard.bool(forKey: "demoMode")
        ))
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // Build the schema from the newest versioned schema so the store is
        // stamped with a version and `PilotMigrationPlan` governs upgrades.
        let schema = Schema(versionedSchema: PilotSchemaV3.self)
        let container: ModelContainer
        if isRunningTests {
            // A hosted unit-test launch must never open, back up, migrate, or
            // quarantine the developer's real Pilot store. It can also deadlock
            // behind a normally running Pilot process. Keep the test host fully
            // isolated and ephemeral.
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            container = try! ModelContainer(for: schema, configurations: configuration)
        } else {
            // Two live Pilot processes must never share the SwiftData store:
            // a second instance reading while the first checkpoints the WAL
            // fatals deep inside model getters (PersistentModel.getValue).
            // Finder launches are single-instance via LaunchServices, but
            // direct executable launches (Xcode debug runs, CLI) bypass that
            // — enforce it here, before the store is ever opened.
            Self.yieldToExistingInstanceIfNeeded()
            let storeURL = Self.persistentStoreURL()
            // Safety net: copy the on-disk store aside BEFORE opening it, so a failed
            // open or migration can never be the only thing standing between the user
            // and their workspaces/notes. Runs before `makeModelContainer` on purpose.
            Self.backUpStore(at: storeURL, fileManager: .default)
            let configuration = ModelConfiguration(schema: schema, url: storeURL)
            container = Self.makeModelContainer(
                schema: schema,
                migrationPlan: PilotMigrationPlan.self,
                configuration: configuration,
                storeURL: storeURL
            )
        }
        self.modelContainer = container
        let preferences = isRunningTests ? UserDefaults(suiteName: "app.blau.pilot.test-host")! : .standard
        let store = WorkspaceStore(
            modelContext: container.mainContext,
            workspaceGroups: WorkspaceGroups(defaults: preferences),
            defaults: preferences
        )
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
        let actionWatcher = WorkspaceActionWatcher()
        let usageStore = UsageStore(defaults: preferences)
        let agenticUseStore = AgenticUsageStore(defaults: preferences)
        let runnersStore = RunnersStore(defaults: preferences)
        let dashboardPublisher = DashboardPublisher(
            actionWatcher: actionWatcher,
            usageStore: usageStore,
            agenticUsageStore: agenticUseStore,
            runnersStore: runnersStore,
            defaults: preferences
        )
        self._actionWatcher = State(initialValue: actionWatcher)
        self._usageStore = State(initialValue: usageStore)
        self._agenticUseStore = State(initialValue: agenticUseStore)
        self._runnersStore = State(initialValue: runnersStore)
        self._dashboardPublisher = State(initialValue: dashboardPublisher)
        let sender = FrameSender()
        dashboardPublisher.onEnvelopeChange = { envelope in
            sender.send(.dashboard(envelope))
        }
        self._frameSender = State(initialValue: sender)
        let screenMirror = ScreenMirror(sender: sender)
        screenMirror.onClientConnected = { [weak dashboardPublisher] in
            dashboardPublisher?.republish()
        }
        self._screenMirror = State(initialValue: screenMirror)
    }

    /// If another Pilot process is already running, bring it forward and exit
    /// quietly instead of racing it for the store. Opt out for deliberate
    /// multi-instance development with the launch args
    /// `-allowMultipleInstances YES` (each instance then needs its own store
    /// via a distinct $HOME or it will still corrupt reads).
    private static func yieldToExistingInstanceIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "allowMultipleInstances") else { return }
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != currentPID && !$0.isTerminated }
        guard let existing else { return }
        existing.activate()
        exit(0)
    }

    /// Pilot runs unsandboxed (so Ghostty can launch real shell processes), so
    /// it owns `~/Library/Application Support` directly. Earlier builds wrote the
    /// SwiftData store into the *sandbox container* at
    /// `~/Library/Containers/app.blau.pilot/Data/…`; once unsandboxed, every
    /// access to that path makes macOS treat us as reaching into another app's
    /// data and throws a "would like to access data from other apps" prompt — on
    /// every launch, since the store reopens each time. Keep the store in
    /// Application Support instead, and migrate the old one over once so existing
    /// notes/workspaces carry across.
    private static func persistentStoreURL() -> URL {
        let fileManager = FileManager.default
        let appSupport = (try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let directory = appSupport.appendingPathComponent("Pilot", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent("default.store")

        migrateLegacyStoreIfNeeded(to: directory, storeURL: storeURL, fileManager: fileManager)
        return storeURL
    }

    /// One-time copy of the SwiftData store out of an older location, run only
    /// when the new store is absent.
    ///
    /// There are two legacy locations to rescue, because the store has moved
    /// twice:
    ///   1. `~/Library/Application Support/default.store` — the unsandboxed-era
    ///      store, written there by `ModelConfiguration` before the move into
    ///      the `Pilot/` subdirectory. This is where most existing users' data
    ///      actually lives, and missing it orphaned real workspaces/notes.
    ///   2. `~/Library/Containers/app.blau.pilot/.../default.store` — the
    ///      original sandbox-container store (pre-unsandboxing).
    /// Whichever exists and was modified most recently wins, so the freshest
    /// data is the one carried across.
    ///
    /// It *copies* (never moves) so a denied or failed migration leaves the
    /// legacy data intact and retryable rather than destroyed, and it commits the
    /// base `.store` LAST via an atomic same-volume rename: SQLite only ever sees
    /// the new store appear with its WAL/SHM sidecars already in place, never an
    /// orphan `-wal` next to an empty store (which it would read as a malformed
    /// image and crash on). Any failure rolls the partial copy back so the next
    /// launch retries from a clean slate.
    private static func migrateLegacyStoreIfNeeded(to directory: URL, storeURL: URL, fileManager: FileManager) {
        guard !fileManager.fileExists(atPath: storeURL.path) else { return }

        let stagedStore = directory.appendingPathComponent("default.store.import")
        let sidecars = ["-wal", "-shm"].map { directory.appendingPathComponent("default.store\($0)") }
        func rollback() {
            try? fileManager.removeItem(at: stagedStore)
            for sidecar in sidecars { try? fileManager.removeItem(at: sidecar) }
        }
        // The base store is absent, so any sidecars/staging present here are
        // orphans from a prior aborted run. Clear them up front — before the
        // legacy-present check below can early-return — so SQLite is never handed
        // a `-wal` next to a missing base (a "malformed image"), whatever happens
        // to the legacy source.
        rollback()

        // Candidate legacy stores. `directory` is `…/Application Support/Pilot`,
        // so its parent is the unsandboxed-era root location.
        let rootAppSupportStore = directory.deletingLastPathComponent()
            .appendingPathComponent("default.store")
        let sandboxStore = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Containers/app.blau.pilot/Data/Library/Application Support/default.store", isDirectory: true)

        func modificationDate(_ url: URL) -> Date {
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            return (attributes?[.modificationDate] as? Date) ?? .distantPast
        }
        let candidates = [rootAppSupportStore, sandboxStore]
            .filter { fileManager.fileExists(atPath: $0.path) }
        guard let legacyStore = candidates.max(by: { modificationDate($0) < modificationDate($1) }) else { return }
        let legacyDirectory = legacyStore.deletingLastPathComponent()

        do {
            // Copy the base to a staging name and the sidecars to their final
            // names; the base is committed last so it never appears half-built.
            try fileManager.copyItem(at: legacyStore, to: stagedStore)
            for suffix in ["-wal", "-shm"] {
                let source = legacyDirectory.appendingPathComponent("default.store\(suffix)")
                guard fileManager.fileExists(atPath: source.path) else { continue }
                try fileManager.copyItem(at: source, to: directory.appendingPathComponent("default.store\(suffix)"))
            }
            // Commit: the base store appears only now, with sidecars in place.
            try fileManager.moveItem(at: stagedStore, to: storeURL)
        } catch {
            rollback()
        }
    }

    /// Number of timestamped store backups to retain. Enough that a handful of
    /// rapid relaunches can't prune away the last known-good copy.
    private static let maxStoreBackups = 15

    /// Copy the on-disk store (base + WAL + SHM) into a timestamped folder under
    /// `Pilot/Backups/` before it is opened, then prune to `maxStoreBackups`.
    ///
    /// This is the data-loss backstop: notes and workspaces can only be lost if
    /// *every* copy is gone, and this guarantees a recent copy always survives an
    /// open or migration that goes wrong — independent of the corruption handler.
    /// It copies (never moves) and tolerates every failure silently: a backup is
    /// best-effort insurance and must never block the app from launching.
    private static func backUpStore(at storeURL: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: storeURL.path) else { return }
        let directory = storeURL.deletingLastPathComponent()
        let backupsRoot = directory.appendingPathComponent("Backups", isDirectory: true)

        // Skip if the newest backup already matches the current store (size +
        // mtime), so repeated launches with no changes don't churn the history.
        let currentSignature = storeSignature(storeURL, fileManager: fileManager)
        if let newest = (try? fileManager.contentsOfDirectory(at: backupsRoot, includingPropertiesForKeys: nil))?
            .filter({ (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
            .max(by: { $0.lastPathComponent < $1.lastPathComponent }),
           storeSignature(newest.appendingPathComponent("default.store"), fileManager: fileManager) == currentSignature {
            return
        }

        let stamp = Int(Date().timeIntervalSince1970)
        let destination = backupsRoot.appendingPathComponent(String(format: "%012d", stamp), isDirectory: true)
        guard (try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)) != nil else { return }
        for suffix in ["", "-wal", "-shm"] {
            let source = directory.appendingPathComponent("default.store\(suffix)")
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try? fileManager.copyItem(at: source, to: destination.appendingPathComponent("default.store\(suffix)"))
        }

        // Prune oldest backups beyond the retention count.
        if let backups = try? fileManager.contentsOfDirectory(at: backupsRoot, includingPropertiesForKeys: nil) {
            let sorted = backups
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if sorted.count > maxStoreBackups {
                for old in sorted.prefix(sorted.count - maxStoreBackups) {
                    try? fileManager.removeItem(at: old)
                }
            }
        }
    }

    /// Cheap content fingerprint (byte size + modification time) for the store
    /// base file, used to avoid making identical back-to-back backups.
    private static func storeSignature(_ url: URL, fileManager: FileManager) -> String? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attributes[.size] as? Int) ?? -1
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return "\(size)-\(modified)"
    }

    /// Open the store, but never let a corrupt/unreadable one crash every launch:
    /// on failure, quarantine the on-disk store aside and start fresh so the app
    /// still opens. The quarantined files are preserved for manual recovery, and
    /// `backUpStore` has already saved a copy aside before this runs.
    ///
    /// Quarantine names are unique per failure (timestamped). A fixed
    /// `default.store.corrupt` name was catastrophic: a *second* failed open
    /// would delete the first quarantine before writing its own, so two bad
    /// launches in a row (e.g. across two schema changes) destroyed the only
    /// surviving copy of the user's data. Never delete an existing quarantine.
    private static func makeModelContainer(
        schema: Schema,
        migrationPlan: (any SchemaMigrationPlan.Type)?,
        configuration: ModelConfiguration,
        storeURL: URL
    ) -> ModelContainer {
        do {
            return try ModelContainer(for: schema, migrationPlan: migrationPlan, configurations: configuration)
        } catch {
            let fileManager = FileManager.default
            let directory = storeURL.deletingLastPathComponent()
            let stamp = Int(Date().timeIntervalSince1970)
            for suffix in ["", "-wal", "-shm"] {
                let file = directory.appendingPathComponent("default.store\(suffix)")
                guard fileManager.fileExists(atPath: file.path) else { continue }
                // Find a quarantine name that does not already exist; never
                // overwrite a prior quarantine — it may be the last good copy.
                var quarantined = directory.appendingPathComponent("default.store\(suffix).\(stamp).corrupt")
                var bump = 1
                while fileManager.fileExists(atPath: quarantined.path) {
                    quarantined = directory.appendingPathComponent("default.store\(suffix).\(stamp)-\(bump).corrupt")
                    bump += 1
                }
                try? fileManager.moveItem(at: file, to: quarantined)
            }
            if let fresh = try? ModelContainer(for: schema, migrationPlan: migrationPlan, configurations: configuration) {
                return fresh
            }
            // Last resort when even a fresh on-disk store can't be created (disk
            // full, unwritable directory): an ephemeral in-memory store so the
            // app still opens this session instead of crash-looping every launch.
            return try! ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            )
        }
    }

    var body: some Scene {
        Window("Cockpit", id: PilotWindowID.main) {
            Group {
                if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                    // Hosted tests mount their own views. Do not start the live
                    // workspace, terminal, or account pollers behind those views.
                    Color.clear
                } else if setupProgress.needsInitialSetup {
                    SetupView(progress: setupProgress, updater: updaterController.updater) { directory in
                        if let directory { store.addWorkspace(directory: directory) }
                    }
                } else {
                    ContentView(
                        store: store,
                        syncService: syncService,
                        peerDeviceStatus: peerDeviceStatus,
                        localAudioOutput: headphoneDetector.audioOutput,
                        isPlotterConnected: plotterClientCount > 0,
                        remoteInkModel: remoteInkModel,
                        isPeerRecording: isPeerRecordingForDisplay,
                        usageStore: usageStore,
                        agenticUseStore: agenticUseStore,
                        runnersStore: runnersStore
                    )
                }
            }
                .environment(\.uiZoom, uiZoom)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .onOpenURL(perform: openDashboard)
                // Report Pilot's light/dark appearance to connected Plotters so
                // they can match it; fires on connect and whenever the Mac's
                // appearance changes.
                .background {
                    AppearanceReporter(isConnected: plotterClientCount > 0) { isDark in
                        frameSender.send(.appearance(isDark: isDark))
                    }
                }
                .onChange(of: uiZoom) { _, newValue in
                    GhosttyRuntime.shared.userZoomFactor = newValue
                }
                .task(id: setupProgress.needsInitialSetup) {
                    GhosttyRuntime.shared.userZoomFactor = uiZoom
                    // Skip services that prompt for permissions when XCTest is host-running us.
                    guard !setupProgress.needsInitialSetup, !didStartServices,
                          !UserDefaults.standard.bool(forKey: "demoMode"),
                          ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
                    didStartServices = true
                    try? updaterController.updater.start()
                    RepositoryPollingEnvironmentMonitor.shared.start()
                    headphoneDetector.start()
                    actionWatcher.start(store: store)
                    usageStore.start()
                    agenticUseStore.start()
                    runnersStore.start()
                    droneStore.start()
                    TerminalSessionProvider.shared.configure { [droneStore] droneID in
                        MainActor.assumeIsolated { droneStore.terminalClient(for: droneID) }
                    }
                    dashboardPublisher.start()
                    buildPush.onUpdate = { run in syncService.send(.buildRunUpdate(run)) }
                    if companionsEnabled { buildPush.restore() }
                    frameSender.onClientCountChanged = { clientCount in
                        Task { @MainActor in
                            guard companionsEnabled else { return }
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
                    if companionsEnabled {
                        setupSync()
                        frameSender.start()
                    }
                }
                .onChange(of: companionsEnabled) { _, enabled in
                    guard didStartServices else { return }
                    if enabled {
                        setupSync()
                        frameSender.start()
                    } else {
                        buildPush.stop()
                        syncService.stop()
                        frameSender.stop()
                        screenMirror.stop()
                        plotterClientCount = 0
                    }
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
                    walkiePairingPrompt?.isKeyChange == true
                        ? "Trust New Walkie Identity?"
                        : "Pair with Walkie?",
                    isPresented: Binding(
                        get: { walkiePairingPrompt != nil },
                        set: { if !$0 { resolveWalkiePairing(approved: false) } }
                    )
                ) {
                    Button("Reject", role: .cancel) {
                        resolveWalkiePairing(approved: false)
                    }
                    Button(walkiePairingPrompt?.isKeyChange == true ? "Trust New Key" : "Pair") {
                        resolveWalkiePairing(approved: true)
                    }
                } message: {
                    let request = walkiePairingPrompt
                    Text("Verify this fingerprint on \(request?.displayName ?? "the other device") before approving:\n\n\(request?.fingerprint ?? "")")
                }
                .alert(
                    plotterPairingPrompt?.isKeyChange == true
                        ? "Trust New Kneeboard Identity?"
                        : "Pair with Kneeboard?",
                    isPresented: Binding(
                        get: { plotterPairingPrompt != nil },
                        set: { if !$0 { resolvePlotterPairing(approved: false) } }
                    )
                ) {
                    Button("Reject", role: .cancel) {
                        resolvePlotterPairing(approved: false)
                    }
                    Button(plotterPairingPrompt?.isKeyChange == true ? "Trust New Key" : "Pair") {
                        resolvePlotterPairing(approved: true)
                    }
                } message: {
                    Text("Verify this fingerprint on Kneeboard before approving:\n\n\(plotterPairingPrompt?.fingerprint ?? "")")
                }
                #if DEBUG
                .background { DemoSecureMessagingOpener() }
                #endif
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
        // Setup uses a compact window; workspaces keep their roomier default.
        // Content bounds also keep a restored workspace frame from stretching setup.
        .defaultSize(
            width: setupProgress.needsInitialSetup ? SetupView.windowSize.width : 1440,
            height: setupProgress.needsInitialSetup ? SetupView.windowSize.height : 920
        )
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(PilotWindowLaunchPolicy.defaultBehavior(for: PilotWindowID.main))
        .commands {
            PilotWindowCommands()
            PilotCloseCommands()
            PilotPaneNavigationCommands()
            CommandGroup(after: .appInfo) {
                CheckForSoftwareUpdatesView(updater: updaterController.updater)
                OpenSetupButton().disabled(setupProgress.needsInitialSetup)
            }

            // New Terminal / New Browser as real main-menu commands. As toolbar
            // ControlGroup button shortcuts they were swallowed by a focused
            // WKWebView; menu key-equivalents take precedence over the web view.
            // They follow the key scene's focused Workspace so they work in the
            // Extension window too (see PilotPaneCreationCommands).
            PilotPaneCreationCommands()
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") {
                    sendStandardEditAction(#selector(NSText.cut(_:)))
                }
                .keyboardShortcut("x", modifiers: .command)

                Button("Copy") {
                    copyOrCaptureScreenshot()
                }
                .keyboardShortcut("c", modifiers: .command)

                Button("Paste") {
                    pasteIntoSelectedPane()
                }
                .keyboardShortcut("v", modifiers: .command)

                // Replacing `.pasteboard` drops the stock Select All too;
                // re-add it so ⌘A works in the notes editor and other fields.
                Button("Select All") {
                    sendStandardEditAction(#selector(NSText.selectAll(_:)))
                }
                .keyboardShortcut("a", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Button(store.selectedWorkspace?.isInspectorPresented == true ? "Hide Inspector" : "Show Inspector") {
                    guard let workspace = store.selectedWorkspace else { return }
                    workspace.setInspectorPresented(!workspace.isInspectorPresented)
                }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(store.selectedWorkspace == nil)

                Button(store.isNotesMode ? "Hide Notes" : "Show Notes") {
                    store.toggleNotesMode()
                }
                .keyboardShortcut("0", modifiers: .command)

                Button(store.isRemoteDesktopMode ? "Hide Remote Desktop" : "Show Remote Desktop") {
                    store.toggleRemoteDesktopMode()
                }
                .keyboardShortcut("0", modifiers: [.command, .shift])

                Button(store.isDockerMode ? "Hide Docker" : "Show Docker") {
                    store.toggleDockerMode()
                }
                .keyboardShortcut("0", modifiers: [.command, .control])

                Button(store.isRunnersMode ? "Hide Runners" : "Show Runners") { store.isRunnersMode.toggle() }
            }
            // Edit ▸ Find… / Find Next / Find Previous, and View ▸ Focus
            // Selected Pane, which shares ⌘F with Find (see the type).
            PilotBrowserFindCommands(store: store)
            CommandGroup(after: .toolbar) {
                Button("Increase Text Size") {
                    uiZoom = UIZoomLadder.next(after: uiZoom)
                }
                .keyboardShortcut("=", modifiers: .command)

                Button("Decrease Text Size") {
                    uiZoom = UIZoomLadder.previous(before: uiZoom)
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Actual Size") {
                    uiZoom = UIZoomLadder.default
                }
                .keyboardShortcut("0", modifiers: [.command, .option])
            }
            PilotBrowserCommands(isMobileDeviceConnected: syncService.isConnected)
        }

        Window(PilotWindowID.extendoTitle, id: PilotWindowID.extendo) {
            Group {
                if setupProgress.needsInitialSetup {
                    ContentUnavailableView("Setup Required", systemImage: "gearshape.2", description: Text(
                        "Finish setup in the main Cockpit window to open your workspaces."
                    ))
                    .legibleSecondaryHierarchy()
                    .padding(LiquidGlassMetrics.Spacing.xxLarge) // Designed empty state (MOT-6).
                } else {
                    ExtensionWindowView(
                        store: store,
                        controller: extensionWorkspaceController,
                        usageStore: usageStore
                    )
                }
            }
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

        #if DEBUG
        // Review-only: nothing in the app opens Secure Messaging yet, so a
        // demo launch with `-demoSecureMessaging YES` shows it in its own
        // window. Release builds compile none of this.
        Window("Secure Messaging", id: DemoReviewFixture.secureMessagingWindowID) {
            PilotSecureMessagingView()
        }
        .defaultLaunchBehavior(.suppressed)
        // Kept out of the Window menu: debug builds outside a review launch
        // should not offer an unfinished surface.
        .commandsRemoved()
        #endif

        Window("Set Up Cockpit", id: "setup") {
            SetupWindowView(progress: setupProgress, updater: updaterController.updater) { directory in
                if let directory { store.addWorkspace(directory: directory) }
            }
        }
        .defaultSize(width: SetupView.windowSize.width, height: SetupView.windowSize.height)
        .defaultLaunchBehavior(.suppressed)
        .windowResizability(.contentSize)

        // Standard macOS Settings window (⌘,). A thin, extensible shell; the
        // first real use is peer key sharing (#51), which drops into the
        // shared Identity & Keys section.
        Settings {
            PilotSettingsView(updater: updaterController.updater, droneStore: droneStore)
                .environment(secureIdentity)
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .windowResizability(.contentMinSize)
    }

    private var isPeerRecordingForDisplay: Bool {
        #if DEBUG
        if DemoReviewFixture.flag("demoPeerRecording") { return true }
        #endif
        return walkieInput.isRecording
    }

    // Demo prompts never reached the peer services (demo mode does not start
    // them), so resolving one only dismisses it and writes nothing.
    private var walkiePairingPrompt: PeerSyncPairingRequest? {
        #if DEBUG
        if let demoWalkiePairing { return demoWalkiePairing }
        #endif
        return syncService.pairingRequest
    }

    private var plotterPairingPrompt: FrameLinkPairingRequest? {
        #if DEBUG
        if let demoPlotterPairing { return demoPlotterPairing }
        #endif
        return plotterPairingRequest
    }

    private func resolveWalkiePairing(approved: Bool) {
        #if DEBUG
        if demoWalkiePairing != nil { demoWalkiePairing = nil; return }
        #endif
        syncService.resolvePairingRequest(approved: approved)
    }

    private func resolvePlotterPairing(approved: Bool) {
        #if DEBUG
        if demoPlotterPairing != nil { demoPlotterPairing = nil; return }
        #endif
        frameSender.resolvePairingRequest(approved: approved)
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

    private var selectedTerminalView: GhosttyMetalView? {
        guard let pane = store.selectedWorkspace?.selectedPane,
              pane.kind == .terminal else { return nil }
        return terminalView(for: pane.id)
    }

    private func copyOrCaptureScreenshot() {
        // If a text editor (sheet field, address bar, etc.) is the
        // first responder, let it handle the standard copy.
        if let responder = NSApp.keyWindow?.firstResponder,
           responder is NSText {
            sendStandardEditAction(#selector(NSText.copy(_:)))
            return
        }

        // In a device, Simulator, or Android pane: ⌘C grabs a screenshot to
        // the clipboard, and each session's `clipboardCopyCount` drives its
        // toast. The menu command owns ⌘C, so the panes never see the key.
        if let pane = store.selectedWorkspace?.selectedPane {
            switch pane.kind {
            case .device:
                DeviceCaptureRegistry.shared.session(for: pane.id).copyScreenshotToClipboard()
                return
            case .simulator:
                SimulatorRegistry.shared.session(for: pane.id).copyScreenshotToClipboard()
                return
            case .android:
                AndroidDeviceRegistry.shared.session(for: pane.id).copyScreenshotToClipboard()
                return
            case .terminal, .browser, .editor:
                break
            }
        }

        sendStandardEditAction(#selector(NSText.copy(_:)))
    }

    private func pasteIntoSelectedPane() {
        // If a text editor (sheet field, alert, address bar, etc.) is the
        // first responder, let it handle paste normally — otherwise the
        // terminal beneath the sheet would steal the keystroke.
        if let responder = NSApp.keyWindow?.firstResponder,
           responder is NSText {
            sendStandardEditAction(#selector(NSText.paste(_:)))
            return
        }

        // In an Android pane: ⌘V types the clipboard on the device. Must be
        // handled here — the menu command owns the key equivalent, so the
        // pane's host view never sees the keystroke.
        if let pane = store.selectedWorkspace?.selectedPane,
           pane.kind == .android {
            AndroidDeviceRegistry.shared.session(for: pane.id)
                .pasteFromClipboard()
            return
        }

        if let terminal = selectedTerminalView {
            terminal.paste(nil)
            return
        }

        sendStandardEditAction(#selector(NSText.paste(_:)))
    }

    private func sendStandardEditAction(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: nil)
    }

    private func setupSync() {
        guard !didSetupSync else {
            syncService.start()
            return
        }
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
            case .followBuild(let request):
                buildPush.follow(request, available: actionWatcher.recentRuns)
            case .unfollowBuild(let request):
                buildPush.stop(runKey: request.runKey)
            case .buildRunUpdate:
                break
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
            var runs: [BuildWorkflowRun]?
            var dashboard: DashboardSnapshotEnvelope?
        }
        let lastBroadcast = LastBroadcast()
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                guard syncService.isConnected else {
                    lastBroadcast.summaries = nil
                    lastBroadcast.selectedID = nil
                    lastBroadcast.runs = nil
                    lastBroadcast.dashboard = nil
                    return
                }
                let summaries = store.syncSummaries
                let selectedID = store.selectedSyncWorkspaceID
                let runs = actionWatcher.recentRuns
                let dashboard = dashboardPublisher.envelope
                guard summaries != lastBroadcast.summaries
                        || selectedID != lastBroadcast.selectedID
                        || runs != lastBroadcast.runs
                        || dashboard != lastBroadcast.dashboard else { return }
                lastBroadcast.summaries = summaries
                lastBroadcast.selectedID = selectedID
                lastBroadcast.runs = runs
                lastBroadcast.dashboard = dashboard
                let state = WorkspaceState(
                    workspaces: summaries,
                    selectedWorkspaceID: selectedID,
                    workflowRuns: runs,
                    actionsDashboard: dashboard.actions,
                    usageDashboard: dashboard.usage,
                    runnersDashboard: dashboard.runners
                )
                syncService.send(.workspaceState(state))
            }
        }
    }

    private func openDashboard(_ url: URL) {
        guard DashboardDeepLink.open(url, store: store) else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func sendLocalDeviceStatus() {
        let status = DeviceStatus(audioOutput: headphoneDetector.audioOutput)
        syncService.send(.deviceStatus(status))
    }
}
