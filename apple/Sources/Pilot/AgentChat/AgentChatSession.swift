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

    /// Requests beyond this are answered `cancelled` rather than queued.
    static let maximumPendingPermissions = 32

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
    private(set) var modelState: ACPModelState?
    var modelName: String? { modelState?.currentName }
    private(set) var isChangingModel = false
    private(set) var attachments: [AgentChatAttachment] = []
    private(set) var isImportingAttachments = false
    private(set) var isPreparingPrompt = false
    private(set) var composerError: String?
    private(set) var context: ACPContextUsage?
    private(set) var lastTurnUsage: NormalizedTurnUsage?
    private(set) var sessionUsage: NormalizedTurnUsage?
    /// One editable, removable slot sent after the turn ends with end_turn.
    private(set) var queuedPrompt: String?
    /// Diagnostics and tests: the latest transcript events and their count.
    @ObservationIgnored private(set) var recentEvents: [AgentActivityEvent] = []
    private(set) var eventSequence = 0
    var draft = ""

    @ObservationIgnored private var connection: ACPConnection?
    @ObservationIgnored private var rootSessionID: String?
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let resolveLaunch: LaunchResolver
    @ObservationIgnored private let attachmentDirectory: URL
    @ObservationIgnored private var attachmentImportTask: Task<Void, Never>?
    @ObservationIgnored private let now: @Sendable () -> Date

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
        // WP2: implement
        false
    }

    var canSteer: Bool { isTurnRunning && agentInfo?.supportsSteering == true }

    // MARK: - Lifecycle

    func startIfNeeded() {
        if phase == .idle { start() }
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
    /// ID stays saved, so `start()` can pick the conversation back up.
    func shutDown() {
        isChangingModel = false
        isPreparingPrompt = false
        generation += 1
        lifecycleTask?.cancel()
        eventTask?.cancel()
        lifecycleTask = nil
        eventTask = nil
        permissionQueue.removeAll()
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
            composerError = errors.isEmpty ? nil : errors.joined(separator: "\n")
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

    func selectModel(_ id: String) {
        guard phase == .ready, !isChangingModel, !isPreparingPrompt, let connection, let rootSessionID,
              let state = modelState, id != state.currentID,
              let request = state.request(sessionID: rootSessionID, modelID: id) else { return }
        isChangingModel = true
        composerError = nil
        let generation = generation
        Task {
            do {
                let result = try await connection.request(request.method, params: request.params, timeout: .seconds(30))
                guard generation == self.generation else { return }
                if let updated = ACPModelState(result) {
                    modelState = updated
                } else if state.selection == .legacy {
                    modelState?.currentID = id
                } else { composerError = "The agent did not confirm the selected model. Please try again." }
            } catch {
                guard generation == self.generation else { return }
                composerError = "Could not change model: \(error.localizedDescription)"
            }
            if generation == self.generation { isChangingModel = false }
        }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, connection != nil, rootSessionID != nil else { return }
        let media = attachments
        guard !media.isEmpty else { submit(text: text, media: [], blocks: []); return }
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
                submit(text: text, media: media, blocks: blocks)
            } catch {
                guard generation == self.generation else { return }
                isPreparingPrompt = false
                composerError = "Could not prepare attachments: \(error.localizedDescription)"
            }
        }
    }

    private func submit(text: String, media: [AgentChatAttachment], blocks: [JSONValue]) {
        guard phase == .ready, let connection, let rootSessionID else { return }
        draft = ""
        attachments = []
        composerError = nil
        transcript.appendUser(text, attachments: media)
        phase = .prompting
        let generation = generation
        let agent = agent
        Task {
            do {
                let result = try await connection.request(
                    ACP.Method.prompt,
                    params: ACP.promptParams(sessionID: rootSessionID, text: text, attachments: blocks)
                )
                guard generation == self.generation else { return }
                recordUsage(result, agent: agent)
                if let notice = Self.stopNotice(result["stopReason"]?.stringValue) {
                    transcript.appendNotice(notice)
                }
            } catch {
                guard generation == self.generation else { return }
                // A closed connection is reported once, by `connectionEnded`.
                if !(error is ACPConnectionError) { transcript.appendNotice(error.localizedDescription) }
            }
            if generation == self.generation, phase == .prompting {
                transcript.finishUnreportedSubagents()
                phase = .ready
            }
        }
    }

    /// Asks the agent to stop the current turn. ACP requires answering any
    /// open permission request with `cancelled` first.
    func cancelTurn() {
        guard phase == .prompting, let connection, let rootSessionID else { return }
        let open = permissionQueue
        permissionQueue.removeAll()
        Task {
            for request in open {
                await connection.respond(to: request.requestID, result: ACP.permissionResult(optionID: nil))
            }
            await connection.notify(ACP.Method.cancel, params: ACP.cancelParams(sessionID: rootSessionID))
        }
    }

    func answerPermission(_ request: ACPPermissionRequest, optionID: String?) {
        guard permissionQueue.contains(request) else { return }
        permissionQueue.removeAll { $0.requestID == request.requestID }
        let connection = connection
        Task { await connection?.respond(to: request.requestID, result: ACP.permissionResult(optionID: optionID)) }
    }

    /// Injects `text` into the running turn (`_session/steering`). Injected →
    /// "Sent to running turn"; promptRequired → queued; failure, a 15 s
    /// timeout, or an error returns the text to the draft with a composerError.
    /// Attachments are not sent while steering.
    func steer(_ text: String) {
        // WP2: implement
    }

    /// Fills the single queued slot; sent only after stopReason end_turn,
    /// otherwise restored to the draft. Cleared on shutDown, switchAgent, and
    /// a new conversation.
    func queueForNextTurn(_ text: String) {
        // WP2: implement
    }

    /// "Ask to retry…": pre-fills the draft (redacted) for the failed step; never sends.
    func prefillAskToRetry(stepKey: String) {
        // WP2: implement
    }

    /// "Ask to continue…": pre-fills the draft (redacted) for the failed agent; never sends.
    func prefillAskToContinue(childSessionID: String) {
        // WP2: implement
    }

    /// Resends the last prompt's text and attachments; offered on a failed-turn notice.
    func sendAgain() {
        // WP2: implement
    }

    /// "Cancel Request": answers `cancelled` and records `.cancelledByUser`.
    func dismissPermission(_ request: ACPPermissionRequest) {
        // WP2: implement (record .cancelledByUser after respond succeeds)
        answerPermission(request, optionID: nil)
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
        do {
            try await connection.start(configuration)
            eventTask = Task { [weak self] in
                for await event in connection.incoming {
                    self?.handle(event, generation: generation)
                }
                await self?.connectionEnded(connection, generation: generation)
            }

            let info = ACPAgentInfo(try await connection.request(
                ACP.Method.initialize,
                params: ACP.initializeParams(clientVersion: Self.clientVersion),
                timeout: .seconds(30)
            ))
            guard generation == self.generation else { return }
            agentInfo = info

            var sessionResult = try await loadSavedSession(
                connection, info: info, workingDirectory: workingDirectory, resume: resume
            )
            if sessionResult == nil {
                let hadTranscript = !transcript.items.isEmpty
                let result = try await newSession(connection, info: info, workingDirectory: workingDirectory)
                guard let sessionID = result["sessionId"]?.stringValue else {
                    throw ACPRemoteError(code: -32603, message: "The agent did not return a session ID.")
                }
                guard generation == self.generation else { return }
                rootSessionID = sessionID
                AgentChatPaneStore.setSessionID(sessionID, for: paneID, agent: agent, defaults: defaults)
                if hadTranscript {
                    transcript.appendNotice("Started a new session. Earlier messages are not in the agent's context.")
                }
                sessionResult = result
            }
            guard generation == self.generation else { return }
            modelState = sessionResult.flatMap(ACPModelState.init)
            phase = .ready
        } catch let issue as ChatAgentSetupIssue {
            guard generation == self.generation else { return }
            phase = .needsSetup(issue)
            await connection.terminate()
        } catch {
            guard generation == self.generation else { return }
            phase = .failed(error.localizedDescription)
            await connection.terminate()
        }
    }

    /// Replays the pane's previous session into the transcript. Returns nil
    /// when there is nothing to load or the agent rejects it.
    private func loadSavedSession(
        _ connection: ACPConnection,
        info: ACPAgentInfo,
        workingDirectory: String,
        resume: Bool
    ) async throws -> JSONValue? {
        guard resume, info.canLoadSession,
              let saved = AgentChatPaneStore.sessionID(for: paneID, agent: agent, defaults: defaults) else { return nil }
        // The agent replays history as session/update notifications before it
        // answers, so the root session must be known before the request.
        transcript.reset()
        rootSessionID = saved
        do {
            return try await connection.request(
                ACP.Method.loadSession,
                params: ACP.loadSessionParams(sessionID: saved, cwd: workingDirectory),
                timeout: .seconds(120)
            )
        } catch let error as ACPConnectionError {
            throw error
        } catch {
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
        case .notification(let method, let params):
            guard method == ACP.Method.update,
                  let rootSessionID,
                  let notification = ACP.parseSessionUpdate(params) else { return }
            if notification.sessionID == rootSessionID, case .context(let usage) = notification.update {
                context = usage
            }
            if notification.sessionID == rootSessionID {
                switch notification.update {
                case .modelConfiguration(let state):
                    if state != nil || modelState?.selection != .legacy { modelState = state }
                case .currentModel(let id): modelState?.currentID = id
                default: break
                }
            }
            transcript.apply(notification, rootSessionID: rootSessionID)
        case .request(let id, let method, let params):
            let connection = connection
            if method == ACP.Method.requestPermission,
               let request = ACPPermissionRequest(requestID: id, params: params),
               permissionQueue.count < Self.maximumPendingPermissions {
                permissionQueue.append(request)
            } else if method == ACP.Method.requestPermission {
                Task { await connection?.respond(to: id, result: ACP.permissionResult(optionID: nil)) }
            } else {
                // Cockpit advertises no fs/terminal capabilities, so agents
                // should not send these; answer rather than leave them hanging.
                Task {
                    await connection?.respond(
                        to: id,
                        error: ACPRemoteError(code: ACPRemoteError.methodNotFound, message: "Cockpit does not support \(method)")
                    )
                }
            }
        }
    }

    private func connectionEnded(_ connection: ACPConnection, generation: Int) async {
        let reason = await connection.closeReason
        guard generation == self.generation else { return }
        permissionQueue.removeAll()
        self.connection = nil
        rootSessionID = nil
        if reason == .closedByClient { return }
        phase = .failed(reason?.localizedDescription ?? "The agent stopped.")
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
        modelState = nil
        isChangingModel = false
        composerError = nil
        context = nil
        lastTurnUsage = nil
        sessionUsage = nil
    }

    static func stopNotice(_ stopReason: String?) -> String? {
        switch stopReason {
        case "max_tokens": "Stopped: the response reached the model's output limit."
        case "max_turn_requests": "Stopped: the turn reached its request limit."
        case "refusal": "The agent declined to continue."
        case "cancelled": "Stopped."
        default: nil
        }
    }

    private static var clientVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
}

