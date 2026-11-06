import AppKit
import Observation

@MainActor
enum InspectorNativeUI {
    static func font(_ size: CGFloat = 12, weight: NSFont.Weight = .regular, defaults: UserDefaults = .standard) -> NSFont {
        .systemFont(ofSize: size * zoom(defaults: defaults), weight: weight)
    }
    static func zoom(defaults: UserDefaults) -> Double {
        if defaults === UserDefaults.standard { return CockpitUIZoomController.shared.factor }
        return UIZoomLadder.normalized(defaults.double(forKey: "ui.zoom"))
    }
    static func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor, defaults: UserDefaults = .standard) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font(size, weight: weight, defaults: defaults)
        field.textColor = color
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    static func vertical(_ children: [NSView] = [], spacing: CGFloat = 8) -> InspectorVerticalStack {
        let stack = InspectorVerticalStack()
        children.forEach(stack.addArrangedSubview)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }
    static func horizontal(_ children: [NSView] = [], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: children)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }
    static func pin(_ child: NSView, in parent: NSView, inset: CGFloat = 0) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
        ])
    }
    static func scrollDocument(_ document: NSView, in scroll: NSScrollView, inset: CGFloat = 12) {
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let container = InspectorFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(document)
        container.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = container
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            document.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            document.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            document.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset),
        ])
    }
}
/// AppKit stacks align edges; equal-width constraints make vertical content
/// fill its available column and allow wrapping labels to measure correctly.
@MainActor
final class InspectorVerticalStack: NSStackView {
    var fillsWidth = false { didSet { synchronizeWidths() } }
    private var widthConstraints: [ObjectIdentifier: NSLayoutConstraint] = [:]
    override func addArrangedSubview(_ view: NSView) {
        super.addArrangedSubview(view)
        synchronizeWidths()
    }
    override func removeArrangedSubview(_ view: NSView) {
        widthConstraints.removeValue(forKey: ObjectIdentifier(view))?.isActive = false
        super.removeArrangedSubview(view)
    }
    private func synchronizeWidths() {
        if fillsWidth {
            for child in arrangedSubviews where widthConstraints[ObjectIdentifier(child)] == nil {
                child.translatesAutoresizingMaskIntoConstraints = false
                let constraint = child.widthAnchor.constraint(equalTo: widthAnchor)
                constraint.isActive = true
                widthConstraints[ObjectIdentifier(child)] = constraint
            }
        } else {
            widthConstraints.values.forEach { $0.isActive = false }
            widthConstraints.removeAll()
        }
    }
}
final class InspectorFlippedView: NSView {
    override var isFlipped: Bool { true }
}
@MainActor
final class InspectorActionButton: NSButton {
    var handler: (() -> Void)?
    init(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        controlSize = .small
        target = self
        action = #selector(performHandler)
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        }
    }
    required init?(coder: NSCoder) { nil }
    @objc private func performHandler() { handler?() }
}
@MainActor
final class InspectorSectionHeader: NSView {
    private let titleField = InspectorNativeUI.label("", weight: .medium, color: .secondaryLabelColor)
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let refreshButton = InspectorActionButton("", symbol: "arrow.clockwise", handler: {})
    var refresh: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        icon.setAccessibilityElement(false)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        refreshButton.handler = { [weak self] in self?.refresh?() }
        InspectorNativeUI.pin(InspectorNativeUI.horizontal([icon, titleField, NSView(), spinner, refreshButton]), in: self, inset: 8)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            refreshButton.widthAnchor.constraint(equalToConstant: 26),
            spinner.widthAnchor.constraint(equalToConstant: 16),
        ])
    }
    required init?(coder: NSCoder) { nil }
    func update(title: String, symbol: String, loading: Bool = false, refreshHelp: String? = nil,
                refreshEnabled: Bool = true, defaults: UserDefaults = .standard) {
        titleField.stringValue = title
        titleField.font = InspectorNativeUI.font(12, weight: .medium, defaults: defaults)
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.maximumNumberOfLines = 1
        titleField.toolTip = title
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        refreshButton.isHidden = refreshHelp == nil
        refreshButton.toolTip = refreshHelp
        refreshButton.setAccessibilityLabel(refreshHelp ?? "Refresh")
        refreshButton.isEnabled = refreshEnabled && !loading
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
}
enum InspectorCardMetrics {
    static let padding: CGFloat = 8
    static let cornerRadius: CGFloat = 12
}

