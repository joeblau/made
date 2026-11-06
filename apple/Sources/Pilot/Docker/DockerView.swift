import AppKit
import Observation

/// Native presentation of the existing connection-scoped Docker store. Views
/// never own an Engine client, so row reuse cannot duplicate container actions.
@MainActor
final class DockerViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate, CockpitPanePresenting {
    let store: DockerStore
    private let isLive: Bool
    private let status = NSTextField(labelWithString: "")
    private let search = NSSearchField()
    private let stopped = NSButton(checkboxWithTitle: "Show stopped", target: nil, action: nil)
    private let refreshButton = NSButton()
    private let spinner = NSProgressIndicator()
    private let errorText = NSTextField(wrappingLabelWithString: "")
    private let dismissError = NSButton()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let emptyTitle = NSTextField(labelWithString: "")
    private let emptyDetail = NSTextField(wrappingLabelWithString: "")
    private let retry = NSButton(title: "Retry", target: nil, action: nil)
    private let openDocker = NSButton(title: "Open Docker Desktop", target: nil, action: nil)
    private var rows: [Row] = []
    private var isActive = false
    private var observationGeneration = 0
    private var presentedRemovalID: String?
    private var removalAlert: NSAlert?
    private var isApplyingSelection = false

    private enum Row: Equatable {
        case group(id: String, title: String)
        case container(DockerContainerSummary)

        var id: String {
            switch self {
            case .group(let id, _): "group:" + id
            case .container(let container): "container:" + container.id
            }
        }
    }

