import AppKit
import Testing
@testable import Pilot

/// The model picker inside a live pane, against shell agents that answer
/// `session/new` with the probe fixtures and log every later request.
@Suite("Agent model picker integration")
@MainActor
struct AgentModelPickerIntegrationTests {
    struct Label: Sendable, CustomTestStringConvertible {
        var agent: ChatAgent
        var model: String
        var reasoning: String?
        var testDescription: String { agent.rawValue }
    }

    nonisolated static let labels: [Label] = [
        Label(agent: .claude, model: "Opus 5.5", reasoning: "High"),
        Label(agent: .codex, model: "6 Astra", reasoning: "Extra High"),
        Label(agent: .kimi, model: "K3.1 Pro Highspeed 2x Usage Cost", reasoning: "High"),
        Label(agent: .grok, model: "Grok 4.7 Fast", reasoning: "Medium"),
        Label(agent: .cursor, model: "grok-4.7", reasoning: nil),
    ]

    @Test("The trigger reads `{model} {reasoning}` for each agent, and session/new fills the catalog", arguments: labels)
    func triggerLabelAndCatalog(_ expected: Label) async throws {
        let label = AgentModelPickerController.triggerLabel(ACPSessionConfig(try ACPProbeFixtures.result(expected.agent)))
        #expect(label.model == expected.model && label.reasoning == expected.reasoning)

        let harness = try Harness(expected.agent)
        defer { harness.close() }
        try await harness.waitUntil { harness.session.phase == .ready }
        let trigger = harness.controller.modelPicker.trigger
        #expect(trigger.accessibilityIdentifier() == "agent-chat.agent")
        #expect(trigger.accessibilityLabel() == "Model and provider")
        #expect(trigger.agent == expected.agent)
        let text = [expected.model, expected.reasoning].compactMap { $0 }.joined(separator: " ")
        try await harness.waitUntil { trigger.label.stringValue == text }
        let snapshot = try #require(AgentModelCatalog(defaults: harness.defaults).snapshot(for: expected.agent))
        #expect(snapshot.models.count == harness.session.config?.model?.choices.count)
        #expect(snapshot.currentModelID == harness.session.config?.model?.currentID)
    }