/// The workspace owns tab selection; this controller owns only visible UI and polling.
@MainActor
final class InspectorViewController: NSViewController {
    private(set) var workspace: Workspace
    let gitStore: RepositoryStore
    let tasksStore: GitHubTasksStore
    let usageStore: UsageStore
    let defaults: UserDefaults
    let isLive: Bool
    var onOpenFile: ((URL) -> Void)?
    var onOpenUsageSettings: (() -> Void)?
    var onSendIssuePrompt: ((String) -> Void)?
    private var isActive = false
    private var observationGeneration = 0
    private var observedRoot: String?
    private var observedTab: InspectorTab?
    private var preferencesObserver: NSObjectProtocol?
    private var zoomObserver: NSObjectProtocol?
    private var ageTimer: Timer?
    private var displayedTab: InspectorTab?
    private let bodyHost = NSView()
    private let header = InspectorSectionHeader()
    private let tabs = NSSegmentedControl(labels: InspectorTab.allCases.map(\.rawValue),
                                          trackingMode: .selectOne, target: nil, action: nil)
    private let list = InspectorRepositoryListView()
    private lazy var filesystem = FileSystemOutlineViewController()
    private lazy var usage = UsageViewController(store: usageStore, defaults: defaults)

    init(workspace: Workspace, usageStore: UsageStore, gitStore: RepositoryStore = RepositoryStore(),
         tasksStore: GitHubTasksStore = GitHubTasksStore(), defaults: UserDefaults = .standard, isLive: Bool = true) {
        self.workspace = workspace
        self.usageStore = usageStore
        self.gitStore = gitStore
        self.tasksStore = tasksStore
        self.defaults = defaults
        self.isLive = isLive
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        view = NSView()
        tabs.segmentStyle = .rounded
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.setAccessibilityLabel("Inspector view")
        tabs.identifier = .init("inspector.tabs")
        let layout = InspectorNativeUI.vertical([tabs, header, bodyHost], spacing: 0)
        layout.fillsWidth = true
        InspectorNativeUI.pin(layout, in: view)
        tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        bodyHost.setContentHuggingPriority(.defaultLow, for: .vertical)
        header.refresh = { [weak self] in self?.refreshSelectedTab() }
        list.onOpen = { [weak self] row in self?.open(row) }
        list.onImplement = { [weak self] number in self?.sendImplementationPrompt(number: number) }
        filesystem.onOpenFile = { [weak self] url in self?.onOpenFile?(url) }
        usage.onOpenSettings = { [weak self] in self?.onOpenUsageSettings?() }
        render()
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        setPresentationActive(true)
    }
    override func viewWillDisappear() {
        setPresentationActive(false)
        super.viewWillDisappear()
    }
    isolated deinit { setPresentationActive(false) }

