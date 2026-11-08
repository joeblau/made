import AppKit
import CodeEditSourceEditor
import Observation

enum EditorViewportPolicy {
    static let findPanelHeight: CGFloat = 28

    static func normalizedWrappedScrollPosition(_ position: CGPoint?) -> CGPoint? {
        guard var position else { return nil }
        position.x = 0
        return position
    }

    static func adjustedScrollPosition(
        _ position: CGPoint?, findPanelWasVisible: Bool, findPanelIsVisible: Bool
    ) -> CGPoint? {
        guard findPanelWasVisible != findPanelIsVisible else { return position }
        var position = position ?? .zero
        position.y += findPanelIsVisible ? -findPanelHeight : findPanelHeight
        return position
    }
}

@MainActor
enum EditorFindPanelHitTestingPolicy {
    @discardableResult
    static func bringFindPanelsToFront(in rootView: NSView) -> Int {
        bringFindPanelsToFront(in: rootView) {
            NSStringFromClass(type(of: $0)).hasSuffix(".NativeFindPanelView")
        }
    }

    @discardableResult
    static func bringFindPanelsToFront(
        in rootView: NSView, matching isFindPanel: (NSView) -> Bool
    ) -> Int {
        var pending = [rootView]
        var repairCount = 0
        while let container = pending.popLast() {
            pending.append(contentsOf: container.subviews)
            for child in container.subviews where isFindPanel(child) && container.subviews.last !== child {
                container.addSubview(child, positioned: .above, relativeTo: nil)
                repairCount += 1
            }
        }
        return repairCount
    }
}

