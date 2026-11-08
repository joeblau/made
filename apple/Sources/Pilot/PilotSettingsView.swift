import AppKit
import Sparkle

/// Xcode-style Settings: a full-height sidebar of pages under the traffic
/// lights, and a content column whose toolbar row holds a glass back/forward
/// capsule, the current page title, and the settings search field.
@MainActor
final class PilotSettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private struct Section {
        let id: String
        let title: String
        let symbol: String
        let searchTerms: String
    }
    private let sections = [
        Section(id: SettingsTab.general, title: "General", symbol: "gearshape",
                searchTerms: "General identity keys about version updates setup permissions tools Chromium"),
        Section(id: SettingsTab.sidebar, title: "Sidebar", symbol: "sidebar.left",
                searchTerms: (["Sidebar", "show", "hide"] + SidebarFeature.allCases.map(\.title)).joined(separator: " ")),
        Section(id: SettingsTab.drones, title: "Drones", symbol: "antenna.radiowaves.left.and.right",
                searchTerms: "Drones remote workers pairing Bonjour"),
        Section(id: SettingsTab.usage, title: "Usage", symbol: "chart.bar", searchTerms: "Usage Claude Codex Kimi Grok")
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
    private let header = NSView()
    private let pageTitle = NativeSettingsUI.label("", size: 15, weight: .bold)
    private let backButton = PilotSettingsViewController.navigationButton("chevron.left", label: "Back", key: "[")
    private let forwardButton = PilotSettingsViewController.navigationButton("chevron.right", label: "Forward", key: "]")
    private let noResults = NativeSettingsUI.label("No settings match your search.", color: .secondaryLabelColor)
    private var filtered: [Section] = []
    private var currentSection: String?
    private var currentController: NSViewController?
    private var controllers: [String: NSViewController] = [:]
    private var defaultsObserver: NSObjectProtocol?
    private var headerHeight: NSLayoutConstraint?
    /// Pages visited in this window, for the toolbar's back/forward capsule.
    private(set) var history: [String] = []
    private(set) var historyIndex = -1
    private var isNavigatingHistory = false
    static let sidebarWidth: CGFloat = 200
    /// The unified toolbar's height; the header band spans the title bar.
    static let defaultHeaderHeight: CGFloat = 52

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

    private static func navigationButton(_ symbol: String, label: String, key: String) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        button.contentTintColor = .labelColor
        button.setAccessibilityLabel(label)
        button.toolTip = label
        button.identifier = .init("settings.\(label.lowercased())")
        button.keyEquivalent = key
        button.keyEquivalentModifierMask = .command
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 28)
        ])
        return button
    }

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
        search.placeholderString = "Search"
        search.setAccessibilityLabel("Search Settings")
        search.delegate = self
        search.controlSize = .regular
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section"))
        table.addTableColumn(column)
        table.headerView = nil
        // Rows draw their own quiet rounded selection (PilotSettingsSidebarRowView)
        // rather than the vibrant source-list highlight.
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.delegate = self
        table.dataSource = self
        table.allowsEmptySelection = true
        table.setAccessibilityLabel("Settings sections")
        table.backgroundColor = .clear
        NotificationCenter.default.addObserver(self, selector: #selector(refreshTypography), name: .cockpitUIZoomDidChange, object: nil)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        // A short list never shows a track, even with "Show scroll bars: Always".
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        // The sidebar runs the full window height, under the traffic lights.
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .followsWindowActiveState
        let divider = NSBox()
        divider.boxType = .separator
        [scroll, noResults, divider].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            sidebar.addSubview($0)
        }
        let headerHeight = header.heightAnchor.constraint(equalToConstant: Self.defaultHeaderHeight)
        self.headerHeight = headerHeight
        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: sidebar.topAnchor),
            divider.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            divider.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            noResults.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            noResults.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -16),
            noResults.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 8)
        ])

        backButton.target = self
        backButton.action = #selector(goBack(_:))
        forwardButton.target = self
        forwardButton.action = #selector(goForward(_:))
        let separator = NSBox()
        separator.boxType = .custom
        separator.borderWidth = 0
        separator.fillColor = .separatorColor
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let navigation = NativeSettingsUI.row([backButton, separator, forwardButton], spacing: 1)
        navigation.edgeInsets = NSEdgeInsets(top: 1, left: 3, bottom: 1, right: 3)
        let capsule = CockpitGlassView(content: navigation, cornerRadius: 15, interactive: true)
        capsule.setAccessibilityElement(false)
        pageTitle.maximumNumberOfLines = 1
        pageTitle.lineBreakMode = .byTruncatingTail
        pageTitle.identifier = .init("settings.pageTitle")
        pageTitle.setAccessibilityRole(.staticText)
        search.translatesAutoresizingMaskIntoConstraints = false
        let searchWidth = search.widthAnchor.constraint(equalToConstant: 200)
        searchWidth.priority = .defaultHigh
        searchWidth.isActive = true
        search.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        search.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bar = NativeSettingsUI.row([capsule, pageTitle, NativeSettingsUI.spacer(), search], spacing: 14)
        bar.distribution = .fill
        pageTitle.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        NativeSettingsUI.pin(bar, to: header)
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 16)

        let content = NSView()
        [header, detail].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }
        [sidebar, content].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: view.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),
            content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.topAnchor.constraint(equalTo: content.topAnchor),
            headerHeight,
            // The page list starts below the traffic lights, level with the content.
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            detail.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            detail.topAnchor.constraint(equalTo: header.bottomAnchor),
            detail.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        refreshTypography()
        updateFilter()
        select(section: defaults.string(forKey: SettingsTab.storageKey) ?? SettingsTab.general)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        configureWindowChrome()
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
    override func viewDidLayout() {
        super.viewDidLayout()
        syncHeaderHeight()
    }

    /// The content extends under a transparent unified title bar so the
    /// sidebar reaches the traffic lights and the header row shares their line.
    private func configureWindowChrome() {
        guard let window = view.window, !window.styleMask.contains(.fullSizeContentView) else { return }
        // Keep the window's (possibly restored) frame; only the chrome changes.
        let frame = window.frame
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        if window.toolbar == nil {
            let toolbar = NSToolbar(identifier: "cockpit.settings")
            toolbar.allowsUserCustomization = false
            toolbar.displayMode = .iconOnly
            window.toolbar = toolbar
        }
        window.toolbarStyle = .unified
        window.setFrame(frame, display: false)
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        syncHeaderHeight()
    }

    private func syncHeaderHeight() {
        guard let window = view.window, window.styleMask.contains(.fullSizeContentView) else { return }
        let height = window.frame.height - window.contentLayoutRect.height
        if height > 0, abs((headerHeight?.constant ?? 0) - height) > 0.5 { headerHeight?.constant = height }
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
        if !isNavigatingHistory {
            if historyIndex < history.count - 1 { history.removeSubrange((historyIndex + 1)...) }
            history.append(selected)
            historyIndex = history.count - 1
        }
        pageTitle.stringValue = sections.first { $0.id == selected }?.title ?? ""
        updateSidebarEmphasis()
        updateNavigationButtons()
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
                    controller = UsageSettingsViewController(defaults: defaults, showsPageHeader: false)
                } else {
                    controller = UsageSettingsViewController(defaults: defaults, showsPageHeader: false, detector: { _ in false })
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

    @objc func goBack(_ sender: Any?) { navigateHistory(by: -1) }
    @objc func goForward(_ sender: Any?) { navigateHistory(by: 1) }

    private func navigateHistory(by offset: Int) {
        let target = historyIndex + offset
        guard history.indices.contains(target) else { return }
        historyIndex = target
        isNavigatingHistory = true
        defer { isNavigatingHistory = false }
        if !filtered.contains(where: { $0.id == history[target] }) {
            // A page hidden by the search still opens; clear the filter for it.
            search.stringValue = ""
            updateFilter()
        }
        select(section: history[target])
        updateNavigationButtons()
    }

    private func updateNavigationButtons() {
        backButton.isEnabled = historyIndex > 0
        forwardButton.isEnabled = historyIndex < history.count - 1
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row) else { return nil }
        let section = filtered[row]
        let cell = NSTableCellView()
        cell.identifier = .init("settings.section.\(section.id)")
        let field = NativeSettingsUI.label(section.title)
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        let icon = NSImageView(image: NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil) ?? NSImage())
        let zoom = CGFloat(CockpitUIZoomController.shared.factor)
        icon.symbolConfiguration = .init(pointSize: 16 * zoom, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        icon.setAccessibilityElement(false)
        cell.textField = field
        cell.imageView = icon
        let stack = NativeSettingsUI.row([icon, field], spacing: 8)
        icon.widthAnchor.constraint(equalToConstant: 24 * zoom).isActive = true
        if section.id == currentSection { field.fontWeight = .semibold }
        NativeSettingsUI.pin(stack, to: cell)
        // Content sits inside the rounded selection (PilotSettingsSidebarRowView.selectionInset).
        let inset = PilotSettingsSidebarRowView.selectionInset
        stack.edgeInsets = NSEdgeInsets(top: 0, left: inset + 6, bottom: 0, right: inset + 6)
        return cell
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PilotSettingsSidebarRowView()
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
        let font = CockpitTypography.font(size: 13)
        table.rowHeight = max(28, font.ascender - font.descender + 13)
        if isViewLoaded { table.reloadData(); reselectCurrentRow() }
    }

    private func updateFilter() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filtered = sections.filter { query.isEmpty || $0.searchTerms.localizedCaseInsensitiveContains(query) }
        table.reloadData()
        noResults.isHidden = !filtered.isEmpty
        reselectCurrentRow()
    }

    /// The selected page's title is semibold, like Xcode's Settings sidebar.
    private func updateSidebarEmphasis() {
        for row in 0..<table.numberOfRows {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
                  let field = cell.textField as? CockpitLabel, filtered.indices.contains(row) else { continue }
            field.fontWeight = filtered[row].id == currentSection ? .semibold : .regular
        }
    }

    private func reselectCurrentRow() {
        if let currentSection, let row = filtered.firstIndex(where: { $0.id == currentSection }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }
}

