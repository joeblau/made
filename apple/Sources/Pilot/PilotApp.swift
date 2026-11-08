import AppKit
import Observation
import Sparkle
import SwiftData

/// Services and persistent sessions outlive their native windows.
@MainActor
final class PilotApp {
    let modelContainer: ModelContainer
    let preferences: UserDefaults
    let isIsolated: Bool
    let updaterController: SPUStandardUpdaterController
    let setupProgress: SetupProgress
    let store: WorkspaceStore
    let extensionWorkspaceController: ExtensionWorkspaceController
    let syncService: PeerSyncService
    let headphoneDetector = HeadphoneDetector()
    let frameSender: FrameSender
    let screenMirror: ScreenMirror
    let remoteInkModel = RemoteInkModel()
    let actionWatcher: WorkspaceActionWatcher
    let usageStore: UsageStore
    let agenticUseStore: AgenticUsageStore
    let runnersStore: RunnersStore
    let droneStore: DroneStore
    let dashboardPublisher: DashboardPublisher
    let buildPush = BuildPushCoordinator()
    let secureIdentity: SecureIdentity
    let pairingPrompts = PairingPromptCoordinator()
    var peerDeviceStatus = DeviceStatus()
    lazy var walkieDeliveryQueue = PilotWalkieDeliveryQueue(delivery: walkieDelivery)
    var walkieInput: PilotWalkieInputState { walkieDeliveryQueue.state }
    var plotterClientCount = 0
    var plotterPairingRequest: FrameLinkPairingRequest?
    var mainWindowID: CGWindowID?
    var extensionWindowID: CGWindowID?
    var lastRemoteInputSurface: WorkspacePaneSurface = .main
    var didSetupSync = false
    var didStartServices = false
    var syncTimer: Timer?
    var mainWindow: CockpitWindowController?
    var extensionWindow: CockpitWindowController?
    private var settingsWindow: NSWindowController?
    private var setupWindow: NSWindowController?
    private var messagingWindow: NSWindowController?
    private var menuController: CockpitMenuController?
    private var globalControllers: [SidebarSelection: NSViewController] = [:]
    private var observation: CockpitObservation?
    private var notificationTokens: [NSObjectProtocol] = []
    private var lastCompanionsEnabled = false
    private var lastPeerConnected = false
    private var presentedWalkieID: UUID?
    private var presentedPlotterID: UUID?
    private var appearanceReporter: AppearanceReporter?
    private var lastAudioDescription = ""
    private var pendingSaveFailure: String?
    private var saveFailureAlert: NSAlert?
    #if DEBUG
    private var demoWalkiePairing = DemoReviewFixture.walkiePairingRequest()
    private var demoPlotterPairing = DemoReviewFixture.plotterPairingRequest()
    #endif
    var companionsEnabled: Bool { preferences.bool(forKey: SetupProgress.companionsKey) }

