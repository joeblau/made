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
        table.rowHeight = 40
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
            self.table.rowHeight = 40 * CockpitUIZoomController.shared.factor
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

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { CockpitCardRowView(shape: .well) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard servers.indices.contains(row) else { return nil }
        let server = servers[row]
        let name = BrowserNativeUI.label(server.name)
        name.font = CockpitTypography.font(size: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.maximumNumberOfLines = 1
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // One line: name, then the port, shortcut and live status at the trailing edge.
        let port = ServerPortBadge()
        port.port = server.port
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let hotkey = NewTabKeyBadge()
        hotkey.key = row < 9 ? String(row + 1) : nil
        // Keep the shortcut slot when empty so ports align in one column.
        hotkey.alphaValue = row < 9 ? 1 : 0
        hotkey.widthAnchor.constraint(equalToConstant: 24).isActive = true
        hotkey.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let live = liveness[server.port] == true
        let indicator = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: live ? "Listening" : "Not listening") ?? NSImage())
        indicator.contentTintColor = live ? .systemGreen : .tertiaryLabelColor
        indicator.widthAnchor.constraint(equalToConstant: 10).isActive = true
        indicator.heightAnchor.constraint(equalToConstant: 10).isActive = true
        let content = NSStackView(views: [name, spacer, port, hotkey, indicator])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.distribution = .fill
        content.spacing = 8
        content.setCustomSpacing(10, after: port)
        content.setCustomSpacing(12, after: hotkey)
        content.edgeInsets = NSEdgeInsets(top: 6, left: 20, bottom: 6, right: 18)
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

/// A server's port as quiet monospaced text in the row's trailing column.
@MainActor
final class ServerPortBadge: NSView {
    private let label = NSTextField(labelWithString: "")
    var port: Int? { didSet { label.stringValue = port.map(String.init) ?? ""; invalidateIntrinsicContentSize(); needsLayout = true } }

