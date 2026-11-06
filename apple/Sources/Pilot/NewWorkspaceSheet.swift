import AppKit
import Observation

struct NewWorkspaceRequest: Identifiable {
    let id = UUID()
    var groupID: UUID?
}

@MainActor
final class NewWorkspaceSheet: NSWindowController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let finder: DirectoryFinder
    private let onCreate: (URL?) -> Void
    private let search = NSSearchField()
    private let table = NSTableView()
    private let selectedName = CockpitUI.label("Home Folder", role: .sectionTitle)
    private let selectedPath = CockpitUI.label("~", role: .caption, color: .secondaryLabelColor)
    private let resultsHost = NSView()
    private let scroll = NSScrollView()
    private let status = CockpitUI.label("", role: .caption, color: .secondaryLabelColor)
    private var contentStack: NSStackView!
    private var resultsHeight: NSLayoutConstraint!
    private var zoomObserver: NSObjectProtocol?
    private var sizingTask: Task<Void, Never>?
    private var directory: URL?
    private var isFinished = false
    private var observedGeneration = 0
    var onDismiss: (() -> Void)?

    init(finder: DirectoryFinder = DirectoryFinder(), onCreate: @escaping (URL?) -> Void) {
        self.finder = finder
        self.onCreate = onCreate
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 430),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "New Workspace"
        super.init(window: window)
        let title = CockpitUI.label("New Workspace", role: .windowTitle)
        let subtitle = CockpitUI.label("Choose where your workspace starts.", role: .body, color: .secondaryLabelColor)
        let icon = NSImageView(image: NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 32, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        icon.widthAnchor.constraint(equalToConstant: 44).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let heading = shellStack([icon, shellStack([title, subtitle], spacing: 4)], orientation: .horizontal, spacing: 12)
        search.placeholderString = "Search folders"
        search.toolTip = "Search \((finder.root as NSString).abbreviatingWithTildeInPath)"
        search.controlSize = .large
        search.delegate = self
        search.setAccessibilityLabel("Search workspace folders")
        search.target = self
        search.action = #selector(create)
        let fieldLabel = CockpitUI.label("Starting folder", role: .caption)
        let searchGroup = shellStack([fieldLabel, search], spacing: 6)
        search.widthAnchor.constraint(equalTo: searchGroup.widthAnchor).isActive = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil
        table.rowHeight = 44
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(create)
        table.setAccessibilityLabel("Matching folders")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        resultsHeight = resultsHost.heightAnchor.constraint(equalToConstant: 164)
        resultsHeight.isActive = true
        resultsHost.addSubview(scroll)
        scroll.cockpitPinToEdges(of: resultsHost)
        status.alignment = .center
        status.translatesAutoresizingMaskIntoConstraints = false
        resultsHost.addSubview(status)
        NSLayoutConstraint.activate([
            status.centerXAnchor.constraint(equalTo: resultsHost.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: resultsHost.centerYAnchor),
            status.widthAnchor.constraint(lessThanOrEqualTo: resultsHost.widthAnchor, constant: -24),
        ])
        resultsHost.isHidden = true
        let choose = CockpitActionButton(title: "Browse…") { [weak self] in self?.chooseDirectory() }
        choose.controlSize = .small
        choose.setContentHuggingPriority(.required, for: .horizontal)
        let folderIcon = NSImageView(image: NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil) ?? NSImage())
        folderIcon.contentTintColor = .controlAccentColor
        folderIcon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let labels = shellStack([selectedName, selectedPath], spacing: 3)
        labels.setHuggingPriority(.defaultLow, for: .horizontal)
        for label in [selectedName, selectedPath] {
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        }
        let selectedRow = shellStack([folderIcon, labels, choose], orientation: .horizontal, spacing: 12)
        selectedRow.distribution = .fill
        let selection = CockpitCardView(content: selectedRow, padding: 12)
        selection.setAccessibilityIdentifier("workspace.selected-folder")
        let home = CockpitActionButton(title: "Use Home Folder") { [weak self] in
            guard let self else { return }
            self.directory = nil
            self.search.stringValue = ""
            self.finder.setQuery("")
            self.updateSelection()
            self.updateResults()
        }
        home.isBordered = false
        home.contentTintColor = .controlAccentColor
        home.controlSize = .small
        let cancel = CockpitActionButton(title: "Cancel") { [weak self] in self?.finish(create: false) }
        cancel.keyEquivalent = "\u{1b}"
        let create = CockpitActionButton(title: "Create") { [weak self] in self?.finish(create: true) }
        create.keyEquivalent = "\r"
        cancel.controlSize = .large
        create.controlSize = .large
        let actions = shellStack([home, NSView(), cancel, create], orientation: .horizontal, spacing: 8)
        actions.distribution = .fill
        let stack = shellStack([heading, searchGroup, resultsHost, selection, CockpitUI.divider(), actions], spacing: 16)
        contentStack = stack
        let root = NSView()
        root.addSubview(stack)
        stack.cockpitPinToEdges(of: root, insets: NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24))
        for child in stack.arrangedSubviews { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        window.contentView = root
        updateSize()
        zoomObserver = NotificationCenter.default.addObserver(
            forName: .cockpitUIZoomDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Measure after the existing controls have updated their fonts.
                // Retain the field editor and its selection during live zoom.
                self?.sizingTask?.cancel()
                self?.sizingTask = Task { @MainActor [weak self] in
                    guard !Task.isCancelled, let self, !self.isFinished else { return }
                    self.updateSize()
                }
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    func present(on parent: NSWindow) {
        guard let window else { return }
        finder.setQuery("")
        finder.start()
        observeResults()
        parent.beginSheet(window)
        window.makeFirstResponder(search)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { finder.results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard finder.results.indices.contains(row) else { return nil }
        let item = finder.results[row]
        let name = CockpitUI.label(item.name, role: .body)
        let path = CockpitUI.label((item.path as NSString).abbreviatingWithTildeInPath,
                                   role: .caption, color: .secondaryLabelColor)
        name.lineBreakMode = .byTruncatingTail
        path.lineBreakMode = .byTruncatingMiddle
        let labels = shellStack([name, path], spacing: 2)
        for label in [name, path] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        }
        return labels
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard finder.results.indices.contains(table.selectedRow) else { return }
        directory = URL(fileURLWithPath: finder.results[table.selectedRow].path, isDirectory: true)
        updateSelection()
    }

    func controlTextDidChange(_ notification: Notification) {
        finder.setQuery(search.stringValue)
        updateResults()
    }

    private func updateSelection() {
        selectedName.stringValue = directory?.lastPathComponent ?? "Home Folder"
        selectedPath.stringValue = directory.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "~"
        selectedPath.toolTip = directory?.path ?? NSHomeDirectory()
    }

    private func updateResults() {
        let show = !search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        resultsHost.isHidden = !show
        scroll.isHidden = finder.results.isEmpty
        status.isHidden = !finder.results.isEmpty
        status.stringValue = finder.isIndexing ? "Searching folders…" : "No matching folders. Try Browse instead."
        updateSize()
    }

    private func updateSize() {
        guard let window else { return }
        let zoom = CockpitUIZoomController.shared.factor
        table.rowHeight = 44 * zoom
        search.font = CockpitTypography.font(.body)
        resultsHeight.constant = min(240, max(88, CGFloat(max(1, finder.results.count)) * table.rowHeight + 8))
        // Size to the controls instead of fixed dialog heights: zoomed text and
        // native button metrics can grow independently of the results viewport.
        let visible = contentStack.arrangedSubviews.filter { !$0.isHidden }
        let height = visible.reduce(CGFloat(48)) { $0 + ceil($1.fittingSize.height) }
            + CGFloat(max(0, visible.count - 1)) * contentStack.spacing
        let size = NSSize(width: max(520, min(760, 520 * zoom)), height: max(310, height))
        if window.contentView?.bounds.size != size { window.setContentSize(size) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)) { moveSelection(1); return true }
        if commandSelector == #selector(NSResponder.moveUp(_:)) { moveSelection(-1); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { finish(create: false); return true }
        return false
    }

    private func moveSelection(_ delta: Int) {
        guard !finder.results.isEmpty else { return }
        let row = min(max(table.selectedRow + delta, 0), finder.results.count - 1)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func observeResults() {
        guard !isFinished else { return }
        observedGeneration += 1
        let generation = observedGeneration
        withObservationTracking {
            _ = finder.results
            _ = finder.isIndexing
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isFinished, self.observedGeneration == generation else { return }
                self.table.reloadData()
                self.updateResults()
                if !self.search.stringValue.isEmpty, !self.finder.results.isEmpty {
                    let row = self.finder.results.firstIndex { $0.path == self.directory?.path } ?? 0
                    self.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
                self.observeResults()
            }
        }
    }

    private func chooseDirectory() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a workspace folder"
        panel.prompt = "Use Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.search.stringValue = ""
            self.finder.setQuery("")
            self.directory = url
            self.updateSelection()
            self.updateResults()
        }
    }

    @objc private func create() { finish(create: true) }

    private func finish(create: Bool) {
        guard !isFinished else { return }
        isFinished = true
        sizingTask?.cancel()
        observedGeneration += 1
        if let window { window.sheetParent?.endSheet(window); window.orderOut(nil) }
        if create { onCreate(directory) }
        onDismiss?()
    }

    isolated deinit {
        sizingTask?.cancel()
        if let zoomObserver { NotificationCenter.default.removeObserver(zoomObserver) }
    }
}