    init(store: DockerStore, isLive: Bool = true) {
        self.store = store
        self.isLive = isLive
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = DockerRootView()
        search.placeholderString = "Filter containers"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("Filter containers")
        stopped.target = self
        stopped.action = #selector(toggleStopped)
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh containers")
        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(refreshContainers)
        refreshButton.toolTip = "Refresh containers"
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        status.lineBreakMode = .byTruncatingTail
        errorText.textColor = .systemOrange
        dismissError.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss error")
        dismissError.bezelStyle = .rounded
        dismissError.target = self
        dismissError.action = #selector(clearError)
        retry.target = self
        retry.isEnabled = isLive
        retry.action = #selector(reconnect)
        openDocker.target = self
        openDocker.isEnabled = isLive
        openDocker.action = #selector(launchDocker)
        emptyTitle.alignment = .center
        emptyDetail.alignment = .center
        emptyDetail.textColor = .secondaryLabelColor
        emptyDetail.isSelectable = true

        let column = NSTableColumn(identifier: .init("container"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("Docker containers")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        for child in [status, search, stopped, refreshButton, spinner, errorText, dismissError,
                      scroll, emptyTitle, emptyDetail, retry, openDocker] {
            view.addSubview(child)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(zoomChanged), name: .cockpitUIZoomDidChange, object: nil
        )
        refreshPresentation()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        updatePresentation(isActive: true, isSelected: true)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        updatePresentation(isActive: false, isSelected: false)
    }

    func updatePresentation(isActive: Bool, isSelected: Bool) {
        guard self.isActive != isActive else { return }
        self.isActive = isActive
        observationGeneration &+= 1
        if isActive {
            if isLive { store.start() }
            observe()
        } else {
            cancelRemoval()
            if isLive { store.stop() }
        }
    }

    /// Explicit refresh also supports fixture captures without making a view
    /// appear or starting the engine discovery service.
    func refreshPresentation() {
        guard isViewLoaded else { return }
        switch store.engine {
        case .checking:
            status.stringValue = "Looking for a container engine…"
            status.textColor = .secondaryLabelColor
            status.toolTip = nil
        case .unavailable:
            status.stringValue = "Engine not running"
            status.textColor = .secondaryLabelColor
            status.toolTip = nil
        case .connected(let version, let socket):
            status.stringValue = (version.version.isEmpty ? "Docker" : "Docker " + version.version)
                + " · \(store.runningCount) of \(store.containers.count) running"
            status.textColor = .labelColor
            status.toolTip = socket
        }
        if search.currentEditor() == nil { search.stringValue = store.searchText }
        stopped.state = store.showsStopped ? .on : .off
        refreshButton.isEnabled = isLive && store.engine.isConnected && !store.isRefreshing
        if store.isRefreshing || store.engine == .checking { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        errorText.stringValue = store.actionError ?? ""
        errorText.isHidden = store.actionError == nil
        dismissError.isHidden = errorText.isHidden

        let nextRows = store.groupedContainers.flatMap { group in
            [Row.group(id: group.id, title: group.isCompose ? "Compose · " + group.title : group.title)]
                + group.containers.map(Row.container)
        }
        let oldRows = rows
        rows = nextRows
        if oldRows.map(\.id) != rows.map(\.id) {
            table.reloadData()
        } else {
            // Busy/selection can change without container data changing. Rebind
            // visible cells only; untouched offscreen rows need no presentation work.
            let visible = table.rows(in: table.visibleRect)
            if visible.location != NSNotFound {
                for index in visible.location..<NSMaxRange(visible) where rows.indices.contains(index) {
                    if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? DockerContainerCell,
                       case .container(let container) = rows[index] {
                        configure(cell, container: container)
                    } else if oldRows[index] != rows[index] {
                        table.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
                    }
                }
            }
        }
        isApplyingSelection = true
        if let index = rows.firstIndex(where: {
            if case .container(let container) = $0 { return container.id == store.selectedContainerID }
            return false
        }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        isApplyingSelection = false
        updateEmptyState()
        if removalAlert != nil, !store.engine.isConnected { cancelRemoval() }
        presentRemovalIfNeeded()
        view.needsLayout = true
    }

    private func observe() {
        guard isActive else { return }
        let generation = observationGeneration
        withObservationTracking {
            _ = store.engine
            _ = store.containers
            _ = store.isRefreshing
            _ = store.actionError
            _ = store.busyContainerIDs
            _ = store.searchText
            _ = store.showsStopped
            _ = store.selectedContainerID
            _ = store.containerPendingRemoval
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isActive, self.observationGeneration == generation else { return }
                self.refreshPresentation()
                self.observe()
            }
        }
        refreshPresentation()
    }

    private func updateEmptyState() {
        retry.isHidden = true
        openDocker.isHidden = true
        switch store.engine {
        case .checking:
            emptyTitle.stringValue = "Looking for a container engine…"
            emptyDetail.stringValue = ""
        case .unavailable(let reason):
            emptyTitle.stringValue = "No Container Engine"
            emptyDetail.stringValue = reason + "\nCockpit uses the engine you already run: Docker Desktop, Colima, Rancher Desktop, or Podman's Docker-compatible service."
            retry.isHidden = false
            openDocker.isHidden = !FileManager.default.fileExists(atPath: "/Applications/Docker.app")
        case .connected:
            if store.containers.isEmpty {
                emptyTitle.stringValue = "No Containers"
                emptyDetail.stringValue = "Nothing has been created on this engine yet. Start one from a terminal with docker run."
            } else if rows.isEmpty {
                emptyTitle.stringValue = "Nothing Matches"
                emptyDetail.stringValue = store.showsStopped ? "No container matches the filter."
                    : "No running container matches the filter. Turn on Show stopped to see the rest."
            } else {
                emptyTitle.stringValue = ""
                emptyDetail.stringValue = ""
            }
        }
        let empty = !store.engine.isConnected || rows.isEmpty
        scroll.isHidden = empty
        emptyTitle.isHidden = !empty
        emptyDetail.isHidden = !empty
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = view.bounds.width
        let zoom = CockpitUIZoomController.shared.factor
        let compact = width < 760 * zoom
        let headerHeight: CGFloat = (compact ? 80 : 46) * zoom
        let controlsY: CGFloat = (compact ? 42 : 10) * zoom
        status.frame = NSRect(x: 16, y: 12, width: max(80, compact ? width - 60 : width - 435 * zoom), height: 24 * zoom)
        spinner.frame = NSRect(x: width - 38, y: 13, width: 16, height: 16)
        refreshButton.frame = NSRect(x: width - 16 - 28 * zoom, y: controlsY, width: 28 * zoom, height: 28 * zoom)
        stopped.frame = NSRect(x: max(16, refreshButton.frame.minX - 12 - 142 * zoom), y: controlsY, width: 142 * zoom, height: 28 * zoom)
        let searchWidth = max(60, min(180 * zoom, stopped.frame.minX - 28))
        search.frame = NSRect(x: compact ? 16 : stopped.frame.minX - 12 - searchWidth, y: controlsY, width: searchWidth, height: 28 * zoom)
        search.font = CockpitTypography.font(size: 12)
        status.font = CockpitTypography.font(size: 12)
        stopped.font = CockpitTypography.font(size: 12)
        errorText.font = CockpitTypography.font(size: 12)
        let errorHeight: CGFloat = errorText.isHidden ? 0 : 52 * zoom
        errorText.frame = NSRect(x: 16, y: headerHeight, width: max(0, width - 70), height: errorHeight)
        dismissError.frame = NSRect(x: width - 44, y: headerHeight + 8, width: 28, height: 24)
        let top = headerHeight + errorHeight
        scroll.frame = NSRect(x: 8, y: top, width: max(0, width - 16), height: max(0, view.bounds.height - top - 8))
        table.tableColumns.first?.width = scroll.contentSize.width
        let centerY = top + max(0, view.bounds.height - top - 170) / 2
        emptyTitle.font = CockpitTypography.font(size: 20, weight: .semibold)
        emptyDetail.font = CockpitTypography.font(size: 13)
        emptyTitle.frame = NSRect(x: 24, y: centerY, width: max(0, width - 48), height: 34 * zoom)
        emptyDetail.frame = NSRect(x: 32, y: centerY + 42 * zoom, width: max(0, width - 64), height: 90 * zoom)
        retry.frame = NSRect(x: max(16, width / 2 - 125), y: centerY + 135 * zoom, width: 80, height: 28)
        openDocker.frame = NSRect(x: max(104, width / 2 - 35), y: centerY + 135 * zoom, width: 180, height: 28)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .group = rows[row] { return 28 * CockpitUIZoomController.shared.factor }
        return 70 * CockpitUIZoomController.shared.factor
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .container = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .group(_, let title):
            let cell = tableView.makeView(withIdentifier: .init("group"), owner: self) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = .init("group")
            let label = cell.textField ?? NSTextField(labelWithString: "")
            if label.superview == nil { cell.addSubview(label); cell.textField = label }
            label.stringValue = title
            label.font = CockpitTypography.font(size: 12, weight: .semibold)
            label.textColor = .secondaryLabelColor
            let zoom = CockpitUIZoomController.shared.factor
            label.frame = NSRect(x: 8, y: 4 * zoom, width: max(0, tableView.bounds.width - 16), height: 22 * zoom)
            label.setAccessibilityRole(.staticText)
            label.setAccessibilityRoleDescription("Heading")
            return cell
        case .container(let container):
            let cell = tableView.makeView(withIdentifier: .init("container"), owner: self) as? DockerContainerCell ?? DockerContainerCell()
            cell.identifier = .init("container")
            configure(cell, container: container)
            return cell
        }
    }

    private func configure(_ cell: DockerContainerCell, container: DockerContainerSummary) {
        cell.configure(container: container, isBusy: store.busyContainerIDs.contains(container.id), actionsEnabled: isLive) { [weak self] action in
            guard let self, self.isLive, !self.store.busyContainerIDs.contains(container.id) else { return }
            if action == .remove { self.store.requestRemoval(of: container); self.presentRemovalIfNeeded() } else { self.store.perform(action, on: container) }
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection, rows.indices.contains(table.selectedRow),
              case .container(let container) = rows[table.selectedRow] else { return }
        store.selectedContainerID = container.id
    }

    func controlTextDidChange(_ obj: Notification) { store.searchText = search.stringValue }
    @objc private func toggleStopped() { store.showsStopped = stopped.state == .on }
    @objc private func refreshContainers() { if isLive { store.refreshNow() } }
    @objc private func clearError() { store.dismissActionError() }
    @objc private func reconnect() { if isLive { store.reconnect() } }
    @objc private func launchDocker() {
        guard isLive else { return }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Docker.app"), configuration: .init())
    }
    @objc private func zoomChanged() {
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: rows.indices))
        table.reloadData()
        view.needsLayout = true
    }

    private func presentRemovalIfNeeded() {
        guard isLive, store.engine.isConnected, presentedRemovalID == nil, let container = store.containerPendingRemoval, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove Container?"
        alert.informativeText = "“\(container.name)” will be stopped and deleted. Its named volumes are kept."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove Container")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        presentedRemovalID = container.id
        removalAlert = alert
        let generation = observationGeneration
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            defer { self.presentedRemovalID = nil; self.removalAlert = nil }
            guard self.observationGeneration == generation,
                  self.store.containerPendingRemoval?.id == container.id else { return }
            self.store.containerPendingRemoval = nil
            if response == .alertFirstButtonReturn { self.store.perform(.remove, on: container) }
        }
    }

