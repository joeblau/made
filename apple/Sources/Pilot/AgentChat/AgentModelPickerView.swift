import AppKit

/// Everything the model picker popover shows, as plain values. The pane
/// adapts session, catalog and favorites data into this; the view never
/// touches a session.
struct AgentModelPickerState: Equatable {
    struct Tab: Equatable {
        enum Kind: Equatable { case favorites, agent(ChatAgent) }
        var kind: Kind
        var title: String
    }

    struct Row: Equatable {
        var agent: ChatAgent
        var modelID: String
        var name: String
        var detail: String?
        var group: String?
        var isCurrent: Bool
        var isFavorite: Bool
        /// "Start <Provider> to see its models": no keycap or favorite toggle.
        var isPlaceholder: Bool
    }

    struct Choice: Equatable {
        var id: String
        var name: String
        var detail: String?
        var isCurrent: Bool
        var isUnrestricted: Bool
    }

    var tabs: [Tab]
    var selectedTab: Tab.Kind
    /// Rows for `selectedTab`, unfiltered; the view filters by its own search text.
    var rows: [Row]
    /// Short model name shown right of "Reasoning"; nil hides the column.
    var reasoningTitle: String?
    /// Empty hides the column.
    var reasoning: [Choice]
    /// nil hides Standard | Fast.
    var fast: Bool?
    /// nil hides the mode button.
    var modeName: String?
    var modeChoices: [Choice]
    var modeIsUnrestricted: Bool
    /// false: rows, reasoning and footer are disabled; tabs stay browsable.
    var isEditable: Bool
}

enum AgentModelPickerAction: Equatable {
    case selectTab(AgentModelPickerState.Tab.Kind)
    case selectModel(agent: ChatAgent, modelID: String)
    case toggleFavorite(agent: ChatAgent, modelID: String)
    case selectReasoning(String)
    case setFast(Bool)
    case selectMode(String)
    case dismiss
}

/// Layout of the popover in points at 1× UI zoom, measured from the reference.
struct AgentModelPickerMetrics {
    var scale: CGFloat
    var width: CGFloat { 552 * scale }
    var rail: CGFloat { 46 * scale }
    var reasoning: CGFloat { 192 * scale }
    var header: CGFloat { 46 * scale }
    var body: CGFloat { 304 * scale }
    var footer: CGFloat { 46 * scale }
    var row: CGFloat { 34 * scale }
    var groupHeader: CGFloat { 26 * scale }
    var inset: CGFloat { 12 * scale }
    var listTop: CGFloat { 10 * scale }
    static let collapsedRowCount = 4
    static let shortcutCount = 4

    func height(footer visible: Bool) -> CGFloat { header + body + (visible ? footer : 0) }
}

/// The popover content: provider rail, searchable model list, reasoning
/// column and a speed/permission footer (see docs/agent-chat.md).
@MainActor
final class AgentModelPickerViewController: NSViewController, NSSearchFieldDelegate {
    enum ListEntry: Equatable {
        case group(String)
        case row(Int)
    }

    private(set) var state: AgentModelPickerState
    private let onAction: (AgentModelPickerAction) -> Void
    let searchField = NSSearchField()

    private(set) var railButtons: [AgentModelPickerRailButton] = []
    private(set) var rowViews: [AgentModelPickerRowView] = []
    private(set) var reasoningButtons: [AgentModelPickerChoiceButton] = []
    private(set) var groupLabels: [NSTextField] = []
    let showMoreButton = AgentChatClosureButton.link("Show more", size: 15, color: .textMuted)
    let emptyLabel = AgentChatText.makeLabel()
    let reasoningLabel = AgentChatText.makeLabel()
    let reasoningTitleLabel = AgentChatText.makeLabel()
    let fastToggle = AgentModelPickerFastToggle()
    let modeButton = AgentModelPickerModeButton()

    /// The rows the list shows, after search and Show more.
    private(set) var visibleRows: [AgentModelPickerState.Row] = []
    private(set) var entries: [ListEntry] = []
    private(set) var highlightedIndex: Int?
    private(set) var isExpanded = false
    private var hoveredIndex: Int?

