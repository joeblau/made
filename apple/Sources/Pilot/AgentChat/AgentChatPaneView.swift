import AppKit
import Observation

/// A virtualized native transcript. The registry owns the ACP process; this
/// controller owns only the currently attached presentation and its updates.
@MainActor
final class AgentChatPaneViewController: NSViewController, CockpitPanePresenting, CockpitPaneClosing, CockpitPaneContextUpdating,
    CockpitPaneInputFocusing, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
    let pane: Pane
    let session: AgentChatSession
    var onSelect: (() -> Void)?
    private let table = NSTableView()
    private let transcriptScroll = NSScrollView()
    private let agentMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    private let providerMark = NSImageView()
    private let modelLabel = NSTextField(labelWithString: "")
    private let usageLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let composer = AgentChatComposerTextView()
    private let composerScroll = NSScrollView()
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    private let setupStack = NSStackView()
    private let failureStack = NSStackView()
    private let permissionStack = NSStackView()
    private var permissionButtons: NSStackView?
    private var rows: [AgentChatNativeRow] = []
    private var rendered: [String: AgentChatRenderedRow] = [:]
    private var expandedIDs: Set<String> = []
    private var refreshTask: Task<Void, Never>?
    private var observationGeneration = 0
    private var rootPath: String?
    private var active = false
    private var selected = false
    private var closed = false
    private var wantsComposerFocus = false
    private var applyingRowsFollowOutput: Bool?
    private var previousPhase: AgentChatSession.Phase?
    private var previousPermission: ACPPermissionRequest?
    private var previousQueuedPermissions = -1
    private var lastWidth: CGFloat = 0

    init(pane: Pane, rootPath: String?) {
        self.pane = pane
        self.rootPath = rootPath
        session = AgentChatRegistry.shared.session(for: pane.id, workingDirectory: rootPath)
        super.init(nibName: nil, bundle: nil)
        session.setWorkingDirectory(rootPath)
    }

    /// Injecting a session keeps native UI tests independent of agent installs,
    /// authentication and the user's saved conversation.
    init(pane: Pane, session: AgentChatSession) {
        self.pane = pane
        self.session = session
        self.rootPath = session.workingDirectory
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = AgentChatBackgroundView()
        view = root
        let header = makeHeader()
        let content = NSView()
        configureTranscript(in: content)
        configureSetup(in: content)
        configureComposer()
        failureStack.orientation = .horizontal
        failureStack.spacing = 8
        permissionStack.orientation = .vertical
        permissionStack.alignment = .leading
        permissionStack.spacing = 8
        failureStack.isHidden = true
        permissionStack.isHidden = true
        let composeRow = NSStackView(views: [composerScroll, sendButton])
        composeRow.orientation = .horizontal
        composeRow.alignment = .bottom
        composeRow.spacing = 8
        let lower = NSStackView(views: [failureStack, permissionStack, composeRow])
        lower.orientation = .vertical
        lower.alignment = .leading
        lower.spacing = 8
        for child in [header, content, lower] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        for child in [failureStack, permissionStack, composeRow] {
            child.widthAnchor.constraint(equalTo: lower.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: lower.topAnchor, constant: -8),
            lower.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            lower.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            lower.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            composerScroll.heightAnchor.constraint(equalToConstant: 74),
            composerScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(zoomChanged), name: .cockpitUIZoomDidChange, object: nil)
        render()
    }

    private func makeHeader() -> NSStackView {
        agentMenu.addItem(withTitle: session.agent.displayName)
        for agent in ChatAgent.allCases {
            let item = NSMenuItem(title: agent.displayName, action: #selector(changeAgent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = agent.rawValue
            agentMenu.menu?.addItem(item)
        }
        agentMenu.menu?.addItem(.separator())
        let new = NSMenuItem(title: "New Conversation", action: #selector(newConversation), keyEquivalent: "")
        new.target = self
        agentMenu.menu?.addItem(new)
        let restart = NSMenuItem(title: "Restart Agent", action: #selector(restart), keyEquivalent: "")
        restart.target = self
        agentMenu.menu?.addItem(restart)
        agentMenu.setAccessibilityLabel("Chat agent and conversation actions")
        agentMenu.setAccessibilityIdentifier("agent-chat.agent")
        agentMenu.toolTip = "Switch agent or start a new conversation"
        providerMark.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        providerMark.imageScaling = .scaleProportionallyUpOrDown
        providerMark.widthAnchor.constraint(equalToConstant: 8).isActive = true
        providerMark.heightAnchor.constraint(equalToConstant: 8).isActive = true
        modelLabel.font = CockpitTypography.font(size: 11)
        agentMenu.font = CockpitTypography.font(size: 13, weight: .semibold)
        modelLabel.lineBreakMode = .byTruncatingTail
        modelLabel.textColor = .secondaryLabelColor
        modelLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        usageLabel.textColor = .secondaryLabelColor
        usageLabel.font = CockpitTypography.font(size: 10, monospaced: true)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let header = NSStackView(views: [providerMark, agentMenu, modelLabel, NSView(), usageLabel, spinner])
        header.orientation = .horizontal
        header.spacing = 8
        return header
    }

    private func configureTranscript(in content: NSView) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("transcript"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.intercellSpacing = NSSize(width: 0, height: 8)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.selectionHighlightStyle = .none
        table.backgroundColor = .textBackgroundColor
        table.setAccessibilityLabel("Agent conversation")
        table.setAccessibilityIdentifier("agent-chat.transcript")
        transcriptScroll.documentView = table
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.autohidesScrollers = true
        transcriptScroll.drawsBackground = false
        transcriptScroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(transcriptScroll)
        NSLayoutConstraint.activate([
            transcriptScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            transcriptScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            transcriptScroll.topAnchor.constraint(equalTo: content.topAnchor),
            transcriptScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func configureSetup(in content: NSView) {
        setupStack.orientation = .vertical
        setupStack.alignment = .centerX
        setupStack.spacing = 12
        setupStack.translatesAutoresizingMaskIntoConstraints = false
        setupStack.isHidden = true
        content.addSubview(setupStack)
        NSLayoutConstraint.activate([
            setupStack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            setupStack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            setupStack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 20),
            setupStack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
        ])
    }

    private func configureComposer() {
        composer.delegate = self
        composer.font = CockpitTypography.font(size: 13)
        composer.isRichText = false
        composer.allowsUndo = true
        composer.textContainerInset = NSSize(width: 8, height: 8)
        composer.isVerticallyResizable = true
        composer.isHorizontallyResizable = false
        composer.textContainer?.widthTracksTextView = true
        composer.autoresizingMask = [.width]
        composer.setAccessibilityLabel("Message to agent")
        composer.setAccessibilityIdentifier("agent-chat.composer")
        composer.onSubmit = { [weak self] in self?.sendDraft() }
        composer.onCancel = { [weak self] in
            guard let self, session.phase == .prompting else { return false }
            session.cancelTurn()
            return true
        }
        composer.onFocus = { [weak self] in self?.onSelect?() }
        composerScroll.documentView = composer
        composerScroll.hasVerticalScroller = true
        composerScroll.autohidesScrollers = true
        composerScroll.borderType = .bezelBorder
        sendButton.target = self
        sendButton.action = #selector(sendOrStop)
        sendButton.font = CockpitTypography.font(size: 13)
        sendButton.setAccessibilityIdentifier("agent-chat.send")
    }

    func updateContext(rootPath: String?) {
        self.rootPath = rootPath
        session.setWorkingDirectory(rootPath)
    }

    func focusPaneInput() {
        guard active, selected, !closed, isViewLoaded, let window = view.window else { return }
        wantsComposerFocus = !composer.isEditable
        if wantsComposerFocus || !window.makeFirstResponder(composer) { window.makeFirstResponder(nil) }
    }

    func updatePresentation(isActive: Bool, isSelected: Bool) {
        guard !closed else { return }
        let wasActive = active
        let becameSelected = !selected && isSelected
        active = isActive
        selected = isSelected
        if !active || !selected { wantsComposerFocus = false }
        if active {
            _ = view
            session.setWorkingDirectory(rootPath)
            session.startIfNeeded()
            if !wasActive { renderAndObserve() }
            if becameSelected { focusPaneInput() }
        } else if wasActive {
            observationGeneration += 1
            refreshTask?.cancel()
            refreshTask = nil
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if active, selected { focusPaneInput() }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if let buttons = permissionButtons {
            let requiredWidth = buttons.arrangedSubviews.reduce(CGFloat(0)) { $0 + $1.fittingSize.width }
                + CGFloat(max(0, buttons.arrangedSubviews.count - 1)) * buttons.spacing
            let orientation: NSUserInterfaceLayoutOrientation = requiredWidth > permissionStack.bounds.width ? .vertical : .horizontal
            if buttons.orientation != orientation {
                buttons.orientation = orientation
                buttons.alignment = orientation == .vertical ? .leading : .centerY
            }
        }
        let width = table.bounds.width
        guard abs(width - lastWidth) > 1, !rows.isEmpty else { return }
        lastWidth = width
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: rows.indices))
    }

    private func renderAndObserve() {
        guard active, !closed else { return }
        observationGeneration += 1
        let generation = observationGeneration
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation, self.active, !self.closed else { return }
                self.scheduleRefresh()
            }
        }
    }

    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            refreshTask = nil
            renderAndObserve()
        }
    }

    private func render() {
        agentMenu.item(at: 0)?.title = session.agent.displayName
        providerMark.contentTintColor = AgenticUseModelPalette.providerColor(for: session.agent.provider)
        for item in agentMenu.itemArray {
            if let raw = item.representedObject as? String {
                item.state = raw == session.agent.rawValue ? .on : .off
            }
        }
        modelLabel.stringValue = session.modelName ?? ""
        var usage: [String] = []
        var help: [String] = []
        if let context = session.context {
            usage.append("\(AgentChatFormat.tokens(context.usedTokens)) / \(AgentChatFormat.tokens(context.windowTokens))")
            help.append("Context window: \(context.usedTokens.formatted()) of \(context.windowTokens.formatted()) tokens used")
            if let amount = context.costAmount {
                help.append("Session cost: \(amount.formatted(.currency(code: context.costCurrency ?? "USD")))")
            }
        }
        if let rate = session.lastTurnUsage?.cacheHitRate {
            usage.append("Cache \(AgentChatFormat.percent(rate))")
        }
        if let total = session.sessionUsage {
            help.append("This session: \(total.cacheReadTokens.formatted()) cached, \(total.uncachedInputTokens.formatted()) uncached, \(total.cacheWriteTokens.formatted()) written to cache, \(total.outputTokens.formatted()) output tokens.")
        }
        usageLabel.stringValue = usage.joined(separator: "  ·  ")
        usageLabel.toolTip = help.joined(separator: "\n")
        let running = session.phase == .starting || session.phase == .prompting
        if running { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        spinner.toolTip = session.phase == .starting ? "Starting \(session.agent.displayName)…" : "Working…"
        composer.isEditable = session.phase == .ready || session.phase == .prompting
        if composer.isEditable, wantsComposerFocus, let window = view.window {
            wantsComposerFocus = false
            // A startup focus request may finish after the user focuses a
            // toolbar field. Only reclaim the neutral responder we left.
            if active, selected,
               window.firstResponder == nil || window.firstResponder === window || window.firstResponder === window.contentView {
                window.makeFirstResponder(composer)
            }
        }
        composer.placeholder = "Message \(session.agent.displayName)"
        if composer.string != session.draft, !composer.hasMarkedText() {
            composer.string = session.draft
        }
        sendButton.title = session.phase == .prompting ? "Stop" : "Send"
        sendButton.toolTip = session.phase == .prompting ? "Stop (Esc)" : "Send (Return); Option-Return inserts a newline"
        sendButton.isEnabled = session.phase == .prompting || session.canSend
        renderPhase()
        renderPermission()
        applyRows(projectedRows())
    }

    private func renderPhase() {
        guard previousPhase != session.phase else { return }
        previousPhase = session.phase
        clear(setupStack)
        clear(failureStack)
        setupStack.isHidden = true
        transcriptScroll.isHidden = false
        failureStack.isHidden = true
        switch session.phase {
        case .needsSetup(let issue):
            setupStack.isHidden = false
            transcriptScroll.isHidden = true
            setupStack.addArrangedSubview(label(issue.message, size: 13))
            if let command = issue.command {
                let commandLabel = label(command, size: 12, monospaced: true)
                let copy = AgentChatActionButton(title: "Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                setupStack.addArrangedSubview(commandLabel)
                setupStack.addArrangedSubview(copy)
            }
            if issue != .noWorkingDirectory {
                setupStack.addArrangedSubview(AgentChatActionButton(title: "Try Again") { [weak self] in self?.session.restart() })
            }
        case .failed(let message):
            failureStack.isHidden = false
            let error = label(message, size: 12)
            error.textColor = .systemRed
            failureStack.addArrangedSubview(error)
            failureStack.addArrangedSubview(AgentChatActionButton(title: "Restart") { [weak self] in self?.session.restart() })
        default: break
        }
    }

    private func renderPermission() {
        let request = session.pendingPermission
        let queued = session.permissionQueue.count
        guard previousPermission != request || previousQueuedPermissions != queued else { return }
        previousPermission = request
        previousQueuedPermissions = queued
        clear(permissionStack)
        permissionButtons = nil
        permissionStack.isHidden = request == nil
        guard let request else { return }
        let title = "\(session.agent.displayName) is asking for permission" + (queued > 1 ? " · +\(queued - 1) more" : "")
        for field in [label(title, size: 12), label(request.title, size: 12, monospaced: true)] {
            permissionStack.addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: permissionStack.widthAnchor).isActive = true
        }
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let options = request.options.filter { $0.kind?.allows == true } + request.options.filter { $0.kind?.allows != true }
        for option in options {
            buttons.addArrangedSubview(AgentChatActionButton(title: option.name) { [weak self] in
                self?.session.answerPermission(request, optionID: option.id)
            })
        }
        buttons.addArrangedSubview(AgentChatActionButton(title: "Cancel Request") { [weak self] in
            self?.session.answerPermission(request, optionID: nil)
        })
        permissionStack.addArrangedSubview(buttons)
        permissionButtons = buttons
        view.needsLayout = true
        NSAccessibility.post(element: permissionStack, notification: .layoutChanged)
    }

    private func projectedRows() -> [AgentChatNativeRow] {
        let transcript = session.transcript
        var output: [AgentChatNativeRow] = []
        func append(_ items: [AgentChatItem], parent: String, depth: Int, ancestors: Set<String>) {
            for item in items {
                let id = parent + "/" + item.id
                let isExpanded = expandedIDs.contains(id)
                let children: [AgentChatItem]
                if case .subagent(let subagent) = item.content {
                    children = transcript.children(of: subagent.childSessionID)
                } else { children = [] }
                output.append(AgentChatNativeRow(id: id, item: item, depth: depth, expanded: isExpanded, childCount: children.count))
                if isExpanded, case .subagent(let subagent) = item.content,
                   depth < 16, !ancestors.contains(subagent.childSessionID) {
                    append(children, parent: id, depth: depth + 1, ancestors: ancestors.union([subagent.childSessionID]))
                }
            }
        }
        append(transcript.items, parent: "root", depth: 0, ancestors: [])
        if output.isEmpty, session.phase == .ready {
            let directory = session.workingDirectory.map { ($0 as NSString).lastPathComponent } ?? "this workspace"
            output.append(.notice(id: "empty", text: "Ask \(session.agent.displayName) about \(directory)"))
        }
        if session.phase == .starting {
            output.append(.notice(id: "starting", text: "Starting \(session.agent.displayName)…"))
        }
        return output
    }

    private func applyRows(_ next: [AgentChatNativeRow]) {
        guard rows != next else { return }
        let visible = transcriptScroll.contentView.bounds
        let follow = rows.isEmpty || visible.maxY >= table.bounds.maxY - 32
        applyingRowsFollowOutput = follow
        defer { applyingRowsFollowOutput = nil }
        let oldIDs = rows.map(\.id)
        let newIDs = next.map(\.id)
        let oldRows = rows
        rows = next
        let currentIDs = Set(newIDs)
        rendered = rendered.filter { currentIDs.contains($0.key) }
        expandedIDs.formIntersection(currentIDs)
        if oldIDs == newIDs {
            let changed = IndexSet(next.indices.filter { oldRows[$0] != next[$0] })
            for index in changed { rendered.removeValue(forKey: next[index].id) }
            for index in changed {
                if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? AgentChatTranscriptCell {
                    configure(cell, row: index, followStreamingOutput: follow)
                }
            }
            table.noteHeightOfRows(withIndexesChanged: changed)
        } else if next.count >= oldRows.count, Array(newIDs.prefix(oldRows.count)) == oldIDs {
            let changed = IndexSet(oldRows.indices.filter { oldRows[$0] != next[$0] })
            for index in changed { rendered.removeValue(forKey: next[index].id) }
            table.beginUpdates()
            table.insertRows(at: IndexSet(integersIn: oldRows.count..<next.count), withAnimation: [])
            table.endUpdates()
            for index in changed {
                if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? AgentChatTranscriptCell {
                    configure(cell, row: index, followStreamingOutput: follow)
                }
            }
            table.noteHeightOfRows(withIndexesChanged: changed)
        } else {
            rendered.removeAll()
            table.reloadData()
        }
        if follow, !rows.isEmpty {
            table.layoutSubtreeIfNeeded()
            // A capped message row can still be taller than the viewport;
            // scrollRowToVisible may align its top instead of the newest text.
            let clip = transcriptScroll.contentView
            clip.scroll(to: NSPoint(x: 0, y: max(0, table.bounds.maxY - clip.bounds.height)))
            transcriptScroll.reflectScrolledClipView(clip)
            if let cell = table.view(atColumn: 0, row: rows.count - 1, makeIfNecessary: true) as? AgentChatTranscriptCell {
                configure(cell, row: rows.count - 1, followStreamingOutput: true)
                cell.layoutSubtreeIfNeeded()
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        onSelect?()
        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("agent-message")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? AgentChatTranscriptCell) ?? AgentChatTranscriptCell()
        cell.identifier = identifier
        configure(cell, row: row)
        return cell
    }

    private func configure(_ cell: AgentChatTranscriptCell, row: Int, followStreamingOutput: Bool? = nil) {
        guard rows.indices.contains(row) else { return }
        let item = rows[row]
        let outerFollows = followStreamingOutput ?? applyingRowsFollowOutput
            ?? (transcriptScroll.contentView.bounds.maxY >= table.bounds.maxY - 32)
        cell.apply(renderedRow(at: row), depth: item.depth,
                   followStreamingOutput: outerFollows && row == rows.count - 1)
        cell.onToggle = { [weak self] in
            guard let self else { return }
            if expandedIDs.contains(item.id) { expandedIDs.remove(item.id) } else { expandedIDs.insert(item.id) }
            applyRows(projectedRows())
        }
        cell.onSelect = { [weak self] in self?.onSelect?() }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return 44 }
        let display = renderedRow(at: row)
        let width = max(100, table.bounds.width - 36 - CGFloat(rows[row].depth) * 14)
        let textHeight = display.text.length == 0 ? 0 : ceil(display.text.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height) + 16
        return max(36, min(display.maximumTextHeight, textHeight) + (display.header == nil ? 8 : 32))
    }

    private func renderedRow(at index: Int) -> AgentChatRenderedRow {
        let row = rows[index]
        if let existing = rendered[row.id], existing.source == row { return existing }
        let result = AgentChatRenderedRow(row: row)
        rendered[row.id] = result
        return result
    }

    func textDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === composer else { return }
        session.draft = composer.string
        sendButton.isEnabled = session.phase == .prompting || session.canSend
        composer.needsDisplay = true
    }

    private func sendDraft() {
        // Return while a turn is streaming must not become the Stop action.
        guard session.phase == .ready else { return }
        session.draft = composer.string
        session.send()
        renderAndObserve()
    }

    @objc private func sendOrStop() {
        if session.phase == .prompting {
            session.cancelTurn()
            renderAndObserve()
        } else {
            sendDraft()
        }
    }

    @objc private func changeAgent(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let agent = ChatAgent(rawValue: raw) else { return }
        session.switchAgent(to: agent)
    }

    @objc private func newConversation() { session.startNewConversation() }
    @objc private func restart() { session.restart() }

    @objc private func zoomChanged() {
        composer.font = CockpitTypography.font(size: 13)
        modelLabel.font = CockpitTypography.font(size: 11)
        agentMenu.font = CockpitTypography.font(size: 13, weight: .semibold)
        sendButton.font = CockpitTypography.font(size: 13)
        usageLabel.font = CockpitTypography.font(size: 10, monospaced: true)
        previousPhase = nil
        previousPermission = nil
        previousQueuedPermissions = -1
        renderPhase()
        renderPermission()
        rendered.removeAll()
        table.reloadData()
    }

    func closePane() {
        guard !closed else { return }
        closed = true
        active = false
        observationGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        NotificationCenter.default.removeObserver(self)
        // Pane deletion already removes the registry session. Releasing a view
        // during application teardown must not erase its saved ACP session ID.
    }

    isolated deinit { closePane() }

    private func label(_ text: String, size: CGFloat, monospaced: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = CockpitTypography.font(size: size, monospaced: monospaced)
        field.isSelectable = true
        return field
    }

    private func clear(_ stack: NSStackView) {
        for child in stack.arrangedSubviews { stack.removeArrangedSubview(child); child.removeFromSuperview() }
    }
}