    @Test("The trigger opens the picker on the running agent; Esc closes it and returns focus to the composer")
    func popoverOpensAndCloses() async throws {
        let harness = try Harness(.codex)
        defer { harness.close() }
        try await harness.waitUntil { harness.session.phase == .ready }
        harness.layout()
        let picker = harness.controller.modelPicker
        harness.window.makeFirstResponder(nil)
        picker.trigger.performClick(nil)
        #expect(picker.isShown)
        let view = try #require(picker.picker)
        #expect(view.state.selectedTab == .agent(.codex))
        #expect(view.state.rows.map(\.modelID).prefix(2) == ["gpt-6.1-sol", "gpt-6-astra"])
        #expect(view.state.rows.filter(\.isCurrent).map(\.modelID) == ["gpt-6-astra"])
        #expect(view.state.reasoningTitle == "6 Astra")
        #expect(view.state.reasoning.first { $0.isCurrent }?.name == "Extra High")
        #expect(view.state.fast == false && view.state.modeName == "Auto review" && !view.state.modeIsUnrestricted)
        #expect(view.state.isEditable && view.isFooterVisible && view.isReasoningVisible)
        #expect(view.visibleRows.count == AgentModelPickerMetrics.collapsedRowCount && view.keycapCount == 4)

        // A refresh while open keeps the search text.
        view.searchField.stringValue = "sol"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: view.searchField))
        harness.controller.modelPicker.handle(.selectTab(.agent(.claude)))
        #expect(view.state.selectedTab == .agent(.claude) && view.state.rows.first?.isPlaceholder == true)
        #expect(view.state.reasoningTitle == nil && view.state.modeName == nil, "Reasoning and the footer belong to the running tab")
        harness.controller.modelPicker.handle(.selectTab(.agent(.codex)))
        harness.controller.modelPicker.refresh()
        #expect(view.searchField.stringValue == "sol")
        #expect(view.visibleRows.map(\.modelID) == ["gpt-6.1-sol", "gpt-6-sol", "gpt-5.6-sol"])

        view.view.cancelOperation(nil)
        try await harness.waitUntil { !picker.isShown && picker.picker == nil }
        // AppKit may reassign first responder as the parent window becomes key
        // again; the pane re-asserts composer focus on the next turn.
        try await harness.waitUntil { harness.window.firstResponder === harness.composer }
        #expect(harness.window.firstResponder === harness.composer, "Closing the picker returns focus to the composer")
    }

    @Test("Model, ⌘1, reasoning, Fast and mode choices send set_config_option and show once acknowledged")
    func selectionsSendTheirRequests() async throws {
        let harness = try Harness(.codex)
        defer { harness.close() }
        let codex = try ACPProbeFixtures.result(.codex)
        try harness.files.reply(.codex, 1, options(codex, current: ["model": "gpt-6-luna"]))
        try harness.files.reply(.codex, 2, options(codex, current: ["model": "gpt-6.1-sol"]))
        try harness.files.reply(.codex, 3, options(codex, current: ["model": "gpt-6.1-sol", "reasoning_effort": "low"]))
        try harness.files.reply(.codex, 4, options(codex, current: ["model": "gpt-6.1-sol", "reasoning_effort": "low",
                                                                    "fast-mode": "on"]))
        try harness.files.reply(.codex, 5, options(codex, current: ["model": "gpt-6.1-sol", "reasoning_effort": "low",
                                                                    "fast-mode": "on", "mode": "read-only"]))
        try await harness.waitUntil { harness.session.phase == .ready }
        harness.layout()
        let picker = harness.controller.modelPicker
        picker.show()
        let view = try #require(picker.picker)

        // A row click keeps the popover open: Codex's reasoning column follows the model.
        view.expand()
        let luna = try #require(view.visibleRows.firstIndex { $0.modelID == "gpt-6-luna" })
        view.select(rowAt: luna)
        try await harness.waitUntil { harness.session.modelName == "6 Luna" && !harness.session.isChangingModel }
        #expect(try harness.requests(.codex).last == ["configId": "model", "value": "gpt-6-luna"])
        try await harness.waitUntil { picker.trigger.label.stringValue == "6 Luna Extra High" }
        #expect(picker.isShown && view.state.rows.first { $0.isCurrent }?.modelID == "gpt-6-luna")

        // ⌘1 picks the first visible row.
        #expect(view.view.performKeyEquivalent(with: try key(18, "1", flags: .command)))
        try await harness.waitUntil { harness.session.modelName == "6.1 Sol" && !harness.session.isChangingModel }
        #expect(try harness.requests(.codex).last == ["configId": "model", "value": "gpt-6.1-sol"])

        picker.handle(.selectReasoning("low"))
        try await harness.waitUntil { harness.session.config?.thoughtLevel?.currentID == "low" && !harness.session.isChangingModel }
        #expect(try harness.requests(.codex).last == ["configId": "reasoning_effort", "value": "low"])
        try await harness.waitUntil { !picker.isShown }
        try await harness.waitUntil { picker.trigger.label.stringValue == "6.1 Sol Low" }

        picker.show()
        picker.handle(.setFast(true))
        try await harness.waitUntil { harness.session.config?.fast?.currentID == "on" && !harness.session.isChangingModel }
        #expect(try harness.requests(.codex).last == ["configId": "fast-mode", "value": "on"])
        try await harness.waitUntil { picker.picker?.state.fast == true }

        picker.handle(.selectMode("read-only"))
        try await harness.waitUntil { harness.session.config?.mode?.currentID == "read-only" && !harness.session.isChangingModel }
        #expect(try harness.requests(.codex).last == ["configId": "mode", "value": "read-only"])
        try await harness.waitUntil { picker.picker?.state.modeName == "Read-only" }
        #expect(try harness.requests(.codex).count == 5)
    }

    @Test("An unrestricted mode asks first: Cancel sends nothing, Allow sends the change")
    func unrestrictedModeNeedsConfirmation() async throws {
        let harness = try Harness(.codex)
        defer { harness.close() }
        let codex = try ACPProbeFixtures.result(.codex)
        try harness.files.reply(.codex, 1, options(codex, current: ["mode": "agent-full-access"]))
        try await harness.waitUntil { harness.session.phase == .ready }
        harness.layout()
        let prompt = ConfirmationPrompt()
        harness.controller.confirmUnrestrictedMode = { agent, choice in
            prompt.asked.append("\(agent.rawValue):\(choice.id)")
            return prompt.allow
        }
        let picker = harness.controller.modelPicker
        picker.show()
        picker.handle(.selectMode("agent-full-access"))
        try await harness.waitUntil { !picker.isShown }
        try await harness.waitUntil { prompt.asked.count == 1 && !harness.session.isChangingModel }
        #expect(prompt.asked == ["codex:agent-full-access"])
        #expect(harness.session.config?.mode?.currentID == "agent")
        try await Task.sleep(for: .milliseconds(100))
        #expect(try harness.requests(.codex).isEmpty, "A cancelled confirmation sends nothing")

        prompt.allow = true
        picker.handle(.selectMode("agent-full-access"))
        try await harness.waitUntil { harness.session.config?.mode?.currentID == "agent-full-access" }
        #expect(try harness.requests(.codex) == [["configId": "mode", "value": "agent-full-access"]])
        #expect(prompt.asked.count == 2)
    }

    @Test("A cached model on another provider switches agent and is selected once that agent is ready")
    func crossProviderSelection() async throws {
        let harness = try Harness(.claude)
        defer { harness.close() }
        let codex = try ACPProbeFixtures.result(.codex)
        try #require(AgentModelCatalog(defaults: harness.defaults).record(try #require(ACPSessionConfig(codex)), for: .codex))
        try harness.files.reply(.codex, 1, options(codex, current: ["model": "gpt-6-luna"]))
        try await harness.waitUntil { harness.session.phase == .ready }
        harness.layout()
        let picker = harness.controller.modelPicker
        picker.show()
        let view = try #require(picker.picker)
        picker.handle(.selectTab(.agent(.codex)))
        #expect(view.state.rows.count == 8 && !view.state.rows.contains(where: \.isCurrent))
        #expect(view.state.isEditable && view.state.reasoningTitle == nil)
        picker.handle(.toggleFavorite(agent: .codex, modelID: "gpt-6-luna"))
        #expect(view.state.rows.first { $0.modelID == "gpt-6-luna" }?.isFavorite == true)
        picker.handle(.selectTab(.favorites))
        #expect(view.state.rows.map(\.name) == ["6 Luna"] && view.state.rows.first?.agent == .codex)

        view.select(rowAt: 0)
        #expect(harness.session.agent == .codex)
        try await harness.waitUntil { !picker.isShown }
        try await harness.waitUntil { harness.session.modelName == "6 Luna" && !harness.session.isChangingModel }
        #expect(try harness.requests(.codex) == [["configId": "model", "value": "gpt-6-luna"]])
        try await harness.waitUntil { picker.trigger.agent == .codex && picker.trigger.label.stringValue == "6 Luna Extra High" }
    }

    @Test("A running-agent model is enabled only while the session can select it, on every tab")
    func runningAgentRowsMatchWhatTheSessionCanSelect() async throws {
        let harness = try Harness(.codex)
        defer { harness.close() }
        let catalog = AgentModelCatalog(defaults: harness.defaults)
        try #require(catalog.record(try #require(ACPSessionConfig(ACPProbeFixtures.result(.claude))), for: .claude))
        try await harness.waitUntil { harness.session.phase == .ready }
        harness.layout()
        catalog.addFavorite(.init(agent: .codex, modelID: "gpt-6-luna"))
        catalog.addFavorite(.init(agent: .claude, modelID: "opus"))
        let picker = harness.controller.modelPicker
        picker.show()
        let view = try #require(picker.picker)
        picker.handle(.selectTab(.favorites))
        #expect(view.state.rows.map(\.isEnabled) == [true, true])

        // Mid-change (or mid-turn), the running agent's favorite is disabled; another provider's is not.
        harness.session.changingConfigOptionID = "mode"
        picker.refresh()
        #expect(view.state.rows.map(\.isEnabled) == [false, true])
        #expect(view.rowViews[0].alphaValue < 1 && view.rowViews[1].alphaValue == 1)
        view.select(rowAt: 0)
        #expect(view.handleKeyEquivalent(try key(18, "1", flags: .command)))
        harness.session.changingConfigOptionID = nil

        // Live config without model choices: the cached rows are shown but inert, with a reason.
        let live = try #require(harness.session.config)
        var bare = live
        bare.legacyModels = nil
        let modelIndex = try #require(bare.options.firstIndex { $0.category == .model })
        bare.options[modelIndex].choices = []
        harness.session.config = bare
        picker.handle(.selectTab(.agent(.codex)))
        #expect(view.state.isEditable && view.state.rows.count == 8)
        #expect(view.state.rows.allSatisfy { !$0.isEnabled && $0.disabledReason == AgentModelPickerController.notOfferedReason })
        #expect(view.rowViews.first?.toolTip == AgentModelPickerController.notOfferedReason)
        #expect(view.handleKeyEquivalent(try key(18, "1", flags: .command)))
        picker.handle(.selectTab(.favorites))
        #expect(view.state.rows.map(\.isEnabled) == [false, true])
        // A selection that still arrives is reported rather than dropped.
        picker.handle(.selectModel(agent: .codex, modelID: "gpt-6-luna"))
        #expect(harness.session.composerError == "Codex no longer offers the selected model.")
        try await harness.waitUntil { !picker.isShown }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try harness.requests(.codex).isEmpty, "Disabled rows send nothing")

        // An unlisted current mode is classified by its reported ID and shown sanitized.
        harness.session.config = live.settingCurrent(optionID: "mode", to: "yo\u{202E}lo")
        picker.show()
        let reopened = try #require(picker.picker)
        #expect(reopened.state.modeName == "yolo" && reopened.state.modeIsUnrestricted)
        #expect(reopened.modeButton.isUnrestricted)
    }

    @Test("The popover paints under its arrow and keeps the content inside the chrome's safe area")
    func popoverUsesFullSizeContent() async throws {
        let harness = try Harness(.codex)
        defer { harness.close() }
        try await harness.waitUntil { harness.session.phase == .ready }
        harness.layout()
        let picker = harness.controller.modelPicker
        picker.show()
        let popover = try #require(picker.popover)
        let view = try #require(picker.picker)
        #expect(popover.hasFullSizeContent)
        view.view.layoutSubtreeIfNeeded()
        let insets = view.view.safeAreaInsets
        #expect(view.root.frame == view.view.safeAreaRect)
        #expect(view.preferredContentSize.width == view.metrics.width + insets.left + insets.right)
        #expect(view.preferredContentSize.height == view.metrics.height(footer: true) + insets.top + insets.bottom)
        picker.close()
    }

    // MARK: Helpers

    @MainActor
    private final class ConfirmationPrompt {
        var asked: [String] = []
        var allow = false
    }

    private func options(_ result: JSONValue, current: [String: String]) -> JSONValue {
        let list = (result["configOptions"]?.arrayValue ?? []).map { option -> JSONValue in
            guard case .object(var fields) = option, let id = option["id"]?.stringValue, let value = current[id] else { return option }
            fields["currentValue"] = .string(value)
            return .object(fields)
        }
        return ["configOptions": .array(list)]
    }

    private func key(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                      context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: code))
    }
}

