import AppKit
import Sparkle

@MainActor
final class PilotSettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private struct Section {
        let id: String
        let title: String
        let searchTerms: String
    }
    private let sections = [
        Section(id: SettingsTab.general, title: "General", searchTerms: "General identity keys about version updates setup permissions tools Chromium"),
        Section(id: SettingsTab.sidebar, title: "Sidebar",
                searchTerms: (["Sidebar", "show", "hide"] + SidebarFeature.allCases.map(\.title)).joined(separator: " ")),
        Section(id: SettingsTab.drones, title: "Drones", searchTerms: "Drones remote workers pairing Bonjour"),
        Section(id: SettingsTab.usage, title: "Usage", searchTerms: "Usage Claude Codex Kimi Grok")
    ]
    private let updater: SPUUpdater
    private let droneStore: DroneStore
    private let identity: SecureIdentity
    private let onOpenSetup: () -> Void
    private let onOpenMessaging: () -> Void
    private let defaults: UserDefaults
    private let sidebarVisibility: SidebarFeatureVisibility
    private let runsLiveChecks: Bool
    private let search = NSSearchField()
    private let table = NSTableView()
    private let detail = NSView()
    private let noResults = NativeSettingsUI.label("No settings match your search.", color: .secondaryLabelColor)
    private var filtered: [Section] = []
    private var currentSection: String?
    private var currentController: NSViewController?
    private var controllers: [String: NSViewController] = [:]
    private var defaultsObserver: NSObjectProtocol?

    init(updater: SPUUpdater, droneStore: DroneStore, identity: SecureIdentity,
         onOpenSetup: @escaping () -> Void, onOpenMessaging: @escaping () -> Void,
         defaults: UserDefaults = .standard, sidebarVisibility: SidebarFeatureVisibility? = nil,
         runsLiveChecks: Bool = true) {
        self.updater = updater
        self.droneStore = droneStore
        self.identity = identity
        self.onOpenSetup = onOpenSetup
        self.onOpenMessaging = onOpenMessaging
        self.defaults = defaults
        self.sidebarVisibility = sidebarVisibility ?? SidebarFeatureVisibility(defaults: defaults)
        self.runsLiveChecks = runsLiveChecks
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 920, height: 680)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
        search.placeholderString = "Search Settings"
        search.setAccessibilityLabel("Search Settings")
        search.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 32
        table.delegate = self
        table.dataSource = self
        table.allowsEmptySelection = true
        table.setAccessibilityLabel("Settings sections")
        refreshTypography()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshTypography), name: .cockpitUIZoomDidChange, object: nil)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let sidebar = NSView()
        [search, scroll, noResults].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            sidebar.addSubview($0)
        }
        NSLayoutConstraint.activate([
            sidebar.widthAnchor.constraint(equalToConstant: 220),
            search.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            search.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            noResults.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            noResults.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -16),
            noResults.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 24)
        ])
        let split = NativeSettingsUI.row([sidebar, detail], spacing: 0)
        split.alignment = .top
        // The sidebar is fixed; the detail pane takes all remaining width.
        split.distribution = .fill
        detail.setContentHuggingPriority(.init(1), for: .horizontal)
        NativeSettingsUI.pin(split, to: view)
        sidebar.heightAnchor.constraint(equalTo: split.heightAnchor).isActive = true
        detail.heightAnchor.constraint(equalTo: split.heightAnchor).isActive = true
        updateFilter()
        select(section: defaults.string(forKey: SettingsTab.storageKey) ?? SettingsTab.general)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        select(section: defaults.string(forKey: SettingsTab.storageKey) ?? SettingsTab.general)
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.select(section: self.defaults.string(forKey: SettingsTab.storageKey) ?? SettingsTab.general)
            }
        }
    }
    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
    }

    func select(section id: String) {
        guard isViewLoaded else { defaults.set(id, forKey: SettingsTab.storageKey); return }
        let selected = sections.contains(where: { $0.id == id }) ? id : SettingsTab.general
        if defaults.string(forKey: SettingsTab.storageKey) != selected { defaults.set(selected, forKey: SettingsTab.storageKey) }
        if let row = filtered.firstIndex(where: { $0.id == selected }), table.selectedRow != row {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        guard currentSection != selected else { return }
        currentSection = selected
        currentController?.view.removeFromSuperview()
        currentController?.removeFromParent()
        let controller: NSViewController
        if let cached = controllers[selected] { controller = cached } else {
            switch selected {
            case SettingsTab.sidebar:
                controller = SidebarSettingsViewController(visibility: sidebarVisibility)
            case SettingsTab.drones:
                controller = DroneSettingsViewController(store: droneStore, runsDiscovery: runsLiveChecks)
            case SettingsTab.usage:
                if runsLiveChecks {
                    controller = UsageSettingsViewController(defaults: defaults, showsPageHeader: true)
                } else {
                    controller = UsageSettingsViewController(defaults: defaults, showsPageHeader: true, detector: { _ in false })
                }
            default:
                controller = GeneralSettingsViewController(
                    updater: updater, identity: identity, onOpenSetup: onOpenSetup,
                    onOpenMessaging: onOpenMessaging, allowsIdentityChanges: runsLiveChecks
                )
            }
            controllers[selected] = controller
        }
        currentController = controller
        addChild(controller)
        NativeSettingsUI.pin(controller.view, to: detail)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row) else { return nil }
        let cell = NSTableCellView()
        let field = NativeSettingsUI.label(filtered[row].title)
        cell.textField = field
        NativeSettingsUI.pin(field, to: cell, inset: 8)
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard filtered.indices.contains(table.selectedRow) else { return }
        select(section: filtered[table.selectedRow].id)
    }
    func controlTextDidChange(_ notification: Notification) { updateFilter() }

    @objc private func refreshTypography() {
        search.font = CockpitTypography.font(size: NSFont.systemFontSize)
        search.currentEditor()?.font = search.font
        search.invalidateIntrinsicContentSize()
        table.rowHeight = max(32, CockpitTypography.font(size: 13).ascender - CockpitTypography.font(size: 13).descender + 16)
    }

    private func updateFilter() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filtered = sections.filter { query.isEmpty || $0.searchTerms.localizedCaseInsensitiveContains(query) }
        table.reloadData()
        noResults.isHidden = !filtered.isEmpty
        if let currentSection, let row = filtered.firstIndex(where: { $0.id == currentSection }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }
}