    init(isolated: Bool = false) {
        isIsolated = isolated
        preferences = isolated ? UserDefaults(suiteName: "app.blau.pilot.fixture.\(UUID().uuidString)")! : .standard
        setupProgress = SetupProgress(defaults: preferences, bypass: isolated)
        updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let schema = Schema(versionedSchema: PilotSchemaV4.self)
        if isolated {
            modelContainer = try! ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        } else {
            CockpitPersistence.yieldToExistingInstanceIfNeeded()
            let url = CockpitPersistence.persistentStoreURL()
            CockpitPersistence.backUpStore(at: url, fileManager: .default)
            do {
                modelContainer = try CockpitPersistence.makeModelContainer(
                    schema: schema, migrationPlan: PilotMigrationPlan.forStore(at: url),
                    configuration: ModelConfiguration(schema: schema, url: url))
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "Saved workspaces could not be opened"
                alert.informativeText = "Your workspace database has been kept in place. Cockpit will quit so it can be recovered.\n\n\(error.localizedDescription)"
                alert.addButton(withTitle: "Quit")
                alert.addButton(withTitle: "Show Database in Finder")
                if alert.runModal() == .alertSecondButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                exit(EXIT_FAILURE)
            }
        }
        store = WorkspaceStore(modelContext: modelContainer.mainContext,
                               workspaceGroups: WorkspaceGroups(defaults: preferences), defaults: preferences)
        let workspaceStore = store
        extensionWorkspaceController = ExtensionWorkspaceController(
            modelContext: modelContainer.mainContext,
            onMembershipChange: { workspaceStore.extensionWorkspaceMembershipDidChange() })
        if isolated {
            store.isNotesMode = true
            store.selectedNote?.body = "# Cockpit native fixture\n\nThis note uses an isolated in-memory store.\n\n- [ ] Verify native editing\n- [x] Preserve the user's workspace\n"
        }
        if UserDefaults.standard.bool(forKey: "demoMode") { store.seedDemoWorkspacesIfNeeded() }
        syncService = PeerSyncService(role: .advertiser, displayName: Host.current().localizedName ?? "Mac",
                                      usesEphemeralIdentity: isolated)
        secureIdentity = SecureIdentity(role: .pilot, isolated: isolated)
        actionWatcher = WorkspaceActionWatcher()
        usageStore = UsageStore(defaults: preferences)
        agenticUseStore = AgenticUsageStore(defaults: preferences)
        runnersStore = RunnersStore(defaults: preferences)
        droneStore = isolated ? DroneStore.isolated() : .shared
        dashboardPublisher = DashboardPublisher(actionWatcher: actionWatcher, usageStore: usageStore,
            agenticUsageStore: agenticUseStore, runnersStore: runnersStore, defaults: preferences)
        frameSender = FrameSender(usesEphemeralIdentity: isolated)
        screenMirror = ScreenMirror(sender: frameSender)
        let sender = frameSender
        dashboardPublisher.onEnvelopeChange = { sender.send(.dashboard($0)) }
        screenMirror.onClientConnected = { [weak dashboardPublisher] in dashboardPublisher?.republish() }
    }

    func start() {
        CockpitPaneControllerCache.shared.onCloseValidationFailure = { [weak self] id in
            guard let self else { return }
            if self.mainWindow?.revealPane(withID: id) != true {
                self.showMain()
                _ = self.extensionWindow?.revealPane(withID: id)
            }
        }
        installMenus()
        installNotifications()
        if setupProgress.needsInitialSetup { showSetup() } else { showInitialWindows(); startServices() }
        observation = CockpitObservation { [weak self] in self?.refreshObservedState() }
        observation?.start()
        #if DEBUG
        if DemoReviewFixture.flag("demoSecureMessaging") { showMessaging() }
        Task { await DemoReviewFixture.postPersistenceFailureOnce() }
        #endif
    }

    var activeWindowController: CockpitWindowController? {
        remoteInputSurface() == .main ? mainWindow : extensionWindow
    }

    var keyWindowController: CockpitWindowController? {
        if mainWindow?.window?.isKeyWindow == true { return mainWindow }
        if extensionWindow?.window?.isKeyWindow == true { return extensionWindow }
        return nil
    }