    func update(workspace: Workspace) {
        if self.workspace !== workspace {
            self.workspace = workspace
            observedRoot = nil
            observedTab = nil
        }
        refresh()
    }
    func selectTab(_ tab: InspectorTab) {
        guard workspace.inspectorTab != tab else { return }
        workspace.setInspectorTab(tab)
        refresh()
    }
    func setPresentationActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        observationGeneration += 1
        if active {
            _ = view
            preferencesObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isActive else { return }
                    self.render()
                }
            }
            zoomObserver = NotificationCenter.default.addObserver(
                forName: .cockpitUIZoomDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isActive else { return }
                    self.render()
                }
            }
            ageTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isActive else { return }
                    if self.workspace.inspectorTab == .tasks { self.render() }
                }
            }
            observe(generation: observationGeneration)
        } else {
            ageTimer?.invalidate()
            ageTimer = nil
            if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
            preferencesObserver = nil
            if let zoomObserver { NotificationCenter.default.removeObserver(zoomObserver) }
            zoomObserver = nil
            observedRoot = nil
            observedTab = nil
            usage.setPresentationActive(false)
            if isLive {
                // Usage has no repository polling. Suspend the native lists
                // without discarding their cached rows when the sidebar hides.
                gitStore.setVisibleTab(.usage)
                tasksStore.load(directory: workspace.effectiveRootPath, isVisible: false)
            }
        }
    }
    func refresh() {
        if isActive {
            observationGeneration += 1
            observe(generation: observationGeneration)
        } else if isViewLoaded { render() }
    }
    private func observe(generation: Int) {
        guard isActive, generation == observationGeneration else { return }
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isActive, generation == self.observationGeneration else { return }
                self.observe(generation: generation)
            }
        }
    }
    @objc private func tabChanged() {
        let index = tabs.selectedSegment
        guard InspectorTab.allCases.indices.contains(index) else { return }
        selectTab(InspectorTab.allCases[index])
    }
    private func synchronizePolling(tab: InspectorTab, root: String?) {
        guard isLive, isActive, root != observedRoot || tab != observedTab else { return }
        observedRoot = root
        observedTab = tab
        guard let root, !root.isEmpty else {
            gitStore.stopWatching()
            tasksStore.load(directory: nil)
            return
        }
        gitStore.startWatching(directory: root, visibleTab: tab)
        tasksStore.load(directory: root, isVisible: tab == .tasks)
        if tab == .usage { usageStore.reload() }
    }
    private func render() {
        guard isViewLoaded else { return }
        let tab = workspace.inspectorTab
        tabs.selectedSegment = InspectorTab.allCases.firstIndex(of: tab) ?? 0
        tabs.font = InspectorNativeUI.font(11, defaults: defaults)
        synchronizePolling(tab: tab, root: workspace.effectiveRootPath)
        if displayedTab != tab {
            usage.setPresentationActive(false)
            for child in children { child.removeFromParent() }
            bodyHost.subviews.forEach { $0.removeFromSuperview() }
            header.isHidden = tab == .usage
            switch tab {
            case .filesystem:
                addChild(filesystem)
                InspectorNativeUI.pin(filesystem.view, in: bodyHost)
            case .usage:
                addChild(usage)
                InspectorNativeUI.pin(usage.view, in: bodyHost)
            default: InspectorNativeUI.pin(list, in: bodyHost)
            }
            displayedTab = tab
        }
        switch tab {
        case .filesystem:
            header.update(title: gitStore.repoPath, symbol: "folder", loading: gitStore.isLoadingFilesystem, defaults: defaults)
            filesystem.update(entries: gitStore.filesystem, rootPath: gitStore.repoPath,
                              uiZoom: InspectorNativeUI.zoom(defaults: defaults), loading: gitStore.isLoadingFilesystem)
        case .usage:
            usage.setPresentationActive(isActive)
            usage.refresh()
        case .tasks:
            header.update(title: tasksStore.tasks.isEmpty ? "Issues" : "\(tasksStore.tasks.count) open",
                          symbol: "checkmark.square", loading: tasksStore.isLoading, refreshHelp: "Refresh GitHub issues", defaults: defaults)
            list.update(rows: tasksStore.tasks.map(InspectorRepositoryRow.init(task:)),
                        emptyTitle: tasksStore.isLoading ? "Loading Issues…" : (tasksStore.errorMessage == nil ? "No Open Issues" : "Couldn’t Load Issues"),
                        detail: tasksStore.errorMessage ?? "This repository has no open GitHub issues.", loading: tasksStore.isLoading,
                        retry: tasksStore.errorMessage == nil ? nil : { [weak self] in self?.tasksStore.refresh() }, defaults: defaults)
        case .pullRequests:
            let loading = gitStore.isLoading && !gitStore.hasLoadedPullRequests
            header.update(title: gitStore.repositoryName, symbol: "arrow.triangle.pull", loading: loading,
                          refreshHelp: "Refresh pull requests", refreshEnabled: !gitStore.repoPath.isEmpty, defaults: defaults)
            list.update(rows: gitStore.pullRequests.map(InspectorRepositoryRow.init(pullRequest:)),
                        emptyTitle: loading ? "Loading Pull Requests…" : (gitStore.pullRequestError == nil ? "No Pull Requests" : "Couldn’t Load Pull Requests"),
                        detail: gitStore.pullRequestError ?? (gitStore.repoPath.isEmpty ? "Select a workspace with a GitHub repository root path." : "This repository has no open pull requests."),
                        loading: loading, retry: gitStore.pullRequestError == nil ? nil : { [weak self] in self?.gitStore.fetchPullRequests(policy: .manual) }, defaults: defaults)
        case .actions:
            let loading = gitStore.workflowRunsOverlay == .loading
            header.update(title: gitStore.repositoryName, symbol: "folder", loading: loading,
                          refreshHelp: "Refresh actions", refreshEnabled: !gitStore.repoPath.isEmpty, defaults: defaults)
            list.update(rows: gitStore.actions.map(InspectorRepositoryRow.init(action:)),
                        emptyTitle: loading ? "Loading Actions…" : (gitStore.workflowError == nil ? "No Actions" : "Couldn’t Load Actions"),
                        detail: gitStore.workflowError ?? (gitStore.repoPath.isEmpty ? "Select a workspace with a GitHub repository root path." : "No GitHub Actions workflow runs for this repository."),
                        loading: loading, retry: gitStore.workflowError == nil ? nil : { [weak self] in self?.gitStore.fetchWorkflowRuns(policy: .manual) }, defaults: defaults)
        }
    }
    private func refreshSelectedTab() {
        switch workspace.inspectorTab {
        case .actions: gitStore.fetchWorkflowRuns(policy: .manual)
        case .tasks: tasksStore.refresh()
        case .pullRequests: gitStore.fetchPullRequests(policy: .manual)
        case .filesystem: gitStore.fetchFilesystem()
        case .usage: usageStore.reload()
        }
    }
    private func open(_ row: InspectorRepositoryRow) {
        guard let url = URL(string: row.url), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
    private func sendImplementationPrompt(number: Int) {
        let prompt = "Implement GitHub issue #\(number). "
            + "Read it first with `gh issue view \(number)`, then build and apply the fix. "
            + "When you open the pull request, include `fixes #\(number)` in the commit "
            + "message so merging auto-closes the issue."
        if let onSendIssuePrompt {
            onSendIssuePrompt(prompt)
        } else {
            NotificationCenter.default.post(name: .pilotSendIssuePrompt, object: nil, userInfo: ["prompt": prompt])
        }
    }
}

