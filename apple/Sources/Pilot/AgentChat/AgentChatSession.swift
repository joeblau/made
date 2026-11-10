import Foundation
import Observation

extension ChatAgentSetupIssue: Error {}

/// One agent chat pane's live conversation: the agent process, its ACP
/// session, the rendered transcript, open permission requests, and usage.
///
/// The agent owns the conversation and its context; Cockpit sends only each
/// new prompt, so the agent's own prompt caching, compaction, and subagents
/// work exactly as in its TUI. `generation` fences every async callback so a
/// stopped or replaced agent can never write into the current one's state.
///
/// Ordering: a `session/load` or `session/prompt` response can overtake the
/// notifications sent before it, so both carry a barrier token and the session
/// acts on completion (ready, `finishTurn`, the queued prompt) only once the
/// event loop reaches that barrier, after every earlier notification.
@MainActor
@Observable
final class AgentChatSession {
    enum Phase: Equatable {
        case idle
        case starting
        case ready
        case prompting
        case needsSetup(ChatAgentSetupIssue)
        case failed(String)

        var isRunning: Bool { self == .starting || self == .ready || self == .prompting }
    }

    /// Session milestones kept (bounded) for diagnostics and tests.
    enum Diagnostic: Equatable, Sendable {
        case barrierReached(token: Int)
        case turnFinished(stopReason: String?)
        case approvalRecorded(requestID: JSONValue, agentName: String)
        case approvalResolved(requestID: JSONValue, decision: AgentChatItem.Approval.Decision)
        case approvalAutoApproved(requestID: JSONValue)
    }

    typealias Decision = AgentChatItem.Approval.Decision

    /// Requests beyond this are answered `cancelled` rather than queued.
    static let maximumPendingPermissions = 32
    /// Ring-buffer sizes for `recentEvents` and `diagnostics`.
    static let maximumRecentEvents = 256
    /// Names a permission request from a session no subagent card claims.
    static let untrackedSubagentName = "untracked subagent"

    /// Resolves how to launch an agent in a working directory. Injected so
    /// tests can drive a scripted agent without the user's login shell.
    typealias LaunchResolver = @Sendable (ChatAgent, String) async
        -> Result<ACPConnection.LaunchConfiguration, ChatAgentSetupIssue>

    static let loginShellLaunchResolver: LaunchResolver = { agent, workingDirectory in
        let environment = await LoginShellEnvironment.shared.environment()
        return ChatAgentLauncher.configuration(
            for: agent,
            workingDirectory: workingDirectory,
            shellEnvironment: environment
        )
    }

    let paneID: UUID
    private(set) var agent: ChatAgent
    private(set) var workingDirectory: String?
    private(set) var phase: Phase = .idle
    private(set) var transcript = AgentTranscript()
    private(set) var permissionQueue: [ACPPermissionRequest] = []
    private(set) var agentInfo: ACPAgentInfo?
    /// Advertised configuration, the option being changed, and a model picked
    /// on another provider: written only by AgentChatSessionConfig.swift.
    var config: ACPSessionConfig?
    var changingConfigOptionID: String?
    var pendingModel: PendingModel?
    /// Asks the user before an unrestricted mode is selected; the default refuses.
    @ObservationIgnored var confirmUnrestrictedMode: @MainActor (ChatAgent, ACPConfigOption.Choice) async -> Bool = { _, _ in false }
    /// Session-scoped "Auto-approve": while on, permission requests that offer
    /// an `allow_once` option are answered with it. In memory only, off for
    /// every new session, and reset whenever the agent stops (see
    /// "Auto-approve" below).
    private(set) var isAutoApproveEnabled = false
    /// True while the confirmation sheet for turning auto-approve on is up.
    private(set) var isConfirmingAutoApprove = false
    /// Asks the user before auto-approve turns on; the default refuses.
    @ObservationIgnored var confirmAutoApprove: @MainActor (ChatAgent) async -> Bool = { _ in false }
    private(set) var attachments: [AgentChatAttachment] = []
    private(set) var isImportingAttachments = false
    private(set) var isPreparingPrompt = false
    var composerError: String?
    private(set) var context: ACPContextUsage?
    private(set) var lastTurnUsage: NormalizedTurnUsage?
    private(set) var sessionUsage: NormalizedTurnUsage?
    /// One editable, removable slot sent after the turn ends with end_turn.
    private(set) var queuedPrompt: String?
    /// Text sent with `_session/steering` and not answered yet: the pending
    /// user bubble. Cleared when the agent answers.
    private(set) var pendingSteer: String?
    /// Keys of user items the agent accepted into a running turn ("Sent to
    /// running turn"); the agent does not echo steered text itself.
    private(set) var steeredItemKeys: Set<String> = []
    /// The notice of the latest failed turn, which offers "Send again".
    private(set) var sendAgainNoticeKey: String?
    /// Diagnostics and tests: the latest transcript events and their count.
    @ObservationIgnored private(set) var recentEvents: [AgentActivityEvent] = []
    private(set) var eventSequence = 0
    @ObservationIgnored private(set) var diagnostics: [Diagnostic] = []
    /// How long `steer(_:)` waits for the agent; injectable for tests.
    @ObservationIgnored var steerTimeout: Duration = .seconds(15)
    var draft = ""

