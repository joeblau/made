import AppKit
import Sparkle
import SwiftData
import SwiftUI

/// Scene-local browser selection used by menu commands. Revealing a browser
/// preserves focused-pane mode by moving that focus to the browser instead of
/// leaving `focusedPaneID` attached to a hidden pane.
@MainActor
enum BrowserCommandSelection {
    static func selectedState(
        in workspace: Workspace?,
        supporting capability: BrowserCapability? = nil
    ) -> BrowserState? {
        guard let state = BrowserToolbarSelection.state(for: workspace?.selectedPane) else {
            return nil
        }
        if let capability, !state.supports(capability) {
            return nil
        }
        return state
    }

    static func hasBrowser(
        in workspace: Workspace?,
        supporting capability: BrowserCapability? = nil
    ) -> Bool {
        workspace?.panes.contains { pane in
            guard pane.kind == .browser,
                  let state = pane.browserState else { return false }
            return capability.map(state.supports) ?? true
        } ?? false
    }

    @discardableResult
    static func revealBrowser(
        in workspace: Workspace?,
        supporting capability: BrowserCapability? = nil
    ) -> BrowserState? {
        guard let workspace else { return nil }

        func isEligible(_ pane: Pane) -> Bool {
            guard pane.kind == .browser,
                  let state = pane.browserState else { return false }
            return capability.map(state.supports) ?? true
        }

        let browser: Pane
        if let selectedPane = workspace.selectedPane,
           isEligible(selectedPane) {
            browser = selectedPane
        } else if let firstBrowser = workspace.sortedPanes.first(where: isEligible) {
            browser = firstBrowser
        } else {
            return nil
        }

        if let focusedPaneID = workspace.focusedPaneID,
           focusedPaneID != browser.id {
            workspace.focusPane(browser)
        } else {
            workspace.expandPane(browser)
            workspace.selectedPaneID = browser.id
        }
        return BrowserToolbarSelection.state(for: browser)
    }
}

/// Browser menu commands follow the key scene's focused Workspace. Main and
/// Extension publish their own workspace with `focusedSceneValue`, preventing
/// shortcuts in one window from reloading, annotating, or selecting a browser
/// in the other.
struct PilotBrowserCommands: Commands {
    @FocusedValue(Workspace.self) private var workspace
    let isMobileDeviceConnected: Bool

