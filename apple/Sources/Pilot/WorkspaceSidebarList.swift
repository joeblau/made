import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor
final class WorkspaceSidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private enum Row: Hashable {
        case mode(SidebarSelection)
        case heading(String)
        case workspace(UUID, group: UUID?)
        case group(UUID)
        case emptyGroup(UUID)
    }
    private enum RowContent: Equatable {
        case fixed
        case disclosure(String, Bool)
        case workspace(String, String?, Int)
    }

    let store: WorkspaceStore
    private let isLive: Bool
    var onSelect: ((SidebarSelection) -> Void)?
    var onNewWorkspace: ((UUID?) -> Void)?
    var onDeleteWorkspace: ((Workspace) -> Void)?
    private let table = CockpitSidebarTableView(frame: NSRect(x: 0, y: 0, width: 240, height: 1))
    private let scroll = NSScrollView()
    private var hasLaidOutRows = false
    private let branches = WorkspaceBranchStore()
    private var rows: [Row] = []
    private var rowContents: [RowContent] = []
    private var observationGeneration = 0
    private var refreshTimer: Timer?
    private var monitoring = false
    private var isRefreshing = false
    private var lastBranchRefresh = Date.distantPast
    private var lastZoom = 0.0

    init(store: WorkspaceStore, defaults: UserDefaults = .standard, isLive: Bool = true) {
        self.store = store
        self.isLive = isLive
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    isolated deinit { stopMonitoring() }

    override func loadView() {
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("workspace"))
        table.addTableColumn(column)
        table.headerView = nil
        table.autoresizingMask = [.width]
        table.style = .sourceList
        table.dataSource = self
        table.delegate = self
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("Cockpit navigation")
        table.onDisclosureKey = { [weak self] expand in self?.discloseSelectedRow(expand: expand) ?? false }
        table.registerForDraggedTypes([NSPasteboard.PasteboardType(UTType.pilotWorkspace.identifier)])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        scroll.documentView = table
        view = scroll
        refresh()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = scroll.contentSize.width
        guard width > 0 else { return }
        if table.frame.width != width { table.setFrameSize(NSSize(width: width, height: table.frame.height)) }
        if !hasLaidOutRows, scroll.contentSize.height > 0 {
            hasLaidOutRows = true
            table.reloadData()
            table.scrollRowToVisible(0)
        }
    }

    override func viewDidAppear() { super.viewDidAppear(); refresh(); startMonitoring() }
    override func viewDidDisappear() { super.viewDidDisappear(); stopMonitoring() }

    func startMonitoring() {
        guard !monitoring else { return }
        monitoring = true
        if isLive {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshVisibleStatus() }
            }
            refreshVisibleStatus()
        }
        observe()
    }

    func stopMonitoring() {
        monitoring = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        observationGeneration += 1
        branches.stop()
    }

    func refresh() {
        guard isViewLoaded else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let workspaces = store.workspaces
        let selectedDisclosure: Row? = if table.window?.firstResponder === table,
            rows.indices.contains(table.selectedRow), isDisclosure(rows[table.selectedRow]) { rows[table.selectedRow] } else { nil }
        let zoom = CockpitUIZoomController.shared.factor
        let zoomChanged = lastZoom != zoom
        if zoomChanged {
            lastZoom = zoom
            if !rows.isEmpty { table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: rows.indices)) }
        }
        if isLive, view.window?.isVisible == true, NSApp.isActive {
            branches.refresh(workspaces.compactMap { workspace in
                workspace.effectiveRootPath.map { WorkspaceBranchStore.Target(id: workspace.id, rootPath: $0) }
            })
        }
        var next: [Row] = [.mode(.notes), .mode(.remoteDesktop), .mode(.docker), .mode(.agenticUse), .mode(.runners)]
        let pinned = workspaces.filter(\.isPinned)
        if !pinned.isEmpty {
            next.append(.heading("Pinned"))
            next += pinned.map { .workspace($0.id, group: nil) }
        }
        next.append(.heading("Workspaces"))
        next += store.workspaceGroups.visibleRows(workspaceIDs: store.unpinnedWorkspaceIDs).map {
            switch $0 {
            case .workspace(let id, let groupID): return .workspace(id, group: groupID)
            case .group(let id): return .group(id)
            case .emptyGroup(let id): return .emptyGroup(id)
            }
        }
        let workspacesByID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        let contents: [RowContent] = next.map { row in
            switch row {
            case .workspace(let id, _):
                guard let workspace = workspacesByID[id] else { return .fixed }
                return .workspace(workspace.name, branches.branches[id], workspace.badgeCount)
            case .group(let id):
                guard let group = store.workspaceGroups.group(id) else { return .fixed }
                return .disclosure(group.name, group.isExpanded)
            default: return .fixed
            }
        }
        if next != rows {
            rows = next
            rowContents = contents
            table.reloadData()
        } else {
            let changed = IndexSet(contents.indices.filter { zoomChanged || rowContents[$0] != contents[$0] })
            rowContents = contents
            if !changed.isEmpty { table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0)) }
        }
        if let selected = selectedDisclosure ?? selectedRowValue(), let index = rows.firstIndex(of: selected) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else { table.deselectAll(nil) }
    }

    private func selectedRowValue() -> Row? {
        if store.isNotesMode { return .mode(.notes) }
        if store.isRemoteDesktopMode { return .mode(.remoteDesktop) }
        if store.isDockerMode { return .mode(.docker) }
        if store.isAgenticUseMode { return .mode(.agenticUse) }
        if store.isRunnersMode { return .mode(.runners) }
        return rows.first { if case .workspace(let id, _) = $0 { return id == store.selectedWorkspaceID }; return false }
    }

    private func observe() {
        guard monitoring else { return }
        observationGeneration += 1
        let generation = observationGeneration
        withObservationTracking {
            _ = store.changeCount
            _ = CockpitUIZoomController.shared.factor
            _ = store.selectedWorkspaceID
            _ = store.isWorkspaceDetailVisible
            _ = store.workspaceGroups.groups
            _ = branches.branches
            for workspace in store.workspaces { _ = workspace.name; _ = workspace.badgeCount; _ = workspace.isPinned; _ = workspace.effectiveRootPath }
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, generation == self.observationGeneration else { return }
                self.refresh()
                self.observe()
            }
        }
    }

    private func refreshVisibleStatus() {
        guard view.window?.isVisible == true, NSApp.isActive else { return }
        if Date().timeIntervalSince(lastBranchRefresh) >= 20 {
            lastBranchRefresh = Date()
            branches.refresh(store.workspaces.compactMap { workspace in
                workspace.effectiveRootPath.map { WorkspaceBranchStore.Target(id: workspace.id, rootPath: $0) }
            })
        }
        let visible = table.rows(in: table.visibleRect)
        guard visible.location != NSNotFound else { return }
        for index in visible.location..<min(rows.count, visible.location + visible.length) {
            guard case .workspace(let id, _) = rows[index],
                  let workspace = store.workspaces.first(where: { $0.id == id }),
                  let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? WorkspaceSidebarCell else { continue }
            cell.refreshStatus(workspace: workspace, store: store)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let zoom = CGFloat(CockpitUIZoomController.shared.factor)
        guard rows.indices.contains(row) else { return 28 * zoom }
        if case .workspace = rows[row] { return 44 * zoom }
        return 28 * zoom
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        if case .heading = rows[row] { return false }
        if case .emptyGroup = rows[row] { return false }
        return true
    }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        if case .heading = rows[row] { return true }
        return false
    }
    private func isDisclosure(_ row: Row) -> Bool {
        switch row {
        case .group: true
        default: false
        }
    }
    private func discloseSelectedRow(expand: Bool?) -> Bool {
        guard rows.indices.contains(table.selectedRow) else { return false }
        return disclose(rows[table.selectedRow], expand: expand)
    }
    @discardableResult
    private func disclose(_ row: Row, expand: Bool?) -> Bool {
        switch row {
        case .group(let id):
            guard let group = store.workspaceGroups.group(id) else { return false }
            store.workspaceGroups.setExpanded(id, expand ?? !group.isExpanded)
        default: return false
        }
        refresh()
        if let index = rows.firstIndex(of: row) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        return true
    }
    private func disclosureView(title: String, expanded: Bool, row: Row, identifier: String) -> NSView {
        let button = ShellActionButton("") { [weak self] in _ = self?.disclose(row, expand: nil) }
        button.bezelStyle = .disclosure
        button.setButtonType(.onOff)
        button.state = expanded ? .on : .off
        button.focusRingType = .default
        button.setAccessibilityRole(.disclosureTriangle)
        button.setAccessibilityLabel(title)
        button.setAccessibilityExpanded(expanded)
        button.setAccessibilityIdentifier(identifier)
        button.toolTip = (expanded ? "Collapse " : "Expand ") + title
        let label = shellLabel(title)
        label.font = CockpitTypography.font(size: 12, weight: .semibold)
        let folder = NSImageView(image: NSImage(systemSymbolName: expanded ? "folder.fill" : "folder",
                                                accessibilityDescription: nil) ?? NSImage())
        folder.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        folder.contentTintColor = .secondaryLabelColor
        folder.setAccessibilityElement(false)
        folder.widthAnchor.constraint(equalToConstant: 16).isActive = true
        return shellStack([button, folder, label], orientation: .horizontal, spacing: 4)
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRefreshing, rows.indices.contains(table.selectedRow) else { return }
        switch rows[table.selectedRow] {
        case .mode(let mode): onSelect?(mode)
        case .workspace(let id, _): onSelect?(.workspace(id))
        default: break
        }
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .workspace(let id, let group):
            guard let workspace = store.workspaces.first(where: { $0.id == id }) else { return nil }
            let cell = (table.makeView(withIdentifier: NSUserInterfaceItemIdentifier("workspace.cell"), owner: self) as? WorkspaceSidebarCell) ?? WorkspaceSidebarCell()
            cell.identifier = NSUserInterfaceItemIdentifier("workspace.cell")
            cell.configure(workspace: workspace, branch: branches.branches[id], indentation: group == nil ? 0 : 16, store: store)
            return cell
        case .mode(let mode):
            let (title, symbol) = Self.presentation(mode)
            let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
            image.contentTintColor = .controlAccentColor
            image.widthAnchor.constraint(equalToConstant: 18).isActive = true
            return shellStack([image, shellLabel(title)], orientation: .horizontal)
        case .heading(let title):
            let label = shellLabel(title, secondary: true)
            label.font = CockpitTypography.font(size: 11, weight: .semibold)
            label.setAccessibilityIdentifier("sidebar.section." + title.lowercased())
            label.setAccessibilityRoleDescription("Section heading")
            return label
        case .group(let id):
            guard let group = store.workspaceGroups.group(id) else { return nil }
            return disclosureView(title: group.name, expanded: group.isExpanded, row: rows[row], identifier: "sidebar.group." + id.uuidString)
        case .emptyGroup: return shellLabel("    Drop workspaces here", secondary: true)
        }
    }

    private static func presentation(_ selection: SidebarSelection) -> (String, String) {
        switch selection {
        case .notes: ("Notes", "note.text")
        case .remoteDesktop: ("Remote Desktop", "macbook.and.iphone")
        case .docker: ("Docker", "shippingbox")
        case .agenticUse: ("Agentic Use", "chart.bar.xaxis")
        case .runners: ("Runners", "server.rack")
        case .workspace: ("Workspace", "terminal")
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let rowIndex = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard rows.indices.contains(rowIndex) else {
            menu.addItem(ShellMenuItem("New Workspace…") { [weak self] in self?.onNewWorkspace?(nil) }); return
        }
        switch rows[rowIndex] {
        case .workspace(let id, _):
            guard let workspace = store.workspaces.first(where: { $0.id == id }) else { return }
            menu.addItem(ShellMenuItem("Rename Workspace…") { [weak self] in
                TextPromptSheet.present(on: self?.view.window, title: "Rename Workspace", label: "Workspace name", value: workspace.name) { name in
                    workspace.name = name; _ = workspace.modelContext?.saveReporting()
                }
            })
            menu.addItem(ShellMenuItem("Update Root Path…") { [weak self] in self?.chooseRoot(workspace) })
            menu.addItem(ShellMenuItem(workspace.isPinned ? "Unpin" : "Pin") { [weak self] in self?.store.togglePin(workspace) })
            let move = NSMenuItem(title: "Move to Group", action: nil, keyEquivalent: "")
            let groups = NSMenu()
            groups.addItem(ShellMenuItem("Ungrouped") { [weak self] in self?.store.moveWorkspace(workspace, toGroup: nil) })
            for group in store.workspaceGroups.groups {
                groups.addItem(ShellMenuItem(group.name) { [weak self] in self?.store.moveWorkspace(workspace, toGroup: group.id) })
            }
            move.submenu = groups; menu.addItem(move)
            menu.addItem(.separator())
            menu.addItem(ShellMenuItem("Delete Workspace…") { [weak self] in self?.onDeleteWorkspace?(workspace) })
        case .group(let id), .emptyGroup(let id):
            guard let group = store.workspaceGroups.group(id) else { return }
            menu.addItem(ShellMenuItem("New Workspace in Group…") { [weak self] in self?.onNewWorkspace?(id) })
            menu.addItem(ShellMenuItem("Rename Group…") { [weak self] in
                TextPromptSheet.present(on: self?.view.window, title: "Rename Group", label: "Group name", value: group.name) { [weak self] name in self?.store.workspaceGroups.rename(id, to: name) }
            })
            menu.addItem(ShellMenuItem("Ungroup Workspaces") { [weak self] in
                guard let self else { return }; self.store.workspaceGroups.remove(id, workspaceIDs: self.store.unpinnedWorkspaceIDs)
            })
        default: menu.addItem(ShellMenuItem("New Workspace…") { [weak self] in self?.onNewWorkspace?(nil) })
        }
    }

    private func chooseRoot(_ workspace: Workspace) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Set Root Path"
        panel.message = "Choose the root directory for “\(workspace.name)”."
        panel.directoryURL = workspace.effectiveRootPath.map { URL(fileURLWithPath: $0) }
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url { workspace.setRootPath(url.path) }
        }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let payload: WorkspaceSidebarDragPayload
        switch rows[row] {
        case .workspace(let id, _): payload = WorkspaceSidebarDragPayload(workspaceID: id)
        case .group(let id): payload = WorkspaceSidebarDragPayload(groupID: id)
        default: return nil
        }
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        let item = NSPasteboardItem()
        item.setData(data, forType: NSPasteboard.PasteboardType(UTType.pilotWorkspace.identifier))
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard decode(info) != nil else { return [] }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let payload = decode(info) else { return false }
        let target = rows.indices.contains(row) ? rows[row] : nil
        let accepted: Bool
        if dropOperation == .on, case .group(let id) = target {
            accepted = store.acceptWorkspaceDrop([payload], toGroup: id)
        } else if case .emptyGroup(let id) = target {
            accepted = store.acceptWorkspaceDrop([payload], toGroup: id)
        } else if case .workspace(let id, let groupID) = target {
            if let workspace = store.workspaces.first(where: { $0.id == id }), workspace.isPinned {
                let pinned = store.workspaces.filter(\.isPinned)
                accepted = store.acceptPinnedWorkspaceDrop(payload, at: pinned.firstIndex(where: { $0.id == id }) ?? pinned.count)
            } else { accepted = store.acceptSidebarDrop(payload, before: .workspace(id, groupID: groupID)) }
        } else if case .group(let id) = target {
            accepted = store.acceptSidebarDrop(payload, before: .group(id))
        } else if case .heading("Pinned") = target {
            accepted = store.acceptPinnedWorkspaceDrop(payload, at: 0)
        } else { accepted = store.acceptSidebarDrop(payload, before: nil) }
        if accepted { refresh() }
        return accepted
    }

    private func decode(_ info: NSDraggingInfo) -> WorkspaceSidebarDragPayload? {
        guard let data = info.draggingPasteboard.data(forType: NSPasteboard.PasteboardType(UTType.pilotWorkspace.identifier)), data.count <= 16_384 else { return nil }
        return try? JSONDecoder().decode(WorkspaceSidebarDragPayload.self, from: data)
    }
}