    private let listScroll = NSScrollView()
    private let listDocument = AgentModelPickerFlippedView()
    private let reasoningScroll = NSScrollView()
    private let reasoningDocument = AgentModelPickerFlippedView()
    private var root: AgentModelPickerRootView { view as! AgentModelPickerRootView }

    init(state: AgentModelPickerState, onAction: @escaping (AgentModelPickerAction) -> Void) {
        self.state = state
        self.onAction = onAction
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    var metrics: AgentModelPickerMetrics { AgentModelPickerMetrics(scale: CGFloat(CockpitUIZoomController.shared.factor)) }
    var query: String { searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isReasoningVisible: Bool { state.reasoningTitle != nil && !state.reasoning.isEmpty }
    var isFooterVisible: Bool { state.fast != nil || state.modeName != nil }
    var keycapCount: Int { rowViews.filter { !$0.keycap.isHidden }.count }

    override func loadView() {
        let root = AgentModelPickerRootView()
        root.controller = self
        root.setAccessibilityIdentifier("agent-model-picker")
        root.setAccessibilityLabel("Model picker")
        view = root
        configureSearchField()
        for scroll in [listScroll, reasoningScroll] {
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            scroll.horizontalScrollElasticity = .none
        }
        listScroll.documentView = listDocument
        reasoningScroll.documentView = reasoningDocument
        listScroll.setAccessibilityIdentifier("agent-model-picker.models")
        reasoningScroll.setAccessibilityIdentifier("agent-model-picker.reasoning-list")
        showMoreButton.onPress = { [weak self] in self?.expand() }
        showMoreButton.setAccessibilityIdentifier("agent-model-picker.show-more")
        reasoningLabel.setAccessibilityIdentifier("agent-model-picker.reasoning-title")
        fastToggle.onChange = { [weak self] value in self?.perform(.setFast(value), editing: true) }
        modeButton.onPress = { [weak self] in self?.showModeMenu() }
        for subview in [searchField, listScroll, reasoningLabel, reasoningTitleLabel, reasoningScroll, fastToggle, modeButton] as [NSView] {
            root.addSubview(subview)
        }
        listDocument.addSubview(showMoreButton)
        listDocument.addSubview(emptyLabel)
        NotificationCenter.default.addObserver(self, selector: #selector(zoomChanged), name: .cockpitUIZoomDidChange, object: nil)
        render(rowsChanged: true)
        view.frame = NSRect(origin: .zero, size: preferredContentSize)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
    }

    /// Applies new values. Search text always survives; highlight, scroll
    /// position and Show more survive while the row identities are unchanged.
    func update(_ state: AgentModelPickerState) {
        guard state != self.state else { return }
        let identities = { (rows: [AgentModelPickerState.Row]) in rows.map { "\($0.agent.rawValue)\u{1F}\($0.modelID)" } }
        let rowsChanged = identities(state.rows) != identities(self.state.rows) || state.selectedTab != self.state.selectedTab
        let tabsChanged = state.tabs != self.state.tabs
        self.state = state
        guard isViewLoaded else { return }
        if tabsChanged { railButtons.forEach { $0.removeFromSuperview() }; railButtons = [] }
        render(rowsChanged: rowsChanged)
    }

    // MARK: - Filtering

    /// Case- and diacritic-insensitive match on name and id.
    nonisolated static func filter(_ rows: [AgentModelPickerState.Row], query: String) -> [AgentModelPickerState.Row] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return rows }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return rows.filter { !$0.isPlaceholder && ($0.name.range(of: needle, options: options) != nil
            || $0.modelID.range(of: needle, options: options) != nil) }
    }

    // MARK: - Rendering

    private func render(rowsChanged: Bool) {
        let scrollOrigin = listScroll.contentView.bounds.origin
        if rowsChanged {
            highlightedIndex = nil
            hoveredIndex = nil
            isExpanded = false
        }
        renderRail()
        renderList()
        renderReasoning()
        renderFooter()
        preferredContentSize = NSSize(width: metrics.width, height: metrics.height(footer: isFooterVisible))
        view.needsLayout = true
        view.needsDisplay = true
        layoutContent()
        listScroll.contentView.scroll(to: rowsChanged ? .zero : scrollOrigin)
        listScroll.reflectScrolledClipView(listScroll.contentView)
        updateKeyViewLoop()
    }

    private func configureSearchField() {
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.cell?.isScrollable = true
        searchField.setAccessibilityLabel("Search models")
        searchField.setAccessibilityIdentifier("agent-model-picker.search")
        styleSearchField()
    }

    private func styleSearchField() {
        let font = AgentChatText.font(15)
        searchField.font = font
        searchField.textColor = AgentChatPalette.color(.textPrimary)
        searchField.placeholderAttributedString = NSAttributedString(string: "Search models…", attributes: [
            .font: font, .foregroundColor: AgentChatPalette.color(.textMuted),
        ])
        if let cell = searchField.cell as? NSSearchFieldCell, let button = cell.searchButtonCell {
            button.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14 * metrics.scale, weight: .regular))
        }
    }

    private func renderRail() {
        if railButtons.isEmpty {
            railButtons = state.tabs.map { tab in
                let button = AgentModelPickerRailButton(tab: tab)
                button.onPress = { [weak self] in self?.selectTab(tab.kind) }
                view.addSubview(button)
                return button
            }
        }
        for button in railButtons { button.configure(selected: button.kind == state.selectedTab, scale: metrics.scale) }
    }

    private func renderList() {
        let filtered = Self.filter(state.rows, query: query)
        let collapsible = query.isEmpty && !isExpanded && filtered.count > AgentModelPickerMetrics.collapsedRowCount
        visibleRows = collapsible ? Array(filtered.prefix(AgentModelPickerMetrics.collapsedRowCount)) : filtered
        entries = []
        var lastGroup: String?
        for (index, row) in visibleRows.enumerated() {
            if let group = row.group, group != lastGroup { entries.append(.group(group)) }
            lastGroup = row.group
            entries.append(.row(index))
        }
        rowViews.forEach { $0.removeFromSuperview() }
        groupLabels.forEach { $0.removeFromSuperview() }
        var shortcut = 0
        rowViews = visibleRows.enumerated().map { index, row in
            var number: Int?
            if !row.isPlaceholder, shortcut < AgentModelPickerMetrics.shortcutCount {
                shortcut += 1
                number = shortcut
            }
            let view = AgentModelPickerRowView(row: row, shortcut: number, enabled: state.isEditable, scale: metrics.scale)
            view.callbacks = .init(
                select: { [weak self] in self?.select(rowAt: index) },
                toggleFavorite: { [weak self] in self?.onAction(.toggleFavorite(agent: row.agent, modelID: row.modelID)) },
                hover: { [weak self] inside in self?.hover(index, inside: inside) }
            )
            listDocument.addSubview(view)
            return view
        }
        groupLabels = entries.compactMap { entry in
            guard case .group(let title) = entry else { return nil }
            let label = AgentChatText.makeLabel()
            AgentChatText.apply(label, text: title, font: AgentChatText.font(11, .semibold), color: .textMuted)
            label.setAccessibilityRole(.staticText)
            listDocument.addSubview(label)
            return label
        }
        if let highlightedIndex, highlightedIndex >= visibleRows.count { self.highlightedIndex = nil }
        applyHighlight()
        showMoreButton.isHidden = !collapsible
        showMoreButton.setLinkStyle("Show more", size: 15, color: .textMuted)
        showMoreButton.attributedTitle = NSAttributedString(string: "Show more", attributes: [
            .font: AgentChatText.font(15), .foregroundColor: AgentChatPalette.color(.textMuted),
        ])
        let emptyText = !query.isEmpty ? "No models match “\(query)”"
            : state.selectedTab == .favorites ? "Star a model to keep it here" : "No models"
        AgentChatText.apply(emptyLabel, text: emptyText, font: AgentChatText.font(13), color: .textMuted)
        emptyLabel.isHidden = !visibleRows.isEmpty
    }

    private func renderReasoning() {
        reasoningButtons.forEach { $0.removeFromSuperview() }
        let visible = isReasoningVisible
        for label in [reasoningLabel, reasoningTitleLabel] { label.isHidden = !visible }
        reasoningScroll.isHidden = !visible
        AgentChatText.apply(reasoningLabel, text: "Reasoning", font: AgentChatText.font(15), color: .textMuted)
        AgentChatText.apply(reasoningTitleLabel, text: state.reasoningTitle ?? "", font: AgentChatText.font(13), color: .textMuted)
        reasoningTitleLabel.alignment = .right
        guard visible else { reasoningButtons = []; return }
        reasoningButtons = state.reasoning.enumerated().map { index, choice in
            let button = AgentModelPickerChoiceButton(choice: choice, enabled: state.isEditable, scale: metrics.scale)
            button.onPress = { [weak self] in self?.perform(.selectReasoning(choice.id), editing: true) }
            button.onArrow = { [weak self] step in self?.focusReasoning(index + step) }
            reasoningDocument.addSubview(button)
            return button
        }
    }

    private func renderFooter() {
        fastToggle.isHidden = state.fast == nil
        fastToggle.configure(fast: state.fast ?? false, enabled: state.isEditable, scale: metrics.scale)
        modeButton.isHidden = state.modeName == nil
        modeButton.scale = metrics.scale
        modeButton.modeName = state.modeName ?? ""
        modeButton.isUnrestricted = state.modeIsUnrestricted
        modeButton.isEnabled = state.isEditable && !state.modeChoices.isEmpty
        modeButton.toolTip = state.modeChoices.first { $0.isCurrent }?.detail
        root.showsFooter = isFooterVisible
        root.showsReasoning = isReasoningVisible
    }

    // MARK: - Layout

    func layoutContent() {
        guard isViewLoaded else { return }
        let m = metrics
        let bounds = view.bounds
        let footerTop = isFooterVisible ? bounds.height - m.footer : bounds.height
        let middleMaxX = isReasoningVisible ? bounds.width - m.reasoning : bounds.width
        root.metrics = m
        // Rail: ★ above a hairline, then one tab per provider.
        let tab = 36 * m.scale
        for (index, button) in railButtons.enumerated() {
            let center = index == 0 ? 26 * m.scale : 71 * m.scale + CGFloat(index - 1) * 40 * m.scale
            button.frame = NSRect(x: 0, y: center - tab / 2, width: m.rail, height: tab)
        }
        // Middle column: search, hairline, rows.
        let searchHeight = ceil(searchField.intrinsicContentSize.height)
        searchField.frame = NSRect(x: m.rail + m.inset - 4 * m.scale, y: (m.header - searchHeight) / 2,
                                   width: middleMaxX - m.rail - m.inset * 2 + 4 * m.scale, height: searchHeight)
        listScroll.frame = NSRect(x: m.rail, y: m.header, width: middleMaxX - m.rail, height: max(0, footerTop - m.header))
        layoutList(width: middleMaxX - m.rail)
        // Reasoning column.
        let columnX = bounds.width - m.reasoning
        let labelHeight = AgentModelPickerDrawing.fit(reasoningLabel).height
        reasoningLabel.frame = NSRect(x: columnX + 13 * m.scale, y: (m.header - labelHeight) / 2,
                                      width: AgentModelPickerDrawing.fit(reasoningLabel).width, height: labelHeight)
        let titleHeight = AgentModelPickerDrawing.fit(reasoningTitleLabel).height
        let titleX = reasoningLabel.frame.maxX + 8 * m.scale
        reasoningTitleLabel.frame = NSRect(x: titleX, y: (m.header - titleHeight) / 2,
                                           width: max(0, bounds.width - 11 * m.scale - titleX), height: titleHeight)
        reasoningScroll.frame = NSRect(x: columnX, y: m.header, width: m.reasoning, height: max(0, footerTop - m.header))
        var y = m.listTop
        for button in reasoningButtons {
            button.frame = NSRect(x: 8 * m.scale, y: y, width: m.reasoning - 16 * m.scale, height: m.row)
            y += m.row
        }
        reasoningDocument.frame = NSRect(x: 0, y: 0, width: m.reasoning, height: max(y + m.listTop, reasoningScroll.contentSize.height))
        // Footer.
        let fastSize = fastToggle.preferredSize
        fastToggle.frame = NSRect(x: 14 * m.scale, y: footerTop + (m.footer - fastSize.height) / 2,
                                  width: fastSize.width, height: fastSize.height)
        let modeSize = modeButton.preferredSize
        modeButton.frame = NSRect(x: bounds.width - 16 * m.scale - modeSize.width, y: footerTop + (m.footer - modeSize.height) / 2,
                                  width: modeSize.width, height: modeSize.height)
    }

    private func layoutList(width: CGFloat) {
        let m = metrics
        let rowWidth = width - m.inset * 2
        var y = m.listTop
        var groupIndex = 0
        for entry in entries {
            switch entry {
            case .group:
                let label = groupLabels[groupIndex]
                groupIndex += 1
                let height = AgentModelPickerDrawing.fit(label).height
                label.frame = NSRect(x: m.inset + 8 * m.scale, y: y + m.groupHeader - height - 4 * m.scale,
                                     width: rowWidth - 16 * m.scale, height: height)
                y += m.groupHeader
            case .row(let index):
                rowViews[index].frame = NSRect(x: m.inset, y: y, width: rowWidth, height: m.row)
                rowViews[index].needsLayout = true
                y += m.row
            }
        }
        if !showMoreButton.isHidden {
            let size = showMoreButton.cellSize
            showMoreButton.frame = NSRect(x: m.inset + 6 * m.scale, y: y + (m.row - size.height) / 2, width: size.width, height: size.height)
            y += m.row
        }
        if !emptyLabel.isHidden {
            let height = AgentModelPickerDrawing.fit(emptyLabel).height
            emptyLabel.frame = NSRect(x: m.inset + 8 * m.scale, y: y + (m.row - height) / 2, width: rowWidth - 16 * m.scale, height: height)
            y += m.row
        }
        listDocument.frame = NSRect(x: 0, y: 0, width: width, height: max(y + m.listTop, listScroll.contentSize.height))
    }

    // MARK: - Interaction

    private func perform(_ action: AgentModelPickerAction, editing: Bool) {
        guard !editing || state.isEditable else { return }
        onAction(action)
    }

    func select(rowAt index: Int) {
        guard visibleRows.indices.contains(index), state.isEditable else { return }
        let row = visibleRows[index]
        onAction(.selectModel(agent: row.agent, modelID: row.modelID))
    }

    /// ⌘1–⌘4: the Nth non-placeholder visible row.
    func selectShortcut(_ number: Int) -> Bool {
        guard let index = rowViews.firstIndex(where: { $0.keycap.text == "⌘\(number)" && !$0.keycap.isHidden }) else { return false }
        select(rowAt: index)
        return true
    }

    func expand() {
        guard !isExpanded else { return }
        isExpanded = true
        render(rowsChanged: false)
    }

    func moveHighlight(by step: Int) {
        guard !visibleRows.isEmpty else { return }
        let next: Int
        if let highlightedIndex {
            next = min(max(highlightedIndex + step, 0), visibleRows.count - 1)
        } else {
            next = step > 0 ? 0 : visibleRows.count - 1
        }
        highlightedIndex = next
        applyHighlight()
        if rowViews.indices.contains(next) { listDocument.scrollToVisible(rowViews[next].frame) }
    }

    /// Return: the highlighted row, else the first visible one.
    func activateHighlight() {
        guard !visibleRows.isEmpty else { return }
        select(rowAt: highlightedIndex ?? 0)
    }

    private func hover(_ index: Int, inside: Bool) {
        hoveredIndex = inside ? index : (hoveredIndex == index ? nil : hoveredIndex)
        if inside { highlightedIndex = index }
        applyHighlight()
    }

    private func applyHighlight() {
        for (index, view) in rowViews.enumerated() { view.setHighlighted(index == highlightedIndex) }
    }

    private func focusReasoning(_ index: Int) {
        guard reasoningButtons.indices.contains(index) else { return }
        view.window?.makeFirstResponder(reasoningButtons[index])
    }

    func dismiss() { onAction(.dismiss) }

    /// A clicked tab hands focus back to search so typing keeps filtering;
    /// a tab reached with the keyboard keeps focus for further navigation.
    private func selectTab(_ kind: AgentModelPickerState.Tab.Kind) {
        onAction(.selectTab(kind))
        if NSApp.currentEvent?.type != .keyDown { view.window?.makeFirstResponder(searchField) }
    }

    func modeMenu() -> NSMenu {
        let menu = NSMenu(title: "Permission mode")
        for choice in state.modeChoices {
            let item = NSMenuItem(title: choice.name, action: #selector(modeItemChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.id
            item.state = choice.isCurrent ? .on : .off
            item.toolTip = choice.detail
            item.image = NSImage(systemSymbolName: choice.isUnrestricted ? "shield.slash" : "checkmark.shield",
                                 accessibilityDescription: choice.isUnrestricted ? "Unrestricted" : nil)
            item.isEnabled = state.isEditable
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        return menu
    }

    private func showModeMenu() {
        guard state.isEditable, !state.modeChoices.isEmpty else { return }
        let menu = modeMenu()
        let current = menu.items.first { $0.state == .on }
        menu.popUp(positioning: current, at: NSPoint(x: 0, y: modeButton.bounds.height), in: modeButton)
    }

    @objc func modeItemChosen(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        perform(.selectMode(id), editing: true)
    }

    @objc private func zoomChanged() {
        guard isViewLoaded else { return }
        styleSearchField()
        railButtons.forEach { $0.removeFromSuperview() }
        railButtons = []
        render(rowsChanged: false)
    }

    // MARK: - Keyboard

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveHighlight(by: 1)
        case #selector(NSResponder.moveUp(_:)): moveHighlight(by: -1)
        case #selector(NSResponder.insertNewline(_:)): activateHighlight()
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        case #selector(NSResponder.insertTab(_:)): view.window?.makeFirstResponder(searchField.nextValidKeyView)
        case #selector(NSResponder.insertBacktab(_:)): view.window?.makeFirstResponder(searchField.previousValidKeyView)
        default: return false
        }
        return true
    }

    func controlTextDidChange(_ notification: Notification) {
        isExpanded = false
        render(rowsChanged: false)
        highlightedIndex = query.isEmpty || visibleRows.isEmpty ? nil : 0
        applyHighlight()
        listScroll.contentView.scroll(to: .zero)
    }

    /// Search → reasoning levels → footer → rail → search.
    private func updateKeyViewLoop() {
        var chain: [NSView] = [searchField]
        chain += reasoningButtons.prefix(1).map { $0 as NSView }
        if !fastToggle.isHidden { chain.append(fastToggle.isFastOn ? fastToggle.fast : fastToggle.standard) }
        if !modeButton.isHidden { chain.append(modeButton) }
        chain += railButtons
        for (index, view) in chain.enumerated() { view.nextKeyView = chain[(index + 1) % chain.count] }
        for (index, button) in reasoningButtons.enumerated() where index > 0 {
            button.nextKeyView = reasoningButtons.first?.nextKeyView
        }
    }

    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, let characters = event.charactersIgnoringModifiers,
              let number = Int(characters), (1...AgentModelPickerMetrics.shortcutCount).contains(number) else { return false }
        return selectShortcut(number)
    }
}