struct AgentChatNativeRow: Equatable {
    var id: String
    var item: AgentChatItem
    var depth: Int
    var expanded: Bool
    var childCount: Int

    static func notice(id: String, text: String) -> Self {
        Self(id: id, item: AgentChatItem(id: id, content: .notice(text)), depth: 0, expanded: false, childCount: 0)
    }
}

@MainActor
struct AgentChatRenderedRow {
    let source: AgentChatNativeRow
    let header: String?
    let text: NSAttributedString
    let copyText: String
    let expandable: Bool
    let maximumTextHeight: CGFloat
    let tint: NSColor?

    init(row: AgentChatNativeRow) {
        source = row
        maximumTextHeight = if case .tool = row.item.content { 200 } else { 1_200 }
        switch row.item.content {
        case .user(let value):
            header = nil
            text = AgentChatNativeMarkdown.plain(value, alignment: .right)
            copyText = value
            expandable = false
            tint = .controlAccentColor.withAlphaComponent(0.09)
        case .assistant(let value):
            header = nil
            text = AgentChatNativeMarkdown.render(value)
            copyText = value
            expandable = false
            tint = nil
        case .thought(let value):
            header = "Thinking"
            text = row.expanded ? AgentChatNativeMarkdown.plain(value, color: .secondaryLabelColor) : NSAttributedString()
            copyText = value
            expandable = true
            tint = nil
        case .tool(let tool):
            let status: String = switch tool.status {
            case .completed: "Completed"
            case .failed: "Failed"
            case .pending, .inProgress, nil: "Running"
            }
            header = "\(tool.title) · \(status)"
            text = row.expanded ? AgentChatNativeMarkdown.plain(tool.content, monospaced: true) : NSAttributedString()
            copyText = tool.content
            expandable = !tool.content.isEmpty
            tint = tool.status == .failed ? .systemRed.withAlphaComponent(0.07) : .quaternaryLabelColor.withAlphaComponent(0.12)
        case .plan(let entries):
            header = "Plan"
            let plan = NSMutableAttributedString()
            for entry in entries {
                let mark = entry.status == "completed" ? "✓" : (entry.status == "in_progress" ? "◉" : "○")
                let line = NSMutableAttributedString(attributedString: AgentChatNativeMarkdown.plain(mark + " " + entry.content + "\n"))
                if entry.status == "completed" {
                    line.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.secondaryLabelColor], range: NSRange(location: 0, length: line.length))
                }
                plan.append(line)
            }
            text = plan
            copyText = entries.map(\.content).joined(separator: "\n")
            expandable = false
            tint = .quaternaryLabelColor.withAlphaComponent(0.12)
        case .subagent(let subagent):
            let status = subagent.error != nil ? "Failed" : (subagent.isRunning ? "Running" : "Finished")
            header = "\(subagent.title) · \(status) · \(row.childCount) step\(row.childCount == 1 ? "" : "s")"
            let details = [subagent.detail, subagent.error].compactMap { $0 }.joined(separator: "\n")
            text = AgentChatNativeMarkdown.plain(details, color: subagent.error == nil ? .secondaryLabelColor : .systemRed)
            copyText = [subagent.title, details].filter { !$0.isEmpty }.joined(separator: "\n")
            expandable = true
            tint = .quaternaryLabelColor.withAlphaComponent(0.12)
        case .notice(let value):
            header = nil
            text = AgentChatNativeMarkdown.plain(value, color: .secondaryLabelColor)
            copyText = value
            expandable = false
            tint = nil
        }
    }
}