private struct InspectorRepositoryRow: Equatable {
    let id: String
    let title: String
    let metadata: String
    let detail: String
    let url: String
    let symbol: String
    let color: NSColor
    var issueNumber: Int?
    var busy = false
    init(task: GitHubTask) {
        id = "issue-\(task.number)"
        title = task.title
        metadata = [task.assignees.map(\.login).joined(separator: ", "), task.age].filter { !$0.isEmpty }.joined(separator: " · ")
        detail = task.assignees.map(\.fullDescription).joined(separator: ", ")
        url = task.url
        symbol = "checkmark.circle"
        color = .systemGreen
        issueNumber = task.number
    }
    init(pullRequest: GitPullRequest) {
        id = "pr-\(pullRequest.id)"
        title = pullRequest.title
        metadata = ["#\(pullRequest.id)", pullRequest.author, pullRequest.elapsed].filter { !$0.isEmpty }.joined(separator: " · ")
        detail = pullRequest.headBranch
        url = pullRequest.url
        switch pullRequest.state {
        case "MERGED": (symbol, color) = ("arrow.triangle.merge", .systemPurple)
        case "CLOSED": (symbol, color) = ("xmark.circle.fill", .systemRed)
        case "OPEN" where pullRequest.isDraft: (symbol, color) = ("circle.dashed", .secondaryLabelColor)
        case "OPEN": (symbol, color) = ("arrow.triangle.pull", .systemGreen)
        default: (symbol, color) = ("circle", .secondaryLabelColor)
        }
    }
    init(action: GitAction) {
        id = "action-\(action.id)"
        title = action.displayTitle
        detail = [action.name, action.headBranch].filter { !$0.isEmpty }.joined(separator: " · ")
        metadata = [String(action.headSha.prefix(7)), action.actor, action.duration, action.elapsed].filter { !$0.isEmpty }.joined(separator: " · ")
        url = action.url
        switch action.conclusion {
        case "success": (symbol, color) = ("checkmark.circle.fill", .systemGreen)
        case "failure": (symbol, color) = ("xmark.circle.fill", .systemRed)
        case "cancelled": (symbol, color) = ("slash.circle.fill", .secondaryLabelColor)
        default:
            busy = action.status == "in_progress"
            (symbol, color) = (busy ? "arrow.triangle.2.circlepath" : "clock.circle", busy ? .systemOrange : .secondaryLabelColor)
        }
    }
}

