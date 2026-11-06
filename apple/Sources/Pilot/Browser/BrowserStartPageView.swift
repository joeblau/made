import AppKit

@MainActor
final class BrowserStartPageViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let rootPath: String?
    let onSelect: (LocalServer) -> Void
    private let table = NSTableView()
    private let heading = BrowserNativeUI.label("Local")
    private let zoomObservation = BrowserNativeObservation()
    private let status = BrowserNativeUI.label("Looking for dev servers…", secondary: true)
    private let keyHandler = StartPageKeyHandler()
    private var servers: [LocalServer] = []
    private var liveness: [Int: Bool] = [:]
    private var task: Task<Void, Never>?
    private var scanningDelayTask: Task<Void, Never>?
    private var hasScanned = false
    private var generation = 0
    private var active = false
    private var selected = false

    init(rootPath: String?, onSelect: @escaping (LocalServer) -> Void) {
        self.rootPath = rootPath
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        status.isHidden = !hasScanned
        stack.addArrangedSubview(heading)
        stack.addArrangedSubview(status)
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("server")))
        table.headerView = nil
        table.rowHeight = 72
        table.intercellSpacing = NSSize(width: 0, height: 8)
        table.style = .fullWidth
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(openSelected)
        table.doubleAction = #selector(openSelected)
        table.setAccessibilityLabel("Local development servers")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = table
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        view = stack
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        zoomObservation.start { [weak self] in
            guard let self else { return }
            self.heading.font = CockpitTypography.font(size: 15, weight: .semibold)
            self.status.font = CockpitTypography.font(size: 13)
            self.table.rowHeight = 72 * CockpitUIZoomController.shared.factor
            self.table.reloadData()
        }
    }

    func setPresentation(isActive: Bool, isSelected: Bool) {
        selected = isSelected
        if isActive != active {
            active = isActive
            generation += 1
            task?.cancel()
            scanningDelayTask?.cancel()
            task = nil
            if isActive { refresh() }
        }
        if isActive && isSelected {
            keyHandler.onDigit = { [weak self] digit in
                MainActor.assumeIsolated {
                    guard let self, self.active, self.selected,
                          self.view.window === NSApp.keyWindow,
                          digit > 0, digit <= self.servers.count else { return false }
                    self.onSelect(self.servers[digit - 1])
                    return true
                }
            }
            keyHandler.install()
        } else {
            keyHandler.remove()
        }
    }

    func setActive(_ active: Bool) { setPresentation(isActive: active, isSelected: selected) }

    private func refresh() {
        let path = rootPath ?? ""
        let currentGeneration = generation
        if !hasScanned {
            // Fast scans never flash a loading row.
            scanningDelayTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, self?.generation == currentGeneration else { return }
                self?.status.isHidden = false
            }
        }
        task = Task { @MainActor [weak self] in
            let discovered = await LocalServerScanner.scan(rootPath: path)
            guard !Task.isCancelled, self?.generation == currentGeneration else { return }
            self?.scanningDelayTask?.cancel()
            self?.scanningDelayTask = nil
            self?.hasScanned = true
            self?.status.isHidden = false
            self?.servers = discovered
            self?.status.stringValue = discovered.isEmpty
                ? "No dev servers found in this workspace. Start a local server, or enter a URL in the address bar."
                : "Choose a server, or press its number while this pane is selected."
            self?.table.reloadData()
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

    func numberOfRows(in tableView: NSTableView) -> Int { servers.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard servers.indices.contains(row) else { return nil }
        let server = servers[row]
        let name = BrowserNativeUI.label(server.name)
        name.font = CockpitTypography.font(size: 15, weight: .semibold)
        let address = BrowserNativeUI.label(server.displayURL, secondary: true)
        address.font = CockpitTypography.font(size: 13)
        address.lineBreakMode = .byTruncatingHead
        address.maximumNumberOfLines = 1
        let labels = NSStackView(views: [name, address])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4
        let hotkey = BrowserNativeUI.label(row < 9 ? String(row + 1) : "", secondary: true)
        hotkey.font = CockpitTypography.font(size: 12, weight: .semibold, monospaced: true)
        let live = liveness[server.port] == true
        let indicator = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: live ? "Listening" : "Not listening") ?? NSImage())
        indicator.contentTintColor = live ? .systemGreen : .tertiaryLabelColor
        indicator.widthAnchor.constraint(equalToConstant: 10).isActive = true
        indicator.heightAnchor.constraint(equalToConstant: 10).isActive = true
        let content = NSStackView(views: [labels, hotkey, indicator])
        content.orientation = .horizontal
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
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
        keyHandler.remove()
    }
}

// StartPageKeyHandler — installs an `NSEvent` local key-down monitor while
// the start page is on screen and forwards 1-9 keypresses to the matching
// server card. Skipped while a text editor (address bar, terminal field
// editor) is the first responder so typing isn't hijacked.
//
// AppKit's `addLocalMonitorForEvents` always invokes the handler on the
// main thread. Inspect the event under that actor without transferring
// the non-Sendable NSEvent across isolation boundaries.
@MainActor
final class StartPageKeyHandler {
    /// Returns `true` if the digit was consumed (start page navigated). When
    /// `false`, the event is passed through so default handling fires (e.g.
    /// system beep for an unbound key).
    var onDigit: ((Int) -> Bool)?
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self.map { $0.handle(event) == nil } ?? false }
            return consumed ? nil : event
        }
    }

    func remove() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    isolated deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if let responder = NSApp.keyWindow?.firstResponder, Self.isTextEditor(responder) {
            return event
        }
        let blockedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        guard event.modifierFlags.intersection(blockedModifiers).isEmpty,
              let digit = Self.digit(for: event) else { return event }

        let handled = onDigit?(digit) ?? false
        return handled ? nil : event
    }

    /// Maps a `keyDown` event to a 1...9 digit. Uses hardware `keyCode`
    /// first so layout/IME quirks (AZERTY top row, Dvorak, etc.) don't
    /// break the shortcut, then falls back to the character value to
    /// cover the numeric keypad.
    private static func digit(for event: NSEvent) -> Int? {
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

    /// Only treats *actual* text-input responders as "editors". The earlier
    /// `className.contains("Text")` heuristic was too eager: AppKit ships
    /// plenty of internal responder classes with "Text" in the
    /// name (text input contexts, toolbar item hosts, layout managers) that
    /// can land as `firstResponder` even when nothing is actually being
    /// typed into, which made every digit key fall through to default
    /// handling.
    private static func isTextEditor(_ responder: NSResponder) -> Bool {
        // NSText is the abstract base of NSTextView; an NSTextField's field
        // editor is an NSTextView, so this covers address-field focus.
        if responder is NSText { return true }
        // Ghostty's terminal view implements NSTextInputClient — keys typed
        // into it should reach the terminal, not the start page.
        if String(describing: type(of: responder)).contains("Ghostty") { return true }
        return false
    }
}