@MainActor
private enum AgentChatNativeMarkdown {
    static func plain(
        _ value: String,
        color: NSColor = .labelColor,
        monospaced: Bool = false,
        alignment: NSTextAlignment = .left
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.paragraphSpacing = 4
        return NSAttributedString(string: value, attributes: [
            .font: CockpitTypography.font(size: 13, monospaced: monospaced),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }

    static func render(_ value: String) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for segment in AgentChatMarkdown.segments(value) {
            if output.length > 0 { output.append(plain("\n\n")) }
            switch segment {
            case .code(let code):
                let block = NSMutableAttributedString(attributedString: plain(code, monospaced: true))
                block.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor.withAlphaComponent(0.12), range: NSRange(location: 0, length: block.length))
                output.append(block)
            case .prose(let prose):
                let parsed = AgentChatMarkdown.inline(prose)
                for run in parsed.runs {
                    let characters = String(parsed[run.range].characters)
                    let part = NSMutableAttributedString(attributedString: plain(characters))
                    let range = NSRange(location: 0, length: part.length)
                    var font = CockpitTypography.font(size: 13)
                    if let intent = run.inlinePresentationIntent {
                        if intent.contains(.code) {
                            font = CockpitTypography.font(size: 13, monospaced: true)
                            part.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor.withAlphaComponent(0.12), range: range)
                        }
                        if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                        if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                        if intent.contains(.strikethrough) { part.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
                    }
                    part.addAttribute(.font, value: font, range: range)
                    if let link = run.link { part.addAttribute(.link, value: link, range: range) }
                    output.append(part)
                }
            }
        }
        return output
    }
}