/// Xcode's Settings sidebar keeps accent icons and primary text on a quiet
/// rounded gray selection instead of the vibrant source-list highlight.
@MainActor
private final class PilotSettingsSidebarRowView: NSTableRowView {
    static let selectionInset: CGFloat = 10
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: Self.selectionInset, dy: 0)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        NSColor.labelColor.withAlphaComponent(reduceTransparency ? 0.16 : 0.1).setFill()
        path.fill()
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
        let stack = NativeSettingsUI.column()
        NativeSettingsUI.fillWidth(NativeSettingsUI.group("About", [
            NativeSettingsUI.valueRow("Application", value: AppInfo.name, icon: "macwindow"),
            NativeSettingsUI.valueRow("Version", value: "\(AppInfo.version) (\(AppInfo.build))", icon: "tag"),
            NativeSettingsUI.formRow("Software Update", icon: "arrow.triangle.2.circlepath", accessories: [updateAction.makeButton()]),
        ]), in: stack)
        let setup = NativeSettingsButton("Open…", action: onOpenSetup)
        setup.toolTip = "Review permissions, companion connections, and developer tools."
        NativeSettingsUI.fillWidth(NativeSettingsUI.group("Setup", [
            NativeSettingsUI.formRow("Setup Assistant", icon: "wand.and.stars", accessories: [setup]),
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
            NativeSettingsUI.formRow("Paired Device", subtitle: peerKey, icon: "iphone", status: syncStatus),
            NativeSettingsUI.formRow("This Device", subtitle: localKey, icon: "laptopcomputer", accessories: [regenerate]),
            NativeSettingsUI.formRow("Secure Messaging", icon: "lock.shield",
                                     accessories: [NativeSettingsButton("Open…", action: onOpenMessaging)]),
        ]
        let identityGroup = NativeSettingsUI.group("Identity & Keys", identityRows)
        identityGroup.toolTip = "Your device key is generated automatically and exchanged with your paired device over the encrypted connection."
        NativeSettingsUI.fillWidth(identityGroup, in: stack)
        let diagnostics = ChromiumDiagnosticsViewController()
        addChild(diagnostics)
        NativeSettingsUI.fillWidth(diagnostics.view, in: stack)
        view = NativeSettingsUI.page(stack)
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
