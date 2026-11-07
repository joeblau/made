import AppKit
import Observation

@MainActor
final class RunnersViewController: NSViewController, CockpitPanePresenting, CockpitPageToolbarProviding, NSSearchFieldDelegate,
                                   NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    let store: RunnersStore
    private let isLive: Bool
    private let defaults: UserDefaults
    private let observation = RRObservation()
    private let tabs = NSStackView()
    private lazy var tabStrip = CockpitTabStrip(stack: tabs)
    private let summary = RRUI.label("", size: 13, weight: .semibold)
    private let updated = RRUI.label("", size: 11, color: .secondaryLabelColor)
    private let error = RRUI.label("", size: 12, color: .systemOrange)
    private let search = NSSearchField(string: "")
    private let layoutPicker = NSSegmentedControl(labels: ["3D Fleet", "Compact", "Cards"], trackingMode: .selectOne, target: nil, action: nil)
    private let refresh = RRButton("Refresh", symbol: "arrow.clockwise", action: {})
    private let toolbar = NSStackView()
    private let filters = CockpitToolbarGroups()
    var pageToolbarView: NSView { loadViewIfNeeded(); return filters }
    private let toolbarSpacer = RRUI.spacer()
    private let body = NSView()
    private let collection = NSCollectionView()
    private let collectionScroll = NSScrollView()
    private let collectionLayout = NSCollectionViewFlowLayout()
    private lazy var fleet = RunnerFleetViewController()
    private var visibleRunners: [GitHubRunner] = []
    private var rowSignatures: [String] = []
    private var active = false
    private var refreshTask: Task<Void, Never>?
    private var footnoteTimer: Timer?
    private var previousScope: String?
    private var currentContent: NSView?
    private var layout: RunnerLayout
    private var zoomObservation: RRZoomObservation?

    init(store: RunnersStore, defaults: UserDefaults = .standard, isLive: Bool = true) {
        self.store = store
        self.defaults = defaults
        self.isLive = isLive
        layout = RunnerLayout(rawValue: defaults.string(forKey: "runners.layout") ?? "") ?? .fleet
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        refreshTask?.cancel()
        footnoteTimer?.invalidate()
    }

    override func loadView() {
        view = RRBackgroundView()
        tabs.orientation = .horizontal
        tabs.alignment = .centerY
        tabs.spacing = 6
        tabStrip.setAccessibilityIdentifier("runners.sources")
        search.placeholderString = "Filter runners"
        search.setAccessibilityLabel("Filter runners")
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        search.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        let preferredSearchWidth = search.widthAnchor.constraint(equalToConstant: 180)
        preferredSearchWidth.priority = .defaultHigh
        preferredSearchWidth.isActive = true
        layoutPicker.target = self
        layoutPicker.action = #selector(changeLayout)
        layoutPicker.selectedSegment = RunnerLayout.allCases.firstIndex(of: layout) ?? 0
        layoutPicker.setAccessibilityLabel("Runner layout")
        refresh.perform = { [weak self] in self?.refreshSelected() }
        filters.setAccessibilityIdentifier("runners.toolbar-controls")
        layoutPicker.segmentStyle = .capsule
        layoutPicker.controlSize = .small
        refresh.title = ""
        refresh.imagePosition = .imageOnly
        refresh.isBordered = false
        refresh.toolTip = "Refresh"
        refresh.setAccessibilityLabel("Refresh")
        filters.setGroups([[search], [layoutPicker], [refresh]])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 10
        toolbar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        for control in [summary, toolbarSpacer] { toolbar.addArrangedSubview(control) }
        let footer = RRUI.stack([updated], axis: .horizontal)
        footer.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 8, right: 12)
        let stack = RRUI.stack([tabStrip, toolbar, error, body, footer], spacing: 8)
        RRUI.fillWidth(stack)
        RRUI.pin(stack, to: view)
        collection.collectionViewLayout = collectionLayout
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.backgroundColors = [.clear]
        collection.register(RunnerCollectionItem.self, forItemWithIdentifier: RunnerCollectionItem.identifier)
        collectionLayout.minimumInteritemSpacing = 12
        collectionLayout.minimumLineSpacing = 12
        collectionLayout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        collectionScroll.documentView = collection
        collectionScroll.hasVerticalScroller = true
        collectionScroll.drawsBackground = false
        zoomObservation = RRZoomObservation { [weak self] in
            guard let self else { return }
            RRUI.zoomControls(in: self.view)
            RRUI.zoomControls(in: self.filters)
            self.tabStrip.needsLayout = true
            self.updateCollectionSize()
        }
        render()
    }

    override func viewWillAppear() { super.viewWillAppear(); updatePresentation(isActive: true, isSelected: true) }
    override func viewDidDisappear() { super.viewDidDisappear(); updatePresentation(isActive: false, isSelected: false) }
    override func viewDidLayout() {
        super.viewDidLayout()
        updateCollectionSize()
    }

    func updatePresentation(isActive: Bool, isSelected: Bool) {
        if isActive { _ = view }
        guard active != isActive else { return }
        active = isActive
        guard isViewLoaded else { return }
        if active {
            render()
            observation.start(tracking: { [weak self] in
                guard let self else { return }
                _ = self.store.scopes
                _ = self.store.selectedScopeID
                _ = self.store.snapshots
                _ = self.store.refreshing
                _ = self.store.presentations
                _ = self.store.searchText
            }, changed: { [weak self] in self?.render() })
            refreshSelected()
            footnoteTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.active else { return }
                    self.updateFootnote()
                }
            }
        } else {
            observation.stop()
            refreshTask?.cancel()
            refreshTask = nil
            footnoteTimer?.invalidate()
            footnoteTimer = nil
            if fleet.parent != nil { fleet.setPresentationActive(false) }
            for case let item as RunnerCollectionItem in collection.visibleItems() { item.stopHover() }
        }
    }

    private func render() {
        guard isViewLoaded else { return }
        renderTabs()
        let counts = store.snapshot.runners.reduce(into: [GitHubRunner.State: Int]()) { $0[$1.state, default: 0] += 1 }
        let runners = store.visibleRunners
        summary.stringValue = "\(runners.count) of \(store.snapshot.runners.count) runners · \(counts[.idle, default: 0]) idle · \(counts[.busy, default: 0]) busy · \(counts[.offline, default: 0]) offline"
        if search.stringValue != store.searchText { search.stringValue = store.searchText }
        refresh.isEnabled = isLive && !store.isRefreshing
        refresh.toolTip = store.isRefreshing ? "Refreshing…" : "Refresh"
        error.stringValue = store.snapshot.error.map { $0 + (store.snapshot.updatedAt == nil ? "" : " Showing the last successful refresh.") } ?? ""
        error.isHidden = error.stringValue.isEmpty
        updateFootnote()
        if previousScope != store.selectedScopeID {
            previousScope = store.selectedScopeID
            if active { refreshSelected() }
        }
        if store.selectedScope == nil {
            showState("Your Runner Fleet", message: "Add an enterprise, organization, or repository to see its self-hosted runners.", add: true)
        } else if store.snapshot.updatedAt == nil && store.isRefreshing {
            showState("Loading runners…", message: "Fetching runner status from GitHub.")
        } else if store.snapshot.runners.isEmpty {
            showState(store.snapshot.error == nil ? "No Runners" : "Runners Unavailable",
                      message: store.snapshot.error == nil ? "No self-hosted runners are registered for this source." : "Resolve the access or connection issue above, then refresh.")
        } else if runners.isEmpty {
            showState("No Matching Runners", message: "Try a different name, platform, status, or label.")
        } else if layout == .fleet {
            if fleet.parent == nil { addChild(fleet) }
            fleet.onEdit = { [weak self] in self?.edit($0) }
            fleet.configure(runners: runners, scopeName: store.selectedScope?.name ?? "",
                            name: store.displayName(for:), hardware: store.hardware(for:))
            show(fleet.view)
            fleet.setPresentationActive(active)
        } else {
            if fleet.parent != nil { fleet.setPresentationActive(false) }
            let oldIDs = visibleRunners.map(\.id)
            let signatures = runners.map { runner in
                "\(runner.id)|\(store.displayName(for: runner))|\(store.hardware(for: runner).rawValue)|\(runner.state.rawValue)|\(runner.labels.map(\.name).joined(separator: ","))|\(layout.rawValue)"
            }
            visibleRunners = runners
            show(collectionScroll)
            updateCollectionSize()
            if oldIDs != runners.map(\.id) {
                collection.reloadData()
            } else {
                let changes = signatures.indices.filter { !rowSignatures.indices.contains($0) || signatures[$0] != rowSignatures[$0] }
                collection.reloadItems(at: Set(changes.map { IndexPath(item: $0, section: 0) }))
            }
            rowSignatures = signatures
        }
    }

    private func renderTabs() {
        defer { tabStrip.needsLayout = true }
        RRUI.clear(tabs)
        for scope in store.scopes {
            let button = RRButton(scope.name, symbol: scope.kind.symbol) { [weak self] in
                self?.store.selectedScopeID = scope.id
                self?.store.searchText = ""
                self?.render()
            }
            button.setButtonType(.pushOnPushOff)
            button.state = scope.id == store.selectedScopeID ? .on : .off
            let menu = NSMenu()
            menu.autoenablesItems = false
            if let url = scope.settingsURL {
                menu.addItem(RRMenuItem("Open Runner Settings on GitHub", enabled: isLive) { [weak self] in
                    guard self?.isLive == true else { return }
                    NSWorkspace.shared.open(url)
                })
            }
            menu.addItem(RRMenuItem("Remove Tab", enabled: isLive) { [weak self] in self?.remove(scope) })
            button.menu = menu
            tabs.addArrangedSubview(button)
            if scope.id == store.selectedScopeID {
                let close = RRButton("", symbol: "xmark") { [weak self] in self?.remove(scope) }
                close.isEnabled = isLive
                close.setAccessibilityLabel("Remove \(scope.name) source")
                tabs.addArrangedSubview(close)
            }
        }
        let add = RRButton("Add Source", symbol: "plus") { [weak self] in self?.addSource() }
        add.isEnabled = isLive
        tabs.addArrangedSubview(add)
    }

    private func remove(_ scope: RunnerScope) {
        guard isLive else { return }
        store.remove(scope)
        render()
    }

    private func updateFootnote() {
        if let date = store.snapshot.updatedAt {
            updated.stringValue = "Updated \(Date().timeIntervalSince(date) < 60 ? "just now" : RelativeTime.string(from: date))" + (isLive ? " · Refreshes every 30s" : "")
        } else { updated.stringValue = "" }
    }

    private func show(_ content: NSView) {
        guard currentContent !== content else { return }
        currentContent?.removeFromSuperview()
        currentContent = content
        RRUI.pin(content, to: body)
    }

    private func showState(_ title: String, message: String, add: Bool = false) {
        if fleet.parent != nil { fleet.setPresentationActive(false) }
        let stack = RRUI.stack([RRUI.label(title, size: 21, weight: .semibold), RRUI.label(message, color: .secondaryLabelColor)], spacing: 14)
        stack.alignment = .centerX
        if add {
            let button = RRButton("Add Runner Source", symbol: "plus") { [weak self] in self?.addSource() }
            button.isEnabled = isLive
            stack.addArrangedSubview(button)
        }
        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
        ])
        show(container)
    }

    private func updateCollectionSize() {
        let available = max(240, collectionScroll.contentSize.width - 24)
        let columns = max(1, floor((available + 12) / (layout.minimumWidth * RRUI.zoom + 12)))
        let size = NSSize(width: floor((available - (columns - 1) * 12) / columns), height: (layout == .compact ? 88 : 226) * RRUI.zoom)
        if collectionLayout.itemSize != size { collectionLayout.itemSize = size; collectionLayout.invalidateLayout() }
    }

    private func refreshSelected() {
        guard isLive, !store.isRefreshing else { return }
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.store.refreshSelected()
            guard !Task.isCancelled else { return }
            self.render()
        }
    }

    func controlTextDidChange(_ obj: Notification) { store.searchText = search.stringValue; render() }
    @objc private func changeLayout() {
        guard RunnerLayout.allCases.indices.contains(layoutPicker.selectedSegment) else { return }
        layout = RunnerLayout.allCases[layoutPicker.selectedSegment]
        if isLive { defaults.set(layout.rawValue, forKey: "runners.layout") }
        render()
    }

    private func addSource() {
        guard isLive, let parent = view.window, parent.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Add Runner Source"
        alert.addButton(withTitle: "Add Source")
        alert.addButton(withTitle: "Cancel")
        let form = RunnerSourceForm()
        alert.accessoryView = form
        alert.buttons[0].isEnabled = false
        form.onValidityChanged = { [weak alert] valid in alert?.buttons.first?.isEnabled = valid }
        alert.beginSheetModal(for: parent) { [weak self] response in
            guard response == .alertFirstButtonReturn, let scope = form.scope else { return }
            self?.store.add(scope)
            self?.render()
        }
        alert.window.makeFirstResponder(form.name)
    }

    private func edit(_ runner: GitHubRunner) {
        guard isLive, let parent = view.window, parent.attachedSheet == nil, let scope = store.selectedScope else { return }
        let alert = NSAlert()
        alert.messageText = "Edit Device"
        alert.informativeText = runner.name
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let form = RunnerPresentationForm(runner: runner, presentation: store.presentation(for: runner))
        alert.accessoryView = form
        alert.beginSheetModal(for: parent) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.store.savePresentation(form.presentation, runner: runner, scope: scope)
            self?.render()
        }
        alert.window.makeFirstResponder(form.name)
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { visibleRunners.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: RunnerCollectionItem.identifier, for: indexPath)
        guard let card = item as? RunnerCollectionItem, visibleRunners.indices.contains(indexPath.item) else { return item }
        let runner = visibleRunners[indexPath.item]
        card.configure(runner: runner, name: store.displayName(for: runner), hardware: store.hardware(for: runner), compact: layout == .compact, canEdit: isLive) { [weak self] in self?.edit(runner) }
        return card
    }
}