@MainActor
private final class InspectorRepositoryTableView: NSTableView {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, let doubleAction {
            NSApp.sendAction(doubleAction, to: target, from: self)
        } else { super.keyDown(with: event) }
    }
}

@MainActor
private final class InspectorRepositoryListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onOpen: ((InspectorRepositoryRow) -> Void)?
    var onImplement: ((Int) -> Void)?
    private let table = InspectorRepositoryTableView()
    private let scroll = NSScrollView()
    private let empty = InspectorNativeUI.vertical(spacing: 12)
    private let emptyTitle = InspectorNativeUI.label("", weight: .semibold)
    private let emptyDetail = InspectorNativeUI.label("", color: .secondaryLabelColor)
    private let spinner = NSProgressIndicator()
    private let retry = InspectorActionButton("Retry", handler: {})
    private var rows: [InspectorRepositoryRow] = []
    private var defaults = UserDefaults.standard
    private var zoom = 1.0
    override init(frame: NSRect) {
        super.init(frame: frame)
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.rowHeight = 88
        table.intercellSpacing = NSSize(width: 0, height: 8)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        let column = NSTableColumn(identifier: .init("content"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        InspectorNativeUI.pin(scroll, in: self, inset: 8)
        empty.alignment = .centerX
        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false
        [emptyTitle, emptyDetail, spinner, retry].forEach(empty.addArrangedSubview)
        empty.translatesAutoresizingMaskIntoConstraints = false
        addSubview(empty)
        NSLayoutConstraint.activate([
            empty.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            empty.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { nil }
    func update(rows next: [InspectorRepositoryRow], emptyTitle: String, detail: String, loading: Bool,
                retry action: (() -> Void)?, defaults: UserDefaults) {
        self.defaults = defaults
        let newZoom = InspectorNativeUI.zoom(defaults: defaults)
        let oldRows = rows
        rows = next
        if oldRows.map(\.id) != next.map(\.id) || zoom != newZoom {
            let selected = oldRows.indices.contains(table.selectedRow) ? oldRows[table.selectedRow].id : nil
            let origin = scroll.contentView.bounds.origin
            zoom = newZoom
            table.rowHeight = 88 * newZoom
            table.reloadData()
            if let selected, let index = next.firstIndex(where: { $0.id == selected }) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
            scroll.contentView.scroll(to: origin)
        } else {
            let changed = IndexSet(next.indices.filter { next[$0] != oldRows[$0] })
            if !changed.isEmpty { table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0)) }
        }
        empty.isHidden = !next.isEmpty
        scroll.isHidden = next.isEmpty
        self.emptyTitle.stringValue = emptyTitle
        emptyDetail.stringValue = detail
        self.emptyTitle.font = InspectorNativeUI.font(13, weight: .semibold, defaults: defaults)
        emptyDetail.font = InspectorNativeUI.font(defaults: defaults)
        retry.handler = action
        retry.isHidden = action == nil
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("inspector.repository.row")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? InspectorRepositoryCell) ?? InspectorRepositoryCell()
        cell.identifier = id
        let model = rows[row]
        cell.configure(model, defaults: defaults, open: { [weak self] in self?.onOpen?(model) }, implement: { [weak self] in
            guard let number = model.issueNumber else { return }
            self?.onImplement?(number)
        })
        return cell
    }
    @objc private func openSelected() {
        guard rows.indices.contains(table.selectedRow) else { return }
        onOpen?(rows[table.selectedRow])
    }
}
@MainActor
private final class InspectorRepositoryCell: NSTableCellView {
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let number = InspectorActionButton("", handler: {})
    private let title = InspectorActionButton("", handler: {})
    private let detail = InspectorNativeUI.label("", color: .secondaryLabelColor)
    private let metadata = InspectorNativeUI.label("", size: 11, color: .secondaryLabelColor)
    private var confirmationTask: Task<Void, Never>?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = InspectorCardMetrics.cornerRadius
        title.isBordered = false
        title.alignment = .left
        title.cell?.wraps = true
        title.cell?.truncatesLastVisibleLine = true
        detail.maximumNumberOfLines = 1
        detail.lineBreakMode = .byTruncatingMiddle
        metadata.maximumNumberOfLines = 1
        metadata.lineBreakMode = .byTruncatingTail
        let text = InspectorNativeUI.vertical([title, detail, metadata], spacing: 2)
        text.fillsWidth = true
        let leading = InspectorNativeUI.vertical([icon, spinner, number], spacing: 4)
        leading.alignment = .centerX
        let row = InspectorNativeUI.horizontal([leading, text])
        row.alignment = .top
        InspectorNativeUI.pin(row, in: self, inset: 8)
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
    }
    func configure(_ row: InspectorRepositoryRow, defaults: UserDefaults, open: @escaping () -> Void, implement: @escaping () -> Void) {
        confirmationTask?.cancel()
        confirmationTask = nil
        title.title = row.title
        title.font = InspectorNativeUI.font(defaults: defaults)
        title.handler = open
        title.isEnabled = !row.url.isEmpty
        title.toolTip = "Open on GitHub"
        title.setAccessibilityLabel(row.title)
        detail.stringValue = row.detail
        detail.isHidden = row.detail.isEmpty
        metadata.stringValue = row.metadata
        metadata.toolTip = [row.detail, row.metadata].joined(separator: " · ")
        detail.font = InspectorNativeUI.font(11, defaults: defaults)
        metadata.font = InspectorNativeUI.font(11, defaults: defaults)
        icon.image = NSImage(systemSymbolName: row.symbol, accessibilityDescription: row.symbol)
        icon.contentTintColor = row.color
        icon.isHidden = row.issueNumber != nil || row.busy
        if row.busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        number.isHidden = row.issueNumber == nil
        if let issue = row.issueNumber {
            number.title = "#\(issue)"
            number.font = .monospacedSystemFont(ofSize: InspectorNativeUI.font(defaults: defaults).pointSize, weight: .semibold)
            number.setAccessibilityLabel("Implement issue \(issue)")
            number.toolTip = "Run an implement #\(issue) task in the active terminal"
            number.handler = { [weak self] in
                implement()
                self?.number.title = "✓\(issue)"
                self?.confirmationTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    self?.number.title = "#\(issue)"
                }
            }
        }
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
    }
}