extension AgentModelPickerFastToggle {
    var isFastOn: Bool { fast.isOn }
}

/// Draws the surface and hairlines; routes ⌘1–⌘4 and Esc.
@MainActor
final class AgentModelPickerRootView: NSView {
    weak var controller: AgentModelPickerViewController?
    var metrics = AgentModelPickerMetrics(scale: 1) { didSet { needsDisplay = true } }
    var showsFooter = true { didSet { needsDisplay = true } }
    var showsReasoning = true { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        controller?.layoutContent()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if controller?.handleKeyEquivalent(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { controller?.dismiss(); return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) { controller?.dismiss() }

    override func draw(_ dirtyRect: NSRect) {
        AgentChatPalette.color(.pickerSurface).setFill()
        bounds.fill()
        let m = metrics
        let footerTop = showsFooter ? bounds.height - m.footer : bounds.height
        let hairline = AgentChatPalette.color(.pickerHairline)
        hairline.setFill()
        let line: CGFloat = 1
        // Column dividers.
        NSRect(x: m.rail - line, y: 0, width: line, height: footerTop).fill()
        let middleMaxX = showsReasoning ? bounds.width - m.reasoning : bounds.width
        if showsReasoning { NSRect(x: middleMaxX, y: 0, width: line, height: footerTop).fill() }
        if showsFooter { NSRect(x: 0, y: footerTop, width: bounds.width, height: line).fill() }
        // Under the search field, the reasoning header and the ★ tab.
        NSRect(x: m.rail + m.inset, y: m.header - line, width: middleMaxX - m.rail - m.inset * 2, height: line).fill()
        if showsReasoning {
            NSRect(x: middleMaxX + m.inset, y: m.header - line, width: m.reasoning - m.inset - 11 * m.scale, height: line).fill()
        }
        NSRect(x: 6 * m.scale, y: 48 * m.scale, width: m.rail - 12 * m.scale, height: line).fill()
    }
}

/// The composer capsule: `{brand} {model} {reasoning}` ("6.1 Sol Low"),
/// collapsing to the brand mark alone in compact composers.
@MainActor
final class AgentModelTriggerButton: NSButton {
    let glyph = AgentModelPickerBrand.imageView(pointSize: 14)
    let label = AgentChatText.makeLabel()
    private(set) var compact = false
    private(set) var agent: ChatAgent = .claude

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        imagePosition = .noImage
        setButtonType(.momentaryPushIn)
        focusRingType = .exterior
        addSubview(glyph)
        addSubview(label)
        setAccessibilityIdentifier("agent-chat.agent")
        setAccessibilityLabel("Model and provider")
    }

    required init?(coder: NSCoder) { nil }

    func configure(agent: ChatAgent, modelName: String?, reasoning: String?, compact: Bool) {
        self.agent = agent
        self.compact = compact
        glyph.image = AgentModelPickerBrand.image(for: agent)
        glyph.symbolConfiguration = .init(pointSize: 18 * scale, weight: .regular)
        glyph.contentTintColor = AgentModelPickerBrand.tint(for: agent, emphasized: true)
        let text = [modelName ?? agent.displayName, reasoning].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ")
        AgentChatText.apply(label, text: text, font: AgentChatText.font(13, .medium), color: .textPrimary)
        label.isHidden = compact
        setAccessibilityValue(text)
        toolTip = [agent.displayName, text].joined(separator: " · ")
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    private var scale: CGFloat { CGFloat(CockpitUIZoomController.shared.factor) }

    override var intrinsicContentSize: NSSize {
        let height = 28 * scale
        guard !compact else { return NSSize(width: height, height: height) }
        let text = AgentModelPickerDrawing.fit(label).width
        return NSSize(width: 10 * scale + 18 * scale + 6 * scale + text + 11 * scale, height: height)
    }

    override func layout() {
        super.layout()
        let size = 18 * scale
        let glyphX = compact ? (bounds.width - size) / 2 : 10 * scale
        glyph.frame = NSRect(x: glyphX, y: (bounds.height - size) / 2, width: size, height: size)
        let height = AgentModelPickerDrawing.fit(label).height
        let x = glyph.frame.maxX + 6 * scale
        label.frame = NSRect(x: x, y: (bounds.height - height) / 2, width: max(0, bounds.width - x - 10 * scale), height: height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) && !isHidden ? self : nil
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.14 : 0.07).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}