/// Owns the native editor and its document independently of attachment to a workspace window.
@MainActor
final class EditorPaneViewController: NSViewController, CockpitPanePresenting, CockpitPaneClosing, CockpitPaneContextUpdating, CockpitPaneInputFocusing,
    CockpitPaneCloseValidating, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate,
    NSUserInterfaceValidations {
    let session: EditorDocumentSession
    let state: EditorState
    var onSelect: (() -> Void)?

    private weak var pane: Pane?
    private var rootPath: String?
    private let finder: FileFinder
    private var editor: TextViewController?
    private var textCoordinator: NativeEditorTextCoordinator?
    private var loadedDocumentID: UInt64?
    private var selected = false
    private var active = false
    private var started = false
    private var closed = false
    private var finding = false
    private var conflictAlert: NSAlert?
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var scrollObserver: NSObjectProtocol?
    private var displayedFiles: [FileItem] = []
    private var displayedQuery = ""
    private var lastRoot: String?
    private var loadingURL: URL?
    private var requestedStateURL: URL?

    private let editorHost = NSView()
    private let emptyView = NSStackView()
    private let errorRow = NSStackView()
    private let errorLabel = CockpitUI.label("")
    private let palette = NSVisualEffectView()
    private let searchField = NSSearchField()
    /// Back to New Tab, offered until the first file opens.
    private let backButton = NSButton()
    private let results = NSTableView()
    private let resultsScroll = NSScrollView()
    private let finderStatus = CockpitUI.label("", color: .secondaryLabelColor)
    private var paletteHeight: NSLayoutConstraint!
    private var searchLeading: NSLayoutConstraint!

    convenience init(pane: Pane, rootPath: String?) {
        let state = pane.editorState ?? EditorState()
        if pane.editorState == nil { pane.editorState = state }
        self.init(state: state, rootPath: rootPath)
        self.pane = pane
    }

    init(state: EditorState, rootPath: String?, session: EditorDocumentSession = EditorDocumentSession(), finder: FileFinder = FileFinder()) {
        self.state = state
        self.rootPath = rootPath
        self.session = session
        self.finder = finder
        super.init(nibName: nil, bundle: nil)
        session.attach(store: state)
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func loadView() {
        let root = NativeEditorRootView()
        root.onAppearanceChange = { [weak self] in self?.updateAppearance() }
        view = root
        view.setAccessibilityIdentifier("editor.pane")
        editorHost.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(editorHost)
        NSLayoutConstraint.activate([
            editorHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            editorHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            editorHost.topAnchor.constraint(equalTo: view.topAnchor),
            editorHost.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        buildEmptyView()
        buildErrorRow()
        buildFinder()
        observers.append(NotificationCenter.default.addObserver(
            forName: .cockpitUIZoomDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateAppearance() }
        })
        updateAppearance()
        observe()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startIfNeeded()
        refresh()
        if active && selected { focusCurrentSurface() }
    }

    func updatePresentation(isActive: Bool, isSelected: Bool) {
        let becameSelected = isActive && isSelected && (!active || !selected)
        active = isActive
        selected = isSelected
        guard !closed else { return }
        _ = view
        updateRootPath(pane?.workspace?.effectiveRootPath ?? rootPath)
        if active {
            startIfNeeded()
            installEventMonitor()
            if becameSelected { focusCurrentSurface() }
        } else {
            removeEventMonitor()
        }
    }

    func updateRootPath(_ root: String?) {
        rootPath = root
        guard lastRoot != root else { return }
        lastRoot = root
        if finding {
            if let root { finder.start(root: root) } else { finder.reset() }
        }
    }

    func updateContext(rootPath: String?) { updateRootPath(rootPath) }

    func focusPaneInput() { focusCurrentSurface() }

    var isReadyToClose: Bool { !session.isDirty }

    func prepareToClose(_ completion: @escaping @MainActor (Bool) -> Void) {
        // A close is not an explicit Save command. Untouched documents can
        // be read-only or have changed on disk without needing an overwrite.
        // The editor coordinator publishes marked-text edits synchronously,
        // so an in-progress composition still enters the dirty save path.
        guard session.isDirty else { completion(true); return }
        Task { [weak self] in
            guard let self else { completion(true); return }
            let outcome = await self.session.save(.interactive)
            switch outcome {
            case .saved, .clean, .noDocument:
                // Edits made while the write was in flight remain dirty.
                completion(!self.session.isDirty)
            case .conflict, .failed:
                self.refresh()
                completion(false)
            }
        }
    }

    func closePane() {
        guard !closed else { return }
        closed = true
        removeEventMonitor()
        finder.reset()
        session.close()
        if let alert = conflictAlert, let window = alert.window.sheetParent {
            window.endSheet(alert.window, returnCode: .abort)
        }
        conflictAlert = nil
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    private func startIfNeeded() {
        guard !started, !closed else { return }
        started = true
        if let url = state.fileURL { openFile(url) } else { presentFinder(resetQuery: true) }
    }

    private func observe() {
        guard !closed else { return }
        withObservationTracking {
            _ = session.document
            _ = session.errorMessage
            _ = session.conflictPending
            _ = session.isDirty
            _ = finder.results
            _ = finder.resultsQuery
            _ = finder.isIndexing
            _ = state.filePath
            _ = pane?.workspace?.effectiveRootPath
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                self.refresh()
                self.observe()
            }
        }
    }

    private func refresh() {
        guard isViewLoaded, !closed else { return }
        updateRootPath(pane?.workspace?.effectiveRootPath ?? rootPath)
        if let url = state.fileURL, url != session.url, url != loadingURL,
           url != requestedStateURL, started {
            openFile(url)
        }
        if let document = session.document, document.id != loadedDocumentID {
            installDocument()
        }
        emptyView.isHidden = session.document != nil || finding
        errorRow.isHidden = session.errorMessage == nil
        errorLabel.stringValue = session.errorMessage ?? ""
        refreshFinder()
        if session.conflictPending { presentConflict() }
    }

    private func installDocument() {
        guard let document = session.document, document.id != loadedDocumentID else { return }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        editor?.view.removeFromSuperview()
        editor?.removeFromParent()
        let coordinator = NativeEditorTextCoordinator { [weak self] controller in
            guard let self else { return }
            if self.session.updateText(controller.text) { self.selectPane() }
        }
        let controller = TextViewController(
            string: session.text,
            language: session.language,
            configuration: configuration(),
            // The native text engine does not create a selection on focus.
            // Establish an insertion point for keyboard-first typing and IME.
            cursorPositions: [CursorPosition(range: NSRange(location: 0, length: 0))],
            coordinators: [coordinator]
        )
        textCoordinator = coordinator
        editor = controller
        loadedDocumentID = document.id
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        editorHost.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: editorHost.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: editorHost.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: editorHost.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: editorHost.bottomAnchor)
        ])
        controller.textView.setAccessibilityLabel("Source editor")
        scrollObserver = NotificationCenter.default.addObserver(
            forName: TextViewController.scrollPositionDidUpdateNotification, object: controller, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.normalizeWrappedScroll() }
        }
        emptyView.isHidden = true
        if active && selected && !finding { focusCurrentSurface() }
    }

    private func configuration() -> SourceEditorConfiguration {
        let zoom = CockpitUIZoomController.shared.factor
        return SourceEditorConfiguration(
            appearance: .init(
                theme: PilotEditorTheme.theme(for: view.effectiveAppearance),
                font: .monospacedSystemFont(ofSize: 12 * zoom, weight: .regular),
                wrapLines: true
            ),
            behavior: .init(indentOption: .spaces(count: 4)),
            layout: .init(contentInsets: NSEdgeInsets())
        )
    }

    private func updateAppearance() {
        guard isViewLoaded else { return }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            errorRow.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
        searchField.font = CockpitTypography.font(size: NSFont.systemFontSize)
        results.rowHeight = 42 * CockpitUIZoomController.shared.factor
        refreshFinder()
        guard let editor else { return }
        let newConfiguration = configuration()
        if editor.configuration != newConfiguration { editor.configuration = newConfiguration }
        normalizeWrappedScroll()
    }

    private func normalizeWrappedScroll() {
        guard let scroll = editor?.scrollView else { return }
        let point = scroll.contentView.bounds.origin
        guard point.x != 0 else { return }
        scroll.contentView.scroll(to: CGPoint(x: 0, y: point.y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func openFile(_ url: URL) {
        requestedStateURL = url
        loadingURL = url
        session.requestOpen(url) { [weak self] outcome in
            guard let self else { return }
            self.loadingURL = nil
            switch outcome {
            case .loaded:
                self.installDocument()
                self.dismissFinder()
                self.selectPane()
                self.focusCurrentSurface()
            case .blockedBySave, .blockedByEdits:
                self.dismissFinder()
            case .tooLarge, .binary, .failed:
                self.presentFinder(resetQuery: false)
            case .superseded:
                break
            }
            self.refresh()
        }
    }

    @objc func saveDocument(_ sender: Any?) { session.requestSave(.interactive) }
    @objc func openDocument(_ sender: Any?) {
        guard active else { return }
        selectPane()
        presentFinder(resetQuery: true)
    }
    @objc func showFindPanel(_ sender: Any?) { editor?.showNativeFindPanel() }
    @objc func findNext(_ sender: Any?) { editor?.findNextNativeMatch() }
    @objc func findPrevious(_ sender: Any?) { editor?.findPreviousNativeMatch() }
    @objc func useSelectionForFind(_ sender: Any?) { editor?.useSelectionForNativeFind() }

    @objc func performFindPanelAction(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? NSTextFinder.Action.showFindInterface.rawValue
        switch tag {
        case NSTextFinder.Action.nextMatch.rawValue: findNext(sender)
        case NSTextFinder.Action.previousMatch.rawValue: findPrevious(sender)
        case NSTextFinder.Action.setSearchString.rawValue: useSelectionForFind(sender)
        case NSTextFinder.Action.showReplaceInterface.rawValue: editor?.showNativeFindPanel(replacing: true)
        case NSTextFinder.Action.hideFindInterface.rawValue: editor?.hideNativeFindPanel()
        default: showFindPanel(sender)
        }
    }

    override func performTextFinderAction(_ sender: Any?) { performFindPanelAction(sender) }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard active && selected else { return false }
        switch item.action {
        case #selector(openDocument(_:)): return true
        case #selector(saveDocument(_:)), #selector(showFindPanel(_:)), #selector(performFindPanelAction(_:)),
             #selector(findNext(_:)), #selector(findPrevious(_:)), #selector(useSelectionForFind(_:)):
            return session.document != nil
        default: return false
        }
    }

    private func selectPane() {
        if let pane { pane.workspace?.selectedPaneID = pane.id }
        onSelect?()
    }

    private func focusCurrentSurface() {
        guard active && selected, view.window?.isKeyWindow == true else { return }
        if finding {
            view.window?.makeFirstResponder(searchField)
        } else if let editor {
            view.window?.makeFirstResponder(editor.textView)
        }
    }

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self, self.active, event.window === self.view.window,
                  self.view.window?.isKeyWindow == true else { return event }
            if event.type == .leftMouseDown {
                if self.view.bounds.contains(self.view.convert(event.locationInWindow, from: nil)) { self.selectPane() }
                return event
            }
            guard self.selected else { return event }
            guard let responder = self.view.window?.firstResponder as? NSView,
                  responder === self.view || responder.isDescendant(of: self.view) ||
                    responder === self.searchField.currentEditor() else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers == .command {
                switch event.charactersIgnoringModifiers {
                case "s": self.saveDocument(nil); return nil
                case "p", "o": self.openDocument(nil); return nil
                case "f": self.showFindPanel(nil); return nil
                case "g": self.findNext(nil); return nil
                case "e": self.useSelectionForFind(nil); return nil
                default: break
                }
            } else if modifiers == [.command, .shift], event.charactersIgnoringModifiers == "g" {
                self.findPrevious(nil)
                return nil
            }
            return event
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }

    private func buildEmptyView() {
        let title = CockpitUI.label("No File Open", size: 20, weight: .semibold)
        let hint = CockpitUI.label("⌘P to find a file", color: .secondaryLabelColor)
        let button = CockpitActionButton(title: "Find File…") { [weak self] in self?.openDocument(nil) }
        emptyView.orientation = .vertical
        emptyView.spacing = 10
        [title, hint, button].forEach(emptyView.addArrangedSubview)
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyView)
        NSLayoutConstraint.activate([
            emptyView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyView.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -20)
        ])
    }

    private func buildErrorRow() {
        errorRow.orientation = .horizontal
        errorRow.spacing = 8
        errorRow.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        errorRow.wantsLayer = true
        errorRow.layer?.cornerRadius = 8
        errorRow.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        errorLabel.maximumNumberOfLines = 3
        errorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let dismiss = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss error")!,
                               target: self, action: #selector(dismissError))
        dismiss.isBordered = false
        [errorLabel, dismiss].forEach(errorRow.addArrangedSubview)
        errorRow.translatesAutoresizingMaskIntoConstraints = false
        errorRow.isHidden = true
        view.addSubview(errorRow)
        NSLayoutConstraint.activate([
            errorRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            errorRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            errorRow.topAnchor.constraint(equalTo: view.topAnchor, constant: 8)
        ])
    }

    @objc private func dismissError() { session.errorMessage = nil }

    private func buildFinder() {
        palette.material = .popover
        palette.blendingMode = .withinWindow
        palette.state = .active
        palette.wantsLayer = true
        palette.layer?.cornerRadius = 12
        palette.layer?.masksToBounds = true
        palette.translatesAutoresizingMaskIntoConstraints = false
        palette.isHidden = true
        view.addSubview(palette)
        searchField.placeholderString = "Search files…"
        searchField.setAccessibilityLabel("Find a file")
        searchField.setAccessibilityIdentifier("editor.quick-open.search")
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        palette.addSubview(searchField)
        backButton.bezelStyle = .accessoryBarAction
        backButton.isBordered = false
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        backButton.imagePosition = .imageOnly
        backButton.contentTintColor = .secondaryLabelColor
        backButton.target = self
        backButton.action = #selector(returnToNewTab)
        backButton.toolTip = "Back to New Tab (Esc)"
        backButton.setAccessibilityLabel("Back to New Tab")
        backButton.setAccessibilityIdentifier("editor.quick-open.back")
        backButton.translatesAutoresizingMaskIntoConstraints = false
        palette.addSubview(backButton)
        searchLeading = searchField.leadingAnchor.constraint(equalTo: palette.leadingAnchor, constant: 10)
        results.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file")))
        results.headerView = nil
        results.rowHeight = 42
        results.intercellSpacing = .zero
        results.allowsEmptySelection = false
        results.dataSource = self
        results.delegate = self
        results.target = self
        results.action = #selector(openSelected)
        results.setAccessibilityLabel("Matching files")
        results.setAccessibilityIdentifier("editor.quick-open.results")
        resultsScroll.documentView = results
        resultsScroll.hasVerticalScroller = true
        resultsScroll.drawsBackground = false
        resultsScroll.translatesAutoresizingMaskIntoConstraints = false
        palette.addSubview(resultsScroll)
        finderStatus.textColor = .secondaryLabelColor
        finderStatus.translatesAutoresizingMaskIntoConstraints = false
        palette.addSubview(finderStatus)
        paletteHeight = palette.heightAnchor.constraint(equalToConstant: 120)
        let width = palette.widthAnchor.constraint(equalToConstant: 520)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            width, paletteHeight,
            palette.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -16),
            palette.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            palette.topAnchor.constraint(equalTo: view.topAnchor, constant: 48),
            searchField.topAnchor.constraint(equalTo: palette.topAnchor, constant: 10),
            searchLeading,
            backButton.leadingAnchor.constraint(equalTo: palette.leadingAnchor, constant: 8),
            backButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 24),
            searchField.trailingAnchor.constraint(equalTo: palette.trailingAnchor, constant: -10),
            resultsScroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            resultsScroll.leadingAnchor.constraint(equalTo: palette.leadingAnchor, constant: 6),
            resultsScroll.trailingAnchor.constraint(equalTo: palette.trailingAnchor, constant: -6),
            resultsScroll.bottomAnchor.constraint(equalTo: palette.bottomAnchor, constant: -6),
            finderStatus.centerXAnchor.constraint(equalTo: resultsScroll.centerXAnchor),
            finderStatus.centerYAnchor.constraint(equalTo: resultsScroll.centerYAnchor),
            finderStatus.widthAnchor.constraint(lessThanOrEqualTo: palette.widthAnchor, constant: -24)
        ])
    }

    /// True until this pane opens its first file: backing out then undoes
    /// the Editor choice instead of leaving an empty editor behind.
    private var canReturnToNewTab: Bool {
        pane != nil && session.document == nil && state.filePath.isEmpty
    }

    @objc private func returnToNewTab() {
        guard canReturnToNewTab, let pane else { return }
        finding = false
        palette.isHidden = true
        pane.returnToNewTab()
    }

    private func presentFinder(resetQuery: Bool) {
        finding = true
        palette.isHidden = false
        backButton.isHidden = !canReturnToNewTab
        searchLeading.constant = canReturnToNewTab ? 36 : 10
        emptyView.isHidden = true
        if resetQuery {
            searchField.stringValue = ""
            selectFirstFinderResult()
            finder.setQuery("")
        }
        if let rootPath { finder.start(root: rootPath) } else { finder.reset() }
        refreshFinder()
        focusCurrentSurface()
    }

    private func dismissFinder() {
        if canReturnToNewTab { returnToNewTab(); return }
        guard session.document != nil else { return }
        finding = false
        palette.isHidden = true
        focusCurrentSurface()
    }

    private func refreshFinder() {
        guard finding else { return }
        let queryChanged = displayedQuery != finder.resultsQuery
        let oldPath = !queryChanged && displayedFiles.indices.contains(results.selectedRow)
            ? displayedFiles[results.selectedRow].path : nil
        if displayedFiles != finder.results || queryChanged {
            displayedFiles = finder.results
            displayedQuery = finder.resultsQuery
            results.reloadData()
            if !displayedFiles.isEmpty {
                let index = oldPath.flatMap { path in displayedFiles.firstIndex { $0.path == path } } ?? 0
                results.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
        }
        let message: String?
        if rootPath == nil {
            message = "Set a workspace root path to browse files."
        } else if let error = session.errorMessage {
            message = error
        } else if finder.isIndexing && displayedFiles.isEmpty {
            message = "Indexing…"
        } else if displayedFiles.isEmpty {
            message = "No matches"
        } else {
            message = nil
        }
        finderStatus.stringValue = message ?? ""
        finderStatus.isHidden = message == nil
        resultsScroll.isHidden = message != nil
        paletteHeight.constant = message == nil ? min(360, 46 + CGFloat(displayedFiles.count) * results.rowHeight) : 120
    }

    func numberOfRows(in tableView: NSTableView) -> Int { displayedFiles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard displayedFiles.indices.contains(row) else { return nil }
        let item = displayedFiles[row]
        let cell = NativeEditorFileCell()
        cell.name.stringValue = item.name
        cell.directory.stringValue = item.directoryPath
        cell.setAccessibilityLabel(item.relativePath)
        return cell
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === searchField else { return }
        selectFirstFinderResult()
        finder.setQuery(searchField.stringValue)
    }

    private func selectFirstFinderResult() {
        guard !displayedFiles.isEmpty else { return }
        results.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        results.scrollRowToVisible(0)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        guard control === searchField else { return false }
        switch command {
        case #selector(NSResponder.moveDown(_:)): moveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1); return true
        case #selector(NSResponder.insertNewline(_:)): openSelected(nil); return true
        case #selector(NSResponder.cancelOperation(_:)): dismissFinder(); return true
        default: return false
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !displayedFiles.isEmpty else { return }
        let index = min(max(0, results.selectedRow + delta), displayedFiles.count - 1)
        results.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        results.scrollRowToVisible(index)
    }

    @objc private func openSelected(_ sender: Any?) {
        guard finding, displayedFiles.indices.contains(results.selectedRow) else { return }
        openFile(URL(fileURLWithPath: displayedFiles[results.selectedRow].path))
    }

    private func presentConflict() {
        guard conflictAlert == nil, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "“\(session.url?.lastPathComponent ?? "File")” changed on disk"
        alert.informativeText = "This file was modified by another program since you opened it."
        alert.addButton(withTitle: "Overwrite")
        alert.addButton(withTitle: "Reload")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        conflictAlert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.conflictAlert = nil
            self.session.conflictPending = false
            switch response {
            case .alertFirstButtonReturn: self.session.requestSave(.overwrite)
            case .alertSecondButtonReturn:
                self.session.requestReload { [weak self] outcome in
                    if case .loaded = outcome { self?.installDocument() }
                    self?.refresh()
                }
            default: break
            }
        }
    }
}

@MainActor
private final class NativeEditorRootView: NSView {
    var onAppearanceChange: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); onAppearanceChange?() }
}

@MainActor
private final class NativeEditorTextCoordinator: NSObject, @preconcurrency TextViewCoordinator {
    let changed: (TextViewController) -> Void
    init(changed: @escaping (TextViewController) -> Void) { self.changed = changed }
    func prepareCoordinator(controller: TextViewController) {}
    func textViewDidChangeText(controller: TextViewController) { changed(controller) }
}

@MainActor
private final class NativeEditorFileCell: NSTableCellView {
    let name = CockpitUI.label("", size: 13)
    let directory = CockpitUI.label("", size: 11, color: .secondaryLabelColor)
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        name.maximumNumberOfLines = 1
        directory.maximumNumberOfLines = 1
        directory.lineBreakMode = .byTruncatingHead
        let stack = NSStackView(views: [name, directory])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { nil }
}