@MainActor
final class FileSystemOutlineViewController: NSViewController {
    var onOpenFile: ((URL) -> Void)? { didSet { coordinator.onOpenFile = onOpenFile } }
    private let outline = ClickableFileSystemOutlineView()
    private let coordinator = Coordinator(entries: [], rootPath: "", uiZoom: 1)
    private let empty = InspectorNativeUI.label("No Files\nSelect a workspace with a repository root path.", color: .secondaryLabelColor)
    override func loadView() {
        view = NSView()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        outline.headerView = nil
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.rowSizeStyle = .small
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.indentationPerLevel = 14
        outline.delegate = coordinator
        outline.dataSource = coordinator
        outline.target = coordinator
        outline.doubleAction = #selector(Coordinator.openSelected(_:))
        let column = NSTableColumn(identifier: .init("FileSystemColumn"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        scroll.documentView = outline
        InspectorNativeUI.pin(scroll, in: view)
        empty.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            empty.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            empty.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])
    }
    func update(entries: [FileSystemEntry], rootPath: String, uiZoom: Double, loading: Bool = false) {
        _ = view
        empty.isHidden = !entries.isEmpty || loading
        coordinator.reload(outlineView: outline, entries: entries, rootPath: rootPath, uiZoom: uiZoom)
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var onOpenFile: ((URL) -> Void)?
        private var nodes: [FileSystemNode]
        private var expandedIDs: Set<String> = []
        private var rootURL: URL
        private var rowFont: NSFont
        private var loadedEntries: [FileSystemEntry]?
        private var loadedUIZoom: Double?

        init(entries: [FileSystemEntry], rootPath: String, uiZoom: Double) {
            self.nodes = entries.map(FileSystemNode.init(entry:))
            self.rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            self.rowFont = Self.fileTreeFont(uiZoom: uiZoom)
        }

        func reload(
            outlineView: NSOutlineView,
            entries: [FileSystemEntry],
            rootPath: String,
            uiZoom: Double
        ) {
            let newRootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            guard entries != loadedEntries || newRootURL.path != rootURL.path || uiZoom != loadedUIZoom else {
                return
            }
            let sameRoot = rootURL.path == newRootURL.path
            let selectedID = sameRoot ? (outlineView.item(atRow: outlineView.selectedRow) as? FileSystemNode)?.entry.id : nil
            let origin = outlineView.enclosingScrollView?.contentView.bounds.origin
            if sameRoot {
                captureExpandedIDs(from: outlineView)
            } else {
                expandedIDs.removeAll()
            }
            rootURL = newRootURL
            loadedEntries = entries
            loadedUIZoom = uiZoom
            nodes = entries.map(FileSystemNode.init(entry:))
            rowFont = Self.fileTreeFont(uiZoom: uiZoom)
            outlineView.rowHeight = max(
                20,
                ceil(rowFont.ascender - rowFont.descender + rowFont.leading) + 4
            )
            outlineView.reloadData()
            restoreExpandedNodes(in: outlineView, nodes: nodes)
            if let selectedID, let row = (0..<outlineView.numberOfRows).first(where: {
                (outlineView.item(atRow: $0) as? FileSystemNode)?.entry.id == selectedID
            }) {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            if sameRoot, let origin { outlineView.enclosingScrollView?.contentView.scroll(to: origin) }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            children(for: item).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            children(for: item)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? FileSystemNode else { return false }
            return node.isExpandable
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            true
        }

        @objc func openSelected(_ outlineView: NSOutlineView) {
            guard let node = outlineView.item(atRow: outlineView.selectedRow) as? FileSystemNode, !node.entry.isDirectory else { return }
            onOpenFile?(URL(fileURLWithPath: node.entry.path))
        }

        func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
            guard let node = item as? FileSystemNode else { return false }
            loadChildrenIfNeeded(for: node)
            outlineView.reloadItem(node, reloadChildren: true)
            return node.isExpandable
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? FileSystemNode else { return nil }

            let identifier = NSUserInterfaceItemIdentifier("FileSystemCell")
            let view = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? FileSystemOutlineCellView)
                ?? FileSystemOutlineCellView()
            view.identifier = identifier
            view.configure(with: node.entry, font: rowFont)
            return view
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? FileSystemNode else { return }
            expandedIDs.insert(node.entry.id)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? FileSystemNode else { return }
            expandedIDs.remove(node.entry.id)
        }

