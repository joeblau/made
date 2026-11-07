import Foundation
import Testing
@testable import Pilot

// MARK: - Protocol: session configuration parsing

@Suite("ACP session configuration")
struct AgentSessionConfigTests {
    struct Expected: Sendable, CustomTestStringConvertible {
        var agent: ChatAgent
        var optionIDs: [String]
        var model: (current: String, name: String, count: Int)
        var thoughtLevel: (id: String, current: String, values: [String])?
        var mode: (id: String, current: String, count: Int)?
        var fastID: String?
        var legacyModels: Int?
        var legacyModes: Int?

        var testDescription: String { agent.rawValue }
    }

    static let expectations: [Expected] = [
        Expected(agent: .claude, optionIDs: ["mode", "model", "effort", "fast", "ultracode", "agent"],
                 model: ("opus", "Opus 5.5", 13),
                 thoughtLevel: ("effort", "high", ["default", "low", "medium", "high", "xhigh", "max"]),
                 mode: ("mode", "auto", 5), fastID: "fast", legacyModels: nil, legacyModes: 5),
        Expected(agent: .codex, optionIDs: ["mode", "collaboration_mode", "model", "reasoning_effort", "fast-mode"],
                 model: ("gpt-6-astra", "6 Astra", 8),
                 thoughtLevel: ("reasoning_effort", "xhigh", ["low", "medium", "high", "xhigh", "max", "ultra"]),
                 mode: ("mode", "agent", 4), fastID: "fast-mode", legacyModels: 46, legacyModes: 4),
        Expected(agent: .kimi, optionIDs: ["model", "thinking", "mode"],
                 model: ("kimi-code/k3.1-pro-highspeed", "K3.1 Pro Highspeed 2x Usage Cost", 12),
                 thoughtLevel: ("thinking", "high", ["low", "high", "max"]),
                 mode: ("mode", "default", 4), fastID: nil, legacyModels: nil, legacyModes: 4),
        Expected(agent: .grok, optionIDs: ["model", "reasoning_effort"],
                 model: ("grok-4.7-build-fast", "Grok 4.7 Fast", 4),
                 thoughtLevel: ("reasoning_effort", "medium", ["xhigh", "high", "medium", "low"]),
                 mode: nil, fastID: nil, legacyModels: 4, legacyModes: nil),
        Expected(agent: .cursor, optionIDs: ["mode", "model"],
                 model: ("grok-4.7[context=256k,reasoning_effort=high,fast=true]", "grok-4.7", 47),
                 thoughtLevel: nil, mode: ("mode", "agent", 3), fastID: nil, legacyModels: 47, legacyModes: 3),
    ]

    @Test("Every agent's real session/new result parses", arguments: expectations)
    func probeFixturesParse(_ expected: Expected) throws {
        let config = try #require(ACPSessionConfig(ACPProbeFixtures.result(expected.agent)))
        #expect(config.options.map(\.id) == expected.optionIDs)
        let model = try #require(config.model)
        #expect(model.id == "model" && !model.isLegacy)
        #expect(model.currentID == expected.model.current)
        #expect(model.currentName == expected.model.name)
        #expect(model.choices.count == expected.model.count)
        #expect(config.thoughtLevel?.id == expected.thoughtLevel?.id)
        #expect(config.thoughtLevel?.currentID == expected.thoughtLevel?.current)
        #expect(config.thoughtLevel?.choices.map(\.id) ?? [] == expected.thoughtLevel?.values ?? [])
        // Config options win over the legacy modes list when both are advertised.
        #expect(config.mode?.id == expected.mode?.id)
        #expect(config.mode?.currentID == expected.mode?.current)
        #expect(config.mode?.choices.count == expected.mode?.count)
        #expect(config.fast?.id == expected.fastID)
        #expect(config.legacyModels?.choices.count == expected.legacyModels)
        #expect(config.legacyModes?.choices.count == expected.legacyModes)
        // The compatibility accessors still read the model option.
        #expect(ACPSessionResult.modelName(try ACPProbeFixtures.result(expected.agent)) == expected.model.name)
        #expect(try ACPModelState(ACPProbeFixtures.result(expected.agent))?.currentID == expected.model.current)
    }