// MARK: - Persistence

/// Per-pane agent choice and ACP session IDs. Like `TerminalFastCommandStore`,
/// this is UI state kept in UUID-keyed preferences so adding it does not
/// migrate the versioned SwiftData store.
enum AgentChatPaneStore {
    private static let agentPrefix = "agentChat.agent."
    private static let sessionPrefix = "agentChat.session."
    static let lastAgentKey = "agentChat.lastAgent"

    static func agent(for paneID: UUID, defaults: UserDefaults = .standard) -> ChatAgent {
        defaults.string(forKey: agentPrefix + key(paneID)).flatMap(ChatAgent.init(rawValue:))
            ?? lastUsedAgent(defaults: defaults)
    }

    static func lastUsedAgent(defaults: UserDefaults = .standard) -> ChatAgent {
        defaults.string(forKey: lastAgentKey).flatMap(ChatAgent.init(rawValue:)) ?? .claude
    }

    static func setAgent(_ agent: ChatAgent, for paneID: UUID, defaults: UserDefaults = .standard) {
        defaults.set(agent.rawValue, forKey: agentPrefix + key(paneID))
        defaults.set(agent.rawValue, forKey: lastAgentKey)
    }

    static func sessionID(for paneID: UUID, agent: ChatAgent, defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: sessionKey(paneID, agent))
    }

    static func setSessionID(_ sessionID: String?, for paneID: UUID, agent: ChatAgent, defaults: UserDefaults = .standard) {
        if let sessionID {
            defaults.set(sessionID, forKey: sessionKey(paneID, agent))
        } else {
            defaults.removeObject(forKey: sessionKey(paneID, agent))
        }
    }

    static func remove(paneID: UUID, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: agentPrefix + key(paneID))
        for agent in ChatAgent.allCases {
            defaults.removeObject(forKey: sessionKey(paneID, agent))
        }
    }

    private static func key(_ paneID: UUID) -> String { paneID.uuidString.lowercased() }

    private static func sessionKey(_ paneID: UUID, _ agent: ChatAgent) -> String {
        sessionPrefix + agent.rawValue + "." + key(paneID)
    }
}