private enum RunnerLayout: String, CaseIterable {
    case fleet, compact, cards
    var minimumWidth: CGFloat { self == .compact ? 236 : 240 }
}

@MainActor
private final class RunnerCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("runner.card")
    private var hoverTask: Task<Void, Never>?
    private var popover: NSPopover?

    override func loadView() { view = RunnerCardSurface() }
    override func prepareForReuse() { super.prepareForReuse(); stopHover() }
    func stopHover() { hoverTask?.cancel(); hoverTask = nil; popover?.close(); popover = nil }

    func configure(runner: GitHubRunner, name: String, hardware: RunnerHardware, compact: Bool, canEdit: Bool, edit: @escaping () -> Void) {
        stopHover()
        let surface = view as! RunnerCardSurface
        for child in surface.subviews { child.removeFromSuperview() }
        let image = runnerImage(hardware, size: compact ? 44 : 58)
        let heading = RRUI.label(name, size: compact ? 13 : 15, weight: .semibold)
        heading.maximumNumberOfLines = 1
        heading.lineBreakMode = .byTruncatingMiddle
        heading.toolTip = name
        let status = RRUI.label("● \(runner.state.rawValue)", size: 11, weight: .medium, color: runner.state.fleetColor)
        let editButton = RRButton("", symbol: "pencil") { [weak self] in self?.stopHover(); edit() }
        editButton.isEnabled = canEdit
        editButton.setAccessibilityLabel("Edit \(name)")
        editButton.toolTip = "Edit Device…"
        // A fixed round button pinned to the card's trailing edge, not floating
        // after the status text at whatever width the name happens to be.
        editButton.borderShape = .circle
        editButton.controlSize = .small
        editButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            editButton.widthAnchor.constraint(equalToConstant: 26),
            editButton.heightAnchor.constraint(equalToConstant: 26),
        ])
        editButton.setContentHuggingPriority(.required, for: .horizontal)
        let stack: NSStackView
        if compact {
            image.alphaValue = runner.state == .offline ? 0.6 : 1
            let text = RRUI.stack([heading, status], spacing: 6)
            text.setContentHuggingPriority(.init(1), for: .horizontal)
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            stack = RRUI.stack([image, text, editButton], axis: .horizontal, spacing: 12)
            stack.distribution = .fill
        } else {
            let footer = RRUI.stack([RRUI.label(name == runner.name ? "" : runner.name, size: 11, color: .secondaryLabelColor), RRUI.spacer(), editButton], axis: .horizontal)
            footer.distribution = .fill
            let labels = RRUI.label(runner.labels.map(\.name).joined(separator: " · "), size: 11, color: .secondaryLabelColor)
            labels.maximumNumberOfLines = 2
            labels.toolTip = runner.labels.map(\.name).joined(separator: ", ")
            stack = RRUI.stack([
                RRUI.stack([image, RRUI.spacer(), status], axis: .horizontal), heading,
                RRUI.label(hardware.title, size: 12, color: .secondaryLabelColor),
                RRUI.label([runner.platform, runner.architecture].compactMap { $0 }.joined(separator: " · "), size: 11, color: .secondaryLabelColor),
                labels, footer,
            ], spacing: 8)
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        RRUI.pin(stack, to: surface, inset: 12)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(RRMenuItem("Edit Device…", enabled: canEdit) { [weak self] in self?.stopHover(); edit() })
        surface.menu = menu
        surface.onDoubleClick = edit
        surface.setAccessibilityRole(.button)
        surface.setAccessibilityLabel("\(name), \(hardware.title), \(runner.state.rawValue)")
        surface.onHover = { [weak self, weak surface, weak editButton] inside, point in
            guard let self else { return }
            self.stopHover()
            guard compact, inside, let surface,
                  !(editButton.map { $0.bounds.contains($0.convert(point, from: surface)) } ?? false) else { return }
            self.hoverTask = Task { @MainActor [weak self, weak surface] in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, let self, let surface, surface.window != nil else { return }
                let popover = NSPopover()
                popover.behavior = .transient
                popover.contentViewController = RunnerDetailsViewController(runner: runner, name: name, hardware: hardware)
                self.popover = popover
                popover.show(relativeTo: surface.bounds, of: surface, preferredEdge: .maxY)
            }
        }
    }
}

