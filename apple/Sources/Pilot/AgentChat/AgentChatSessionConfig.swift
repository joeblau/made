import Foundation

/// Session configuration: the options the agent advertises (model,
/// reasoning level, mode, fast), changes the user selects, a model picked on
/// another provider, and the confirmation an unrestricted mode needs.
///
/// A change is shown only once the agent acknowledges it or reports it in
/// an update; a rejected change keeps the previous value and reports the
/// failure in `composerError`. Cockpit never selects an unrestricted mode on
/// its own: the user confirms each one through `confirmUnrestrictedMode`.
extension AgentChatSession {
    /// A model chosen on a provider that is not running; selected once that
    /// provider's session is ready, if it still advertises the model.
    struct PendingModel: Equatable, Sendable {
        var agent: ChatAgent
        var modelID: String
    }

    var modelState: ACPConfigOption? { config?.model }
    var modelName: String? { config?.model?.currentName }
    /// True while any configuration change awaits the agent or the user.
    var isChangingModel: Bool { changingConfigOptionID != nil }

    var canChangeConfiguration: Bool {
        phase == .ready && changingConfigOptionID == nil && !isPreparingPrompt && connection != nil && rootSessionID != nil
    }

    func selectModel(_ id: String) {
        guard let model = config?.model else { return }
        selectConfigOption(model.id, value: id)
    }

    /// Selects `id` on `target`; another provider is started first (as
    /// `switchAgent` does) and the model is selected once it is ready. On the
    /// running agent before its session is ready, the choice replaces any
    /// pending one, so the latest pick is the one applied; once ready, a model
    /// the session no longer advertises is reported instead of dropped.
    func selectModel(_ id: String, on target: ChatAgent) {
        guard target != agent else {
            switch phase {
            case .idle, .starting:
                pendingModel = PendingModel(agent: target, modelID: id)
            default:
                if canChangeConfiguration, config?.model?.choice(id) == nil {
                    composerError = "\(agent.displayName) no longer offers the selected model."
                } else {
                    selectModel(id)
                }
            }
            return
        }
        switchAgent(to: target)
        guard agent == target else { return }
        pendingModel = PendingModel(agent: target, modelID: id)
    }

    /// Asks the agent to set `optionID` to `value`. Ignored unless the option
    /// advertises `value` and no other change is in flight. Unrestricted modes
    /// are sent only after `confirmUnrestrictedMode` returns true.
    func selectConfigOption(_ optionID: String, value: String) {
        guard canChangeConfiguration, let option = config?.option(id: optionID), value != option.currentID,
              let choice = option.choice(value) else { return }
        guard option.category == .mode, ACPConfigOption.isUnrestrictedMode(choice) else {
            sendConfigChange(optionID: optionID, value: value)
            return
        }
        changingConfigOptionID = optionID
        let generation = generation
        let agent = agent
        let confirm = confirmUnrestrictedMode
        Task {
            let allowed = await confirm(agent, choice)
            guard generation == self.generation, changingConfigOptionID == optionID else { return }
            changingConfigOptionID = nil
            if allowed { sendConfigChange(optionID: optionID, value: value) }
        }
    }

    /// Replaces the configuration and caches its model list for the picker.
    func applyConfiguration(_ newConfig: ACPSessionConfig?) {
        config = newConfig
        if let newConfig { AgentModelCatalog(defaults: defaults).record(newConfig, for: agent) }
    }

    /// Agent-initiated changes (`config_option_update`, `current_model_update`,
    /// `current_mode_update`) are displayed as reported.
    func applyConfigurationUpdate(_ update: ACPUpdate) {
        switch update {
        case .configuration(let patch) where !patch.isEmpty:
            applyConfiguration((config ?? ACPSessionConfig()).applying(patch))
        case .currentModel(let id):
            if let config, let model = config.model { applyConfiguration(config.settingCurrent(optionID: model.id, to: id)) }
        case .currentMode(let id):
            if let config, let mode = config.mode { applyConfiguration(config.settingCurrent(optionID: mode.id, to: id)) }
        default:
            break
        }
    }

    /// Runs when a session becomes ready: selects the model picked on this
    /// provider before it was running, or says it is no longer offered.
    func applyPendingModel() {
        guard let pending = pendingModel else { return }
        pendingModel = nil
        guard pending.agent == agent, config?.model?.currentID != pending.modelID else { return }
        guard let model = config?.model, model.choice(pending.modelID) != nil else {
            composerError = "\(agent.displayName) no longer offers the selected model."
            return
        }
        selectConfigOption(model.id, value: pending.modelID)
    }

    private func sendConfigChange(optionID: String, value: String) {
        guard canChangeConfiguration, let connection, let rootSessionID, let option = config?.option(id: optionID),
              let request = option.request(sessionID: rootSessionID, value: value) else { return }
        changingConfigOptionID = optionID
        composerError = nil
        let generation = generation
        let noun = Self.changeNoun(option)
        Task {
            do {
                let result = try await connection.request(request.method, params: request.params, timeout: .seconds(30))
                guard generation == self.generation else { return }
                let patch = ACPSessionConfig.Patch(result)
                let current = config ?? ACPSessionConfig()
                if option.isLegacy {
                    // set_model / set_mode answer with an empty result: the answer is the acknowledgement.
                    let updated = current.applying(patch)
                    let reported = optionID == ACPConfigOption.legacyModelID ? patch.legacyModels : patch.legacyModes
                    applyConfiguration(reported == nil ? updated.settingCurrent(optionID: optionID, to: value) : updated)
                } else if patch.options != nil {
                    // set_config_option answers with the full list, which can
                    // change other options too (Codex's reasoning levels per model).
                    applyConfiguration(current.applying(patch))
                } else {
                    composerError = "The agent did not confirm the selected \(noun). Please try again."
                }
            } catch {
                guard generation == self.generation else { return }
                composerError = "Could not change \(noun): " + redactInline(error.localizedDescription)
            }
            if generation == self.generation { changingConfigOptionID = nil }
        }
    }

    private static func changeNoun(_ option: ACPConfigOption) -> String {
        switch option.category {
        case .model: "model"
        case .thoughtLevel: "reasoning level"
        case .mode: "mode"
        case .modelConfig, .other: "setting"
        }
    }
}