@MainActor
final class AgentChatTranscriptCell: NSTableCellView {
    var onToggle: (() -> Void)?
    var onSelect: (() -> Void)?
    private let headerButton = NSButton(title: "", target: nil, action: nil)
    private let copyButton = NSButton(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy message")!, target: nil, action: nil)
    private let text = AgentChatSelectableTextView()
    private let textScroll = NSScrollView()
    private var rowID: String?
    private var copyText = ""
    private var depth: Int = 0
    private var hasHeader = false
    private var tint: NSColor?
    private var followAfterLayout = false
    private var preservedScrollOrigin: NSPoint?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        headerButton.isBordered = false
        headerButton.alignment = .left
        headerButton.lineBreakMode = .byTruncatingMiddle
        headerButton.target = self
        headerButton.action = #selector(toggle)
        copyButton.isBordered = false
        copyButton.target = self
        copyButton.action = #selector(copyMessage)
        copyButton.toolTip = "Copy message"
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 4, height: 4)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true
        text.autoresizingMask = [.width]
        text.onSelect = { [weak self] in self?.onSelect?() }
        textScroll.drawsBackground = false
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        textScroll.documentView = text
        addSubview(headerButton)
        addSubview(copyButton)
        addSubview(textScroll)
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ row: AgentChatRenderedRow, depth: Int, followStreamingOutput: Bool = false) {
        let wasAtBottom = rowID != row.source.id || textScroll.contentView.bounds.maxY >= text.bounds.maxY - 24
        followAfterLayout = followAfterLayout || (followStreamingOutput && wasAtBottom)
        if !followAfterLayout { preservedScrollOrigin = textScroll.contentView.bounds.origin }
        let selection = rowID == row.source.id ? text.selectedRanges : []
        rowID = row.source.id
        self.depth = depth
        hasHeader = row.header != nil
        copyText = row.copyText
        headerButton.isHidden = !hasHeader
        headerButton.title = row.header ?? ""
        headerButton.isEnabled = row.expandable
        headerButton.image = row.expandable ? NSImage(systemSymbolName: row.source.expanded ? "chevron.down" : "chevron.right", accessibilityDescription: row.source.expanded ? "Collapse" : "Expand") : nil
        headerButton.imagePosition = .imageLeading
        headerButton.font = CockpitTypography.font(size: 12, weight: .medium)
        headerButton.setAccessibilityLabel(row.header)
        if !text.attributedString().isEqual(to: row.text) {
            text.textStorage?.setAttributedString(row.text)
            let length = row.text.length
            let valid = selection.filter { NSMaxRange($0.rangeValue) <= length }
            if !valid.isEmpty { text.selectedRanges = valid }
        }
        copyButton.isHidden = row.copyText.isEmpty
        tint = row.tint
        updateBackground()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = tint?.cgColor
        }
    }

    override func layout() {
        super.layout()
        let left = CGFloat(depth) * 14 + 8
        let width = max(0, bounds.width - left - 8)
        headerButton.frame = NSRect(x: left, y: bounds.height - 28, width: max(0, width - 30), height: 24)
        copyButton.frame = NSRect(x: bounds.width - 30, y: bounds.height - 28, width: 24, height: 24)
        let top = hasHeader ? 30.0 : 4.0
        textScroll.frame = NSRect(x: left, y: 4, width: max(0, width - (hasHeader ? 0 : 24)), height: max(0, bounds.height - top - 4))
        text.setFrameSize(NSSize(width: textScroll.contentSize.width, height: max(textScroll.contentSize.height, text.frame.height)))
        if let container = text.textContainer { text.layoutManager?.ensureLayout(for: container) }
        if followAfterLayout {
            text.scrollToEndOfDocument(nil)
        } else if let origin = preservedScrollOrigin {
            textScroll.contentView.scroll(to: origin)
            textScroll.reflectScrolledClipView(textScroll.contentView)
        }
        followAfterLayout = false
        preservedScrollOrigin = nil
    }

    @objc private func toggle() { onSelect?(); onToggle?() }

    @objc private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
    }
}

