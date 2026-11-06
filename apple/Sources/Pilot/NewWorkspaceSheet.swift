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
    private let selectedPath = NSTextField(labelWithString: "Home folder (~)")
    private let status = NSTextField(labelWithString: "")
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
        let title = shellLabel("New Workspace")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        search.placeholderString = "Search \((finder.root as NSString).abbreviatingWithTildeInPath)"
        search.delegate = self
        search.setAccessibilityLabel("Starting Folder")
        search.target = self
        search.action = #selector(create)
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder")))
        table.headerView = nil
        table.rowHeight = 38
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(create)
        table.setAccessibilityLabel("Matching folders")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.heightAnchor.constraint(equalToConstant: 220).isActive = true
        let choose = ShellActionButton("Choose…") { [weak self] in self?.chooseDirectory() }
        let home = ShellActionButton("Use Home Folder") { [weak self] in
            guard let self else { return }
            self.directory = nil
            self.search.stringValue = ""
            self.finder.setQuery("")
            self.selectedPath.stringValue = "Home folder (~)"
        }
        let cancel = ShellActionButton("Cancel") { [weak self] in self?.finish(create: false) }
        cancel.keyEquivalent = "\u{1b}"
        let create = ShellActionButton("Create") { [weak self] in self?.finish(create: true) }
        create.keyEquivalent = "\r"
        selectedPath.lineBreakMode = .byTruncatingMiddle
        status.textColor = .secondaryLabelColor
        let stack = shellStack([title, shellLabel("Starting Folder", secondary: true), search, scroll,
                                selectedPath, status,
                                shellStack([home, choose, cancel, create], orientation: .horizontal)])
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.setHuggingPriority(.required, for: .vertical)
        window.contentView = stack
        search.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        scroll.widthAnchor.constraint(equalTo: search.widthAnchor).isActive = true
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
        let name = shellLabel(item.name)
        let path = shellLabel((item.path as NSString).abbreviatingWithTildeInPath, secondary: true)
        path.font = .systemFont(ofSize: 10)
        return shellStack([name, path], spacing: 1)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard finder.results.indices.contains(table.selectedRow) else { return }
        directory = URL(fileURLWithPath: finder.results[table.selectedRow].path, isDirectory: true)
        selectedPath.stringValue = (directory!.path as NSString).abbreviatingWithTildeInPath
    }

    func controlTextDidChange(_ notification: Notification) { finder.setQuery(search.stringValue) }

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
                self.status.stringValue = self.finder.isIndexing ? "Indexing folders…" : (self.finder.results.isEmpty && !self.search.stringValue.isEmpty ? "No matching folders" : "")
                if !self.search.stringValue.isEmpty, !self.finder.results.isEmpty {
                    self.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
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
            self.selectedPath.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }

    @objc private func create() { finish(create: true) }

    private func finish(create: Bool) {
        guard !isFinished else { return }
        isFinished = true
        observedGeneration += 1
        if let window { window.sheetParent?.endSheet(window); window.orderOut(nil) }
        if create { onCreate(directory) }
        onDismiss?()
    }
}