    func showMain() {
        guard !setupProgress.needsInitialSetup else { showSetup(); return }
        if mainWindow == nil { mainWindow = makeWindow(surface: .main) }
        mainWindow?.showWindow(nil)
        mainWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showInitialWindows() {
        if !isIsolated, PilotWindowLaunchPolicy.opensByDefault(PilotWindowID.extendo) {
            extensionWindow = makeWindow(surface: .extension)
            extensionWindow?.showWindow(nil)
        }
        showMain()
    }

    func toggleExtendo() {
        guard !setupProgress.needsInitialSetup else { showSetup(); return }
        if extensionWindow == nil { extensionWindow = makeWindow(surface: .extension) }
        guard let controller = extensionWindow else { return }
        if controller.window?.isVisible == true { controller.window?.performClose(nil) } else {
            showMain()
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        }
    }

    private func makeWindow(surface: WorkspacePaneSurface) -> CockpitWindowController {
        let controller = CockpitWindowController(
            store: store, extensionController: extensionWorkspaceController, surface: surface,
            defaults: preferences, isLive: !isIsolated,
            paneFactory: { [weak self] pane, path in self?.makePane(pane, rootPath: path) ?? NSViewController() },
            globalFactory: { [weak self] selection in self?.globalController(for: selection) })
        controller.onWindowActivate = { [weak self] in self?.lastRemoteInputSurface = surface }
        controller.onWindowIDChange = { [weak self] windowID in
            guard let self else { return }
            if surface == .main { mainWindowID = windowID; screenMirror.setMainWindowID(windowID) } else {
                extensionWindowID = windowID
                if windowID == nil, lastRemoteInputSurface == .extension { lastRemoteInputSurface = .main }
            }
            if windowID == nil { walkieDeliveryQueue.reset() }
        }
        controller.inspectorFactory = { [weak self] workspace in
            guard let self else { return nil }
            let inspector = InspectorViewController(workspace: workspace, usageStore: usageStore,
                defaults: preferences, isLive: !isIsolated)
            inspector.onOpenUsageSettings = { [weak self] in self?.showSettings(section: SettingsTab.usage) }
            return inspector
        }
        controller.featureToolbarFactory = { [weak controller] pane in
            switch pane.kind {
            case .terminal:
                return TerminalFastCommandToolbarView(pane: pane)
            case .browser:
                guard let state = pane.browserState else { return nil }
                return BrowserToolbarView(state: state)
            case .device, .simulator, .android:
                return (controller?.paneController(for: pane) as? CapturePaneToolbarProviding)?.makeCaptureToolbarView()
            case .editor, .agentChat:
                return nil
            }
        }
        controller.overlayFactory = { [weak controller] in
            InkOverlayViewController(onDismiss: { [weak controller] in controller?.setDrawingActive(false) })
        }
        if surface == .main {
            controller.remoteOverlayController = RemoteInkOverlayViewController(model: remoteInkModel)
            let reporter = AppearanceReporter { [weak self] isDark in
                self?.frameSender.send(.appearance(isDark: isDark))
            }
            controller.window?.contentView?.addSubview(reporter)
            appearanceReporter = reporter
        }
        return controller
    }

    private func makePane(_ pane: Pane, rootPath: String?) -> NSViewController {
        let select: () -> Void = { [weak pane] in
            guard let pane else { return }
            pane.workspace?.selectedPaneID = pane.id
        }
        switch pane.kind {
        case .terminal:
            let controller = TerminalPaneViewController(pane: pane)
            controller.onSelect = select
            return controller
        case .browser:
            let controller = BrowserPaneViewController(pane: pane)
            controller.onSelect = select
            controller.targetTerminalPaneID = { [weak pane] in
                pane?.workspace?.frontmostTerminalPane?.id
            }
            return controller
        case .editor:
            let controller = EditorPaneViewController(pane: pane, rootPath: rootPath)
            controller.onSelect = select
            return controller
        case .agentChat:
            let controller = AgentChatPaneViewController(pane: pane, rootPath: rootPath)
            controller.onSelect = select
            return controller
        case .device:
            let controller = DevicePaneViewController(pane: pane)
            controller.onSelect = select
            return controller
        case .simulator:
            let controller = SimulatorPaneViewController(pane: pane)
            controller.onSelect = select
            return controller
        case .android:
            let controller = AndroidPaneViewController(pane: pane)
            controller.onSelect = select
            return controller
        }
    }

    private func globalController(for selection: SidebarSelection) -> NSViewController? {
        if let existing = globalControllers[selection] { return existing }
        let controller: NSViewController
        switch selection {
        case .notes: controller = NotesViewController(store: store, defaults: preferences)
        case .remoteDesktop: controller = RemoteDesktopViewController(store: store, isLive: !isIsolated)
        case .docker: controller = DockerViewController(store: DockerStore(defaults: preferences), isLive: !isIsolated)
        case .agenticUse: controller = AgenticUseViewController(store: agenticUseStore, isLive: !isIsolated)
        case .runners: controller = RunnersViewController(store: runnersStore, defaults: preferences, isLive: !isIsolated)
        case .mockups: controller = MockupsViewController(defaults: preferences)
        case .workspace: return nil
        }
        globalControllers[selection] = controller
        return controller
    }

    func showSettings(section: String? = nil) {
        if let section { preferences.set(section, forKey: SettingsTab.storageKey) }
        if settingsWindow == nil {
            settingsWindow = auxiliaryWindow(content: PilotSettingsViewController(
                updater: updaterController.updater, droneStore: droneStore, identity: secureIdentity,
                onOpenSetup: { [weak self] in self?.showSetup() },
                onOpenMessaging: { [weak self] in self?.showMessaging() }, defaults: preferences,
                sidebarVisibility: store.sidebarVisibility, runsLiveChecks: !isIsolated),
                title: "Settings", identifier: "settings", size: NSSize(width: 920, height: 680))
        }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    func showSetup() {
        if setupWindow == nil {
            let content = SetupViewController(progress: setupProgress, updater: updaterController.updater,
                                              runsChecks: !isIsolated, defaults: preferences) { [weak self] directory in
                guard let self else { return }
                if let directory { store.addWorkspace(directory: directory) }
                setupProgress.finish()
                setupWindow?.close()
                showInitialWindows()
                startServices()
            }
            setupWindow = auxiliaryWindow(content: content, title: "Set Up Cockpit", identifier: "setup",
                                          size: SetupViewController.windowSize)
        }
        setupWindow?.showWindow(nil)
        setupWindow?.window?.makeKeyAndOrderFront(nil)
    }

    func showMessaging() {
        if messagingWindow == nil {
            messagingWindow = auxiliaryWindow(content: PilotSecureMessagingViewController(defaults: preferences,
                loadsPairingSecrets: !isIsolated, localPublicKey: isIsolated ? "Fixture public key" : nil),
                title: "Secure Messaging", identifier: "secure-messaging", size: NSSize(width: 640, height: 540))
        }
        messagingWindow?.showWindow(nil)
        messagingWindow?.window?.makeKeyAndOrderFront(nil)
    }

    private func auxiliaryWindow(content: NSViewController, title: String, identifier: String, size: NSSize) -> NSWindowController {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        window.isReleasedWhenClosed = false
        window.contentViewController = content
        window.minSize = NSSize(width: min(size.width, 600), height: min(size.height, 400))
        if !isIsolated {
            window.setFrameAutosaveName("cockpit.\(identifier)")
            if !window.setFrameUsingName("cockpit.\(identifier)") { window.center() }
        } else { window.center() }
        return NSWindowController(window: window)
    }

    private func installMenus() {
        let menus = CockpitMenuController(windowProvider: { [weak self] in self?.keyWindowController },
            showMain: { [weak self] in self?.showMain() }, toggleExtendo: { [weak self] in self?.toggleExtendo() },
            showSettings: { [weak self] in self?.showSettings() }, showSetup: { [weak self] in self?.showSetup() },
            checkForUpdates: { [weak self] in self?.updaterController.updater.checkForUpdates() },
            sidebarVisibility: store.sidebarVisibility)
        menus.copyAction = { [weak self] in self?.copyOrCaptureScreenshot() }
        menus.pasteAction = { [weak self] in self?.pasteIntoSelectedPane() }
        menus.cutAction = { [weak self] in self?.sendStandardEditAction(#selector(NSText.cut(_:))) }
        menus.isMobileDeviceConnected = { [weak self] in self?.syncService.isConnected ?? false }
        menus.canCheckForUpdates = { [weak self] in
            guard let self else { return false }
            return !self.isIsolated && self.updaterController.updater.canCheckForUpdates
        }
        menus.install()
        menuController = menus
    }

    private func installNotifications() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshObservedState() }
        })
        notificationTokens.append(center.addObserver(forName: .cockpitUIZoomDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                GhosttyRuntime.shared.userZoomFactor = CockpitUIZoomController.shared.factor
            }
        })
        notificationTokens.append(center.addObserver(forName: .pilotSendIssuePrompt, object: nil, queue: .main) { [weak self] notification in
            let prompt = notification.userInfo?[BrowserAnnotate.promptUserInfoKey] as? String
            let hasTarget = BrowserAnnotate.hasCapturedTarget(in: notification.userInfo)
            let targetID = BrowserAnnotate.targetPaneID(in: notification.userInfo)
            MainActor.assumeIsolated {
                guard let self, let prompt else { return }
                let terminal = hasTarget ? self.terminalView(for: targetID) : self.activeTerminalView()
                guard let terminal else { NSSound.beep(); return }
                terminal.pasteText(prompt)
                terminal.sendEnter()
            }
        })
        notificationTokens.append(center.addObserver(forName: .pilotPersistenceSaveFailed, object: nil, queue: .main) { [weak self] notification in
            let message = notification.userInfo?["message"] as? String
            MainActor.assumeIsolated { self?.presentSaveFailure(message: message) }
        })
        notificationTokens.append(center.addObserver(forName: NSWindow.didEndSheetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.presentPendingSaveFailure() }
        })
    }

    private func presentSaveFailure(message: String?) {
        pendingSaveFailure = message ?? "Your changes remain in memory. Free disk space or fix permissions, then retry."
        presentPendingSaveFailure()
    }

    private func presentPendingSaveFailure() {
        guard saveFailureAlert == nil, let message = pendingSaveFailure else { return }
        guard let window = NSApp.keyWindow ?? activeWindowController?.window ?? setupWindow?.window,
              window.attachedSheet == nil, window.sheetParent == nil else { return }
        pendingSaveFailure = nil
        let alert = NSAlert()
        alert.messageText = "Changes could not be saved"
        alert.informativeText = message
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Cancel")
        saveFailureAlert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.saveFailureAlert = nil
            if response == .alertFirstButtonReturn {
                _ = self.modelContainer.mainContext.saveReporting(operation: "Retrying Cockpit data save")
            }
            self.presentPendingSaveFailure()
        }
    }

    func commitPendingEdits() {
        (globalControllers[.notes] as? NotesViewController)?.commitPendingEdits()
    }

    func validateCloseReadiness() -> Bool {
        CockpitPaneControllerCache.shared.validateCloseReadiness()
    }

    /// Runs on the final synchronous termination decision, after any async
    /// pane saves and browser shutdown, so later Notes edits are included.
    func saveForFinalTermination() -> Bool {
        guard validateCloseReadiness() else { return false }
        commitPendingEdits()
        return modelContainer.mainContext.saveReporting(operation: "Saving Cockpit before quit")
    }

    func startServices() {
        guard !didStartServices, !setupProgress.needsInitialSetup, !isIsolated,
              !UserDefaults.standard.bool(forKey: "demoMode") else { return }
        didStartServices = true
        GhosttyRuntime.shared.userZoomFactor = CockpitUIZoomController.shared.factor
        try? updaterController.updater.start()
        RepositoryPollingEnvironmentMonitor.shared.start()
        headphoneDetector.start()
        actionWatcher.start(store: store)
        usageStore.start()
        agenticUseStore.start()
        runnersStore.start()
        droneStore.start()
        TerminalSessionProvider.shared.configure { [weak droneStore] droneID in
            MainActor.assumeIsolated { droneStore?.terminalClient(for: droneID) }
        }
        dashboardPublisher.start()
        buildPush.onUpdate = { [weak self] in self?.syncService.send(.buildRunUpdate($0)) }
        frameSender.onClientCountChanged = { [weak self] count in
            Task { @MainActor in
                guard let self, self.companionsEnabled else { return }
                let hadClients = self.plotterClientCount > 0
                self.plotterClientCount = count
                if count > 0, !hadClients { self.screenMirror.start() }
                if count == 0, hadClients { self.screenMirror.stop() }
                self.refreshPresentations()
            }
        }
        frameSender.onPairingRequestChanged = { [weak self] request in
            Task { @MainActor in self?.plotterPairingRequest = request; self?.refreshPairingPrompts() }
        }
        frameSender.onAnnotationMessage = { [weak self] sequence, message in
            Task { @MainActor in
                guard let self else { return }
                self.remoteInkModel.handle(message)
                self.frameSender.sendAnnotationAck(sequence)
            }
        }
        remoteInkModel.onLocalEdit = { [weak self] in self?.frameSender.sendAnnotation($0) }
        lastCompanionsEnabled = companionsEnabled
        if companionsEnabled { setupSync(); frameSender.start(); buildPush.restore() }
    }

    private func refreshObservedState() {
        if didStartServices, companionsEnabled != lastCompanionsEnabled {
            lastCompanionsEnabled = companionsEnabled
            if companionsEnabled { setupSync(); frameSender.start(); buildPush.restore() } else {
                buildPush.stop(); syncService.stop(); frameSender.stop(); screenMirror.stop()
                plotterClientCount = 0; walkieDeliveryQueue.reset(); pairingPrompts.cancelAll()
            }
        }
        if syncService.isConnected != lastPeerConnected {
            lastPeerConnected = syncService.isConnected
            if lastPeerConnected {
                sendLocalDeviceStatus(); secureIdentity.refreshPeer(); secureIdentity.announce()
            } else {
                walkieDeliveryQueue.reset()
            }
        }
        let audioDescription = String(describing: headphoneDetector.audioOutput)
        if audioDescription != lastAudioDescription {
            lastAudioDescription = audioDescription
            if didStartServices { sendLocalDeviceStatus() }
        }
        refreshPairingPrompts()
        refreshPresentations()
    }

    func refreshPresentations() {
        let audio = headphoneDetector.audioOutput
        let devices = [
            CockpitConnectionStatus(name: "Walkie", symbol: "iphone", isConnected: syncService.isConnected, detail: syncService.statusText),
            CockpitConnectionStatus(name: "Kneeboard", symbol: "ipad", isConnected: plotterClientCount > 0, detail: nil),
            CockpitConnectionStatus(name: "Trigger", symbol: "applewatch", isConnected: peerDeviceStatus.isWatchConnected, detail: nil),
            CockpitConnectionStatus(name: audio?.name ?? "Audio", symbol: audio?.kind.systemImageName ?? "headphones", isConnected: audio != nil, detail: nil)
        ]
        mainWindow?.statusItems = devices
        extensionWindow?.statusItems = devices
        var isRecording = walkieInput.isRecording
        #if DEBUG
        isRecording = isRecording || DemoReviewFixture.flag("demoPeerRecording")
        #endif
        mainWindow?.isPeerRecording = isRecording
        extensionWindow?.isPeerRecording = isRecording
        appearanceReporter?.isConnected = plotterClientCount > 0
    }

    private func refreshPairingPrompts() {
        var walkie = syncService.pairingRequest
        var plotter = plotterPairingRequest
        #if DEBUG
        walkie = demoWalkiePairing ?? walkie
        plotter = demoPlotterPairing ?? plotter
        #endif
        let owner = [activeWindowController?.window, mainWindow?.window, extensionWindow?.window]
            .compactMap { $0 }.first { $0.isVisible }
        if presentedWalkieID != walkie?.id {
            if let previous = presentedWalkieID { pairingPrompts.cancel(id: previous) }
            presentedWalkieID = walkie?.id
            if let request = walkie {
                pairingPrompts.present(id: request.id, title: request.isKeyChange ? "Trust New Walkie Identity?" : "Pair with Walkie?",
                    message: "Verify this fingerprint on \(request.displayName) before approving:\n\n\(request.fingerprint)",
                    window: owner) { [weak self] approved in
                        guard let self, presentedWalkieID == request.id else { return }
                        #if DEBUG
                        if demoWalkiePairing?.id == request.id { demoWalkiePairing = nil; return }
                        #endif
                        guard syncService.pairingRequest?.id == request.id else { return }
                        syncService.resolvePairingRequest(approved: approved)
                    }
            }
        }
        if presentedPlotterID != plotter?.id {
            if let previous = presentedPlotterID { pairingPrompts.cancel(id: previous) }
            presentedPlotterID = plotter?.id
            if let request = plotter {
                pairingPrompts.present(id: request.id, title: request.isKeyChange ? "Trust New Kneeboard Identity?" : "Pair with Kneeboard?",
                    message: "Verify this fingerprint on \(request.displayName) before approving:\n\n\(request.fingerprint)",
                    window: owner) { [weak self] approved in
                        guard let self, presentedPlotterID == request.id else { return }
                        #if DEBUG
                        if demoPlotterPairing?.id == request.id { demoPlotterPairing = nil; return }
                        #endif
                        guard plotterPairingRequest?.id == request.id else { return }
                        frameSender.resolvePairingRequest(approved: approved)
                    }
            }
        }
    }

    func stop() {
        walkieDeliveryQueue.reset()
        observation?.stop()
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens.removeAll()
        syncTimer?.invalidate()
        syncTimer = nil
        pairingPrompts.shutdown()
        commitPendingEdits()
        (messagingWindow?.window?.contentViewController as? PilotSecureMessagingViewController)?.shutdown()
        guard didStartServices else { return }
        didStartServices = false
        buildPush.stop()
        dashboardPublisher.stop(); actionWatcher.stop(); usageStore.stop()
        agenticUseStore.stop(); runnersStore.stop(); droneStore.stop()
        headphoneDetector.stop(); syncService.stop(); frameSender.stop(); screenMirror.stop()
        _ = modelContainer.mainContext.saveReporting(operation: "Saving Cockpit before quit")
    }
}
