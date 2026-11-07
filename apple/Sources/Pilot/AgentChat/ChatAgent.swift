import Foundation
import Observation

/// A coding agent the chat pane can drive over the Agent Client Protocol.
///
/// Cursor, Grok, and Kimi speak ACP natively. Claude Code and Codex speak it through the
/// ACP project's adapters, which wrap the Claude Agent SDK and `codex
/// app-server` and are pointed at the user's installed CLI so a chat session
/// behaves — and caches — like that CLI's TUI.
enum ChatAgent: String, CaseIterable, Identifiable, Sendable {
    case claude
    case cursor
    case codex
    case kimi
    case grok

    var id: String { rawValue }

    var provider: AgenticProvider {
        switch self {
        case .claude: .claude
        case .cursor: .cursor
        case .codex: .codex
        case .kimi: .kimi
        case .grok: .grok
        }
    }

    var displayName: String { provider.displayName }

    struct LaunchPlan: Equatable, Sendable {
        /// The agent CLI an adapter drives, and the variable that points the
        /// adapter at it instead of the adapter's bundled copy.
        struct WrappedCLI: Equatable, Sendable {
            var name: String
            var environmentKey: String
            var installCommand: String
        }

        /// Executable looked up on the user's login-shell PATH.
        var executableName: String
        var arguments: [String]
        var wrappedCLI: WrappedCLI?
        /// What to run when `executableName` is missing.
        var installCommand: String
    }

    /// Adapter versions are the ones Cockpit was verified against; the user
    /// installs them, Cockpit never downloads code.
    var launchPlan: LaunchPlan {
        switch self {
        case .claude:
            LaunchPlan(
                executableName: "claude-agent-acp",
                arguments: [],
                wrappedCLI: .init(name: "claude", environmentKey: "CLAUDE_CODE_EXECUTABLE",
                                  installCommand: "curl -fsSL https://claude.ai/install.sh | bash"),
                installCommand: "npm install -g @agentclientprotocol/claude-agent-acp@0.101.0"
            )
        case .cursor:
            // The generic `agent` command may belong to another installed CLI.
            LaunchPlan(executableName: "cursor-agent", arguments: ["acp"], wrappedCLI: nil,
                       installCommand: "curl https://cursor.com/install -fsS | bash")
        case .codex:
            LaunchPlan(
                executableName: "codex-acp",
                arguments: [],
                wrappedCLI: .init(name: "codex", environmentKey: "CODEX_PATH",
                                  installCommand: "npm install -g @openai/codex"),
                installCommand: "npm install -g @agentclientprotocol/codex-acp@2.5.0"
            )
        case .kimi:
            LaunchPlan(executableName: "kimi", arguments: ["acp"], wrappedCLI: nil,
                       installCommand: "See https://moonshotai.github.io/kimi-code/ to install Kimi Code")
        case .grok:
            LaunchPlan(executableName: "grok", arguments: ["agent", "stdio"], wrappedCLI: nil,
                       installCommand: "See https://docs.x.ai/build/overview to install Grok Build")
        }
    }

    /// The command that signs the CLI in, shown when the agent reports
    /// `auth_required` and has no silent method.
    var loginCommand: String {
        switch self {
        case .claude: "claude /login"
        case .cursor: "cursor-agent login"
        case .codex: "codex login"
        case .kimi: "kimi login"
        case .grok: "grok login"
        }
    }

    /// Grok's `inputTokens` already includes cache reads. Other providers use
    /// the ACP uncached-input convention.
    var inputTokensIncludeCacheReads: Bool { self == .grok }
}

// MARK: - Launch environment

/// Why an agent could not be launched.
enum ChatAgentSetupIssue: Equatable, Sendable {
    case missingExecutable(name: String, installCommand: String)
    case loginRequired(command: String)
    case noWorkingDirectory

    var message: String {
        switch self {
        case .missingExecutable(let name, _): "Cockpit couldn't find `\(name)` on your shell's PATH."
        case .loginRequired: "This agent needs you to sign in from a terminal first."
        case .noWorkingDirectory: "Set a workspace root folder so the agent knows where to work."
        }
    }

    var command: String? {
        switch self {
        case .missingExecutable(_, let install): install
        case .loginRequired(let command): command
        case .noWorkingDirectory: nil
        }
    }
}

enum ChatAgentLauncher {
    /// Variables a parent Claude Code session exports to its children. If
    /// Cockpit itself was launched from one, passing them on would make the
    /// nested `claude` believe it is a subprocess of that session. User
    /// configuration such as `CLAUDE_CODE_USE_BEDROCK` is deliberately kept.
    static let inheritedSessionVariables: Set<String> = [
        "CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT",
        "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_SSE_PORT",
        "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_SESSION_ATTENDED",
        "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
    ]

