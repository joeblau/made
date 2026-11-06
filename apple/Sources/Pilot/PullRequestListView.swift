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
/// The workspace owns tab selection; this controller owns only visible UI and polling.
@MainActor
final class InspectorViewController: NSViewController {
    private(set) var workspace: Workspace
    let gitStore: RepositoryStore
    let tasksStore: GitHubTasksStore
    let usageStore: UsageStore
    let defaults: UserDefaults
    let isLive: Bool
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
        let tabHeader = NSView()
        tabHeader.addSubview(tabs)
        let inset = LiquidGlassMetrics.Spacing.xSmall
        tabs.cockpitPinToEdges(of: tabHeader, insets: NSEdgeInsets(top: 0, left: inset, bottom: 0, right: inset))
        let layout = InspectorNativeUI.vertical([tabHeader, header, bodyHost], spacing: 0)
        layout.fillsWidth = true
        InspectorNativeUI.pin(layout, in: view)
        tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        bodyHost.setContentHuggingPriority(.defaultLow, for: .vertical)
        header.refresh = { [weak self] in self?.refreshSelectedTab() }
        list.onOpen = { [weak self] row in self?.open(row) }
        list.onImplement = { [weak self] number in self?.sendImplementationPrompt(number: number) }
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
        let changingTab = displayedTab != nil && displayedTab != tab
        defer { if changingTab { CockpitMotion.reveal(bodyHost) } }
        tabs.selectedSegment = InspectorTab.allCases.firstIndex(of: tab) ?? 0
        tabs.font = InspectorNativeUI.font(11, defaults: defaults)
        synchronizePolling(tab: tab, root: workspace.effectiveRootPath)
        if displayedTab != tab {
            usage.setPresentationActive(false)
            header.isHidden = tab == .usage
            let target: NSView
            switch tab {
            case .usage:
                if usage.parent == nil { addChild(usage) }
                target = usage.view
            default: target = list
            }
            // Keep visited native surfaces and their constraints attached.
            // Inactive polling is stopped explicitly; visibility changes avoid
            // rebuilding AppKit's layout engine and key-view loop on every tab.
            if target.superview == nil { InspectorNativeUI.pin(target, in: bodyHost) }
            for child in bodyHost.subviews { child.isHidden = child !== target }
            displayedTab = tab
        }
        switch tab {
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
    /// Row titles are link-style labels; let them receive clicks instead of
    /// the table swallowing them for selection.
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        (responder as? InspectorLinkLabel)?.handler != nil || super.validateProposedFirstResponder(responder, for: event)
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
    private var measuredWidth: CGFloat = 0
    override init(frame: NSRect) {
        super.init(frame: frame)
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.rowHeight = 64
        table.intercellSpacing = NSSize(width: 0, height: 2)
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
            table.rowHeight = 64 * newZoom
            table.reloadData()
            if let selected, let index = next.firstIndex(where: { $0.id == selected }) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
            scroll.contentView.scroll(to: origin)
        } else {
            let changed = IndexSet(next.indices.filter { next[$0] != oldRows[$0] })
            if !changed.isEmpty {
                table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
                table.noteHeightOfRows(withIndexesChanged: changed)
            }
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
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { CockpitCardRowView() }
    override func layout() {
        super.layout()
        let width = table.tableColumns.first?.width ?? 0
        guard abs(width - measuredWidth) > 1 else { return }
        measuredWidth = width
        table.noteHeightOfRows(withIndexesChanged: IndexSet(rows.indices))
    }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        InspectorRepositoryCell.preferredHeight(for: rows[row], width: table.tableColumns.first?.width ?? 0, defaults: defaults)
    }
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
/// A wrapping label that behaves like a link: it opens on click without the
/// bezel insets of a button, so it measures exactly like it renders.
@MainActor
private final class InspectorLinkLabel: NSTextField {
    var handler: (() -> Void)? { didSet { window?.invalidateCursorRects(for: self) } }
    override func mouseDown(with event: NSEvent) {
        if handler == nil { super.mouseDown(with: event) }
    }
    override func mouseUp(with event: NSEvent) {
        guard let handler else { return super.mouseUp(with: event) }
        if event.clickCount == 1, bounds.contains(convert(event.locationInWindow, from: nil)) { handler() }
    }
    override func resetCursorRects() {
        if handler != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }
    override func accessibilityRole() -> NSAccessibility.Role? { handler == nil ? super.accessibilityRole() : .link }
    override func accessibilityPerformPress() -> Bool {
        guard let handler else { return false }
        handler()
        return true
    }
}

/// Compact rounded issue-number chip; drawn by hand so its frame equals its
/// visible bounds and it can be aligned to the title's first line.
@MainActor
private final class InspectorIssueChip: NSButton {
    var handler: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryPushIn)
        alignment = .center
        contentTintColor = .labelColor
        target = self
        action = #selector(performHandler)
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5)
        (isHighlighted ? NSColor.tertiaryLabelColor : NSColor.quaternaryLabelColor).setFill()
        path.fill()
        super.draw(dirtyRect)
    }
    @objc private func performHandler() { handler?() }
}

@MainActor
private final class InspectorRepositoryCell: NSTableCellView {
    private static let horizontalInset: CGFloat = 12
    private static let verticalInset: CGFloat = 10
    private static let columnSpacing: CGFloat = 8
    private static let lineSpacing: CGFloat = 2
    private static let measuring = InspectorRepositoryCell()

    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let number = InspectorIssueChip()
    private let leadingColumn = NSView()
    private let title = InspectorLinkLabel(wrappingLabelWithString: "")
    private let detail = InspectorNativeUI.label("", color: .secondaryLabelColor)
    private let metadata = InspectorNativeUI.label("", size: 11, color: .secondaryLabelColor)
    private let textColumn = NSStackView()
    private var leadingWidth: NSLayoutConstraint!
    private var leadingFirstLineCenter: NSLayoutConstraint!
    private var chipHeight: NSLayoutConstraint!
    private var confirmationTask: Task<Void, Never>?

