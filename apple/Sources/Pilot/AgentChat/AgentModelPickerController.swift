import AppKit

/// Connects the composer's model trigger and picker popover to a session:
/// adapts the session's configuration, the cached catalog and favorites into
/// an `AgentModelPickerState`, and turns picker actions into session calls,
/// catalog writes and tab switches (see docs/agent-chat.md).
@MainActor
final class AgentModelPickerController: NSObject, NSPopoverDelegate {
    let session: AgentChatSession
    let trigger = AgentModelTriggerButton()
    private(set) var popover: NSPopover?
    private(set) var picker: AgentModelPickerViewController?
    /// The rail tab the open popover shows; reset to the running agent on open.
    private(set) var selectedTab: AgentModelPickerState.Tab.Kind = .favorites
    /// Runs after the popover closes with the main window's first responder
    /// from when it opened, so the pane can return focus to the composer.
    var onClose: (NSResponder?) -> Void = { _ in }
    /// Runs after an action changed the session, so the pane renders at once.
    var onChange: () -> Void = {}
    private weak var responderAtOpen: NSResponder?
    private var compact = false
    private var triggerSignature: [String]?
    enum DiscoveryStatus { case loading, failed(String) }
    private var discoveryStatus: [ChatAgent: DiscoveryStatus] = [:]
    private var discoveryTasks: [ChatAgent: Task<Void, Never>] = [:]
    private var discoveryGeneration = 0

    var catalog: AgentModelCatalog { AgentModelCatalog(defaults: session.defaults) }
    var isShown: Bool { popover?.isShown == true }