    private func cancelRemoval() {
        store.containerPendingRemoval = nil
        if let sheet = removalAlert?.window, let parent = sheet.sheetParent { parent.endSheet(sheet, returnCode: .cancel) }
        presentedRemovalID = nil
    }
}

private final class DockerRootView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()
    }
}

@MainActor
private final class DockerActionButton: NSButton {
    var perform: (() -> Void)?
    init(title: String, symbol: String? = nil, perform: @escaping () -> Void) {
        self.perform = perform
        super.init(frame: .zero)
        self.title = title
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            imagePosition = .imageOnly
        }
        bezelStyle = .rounded
        controlSize = .small
        toolTip = title
        target = self
        action = #selector(invoke)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func invoke() { perform?() }
}

@MainActor
private final class DockerContainerCell: NSTableCellView, NSMenuDelegate {
    private let nameLabel = NSTextField(labelWithString: "")
    private let details = NSTextField(labelWithString: "")
    private let ports = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let progress = NSProgressIndicator()
    private var buttons: [DockerActionButton] = []
    private var container: DockerContainerSummary?
    private var perform: ((DockerContainerAction) -> Void)?
    private var isBusy = false
    private var actionsEnabled = true
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        nameLabel.lineBreakMode = .byTruncatingTail
        details.lineBreakMode = .byTruncatingMiddle
        details.textColor = .secondaryLabelColor
        ports.textColor = .secondaryLabelColor
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        for child in [nameLabel, details, ports, dot, progress] { addSubview(child) }
        let contextMenu = NSMenu()
        contextMenu.autoenablesItems = false
        contextMenu.delegate = self
        menu = contextMenu
    }
    required init?(coder: NSCoder) { nil }

    func configure(container: DockerContainerSummary, isBusy: Bool, actionsEnabled: Bool, perform: @escaping (DockerContainerAction) -> Void) {
        let actionsChanged = self.container?.state.isRunning != container.state.isRunning
        self.container = container
        self.perform = perform
        self.isBusy = isBusy
        self.actionsEnabled = actionsEnabled
        nameLabel.stringValue = container.name
        details.stringValue = container.image + " · " + (container.status.isEmpty ? container.state.rawValue.capitalized : container.status)
        ports.stringValue = container.portsSummary
        toolTip = container.shortID + (container.command.isEmpty ? "" : " — " + container.command)
        let color: NSColor = switch container.state {
        case .running: .systemGreen
        case .restarting, .removing, .paused: .systemOrange
        case .dead: .systemRed
        case .created, .exited, .unknown: .secondaryLabelColor
        }
        dot.layer?.backgroundColor = color.cgColor
        if actionsChanged || buttons.isEmpty {
            buttons.forEach { $0.removeFromSuperview() }
            buttons = availableActions.map { action in
                let button = DockerActionButton(title: action.label, symbol: action.systemImage) { [weak self] in
                    self?.perform?(action)
                }
                addSubview(button)
                return button
            }
        }
        buttons.forEach { $0.isEnabled = !isBusy && actionsEnabled }
        setAccessibilityCustomActions(isBusy || !actionsEnabled ? [] : availableActions.map { action in
            NSAccessibilityCustomAction(name: action.label) { [weak self] in
                guard let self, !self.isBusy, self.actionsEnabled else { return false }
                self.perform?(action)
                return true
            }
        })
        if isBusy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        setAccessibilityLabel("\(container.name), \(container.state.rawValue), \(container.image), \(container.portsSummary)")
        needsLayout = true
    }

    private var availableActions: [DockerContainerAction] {
        container?.state.isRunning == true ? [.stop, .restart, .remove] : [.start, .remove]
    }

    override func layout() {
        super.layout()
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.10).cgColor
        let width = bounds.width
        let zoom = CockpitUIZoomController.shared.factor
        nameLabel.font = CockpitTypography.font(size: 13, weight: .medium)
        details.font = CockpitTypography.font(size: 11)
        ports.font = CockpitTypography.font(size: 11, monospaced: true)
        dot.frame = NSRect(x: 12, y: bounds.midY - 4, width: 8, height: 8)
        let actionsWidth: CGFloat = 112 * zoom
        let portWidth: CGFloat = width > 740 * zoom ? 190 * zoom : 0
        let textWidth = max(70, width - 44 - actionsWidth - portWidth)
        nameLabel.frame = NSRect(x: 30, y: bounds.midY - 23 * zoom, width: textWidth, height: 23 * zoom)
        details.frame = NSRect(x: 30, y: bounds.midY + zoom, width: textWidth, height: 22 * zoom)
        ports.frame = NSRect(x: width - actionsWidth - portWidth - 8, y: bounds.midY - 10 * zoom, width: portWidth, height: 22 * zoom)
        ports.isHidden = portWidth == 0
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: width - 10 - CGFloat(buttons.count - index) * 32 * zoom, y: bounds.midY - 13 * zoom, width: 28 * zoom, height: 26 * zoom)
        }
        progress.frame = NSRect(x: width - actionsWidth - 18, y: bounds.midY - 8, width: 16, height: 16)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for (index, action) in availableActions.enumerated() {
            let item = NSMenuItem(title: action.label + (action == .remove ? "…" : ""), action: #selector(menuAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.isEnabled = !isBusy && actionsEnabled
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let copy = NSMenuItem(title: "Copy Container ID", action: #selector(copyID), keyEquivalent: "")
        copy.target = self
        copy.isEnabled = actionsEnabled
        menu.addItem(copy)
        for port in container?.ports ?? [] {
            guard let published = port.publicPort, (1...65535).contains(published), port.networkProtocol == "tcp" else { continue }
            let item = NSMenuItem(title: "Open localhost:\(published)", action: #selector(openPort(_:)), keyEquivalent: "")
            item.target = self
            item.tag = published
            item.isEnabled = actionsEnabled
            menu.addItem(item)
        }
    }
    @objc private func menuAction(_ sender: NSMenuItem) {
        guard actionsEnabled, !isBusy, availableActions.indices.contains(sender.tag) else { return }
        perform?(availableActions[sender.tag])
    }
    @objc private func copyID() {
        guard actionsEnabled, let container else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(container.id, forType: .string)
    }
    @objc private func openPort(_ sender: NSMenuItem) {
        guard actionsEnabled, (1...65535).contains(sender.tag), let url = URL(string: "http://localhost:\(sender.tag)") else { return }
        NSWorkspace.shared.open(url)
    }
}