        private func children(for item: Any?) -> [FileSystemNode] {
            guard let node = item as? FileSystemNode else { return nodes }
            return node.children
        }

        private func captureExpandedIDs(from outlineView: NSOutlineView) {
            expandedIDs.removeAll(keepingCapacity: true)

            for row in 0..<outlineView.numberOfRows {
                guard let node = outlineView.item(atRow: row) as? FileSystemNode,
                      outlineView.isItemExpanded(node) else { continue }
                expandedIDs.insert(node.entry.id)
            }
        }

        private func restoreExpandedNodes(in outlineView: NSOutlineView, nodes: [FileSystemNode]) {
            for node in nodes {
                restoreExpandedNode(node, in: outlineView)
            }
        }

        private func restoreExpandedNode(_ node: FileSystemNode, in outlineView: NSOutlineView) {
            guard node.entry.isDirectory else { return }

            if expandedIDs.contains(node.entry.id) {
                loadChildrenIfNeeded(for: node)
                outlineView.expandItem(node)
            }

            for child in node.children {
                restoreExpandedNode(child, in: outlineView)
            }
        }

        private func loadChildrenIfNeeded(for node: FileSystemNode) {
            guard node.entry.isDirectory, !node.hasLoadedChildren else { return }
            let directoryURL = URL(fileURLWithPath: node.entry.path, isDirectory: true)
            let entries = RepositoryStore.listFilesystemEntries(at: directoryURL, rootURL: rootURL)
            node.children = entries.map(FileSystemNode.init(entry:))
            node.hasLoadedChildren = true
        }