    var body: some Commands {
        CommandMenu("Browser") {
            Button(primaryCommandTitle) {
                if let selectedReloadableBrowserState {
                    selectedReloadableBrowserState.perform(.reload)
                } else if let selectedTerminalFastCommand {
                    Task {
                        _ = await PersistentTerminalSession.runFastCommand(
                            selectedTerminalFastCommand.command,
                            sessionName: selectedTerminalFastCommand.pane.persistentSessionName
                        )
                    }
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(selectedReloadableBrowserState == nil && selectedTerminalFastCommand == nil)

            Button("Focus Address Bar") {
                BrowserCommandSelection.revealBrowser(
                    in: workspace,
                    supporting: .addressFocus
                )?.perform(.focusAddress)
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(!hasBrowserPane)

            Button(selectedAnnotatableBrowserState?.annotateMode == true ? "Turn Off Lasso" : "Turn On Lasso") {
                selectedAnnotatableBrowserState?.perform(.toggleAnnotation)
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(selectedAnnotatableBrowserState == nil)

            Divider()

            Button("Debug Mobile App in Browser") {
                SafariWebInspector.open()
            }
            .keyboardShortcut("d", modifiers: [.command, .option])
            .disabled(!isMobileDeviceConnected)
        }
    }

    private var selectedReloadableBrowserState: BrowserState? {
        BrowserCommandSelection.selectedState(in: workspace, supporting: .navigation)
    }

    private var selectedAnnotatableBrowserState: BrowserState? {
        BrowserCommandSelection.selectedState(in: workspace, supporting: .annotation)
    }

    private var selectedTerminalFastCommand: (pane: Pane, command: String)? {
        guard let pane = TerminalToolbarSelection.pane(for: workspace?.selectedPane),
              let command = TerminalFastCommandStore.executableCommand(
                  from: TerminalFastCommandStore.command(for: pane.id)
              ) else {
            return nil
        }
        return (pane, command)
    }

    private var primaryCommandTitle: String {
        selectedTerminalFastCommand == nil ? "Reload" : "Run Fast Command"
    }

    private var hasBrowserPane: Bool {
        BrowserCommandSelection.hasBrowser(in: workspace, supporting: .addressFocus)
    }
}

/// New Terminal / New Browser follow the key scene's focused Workspace, so the
/// shortcut adds a pane to whichever window — main or Extension — is key. They
/// previously targeted `store.selectedWorkspace` (always the main window), so
/// pressing ⌘T/⌘B while the Extension window was key added a hidden pane to the
/// main workspace and looked broken. Main and Extension publish their workspace
/// with `focusedSceneValue`; a nil value (notes/remote-desktop mode, or no
/// selection) disables the commands.
struct PilotPaneCreationCommands: Commands {
    @FocusedValue(Workspace.self) private var workspace
    @ObservedObject private var chromiumDiagnostics = ChromiumDiagnosticsCenter.shared
    @ObservedObject private var chromiumProfileAccess =
        ChromiumProfileAccessCoordinator.shared

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Terminal") {
                workspace?.addPane(kind: .terminal, side: .right)
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(workspace == nil)

            Button("New Browser") {
                workspace?.addBrowserPane(engine: .webKit, side: .right)
            }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(workspace == nil)

            Button("New Chromium Browser") {
                workspace?.addBrowserPane(engine: .chromium, side: .right)
            }
            .disabled(
                workspace == nil
                    || !chromiumCreationEnabled
            )
        }
    }

    private var chromiumCreationEnabled: Bool {
        _ = chromiumDiagnostics.runtimeStatus
        _ = chromiumProfileAccess.isClearing
        return BrowserPaneCreationPolicy.permitsCreation(
            for: .chromium,
            chromiumCreationEnabled:
                ChromiumBrowserCreationPolicy.isCreationEnabled
        )
    }
}

/// Pane navigation follows the key window's workspace, including Extendo.
/// Menu commands also remain reachable when a terminal or browser has focus.
struct PilotPaneNavigationCommands: Commands {
    @FocusedValue(Workspace.self) private var workspace

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Previous Panel") {
                workspace?.selectPreviousPane()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled((workspace?.panes.count ?? 0) < 2)

            Button("Next Panel") {
                workspace?.selectNextPane()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled((workspace?.panes.count ?? 0) < 2)
        }
    }
}

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
    /// `NSApp.keyWindow` is nil while made is in the background. Retain the
    /// last active made surface so Walkie still targets the window the user
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
        Window("made", id: PilotWindowID.main) {
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
                    AppearanceReporter(isConnected: plotterClientCount > 0) { isDark in
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
            CommandGroup(after: .appInfo) {
                CheckForSoftwareUpdatesView(updater: updaterController.updater)
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

                Button("Focus Selected Pane") {
                    guard let workspace = store.selectedWorkspace,
                          let pane = workspace.selectedPane else { return }
                    workspace.focusPane(pane)
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(store.selectedWorkspace?.selectedPane == nil)
            }
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
        // still AppKit's main window, so consult both while made is active.
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

        // In a device pane: ⌘C grabs a screenshot to the clipboard. The
        // session's `clipboardCopyCount` increment drives the toast.
        if let pane = store.selectedWorkspace?.selectedPane,
           pane.kind == .device {
            DeviceCaptureRegistry.shared.session(for: pane.id)
                .copyScreenshotToClipboard()
            return
        }

        if let pane = store.selectedWorkspace?.selectedPane,
           pane.kind == .android {
            AndroidDeviceRegistry.shared.session(for: pane.id)
                .copyScreenshotToClipboard()
            return
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
        guard !didSetupSync else { return }
        didSetupSync = true

        secureIdentity.send = { syncService.send($0) }
        syncService.onReceive = { (message: SyncMessage) in
            switch message {
            case .selectWorkspace(let sel):
                // Workspace selection follows the active made window.
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

/// Invisible helper that observes Pilot's effective light/dark appearance and
/// reports it to connected Plotters. Sends on first connect (via the
/// `isConnected` transition) and whenever the Mac's appearance changes, so a
/// connected Plotter mirrors Pilot's mode rather than its own.
private struct AppearanceReporter: View {
    @Environment(\.colorScheme) private var colorScheme
    let isConnected: Bool
    let send: (Bool) -> Void

    var body: some View {
        Color.clear
            .onChange(of: colorScheme) { _, scheme in
                if isConnected { send(scheme == .dark) }
            }
            .onChange(of: isConnected) { _, connected in
                if connected { send(colorScheme == .dark) }
            }
    }
}

/// Pilot's Settings window contents (⌘,). A source-list shell — sections on the
/// left, detail on the right — matching the modern macOS/Xcode settings layout.
/// "General" reuses the shared `SettingsSections` (Identity & Keys + About);
/// "Usage" connects the AI usage APIs. The selected section is backed by
/// `AppStorage` so the inspector's Usage empty-state can deep-link straight here.
private struct PilotSettingsView: View {
    @AppStorage(SettingsTab.storageKey) private var selectedTab = SettingsTab.general
    @State private var searchText = ""

    let updater: SPUUpdater

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                Divider()

                List(selection: sidebarSelection) {
                    if matchesSearch("General identity keys about version updates") {
                        Label("General", systemImage: "gearshape")
                            .tag(SettingsTab.general)
                    }
                    if matchesSearch("Usage Claude Codex Kimi Grok") {
                        Label("Usage", systemImage: "chart.bar.xaxis")
                            .tag(SettingsTab.usage)
                    }
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, idealWidth: 920, minHeight: 520, idealHeight: 680)
    }

    /// Bridges the non-optional `AppStorage` string to `List`'s optional selection.
    private var sidebarSelection: Binding<String?> {
        Binding(get: { selectedTab }, set: { selectedTab = $0 ?? SettingsTab.general })
    }

    private func matchesSearch(_ terms: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || terms.localizedCaseInsensitiveContains(query)
    }

    @ViewBuilder
    private var detail: some View {
        switch selectedTab {
        case SettingsTab.usage:
            UsageSettingsView(showsPageHeader: true)
                .formStyle(.grouped)
        default:
            Form {
                PilotSettingsPageHeader(
                    title: "General",
                    subtitle: "Manage made identity, pairing, and app information.",
                    systemImage: "gearshape.fill",
                    tint: .blue
                )
                Section("Updates") {
                    Button("Check for Updates…") {
                        updater.checkForUpdates()
                    }
                }
                SettingsSections()
                ChromiumDiagnosticsSettingsSection()
            }
            .formStyle(.grouped)
        }
    }
}

struct PilotSettingsPageHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 68, height: 68)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))

            Text(title)
                .font(.system(size: 26, weight: .bold))

            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }
}

// MARK: - Versioned schema & migration plan

/// Versioned schema + migration plan for Pilot's local SwiftData store.
///
/// Declaring an explicit version and plan makes app upgrades migrate the store
/// deterministically instead of failing to open (which previously caused the
/// corruption handler to quarantine — and once, destroy — real user data).
///
/// SwiftData handles *additive* changes (a new `@Model`, or a new stored
/// property that has a default value) automatically as a lightweight migration.
/// *Non-additive* changes (renaming a property, changing a type, changing a
/// uniqueness constraint or relationship) are NOT automatic and must be given an
/// explicit `MigrationStage` here, or the store will fail to open on upgrade.
///
/// To evolve the schema safely:
///   1. Copy the current models' shape into a new `PilotSchemaV2` enum
///      (snapshot — do not just point at the live types if they changed).
///   2. Append `PilotSchemaV2.self` to `schemas` (newest last).
///   3. Add a `MigrationStage` from V1 to V2 in `stages`:
///      `.lightweight` for additive changes, `.custom` otherwise.
///   4. Point `PilotApp`'s `Schema(versionedSchema:)` at the newest version.
/// Never edit a shipped version's `models` in place — that is exactly what
/// breaks upgrades and risks data loss.
/// V1 is a FROZEN SNAPSHOT of the shipped model shapes — nested copies, not
/// the live classes (rule 1 above). Pointing V1 at the live types crashes
/// every store upgrade with "Duplicate version checksums detected.":
/// `ExtensionWorkspaceLink.workspace` injects an implicit inverse into the
/// live `Workspace` entity, so a live-class V1 would hash identically to V2
/// and CoreData's staged migration aborts with an uncaught NSException.
/// Nested types keep the entity names ("Workspace", not the qualified name),
/// which is what makes the snapshot's checksum match the stamp already in
/// users' stores. Never edit these snapshot classes.
enum PilotSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            Workspace.self,
            Pane.self,
            BrowserState.self,
            EditorState.self,
            Note.self,
            RemoteDesktopConnection.self,
        ]
    }

    @Model
    final class Workspace {
        #Unique([\Workspace.id])

        var id: UUID = UUID()
        var name: String = ""
        var selectedPaneID: UUID?
        var frontmostTerminalPaneID: UUID?
        var axisRaw: String = "vertical"
        var isInspectorPresented: Bool = false
        var inspectorTabRaw: String = "Actions"
        var focusedPaneID: UUID?
        var isPinned: Bool = false
        var workspaceSortOrder: Int = 0
        var rootPath: String = ""
        var rootPathSourceRaw: String? = "automatic"
        var actionBadgeCount: Int = 0

        @Relationship(deleteRule: .cascade, inverse: \Pane.workspace)
        var panes: [Pane] = []

        init() {}
    }

    @Model
    final class Pane {
        #Unique([\Pane.id])

        var id: UUID = UUID()
        var kindRaw: String = "terminal"
        var sortOrder: Int = 0
        var currentDirectory: String = ""
        var bellCount: Int = 0
        var sizeFraction: Double = 0
        var isCollapsed: Bool = false
        var restoredSizeFraction: Double = 0
        var wasCollapsedBeforeFocus: Bool = false

        @Relationship(deleteRule: .cascade)
        var browserState: BrowserState?

        @Relationship(deleteRule: .cascade)
        var editorState: EditorState?

        var workspace: Workspace?

        init() {}
    }

    @Model
    final class BrowserState {
        var urlText: String = ""
        var appearanceModeRaw: String = "System"
        var navigationRequestID: Int = 0
        var inspectorToggleRequestID: Int = 0

        init() {}
    }

    @Model
    final class EditorState {
        var filePath: String = ""

        init() {}
    }

    @Model
    final class Note {
        #Unique([\Note.id])

        var id: UUID = UUID()
        var body: String = ""
        var sortOrder: Int = 0
        var createdAt: Date = Date()

        init() {}
    }

    @Model
    final class RemoteDesktopConnection {
        #Unique([\RemoteDesktopConnection.id])

        var id: UUID = UUID()
        var host: String = ""
        var port: Int = 5900
        var nickname: String = ""
        var username: String = ""
        var sortOrder: Int = 0
        var createdAt: Date = Date()
        var lastConnectedAt: Date?

        init() {}
    }
}