    init(session: AgentChatSession) {
        self.session = session
        super.init()
        trigger.target = self
        trigger.action = #selector(toggle)
        trigger.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    // MARK: - Rendering

    /// Updates the trigger and, when open, the popover. Called on every pane
    /// render, so it reads the session inside the pane's observation scope.
    func refresh(compact: Bool? = nil) {
        if let compact { self.compact = compact }
        let label = Self.triggerLabel(session.config)
        let signature = [session.agent.rawValue, label.model ?? "", label.reasoning ?? "", "\(self.compact)"]
        if signature != triggerSignature {
            triggerSignature = signature
            trigger.configure(agent: session.agent, modelName: label.model, reasoning: label.reasoning, compact: self.compact)
        }
        guard let picker, isShown else { return }
        picker.update(Self.state(session: session, catalog: catalog, selectedTab: selectedTab, discovery: discoveryStatus))
    }

    /// Re-measures the trigger for a new UI zoom.
    func zoomChanged() {
        triggerSignature = nil
        refresh()
    }

    /// "6.1 Sol" and "Low" for the trigger; no reasoning part without a thought-level option.
    static func triggerLabel(_ config: ACPSessionConfig?) -> (model: String?, reasoning: String?) {
        let model = config?.model.map(\.currentName)
        let reasoning = config?.thoughtLevel.map(\.currentDisplayName)
        return (model, reasoning)
    }

    // MARK: - Popover

    @objc func toggle() {
        if isShown { close() } else { show() }
    }

    func show() {
        guard trigger.window != nil, !isShown else { return }
        selectedTab = .agent(session.agent)
        let picker = AgentModelPickerViewController(
            state: Self.state(session: session, catalog: catalog, selectedTab: selectedTab),
            onAction: { [weak self] action in self?.handle(action) }
        )
        let popover = NSPopover()
        popover.behavior = .transient
        // The surface paints under the arrow too, so the chrome never shows
        // the lighter system material against the near-black body; content
        // stays inside the safe area (see `AgentModelPickerSurfaceView`).
        popover.hasFullSizeContent = true
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentViewController = picker
        popover.delegate = self
        self.picker = picker
        self.popover = popover
        responderAtOpen = trigger.window?.firstResponder
        // Above the trigger: `maxY` is the top edge only in unflipped coordinates.
        popover.show(relativeTo: trigger.bounds, of: trigger, preferredEdge: trigger.isFlipped ? .minY : .maxY)
        for agent in ChatAgent.allCases { discoverModels(for: agent) }
    }

    func close() {
        cancelDiscovery()
        popover?.close()
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === popover else { return }
        cancelDiscovery()
        popover = nil
        picker = nil
        onClose(responderAtOpen)
    }

    isolated deinit { for task in discoveryTasks.values { task.cancel() } }

    private func cancelDiscovery() {
        discoveryGeneration += 1
        for task in discoveryTasks.values { task.cancel() }
        discoveryTasks.removeAll()
        discoveryStatus.removeAll()
    }

    private func discoverModels(for agent: ChatAgent) {
        guard agent != session.agent, catalog.snapshot(for: agent) == nil, discoveryTasks[agent] == nil else { return }
        let generation = discoveryGeneration
        discoveryStatus[agent] = .loading
        discoveryTasks[agent] = Task { [weak self, session] in
            do {
                let config = try await session.discoverModels(for: agent)
                try Task.checkCancellation()
                guard let self, generation == discoveryGeneration else { return }
                // A live session may have supplied a newer list while loading.
                if catalog.snapshot(for: agent) == nil { catalog.record(config, for: agent) }
                discoveryStatus[agent] = nil
            } catch {
                guard !Task.isCancelled, let self, generation == discoveryGeneration else { return }
                if let issue = error as? ChatAgentSetupIssue {
                    discoveryStatus[agent] = .failed([issue.message, issue.command].compactMap { $0 }.joined(separator: " "))
                } else {
                    discoveryStatus[agent] = .failed(redactInline(error.localizedDescription))
                }
            }
            guard let self, generation == discoveryGeneration else { return }
            discoveryTasks[agent] = nil
            refresh()
        }
        refresh()
    }

    // MARK: - Actions

    func handle(_ action: AgentModelPickerAction) {
        switch action {
        case .selectTab(let kind):
            selectedTab = kind
            refresh()
            return
        case .toggleFavorite(let agent, let modelID):
            catalog.toggleFavorite(.init(agent: agent, modelID: modelID))
            refresh()
            return
        case .selectModel(let agent, let modelID):
            if modelID.isEmpty {
                // A failed discovery's row retries it without switching providers.
                if case .failed = discoveryStatus[agent] {
                    discoveryStatus[agent] = nil
                    discoverModels(for: agent)
                    return
                }
                // A running-agent placeholder ("Loading…") carries no model to
                // select; another provider's placeholder starts that provider.
                if agent == session.agent { return }
            }
            if agent != session.agent {
                session.selectModel(modelID, on: agent)
                close()
            } else {
                // Before the session is ready this replaces the pending model;
                // once ready, an unadvertised model is reported, not dropped.
                session.selectModel(modelID, on: agent)
                // Codex refreshes its reasoning levels per model, so the popover
                // stays open where a reasoning column follows the choice.
                let config = session.config
                if session.phase != .ready || config?.thoughtLevel == nil || config?.model?.choice(modelID) == nil { close() }
            }
        case .selectReasoning(let value):
            guard let option = session.config?.thoughtLevel else { return }
            session.selectConfigOption(option.id, value: value)
            close()
        case .setFast(let on):
            guard let option = session.config?.fast else { return }
            session.selectConfigOption(option.id, value: on ? "on" : "off")
        case .selectMode(let value):
            guard let option = session.config?.mode else { return }
            // Unrestricted modes wait for the confirmation sheet, which a
            // transient popover would not survive.
            if let choice = option.choice(value), ACPConfigOption.isUnrestrictedMode(choice) { close() }
            session.selectConfigOption(option.id, value: value)
        case .dismiss:
            close()
            return
        }
        onChange()
    }

    // MARK: - State

    /// Tooltip on a running-agent row the live session does not advertise.
    static let notOfferedReason = "Not offered by the running session"

    /// The picker's values for `selectedTab`. The running agent's tab lists
    /// the models its session advertises; other providers list their cached
    /// catalog, loading status, or a retry row. Reasoning and the footer belong
    /// to the running session and show only on its tab. A row of the running
    /// agent is enabled only while the session can change models and
    /// advertises that model, on every tab, so no click is silently dropped.
    static func state(session: AgentChatSession, catalog: AgentModelCatalog,
                      selectedTab: AgentModelPickerState.Tab.Kind,
                      discovery: [ChatAgent: DiscoveryStatus] = [:]) -> AgentModelPickerState {
        let running = session.agent
        let config = session.config
        let favorites = Set(catalog.favorites())
        let currentModelID = config?.model?.currentID
        let canEdit = session.phase == .ready && !session.isChangingModel && !session.isPreparingPrompt
        let liveModel = config?.model.flatMap { $0.choices.isEmpty ? nil : $0 }
        let tabs = [AgentModelPickerState.Tab(kind: .favorites, title: "Favorites")]
            + ChatAgent.allCases.map { AgentModelPickerState.Tab(kind: .agent($0), title: $0.displayName) }
        func row(_ agent: ChatAgent, _ id: String, _ name: String, _ detail: String?, _ group: String?) -> AgentModelPickerState.Row {
            var row = AgentModelPickerState.Row(agent: agent, modelID: id, name: name, detail: detail, group: group,
                                                isCurrent: agent == running && id == currentModelID,
                                                isFavorite: favorites.contains(.init(agent: agent, modelID: id)), isPlaceholder: false)
            if agent == running {
                let offered = liveModel?.choice(id) != nil
                row.isEnabled = canEdit && offered
                row.disabledReason = offered ? nil : notOfferedReason
            }
            return row
        }
        var state = AgentModelPickerState(tabs: tabs, selectedTab: selectedTab, rows: [], reasoningTitle: nil, reasoning: [],
                                          fast: nil, modeName: nil, modeChoices: [], modeIsUnrestricted: false,
                                          isEditable: true)
        switch selectedTab {
        case .favorites:
            state.rows = catalog.favoriteEntries().map { row($0.favorite.agent, $0.favorite.modelID, $0.name, $0.detail, nil) }
        case .agent(let agent) where agent == running:
            state.isEditable = canEdit
            if let model = config?.model, !model.choices.isEmpty {
                state.rows = model.choices.map { row(agent, $0.id, $0.name, $0.detail, $0.group) }
            } else if let snapshot = catalog.snapshot(for: agent) {
                state.rows = snapshot.models.map { row(agent, $0.id, $0.name, $0.detail, $0.group) }
            } else {
                // Never a bare "No models": say why the list is empty.
                var placeholder = AgentModelPickerState.Row(agent: agent, modelID: "", name: runningPlaceholder(session),
                                                            detail: nil, group: nil, isCurrent: false, isFavorite: false,
                                                            isPlaceholder: true)
                placeholder.isEnabled = false
                state.rows = [placeholder]
            }
            if let level = config?.thoughtLevel, !level.choices.isEmpty {
                state.reasoningTitle = config?.model?.currentName ?? level.name
                state.reasoning = level.choices.map {
                    .init(id: $0.id, name: level.displayName(of: $0), detail: $0.detail, isCurrent: $0.id == level.currentID,
                          isUnrestricted: false)
                }
            }
            state.fast = config?.fast.map { $0.currentID == "on" }
            if let mode = config?.mode, !mode.choices.isEmpty {
                state.modeName = mode.currentDisplayName
                state.modeChoices = mode.choices.map {
                    .init(id: $0.id, name: mode.displayName(of: $0), detail: $0.detail, isCurrent: $0.id == mode.currentID,
                          isUnrestricted: ACPConfigOption.isUnrestrictedMode($0))
                }
                // An unlisted current mode is classified by its ID and shown as reported.
                state.modeIsUnrestricted = ACPConfigOption.isUnrestrictedMode(mode.currentOrUnlistedChoice)
            }
        case .agent(let agent):
            if let snapshot = catalog.snapshot(for: agent) {
                state.rows = snapshot.models.map { row(agent, $0.id, $0.name, $0.detail, $0.group) }
            } else {
                var placeholder = AgentModelPickerState.Row(agent: agent, modelID: "", name: "Loading \(agent.displayName) models…",
                                                            detail: nil, group: nil, isCurrent: false, isFavorite: false,
                                                            isPlaceholder: true, isEnabled: false)
                if case .failed(let message) = discovery[agent] {
                    placeholder.name = "Retry loading \(agent.displayName) models"
                    placeholder.detail = message
                    placeholder.isEnabled = true
                }
                state.rows = [placeholder]
            }
        }
        return state
    }

    /// The running agent's tab when neither its session nor the catalog has
    /// listed models: loading while it starts, a start hint while stopped.
    static func runningPlaceholder(_ session: AgentChatSession) -> String {
        let name = session.agent.displayName
        switch session.phase {
        case .starting: return "Loading \(name) models…"
        case .ready, .prompting: return "\(name) did not list any models"
        case .idle, .needsSetup, .failed: return "Start \(name) to see its models"
        }
    }
}

// MARK: - Unrestricted mode confirmation

@MainActor
enum AgentUnrestrictedModeAlert {
    /// Asks on `window`'s sheet whether `agent` may switch to an unrestricted
    /// mode. Cancel is the default button; no window means no.
    static func confirm(agent: ChatAgent, choice: ACPConfigOption.Choice, window: NSWindow?) async -> Bool {
        guard let window else { return false }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Allow \(agent.displayName) to run without asking?"
        alert.informativeText = [choice.name, choice.detail].compactMap { $0 }.joined(separator: ": ")
            + "\n\n\(agent.displayName) will run commands and edit files without asking for approval."
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        let allow = alert.addButton(withTitle: "Allow")
        allow.keyEquivalent = ""
        allow.hasDestructiveAction = true
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertSecondButtonReturn)
            }
        }
    }
}

// MARK: - Auto-approve confirmation

@MainActor
enum AgentAutoApproveAlert {
    nonisolated static func messageText(agent: ChatAgent) -> String {
        "Approve \(agent.displayName) requests automatically?"
    }

    nonisolated static func informativeText(agent: ChatAgent) -> String {
        "For the rest of this session, \(agent.displayName) will run commands and edit files without asking. "
            + "Each request is approved once; nothing is remembered after the session ends."
    }

    /// Asks on `window`'s sheet whether the session's permission requests may
    /// be approved automatically. Cancel is the default button; no window
    /// means no.
    static func confirm(agent: ChatAgent, window: NSWindow?) async -> Bool {
        guard let window else { return false }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = messageText(agent: agent)
        alert.informativeText = informativeText(agent: agent)
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        let allow = alert.addButton(withTitle: "Auto-approve")
        allow.keyEquivalent = ""
        allow.hasDestructiveAction = true
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertSecondButtonReturn)
            }
        }
    }
}