@MainActor
private final class AgentChatSelectableTextView: NSTextView {
    var onSelect: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onSelect?(); super.mouseDown(with: event) }
}

@MainActor
final class AgentChatComposerTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Bool)?
    var onFocus: (() -> Void)?
    var placeholder = "Message" { didSet { if oldValue != placeholder { needsDisplay = true } } }

    override func becomeFirstResponder() -> Bool {
        onFocus?()
        return super.becomeFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        // An input method owns Return while composing marked text.
        if !hasMarkedText(), event.keyCode == 36 || event.keyCode == 76 {
            if event.modifierFlags.intersection([.option, .shift]).isEmpty {
                onSubmit?()
            } else {
                insertNewline(nil)
            }
            return
        }
        if !hasMarkedText(), event.keyCode == 53, onCancel?() == true { return }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width + 4, y: textContainerInset.height), withAttributes: [
            .font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.placeholderTextColor,
        ])
    }
}

@MainActor
private final class AgentChatActionButton: NSButton {
    private let invoke: () -> Void

    init(title: String, action: @escaping () -> Void) {
        invoke = action
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        font = CockpitTypography.font(size: 13)
        target = self
        self.action = #selector(performAction)
    }

    required init?(coder: NSCoder) { nil }
    @objc private func performAction() { invoke() }
}