        private static func fileTreeFont(uiZoom: Double) -> NSFont {
            let preferredFont = NSFont.preferredFont(forTextStyle: .callout)
            return NSFontManager.shared.convert(
                preferredFont,
                toSize: preferredFont.pointSize * CGFloat(uiZoom)
            )
        }
    }
}

/// `NSOutlineView` only expands a row when its small disclosure control is
/// clicked. Keep the existing single-click folder expansion while supporting
/// native keyboard selection and Return to open a file.
private final class ClickableFileSystemOutlineView: NSOutlineView {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, let doubleAction {
            NSApp.sendAction(doubleAction, to: target, from: self)
        } else { super.keyDown(with: event) }
    }
    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: location)
        let clickedDisclosure = clickedRow >= 0
            && frameOfOutlineCell(atRow: clickedRow).contains(location)

        // Preserve AppKit's native disclosure-button behavior and normal
        // handling for files, blank space, and multi-click gestures.
        super.mouseDown(with: event)

        guard event.clickCount == 1,
              clickedRow >= 0,
              !clickedDisclosure,
              let node = item(atRow: clickedRow) as? FileSystemNode,
              node.entry.isDirectory else { return }

        if isItemExpanded(node) {
            collapseItem(node)
        } else {
            expandItem(node)
        }
    }
}

private final class FileSystemNode: NSObject {
    let entry: FileSystemEntry
    var children: [FileSystemNode]
    var hasLoadedChildren: Bool

    var isExpandable: Bool {
        entry.isDirectory && (!hasLoadedChildren || !children.isEmpty)
    }

    init(entry: FileSystemEntry) {
        self.entry = entry
        self.children = (entry.children ?? []).map(FileSystemNode.init(entry:))
        self.hasLoadedChildren = entry.children != nil
    }
}

private final class FileSystemOutlineCellView: NSTableCellView {
    private let titleField = NSTextField(labelWithString: "")
    private let iconView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)

        titleField.font = .preferredFont(forTextStyle: .callout)
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(titleField)

        addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])

        imageView = iconView
        textField = titleField
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    func configure(with entry: FileSystemEntry, font: NSFont) {
        titleField.stringValue = entry.name
        titleField.font = font
        toolTip = entry.relativePath
        iconView.image = fileIcon(for: entry.path)
    }

    private func fileIcon(for path: String) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}