/// V2 is a frozen snapshot of the shipped Extension ownership/link schema.
/// It must remain unchanged now that V3 adds the browser-engine discriminator.
enum PilotSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            Workspace.self,
            Pane.self,
            BrowserState.self,
            EditorState.self,
            Note.self,
            RemoteDesktopConnection.self,
            ExtensionWorkspaceLink.self,
        ]
    }

    @Model
    final class Workspace {
        #Unique([\Workspace.id])

        var id: UUID = UUID()
        var name: String = ""
        var selectedPaneID: UUID?
        var frontmostTerminalPaneID: UUID?
        var axisRaw: String = "vertical"
        var isInspectorPresented: Bool = false
        var inspectorTabRaw: String = "Actions"
        var focusedPaneID: UUID?
        var isPinned: Bool = false
        var workspaceSortOrder: Int = 0
        var rootPath: String = ""
        var rootPathSourceRaw: String? = "automatic"
        var actionBadgeCount: Int = 0

        @Relationship(deleteRule: .cascade, inverse: \Pane.workspace)
        var panes: [Pane] = []

        init() {}
    }

    @Model
    final class Pane {
        #Unique([\Pane.id])

        var id: UUID = UUID()
        var kindRaw: String = "terminal"
        var sortOrder: Int = 0
        var currentDirectory: String = ""
        var bellCount: Int = 0
        var sizeFraction: Double = 0
        var isCollapsed: Bool = false
        var restoredSizeFraction: Double = 0
        var wasCollapsedBeforeFocus: Bool = false

        @Relationship(deleteRule: .cascade)
        var browserState: BrowserState?

        @Relationship(deleteRule: .cascade)
        var editorState: EditorState?

        var workspace: Workspace?

        init() {}
    }

    @Model
    final class BrowserState {
        var urlText: String = ""
        var appearanceModeRaw: String = "System"
        var navigationRequestID: Int = 0
        var inspectorToggleRequestID: Int = 0

        init() {}
    }

    @Model
    final class EditorState {
        var filePath: String = ""

        init() {}
    }

    @Model
    final class Note {
        #Unique([\Note.id])

        var id: UUID = UUID()
        var body: String = ""
        var sortOrder: Int = 0
        var createdAt: Date = Date()

        init() {}
    }

    @Model
    final class RemoteDesktopConnection {
        #Unique([\RemoteDesktopConnection.id])

        var id: UUID = UUID()
        var host: String = ""
        var port: Int = 5900
        var nickname: String = ""
        var username: String = ""
        var sortOrder: Int = 0
        var createdAt: Date = Date()
        var lastConnectedAt: Date?

        init() {}
    }

    @Model
    final class ExtensionWorkspaceLink {
        var sourceWorkspaceID: UUID = UUID()

        @Relationship(deleteRule: .cascade)
        var workspace: Workspace?

        init() {}
    }
}

/// Adds a persisted browser-engine discriminator. The live BrowserState
/// supplies WebKit as the property default, so V2 stores migrate without
/// changing the behavior of existing browser panes.
enum PilotSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            Workspace.self,
            Pane.self,
            BrowserState.self,
            EditorState.self,
            Note.self,
            RemoteDesktopConnection.self,
            ExtensionWorkspaceLink.self,
        ]
    }
}

enum PilotMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [PilotSchemaV1.self, PilotSchemaV2.self, PilotSchemaV3.self]
    }

    /// One stage per version-to-version upgrade; append a stage whenever a
    /// new `PilotSchemaV*` is added above.
    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: PilotSchemaV1.self, toVersion: PilotSchemaV2.self),
            .lightweight(fromVersion: PilotSchemaV2.self, toVersion: PilotSchemaV3.self),
        ]
    }
}