/// Optional native tab accessory; it observes only agent identity and phase.
@MainActor
final class AgentChatTabBadge: NSView {
    let paneID: UUID
    private let label = NSTextField(labelWithString: "")
    private let badge = NSView()
    private let spinner = NSProgressIndicator()
    private var generation = 0
    private var tint: NSColor = .clear

    init(paneID: UUID) {
        self.paneID = paneID
        super.init(frame: .zero)
        label.font = CockpitTypography.font(size: 10, weight: .semibold)
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 7
        label.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: badge.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: badge.bottomAnchor, constant: -2),
        ])
        let stack = NSStackView(views: [badge, spinner])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let agent = AgentChatPaneStore.agent(for: paneID)
        label.stringValue = agent.displayName
        tint = AgenticUseModelPalette.providerColor(for: agent.provider).withAlphaComponent(0.15)
        updateBackground()
        NotificationCenter.default.addObserver(self, selector: #selector(updateFont), name: .cockpitUIZoomDidChange, object: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        generation += 1
        if window != nil { observe() } else { spinner.stopAnimation(nil) }
    }

    private func observe() {
        let current = generation
        withObservationTracking {
            let session = AgentChatRegistry.shared.existingSession(for: paneID)
            let agent = session?.agent ?? AgentChatPaneStore.agent(for: paneID)
            label.stringValue = agent.displayName
            tint = AgenticUseModelPalette.providerColor(for: agent.provider).withAlphaComponent(0.15)
            updateBackground()
            if session?.phase == .prompting { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == current, self.window != nil else { return }
                self.observe()
            }
        }
    }

    @objc private func updateFont() { label.font = CockpitTypography.font(size: 10, weight: .semibold) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance { badge.layer?.backgroundColor = tint.cgColor }
    }

    isolated deinit { NotificationCenter.default.removeObserver(self) }
}