    @ObservationIgnored private(set) var connection: ACPConnection?
    @ObservationIgnored private(set) var rootSessionID: String?
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private(set) var generation = 0
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private let resolveLaunch: LaunchResolver
    @ObservationIgnored private let attachmentDirectory: URL
    @ObservationIgnored private var attachmentImportTask: Task<Void, Never>?
    /// The injected clock (presentation reads it for live durations).
    @ObservationIgnored let now: @Sendable () -> Date
    /// The last text and attachments sent with `session/prompt`.
    @ObservationIgnored private var lastSubmission: (text: String, media: [AgentChatAttachment])?
    /// True from a prompt's submission until `finishTurn` ran for it.
    @ObservationIgnored private var isTurnOpen = false
    /// How the latest turn ended; only `end_turn` lets held text auto-send.
    @ObservationIgnored private var lastStopReason: String?
    /// Recorded approvals not yet resolved (queued or being answered): the
    /// asking session by JSON-RPC id.
    @ObservationIgnored private var openApprovals: [JSONValue: String] = [:]
    @ObservationIgnored private let barriers = ACPBarrierGate()

    init(
        paneID: UUID,
        agent: ChatAgent,
        workingDirectory: String?,
        defaults: UserDefaults = .standard,
        resolveLaunch: @escaping LaunchResolver = AgentChatSession.loginShellLaunchResolver,
        attachmentDirectory: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.paneID = paneID
        self.agent = agent
        self.workingDirectory = workingDirectory
        self.defaults = defaults
        self.resolveLaunch = resolveLaunch
        self.attachmentDirectory = attachmentDirectory ?? AgentChatAttachmentStore.directory(paneID: paneID)
        self.now = now
    }

    var pendingPermission: ACPPermissionRequest? { permissionQueue.first }

