import Foundation

/// Reads an installed agent's advertised models without changing a chat pane.
/// Only initialization and an empty session are requested; no prompt is sent,
/// conversation is resumed, or pane session ID is saved.
enum AgentModelDiscovery {
    static func load(agent: ChatAgent, workingDirectory: String,
                     resolveLaunch: AgentChatSession.LaunchResolver,
                     timeout: Duration = .seconds(45)) async throws -> ACPSessionConfig {
        let configuration = try await resolveLaunch(agent, workingDirectory).get()
        try Task.checkCancellation()
        let connection = ACPConnection()
        let events = Task {
            for await event in connection.incoming {
                guard case .request(let id, let method, _) = event else { continue }
                if method == ACP.Method.requestPermission {
                    await connection.respond(to: id, result: ACP.permissionResult(optionID: nil))
                } else {
                    await connection.respond(to: id, error: ACPRemoteError(code: ACPRemoteError.methodNotFound,
                                                                          message: "Model discovery does not support this request."))
                }
            }
        }
        do {
            try await connection.start(configuration)
            try Task.checkCancellation()
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"
            let initialized = try await connection.request(ACP.Method.initialize,
                params: ACP.initializeParams(clientVersion: version), timeout: timeout)
            let params = ACP.newSessionParams(cwd: workingDirectory)
            let result: JSONValue
            do {
                result = try await connection.request(ACP.Method.newSession, params: params, timeout: timeout)
            } catch let error as ACPRemoteError where error.code == ACPRemoteError.authRequired {
                guard let method = ACPAgentInfo(initialized).silentAuthMethodID else {
                    throw ChatAgentSetupIssue.loginRequired(command: agent.loginCommand)
                }
                _ = try await connection.request(ACP.Method.authenticate, params: ["methodId": .string(method)], timeout: timeout)
                result = try await connection.request(ACP.Method.newSession, params: params, timeout: timeout)
            }
            guard let config = ACPSessionConfig(result), AgentModelCatalog.snapshot(of: config) != nil else {
                throw ACPRemoteError(code: -32603, message: "\(agent.displayName) did not return any models.")
            }
            try Task.checkCancellation()
            events.cancel()
            await stop(connection)
            return config
        } catch {
            events.cancel()
            await stop(connection)
            throw error
        }
    }

    private static func stop(_ connection: ACPConnection) async {
        // Run cleanup outside the cancelled discovery task so termination's
        // grace-period sleeps still allow the agent to exit after stdin closes.
        await Task { await connection.terminate() }.value
    }
}