@MainActor
private final class AgentChatBackgroundView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateBackground()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        }
    }
}

// MARK: - Formatting

enum AgentChatFormat {
    static func tokens(_ count: Int) -> String {
        let value = Double(count)
        let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))
        switch count {
        case ..<1_000: return "\(count)"
        case ..<1_000_000: return (value / 1_000).formatted(style) + "k"
        default: return (value / 1_000_000).formatted(style) + "M"
        }
    }

    static func percent(_ rate: Double) -> String {
        "\(Int((rate * 100).rounded()))%"
    }
}

/// Minimal Markdown for agent replies: fenced code blocks render as
/// monospaced blocks, everything else as inline Markdown. An unterminated
/// fence (mid-stream) renders as code so text doesn't jump when it closes.
enum AgentChatMarkdown {
    enum Segment: Equatable {
        case prose(String)
        case code(String)
    }

    static func segments(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var prose: [Substring] = []
        var code: [Substring] = []
        var inCode = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    segments.append(.code(code.joined(separator: "\n")))
                    code.removeAll()
                } else if !prose.isEmpty {
                    let joined = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
                    if !joined.isEmpty { segments.append(.prose(joined)) }
                    prose.removeAll()
                }
                inCode.toggle()
            } else if inCode {
                code.append(line)
            } else {
                prose.append(line)
            }
        }
        if inCode {
            segments.append(.code(code.joined(separator: "\n")))
        } else {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { segments.append(.prose(joined)) }
        }
        return segments
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        )) ?? AttributedString(text)
    }
}