    var canSend: Bool {
        phase == .ready && !isChangingModel && !isImportingAttachments && !isPreparingPrompt
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    var isTurnRunning: Bool { phase == .prompting }

    /// Subagents the agent keeps running after the root turn ended.
    var hasBackgroundAgents: Bool {
        guard phase == .ready else { return false }
        return firstSubagent { $0.lifecycle == .background || $0.lifecycle == .running } != nil
    }

    var canSteer: Bool { isTurnRunning && agentInfo?.supportsSteering == true }

    /// "Send again" is available once a prompt was sent and the agent is idle.
    var canSendAgain: Bool { phase == .ready && lastSubmission != nil && !isChangingModel && !isPreparingPrompt }

    // MARK: - Lifecycle

    func startIfNeeded() { if phase == .idle { start() } }

    /// Uses the same installed-agent environment as chat, without switching
    /// this pane's provider or touching its conversation/configuration.
    func discoverModels(for target: ChatAgent) async throws -> ACPSessionConfig {
        guard let workingDirectory else { throw ChatAgentSetupIssue.noWorkingDirectory }
        return try await AgentModelDiscovery.load(agent: target, workingDirectory: workingDirectory, resolveLaunch: resolveLaunch)
    }

    func setWorkingDirectory(_ directory: String?) {
        guard directory != workingDirectory, !phase.isRunning else { return }
        workingDirectory = directory
        if phase == .needsSetup(.noWorkingDirectory) { phase = .idle }
    }

    /// Starts the agent, reloading this pane's previous session when the
    /// agent supports `session/load` and `resume` is true.
    func start(resume: Bool = true) {
        guard !phase.isRunning else { return }
        guard let workingDirectory else {
            phase = .needsSetup(.noWorkingDirectory)
            return
        }
        generation += 1
        let generation = generation
        phase = .starting
        lifecycleTask = Task { await launch(generation: generation, workingDirectory: workingDirectory, resume: resume) }
    }

    /// Stops the agent process. The transcript stays visible and the session
    /// ID stays saved, so `start()` can pick the conversation back up. An
    /// open turn ends as cancelled, open approvals as `.agentStopped`, and
    /// unsent steer or queued text returns to the draft.
    func shutDown() {
        resetAutoApprove()
        changingConfigOptionID = nil
        isPreparingPrompt = false
        finishOpenTurn(stopReason: "cancelled")
        record(transcript.stopAllSessions(stopReason: "cancelled", now: now()))
        stopOpenApprovals()
        returnUnsentTextToDraft()
        generation += 1
        lifecycleTask?.cancel()
        eventTask?.cancel()
        lifecycleTask = nil
        eventTask = nil
        barriers.close()
        rootSessionID = nil
        let connection = connection
        self.connection = nil
        if phase.isRunning { phase = .idle }
        Task { await connection?.terminate() }
    }

    func restart() {
        shutDown()
        phase = .idle
        start(resume: true)
    }

    /// Discards this pane's saved session and starts a fresh conversation.
    func startNewConversation() {
        shutDown()
        AgentChatPaneStore.setSessionID(nil, for: paneID, agent: agent, defaults: defaults)
        resetConversationState()
        phase = .idle
        start(resume: false)
    }

    func switchAgent(to newAgent: ChatAgent) {
        guard newAgent != agent else { return }
        pendingModel = nil
        shutDown()
        agent = newAgent
        AgentChatPaneStore.setAgent(newAgent, for: paneID, defaults: defaults)
        resetConversationState()
        phase = .idle
        start(resume: true)
    }

    // MARK: - Conversation

    func addAttachments(_ inputs: [AgentChatAttachmentInput]) {
        guard !inputs.isEmpty else { return }
        guard !isImportingAttachments && !isPreparingPrompt else { composerError = "Wait for the current attachments to finish loading."; return }
        guard attachments.count + inputs.count <= AgentChatAttachmentStore.maximumCount else {
            composerError = AgentChatAttachmentError.tooMany.localizedDescription
            return
        }
        composerError = nil
        isImportingAttachments = true
        let directory = attachmentDirectory
        let worker = Task.detached(priority: .userInitiated) {
            var imported: [AgentChatAttachment] = []
            var errors: [String] = []
            for input in inputs {
                do {
                    try Task.checkCancellation()
                    imported.append(try await AgentChatAttachmentStore.importMedia(input, into: directory))
                } catch is CancellationError { break } catch { errors.append(error.localizedDescription) }
            }
            return (imported, errors)
        }
        attachmentImportTask = Task { [weak self] in
            let (imported, errors) = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled else {
                for item in imported { AgentChatAttachmentStore.remove(item) }
                return
            }
            attachments.append(contentsOf: imported)
            composerError = errors.isEmpty ? nil : errors.map(redactInline).joined(separator: "\n")
            isImportingAttachments = false
            attachmentImportTask = nil
        }
    }

    func removeAttachment(id: UUID) {
        guard !isPreparingPrompt else { return }
        guard let item = attachments.first(where: { $0.id == id }) else { return }
        attachments.removeAll { $0.id == id }
        composerError = nil
        Task.detached { AgentChatAttachmentStore.remove(item) }
    }

    func clearComposerError() { composerError = nil }

    func removeAttachmentStorage() {
        attachmentImportTask?.cancel()
        let pending = attachmentImportTask
        attachmentImportTask = nil
        let directory = attachmentDirectory
        Task.detached {
            await pending?.value
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, connection != nil, rootSessionID != nil else { return }
        prepareAndSubmit(text: text, media: attachments, fromComposer: true)
    }

    /// Resends the last prompt's text and attachments; offered on a failed-turn notice.
    func sendAgain() {
        guard canSendAgain, connection != nil, let last = lastSubmission else { return }
        prepareAndSubmit(text: last.text, media: last.media, fromComposer: false)
    }

    /// Encodes attachments off the main actor, then submits. A composer send
    /// clears the draft and attachments; a resend leaves them alone.
    private func prepareAndSubmit(text: String, media: [AgentChatAttachment], fromComposer: Bool) {
        guard !media.isEmpty else { submit(text: text, media: [], blocks: [], fromComposer: fromComposer); return }
        let supportsImages = agentInfo?.supportsImages == true
        let generation = generation
        isPreparingPrompt = true
        composerError = nil
        Task {
            do {
                let blocks = try await Task.detached {
                    try media.map { try $0.promptContent(supportsImages: supportsImages) }
                }.value
                guard generation == self.generation else { return }
                isPreparingPrompt = false
                submit(text: text, media: media, blocks: blocks, fromComposer: fromComposer)
            } catch {
                guard generation == self.generation else { return }
                isPreparingPrompt = false
                composerError = "Could not prepare attachments: " + redactInline(error.localizedDescription)
            }
        }
    }

    private func submit(text: String, media: [AgentChatAttachment], blocks: [JSONValue], fromComposer: Bool) {
        guard phase == .ready, let connection, let rootSessionID else { return }
        if fromComposer {
            draft = ""
            attachments = []
        }
        composerError = nil
        sendAgainNoticeKey = nil
        // The first prompt after session/load ends the replay window.
        transcript.isReplaying = false
        transcript.appendUser(text, attachments: media)
        lastSubmission = (text, media)
        phase = .prompting
        isTurnOpen = true
        let barrier = barriers.makeToken()
        let generation = generation
        let agent = agent
        Task {
            do {
                let result = try await connection.request(
                    ACP.Method.prompt,
                    params: ACP.promptParams(sessionID: rootSessionID, text: text, attachments: blocks),
                    barrier: barrier
                )
                guard generation == self.generation, await barriers.wait(for: barrier), generation == self.generation
                else { return }
                recordUsage(result, agent: agent)
                let stopReason = result["stopReason"]?.stringValue.map { String($0.prefix(64)) }
                completeTurn(stopReason: stopReason, notice: Self.stopNotice(stopReason), failed: false)
            } catch let error as ACPRemoteError {
                guard generation == self.generation, await barriers.wait(for: barrier), generation == self.generation
                else { return }
                completeTurn(stopReason: nil, notice: redactInline(error.localizedDescription), failed: true)
            } catch {
                guard generation == self.generation else { return }
                // A closed connection is reported once, by `connectionEnded`,
                // which runs after the event loop drained every notification
                // the agent sent before it went away.
                if error is ACPConnectionError, await connection.closeReason != nil { return }
                guard generation == self.generation else { return }
                let notice = error is ACPConnectionError ? nil : redactInline(error.localizedDescription)
                completeTurn(stopReason: nil, notice: notice, failed: notice != nil)
            }
        }
    }

    /// Runs once the prompt's barrier was reached: every notification the
    /// agent sent before its response is already in the transcript.
    private func completeTurn(stopReason: String?, notice: String?, failed: Bool) {
        guard phase == .prompting else { return }
        if let notice {
            transcript.appendNotice(notice)
            if failed { sendAgainNoticeKey = transcript.items.last?.key }
        }
        finishOpenTurn(stopReason: stopReason)
        phase = .ready
        guard let queued = queuedPrompt else { return }
        queuedPrompt = nil
        if stopReason == "end_turn" {
            submit(text: queued, media: [], blocks: [], fromComposer: false)
        } else {
            restoreToDraft(queued)
        }
    }

    /// Asks the agent to stop the current turn. ACP requires answering any
    /// open permission request with `cancelled` first; those records end as
    /// `.agentStopped`.
    func cancelTurn() {
        guard phase == .prompting, let connection, let rootSessionID else { return }
        let open = permissionQueue
        permissionQueue.removeAll()
        for request in open { resolveApproval(request.requestID, .agentStopped) }
        Task {
            for request in open {
                await connection.respond(to: request.requestID, result: ACP.permissionResult(optionID: nil))
            }
            await connection.notify(ACP.Method.cancel, params: ACP.cancelParams(sessionID: rootSessionID))
        }
    }

    /// Answers with the agent's option. The record is resolved only once the
    /// answer was written to a live connection; `nil` is "Cancel Request".
    func answerPermission(_ request: ACPPermissionRequest, optionID: String?) {
        guard let optionID else {
            dismissPermission(request)
            return
        }
        guard let option = request.options.first(where: { $0.id == optionID }) else { return }
        deliver(request, result: ACP.permissionResult(optionID: optionID), decision: .chose(
            optionID: option.id, name: option.name, allows: option.kind?.allows ?? false
        ))
    }

    /// "Cancel Request": answers `cancelled` and records `.cancelledByUser`.
    func dismissPermission(_ request: ACPPermissionRequest) {
        deliver(request, result: ACP.permissionResult(optionID: nil), decision: .cancelledByUser)
    }

    private func deliver(_ request: ACPPermissionRequest, result: JSONValue, decision: Decision, autoApproved: Bool = false) {
        guard permissionQueue.contains(request), let connection else { return }
        permissionQueue.removeAll { $0.requestID == request.requestID }
        let generation = generation
        Task {
            do {
                try await connection.respondConfirmed(to: request.requestID, result: result)
            } catch {
                // Never reached the agent: the closing connection resolves
                // the record as `.agentStopped`.
                return
            }
            guard generation == self.generation else { return }
            resolveApproval(request.requestID, decision, autoApproved: autoApproved)
        }
    }

    /// Injects `text` into the running turn (`_session/steering`), never with
    /// attachments. Injected → "Sent to running turn"; promptRequired → queued
    /// (sent now if the turn already ended); failure, error, or `steerTimeout`
    /// → the text returns to the draft with a composerError.
    func steer(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, canSteer, pendingSteer == nil, let connection, let rootSessionID else { return }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
        composerError = nil
        pendingSteer = text
        let generation = generation
        let timeout = steerTimeout
        Task {
            let outcome: ACPSteerOutcome
            do {
                outcome = ACPSteerOutcome(try await connection.request(
                    ACP.Method.steer, params: ACP.steerParams(sessionID: rootSessionID, text: text), timeout: timeout
                ))
            } catch ACPConnectionError.timedOut {
                outcome = .failed("The agent did not answer in time.")
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            guard generation == self.generation, pendingSteer == text else { return }
            pendingSteer = nil
            switch outcome {
            case .injected:
                transcript.appendUser(text)
                if let key = transcript.items.last?.key { steeredItemKeys.insert(key) }
            case .promptRequired where phase == .ready && lastStopReason == "end_turn":
                // The turn ended normally before the steer arrived: it is the
                // queued prompt, flushed now. Any other ending restores it.
                submit(text: text, media: [], blocks: [], fromComposer: false)
            case .promptRequired where isTurnRunning:
                queuedPrompt = queuedPrompt.map { $0 + "\n\n" + text } ?? text
            case .promptRequired:
                restoreToDraft(text)
            case .failed(let reason):
                restoreToDraft(text)
                composerError = "Could not steer the running turn: " + Self.redactedLine(reason, limit: 200)
            }
        }
    }

    /// Fills the single queued slot (appending to text already queued); sent
    /// only after stopReason end_turn, otherwise restored to the draft.
    /// Cleared on shutDown, switchAgent, a new conversation, or a new session.
    func queueForNextTurn(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isTurnRunning else { return }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
        queuedPrompt = queuedPrompt.map { $0 + "\n\n" + text } ?? text
    }

    func clearQueuedPrompt() { queuedPrompt = nil }

    /// Moves the queued text back into the draft for editing.
    func editQueuedPrompt() {
        guard let queued = queuedPrompt else { return }
        queuedPrompt = nil
        restoreToDraft(queued)
    }

    /// "Ask to retry…": pre-fills the draft (redacted) for the failed step; never sends.
    func prefillAskToRetry(stepKey: String) {
        guard let item = transcriptItem(forKey: stepKey), case .tool(let tool) = item.content else { return }
        let verb = verbForTool(tool, input: transcript.stepDetails[stepKey]?.rawInput?.value)
        var text = "The step “\(verb.settled)”"
        if item.sessionKey != "root", let card = subagentCard(item.sessionKey) {
            text += " in the subagent “\(Self.redactedLine(card.title, limit: 256))”"
        }
        text += " failed"
        if let summary = tool.errorSummary.map({ Self.redactedLine($0, limit: 200) }), !summary.isEmpty {
            text += " (\(summary))"
        }
        restoreToDraft(redactInline(text + ". Please retry it."), ahead: false)
    }

    /// "Ask to continue…": pre-fills the draft (redacted) for the failed agent; never sends.
    func prefillAskToContinue(childSessionID: String) {
        guard let card = subagentCard(childSessionID) else { return }
        let name = Self.redactedLine(card.title, limit: 256)
        restoreToDraft(redactInline("The subagent “\(name)” stopped before finishing. Please continue its task."), ahead: false)
    }

    // MARK: - Internals

    private func launch(generation: Int, workingDirectory: String, resume: Bool) async {
        let resolution = await resolveLaunch(agent, workingDirectory)
        guard generation == self.generation else { return }

        let configuration: ACPConnection.LaunchConfiguration
        switch resolution {
        case .failure(let issue):
            phase = .needsSetup(issue)
            return
        case .success(let resolved):
            configuration = resolved
        }

        let connection = ACPConnection()
        self.connection = connection
        barriers.reopen()
        do {
            try await connection.start(configuration)
            eventTask = Task { [weak self] in
                for await event in connection.incoming {
                    self?.handle(event, generation: generation)
                }
                await self?.connectionEnded(connection, generation: generation)
            }

            let initialized = try await connection.request(
                ACP.Method.initialize, params: ACP.initializeParams(clientVersion: Self.clientVersion), timeout: .seconds(30)
            )
            let info = ACPAgentInfo(initialized)
            guard generation == self.generation else { return }
            agentInfo = info

            var sessionResult = try await loadSavedSession(
                connection, info: info, workingDirectory: workingDirectory, resume: resume, generation: generation
            )
            guard generation == self.generation else { return }
            let resumed = sessionResult != nil
            if sessionResult == nil {
                let hadTranscript = !transcript.items.isEmpty
                let result = try await newSession(connection, info: info, workingDirectory: workingDirectory)
                guard let sessionID = result["sessionId"]?.stringValue else {
                    throw ACPRemoteError(code: -32603, message: "The agent did not return a session ID.")
                }
                guard generation == self.generation else { return }
                rootSessionID = sessionID
                transcript.isReplaying = false
                queuedPrompt = nil
                AgentChatPaneStore.setSessionID(sessionID, for: paneID, agent: agent, defaults: defaults)
                if hadTranscript {
                    transcript.appendNotice("Started a new session. Earlier messages are not in the agent's context.")
                }
                sessionResult = result
            }
            guard generation == self.generation else { return }
            if resumed {
                // A session/load answer may omit models and configOptions (or
                // carry only some parts): it patches the configuration the
                // replay or an earlier run reported instead of wiping it.
                applyConfiguration(resumedConfiguration(sessionResult))
            } else {
                applyConfiguration(sessionResult.flatMap(ACPSessionConfig.init))
            }
            phase = .ready
            applyPendingModel()
        } catch let issue as ChatAgentSetupIssue {
            guard generation == self.generation else { return }
            phase = .needsSetup(issue)
            await connection.terminate()
        } catch {
            guard generation == self.generation else { return }
            phase = .failed(redactInline(error.localizedDescription))
            await connection.terminate()
        }
    }

    /// Replays the pane's previous session into the transcript. Returns nil
    /// when there is nothing to load or the agent rejects it. The result is
    /// returned only after the replay before the response was applied.
    private func loadSavedSession(
        _ connection: ACPConnection,
        info: ACPAgentInfo,
        workingDirectory: String,
        resume: Bool,
        generation: Int
    ) async throws -> JSONValue? {
        guard resume, info.canLoadSession,
              let saved = AgentChatPaneStore.sessionID(for: paneID, agent: agent, defaults: defaults) else { return nil }
        // The agent replays history as session/update notifications before it
        // answers, so the root session must be known before the request.
        transcript.reset()
        transcript.isReplaying = true
        rootSessionID = saved
        let barrier = barriers.makeToken()
        do {
            let result = try await connection.request(
                ACP.Method.loadSession,
                params: ACP.loadSessionParams(sessionID: saved, cwd: workingDirectory),
                timeout: .seconds(120),
                barrier: barrier
            )
            guard generation == self.generation, await barriers.wait(for: barrier) else {
                let reason = await connection.closeReason
                throw reason ?? ACPConnectionError.notRunning
            }
            return result
        } catch let error as ACPConnectionError {
            throw error
        } catch {
            // Apply whatever the agent replayed before rejecting, then drop it.
            if error is ACPRemoteError, generation == self.generation, await !barriers.wait(for: barrier) {
                let reason = await connection.closeReason
                throw reason ?? ACPConnectionError.notRunning
            }
            guard generation == self.generation else { return nil }
            rootSessionID = nil
            transcript.reset()
            AgentChatPaneStore.setSessionID(nil, for: paneID, agent: agent, defaults: defaults)
            return nil
        }
    }

    /// Creates a session, completing a silent sign-in (such as Grok's cached
    /// token) if the agent asks for one. Interactive sign-in is left to the
    /// user's terminal: Cockpit never opens a browser or switches billing.
    private func newSession(
        _ connection: ACPConnection,
        info: ACPAgentInfo,
        workingDirectory: String
    ) async throws -> JSONValue {
        let params = ACP.newSessionParams(cwd: workingDirectory)
        do {
            return try await connection.request(ACP.Method.newSession, params: params, timeout: .seconds(120))
        } catch let error as ACPRemoteError where error.code == ACPRemoteError.authRequired {
            guard let method = info.silentAuthMethodID else {
                throw ChatAgentSetupIssue.loginRequired(command: agent.loginCommand)
            }
            _ = try await connection.request(
                ACP.Method.authenticate,
                params: ["methodId": .string(method)],
                timeout: .seconds(60)
            )
            return try await connection.request(ACP.Method.newSession, params: params, timeout: .seconds(120))
        }
    }

    private func handle(_ event: ACPIncoming, generation: Int) {
        guard generation == self.generation else { return }
        switch event {
        case .barrier(let token):
            log(.barrierReached(token: token))
            barriers.reach(token)
        case .notification(let method, let params):
            if method == ACP.Method.cancelRequest {
                withdrawPermission(params["requestId"] ?? params["id"])
                return
            }
            guard method == ACP.Method.update,
                  let rootSessionID,
                  let notification = ACP.parseSessionUpdate(params) else { return }
            if notification.sessionID == rootSessionID {
                switch notification.update {
                case .context(let usage): context = usage
                case .configuration, .currentModel, .currentMode: applyConfigurationUpdate(notification.update)
                default: break
                }
            }
            record(transcript.apply(notification, rootSessionID: rootSessionID, now: now()))
        case .request(let id, let method, let params):
            if method == ACP.Method.requestPermission {
                receivePermission(id: id, params: params)
            } else {
                // Cockpit advertises no fs/terminal capabilities, so agents
                // should not send these; answer rather than leave them hanging.
                let connection = connection
                Task {
                    await connection?.respond(
                        to: id,
                        error: ACPRemoteError(code: ACPRemoteError.methodNotFound, message: "Cockpit does not support \(method)")
                    )
                }
            }
        }
    }

    /// Queues and records a permission request. Malformed or overflowing
    /// requests are answered `cancelled` and never recorded; a request that
    /// reuses an open id is ignored, since answering it would answer both.
    private func receivePermission(id: JSONValue, params: JSONValue) {
        guard openApprovals[id] == nil else { return }
        guard let request = ACPPermissionRequest(requestID: id, params: params),
              permissionQueue.count < Self.maximumPendingPermissions else {
            let connection = connection
            Task { await connection?.respond(to: id, result: ACP.permissionResult(optionID: nil)) }
            return
        }
        permissionQueue.append(request)
        openApprovals[id] = request.sessionID
        let name = agentName(forSession: request.sessionID)
        transcript.recordApproval(request, agentName: name, now: now())
        log(.approvalRecorded(requestID: id, agentName: name))
        if isAutoApproveEnabled { autoApprove(request) }
    }

    /// `$/cancel_request`: the agent withdrew an open request. The id must
    /// match exactly (a string id never matches a number). ACP answers a
    /// cancelled request with the `-32800` error.
    private func withdrawPermission(_ requestID: JSONValue?) {
        guard let requestID, let index = permissionQueue.firstIndex(where: { $0.requestID == requestID }) else { return }
        permissionQueue.remove(at: index)
        resolveApproval(requestID, .withdrawnByAgent)
        let connection = connection
        Task {
            await connection?.respond(
                to: requestID,
                error: ACPRemoteError(code: ACPRemoteError.requestCancelled, message: "Request cancelled")
            )
        }
    }

    /// The agent that asked: the root agent, a subagent card's title, or
    /// "untracked subagent".
    private func agentName(forSession sessionID: String) -> String {
        if sessionID == rootSessionID { return agent.displayName }
        guard let card = subagentCard(sessionID) else { return Self.untrackedSubagentName }
        return Self.redactedLine(card.title, limit: 256)
    }

    private func resolveApproval(_ requestID: JSONValue, _ decision: Decision, autoApproved: Bool = false) {
        guard let sessionID = openApprovals.removeValue(forKey: requestID) else { return }
        transcript.resolveApproval(requestID: requestID, sessionID: sessionID, decision: decision, autoApproved: autoApproved)
        log(.approvalResolved(requestID: requestID, decision: decision))
        if autoApproved { log(.approvalAutoApproved(requestID: requestID)) }
    }

    /// Every unresolved record, open or being answered, ends as `.agentStopped`.
    private func stopOpenApprovals() {
        permissionQueue.removeAll()
        for requestID in Array(openApprovals.keys) { resolveApproval(requestID, .agentStopped) }
    }

    private func connectionEnded(_ connection: ACPConnection, generation: Int) async {
        // However it closed, the agent and its subprocesses must not outlive
        // the connection; terminate() is idempotent and escalates to SIGKILL.
        Task { await connection.terminate() }
        let reason = await connection.closeReason
        guard generation == self.generation else { return }
        resetAutoApprove()
        barriers.close()
        finishOpenTurn(stopReason: nil)
        // Background subagents died with the process.
        record(transcript.stopAllSessions(stopReason: nil, now: now()))
        stopOpenApprovals()
        returnUnsentTextToDraft()
        self.connection = nil
        rootSessionID = nil
        if reason == .closedByClient { return }
        phase = .failed(redactInline(reason?.localizedDescription ?? "The agent stopped."))
    }

    // MARK: Turn bookkeeping

    private func finishOpenTurn(stopReason: String?) {
        guard isTurnOpen else { return }
        isTurnOpen = false
        lastStopReason = stopReason
        record(transcript.finishTurn(stopReason: stopReason, now: now()))
        log(.turnFinished(stopReason: stopReason))
    }

    private func record(_ events: [AgentActivityEvent]) {
        guard !events.isEmpty else { return }
        recentEvents = (recentEvents + events).suffix(Self.maximumRecentEvents)
        eventSequence += events.count
    }

    private func log(_ entry: Diagnostic) {
        diagnostics = (diagnostics + [entry]).suffix(Self.maximumRecentEvents)
    }

    // MARK: Draft and transcript lookups

    /// Puts `text` back in the draft, ahead of (restored) or after
    /// (prefilled) whatever the user has typed since.
    private func restoreToDraft(_ text: String, ahead: Bool = true) {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { draft = text; return }
        draft = ahead ? text + "\n\n" + draft : draft + "\n\n" + text
    }

    /// Unsent steer text and the queued prompt go back to the draft rather
    /// than being lost or sent to a different session.
    private func returnUnsentTextToDraft() {
        if let pendingSteer {
            self.pendingSteer = nil
            restoreToDraft(pendingSteer)
        }
        if let queuedPrompt {
            self.queuedPrompt = nil
            restoreToDraft(queuedPrompt)
        }
    }

    /// The first non-nil `match` over every item, root list first, without
    /// building intermediate arrays (`hasBackgroundAgents` is read by views).
    private func firstItem<T>(_ match: (AgentChatItem) -> T?) -> T? {
        for item in transcript.items { if let found = match(item) { return found } }
        for list in transcript.childItems.values { for item in list { if let found = match(item) { return found } } }
        return nil
    }

    private func firstSubagent(where predicate: (AgentChatItem.Subagent) -> Bool) -> AgentChatItem.Subagent? {
        firstItem { item in if case .subagent(let card) = item.content, predicate(card) { card } else { nil } }
    }

    private func subagentCard(_ childSessionID: String) -> AgentChatItem.Subagent? {
        firstSubagent { $0.childSessionID == childSessionID }
    }

    private func transcriptItem(forKey key: String) -> AgentChatItem? { firstItem { $0.key == key ? $0 : nil } }

    /// One redacted line of at most `limit` characters. Redaction runs
    /// before the cut so truncation can never split a secret into a prefix
    /// the patterns no longer match; the 4 KiB pre-bound keeps it cheap.
    private static func redactedLine(_ text: String, limit: Int) -> String {
        let line = String(text.prefix(4_096)).split(whereSeparator: \.isNewline).joined(separator: " ")
        return String(redactInline(line).prefix(limit)).trimmingCharacters(in: .whitespaces)
    }

    private func recordUsage(_ result: JSONValue, agent: ChatAgent) {
        guard let raw = ACPTurnUsage(promptResult: result),
              let usage = NormalizedTurnUsage(raw, inputIncludesCacheReads: agent.inputTokensIncludeCacheReads)
        else { return }
        lastTurnUsage = usage
        sessionUsage = sessionUsage.map { $0 + usage } ?? usage
    }

    private func resetConversationState() {
        transcript.reset()
        agentInfo = nil
        config = nil
        changingConfigOptionID = nil
        composerError = nil
        context = nil
        lastTurnUsage = nil
        sessionUsage = nil
        queuedPrompt = nil
        steeredItemKeys = []
        sendAgainNoticeKey = nil
        lastSubmission = nil
    }

    // MARK: Auto-approve

    /// The switch is offered only while a session is up (ready or prompting).
    var canAutoApprove: Bool { phase == .ready || phase == .prompting }

    /// Takes effect at once for every later request; no confirmation.
    func disableAutoApprove() { isAutoApproveEnabled = false }

    /// Asks first (`confirmAutoApprove`; Cancel keeps it off), then answers
    /// every request already waiting. A session that stopped or changed while
    /// the sheet was up keeps it off.
    func enableAutoApprove() async {
        guard canAutoApprove, !isAutoApproveEnabled, !isConfirmingAutoApprove else { return }
        let generation = generation
        isConfirmingAutoApprove = true
        let confirmed = await confirmAutoApprove(agent)
        guard generation == self.generation else { return }
        isConfirmingAutoApprove = false
        guard confirmed, canAutoApprove else { return }
        isAutoApproveEnabled = true
        for request in permissionQueue { autoApprove(request) }
    }

    /// The option auto-approve may choose: the agent's `allow_once`, never
    /// `allow_always` or a reject. A `switch_mode` request (leaving plan mode)
    /// or an `exit-plan` option is a decision about the agent's mode, so it
    /// always goes to the user, as does a request with no allow-once option.
    nonisolated static func autoApproveOption(for request: ACPPermissionRequest) -> ACPPermissionRequest.Option? {
        guard request.toolKind != .switchMode else { return nil }
        return request.options.first { option in
            option.kind == .allowOnce && !ApprovalCardView.isModeChangeOptionID(option.id)
        }
    }

    /// Answers `request` with its allow-once option, recorded as auto-approved;
    /// a request without one stays queued for the approval card.
    private func autoApprove(_ request: ACPPermissionRequest) {
        guard let option = Self.autoApproveOption(for: request) else { return }
        deliver(request, result: ACP.permissionResult(optionID: option.id),
                decision: .chose(optionID: option.id, name: option.name, allows: true), autoApproved: true)
    }

    private func resetAutoApprove() {
        isAutoApproveEnabled = false
        isConfirmingAutoApprove = false
    }

    private static var clientVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
}
