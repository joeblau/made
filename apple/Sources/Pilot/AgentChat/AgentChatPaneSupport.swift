import AppKit
import Observation

// MARK: - Inspector content and docked approvals

/// Gathers what the Inspector and the docked approval card show from the
/// session; every string is redacted later by the sink.
@MainActor
enum AgentChatPaneContent {
    static func item(forKey key: String, in transcript: AgentTranscript) -> AgentChatItem? {
        if key.hasPrefix(AgentTranscript.rootKey + "/"), let found = transcript.items.first(where: { $0.key == key }) { return found }
        for (child, list) in transcript.childItems where key.hasPrefix(child + "/") {
            if let found = list.first(where: { $0.key == key }) { return found }
        }
        return nil
    }

    static func subagentItem(_ childSessionID: String, in transcript: AgentTranscript) -> AgentChatItem? {
        func matches(_ item: AgentChatItem) -> Bool {
            if case .subagent(let card) = item.content { card.childSessionID == childSessionID } else { false }
        }
        if let found = transcript.items.first(where: matches) { return found }
        for list in transcript.childItems.values { if let found = list.first(where: matches) { return found } }
        return nil
    }

    static func toolItem(callID: String, in transcript: AgentTranscript) -> AgentChatItem? {
        func matches(_ item: AgentChatItem) -> Bool {
            if case .tool(let tool) = item.content { tool.toolCallID == callID } else { false }
        }
        if let found = transcript.items.last(where: matches) { return found }
        for list in transcript.childItems.values { if let found = list.last(where: matches) { return found } }
        return nil
    }

    static func content(for subject: AgentInspectorSubject, session: AgentChatSession, rows: [AgentTimelineRow],
                        now: Date) -> AgentInspectorContent {
        let transcript = session.transcript
        var content = AgentInspectorContent(subject: subject, title: "", agentName: session.agent.displayName)
        switch subject {
        case .step(let key), .thought(let key), .plan(let key):
            let item = item(forKey: key, in: transcript)
            if case .plan = subject {} else { content.model = session.modelName }
            content.item = item
            content.detail = transcript.stepDetails[key]
            switch item?.content {
            // Labels only: the title never needs the redacted exact input,
            // and this runs on every render while the Inspector is open.
            case .tool(let tool)?:
                content.title = verbForTool(tool, input: content.detail?.rawInput?.value, includeExactInput: false).settled
            case .thought(let thought)?: content.title = verbForThought(thought, now: now).settled
            case .plan?: content.title = "Plan"
            default: content.title = "Step"
            }
        case .agent(let child):
            let card = subagentItem(child, in: transcript)
            content.item = card
            let children = transcript.children(of: child)
            if case .subagent(let agent)? = card?.content {
                content.title = agent.title
                content.model = agent.model
            } else {
                content.title = AgentChatSession.untrackedSubagentName
            }
            content.group = childGroup(children, transcript: transcript, now: now)
            content.finalProse = children.reversed().lazy.compactMap { item -> String? in
                if case .assistant(let text) = item.content { text } else { nil }
            }.first
        case .group(let id):
            for case .activity(let group) in rows where group.id == id {
                content.group = group
                content.title = group.summary
            }
            content.model = session.modelName
        case .run:
            content.title = "Run"
            content.model = session.modelName
            content.turnUsage = session.lastTurnUsage
            content.context = session.context
        }
        return content
    }

    /// The child's own steps as one nested card (settled once nothing runs).
    private static func childGroup(_ children: [AgentChatItem], transcript: AgentTranscript, now: Date) -> AgentActivityGroup? {
        let work = children.filter { item in
            switch item.content {
            case .tool, .thought, .subagent: true
            default: false
            }
        }
        let running = work.contains { item in
            switch item.content {
            case .tool(let tool): tool.isRunning
            case .thought(let thought): thought.endedAt == nil && thought.startedAt != nil
            default: false
            }
        }
        let rows = AgentTimeline.project(items: work, isTurnRunning: running, acknowledgedSettles: [], now: now,
                                         stepInput: { transcript.stepDetails[$0]?.rawInput?.value },
                                         childStats: { transcript.stepStats(of: $0) })
        for case .activity(var group) in rows {
            if group.state == .settling { group.state = .settled }
            return group
        }
        return nil
    }

