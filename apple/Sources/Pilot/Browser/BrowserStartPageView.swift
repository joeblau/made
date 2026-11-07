import AppKit

@MainActor
final class BrowserStartPageViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let rootPath: String?
    let onSelect: (LocalServer) -> Void
    private let state: BrowserState
    private let table = BrowserStartPageTable()
    private let enginePicker = NSSegmentedControl()
    private let shortcuts = BrowserNativeUI.label("S Safari · C Chrome · 1–9 Open", secondary: true)
    private let heading = BrowserNativeUI.label("Local Servers")
    private let zoomObservation = BrowserNativeObservation()
    private let status = BrowserNativeUI.label("Looking for dev servers…", secondary: true)
    private var servers: [LocalServer] = []
    private var liveness: [Int: Bool] = [:]
    private var task: Task<Void, Never>?
    private var scanningDelayTask: Task<Void, Never>?
    private var hasScanned = false
    private var generation = 0
    private var active = false
    private var selected = false

    init(rootPath: String?, state: BrowserState, onSelect: @escaping (LocalServer) -> Void) {
        self.rootPath = rootPath
        self.state = state
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        let stack = BrowserStartPageStack()
        stack.onKey = { [weak self] in self?.handleKey($0) ?? false }
        table.onKey = stack.onKey
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        status.isHidden = !hasScanned
        enginePicker.segmentCount = 2
        enginePicker.setLabel("Safari", forSegment: 0)
        enginePicker.setLabel("Chrome", forSegment: 1)
        enginePicker.trackingMode = .selectOne
        enginePicker.segmentStyle = .rounded
        enginePicker.controlSize = .small
        enginePicker.target = self
        enginePicker.action = #selector(engineChanged)
        enginePicker.setAccessibilityLabel("Browser engine")
        enginePicker.setToolTip("Press S for Safari", forSegment: 0)
        stack.addArrangedSubview(enginePicker)
        stack.addArrangedSubview(shortcuts)
        stack.addArrangedSubview(heading)
        stack.addArrangedSubview(status)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("server"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil
        table.rowHeight = 52
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.style = .fullWidth
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(openSelected)
        table.doubleAction = #selector(openSelected)
        table.setAccessibilityLabel("Local development servers")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = table
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        status.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true
        heading.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true
        shortcuts.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true
        shortcuts.lineBreakMode = .byWordWrapping
        shortcuts.maximumNumberOfLines = 0
        enginePicker.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor).isActive = true
        enginePicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.maximumNumberOfLines = 0
        status.lineBreakMode = .byWordWrapping
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        view = stack
        synchronizeEngine()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        zoomObservation.start { [weak self] in
            guard let self else { return }
            self.enginePicker.font = CockpitTypography.font(size: 12)
            self.shortcuts.font = CockpitTypography.font(size: 11)
            self.heading.font = CockpitTypography.font(size: 13, weight: .semibold)
            self.status.font = CockpitTypography.font(size: 12)
            self.table.rowHeight = 52 * CockpitUIZoomController.shared.factor
            self.table.reloadData()
        }
    }

    func setPresentation(isActive: Bool, isSelected: Bool) {
        selected = isSelected
        synchronizeEngine()
        if isActive != active {
            active = isActive
            generation += 1
            task?.cancel()
            scanningDelayTask?.cancel()
            task = nil
            if isActive { refresh() }
        }
    }

    func focusInput() { view.window?.makeFirstResponder(table) }

    private func synchronizeEngine() {
        enginePicker.selectedSegment = state.engine == .webKit ? 0 : 1
        enginePicker.setEnabled(ChromiumBrowserCreationPolicy.isCreationEnabled, forSegment: 1)
        enginePicker.setToolTip(ChromiumBrowserCreationPolicy.unavailableReason?.message ?? "Press C for Chrome", forSegment: 1)
    }

    @objc private func engineChanged() {
        selectEngine(enginePicker.selectedSegment == 1 ? .chromium : .webKit)
        focusInput()
    }

    private func selectEngine(_ engine: BrowserEngine) {
        guard engine == .webKit || ChromiumBrowserCreationPolicy.isCreationEnabled else { synchronizeEngine(); return }
        state.engine = engine
        _ = state.modelContext?.saveReporting(operation: "Choosing browser engine")
        synchronizeEngine()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard active, selected, !view.isHiddenOrHasHiddenAncestor,
              view.window?.attachedSheet == nil, !event.isARepeat,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "s": selectEngine(.webKit); return true
        case "c": selectEngine(.chromium); return true
        default:
            guard let digit = StartPageKeyHandler.digit(for: event), digit <= servers.count else { return false }
            onSelect(servers[digit - 1])
            return true
        }
    }

    func setActive(_ active: Bool) { setPresentation(isActive: active, isSelected: selected) }

    private func refresh() {
        let path = rootPath ?? ""
        let currentGeneration = generation
        let catalog = LocalServerCatalog.shared
        if let cached = catalog.cached(rootPath: path) {
            // A known workspace shows its list at once; a stale one refreshes quietly.
            show(cached)
        } else if !hasScanned {
            // Fast scans never flash a loading row.
            scanningDelayTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, self?.generation == currentGeneration else { return }
                self?.status.isHidden = false
            }
        }
        task = Task { @MainActor [weak self] in
            let discovered = await catalog.servers(rootPath: path)
            guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
            if !self.hasScanned || self.servers != discovered { self.show(discovered) }
            await LocalServerLivenessMonitor.monitor(servers: discovered) { [weak self] latest in
                guard let self, self.generation == currentGeneration, self.liveness != latest else { return }
                let changedRows = IndexSet(self.servers.indices.filter {
                    self.liveness[self.servers[$0].port] != latest[self.servers[$0].port]
                })
                self.liveness = latest
                self.table.reloadData(forRowIndexes: changedRows, columnIndexes: IndexSet(integer: 0))
            }
        }
    }

    private func show(_ discovered: [LocalServer]) {
        scanningDelayTask?.cancel()
        scanningDelayTask = nil
        hasScanned = true
        status.isHidden = false
        servers = discovered
        status.stringValue = discovered.isEmpty
            ? "No dev servers found in this workspace. Start a local server, or enter a URL in the address bar."
            : "Choose a server, or use its 1–9 shortcut."
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { servers.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { CockpitCardRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard servers.indices.contains(row) else { return nil }
        let server = servers[row]
        let name = BrowserNativeUI.label(server.name)
        name.font = CockpitTypography.font(size: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.maximumNumberOfLines = 1
        let address = BrowserNativeUI.label(server.displayURL, secondary: true)
        address.font = CockpitTypography.font(size: 11)
        address.lineBreakMode = .byTruncatingHead
        address.maximumNumberOfLines = 1
        let labels = NSStackView(views: [name, address])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        for label in [name, address] {
            label.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        labels.setHuggingPriority(.defaultLow, for: .horizontal)
        let hotkey = BrowserNativeUI.label(row < 9 ? String(row + 1) : "", secondary: true)
        hotkey.font = CockpitTypography.font(size: 12, weight: .semibold, monospaced: true)
        hotkey.setContentHuggingPriority(.required, for: .horizontal)
        hotkey.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let live = liveness[server.port] == true
        let indicator = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: live ? "Listening" : "Not listening") ?? NSImage())
        indicator.contentTintColor = live ? .systemGreen : .tertiaryLabelColor
        indicator.widthAnchor.constraint(equalToConstant: 10).isActive = true
        indicator.heightAnchor.constraint(equalToConstant: 10).isActive = true
        let content = NSStackView(views: [labels, hotkey, indicator])
        content.orientation = .horizontal
        content.distribution = .fill
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        content.toolTip = server.url.absoluteString
        content.setAccessibilityLabel("\(server.name), \(server.displayURL), \(live ? "listening" : "not listening")")
        return content
    }

    @objc private func openSelected() {
        guard servers.indices.contains(table.selectedRow) else { return }
        onSelect(servers[table.selectedRow])
    }

    isolated deinit {
        zoomObservation.stop()
        task?.cancel()
        scanningDelayTask?.cancel()
    }
}

/// Shortcuts are scoped to the server list's responder chain. Address fields,
/// terminals, inspectors and loaded web apps receive normal text input.
@MainActor
private final class BrowserStartPageStack: NSStackView {
    var onKey: ((NSEvent) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}

@MainActor
private final class BrowserStartPageTable: NSTableView {
    var onKey: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}

@MainActor
private enum StartPageKeyHandler {
    /// Maps a `keyDown` event to a 1...9 digit. Uses hardware `keyCode`
    /// first so layout/IME quirks (AZERTY top row, Dvorak, etc.) don't
    /// break the shortcut, then falls back to the character value to
    /// cover the numeric keypad.
    static func digit(for event: NSEvent) -> Int? {
        // kVK_ANSI_1...9 keycodes in digit order. 5 and 6 are swapped
        // on the hardware (kVK_ANSI_5 = 23, kVK_ANSI_6 = 22).
        let digitRowKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        if let index = digitRowKeyCodes.firstIndex(of: event.keyCode) {
            return index + 1
        }
        if let chars = event.charactersIgnoringModifiers,
           chars.count == 1,
           let digit = chars.first?.wholeNumberValue,
           (1...9).contains(digit) {
            return digit
        }
        return nil
    }

}