@MainActor
private final class WorkspaceSidebarCell: NSTableCellView {
    private let name = shellLabel("")
    private let branch = shellLabel("", secondary: true)
    private let badge = shellLabel("")
    private let gauge = WorkspaceGaugeView(frame: .zero)
    private var coldTicks = 2
    private var workspaceID: UUID?
    private var runningPaneIDs: Set<UUID> = []
    private var nameLeading: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        branch.font = .systemFont(ofSize: 10)
        name.font = .systemFont(ofSize: 12)
        badge.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        let labels = shellStack([name, branch], spacing: 2)
        let row = shellStack([labels, badge, gauge], orientation: .horizontal, spacing: 6)
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        // Indent the whole text block so a grouped row's branch line stays
        // under its name instead of hanging back at the sidebar edge.
        let leading = row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        nameLeading = leading
        NSLayoutConstraint.activate([
            leading,
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        gauge.widthAnchor.constraint(equalToConstant: 26).isActive = true
        gauge.heightAnchor.constraint(equalToConstant: 26).isActive = true
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { nil }

    func configure(workspace: Workspace, branch: String?, indentation: CGFloat, store: WorkspaceStore) {
        if workspaceID != workspace.id { coldTicks = 2; workspaceID = workspace.id; gauge.started = 0; gauge.running = 0 }
        name.font = CockpitTypography.font(size: 12)
        self.branch.font = CockpitTypography.font(size: 10)
        badge.font = CockpitTypography.font(size: 10, weight: .medium, monospaced: true)
        nameLeading?.constant = 4 + indentation
        name.stringValue = workspace.name
        self.branch.stringValue = branch.map { "⑂ \($0)" } ?? ""
        self.branch.isHidden = branch == nil
        badge.stringValue = workspace.badgeCount > 0 ? String(workspace.badgeCount) : ""
        setAccessibilityLabel(workspace.name + (branch.map { ", branch \($0)" } ?? ""))
        refreshStatus(workspace: workspace, store: store)
    }

    func refreshStatus(workspace: Workspace, store: WorkspaceStore) {
        guard NSApp.isActive else { return }
        let terminals = workspace.panes.filter { $0.kind == .terminal }
        if coldTicks > 0 && terminals.contains(where: { !$0.hasTerminalRuntimeSnapshot }) { coldTicks -= 1; return }
        var started = 0
        var running = Set<UUID>()
        for pane in terminals {
            guard let status = pane.liveShellAgentStatus() else { continue }
            started += 1
            if status.agent.needsVisibleTerminalContentsForActivity && pane.visibleTerminalContents() == nil && coldTicks > 0 { coldTicks -= 1; return }
            if status.activity == .running { running.insert(pane.id) }
        }
        coldTicks = 2
        runningPaneIDs = running
        gauge.started = started; gauge.running = running.count
        gauge.isHidden = started == 0
        gauge.isEnabled = !running.isEmpty
        let description = "\(running.count) of \(started) started agents working"
        gauge.toolTip = description
        gauge.setAccessibilityLabel(description)
        gauge.onJump = { [weak self, weak store, weak workspace] in
            guard let self, let store, let workspace,
                  let pane = workspace.panes.first(where: { self.runningPaneIDs.contains($0.id) }) else { return }
            store.selectWorkspace(workspace.id)
            if pane.isCollapsed { workspace.expandPane(pane) }
            workspace.selectedPaneID = pane.id
        }
    }
}

@MainActor
private final class CockpitSidebarTableView: NSTableView {
    var onDisclosureKey: ((Bool?) -> Bool)?
    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { super.keyDown(with: event); return }
        let handled: Bool
        switch event.keyCode {
        case 123: handled = onDisclosureKey?(false) ?? false
        case 124: handled = onDisclosureKey?(true) ?? false
        case 36, 49, 76: handled = onDisclosureKey?(nil) ?? false
        default: handled = false
        }
        if !handled { super.keyDown(with: event) }
    }
}