/// Shell agents: each answers initialize and session/new with its probe
/// fixture, then logs every request and answers request N of an agent with
/// `<agent>-N.json` when the test wrote one (else an empty result).
private struct PickerAgentFiles {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AgentModelPicker-\(UUID())")

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func reply(_ agent: ChatAgent, _ number: Int, _ value: JSONValue) throws {
        try value.serialized().write(to: directory.appendingPathComponent("\(agent.rawValue)-\(number).json"))
    }

    func launch(_ agent: ChatAgent) throws -> ACPConnection.LaunchConfiguration {
        try ACPProbeFixtures.result(agent).serialized().write(to: directory.appendingPathComponent("\(agent.rawValue)-new.json"))
        let script = #"""
        reply() { printf '{"jsonrpc":"2.0","id":%s,"result":' "$1"; cat "$DIR/$2.json"; printf '}\n'; }
        read -r _
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":false}}}'
        read -r _
        reply 2 AGENT-new
        n=0
        while read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
          [ -z "$id" ] && continue
          printf '%s\n' "$line" >> "$DIR/AGENT.log"
          n=$((n+1))
          if [ -f "$DIR/AGENT-$n.json" ]; then reply "$id" "AGENT-$n"; else printf '{"jsonrpc":"2.0","id":%s,"result":{}}\n' "$id"; fi
        done
        """#.replacingOccurrences(of: "AGENT", with: agent.rawValue)
        return ACPConnection.LaunchConfiguration(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
            environment: ["DIR": directory.path, "PATH": "/usr/bin:/bin"], currentDirectory: directory
        )
    }

    /// `{configId, value}` of each `session/set_config_option` the agent received.
    func requests(_ agent: ChatAgent) throws -> [[String: String]] {
        let url = directory.appendingPathComponent("\(agent.rawValue).log")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return try text.split(separator: "\n").compactMap { line in
            let message = try JSONValue.parse(Data(line.utf8))
            guard message["method"]?.stringValue == ACP.Method.setConfigOption, let params = message["params"] else { return nil }
            return ["configId": params["configId"]?.stringValue ?? "", "value": params["value"]?.stringValue ?? ""]
        }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// A pane on a scripted agent in an offscreen window.
@MainActor
private struct Harness {
    let session: AgentChatSession
    let controller: AgentChatPaneViewController
    let window: NSWindow
    let composer: AgentChatComposerTextView
    let defaults: UserDefaults
    let files: PickerAgentFiles
    private let suite: String

    init(_ agent: ChatAgent) throws {
        suite = "AgentModelPickerIntegrationTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        files = try PickerAgentFiles()
        var launches: [ChatAgent: ACPConnection.LaunchConfiguration] = [:]
        for agent in ChatAgent.allCases { launches[agent] = try files.launch(agent) }
        let pane = Pane(kind: .agentChat)
        session = AgentChatSession(paneID: pane.id, agent: agent, workingDirectory: NSTemporaryDirectory(), defaults: defaults,
                                   resolveLaunch: { [launches] agent, _ in
                                       launches[agent].map { .success($0) } ?? .failure(.noWorkingDirectory)
                                   })
        controller = AgentChatPaneViewController(pane: pane, session: session)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 720), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 720, height: 720))
        // A popover needs an on-screen positioning view.
        window.orderFront(nil)
        controller.updatePresentation(isActive: true, isSelected: true)
        composer = try #require(Self.descendants(of: controller.view).compactMap { $0 as? AgentChatComposerTextView }.first)
    }

    func close() {
        controller.closePane()
        session.shutDown()
        window.close()
        files.remove()
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func requests(_ agent: ChatAgent) throws -> [[String: String]] { try files.requests(agent) }

    func layout() { controller.view.layoutSubtreeIfNeeded() }

    func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(predicate())
    }

    static func descendants(of view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants(of: $0) } }
}