@MainActor
final class RunnerDetailsViewController: NSViewController {
    private let runner: GitHubRunner
    private let name: String
    private let hardware: RunnerHardware
    init(runner: GitHubRunner, name: String, hardware: RunnerHardware) {
        self.runner = runner; self.name = name; self.hardware = hardware
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        let stack = RRUI.stack([
            RRUI.stack([runnerImage(hardware, size: 52), RRUI.stack([
                RRUI.label(name, size: 15, weight: .semibold),
                RRUI.label("● \(runner.state.rawValue)", size: 12, color: runner.state.fleetColor),
            ])], axis: .horizontal),
            RRUI.label("Hardware: \(hardware.title)", size: 12),
            RRUI.label("Platform: \([runner.platform, runner.architecture].compactMap { $0 }.joined(separator: " · "))", size: 12),
        ], spacing: 12)
        if name != runner.name { stack.addArrangedSubview(RRUI.label("Runner: \(runner.name)", size: 12)) }
        if !runner.labels.isEmpty {
            let labels = RRUI.label("Labels: \(runner.labels.map(\.name).joined(separator: ", "))", size: 11)
            labels.isSelectable = true
            stack.addArrangedSubview(labels)
        }
        let detailHeight = min(480, 190 + CGFloat(runner.labels.map(\.name).joined(separator: ", ").count / 40 + 1) * 16)
        preferredContentSize = NSSize(width: 340 * RRUI.zoom, height: detailHeight * RRUI.zoom)
        view = RRBackgroundView(frame: NSRect(origin: .zero, size: preferredContentSize))
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let document = RRDocumentView()
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        RRUI.pin(stack, to: document, inset: 16)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        RRUI.pin(scroll, to: view)
    }
}

