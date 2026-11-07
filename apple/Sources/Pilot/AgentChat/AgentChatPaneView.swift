import AppKit
import Observation
import UniformTypeIdentifiers

/// The agent chat pane. The registry owns the ACP process; this controller
/// owns the attached presentation: the projected timeline
/// (`AgentChatTimelineTable`), the Inspector overlay, the docked approval
/// card, and the composer with Stop / Steer / Queue.
@MainActor
final class AgentChatPaneViewController: NSViewController, CockpitPanePresenting, CockpitPaneClosing, CockpitPaneContextUpdating,
    CockpitPaneInputFocusing, NSTextViewDelegate {
    let pane: Pane
    let session: AgentChatSession
    var onSelect: (() -> Void)?
    let table = AgentChatTimelineTableView()
    private(set) lazy var timeline = AgentChatTimelineTable(tableView: table)
    let inspector = AgentInspectorViewController()
    let approvalCard = ApprovalCardView()
    let stopButton = AgentChatStopButton()
    let composerChip = AgentChatComposerChip()
    private let transcriptScroll = NSScrollView()
    private let transcriptArea = NSView()
    private let agentMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    private let attachmentButton = NSButton()
    private let attachmentStrip = AgentChatAttachmentStrip()
    private let composerStatus = NSTextField(wrappingLabelWithString: "")
    private let providerMark = NSImageView()
    private let modelLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let composer = AgentChatComposerTextView()
    private let composerScroll = NSScrollView()
    private let composerCard = AgentChatComposerCard()
    private let composerSpacer = NSView()
    private let sendButton = AgentChatSendButton()
    private let emptyPrompt = NSTextField(wrappingLabelWithString: "")
    private var composerHeight: NSLayoutConstraint?
    private var approvalHeight: NSLayoutConstraint?
    private let setupStack = NSStackView()
    private let failureStack = NSStackView()
    private var refreshTask: Task<Void, Never>?
    private var observationGeneration = 0
    private var rootPath: String?
    private var active = false
    private var selected = false
    private var closed = false
    private var wantsComposerFocus = false
    private var previousPhase: AgentChatSession.Phase?
    private var previousPermission: ACPPermissionRequest?
    private var previousQueuedPermissions = -1
    private var approvalWidth: CGFloat = 0
    private var lastWidth: CGFloat = 0
    private var displayedAgent: ChatAgent?
    private var menuSignature: [String]?
    private var compactComposer: Bool?
    private var composerControls: NSStackView?

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
        root.onStopShortcut = { [weak self] in self?.stopTurn() ?? false }
        view = root
        configureTranscript()
        configureSetup()
        configureComposer()
        let controls = makeComposerControls()
        let editor = NSStackView(views: [composerChip, attachmentStrip, composerScroll])
        editor.orientation = .vertical
        editor.alignment = .leading
        editor.spacing = 8
        composerChip.isHidden = true
        composerChip.onRemove = { [weak self] in self?.session.clearQueuedPrompt() }
        attachmentStrip.isHidden = true
        attachmentStrip.onRemove = { [weak self] id in self?.session.removeAttachment(id: id) }
        for child in [composerChip, attachmentStrip, composerScroll] as [NSView] {
            child.widthAnchor.constraint(equalTo: editor.widthAnchor).isActive = true
        }
        for child in [editor, controls] {
            child.translatesAutoresizingMaskIntoConstraints = false
            composerCard.addSubview(child)
        }
        failureStack.orientation = .horizontal
        failureStack.spacing = 8
        failureStack.isHidden = true
        approvalCard.isHidden = true
        composerStatus.font = CockpitTypography.font(size: 11)
        composerStatus.isHidden = true
        let lower = NSStackView(views: [failureStack, approvalCard, composerStatus, composerCard])
        lower.orientation = .vertical
        lower.alignment = .leading
        lower.spacing = 8
        for child in [transcriptArea, lower] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        for child in [failureStack, approvalCard, composerStatus, composerCard] as [NSView] {
            child.widthAnchor.constraint(equalTo: lower.widthAnchor).isActive = true
        }
        let inputHeight = composerScroll.heightAnchor.constraint(equalToConstant: 44)
        composerHeight = inputHeight
        let cardHeight = approvalCard.heightAnchor.constraint(equalToConstant: 0)
        approvalHeight = cardHeight
        NSLayoutConstraint.activate([
            transcriptArea.leadingAnchor.constraint(equalTo: lower.leadingAnchor, constant: -4),
            transcriptArea.trailingAnchor.constraint(equalTo: lower.trailingAnchor, constant: 4),
            transcriptArea.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            transcriptArea.bottomAnchor.constraint(equalTo: lower.topAnchor, constant: -8),
            lower.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            lower.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            lower.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            editor.leadingAnchor.constraint(equalTo: composerCard.leadingAnchor, constant: 12),
            editor.trailingAnchor.constraint(equalTo: composerCard.trailingAnchor, constant: -12),
            editor.topAnchor.constraint(equalTo: composerCard.topAnchor, constant: 12), inputHeight, cardHeight,
            controls.topAnchor.constraint(equalTo: editor.bottomAnchor, constant: 8),
            controls.leadingAnchor.constraint(equalTo: composerCard.leadingAnchor, constant: 12),
            controls.trailingAnchor.constraint(equalTo: composerCard.trailingAnchor, constant: -12),
            controls.bottomAnchor.constraint(equalTo: composerCard.bottomAnchor, constant: -12),
        ])
        configureInspector()
        NotificationCenter.default.addObserver(self, selector: #selector(zoomChanged), name: .cockpitUIZoomDidChange, object: nil)
        render()
    }

    private func makeComposerControls() -> NSStackView {
        attachmentButton.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil)
        attachmentButton.imagePosition = .imageOnly
        attachmentButton.isBordered = false
        attachmentButton.target = self
        attachmentButton.action = #selector(chooseAttachments)
        attachmentButton.setAccessibilityLabel("Attach photos or videos")
        attachmentButton.setAccessibilityIdentifier("agent-chat.attach")
        agentMenu.isBordered = false
        agentMenu.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        agentMenu.setAccessibilityLabel("Model and provider")
        agentMenu.setAccessibilityIdentifier("agent-chat.agent")
        refreshAgentMenu()
        providerMark.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        providerMark.imageScaling = .scaleProportionallyUpOrDown
        modelLabel.font = CockpitTypography.font(size: 11)
        agentMenu.font = CockpitTypography.font(size: 13, weight: .semibold)
        modelLabel.lineBreakMode = .byTruncatingTail
        modelLabel.textColor = .secondaryLabelColor
        modelLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.isHidden = true
        let controls = NSStackView(views: [attachmentButton, modelLabel, composerSpacer, spinner, providerMark, agentMenu,
                                           stopButton, sendButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        composerControls = controls
        for (control, size) in [(attachmentButton, NSSize(width: 28, height: 32)), (providerMark, NSSize(width: 8, height: 8)),
                                (stopButton, NSSize(width: 28, height: 28)), (sendButton, NSSize(width: 32, height: 32))] as [(NSView, NSSize)] {
            control.widthAnchor.constraint(equalToConstant: size.width).isActive = true
            control.heightAnchor.constraint(equalToConstant: size.height).isActive = true
        }
        return controls
    }

    private func configureTranscript() {
        timeline.actions = rowActions()
        timeline.now = { [weak self] in self?.session.now() ?? Date() }
        timeline.onStateChange = { [weak self] in self?.scheduleRefresh() }
        timeline.onSelect = { [weak self] in self?.onSelect?() }
        // Read live: a stored transcript snapshot would force a full copy on
        // the session's next mutation.
        timeline.stepInput = { [weak self] in self?.session.transcript.stepDetails[$0]?.rawInput?.value }
        timeline.approvalVerb = { [weak self] approval in
            self.flatMap { AgentChatPaneContent.recordVerb(for: approval, in: $0.session.transcript) }
        }
        timeline.observeScrolling(transcriptScroll)
        table.onKey = { [weak self] key in self?.handleTableKey(key) ?? false }
        transcriptScroll.documentView = table
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.autohidesScrollers = true
        transcriptScroll.drawsBackground = false
        transcriptScroll.translatesAutoresizingMaskIntoConstraints = false
        transcriptArea.addSubview(transcriptScroll)
        NSLayoutConstraint.activate([
            transcriptScroll.leadingAnchor.constraint(equalTo: transcriptArea.leadingAnchor, constant: 8),
            transcriptScroll.trailingAnchor.constraint(equalTo: transcriptArea.trailingAnchor, constant: -8),
            transcriptScroll.topAnchor.constraint(equalTo: transcriptArea.topAnchor),
            transcriptScroll.bottomAnchor.constraint(equalTo: transcriptArea.bottomAnchor),
        ])
    }

    /// Row callbacks shared by the timeline and the Inspector's nested card.
    private func rowActions() -> AgentChatRowActions {
        var actions = AgentChatRowActions()
        actions.openInspector = { [weak self] subject, tab in self?.openInspector(subject, tab: tab) }
        actions.copyText = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        actions.askToRetry = { [weak self] key in self?.session.prefillAskToRetry(stepKey: key); self?.focusComposer() }
        actions.askToContinue = { [weak self] child in self?.session.prefillAskToContinue(childSessionID: child); self?.focusComposer() }
        actions.sendAgain = { [weak self] in self?.session.sendAgain() }
        return actions
    }

    private func configureInspector() {
        addChild(inspector)
        inspector.mount(in: transcriptArea)
        var actions = rowActions()
        actions.toggleExpanded = { _ in }
        inspector.actions = actions
        let session = session
        inspector.runTraceSource = { (session.transcript, session.agent.displayName) }
        inspector.now = { session.now() }
        inspector.onClose = { [weak self] in self?.view.needsLayout = true }
    }

    private func configureSetup() {
        emptyPrompt.font = CockpitTypography.font(size: 17, weight: .medium)
        emptyPrompt.textColor = .secondaryLabelColor
        emptyPrompt.alignment = .center
        setupStack.orientation = .vertical
        setupStack.alignment = .centerX
        setupStack.spacing = 12
        setupStack.isHidden = true
        for child in [emptyPrompt, setupStack] {
            child.translatesAutoresizingMaskIntoConstraints = false
            transcriptArea.addSubview(child)
            NSLayoutConstraint.activate([
                child.centerXAnchor.constraint(equalTo: transcriptArea.centerXAnchor),
                child.centerYAnchor.constraint(equalTo: transcriptArea.centerYAnchor),
                child.leadingAnchor.constraint(greaterThanOrEqualTo: transcriptArea.leadingAnchor, constant: 24),
                child.trailingAnchor.constraint(lessThanOrEqualTo: transcriptArea.trailingAnchor, constant: -24),
            ])
        }
    }

    private func configureComposer() {
        composer.onPasteMedia = { [weak self] pasteboard in self?.attach(from: pasteboard) ?? false }
        composerCard.onPasteMedia = { [weak self] pasteboard in self?.attach(from: pasteboard) ?? false }
        composer.delegate = self
        composer.font = CockpitTypography.font(size: 14)
        composer.isRichText = false
        composer.allowsUndo = true
        composer.textContainerInset = NSSize(width: 4, height: 6)
        composer.drawsBackground = false
        composer.isVerticallyResizable = true
        composer.isHorizontallyResizable = false
        composer.textContainer?.widthTracksTextView = true
        composer.autoresizingMask = [.width]
        composer.setAccessibilityLabel("Message to agent")
        composer.setAccessibilityIdentifier("agent-chat.composer")
        composer.onSubmit = { [weak self] in self?.sendDraft() }
        composer.onCancel = { [weak self] in self?.handleEscape(fromComposer: true) ?? false }
        composer.onStop = { [weak self] in self?.stopTurn() ?? false }
        composer.onBacktab = { [weak self] in self?.focusTranscript() ?? false }
        composer.onFocus = { [weak self] in self?.onSelect?() }
        composerScroll.documentView = composer
        composerScroll.hasVerticalScroller = true
        composerScroll.autohidesScrollers = true
        composerScroll.scrollerStyle = .overlay
        composerScroll.drawsBackground = false
        composerScroll.borderType = .noBorder
        sendButton.target = self
        sendButton.action = #selector(sendClicked)
        sendButton.setAccessibilityIdentifier("agent-chat.send")
    }

    private func attach(from pasteboard: NSPasteboard) -> Bool {
        let inputs = AgentChatMediaPasteboard.inputs(pasteboard)
        guard !inputs.isEmpty else { return false }
        onSelect?()
        session.addAttachments(inputs)
        renderAndObserve()
        return true
    }

    @objc private func chooseAttachments() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.title = "Attach Photos or Videos"
        panel.prompt = "Attach"
        panel.allowedContentTypes = [.image, .movie]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            session.addAttachments(panel.urls.map(AgentChatAttachmentInput.file))
            renderAndObserve()
        }
    }

    // MARK: Agent menu

    private func refreshAgentMenu() {
        let editable = session.phase == .ready && !session.isChangingModel && !session.isPreparingPrompt
        let info = AgentChatFormat.contextSummary(session.context, usage: session.lastTurnUsage)
        let signature = [session.agent.rawValue, String(describing: session.modelState), "\(editable)", info ?? ""]
        guard menuSignature != signature else { return }
        menuSignature = signature
        compactComposer = nil
        AgentChatAgentMenu.populate(agentMenu, session: session, editable: editable, info: info, target: self, actions: .init(
            changeModel: #selector(changeModel(_:)), changeAgent: #selector(changeAgent(_:)),
            newConversation: #selector(newConversation), restart: #selector(restart)
        ))
    }

    // MARK: Presentation lifecycle

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
            timeline.isPaused = false
            if !wasActive { renderAndObserve() }
            if becameSelected { focusPaneInput() }
        } else if wasActive {
            observationGeneration += 1
            refreshTask?.cancel()
            refreshTask = nil
            timeline.isPaused = true
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if active, selected { focusPaneInput() }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateComposerLayout()
        if !approvalCard.isHidden, abs(approvalCard.bounds.width - approvalWidth) > 1 { renderApproval(force: true) }
        let width = table.bounds.width
        guard abs(width - lastWidth) > 1 else { return }
        lastWidth = width
        timeline.widthChanged()
    }

    private func updateComposerLayout() {
        let scale = CGFloat(CockpitUIZoomController.shared.factor)
        // Keep the provider and send action usable in narrow split panes.
        let compact = composerCard.bounds.width < 240 * scale
        composerSpacer.isHidden = compact
        providerMark.isHidden = compact
        spinner.isHidden = compact || (session.phase != .starting && session.phase != .prompting)
        if compactComposer != compact {
            compactComposer = compact
            composerControls?.spacing = compact ? 4 : 8
            agentMenu.imagePosition = compact ? .imageOnly : .noImage
            agentMenu.item(at: 0)?.image = compact ? NSImage(systemSymbolName: "brain", accessibilityDescription: nil) : nil
        }
        modelLabel.isHidden = modelLabel.stringValue.isEmpty || composerCard.bounds.width < 440 * scale
        guard composerScroll.contentSize.width > 0, let layout = composer.layoutManager,
              let container = composer.textContainer else { return }
        layout.ensureLayout(for: container)
        let textHeight = layout.usedRect(for: container).height + composer.textContainerInset.height * 2
        // Long drafts scroll once they occupy about a third of the pane.
        let maximum = max(44 * scale, min(180 * scale, view.bounds.height * 0.3))
        let height = min(maximum, max(44 * scale, ceil(textHeight)))
        if let composerHeight, abs(composerHeight.constant - height) > 0.5 {
            composerHeight.constant = height
        }
    }

    private func renderAndObserve() {
        guard active, !closed else { return }
        refreshTask?.cancel()
        refreshTask = nil
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
        guard refreshTask == nil, active, !closed else { return }
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            refreshTask = nil
            renderAndObserve()
        }
    }

    private func render() {
        let changingAgent = displayedAgent != nil && displayedAgent != session.agent
        displayedAgent = session.agent
        defer { if changingAgent { CockpitMotion.reveal(view) } }
        refreshAgentMenu()
        providerMark.contentTintColor = AgenticUseModelPalette.providerColor(for: session.agent.provider)
        modelLabel.stringValue = session.modelName == nil ? "" : session.agent.displayName
        modelLabel.toolTip = session.modelName
        agentMenu.toolTip = [session.agent.displayName, session.modelName].compactMap { $0 }.joined(separator: "\n")
        attachmentStrip.update(session.attachments)
        attachmentStrip.isHidden = session.attachments.isEmpty
        let status = session.composerError ?? (session.isImportingAttachments ? "Adding attachments…"
            : session.isPreparingPrompt ? "Preparing attachments…" : session.isChangingModel ? "Changing model…" : "")
        composerStatus.stringValue = status
        composerStatus.textColor = session.composerError == nil ? .secondaryLabelColor : .systemRed
        composerStatus.isHidden = status.isEmpty
        let running = session.phase == .starting || session.phase == .prompting
        if running { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        spinner.toolTip = session.phase == .starting ? "Starting \(session.agent.displayName)…" : "Working…"
        composer.isEditable = (session.phase == .ready || session.phase == .prompting) && !session.isPreparingPrompt
        if composer.isEditable, wantsComposerFocus, let window = view.window {
            wantsComposerFocus = false
            // A startup focus request may finish after the user focuses a
            // toolbar field. Only reclaim the neutral responder we left.
            if active, selected,
               window.firstResponder == nil || window.firstResponder === window || window.firstResponder === window.contentView {
                window.makeFirstResponder(composer)
            }
        }
        composer.setAccessibilityLabel("Message \(session.agent.displayName)")
        if composer.string != session.draft, !composer.hasMarkedText() {
            composer.string = session.draft
        }
        updateRunControls()
        let directory = session.workingDirectory.map { ($0 as NSString).lastPathComponent } ?? "this workspace"
        emptyPrompt.stringValue = "Ask \(session.agent.displayName) about \(directory)"
        emptyPrompt.isHidden = session.phase != .ready || !session.transcript.items.isEmpty
        updateComposerLayout()
        renderPhase()
        renderApproval(force: false)
        renderTimeline()
    }

    /// Stop, Steer / Queue, the composer chip, placeholders, and attachments.
    private func updateRunControls() {
        let turnRunning = session.isTurnRunning
        stopButton.isHidden = !(turnRunning || session.hasBackgroundAgents)
        stopButton.update(turnRunning: turnRunning)
        let hasDraft = !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let mode: AgentChatSendButton.Mode = !turnRunning ? .send : session.canSteer ? .steer : .queue
        let enabled = turnRunning ? hasDraft && session.pendingSteer == nil : session.canSend
        sendButton.update(mode: mode, enabled: enabled)
        composer.placeholder = !turnRunning ? "Ask anything"
            : session.canSteer ? "Steer the current run…" : "Queue a message for after this turn…"
        if let queued = session.queuedPrompt {
            composerChip.update(text: "Queued for next turn", detail: redactInline(String(queued.prefix(512))), removable: true)
            composerChip.isHidden = false
        } else if turnRunning, session.canSteer {
            composerChip.update(text: "Steering current run", detail: session.pendingSteer.map { redactInline(String($0.prefix(512))) },
                                removable: false)
            composerChip.isHidden = false
        } else {
            composerChip.isHidden = true
        }
        let steering = turnRunning && session.canSteer
        attachmentButton.isEnabled = !session.isImportingAttachments && !session.isPreparingPrompt && !steering
        attachmentButton.toolTip = steering ? "Attachments can't be sent while steering a running turn" : "Attach photos or videos"
    }

    private func renderTimeline() {
        let transcript = session.transcript
        let now = session.now()
        let repository = session.workingDirectory.map { ($0 as NSString).lastPathComponent }
        let starting = session.phase == .starting ? "Starting \(session.agent.displayName)…" : nil
        func project() -> [AgentTimelineRow] {
            var rows = AgentTimeline.project(
                items: transcript.items, isTurnRunning: session.isTurnRunning, acknowledgedSettles: timeline.acknowledgedSettles,
                now: now, isReplaying: transcript.isReplaying, stepInput: { transcript.stepDetails[$0]?.rawInput?.value },
                childStats: { transcript.stepStats(of: $0) }, repositoryName: repository
            )
            if let starting { rows.append(.notice(AgentChatItem(id: "starting", content: .notice(starting)))) }
            return rows
        }
        var rows = project()
        if timeline.acknowledgeSettles(in: rows) { rows = project() }
        timeline.streamingKey = session.isTurnRunning ? AgentChatTimelineTable.streamingProseKey(in: rows) : nil
        timeline.sendAgainNoticeKey = session.canSendAgain ? session.sendAgainNoticeKey : nil
        // A steer shows as a pending bubble until the agent answers, then as
        // the delivered user message marked "Sent to running turn" (§1.3).
        var captions: [String: String] = [:]
        for key in session.steeredItemKeys { captions[key] = "Sent to running turn" }
        if let pending = session.pendingSteer {
            let item = AgentChatItem(id: Self.pendingSteerID, content: .user(pending))
            rows.append(.user(item))
            captions[item.key] = "Sending to running turn…"
        }
        timeline.userCaptions = captions
        var groupWasShown = false
        if case .group(let id)? = inspector.subject { groupWasShown = timeline.rows.contains { $0.id == id } }
        timeline.applyRows(rows, now: now)
        guard inspector.isPresented, let subject = inspector.subject else { return }
        if case .group(let id) = subject, groupWasShown, !rows.contains(where: { $0.id == id }) {
            // A head trim re-keys a group whose first member was dropped; a
            // group that is gone entirely closes the drawer instead of blanking it.
            guard let renamed = timeline.renamedGroups[id] else { return inspector.dismiss() }
            inspector.present(AgentChatPaneContent.content(for: .group(id: renamed), session: session, rows: rows, now: now), tab: nil)
            return
        }
        inspector.update(AgentChatPaneContent.content(for: subject, session: session, rows: rows, now: now))
    }

    static let pendingSteerID = "pending-steer"

    private func renderPhase() {
        guard previousPhase != session.phase else { return }
        previousPhase = session.phase
        for stack in [setupStack, failureStack] {
            for child in stack.arrangedSubviews { stack.removeArrangedSubview(child); child.removeFromSuperview() }
        }
        setupStack.isHidden = true
        transcriptScroll.isHidden = false
        failureStack.isHidden = true
        switch session.phase {
        case .needsSetup(let issue):
            setupStack.isHidden = false
            transcriptScroll.isHidden = true
            setupStack.addArrangedSubview(label(issue.message, size: 13))
            if let command = issue.command {
                setupStack.addArrangedSubview(label(command, size: 12, monospaced: true))
                setupStack.addArrangedSubview(AgentChatActionButton(title: "Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                })
            }
            if issue != .noWorkingDirectory {
                setupStack.addArrangedSubview(AgentChatActionButton(title: "Try Again") { [weak self] in self?.session.restart() })
            }
        case .failed(let message):
            failureStack.isHidden = false
            let error = label(redactInline(message), size: 12)
            error.textColor = .systemRed
            failureStack.addArrangedSubview(error)
            failureStack.addArrangedSubview(AgentChatActionButton(title: "Restart") { [weak self] in self?.session.restart() })
        default: break
        }
    }

    /// The head of the permission queue, docked above the composer. It never
    /// takes focus by itself; decided records render in the timeline.
    private func renderApproval(force: Bool) {
        let request = session.pendingPermission
        let queued = session.permissionQueue.count
        guard force || previousPermission != request || previousQueuedPermissions != queued else { return }
        previousPermission = request
        previousQueuedPermissions = queued
        guard let request else {
            // A hidden card must not keep keyboard focus: hand it to the composer.
            if let window = view.window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: approvalCard) {
                if !focusComposer() { window.makeFirstResponder(nil) }
            }
            approvalCard.isHidden = true
            approvalHeight?.constant = 0
            return
        }
        let model = AgentChatPaneContent.approval(for: request, session: session)
        approvalCard.configure(
            approval: model.approval, verb: model.verb, moreCount: max(0, queued - 1),
            onChoose: { [weak self] option in self?.session.answerPermission(request, optionID: option) },
            onCancelRequest: { [weak self] in self?.session.dismissPermission(request) },
            unredactedInput: model.unredactedInput, maskedInput: model.maskedInput
        )
        let width = max(1, approvalCard.superview?.bounds.width ?? view.bounds.width - 24)
        approvalWidth = width
        approvalHeight?.constant = ApprovalCardView.height(approval: model.approval, verb: model.verb, width: width,
                                                           moreCount: max(0, queued - 1), unredactedInput: model.unredactedInput,
                                                           maskedInput: model.maskedInput)
        approvalCard.isHidden = false
    }

    // MARK: Inspector and keyboard

    func openInspector(_ subject: AgentInspectorSubject, tab: AgentInspectorTab?) {
        onSelect?()
        inspector.present(AgentChatPaneContent.content(for: subject, session: session, rows: timeline.rows, now: session.now()), tab: tab)
    }

    private func handleTableKey(_ key: AgentChatTimelineKey) -> Bool {
        switch key {
        case .next: return timeline.cursor.move(by: 1)
        case .previous: return timeline.cursor.move(by: -1)
        case .open:
            guard let subject = timeline.cursor.subject() else { return false }
            openInspector(subject, tab: nil)
            return true
        case .focusComposer: return focusComposer()
        case .escape: return handleEscape(fromComposer: false)
        case .stop: return stopTurn()
        }
    }

    /// Esc: close the Inspector; else, from an empty composer during a run,
    /// cancel the turn; else nothing.
    func handleEscape(fromComposer: Bool) -> Bool {
        if inspector.isPresented {
            inspector.dismiss()
            return true
        }
        guard fromComposer, session.isTurnRunning, composer.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        session.cancelTurn()
        renderAndObserve()
        return true
    }

    @discardableResult
    func stopTurn() -> Bool {
        guard session.isTurnRunning else { return false }
        session.cancelTurn()
        renderAndObserve()
        return true
    }

    @discardableResult
    func focusComposer() -> Bool {
        guard let window = view.window, composer.isEditable else { return false }
        return window.makeFirstResponder(composer)
    }

    @discardableResult
    func focusTranscript() -> Bool {
        guard let window = view.window, !transcriptScroll.isHidden, table.numberOfRows > 0 else { return false }
        return window.makeFirstResponder(table)
    }

    // MARK: Composer actions

    func textDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === composer else { return }
        session.draft = composer.string
        updateRunControls()
        updateComposerLayout()
        composer.needsDisplay = true
    }

    /// Return and the send button: send when idle; while a turn runs, steer
    /// where the agent supports it, otherwise queue for the next turn.
    private func sendDraft() {
        session.draft = composer.string
        if session.isTurnRunning {
            let text = session.draft
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if session.canSteer { session.steer(text) } else { session.queueForNextTurn(text) }
        } else {
            guard session.phase == .ready else { return }
            session.send()
        }
        renderAndObserve()
    }

    @objc private func sendClicked() { sendDraft() }
    @objc private func stopClicked() { stopTurn() }

    @objc private func changeAgent(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let agent = ChatAgent(rawValue: raw) else { return }
        session.switchAgent(to: agent)
        renderAndObserve()
    }

    @objc private func changeModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        session.selectModel(id)
        renderAndObserve()
    }

    @objc private func newConversation() { session.startNewConversation() }
    @objc private func restart() { session.restart() }

    @objc private func zoomChanged() {
        composer.font = CockpitTypography.font(size: 14)
        emptyPrompt.font = CockpitTypography.font(size: 17, weight: .medium)
        modelLabel.font = CockpitTypography.font(size: 11)
        agentMenu.font = CockpitTypography.font(size: 13, weight: .semibold)
        previousPhase = nil
        renderPhase()
        updateRunControls()
        renderApproval(force: true)
        timeline.reloadAll()
        updateComposerLayout()
    }

    func closePane() {
        guard !closed else { return }
        closed = true
        active = false
        observationGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        timeline.stop()
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
}