    /// The pending record for `request` (with the requesting agent's name),
    /// its verb, the raw input "Reveal secrets" may show, and, when the
    /// request touches a secret file, the input with that content masked.
    static func approval(for request: ACPPermissionRequest, session: AgentChatSession)
        -> (approval: AgentChatItem.Approval, verb: AgentToolVerb, unredactedInput: String?, maskedInput: String?) {
        let transcript = session.transcript
        var approval = AgentChatItem.Approval(request, agentName: session.agent.displayName)
        for item in transcript.items.reversed() {
            if case .approval(let record) = item.content, record.decision == .pending,
               record.requestID == request.requestID, record.sessionID == request.sessionID {
                approval = record
                break
            }
        }
        var tool = AgentChatItem.ToolCall(title: request.title, kind: request.toolKind, status: .pending, content: "")
        var input = request.rawInput?.value
        if let callID = request.toolCallID, let step = toolItem(callID: callID, in: transcript), case .tool(let found) = step.content {
            tool = found
            input = input ?? transcript.stepDetails[step.key]?.rawInput?.value
        }
        // Only a payload that masking changes gets a masked view: a command is never masked.
        // (`JSONValue` takes `nil` as `.null`, so the optionals are spelled out.)
        var maskedInput: String?
        if let input, agentStepTouchesSecretFile(tool, input: input) {
            let masked = maskSecretFileContent(input)
            if masked != input { maskedInput = rawText(masked) }
        }
        return (approval, verbForTool(tool, input: input), input.map(rawText), maskedInput)
    }

    /// The verb of the step an approval record asked about (labels only).
    static func recordVerb(for approval: AgentChatItem.Approval, in transcript: AgentTranscript) -> AgentToolVerb? {
        guard let callID = approval.toolCallID, let step = toolItem(callID: callID, in: transcript),
              case .tool(let tool) = step.content else { return nil }
        return verbForTool(tool, input: transcript.stepDetails[step.key]?.rawInput?.value, includeExactInput: false)
    }

    /// The command itself when the input names one, else the JSON input.
    /// A margin past the card's limit: the card redacts before it clips.
    private static func rawText(_ input: JSONValue) -> String {
        let limit = ApprovalCardView.redactedInputCharacters
        for field in ["command", "cmd"] {
            if let command = input[field]?.stringValue { return String(command.prefix(limit)) }
            if let argv = input[field]?.arrayValue {
                return String(argv.compactMap(\.stringValue).joined(separator: " ").prefix(limit))
            }
        }
        return String(AgentRunTrace.prettyText(input).prefix(limit))
    }
}

// MARK: - Conversation menu

/// The composer's Conversation menu (the ⋯ button left of the model
/// trigger). It ends with the context meter ("Context 58.1k / 258.4k ·
/// Cache 97%") as a disabled item; the meter is not shown in the composer.
/// Models and providers live in the model picker popover.
@MainActor
enum AgentChatAgentMenu {
    struct Actions {
        var newConversation: Selector
        var restart: Selector
    }

    static let contextItemIdentifier = NSUserInterfaceItemIdentifier("agent-chat.context")

    static func conversationMenu(info: String?, target: AnyObject, actions: Actions) -> NSMenu {
        let menu = NSMenu(title: "Conversation")
        menu.autoenablesItems = false
        for (title, action) in [("New Conversation", actions.newConversation), ("Restart Agent", actions.restart)] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            menu.addItem(item)
        }
        if let info {
            menu.addItem(.separator())
            let item = NSMenuItem(title: info, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.identifier = contextItemIdentifier
            menu.addItem(item)
        }
        return menu
    }
}

/// The borderless ⋯ button that opens the Conversation menu above itself.
@MainActor
final class AgentChatConversationMenuButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = .secondaryLabelColor
        target = self
        action = #selector(showMenu)
        toolTip = "Conversation"
        setAccessibilityLabel("Conversation")
        setAccessibilityIdentifier("agent-chat.conversation-menu")
    }

    required init?(coder: NSCoder) { nil }

    @objc private func showMenu() {
        menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.height + 4 : -4), in: self)
    }
}

// MARK: - Controls

@MainActor
final class AgentChatActionButton: NSButton {
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

/// The pane's root: thread background, and Cmd-. for the focused pane.
@MainActor
final class AgentChatBackgroundView: NSView {
    /// Returns true when Cmd-. stopped something.
    var onStopShortcut: () -> Bool = { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateBackground()
    }

    required init?(coder: NSCoder) { nil }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Only the pane holding focus answers, so split chats never stop each other.
        if AgentChatTimelineKey(event) == .stop, let responder = window?.firstResponder as? NSView,
           responder.isDescendant(of: self), onStopShortcut() {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

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

    /// "Context 58.1k / 258.4k · Cache 97%" for the Conversation menu, or nil when
    /// the agent reported neither.
    static func contextSummary(_ context: ACPContextUsage?, usage: NormalizedTurnUsage?) -> String? {
        var parts: [String] = []
        if let context { parts.append("Context \(tokens(context.usedTokens)) / \(tokens(context.windowTokens))") }
        if let rate = usage?.cacheHitRate { parts.append("Cache \(percent(rate))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