@MainActor
private func runnerImage(_ hardware: RunnerHardware, size: CGFloat) -> NSImageView {
    let view = NSImageView()
    view.image = hardware.assetName.flatMap { NSImage(named: $0) } ?? NSImage(systemSymbolName: hardware.symbol, accessibilityDescription: hardware.title)
    view.imageScaling = .scaleProportionallyUpOrDown
    view.contentTintColor = .labelColor
    view.widthAnchor.constraint(equalToConstant: size).isActive = true
    view.heightAnchor.constraint(equalToConstant: size).isActive = true
    view.setAccessibilityLabel(hardware.title)
    return view
}

@MainActor
private final class RunnerCardSurface: NSView {
    var onHover: (Bool, NSPoint) -> Void = { _, _ in }
    var onDoubleClick: () -> Void = {}
    private var tracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateBackground(false) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        updateBackground(false)
    }
    override func mouseEntered(with event: NSEvent) { updateBackground(true); onHover(true, convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { onHover(true, convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { updateBackground(false); onHover(false, .zero) }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { onDoubleClick() } else { super.mouseDown(with: event) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { onDoubleClick() } else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { onDoubleClick(); return true }
    private func updateBackground(_ hovered: Bool) { layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(hovered ? 0.12 : 0.07).cgColor }
}

@MainActor
private final class RunnerSourceForm: NSView, NSTextFieldDelegate {
    let name = NSTextField(string: "")
    private let kind = NSPopUpButton()
    private let help = RRUI.label("", size: 11, color: .secondaryLabelColor)
    var onValidityChanged: (Bool) -> Void = { _ in }
    var scope: RunnerScope? { RunnerScope.parse(name.stringValue, kind: RunnerScope.Kind.allCases[kind.indexOfSelectedItem]) }
    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 420 * RRUI.zoom, height: 160 * RRUI.zoom))
        kind.addItems(withTitles: RunnerScope.Kind.allCases.map(\.title))
        kind.target = self
        kind.action = #selector(update)
        kind.setAccessibilityLabel("Runner source type")
        name.delegate = self
        name.setAccessibilityLabel("Source name")
        let stack = RRUI.stack([kind, RRUI.label("Source name", weight: .medium), name, help], spacing: 10)
        RRUI.fillWidth(stack)
        RRUI.pin(stack, to: self)
        RRUI.zoomControls(in: self)
        update()
    }
    required init?(coder: NSCoder) { nil }
    func controlTextDidChange(_ obj: Notification) { update() }
    @objc private func update() {
        let selected = RunnerScope.Kind.allCases[kind.indexOfSelectedItem]
        name.placeholderString = selected.inputPlaceholder
        help.stringValue = selected == .enterprise
            ? "Uses your GitHub CLI account. Enterprise runners need the manage_runners:enterprise token scope."
            : "Uses your GitHub CLI account. You need access to view this source's self-hosted runners."
        onValidityChanged(scope != nil)
    }
}

@MainActor
private final class RunnerPresentationForm: NSView {
    let name = NSTextField(string: "")
    private let hardware = NSPopUpButton()
    var presentation: RunnerPresentation {
        RunnerPresentation(name: name.stringValue, hardware: hardware.indexOfSelectedItem == 0 ? nil : RunnerHardware.allCases[hardware.indexOfSelectedItem - 1])
    }
    init(runner: GitHubRunner, presentation: RunnerPresentation) {
        super.init(frame: NSRect(x: 0, y: 0, width: 420 * RRUI.zoom, height: 210 * RRUI.zoom))
        name.stringValue = presentation.name
        name.placeholderString = runner.name
        name.setAccessibilityLabel("Display name")
        hardware.addItem(withTitle: "Automatic (\(RunnerHardware.inferred(for: runner).title))")
        hardware.addItems(withTitles: RunnerHardware.allCases.map(\.title))
        hardware.selectItem(at: presentation.hardware.flatMap { RunnerHardware.allCases.firstIndex(of: $0).map { $0 + 1 } } ?? 0)
        hardware.setAccessibilityLabel("Hardware")
        let reset = RRButton("Reset to Defaults") { [weak name, weak hardware] in name?.stringValue = ""; hardware?.selectItem(at: 0) }
        let stack = RRUI.stack([
            RRUI.label("Display name", weight: .medium), name,
            RRUI.label("Hardware", weight: .medium), hardware,
            RRUI.label("Device names and images are saved in Cockpit. Runner labels come from GitHub.", size: 11, color: .secondaryLabelColor), reset,
        ], spacing: 8)
        RRUI.fillWidth(stack)
        RRUI.pin(stack, to: self)
        RRUI.zoomControls(in: self)
    }
    required init?(coder: NSCoder) { nil }
}