    /// Install locations agents commonly use, searched after the shell PATH.
    static func fallbackSearchDirectories(home: String) -> [String] {
        [
            "\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.npm-global/bin",
            "\(home)/.kimi-code/bin", "\(home)/.grok/bin", "/opt/homebrew/bin", "/usr/local/bin",
        ]
    }

    static func launchEnvironment(base: [String: String]) -> [String: String] {
        base.filter { !inheritedSessionVariables.contains($0.key) }
    }

    static func locate(
        _ name: String,
        searchPath: String?,
        fallbackDirectories: [String],
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        let directories = (searchPath ?? "").split(separator: ":").map(String.init) + fallbackDirectories
        var seen = Set<String>()
        for directory in directories where !directory.isEmpty && seen.insert(directory).inserted {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if isExecutable(candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }

    /// Resolves the executable and environment for `agent`, or the setup step
    /// the user has to take first.
    static func configuration(
        for agent: ChatAgent,
        workingDirectory: String,
        shellEnvironment: [String: String],
        fallbackDirectories: [String] = fallbackSearchDirectories(home: NSHomeDirectory())
    ) -> Result<ACPConnection.LaunchConfiguration, ChatAgentSetupIssue> {
        let plan = agent.launchPlan
        var environment = launchEnvironment(base: shellEnvironment)
        let searchPath = environment["PATH"]
        // Node-based adapters need their runtime on PATH too.
        environment["PATH"] = ((searchPath.map { [$0] } ?? []) + fallbackDirectories).joined(separator: ":")

        guard let executable = locate(plan.executableName, searchPath: searchPath,
                                      fallbackDirectories: fallbackDirectories) else {
            return .failure(.missingExecutable(name: plan.executableName, installCommand: plan.installCommand))
        }
        if let wrapped = plan.wrappedCLI {
            guard let cli = locate(wrapped.name, searchPath: searchPath, fallbackDirectories: fallbackDirectories) else {
                return .failure(.missingExecutable(name: wrapped.name, installCommand: wrapped.installCommand))
            }
            environment[wrapped.environmentKey] = cli.path
        }
        return .success(ACPConnection.LaunchConfiguration(
            executable: executable,
            arguments: plan.arguments,
            environment: environment,
            currentDirectory: URL(fileURLWithPath: workingDirectory, isDirectory: true)
        ))
    }
}

/// The environment a new terminal tab would get, captured once from the user's
/// login shell. A GUI app inherits launchd's minimal environment, which lacks
/// the PATH (and any API configuration) the user's agents rely on.
actor LoginShellEnvironment {
    static let shared = LoginShellEnvironment()

    private var cached: Task<[String: String], Never>?

    func environment() async -> [String: String] {
        if let cached { return await cached.value }
        let task = Task.detached(priority: .userInitiated) { await Self.capture() }
        cached = task
        return await task.value
    }

    private static func capture() async -> [String: String] {
        let fallback = ProcessInfo.processInfo.environment
        let shell = fallback["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let marker = "__COCKPIT_ENV_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))__"
        let script = "printf '%s' '\(marker)'; /usr/bin/env -0; printf '%s' '\(marker)'"
        let invocation = ProcessInvocation(
            executableURL: URL(fileURLWithPath: shell),
            arguments: ["-l", "-i", "-c", script],
            timeout: .seconds(10),
            standardOutputLimit: 1_048_576
        )
        guard let result = try? await ProcessRunner.run(invocation),
              let parsed = parse(result.standardOutput, marker: marker), parsed["PATH"] != nil else {
            return fallback
        }
        return parsed
    }

    /// Extracts the NUL-separated `env -0` block between two markers, so
    /// anything an interactive shell prints at startup is ignored.
    static func parse(_ output: Data, marker: String) -> [String: String]? {
        let text = String(decoding: output, as: UTF8.self)
        let parts = text.components(separatedBy: marker)
        guard parts.count >= 3 else { return nil }
        var environment: [String: String] = [:]
        for entry in parts[1].split(separator: "\0") {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return environment.isEmpty ? nil : environment
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

// MARK: - Session result mapping

extension AgentChatSession {
    /// Reads a `_session/steering` result. Unknown outcomes are failures.
    static func steerOutcome(_ result: JSONValue) -> ACPSteerOutcome {
        switch result["outcome"]?.stringValue {
        case "injected": .injected
        case "promptRequired": .promptRequired
        default: ACPSteerOutcome(result)
        }
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
}