    @Test
    func categoriesAndDescriptionsComeFromTheAgent() throws {
        let codex = try #require(ACPSessionConfig(ACPProbeFixtures.result(.codex)))
        #expect(codex.option(id: "collaboration_mode")?.category == .other("collaboration_mode"))
        #expect(codex.fast?.choice("on")?.detail == "1.5x speed, increased usage")
        #expect(codex.legacyModels?.currentID == "gpt-6-astra[xhigh]")
        let claude = try #require(ACPSessionConfig(ACPProbeFixtures.result(.claude)))
        #expect(claude.option(id: "agent")?.category == .other(""))
        // Ultracode is a model_config on/off switch but not "fast".
        #expect(claude.option(id: "ultracode")?.category == .modelConfig)
        #expect(claude.model?.choice("fable")?.detail == "For your toughest challenges")
        // Every mode is selectable through the config option, and the legacy list stays available.
        #expect(claude.allOptions.map(\.id) == claude.options.map(\.id))
        let grok = try #require(ACPSessionConfig(ACPProbeFixtures.result(.grok)))
        #expect(grok.mode == nil && grok.legacyModes == nil)
    }

    @Test
    func legacyListsAdaptWhenNoConfigOptionCoversThem() throws {
        let config = try #require(ACPSessionConfig(json(#"""
        {"models":{"currentModelId":"m1","availableModels":[{"modelId":"m1","name":"One"},{"modelId":"m2","name":"Two","description":"Second"}]},
         "modes":{"currentModeId":"ask","availableModes":[{"id":"ask","name":"Ask"},{"id":"code","name":"Code"}]}}
        """#)))
        #expect(config.options.isEmpty)
        #expect(config.model?.isLegacy == true && config.model?.currentName == "One")
        #expect(config.mode?.id == ACPConfigOption.legacyModeID && config.mode?.currentID == "ask")
        #expect(config.allOptions.map(\.id) == [ACPConfigOption.legacyModelID, ACPConfigOption.legacyModeID])
        // Grok's older adapter reports only the current model: nothing is selectable.
        let bare = try #require(ACPSessionConfig(json(#"{"_meta":{"modelState":{"currentModelId":"grok-4.7-build-fast"}}}"#)))
        #expect(bare.model?.currentName == "grok-4.7-build-fast")
        #expect(bare.request(sessionID: "s", optionID: ACPConfigOption.legacyModelID, value: "grok-4.7-build-fast") == nil)
        #expect(try ACPSessionConfig(json(#"{"sessionId":"s"}"#)) == nil)
    }

    @Test
    func requestsUseTheAPIEachOptionCameFrom() throws {
        let claude = try #require(ACPSessionConfig(ACPProbeFixtures.result(.claude)))
        let model = try #require(claude.request(sessionID: "s", optionID: "model", value: "sonnet"))
        #expect(model.method == "session/set_config_option")
        #expect(model.params == ["sessionId": "s", "configId": "model", "value": "sonnet"])
        let effort = try #require(claude.request(sessionID: "s", optionID: "effort", value: "max"))
        #expect(effort.params["configId"] == "effort")
        let legacyMode = try #require(claude.request(sessionID: "s", optionID: ACPConfigOption.legacyModeID, value: "plan"))
        #expect(legacyMode.method == "session/set_mode")
        #expect(legacyMode.params == ["sessionId": "s", "modeId": "plan"])
        let codex = try #require(ACPSessionConfig(ACPProbeFixtures.result(.codex)))
        let legacyModel = try #require(codex.request(sessionID: "s", optionID: ACPConfigOption.legacyModelID, value: "gpt-6.1-sol[low]"))
        #expect(legacyModel.method == "session/set_model")
        #expect(legacyModel.params == ["sessionId": "s", "modelId": "gpt-6.1-sol[low]"])
        // Never a value or option the agent did not advertise.
        #expect(claude.request(sessionID: "s", optionID: "model", value: "invented") == nil)
        #expect(claude.request(sessionID: "s", optionID: "invented", value: "on") == nil)
        #expect(codex.request(sessionID: "s", optionID: "model", value: "gpt-6.1-sol[low]") == nil)
    }

    @Test
    func displayNamesAreNormalizedWithoutInventingValues() throws {
        let claude = try #require(ACPSessionConfig(ACPProbeFixtures.result(.claude)))
        let effort = try #require(claude.thoughtLevel)
        #expect(effort.choices.map(effort.displayName(of:)) == ["Default", "Low", "Medium", "High", "Extra High", "Max"])
        let kimi = try #require(ACPSessionConfig(ACPProbeFixtures.result(.kimi)))
        let thinking = try #require(kimi.thoughtLevel)
        #expect(thinking.choices.map(thinking.displayName(of:)) == ["Low", "High", "Max"])
        #expect(thinking.currentDisplayName == "High")
        let codex = try #require(ACPSessionConfig(ACPProbeFixtures.result(.codex)))
        #expect(codex.thoughtLevel?.currentDisplayName == "Extra High")
        let grok = try #require(ACPSessionConfig(ACPProbeFixtures.result(.grok)))
        #expect(grok.thoughtLevel?.choices.map { grok.thoughtLevel?.displayName(of: $0) } == ["Extra High", "High", "Medium", "Low"])

        #expect(ACPConfigOption.displayName(choiceID: "xhigh", name: "XHigh", optionName: "Effort") == "Extra High")
        #expect(ACPConfigOption.displayName(choiceID: "xhigh", name: "X-High", optionName: "Effort") == "Extra High")
        #expect(ACPConfigOption.displayName(choiceID: "high", name: "Xhigh", optionName: "Effort") == "Xhigh")
        #expect(ACPConfigOption.displayName(choiceID: "xhigh", name: "Very deep", optionName: "Effort") == "Very deep")
        #expect(ACPConfigOption.displayName(choiceID: "low", name: "Reasoning effort: Low", optionName: "Reasoning effort") == "Low")
        #expect(ACPConfigOption.displayName(choiceID: "x", name: "Thinking", optionName: "Thinking") == "Thinking")
        #expect(ACPConfigOption.displayName(choiceID: "x", name: "Thinkingmax", optionName: "Thinking") == "Thinkingmax")
        #expect(ACPConfigOption.displayName(choiceID: "default", name: "Default", optionName: "Effort") == "Default")
    }

    @Test
    func unrestrictedModesAreRecognizedAcrossAgents() throws {
        var unrestricted: [String] = []
        for agent in ChatAgent.allCases {
            let config = try ACPSessionConfig(ACPProbeFixtures.result(agent))
            for choice in config?.mode?.choices ?? [] where ACPConfigOption.isUnrestrictedMode(choice) {
                unrestricted.append("\(agent.rawValue):\(choice.id)")
            }
        }
        #expect(unrestricted == ["claude:bypassPermissions", "codex:agent-full-access", "kimi:yolo"])
        let named = ACPConfigOption.Choice(id: "m7", name: "Danger zone")
        #expect(ACPConfigOption.isUnrestrictedMode(named))
        #expect(ACPConfigOption.isUnrestrictedMode(.init(id: "full-access", name: "Everything")))
        #expect(!ACPConfigOption.isUnrestrictedMode(.init(id: "auto", name: "Auto")))
    }

    @Test
    func untrustedOptionsAreBoundedBeforeTheyAreKept() throws {
        let longID = String(repeating: "i", count: 257)
        var choices: [JSONValue] = (0..<600).map { ["value": .string("v\($0)"), "name": .string("Choice \($0)")] }
        choices.insert(["value": 7, "name": "Numeric"], at: 0)
        choices.insert(["value": .string(longID), "name": "Long"], at: 0)
        choices.append(["value": "v1", "name": "Duplicate"])
        var options: [JSONValue] = [
            ["id": "big", "type": "select", "currentValue": "v1", "category": "model", "options": .array(choices),
             "name": .string("\u{202E}Mo\u{200B}del\n\tpicker  " + String(repeating: "é", count: 400)),
             "description": .string(String(repeating: "d", count: 5_000))],
            ["id": "flag", "type": "boolean", "currentValue": "true", "options": []],
            ["id": .string(longID), "type": "select", "currentValue": "a", "options": []],
            ["id": "numeric", "type": "select", "currentValue": 3, "options": []],
            ["id": .string(ACPConfigOption.legacyModelID), "type": "select", "currentValue": "a", "options": []],
            ["id": "big", "type": "select", "currentValue": "v2", "options": []],
        ]
        options += (0..<40).map { index -> JSONValue in ["id": .string("o\(index)"), "type": "select", "currentValue": "a", "options": [["value": "a", "name": "A"]]] }
        let config = try #require(ACPSessionConfig(["configOptions": .array(options)]))
        #expect(config.options.count == ACPConfigBounds.options)
        let big = try #require(config.option(id: "big"))
        #expect(config.options.filter { $0.id == "big" }.count == 1)
        #expect(big.choices.count == ACPConfigBounds.choices)
        #expect(big.choices.first?.id == "v0" && big.choice("v1")?.name == "Choice 1")
        #expect(big.name.hasPrefix("Model picker é"))
        #expect(big.name.utf8.count <= ACPConfigBounds.nameBytes)
        #expect(big.detail?.utf8.count == ACPConfigBounds.detailBytes)
        #expect(!config.options.contains { ["flag", "numeric", longID, ACPConfigOption.legacyModelID].contains($0.id) })
        #expect(ACPConfigText.text(.string("\u{2066}A\u{2069}\u{200F} b\u{0000}c"), maximumBytes: 64) == "A b c")
        #expect(ACPConfigText.text(.string("\u{202E}\u{200B}"), maximumBytes: 64) == nil)
    }

    @Test
    func groupedChoicesKeepTheirGroupName() throws {
        let config = try #require(ACPSessionConfig(json(#"""
        {"configOptions":[{"id":"llm","category":"model","type":"select","currentValue":"opus","options":[
          {"group":"recommended","name":"Recommended","options":[{"value":"opus","name":"Opus"},{"value":"sonnet","name":"Sonnet"}]},
          {"value":"haiku","name":"Haiku"}]}]}
        """#)))
        #expect(config.model?.choices.map(\.group) == ["Recommended", "Recommended", nil])
    }

    @Test @MainActor
    func unnamedChoicesAndUnlistedCurrentValuesDisplaySanitizedIDs() throws {
        let sneaky = "agent-full-access\n\nSandboxed: no file or network access"
        let config = try #require(ACPSessionConfig([
            "configOptions": [
                ["id": "m\u{202E}x", "category": "model", "type": "select", "currentValue": "gpt\u{202E}6\nX",
                 "options": [["value": "gpt\u{202E}7"], ["value": "\u{202E}\u{200B}"], ["value": "named", "name": "Named"]]],
                ["id": "mode", "category": "mode", "type": "select", "currentValue": "auto",
                 "options": [["value": .string(sneaky)], ["value": "auto", "name": "Auto"]]],
            ],
            "modes": ["currentModeId": "y\u{2066}olo", "availableModes": [["id": "ask\tfirst"]]],
        ]))
        let model = try #require(config.model)
        #expect(model.name == "mx", "An unnamed option shows its sanitized ID")
        #expect(model.choices.map(\.name) == ["gpt7", "Unnamed", "Named"])
        #expect(model.choices.map(\.id) == ["gpt\u{202E}7", "\u{202E}\u{200B}", "named"], "Requests keep the raw ID")
        #expect(model.request(sessionID: "s", value: "gpt\u{202E}7")?.params["value"] == .string("gpt\u{202E}7"))
        #expect(model.currentChoice == nil && model.currentName == "gpt6 X" && model.currentDisplayName == "gpt6 X")
        #expect(AgentModelPickerController.triggerLabel(config).model == "gpt6 X")
        let mode = try #require(config.mode)
        #expect(mode.choices.first?.name == "agent-full-access Sandboxed: no file or network access")
        #expect(mode.choices.first?.id == sneaky)
        #expect(config.legacyModes?.choices.map(\.name) == ["ask first"] && config.legacyModes?.currentName == "yolo")
        // An unlisted current mode is still classified by what it reports.
        let unlisted = config.settingCurrent(optionID: "mode", to: "bypassPermissions").mode
        #expect(unlisted?.currentChoice == nil)
        #expect(unlisted.map { ACPConfigOption.isUnrestrictedMode($0.currentOrUnlistedChoice) } == true)
        #expect(ACPConfigText.label(forID: "\u{202E}") == "Unnamed")
    }

    // MARK: Updates

    @Test
    func configOptionUpdatesCarryTheFullListOrTheCurrentModel() throws {
        let fixture = try ACPProbeFixtures.result(.codex)
        let full = try #require(ACP.parseSessionUpdate([
            "sessionId": "s", "update": ["sessionUpdate": "config_option_update", "configOptions": fixture["configOptions"] ?? .null],
        ]))
        guard case .configuration(let patch) = full.update else { Issue.record("expected configuration"); return }
        #expect(patch.options?.count == 5 && patch.legacyModels == nil && patch.legacyModes == nil)
        #expect(patch.model?.currentID == "gpt-6-astra")

        for update: JSONValue in [
            ["sessionUpdate": "config_option_update", "currentModelId": "gpt-6-luna"],
            ["sessionUpdate": "config_option_update", "_meta": ["modelState": ["currentModelId": "gpt-6-luna"]]],
            ["sessionUpdate": "current_model_update", "currentModelId": "gpt-6-luna"],
        ] {
            #expect(ACP.parseSessionUpdate(["sessionId": "s", "update": update])?.update == .currentModel("gpt-6-luna"))
        }
        #expect(ACP.parseSessionUpdate(["sessionId": "s", "update": ["sessionUpdate": "current_mode_update", "currentModeId": "plan"]])?
            .update == .currentMode("plan"))
        #expect(ACP.parseSessionUpdate(["sessionId": "s", "update": ["sessionUpdate": "current_mode_update", "currentModeId": 4]]) == nil)
        let empty = ACP.parseSessionUpdate(["sessionId": "s", "update": ["sessionUpdate": "config_option_update"]])
        #expect(empty?.update == .configuration(.init()))
    }

    @Test
    func patchesReplaceOnlyThePartsTheyCarry() throws {
        let codex = try #require(ACPSessionConfig(ACPProbeFixtures.result(.codex)))
        let emptied = codex.applying(.init(options: []))
        #expect(emptied.options.isEmpty)
        // With no model config option left, the legacy models list is the model.
        #expect(emptied.model?.isLegacy == true && emptied.legacyModes == codex.legacyModes)
        #expect(codex.applying(.init()) == codex)
        let moved = codex.settingCurrent(optionID: "reasoning_effort", to: "low")
            .settingCurrent(optionID: ACPConfigOption.legacyModeID, to: "read-only")
            .settingCurrent(optionID: "missing", to: "x")
        #expect(moved.thoughtLevel?.currentID == "low" && moved.legacyModes?.currentID == "read-only")
        #expect(moved.mode?.currentID == "agent")
    }

    private func json(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }
}

// MARK: - Session: selecting options

/// Config changes against scripted shell agents that answer `session/new`
/// with a real probe fixture.
@Suite("Agent chat session configuration")
@MainActor
struct AgentSessionConfigSessionTests {
    @Test
    func aChangeIsShownOnlyAfterTheAgentAcknowledgesItAndARejectionKeepsTheValue() async throws {
        let files = try FixtureFiles()
        defer { files.remove() }
        let codex = try ACPProbeFixtures.result(.codex)
        // Selecting a model returns the full list, with that model's own reasoning levels.
        try files.write("luna", options(codex, current: ["model": "gpt-6-luna", "reasoning_effort": "medium"],
                                        keep: ["reasoning_effort": ["low", "medium", "high"]]))
        try files.write("low", options(codex, current: ["model": "gpt-6-luna", "reasoning_effort": "low"],
                                       keep: ["reasoning_effort": ["low", "medium", "high"]]))
        let defaults = try suite()
        let session = makeSession(.codex, defaults: defaults, launches: [.codex: try files.agent(codex, body: #"""
        read -r line; has "$line" '"method":"session/set_config_option"' && has "$line" '"configId":"model"' \
          && has "$line" '"value":"gpt-6-luna"' || exit 1
        reply 3 luna
        read -r line; has "$line" '"configId":"reasoning_effort"' && has "$line" '"value":"low"' || exit 1
        reply 4 low
        read -r line; has "$line" '"configId":"fast-mode"' || exit 1
        printf '%s\n' '{"jsonrpc":"2.0","id":5,"error":{"code":-32602,"message":"Fast mode is unavailable"}}'
        read -r line; has "$line" '"configId":"mode"' && has "$line" '"value":"read-only"' || exit 1
        printf '%s\n' '{"jsonrpc":"2.0","id":6,"result":{}}'
        read -r _
        """#)])
        defer { session.shutDown() }
        session.start()
        try await waitUntil { session.phase == .ready }
        #expect(session.config?.thoughtLevel?.choices.count == 6)
        #expect(AgentModelCatalog(defaults: defaults).snapshot(for: .codex)?.currentModelID == "gpt-6-astra")

        session.selectModel("gpt-6-luna")
        #expect(session.isChangingModel && !session.canChangeConfiguration)
        #expect(session.modelName == "6 Astra")
        // A second change waits for the first.
        session.selectConfigOption("reasoning_effort", value: "low")
        try await waitUntil { !session.isChangingModel }
        #expect(session.modelName == "6 Luna")
        #expect(session.config?.thoughtLevel?.choices.map(\.id) == ["low", "medium", "high"])
        #expect(session.config?.thoughtLevel?.currentID == "medium")
        #expect(AgentModelCatalog(defaults: defaults).snapshot(for: .codex)?.currentModelID == "gpt-6-luna")

        session.selectConfigOption("reasoning_effort", value: "low")
        try await waitUntil { !session.isChangingModel }
        #expect(session.config?.thoughtLevel?.currentID == "low")

        session.selectConfigOption("fast-mode", value: "on")
        try await waitUntil { !session.isChangingModel }
        #expect(session.config?.fast?.currentID == "off")
        #expect(session.composerError?.hasPrefix("Could not change setting:") == true)

        // An answer without the configuration list is not an acknowledgement.
        session.selectConfigOption("mode", value: "read-only")
        try await waitUntil { !session.isChangingModel }
        #expect(session.config?.mode?.currentID == "agent")
        #expect(session.composerError == "The agent did not confirm the selected mode. Please try again.")
        // Values the agent never advertised are not sent.
        session.selectConfigOption("reasoning_effort", value: "ultra")
        session.selectConfigOption("invented", value: "on")
        #expect(!session.isChangingModel)
    }

    @Test
    func legacyModesAreAcknowledgedByAnEmptyResultAndAgentUpdatesAreDisplayed() async throws {
        let files = try FixtureFiles()
        defer { files.remove() }
        let cursor = try ACPProbeFixtures.result(.cursor)
        var legacy = cursor
        if case .object(var fields) = legacy { fields["configOptions"] = nil; legacy = .object(fields) }
        // The update lists only the model option, so the legacy modes list stays the mode.
        let models = options(cursor, current: ["model": "composer-2.5[fast=true]"])["configOptions"]?.arrayValue?
            .filter { $0["id"] == "model" } ?? []
        try files.write("update", ["sessionUpdate": "config_option_update", "configOptions": .array(models)])
        let session = makeSession(.cursor, launches: [.cursor: try files.agent(legacy, body: #"""
        read -r line; has "$line" '"method":"session/set_mode"' && has "$line" '"modeId":"plan"' || exit 1
        printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":null}'
        read -r _
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"SID","update":{"sessionUpdate":"current_mode_update","currentModeId":"ask"}}}'
        printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"SID","update":'; cat "$DIR/update.json"; printf '}}\n'
        printf '%s\n' '{"jsonrpc":"2.0","id":4,"result":{"stopReason":"end_turn"}}'
        read -r _
        """#)])
        defer { session.shutDown() }
        session.start()
        try await waitUntil { session.phase == .ready }
        #expect(session.config?.mode?.id == ACPConfigOption.legacyModeID)
        session.selectConfigOption(ACPConfigOption.legacyModeID, value: "plan")
        #expect(session.config?.mode?.currentID == "agent")
        try await waitUntil { !session.isChangingModel }
        #expect(session.config?.mode?.currentID == "plan")
        #expect(session.composerError == nil)

        session.draft = "Hello"
        session.send()
        try await waitUntil { session.phase == .ready }
        #expect(session.config?.mode?.currentID == "ask")
        #expect(session.config?.model?.id == "model" && session.modelName == "composer-2.5")
    }

    @Test
    func anUnrestrictedModeIsSentOnlyAfterTheUserConfirms() async throws {
        let files = try FixtureFiles()
        defer { files.remove() }
        let claude = try ACPProbeFixtures.result(.claude)
        try files.write("plan", options(claude, current: ["mode": "plan"]))
        try files.write("bypass", options(claude, current: ["mode": "bypassPermissions"]))
        let session = makeSession(.claude, launches: [.claude: try files.agent(claude, body: #"""
        read -r line; has "$line" '"value":"plan"' || exit 1
        reply 3 plan
        read -r line; has "$line" '"value":"bypassPermissions"' || exit 1
        reply 4 bypass
        read -r _
        """#)])
        defer { session.shutDown() }
        session.start()
        try await waitUntil { session.phase == .ready }

        // Without a confirmation hook the mode is never selected.
        session.selectConfigOption("mode", value: "bypassPermissions")
        try await waitUntil { !session.isChangingModel }
        #expect(session.config?.mode?.currentID == "auto")

        let prompt = ConfirmationPrompt()
        session.confirmUnrestrictedMode = { agent, choice in
            prompt.asked.append("\(agent.rawValue):\(choice.id)")
            return prompt.allow
        }
        session.selectConfigOption("mode", value: "plan")
        try await waitUntil { !session.isChangingModel }
        #expect(session.config?.mode?.currentID == "plan" && prompt.asked.isEmpty)

        session.selectConfigOption("mode", value: "bypassPermissions")
        #expect(session.isChangingModel)
        try await waitUntil { !session.isChangingModel }
        #expect(session.config?.mode?.currentID == "plan")

        prompt.allow = true
        session.selectConfigOption("mode", value: "bypassPermissions")
        try await waitUntil { session.config?.mode?.currentID == "bypassPermissions" && !session.isChangingModel }
        #expect(prompt.asked == ["claude:bypassPermissions", "claude:bypassPermissions"])
    }

    @Test
    func aModelPickedOnAnotherProviderIsSelectedOnceItIsReady() async throws {
        let files = try FixtureFiles()
        defer { files.remove() }
        let codex = try ACPProbeFixtures.result(.codex)
        try files.write("luna", options(codex, current: ["model": "gpt-6-luna"]))
        let defaults = try suite()
        let paneID = UUID()
        let session = makeSession(.claude, defaults: defaults, paneID: paneID, launches: [
            .claude: try files.agent(ACPProbeFixtures.result(.claude), body: "read -r _"),
            .codex: try files.agent(codex, body: #"""
            read -r line; has "$line" '"configId":"model"' && has "$line" '"value":"gpt-6-luna"' || exit 1
            reply 3 luna
            read -r _
            """#),
            .kimi: try files.agent(ACPProbeFixtures.result(.kimi), body: "read -r _"),
        ])
        defer { session.shutDown() }
        session.start()
        try await waitUntil { session.phase == .ready }

        session.selectModel("gpt-6-luna", on: .codex)
        #expect(session.agent == .codex && session.pendingModel == AgentChatSession.PendingModel(agent: .codex, modelID: "gpt-6-luna"))
        #expect(AgentChatPaneStore.agent(for: paneID, defaults: defaults) == .codex)
        try await waitUntil { session.modelName == "6 Luna" && !session.isChangingModel }
        #expect(session.pendingModel == nil && session.composerError == nil)
        let catalog = AgentModelCatalog(defaults: defaults)
        #expect(catalog.snapshot(for: .claude)?.models.count == 13)
        #expect(catalog.snapshot(for: .codex)?.currentModelID == "gpt-6-luna")

        // A cached model the provider no longer offers is dropped with a notice.
        session.selectModel("moonshot-ai/kimi-k1", on: .kimi)
        try await waitUntil { session.phase == .ready }
        #expect(session.pendingModel == nil)
        #expect(session.modelName == "K3.1 Pro Highspeed 2x Usage Cost")
        #expect(session.composerError == "Kimi no longer offers the selected model.")
    }

    @Test
    func aModelPickedWhileTheRunningAgentStartsReplacesThePendingOne() async throws {
        let files = try FixtureFiles()
        defer { files.remove() }
        let codex = try ACPProbeFixtures.result(.codex)
        try files.write("sol", options(codex, current: ["model": "gpt-6.1-sol"]))
        let defaults = try suite()
        let session = makeSession(.claude, defaults: defaults, launches: [
            .claude: try files.agent(ACPProbeFixtures.result(.claude), body: "read -r _"),
            .codex: try files.agent(codex, body: #"""
            read -r line; has "$line" '"configId":"model"' && has "$line" '"value":"gpt-6.1-sol"' || exit 1
            reply 3 sol
            read -r _
            """#),
        ])
        defer { session.shutDown() }
        session.start()
        try await waitUntil { session.phase == .ready }

        session.selectModel("gpt-6-luna", on: .codex)
        #expect(session.agent == .codex && session.phase == .starting)
        // The same agent again while it starts: the latest pick wins.
        session.selectModel("gpt-6.1-sol", on: .codex)
        #expect(session.pendingModel == AgentChatSession.PendingModel(agent: .codex, modelID: "gpt-6.1-sol"))
        try await waitUntil { session.modelName == "6.1 Sol" && !session.isChangingModel }
        #expect(session.pendingModel == nil && session.composerError == nil)

        // Once ready, a model the session does not advertise is reported, not dropped silently.
        session.selectModel("gpt-retired", on: .codex)
        #expect(!session.isChangingModel && session.modelName == "6.1 Sol")
        #expect(session.composerError == "Codex no longer offers the selected model.")
    }

    // MARK: Helpers

    @MainActor
    private final class ConfirmationPrompt {
        var asked: [String] = []
        var allow = false
    }

    private func suite() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "AgentSessionConfigTests.\(UUID().uuidString)"))
    }

    private func makeSession(
        _ agent: ChatAgent,
        defaults: UserDefaults? = nil,
        paneID: UUID = UUID(),
        launches: [ChatAgent: ACPConnection.LaunchConfiguration]
    ) -> AgentChatSession {
        AgentChatSession(
            paneID: paneID, agent: agent, workingDirectory: NSTemporaryDirectory(),
            defaults: defaults ?? UserDefaults(suiteName: "AgentSessionConfigTests.\(UUID().uuidString)") ?? .standard,
            resolveLaunch: { agent, _ in
                guard let launch = launches[agent] else { return .failure(.noWorkingDirectory) }
                return .success(launch)
            }
        )
    }

    /// The `{configOptions}` answer to `set_config_option`: `result`'s list
    /// with new current values and, optionally, fewer choices.
    private func options(_ result: JSONValue, current: [String: String], keep: [String: [String]] = [:]) -> JSONValue {
        let list = (result["configOptions"]?.arrayValue ?? []).map { option -> JSONValue in
            guard case .object(var fields) = option, let id = option["id"]?.stringValue else { return option }
            if let value = current[id] { fields["currentValue"] = .string(value) }
            if let kept = keep[id] {
                fields["options"] = .array((option["options"]?.arrayValue ?? []).filter {
                    kept.contains($0["value"]?.stringValue ?? "")
                })
            }
            return .object(fields)
        }
        return ["configOptions": .array(list)]
    }

    /// JSON files a shell agent `cat`s, since fixtures hold quotes a shell string cannot.
    private struct FixtureFiles {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AgentSessionConfig-\(UUID())")

        init() throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func write(_ name: String, _ value: JSONValue) throws {
            try value.serialized().write(to: directory.appendingPathComponent("\(name).json"))
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }

        /// Answers initialize and session/new (with `newSession`), then runs
        /// `body` with `has` and `reply <id> <file>` helpers.
        func agent(_ newSession: JSONValue, body: String) throws -> ACPConnection.LaunchConfiguration {
            let name = "new-\(UUID().uuidString)"
            try write(name, newSession)
            let sessionID = newSession["sessionId"]?.stringValue ?? "s1"
            let preamble = #"""
            has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
            reply() { printf '{"jsonrpc":"2.0","id":%s,"result":' "$1"; cat "$DIR/$2.json"; printf '}\n'; }
            read -r _
            printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":false}}}'
            read -r _
            reply 2 NEW

            """#.replacingOccurrences(of: "NEW", with: name)
            return ACPConnection.LaunchConfiguration(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", (preamble + body).replacingOccurrences(of: "SID", with: sessionID)],
                environment: ["DIR": directory.path, "PATH": "/usr/bin:/bin"],
                currentDirectory: directory
            )
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(10),
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("condition not met within \(timeout)", sourceLocation: sourceLocation)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
