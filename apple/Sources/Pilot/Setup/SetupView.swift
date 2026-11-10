import AppKit
import Sparkle

@MainActor
final class SetupViewController: NSViewController {
    static let windowSize = CGSize(width: 900, height: 620)
    private let progress: SetupProgress
    private let updater: SPUUpdater
    private let onFinish: (URL?) -> Void
    private let runsChecks: Bool
    private let defaults: UserDefaults
    private let permissions = SetupPermissions()
    private let tools: SetupTools
    private let observation = NativeSettingsObservation()
    private let pages = NativeSettingsUI.column(spacing: 18)
    private let navigation = NativeSettingsUI.row([])
    private var stepButtons: [SetupStep: NSButton] = [:]
    private var requesting: SetupPermission?
    private var enableCompanionsAfterProbe = false
    private var copiedCommand: String?
    private var projectDirectory: URL?
    private var renderedStep: SetupStep?
    private var visible = false
    private var checkTask: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var hasFinished = false

    init(progress: SetupProgress, updater: SPUUpdater, runsChecks: Bool = true,
         defaults: UserDefaults = .standard, tools: SetupTools = SetupTools(), onFinish: @escaping (URL?) -> Void) {
        self.progress = progress
        self.updater = updater
        self.runsChecks = runsChecks
        self.defaults = defaults
        self.tools = tools
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = Self.windowSize
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: Self.windowSize))
        let sidebar = NativeSettingsUI.column(spacing: 16)
        sidebar.addArrangedSubview(NativeSettingsUI.label("Cockpit", size: 22, weight: .bold))
        sidebar.addArrangedSubview(NativeSettingsUI.label("Your development environment, ready for takeoff.", color: .secondaryLabelColor))
        for step in SetupStep.allCases {
            let button = NativeSettingsButton("\(step.rawValue + 1)   \(step.title)") { [weak self] in
                guard let self, self.requesting == nil else { return }
                self.progress.step = step
            }
            button.setButtonType(.onOff)
            button.alignment = .left
            button.bezelStyle = .recessed
            identify(button, "setup.step.\(step.rawValue)")
            NativeSettingsUI.fillWidth(button, in: sidebar)
            stepButtons[step] = button
        }
        sidebar.addArrangedSubview(NativeSettingsUI.label("You can return to setup from the Cockpit menu at any time.", size: 11, color: .secondaryLabelColor))
        let sidebarContainer = NSVisualEffectView()
        sidebarContainer.material = .sidebar
        sidebarContainer.blendingMode = .behindWindow
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebarContainer.addSubview(sidebar)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor, constant: 20),
            sidebar.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor, constant: -20),
            sidebar.topAnchor.constraint(equalTo: sidebarContainer.topAnchor, constant: 24),
            sidebar.bottomAnchor.constraint(lessThanOrEqualTo: sidebarContainer.bottomAnchor, constant: -24),
            sidebarContainer.widthAnchor.constraint(equalToConstant: 220)
        ])
        let scroll = NativeSettingsUI.scrolling(pages)
        let right = NSView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        navigation.translatesAutoresizingMaskIntoConstraints = false
        right.addSubview(scroll)
        right.addSubview(navigation)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: right.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: navigation.topAnchor, constant: -16),
            navigation.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 24),
            navigation.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -24),
            navigation.bottomAnchor.constraint(equalTo: right.bottomAnchor, constant: -20),
            navigation.heightAnchor.constraint(greaterThanOrEqualToConstant: 32)
        ])
        let split = NativeSettingsUI.row([sidebarContainer, right], spacing: 0)
        split.alignment = .top
        NativeSettingsUI.pin(split, to: view)
        sidebarContainer.heightAnchor.constraint(equalTo: split.heightAnchor).isActive = true
        right.heightAnchor.constraint(equalTo: split.heightAnchor).isActive = true
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        visible = true
        hasFinished = false
        renderedStep = nil
        if runsChecks { permissions.refresh() }
        observation.start { [weak self] in self?.refresh() }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.runsChecks, self.visible else { return }
                self.permissions.refresh()
            }
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        visible = false
        observation.stop()
        checkTask?.cancel()
        checkTask = nil
        requestTask?.cancel()
        requestTask = nil
        requesting = nil
        permissions.stopProbe()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
    }

    func refresh() {
        guard isViewLoaded else { return }
        if permissions.status(.localNetwork) == .allowed, enableCompanionsAfterProbe {
            defaults.set(true, forKey: SetupProgress.companionsKey)
            enableCompanionsAfterProbe = false
        }
        let step = progress.step
        let focusedAction = step == renderedStep ? focusedActionIdentifier() : nil
        // Permission polling also rebuilds the page; only a step change fades.
        let stepChanged = step != renderedStep
        if stepChanged {
            renderedStep = step
            if visible, runsChecks, step == .tools || step == .ready {
                checkTask?.cancel()
                checkTask = Task { [weak self] in await self?.tools.refresh() }
            }
        }
        NativeSettingsUI.clear(pages)
        pages.addArrangedSubview(NativeSettingsUI.label("SET UP YOUR MAC", size: 11, weight: .semibold, color: .secondaryLabelColor))
        pages.addArrangedSubview(NativeSettingsUI.label(pageTitle, size: 26, weight: .bold))
        NativeSettingsUI.fillWidth(NativeSettingsUI.label(pageSubtitle, color: .secondaryLabelColor), in: pages)
        switch step {
        case .welcome: renderWelcome()
        case .permissions: renderPermissions()
        case .tools: renderTools()
        case .ready: renderSummary()
        }
        for (candidate, button) in stepButtons {
            button.state = candidate == step ? .on : .off
            button.isEnabled = requesting == nil
        }
        renderNavigation()
        restoreFocusedAction(focusedAction)
        if stepChanged { CockpitMotion.reveal(pages) }
    }

    @discardableResult
    private func identify(_ button: NativeSettingsButton, _ identifier: String) -> NativeSettingsButton {
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityIdentifier(identifier)
        return button
    }

    /// Tool and permission probes can publish while someone is tabbing through
    /// setup. Preserve the same action across a status-only rebuild; never move
    /// focus from the stable sidebar, another control, or an active sheet.
    private func focusedActionIdentifier() -> NSUserInterfaceItemIdentifier? {
        guard let window = view.window, window.attachedSheet == nil,
              let button = window.firstResponder as? NSButton,
              button.isDescendant(of: pages) || button.isDescendant(of: navigation) else { return nil }
        return button.identifier
    }

    private func restoreFocusedAction(_ identifier: NSUserInterfaceItemIdentifier?) {
        guard let identifier, let window = view.window, window.attachedSheet == nil,
              let button = action(with: identifier, in: pages) ?? action(with: identifier, in: navigation),
              button.isEnabled, !button.isHiddenOrHasHiddenAncestor else { return }
        window.makeFirstResponder(button)
    }

    private func action(with identifier: NSUserInterfaceItemIdentifier, in container: NSView) -> NSButton? {
        if let button = container as? NSButton, button.identifier == identifier { return button }
        for child in container.subviews {
            if let button = action(with: identifier, in: child) { return button }
        }
        return nil
    }

    private var pageTitle: String {
        switch progress.step {
        case .welcome: "Welcome to Cockpit"
        case .permissions: "A few permissions. Fewer interruptions."
        case .tools: "Bring your tools along."
        case .ready: "Your workspace is ready."
        }
    }
    private var pageSubtitle: String {
        switch progress.step {
        case .welcome: "Set up the features you use before you start building. Everything here is optional; the terminal and editor are built in."
        case .permissions: "Approve each feature you want to use. macOS asks for each permission separately, and you stay in control."
        case .tools: "We check what is already installed. Use the instructions below to add missing tools, then check again."
        case .ready: "Review your choices, then open Cockpit. Skipped features can be configured later from Set Up Cockpit."
        }
    }
    private func section(_ title: String, _ views: [NSView]) {
        NativeSettingsUI.fillWidth(NativeSettingsUI.section(title, views), in: pages)
    }

    private func renderWelcome() {
        section("Start building", [NativeSettingsUI.label("Terminals, editing, browser previews, and notes in one workspace.")])
        section("Approve access up front", [NativeSettingsUI.label("Choose permissions for device sharing and browser previews before you need them.")])
        section("Connect your tools", [NativeSettingsUI.label("Check Git, GitHub, persistent terminals, simulators, and containers.")])
        let path = Bundle.main.bundleURL.path
        if !path.hasPrefix("/Applications/"), !path.hasPrefix(NSHomeDirectory() + "/Applications/") {
            section("Install in Applications", [NativeSettingsUI.label(
                "For reliable updates, drag Cockpit into Applications and open it there before setting up permissions.", color: .secondaryLabelColor
            )])
        }
        NativeSettingsUI.fillWidth(NativeSettingsUI.label(
            "macOS may ask you to quit and reopen after a permission change. Your setup progress is saved automatically.", color: .secondaryLabelColor
        ), in: pages)
    }

    private func renderPermissions() {
        for permission in SetupPermission.allCases {
            let status = permissions.status(permission)
            var rows: [NSView] = [NativeSettingsUI.label(permission.detail),
                NativeSettingsUI.label(status.label, size: 11, color: status == .allowed ? .systemGreen : .secondaryLabelColor)]
            if status != .allowed {
                let button = NativeSettingsButton(
                    requesting == permission ? "Requesting…" : (status == .needsSettings ? "Open Settings" : "Enable")
                ) { [weak self] in self?.request(permission) }
                button.isEnabled = runsChecks && requesting == nil && status != .checking && status != .restricted
                identify(button, "setup.permission.\(permission.rawValue).request")
                button.setAccessibilityLabel("\(button.title) \(permission.title)")
                rows.append(button)
            }
            section(permission.title, rows)
        }
        let companions = NativeSettingsButton(
            checkbox: "Connect companion apps automatically", checked: defaults.bool(forKey: SetupProgress.companionsKey)
        ) { [weak self] enabled in self?.defaults.set(enabled, forKey: SetupProgress.companionsKey) }
        companions.isEnabled = permissions.status(.localNetwork) == .allowed || defaults.bool(forKey: SetupProgress.companionsKey)
        identify(companions, "setup.companions")
        pages.addArrangedSubview(companions)
        NativeSettingsUI.fillWidth(NativeSettingsUI.label(
            "Enable Local Network first. Turning this off keeps Walkie and Kneeboard discovery off at launch.", size: 11, color: .secondaryLabelColor
        ), in: pages)
        let refresh = NativeSettingsButton("Refresh Status") { [weak self] in self?.permissions.refresh() }
        let verify = NativeSettingsButton("Check Local Network") { [weak self] in self?.permissions.verifyLocalNetwork() }
        refresh.isEnabled = runsChecks && requesting == nil
        verify.isEnabled = runsChecks && requesting == nil && permissions.status(.localNetwork) != .checking
        identify(refresh, "setup.permissions.refresh")
        identify(verify, "setup.permissions.verifyNetwork")
        pages.addArrangedSubview(NativeSettingsUI.row([refresh, verify]))
        NativeSettingsUI.fillWidth(NativeSettingsUI.label(
            "If access is already denied, enable Cockpit in System Settings → Privacy & Security. Screen recording may require reopening the app. Website access and new device pairing still ask for your approval.",
            size: 11, color: .secondaryLabelColor
        ), in: pages)
    }

    private func request(_ permission: SetupPermission) {
        guard runsChecks, requesting == nil else { return }
        if permission == .localNetwork { enableCompanionsAfterProbe = true }
        requesting = permission
        refresh()
        requestTask = Task { [weak self] in
            guard let self else { return }
            await permissions.request(permission)
            guard !Task.isCancelled else { return }
            requesting = nil
            refresh()
        }
    }

    private func renderTools() {
        section("Your first project", [
            NativeSettingsUI.label("Choose a folder now to grant access and open a terminal there when setup finishes."),
            NativeSettingsUI.label(projectDirectory?.path ?? "No folder selected · optional", size: 11, color: .secondaryLabelColor),
            identify(NativeSettingsButton("Choose Folder…") { [weak self] in self?.chooseProjectDirectory() }, "setup.project.choose")
        ])
        for tool in SetupTool.all {
            let ready = tools.results[tool.id] == true
            let status = tools.results[tool.id].map { $0 ? "Ready" : "Setup needed · optional" }
                ?? (tools.isChecking ? "Checking…" : "Not checked")
            var rows: [NSView] = [
                NativeSettingsUI.label(status, size: 11, color: ready ? .systemGreen : .secondaryLabelColor),
                NativeSettingsUI.label(tool.detail)
            ]
            if !ready {
                let command = NativeSettingsUI.label(tool.command, size: 11, selectable: true)
                command.usesMonospacedFont = true
                rows.append(command)
                let copy = NativeSettingsButton(copiedCommand == tool.id ? "Copied" : "Copy") { [weak self] in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tool.command, forType: .string)
                    self?.copiedCommand = tool.id
                    self?.refresh()
                }
                identify(copy, "setup.tool.\(tool.id).copy")
                let instructions = identify(NativeSettingsButton("Instructions") {
                    NSWorkspace.shared.open(tool.helpURL)
                }, "setup.tool.\(tool.id).instructions")
                rows.append(NativeSettingsUI.row([copy, instructions]))
            }
            section(tool.title, rows)
        }
        let refresh = NativeSettingsButton(tools.isChecking ? "Checking…" : "Check Again") { [weak self] in
            self?.checkTask = Task { [weak self] in await self?.tools.refresh() }
        }
        refresh.isEnabled = runsChecks && !tools.isChecking
        identify(refresh, "setup.tools.refresh")
        let homebrew = identify(NativeSettingsButton("Get Homebrew") {
            NSWorkspace.shared.open(URL(string: "https://brew.sh/")!)
        }, "setup.tools.homebrew")
        pages.addArrangedSubview(NativeSettingsUI.row([
            refresh, homebrew
        ]))
        NativeSettingsUI.fillWidth(NativeSettingsUI.label(
            "Run copied commands in Terminal. Install and sign in to your preferred coding agents there as well. Cockpit uses your existing accounts; it does not install tools or change credentials automatically.",
            size: 11, color: .secondaryLabelColor
        ), in: pages)
    }

    private func chooseProjectDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose a project folder"
        panel.prompt = "Use Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK else { return }
            self.projectDirectory = panel.url
            self.refresh()
        }
        if let window = view.window { panel.beginSheetModal(for: window, completionHandler: completion) } else { panel.begin(completionHandler: completion) }
    }

    private func renderSummary() {
        section("Terminal, editor & browser included", [
            NativeSettingsUI.label("Create a workspace, choose a project folder, and start building.")
        ])
        if let projectDirectory { NativeSettingsUI.fillWidth(NativeSettingsUI.label(projectDirectory.path, selectable: true), in: pages) }
        let statuses = SetupPermission.allCases.map { permission -> NSView in
            let allowed = permissions.status(permission) == .allowed
            return NativeSettingsUI.label("\(permission.title): \(allowed ? "Allowed" : "Not verified · optional")",
                                          color: allowed ? .systemGreen : .secondaryLabelColor)
        }
        section("Your choices", statuses + [
            NativeSettingsUI.label("\(tools.results.values.filter { $0 }.count) of \(SetupTool.all.count) optional developer tools ready")
        ])
        pages.addArrangedSubview(identify(NativeSettingsButton(
            checkbox: "Check for updates automatically", checked: updater.automaticallyChecksForUpdates
        ) { [weak self] enabled in self?.updater.automaticallyChecksForUpdates = enabled }, "setup.updates.automatic"))
        NativeSettingsUI.fillWidth(NativeSettingsUI.label(
            "Updates are verified before installation. You can also use Cockpit → Check for Updates.", size: 11, color: .secondaryLabelColor
        ), in: pages)
        NativeSettingsUI.fillWidth(NativeSettingsUI.label(
            "When connecting a companion, compare the fingerprint on both devices and approve the pairing. Approve USB trust or debugging on each phone you connect.",
            color: .secondaryLabelColor
        ), in: pages)
    }

    private func renderNavigation() {
        NativeSettingsUI.clear(navigation)
        if progress.step != .welcome {
            navigation.addArrangedSubview(identify(NativeSettingsButton("Back") { [weak self] in
                guard let self else { return }
                self.progress.step = SetupStep(rawValue: self.progress.step.rawValue - 1) ?? .welcome
            }, "setup.navigation.back"))
        }
        navigation.addArrangedSubview(NativeSettingsUI.spacer())
        let next: NativeSettingsButton
        if progress.step != .ready {
            navigation.addArrangedSubview(identify(NativeSettingsButton("Set Up Later") {
                [weak self] in self?.progress.step = .ready
            }, "setup.navigation.later"))
            next = NativeSettingsButton("Continue") { [weak self] in
                guard let self else { return }
                self.progress.step = SetupStep(rawValue: self.progress.step.rawValue + 1) ?? .ready
            }
            identify(next, "setup.navigation.continue")
        } else {
            next = NativeSettingsButton("Open Cockpit") { [weak self] in
                guard let self, !self.hasFinished else { return }
                self.hasFinished = true
                self.permissions.stopProbe()
                self.progress.finish()
                self.onFinish(self.projectDirectory)
            }
            identify(next, "setup.navigation.finish")
        }
        next.keyEquivalent = "\r"
        navigation.addArrangedSubview(next)
        for case let button as NSButton in navigation.arrangedSubviews { button.isEnabled = requesting == nil }
    }
}