// MARK: - Registry

/// Owns each agent chat pane's session for the life of the pane, so switching
/// workspaces or tabs never restarts an agent mid-turn.
@MainActor
@Observable
final class AgentChatRegistry {
    static let shared = AgentChatRegistry()

    private var sessions: [UUID: AgentChatSession] = [:]

    /// Safe to call from a view body: it never mutates an existing session.
    /// The pane applies root-folder changes from its `.task`.
    func session(for paneID: UUID, workingDirectory: String?) -> AgentChatSession {
        if let existing = sessions[paneID] { return existing }
        let session = AgentChatSession(
            paneID: paneID,
            agent: AgentChatPaneStore.agent(for: paneID),
            workingDirectory: workingDirectory
        )
        sessions[paneID] = session
        return session
    }

    func existingSession(for paneID: UUID) -> AgentChatSession? {
        sessions[paneID]
    }

    /// Called when the pane is deleted: stops the agent and forgets the
    /// pane's preferences. The agent's own session history is left alone.
    func remove(paneID: UUID) {
        let session = sessions.removeValue(forKey: paneID)
        session?.shutDown()
        if let session {
            session.removeAttachmentStorage()
        } else {
            let directory = AgentChatAttachmentStore.directory(paneID: paneID)
            Task.detached { try? FileManager.default.removeItem(at: directory) }
        }
        AgentChatPaneStore.remove(paneID: paneID)
    }
}