@MainActor
private final class GeneralSettingsViewController: NSViewController {
    private let identity: SecureIdentity
    private let updateAction: SoftwareUpdateAction
    private let onOpenSetup: () -> Void
    private let onOpenMessaging: () -> Void
    private let allowsIdentityChanges: Bool
    private let localKey = NativeSettingsUI.label("", size: 11, selectable: true)
    private let peerKey = NativeSettingsUI.label("", size: 11, selectable: true)
    private let syncStatus = NativeSettingsUI.label("")
    private let observation = NativeSettingsObservation()

    init(updater: SPUUpdater, identity: SecureIdentity, onOpenSetup: @escaping () -> Void,
         onOpenMessaging: @escaping () -> Void, allowsIdentityChanges: Bool) {
        self.identity = identity
        updateAction = SoftwareUpdateAction(updater: updater)
        self.onOpenSetup = onOpenSetup
        self.onOpenMessaging = onOpenMessaging
        self.allowsIdentityChanges = allowsIdentityChanges
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let stack = NativeSettingsUI.column(spacing: 20)
        stack.addArrangedSubview(NativeSettingsUI.pageTitle("General"))
        NativeSettingsUI.fillWidth(NativeSettingsUI.group("About", [
            NativeSettingsUI.valueRow("Application", value: AppInfo.name),
            NativeSettingsUI.valueRow("Version", value: "\(AppInfo.version) (\(AppInfo.build))"),
            NativeSettingsUI.formRow("Software Update", accessories: [updateAction.makeButton()]),
        ]), in: stack)
        let setup = NativeSettingsButton("Open…", action: onOpenSetup)
        setup.toolTip = "Review permissions, companion connections, and developer tools."
        NativeSettingsUI.fillWidth(NativeSettingsUI.group("Setup", [
            NativeSettingsUI.formRow("Setup Assistant", accessories: [setup]),
        ]), in: stack)
        for key in [localKey, peerKey] {
            key.usesMonospacedFont = true
            key.textColor = .secondaryLabelColor
            key.lineBreakMode = .byTruncatingMiddle
            key.maximumNumberOfLines = 1
        }
        let regenerate = NativeSettingsButton("Regenerate") { [weak self] in
            guard let self, self.allowsIdentityChanges, !self.identity.isIsolated else { return }
            self.identity.regenerate()
        }
        regenerate.toolTip = "Generate a new device key and re-sync it with your paired device."
        regenerate.isEnabled = allowsIdentityChanges && !identity.isIsolated
        let identityRows: [NSView] = [
            NativeSettingsUI.formRow("Paired Device", subtitle: peerKey, accessories: [syncStatus]),
            NativeSettingsUI.formRow("This Device", subtitle: localKey, accessories: [regenerate]),
            NativeSettingsUI.formRow("Secure Messaging", accessories: [NativeSettingsButton("Open…", action: onOpenMessaging)]),
        ]
        let identityGroup = NativeSettingsUI.group("Identity & Keys", identityRows)
        identityGroup.toolTip = "Your device key is generated automatically and exchanged with your paired device over the encrypted connection."
        NativeSettingsUI.fillWidth(identityGroup, in: stack)
        let diagnostics = ChromiumDiagnosticsViewController()
        addChild(diagnostics)
        NativeSettingsUI.fillWidth(diagnostics.view, in: stack)
        view = NativeSettingsUI.scrolling(stack)
        refreshIdentity()
    }
    override func viewWillAppear() {
        super.viewWillAppear()
        observation.start { [weak self] in self?.refreshIdentity() }
    }
    override func viewWillDisappear() {
        super.viewWillDisappear()
        observation.stop()
    }
    private func refreshIdentity() {
        localKey.stringValue = identity.localPublicKey ?? "Generating…"
        peerKey.stringValue = identity.peerPublicKey ?? ""
        peerKey.isHidden = identity.peerPublicKey == nil
        syncStatus.stringValue = identity.isSynced ? "Synced" : "Waiting…"
        syncStatus.textColor = identity.isSynced ? .systemGreen : .secondaryLabelColor
        localKey.toolTip = identity.localPublicKey
        peerKey.toolTip = identity.peerPublicKey
    }
}