    /// Exact row height for `width`, measured with the same views and fonts the
    /// visible cell uses so wrapping and truncation never disagree.
    static func preferredHeight(for row: InspectorRepositoryRow, width: CGFloat, defaults: UserDefaults) -> CGFloat {
        let cell = measuring
        cell.configure(row, defaults: defaults, open: {}, implement: {})
        let textWidth = max(1, width - 2 * horizontalInset - cell.leadingWidth.constant - columnSpacing)
        cell.title.preferredMaxLayoutWidth = textWidth
        var height = cell.title.intrinsicContentSize.height
        for field in [cell.detail, cell.metadata] where !field.isHidden {
            height += lineSpacing + field.intrinsicContentSize.height
        }
        return ceil(height + 2 * verticalInset)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.isSelectable = false
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byWordWrapping
        title.cell?.truncatesLastVisibleLine = true
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.required, for: .vertical)
        detail.maximumNumberOfLines = 1
        detail.lineBreakMode = .byTruncatingMiddle
        metadata.maximumNumberOfLines = 1
        metadata.lineBreakMode = .byTruncatingTail
        for field in [detail, metadata] {
            field.cell?.wraps = false
            field.setContentCompressionResistancePriority(.required, for: .vertical)
        }

        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.distribution = .fill
        textColumn.spacing = Self.lineSpacing
        textColumn.detachesHiddenViews = true
        for field in [title, detail, metadata] as [NSView] {
            textColumn.addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: textColumn.widthAnchor).isActive = true
        }

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        icon.imageScaling = .scaleProportionallyDown
        for view in [leadingColumn, textColumn, icon, spinner, number] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(leadingColumn)
        addSubview(textColumn)
        [icon, spinner, number].forEach(leadingColumn.addSubview)

        leadingWidth = leadingColumn.widthAnchor.constraint(equalToConstant: 16)
        // Center leading accessories on the title's first line, not the card.
        leadingFirstLineCenter = icon.centerYAnchor.constraint(equalTo: title.topAnchor, constant: 8)
        chipHeight = number.heightAnchor.constraint(equalToConstant: 18)
        NSLayoutConstraint.activate([
            leadingColumn.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
            leadingColumn.topAnchor.constraint(equalTo: topAnchor),
            leadingColumn.bottomAnchor.constraint(equalTo: bottomAnchor),
            leadingWidth,
            textColumn.leadingAnchor.constraint(equalTo: leadingColumn.trailingAnchor, constant: Self.columnSpacing),
            textColumn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
            textColumn.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalInset),
            textColumn.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Self.verticalInset),

            icon.centerXAnchor.constraint(equalTo: leadingColumn.centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            leadingFirstLineCenter,
            spinner.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            number.leadingAnchor.constraint(equalTo: leadingColumn.leadingAnchor),
            number.trailingAnchor.constraint(equalTo: leadingColumn.trailingAnchor),
            number.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            chipHeight,
        ])
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        // Wrap at the title's real width so the second line matches measurement.
        let width = title.frame.width
        if width > 0, abs(title.preferredMaxLayoutWidth - width) > 0.5 {
            title.preferredMaxLayoutWidth = width
            needsLayout = true
        }
    }

    func configure(_ row: InspectorRepositoryRow, defaults: UserDefaults, open: @escaping () -> Void, implement: @escaping () -> Void) {
        confirmationTask?.cancel()
        confirmationTask = nil
        let font = InspectorNativeUI.font(defaults: defaults)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        leadingFirstLineCenter.constant = lineHeight / 2

        title.stringValue = row.title
        title.font = font
        title.handler = row.url.isEmpty ? nil : open
        title.toolTip = row.url.isEmpty ? nil : "Open on GitHub"
        title.setAccessibilityLabel(row.title)
        detail.stringValue = row.detail
        detail.isHidden = row.detail.isEmpty
        metadata.stringValue = row.metadata
        metadata.isHidden = row.metadata.isEmpty
        metadata.toolTip = [row.detail, row.metadata].filter { !$0.isEmpty }.joined(separator: " · ")
        detail.font = InspectorNativeUI.font(11, defaults: defaults)
        metadata.font = InspectorNativeUI.font(11, defaults: defaults)

        icon.image = NSImage(systemSymbolName: row.symbol, accessibilityDescription: row.symbol)
        icon.symbolConfiguration = .init(pointSize: min(16, font.pointSize + 1), weight: .medium)
        icon.contentTintColor = row.color
        icon.isHidden = row.issueNumber != nil || row.busy
        if row.busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

        number.isHidden = row.issueNumber == nil
        guard let issue = row.issueNumber else {
            leadingWidth.constant = 16
            return
        }
        let chipFont = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .semibold)
        number.font = chipFont
        number.title = "#\(issue)"
        // Reserve room for four digits so titles line up across the list.
        let textWidth = max(("#0000" as NSString).size(withAttributes: [.font: chipFont]).width,
                            ("#\(issue)" as NSString).size(withAttributes: [.font: chipFont]).width)
        leadingWidth.constant = ceil(textWidth + 12)
        chipHeight.constant = ceil(chipFont.ascender - chipFont.descender) + 4
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
}
