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
    private(set) var modelName: String?
    private(set) var context: ACPContextUsage?
    private(set) var lastTurnUsage: NormalizedTurnUsage?
    private(set) var sessionUsage: NormalizedTurnUsage?
    var draft = ""

    @ObservationIgnored private var connection: ACPConnection?
    @ObservationIgnored private var rootSessionID: String?
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let resolveLaunch: LaunchResolver

    init(
        paneID: UUID,
        agent: ChatAgent,
        workingDirectory: String?,
        defaults: UserDefaults = .standard,
        resolveLaunch: @escaping LaunchResolver = AgentChatSession.loginShellLaunchResolver
    ) {
        self.paneID = paneID
        self.agent = agent
        self.workingDirectory = workingDirectory
        self.defaults = defaults
        self.resolveLaunch = resolveLaunch
    }

    var pendingPermission: ACPPermissionRequest? { permissionQueue.first }

    var canSend: Bool {
        phase == .ready && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

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

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .ready, !text.isEmpty, let connection, let rootSessionID else { return }
        draft = ""
        transcript.appendUser(text)
        phase = .prompting
        let generation = generation
        let agent = agent
        Task {
            do {
                let result = try await connection.request(
                    ACP.Method.prompt,
                    params: ACP.promptParams(sessionID: rootSessionID, text: text)
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
            modelName = sessionResult.flatMap(ACPSessionResult.modelName)
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
        modelName = nil
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
        sessions.removeValue(forKey: paneID)?.shutDown()
        AgentChatPaneStore.remove(paneID: paneID)
    }
}