    init() {
        super.init(frame: .zero)
        label.font = .monospacedDigitSystemFont(ofSize: 11 * CGFloat(CockpitUIZoomController.shared.factor), weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        addSubview(label)
        setAccessibilityElement(false)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        let text = label.intrinsicContentSize
        return NSSize(width: ceil(text.width) + 4, height: ceil(text.height))
    }

    override func layout() {
        super.layout()
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
    }
}

/// Covers a browser page that shows nothing (a dev server that is not up,
/// a dead web process, `about:blank`) with the same server list as New Tab,
/// painted in the window's background so it follows light and dark mode.
/// Choosing a server navigates this pane in place; 1–9 open servers, 0 focuses
/// the address field, and R retries the address that failed.
@MainActor
final class BrowserEmptyPageView: NSView {
    let state: BrowserState
    var rootPath: () -> String?
    var onNavigate: ((URL) -> Void)?
    /// Whether keys typed here belong to this pane (it is shown and selected).
    var acceptsKeys: () -> Bool = { true }
    private let source: NewTabLiveSource
    private let heading = CockpitUI.label("", role: .sectionTitle)
    private let reason = CockpitUI.label("", size: 12, color: .secondaryLabelColor)
    private let hint = CockpitUI.label("", size: 11, color: .tertiaryLabelColor)
    private let pageView = NewTabPageView()
    private var content = NewTabContent(rows: [])
    private var highlightedID: String?
    private var isLive = false
    private lazy var observation = CockpitObservation(owner: self) { $0.render() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { !isHidden }

    var rows: [NewTabRow] { content.rows }
    private var page: NewTabPage { .browserServers(state.engine) }

    init(paneID: UUID, state: BrowserState, rootPath: @escaping () -> String?, source: NewTabLiveSource? = nil) {
        self.state = state
        self.rootPath = rootPath
        self.source = source ?? NewTabLiveSource(paneID: paneID)
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityIdentifier("browser.empty-page")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        for label in [heading, reason, hint] {
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
        }
        reason.maximumNumberOfLines = 2
        reason.lineBreakMode = .byWordWrapping
        pageView.onActivate = { [weak self] row in self?.activate(row) }
        pageView.onHover = { [weak self] id in self?.setHighlight(id) }
        [heading, reason, pageView, hint].forEach(addSubview)
        updateBackground()
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit { source.deactivate() }

    /// Starts or stops the server scan and liveness polling.
    func setLive(_ live: Bool) {
        guard live != isLive else { return }
        isLive = live
        if live {
            source.activate(page, rootPath: rootPath())
            observation.start()
        } else {
            observation.stop()
            source.deactivate()
        }
    }

    private func render() {
        // Reading the engine and root here re-renders when either changes.
        let currentRoot = rootPath()
        if isLive { source.activate(page, rootPath: currentRoot) }
        let failure = state.emptyPage
        var next = source.content(for: page)
        if let url = failure?.failedURL {
            next.rows.insert(NewTabRow(id: "retry", title: "Try Again", detail: url.absoluteString,
                                       symbol: "arrow.clockwise", shortcut: "r",
                                       action: .open(.browser(state.engine, url))), at: 0)
        }
        heading.stringValue = Self.heading(for: failure, engine: state.engine)
        reason.stringValue = failure?.reason ?? ""
        reason.isHidden = reason.stringValue.isEmpty
        hint.stringValue = failure?.failedURL == nil ? "Press 1–9 to open a server, 0 for an address"
            : "Press R to try again, 1–9 to open a server, 0 for an address"
        setAccessibilityLabel(heading.stringValue)
        if let highlightedID, !next.rows.contains(where: { $0.id == highlightedID && $0.isSelectable }) { self.highlightedID = nil }
        guard next != content else { return }
        content = next
        pageView.update(rows: next.rows, message: next.message, highlightedID: highlightedID)
        needsLayout = true
    }

    static func heading(for failure: BrowserEmptyPage?, engine: BrowserEngine) -> String {
        guard let url = failure?.failedURL else { return NewTabPage.browserServers(engine).title }
        let host = url.host.map { host in url.port.map { "\(host):\($0)" } ?? host }
        return "Can’t open \(host ?? url.absoluteString)"
    }

    @discardableResult
    func press(_ key: String) -> Bool {
        guard let row = content.rows.first(where: { $0.shortcut == key.lowercased() && $0.isSelectable }) else { return false }
        activate(row)
        return true
    }

    func activate(_ row: NewTabRow) {
        guard row.isSelectable else { return }
        switch row.action {
        case .open(.browser(_, let url?)):
            onNavigate?(url)
        case .open(.browser(_, nil)):
            state.requestAddressFocus()
        default:
            break
        }
    }

    private func setHighlight(_ id: String?) {
        highlightedID = id
        pageView.setHighlight(id)
    }

    private func moveHighlight(by delta: Int) {
        let selectable = content.rows.filter(\.isSelectable)
        guard !selectable.isEmpty else { return }
        let index = selectable.firstIndex { $0.id == highlightedID }
        let next = index.map { min(max($0 + delta, 0), selectable.count - 1) } ?? (delta > 0 ? 0 : selectable.count - 1)
        setHighlight(selectable[next].id)
        pageView.scrollToHighlight()
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    override func keyDown(with event: NSEvent) {
        // Only this focused overlay handles keys, never window-wide shortcuts.
        guard acceptsKeys(), !isHiddenOrHasHiddenAncestor, !event.isARepeat,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event); return
        }
        switch event.keyCode {
        case 125: moveHighlight(by: 1); return // Down Arrow
        case 126: moveHighlight(by: -1); return // Up Arrow
        case 36, 76: // Return, Enter
            if let row = content.rows.first(where: { $0.id == highlightedID }) { activate(row); return }
        default:
            if let key = event.charactersIgnoringModifiers, key.count == 1, press(key) { return }
        }
        super.keyDown(with: event)
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateBackground() }
    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    override func layout() {
        super.layout()
        let zoom = CGFloat(CockpitUIZoomController.shared.factor)
        let width = min(440 * zoom, max(0, bounds.width - 32))
        let left = (bounds.width - width) / 2
        let headingHeight = heading.intrinsicContentSize.height
        let reasonHeight = reason.isHidden ? 0 : ceil(reason.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height)
        let reasonGap: CGFloat = reason.isHidden ? 0 : 6
        let hintHeight = hint.intrinsicContentSize.height
        let chrome = headingHeight + reasonGap + reasonHeight + 20 + 16 + hintHeight
        let listHeight = min(pageView.preferredHeight(width: width), max(0, bounds.height - 24 - chrome))
        var top = max(12, (bounds.height - chrome - listHeight) / 2)
        heading.frame = NSRect(x: left, y: top, width: width, height: headingHeight)
        top += headingHeight + reasonGap
        reason.frame = NSRect(x: left, y: top, width: width, height: reasonHeight)
        top += reasonHeight + 20
        pageView.frame = NSRect(x: left, y: top, width: width, height: listHeight)
        top += listHeight + 16
        hint.frame = NSRect(x: left, y: top, width: width, height: hintHeight)
    }
}
