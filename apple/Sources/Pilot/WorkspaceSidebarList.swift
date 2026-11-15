import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor
final class WorkspaceSidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    /// What the list under the global modes shows: the workspaces, or every
    /// agentic job across them grouped by state.
    enum ListMode: String { case workspaces, inbox }
    static let listModeKey = "sidebar.listMode"

    private enum Row: Hashable {
        case mode(SidebarSelection)
        case switcher
        case job(UUID)
        case emptyInbox
        case heading(String)
        case workspace(UUID, group: UUID?)
        case group(UUID)
        case emptyGroup(UUID)
    }
    private enum RowContent: Equatable {
        case fixed
        case disclosure(String, Bool)
        case workspace(String, String?, Int, Int)
        case job(AgentJob, String)
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
    private let defaults: UserDefaults
    let jobs = AgentJobTracker()
    private(set) var listMode: ListMode
    private let switcher = NSSegmentedControl(labels: ["Workspaces", "Inbox"], trackingMode: .selectOne, target: nil, action: nil)

    init(store: WorkspaceStore, defaults: UserDefaults = .standard, isLive: Bool = true) {
        self.store = store
        self.isLive = isLive
        self.defaults = defaults
        listMode = defaults.string(forKey: Self.listModeKey).flatMap(ListMode.init(rawValue:)) ?? .workspaces
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
        switcher.target = self
        switcher.action = #selector(switchListMode)
        switcher.segmentDistribution = .fillEqually
        // The same Liquid Glass capsule as the app's other tab pickers: the
        // selected segment is an accent-tinted glass pill that slides.
        switcher.controlSize = .large
        switcher.segmentStyle = .capsule
        switcher.selectedSegmentBezelColor = LegibleAccent.nsColor
        if #available(macOS 26.0, *) { switcher.borderShape = .capsule }
        if #available(macOS 27.0, *) { switcher.role = .tabs }
        switcher.setAccessibilityIdentifier("sidebar.list-mode")
        switcher.setAccessibilityLabel("Sidebar list")
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
        var next: [Row] = store.sidebarVisibility.visibleFeatures.map { .mode($0.selection) }
        next.append(.switcher)
        let workspacesByID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        // A job whose workspace is gone is dropped by the tracker's next poll.
        let inbox = jobs.jobs.filter { workspacesByID[$0.workspaceID] != nil }
        let jobsByID = Dictionary(uniqueKeysWithValues: inbox.map { ($0.paneID, $0) })
        updateSwitcher(attention: inbox.count(where: \.needsAttention))
        switch listMode {
        case .inbox:
            for state in AgentJobState.allCases {
                let section = inbox.filter { $0.state == state }
                guard !section.isEmpty else { continue }
                next.append(.heading(state.title))
                next += section.map { .job($0.paneID) }
            }
            if inbox.isEmpty { next.append(.emptyInbox) }
        case .workspaces:
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
        }
        let contents: [RowContent] = next.map { row in
            switch row {
            case .job(let id):
                guard let job = jobsByID[id] else { return .fixed }
                return .job(job, workspacesByID[job.workspaceID]?.name ?? "")
            case .workspace(let id, _):
                guard let workspace = workspacesByID[id] else { return .fixed }
                return .workspace(workspace.name, branches.branches[id], workspace.badgeCount, store.openTaskCounts[id] ?? 0)
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
        if let feature = store.activeSidebarFeature { return .mode(feature.selection) }
        if listMode == .inbox {
            guard let paneID = store.selectedWorkspace?.selectedPaneID, rows.contains(.job(paneID)) else { return nil }
            return .job(paneID)
        }
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
            _ = store.sidebarVisibility.hidden
            _ = store.workspaceGroups.groups
            _ = store.openTaskCounts
            _ = branches.branches
            _ = jobs.jobs
            for workspace in store.workspaces { _ = workspace.name; _ = workspace.badgeCount; _ = workspace.isPinned; _ = workspace.effectiveRootPath; _ = workspace.selectedPaneID }
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
        jobs.refresh(store: store)
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
        switch rows[row] {
        case .workspace, .job: return 44 * zoom
        case .switcher: return 46 * zoom
        default: return 28 * zoom
        }
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        switch rows[row] {
        case .heading, .emptyGroup, .switcher, .emptyInbox: return false
        default: return true
        }
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
        case .job(let id): openJob(id)
        default: break
        }
    }

    /// Shows the job's workspace with its pane selected; looking at a
    /// finished job moves it from Completed to Waiting for Input.
    private func openJob(_ paneID: UUID) {
        guard let job = jobs.jobs.first(where: { $0.paneID == paneID }),
              let workspace = store.workspaces.first(where: { $0.id == job.workspaceID }),
              let pane = workspace.panes.first(where: { $0.id == paneID }) else { return }
        onSelect?(.workspace(workspace.id))
        if pane.isCollapsed { workspace.expandPane(pane) }
        workspace.selectedPaneID = pane.id
        jobs.markSeen(paneID)
    }

    func setListMode(_ mode: ListMode) {
        guard mode != listMode else { return }
        listMode = mode
        defaults.set(mode.rawValue, forKey: Self.listModeKey)
        refresh()
    }

    @objc private func switchListMode() {
        setListMode(switcher.selectedSegment == 1 ? .inbox : .workspaces)
    }

    private func updateSwitcher(attention: Int) {
        switcher.setLabel(attention > 0 ? "Inbox (\(attention))" : "Inbox", forSegment: 1)
        switcher.selectedSegment = listMode == .inbox ? 1 : 0
        switcher.font = CockpitTypography.font(size: 11)
        switcher.toolTip = attention > 0
            ? "\(attention) agent \(attention == 1 ? "job needs" : "jobs need") your attention"
            : "Agent jobs across all workspaces"
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .workspace(let id, let group):
            guard let workspace = store.workspaces.first(where: { $0.id == id }) else { return nil }
            let cell = (table.makeView(withIdentifier: NSUserInterfaceItemIdentifier("workspace.cell"), owner: self) as? WorkspaceSidebarCell) ?? WorkspaceSidebarCell()
            cell.identifier = NSUserInterfaceItemIdentifier("workspace.cell")
            cell.configure(workspace: workspace, branch: branches.branches[id], openTaskCount: store.openTaskCounts[id] ?? 0,
                           indentation: group == nil ? 0 : 16, store: store)
            return cell
        case .switcher:
            let cell = NSTableCellView()
            switcher.removeFromSuperview()
            switcher.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(switcher)
            NSLayoutConstraint.activate([
                switcher.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                switcher.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                // The heading below brings its own space above its text, so
                // the control sits low in its row to look evenly spaced.
                switcher.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -4),
            ])
            return cell
        case .job(let id):
            guard let job = jobs.jobs.first(where: { $0.paneID == id }) else { return nil }
            let cell = (table.makeView(withIdentifier: NSUserInterfaceItemIdentifier("job.cell"), owner: self) as? AgentJobSidebarCell) ?? AgentJobSidebarCell()
            cell.identifier = NSUserInterfaceItemIdentifier("job.cell")
            cell.configure(job: job, workspaceName: store.workspaces.first { $0.id == job.workspaceID }?.name ?? "")
            return cell
        case .emptyInbox:
            let label = shellLabel("No agent jobs running", secondary: true)
            label.setAccessibilityIdentifier("sidebar.inbox.empty")
            return label
        case .mode(let mode):
            let (title, symbol) = Self.presentation(mode)
            let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
            image.contentTintColor = .controlAccentColor
            image.widthAnchor.constraint(equalToConstant: 18).isActive = true
            let stack = shellStack([image, shellLabel(title)], orientation: .horizontal)
            stack.setAccessibilityIdentifier("sidebar.mode." + (SidebarFeature(mode)?.rawValue ?? "workspace"))
            return stack
        case .heading(let title):
            let label = shellLabel(title, secondary: true)
            label.font = CockpitTypography.font(size: 11, weight: .semibold)
            label.setAccessibilityIdentifier("sidebar.section." + title.lowercased().replacingOccurrences(of: " ", with: "-"))
            label.setAccessibilityRoleDescription("Section heading")
            return label
        case .group(let id):
            guard let group = store.workspaceGroups.group(id) else { return nil }
            return disclosureView(title: group.name, expanded: group.isExpanded, row: rows[row], identifier: "sidebar.group." + id.uuidString)
        case .emptyGroup: return shellLabel("    Drop workspaces here", secondary: true)
        }
    }

    private static func presentation(_ selection: SidebarSelection) -> (String, String) {
        guard let feature = SidebarFeature(selection) else { return ("Workspace", "terminal") }
        return (feature.title, feature.symbolName)
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
    private let gauge = WorkspaceGaugeView(frame: .zero)
    private let taskBadge = WorkspaceOpenTaskBadgeView(frame: .zero)
    private var coldTicks = 2
    private var workspaceID: UUID?
    private var runningPaneIDs: Set<UUID> = []
    private var nameLeading: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        branch.font = .systemFont(ofSize: 10)
        name.font = .systemFont(ofSize: 12)
        let labels = shellStack([name, branch], spacing: 2)
        // Trailing accessories read left-to-right: gauge, then task badge.
        // A hidden accessory is detached, so a lone one sits at the trailing
        // edge; the labels take the remaining width and truncate first.
        let row = shellStack([labels, gauge, taskBadge], orientation: .horizontal, spacing: 6)
        row.distribution = .fill
        row.detachesHiddenViews = true
        row.setCustomSpacing(4, after: gauge)
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
        gauge.widthAnchor.constraint(equalToConstant: WorkspaceGaugeView.diameter).isActive = true
        gauge.heightAnchor.constraint(equalToConstant: WorkspaceGaugeView.diameter).isActive = true
        taskBadge.heightAnchor.constraint(equalToConstant: WorkspaceOpenTaskBadgeView.diameter).isActive = true
        for accessory in [gauge, taskBadge] as [NSView] {
            accessory.setContentHuggingPriority(.required, for: .horizontal)
            accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        for label in [labels, name, self.branch] as [NSView] {
            label.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
    }
    required init?(coder: NSCoder) { nil }

    /// NSTableRowView sets `.emphasized` on a selected row's cell; the
    /// custom-drawn accessories switch to white-on-accent there.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let emphasized = backgroundStyle == .emphasized
            gauge.isEmphasized = emphasized
            taskBadge.isEmphasized = emphasized
        }
    }

    func configure(workspace: Workspace, branch: String?, openTaskCount: Int, indentation: CGFloat, store: WorkspaceStore) {
        if workspaceID != workspace.id { coldTicks = 2; workspaceID = workspace.id; gauge.started = 0; gauge.running = 0 }
        name.font = CockpitTypography.font(size: 12)
        self.branch.font = CockpitTypography.font(size: 10)
        nameLeading?.constant = 4 + indentation
        name.stringValue = workspace.name
        self.branch.stringValue = branch.map { "⑂ \($0)" } ?? ""
        self.branch.isHidden = branch == nil
        setAccessibilityLabel(workspace.name + (branch.map { ", branch \($0)" } ?? ""))
        taskBadge.count = openTaskCount
        taskBadge.onOpen = { [weak store, weak workspace] in
            guard let store, let workspace else { return }
            store.selectWorkspace(workspace.id)
            workspace.setInspectorTab(.tasks)
            workspace.setInspectorPresented(true)
        }
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
        // Agent Chat panes count too: a live session is started, and it is
        // working while a turn runs or its background subagents do.
        for pane in workspace.panes where pane.kind == .agentChat {
            guard let session = AgentChatRegistry.shared.existingSession(for: pane.id) else { continue }
            started += 1
            if session.phase == .prompting || session.hasBackgroundAgents { running.insert(pane.id) }
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

/// An Inbox row: the job's pane title over "workspace · agent · status",
/// with a state symbol at the trailing edge.
@MainActor
final class AgentJobSidebarCell: NSTableCellView {
    private let title = shellLabel("")
    private let detail = shellLabel("", secondary: true)
    private let status = NSImageView()
    private var job: AgentJob?

    init() {
        super.init(frame: .zero)
        let labels = shellStack([title, detail], spacing: 2)
        let row = shellStack([labels, status], orientation: .horizontal, spacing: 6)
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        status.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        status.setContentHuggingPriority(.required, for: .horizontal)
        status.setContentCompressionResistancePriority(.required, for: .horizontal)
        for label in [labels, title, detail] as [NSView] {
            label.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
    }
    required init?(coder: NSCoder) { nil }

    override var backgroundStyle: NSView.BackgroundStyle { didSet { updateStatusTint() } }

    static func symbolName(for job: AgentJob) -> String {
        switch job.state {
        case .waiting: job.blocker == nil ? "ellipsis.bubble" : "exclamationmark.circle.fill"
        case .working: "arrow.triangle.2.circlepath"
        case .completed: "checkmark.circle.fill"
        }
    }

    func configure(job: AgentJob, workspaceName: String) {
        self.job = job
        title.font = CockpitTypography.font(size: 12)
        detail.font = CockpitTypography.font(size: 10)
        title.stringValue = job.title
        let parts = [workspaceName, job.agentName, job.statusText].filter { !$0.isEmpty }
        detail.stringValue = parts.joined(separator: " · ")
        status.image = NSImage(systemSymbolName: Self.symbolName(for: job), accessibilityDescription: nil)
        status.toolTip = job.statusText
        updateStatusTint()
        setAccessibilityIdentifier("sidebar.job")
        setAccessibilityLabel(([job.title] + parts).joined(separator: ", "))
    }

    private func updateStatusTint() {
        guard let job else { return }
        if backgroundStyle == .emphasized { status.contentTintColor = .white; return }
        status.contentTintColor = switch job.state {
        case .waiting: job.blocker == nil ? .secondaryLabelColor : .systemOrange
        case .working: .controlAccentColor
        case .completed: .systemGreen
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
