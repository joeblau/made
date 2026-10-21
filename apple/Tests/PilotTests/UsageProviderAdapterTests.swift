import Foundation
import Testing
@testable import Pilot

/// Exercises each provider adapter's request, session gating, and error
/// classification through an injected transport — no store, timer, or network.
@Suite("Usage provider adapters")
struct UsageProviderAdapterTests {
    private actor StubTransport {
        private(set) var requests: [URLRequest] = []
        private let status: Int
        private let headers: [String: String]
        private let body: Data

        init(status: Int = 200, headers: [String: String] = [:], body: String = "{}") {
            self.status = status
            self.headers = headers
            self.body = Data(body.utf8)
        }

        func respond(to request: URLRequest) -> (Data, URLResponse) {
            requests.append(request)
            let response = HTTPURLResponse(
                url: request.url ?? URL(fileURLWithPath: "/"),
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            return (body, response)
        }

        var transport: UsageHTTP.Transport {
            { request in await self.respond(to: request) }
        }
    }

    private static let codexSession = UsageSessions.CodexSession(
        accessToken: "codex-token",
        accountId: "account-1"
    )
    private static let claudeSession = UsageSessions.ClaudeSession(
        accessToken: "claude-token",
        scopes: ["user:inference", "user:profile"],
        subscriptionType: "max"
    )
    private static let grokSession = UsageSessions.GrokSession(
        accessToken: "grok-token",
        scope: "https://auth.x.ai::client-id",
        authMode: "oidc",
        email: nil,
        teamId: nil,
        expiresAt: nil,
        refreshToken: nil,
        oidcClientId: nil,
        oidcIssuer: nil
    )
    private static let expiredGrokSession = UsageSessions.GrokSession(
        accessToken: "grok-stale-token",
        scope: "https://auth.x.ai::client-id",
        authMode: "oidc",
        email: nil,
        teamId: nil,
        expiresAt: Date(timeIntervalSince1970: 1),
        refreshToken: "grok-refresh-token",
        oidcClientId: "client-id",
        oidcIssuer: "https://auth.x.ai"
    )
    private static let kimiSession = UsageSessions.KimiSession(
        accessToken: "kimi-token",
        expiresAt: nil
    )
    private static let kimiCredentialFile = URL(fileURLWithPath: "/nonexistent/kimi-code.json")
    private static let expiredKimiSession = UsageSessions.KimiSession(
        accessToken: "kimi-stale-token",
        expiresAt: Date(timeIntervalSince1970: 1),
        refreshToken: "kimi-refresh-token",
        fileURL: kimiCredentialFile
    )
    private static let cursorSession = UsageSessions.CursorSession(
        accessToken: "cursor-token",
        userId: "github|1218847",
        expiresAt: nil
    )

    private func failureMessage(_ fetch: ProviderFetch) -> String? {
        if case .failure(let message) = fetch { return message }
        return nil
    }

    @Test("A missing session is reported without any request")
    func missingSessionsMakeNoRequest() async {
        let stub = StubTransport()
        let transport = await stub.transport

        let results = [
            await ClaudeUsageAdapter.fetch(session: nil, transport: transport),
            await CodexUsageAdapter.fetch(session: nil, transport: transport),
            await CursorUsageAdapter.fetch(session: nil, transport: transport),
            await GrokUsageAdapter.fetch(session: nil, clientVersion: nil, transport: transport),
            await KimiUsageAdapter.fetch(session: nil, transport: transport),
        ]

        for result in results {
            guard case .notSignedIn = result else {
                Issue.record("Expected notSignedIn, got \(result)")
                continue
            }
        }
        #expect(await stub.requests.isEmpty)
    }

    @Test("Unusable local sessions fail with provider-specific reauthentication text")
    func unusableSessionsFailLocally() async {
        let stub = StubTransport()
        let transport = await stub.transport
        let unscoped = UsageSessions.ClaudeSession(
            accessToken: "claude-token",
            scopes: ["user:inference"],
            subscriptionType: nil
        )
        let expired = UsageSessions.KimiSession(
            accessToken: "kimi-token",
            expiresAt: Date(timeIntervalSince1970: 1)
        )
        let expiredCursor = UsageSessions.CursorSession(
            accessToken: "cursor-token",
            userId: "github|1218847",
            expiresAt: Date(timeIntervalSince1970: 1)
        )

        let claude = await ClaudeUsageAdapter.fetch(session: unscoped, transport: transport)
        let kimi = await KimiUsageAdapter.fetch(session: expired, transport: transport)
        let cursor = await CursorUsageAdapter.fetch(session: expiredCursor, transport: transport)

        #expect(failureMessage(claude)
            == "Claude: this session lacks the user:profile scope — re-run `claude` to sign in.")
        #expect(failureMessage(kimi) == "Kimi: session expired — re-run `kimi login` to sign in.")
        #expect(failureMessage(cursor)
            == "Cursor: session expired — sign in to the Cursor app, then refresh.")
        #expect(await stub.requests.isEmpty)
    }

    @Test("Codex sends its CLI headers to its usage endpoint and parses the body")
    func codexRequestAndParse() async throws {
        let stub = StubTransport(body: """
        {"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":40,"limit_window_seconds":18000}}}
        """)

        let result = await CodexUsageAdapter.fetch(session: Self.codexSession, transport: await stub.transport)

        guard case .success(let usage) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(usage.planLabel == "Plus")
        #expect(usage.windows.map(\.name) == ["5-hour"])
        let request = try #require(await stub.requests.first)
        #expect(request.url == CodexUsageAdapter.endpoint)
        #expect(request.httpMethod == "GET")
        #expect(request.timeoutInterval == 20)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer codex-token")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "account-1")
        #expect(request.value(forHTTPHeaderField: "OpenAI-Beta") == "codex-1")
    }

    @Test("Claude sends the OAuth beta header and labels the plan from the session")
    func claudeRequestAndParse() async throws {
        let stub = StubTransport(body: #"{"five_hour":{"utilization":12.5}}"#)

        let result = await ClaudeUsageAdapter.fetch(session: Self.claudeSession, transport: await stub.transport)

        guard case .success(let usage) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(usage.planLabel == "Max")
        #expect(usage.windows.first?.utilization == 0.125)
        let request = try #require(await stub.requests.first)
        #expect(request.url == ClaudeUsageAdapter.endpoint)
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer claude-token")
    }

    @Test("Grok falls back to a known client version and the session's auth mode")
    func grokRequestAndParse() async throws {
        let stub = StubTransport(body: #"{"config":{"creditUsagePercent":50}}"#)

        let result = await GrokUsageAdapter.fetch(
            session: Self.grokSession,
            clientVersion: nil,
            transport: await stub.transport
        )

        guard case .success(let usage) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(usage.planLabel == "SuperGrok")
        #expect(usage.windows.first?.utilization == 0.5)
        let request = try #require(await stub.requests.first)
        #expect(request.url == GrokUsageAdapter.endpoint)
        #expect(request.value(forHTTPHeaderField: "x-grok-client-version")
            == GrokUsageAdapter.fallbackClientVersion)
        #expect(request.value(forHTTPHeaderField: "User-Agent")
            == "grok/\(GrokUsageAdapter.fallbackClientVersion)")
    }

    @Test("Cursor sends the dashboard session cookie to both usage endpoints")
    func cursorRequestAndParse() async throws {
        let stub = StubTransport(body: """
        {"membershipType":"unified_ultra",
         "billingCycleStart":"2026-10-01T00:00:00.000Z",
         "billingCycleEnd":"2026-11-01T00:00:00.000Z",
         "individualUsage":{"plan":{"enabled":true,"limit":55395,"totalPercentUsed":12},
                            "onDemand":{"enabled":false,"used":0,"limit":null}}}
        """)

        let result = await CursorUsageAdapter.fetch(
            session: Self.cursorSession,
            transport: await stub.transport
        )

        guard case .success(let usage) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(usage.planLabel == "Ultra")
        #expect(usage.windows.map(\.name) == ["Monthly"])
        #expect(usage.windows.first?.utilization == 0.12)
        let requests = await stub.requests
        #expect(requests.map(\.url) == [
            CursorUsageAdapter.summaryEndpoint,
            CursorUsageAdapter.statusEndpoint,
        ])
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "Cookie")
                == "WorkosCursorSessionToken=github%7C1218847%3A%3Acursor-token")
        }
    }

    @Test("An expired Grok session refreshes before the request instead of failing")
    func grokExpiredSessionRefreshes() async throws {
        let stub = StubTransport(body: #"{"config":{"creditUsagePercent":25}}"#)
        let refreshed = Self.grokSession

        let result = await GrokUsageAdapter.fetch(
            session: Self.expiredGrokSession,
            clientVersion: nil,
            transport: await stub.transport,
            refresh: { _ in refreshed }
        )

        guard case .success(let usage) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(usage.windows.first?.utilization == 0.25)
        let request = try #require(await stub.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer grok-token")
    }

    @Test("A failed Grok refresh reports the expiry without hitting the usage endpoint")
    func grokFailedRefreshReportsExpiry() async {
        let stub = StubTransport()

        let result = await GrokUsageAdapter.fetch(
            session: Self.expiredGrokSession,
            clientVersion: nil,
            transport: await stub.transport,
            refresh: { _ in nil }
        )

        #expect(failureMessage(result) == "Grok: session expired — re-run `grok` to sign in.")
        #expect(await stub.requests.isEmpty)
    }

    @Test("A Grok token revoked ahead of expiry gets one refresh-and-retry")
    func grokEarlyRevocationRetriesOnce() async {
        let stub = StubTransport(status: 401)
        let revivableSession = UsageSessions.GrokSession(
            accessToken: "grok-revoked-token",
            scope: "https://auth.x.ai::client-id",
            authMode: "oidc",
            email: nil,
            teamId: nil,
            expiresAt: Date().addingTimeInterval(3600),
            refreshToken: "grok-refresh-token",
            oidcClientId: "client-id",
            oidcIssuer: nil
        )

        let result = await GrokUsageAdapter.fetch(
            session: revivableSession,
            clientVersion: nil,
            transport: await stub.transport,
            refresh: { _ in Self.grokSession }
        )

        // Both attempts 401 here; the point is exactly one retry, no loop.
        #expect(failureMessage(result) == "Grok: session expired — re-run `grok` to sign in.")
        let requests = await stub.requests
        #expect(requests.count == 2)
        #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer grok-token")
    }

    @Test("An expired Kimi session refreshes before the request instead of failing")
    func kimiExpiredSessionRefreshes() async throws {
        let stub = StubTransport(body: #"{"usage":{"limit":100,"used":25}}"#)
        let refreshed = Self.kimiSession

        let result = await KimiUsageAdapter.fetch(
            session: Self.expiredKimiSession,
            transport: await stub.transport,
            refresh: { _ in refreshed }
        )

        guard case .success(let usage) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(usage.windows.first?.utilization == 0.25)
        let request = try #require(await stub.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer kimi-token")
    }

    @Test("Kimi labels the card with the account endpoint's membership tier")
    func kimiPlanLabelFromAccountEndpoint() async throws {
        let usagesBody = Data(#"{"usage":{"limit":100,"used":22}}"#.utf8)
        let accountBody = Data(#"{"user_level_name":"Vivace","user_level":30}"#.utf8)
        let transport: UsageHTTP.Transport = { request in
            let body = request.url == KimiUsageAdapter.accountEndpoint ? accountBody : usagesBody
            let response = HTTPURLResponse(
                url: request.url ?? URL(fileURLWithPath: "/"),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (body, response)
        }

        let result = await KimiUsageAdapter.fetch(session: Self.kimiSession, transport: transport)

        guard case .success(let usage) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        // The account endpoint's exact tier name wins over any in-payload guess.
        #expect(usage.planLabel == "Vivace")
        #expect(usage.windows.first?.utilization == 0.22)
    }

    @Test("A failed Kimi refresh reports the expiry without hitting the usage endpoint")
    func kimiFailedRefreshReportsExpiry() async {
        let stub = StubTransport()

        let result = await KimiUsageAdapter.fetch(
            session: Self.expiredKimiSession,
            transport: await stub.transport,
            refresh: { _ in nil }
        )

        #expect(failureMessage(result) == "Kimi: session expired — re-run `kimi login` to sign in.")
        #expect(await stub.requests.isEmpty)
    }

    @Test("A Kimi token revoked ahead of expiry gets one refresh-and-retry")
    func kimiEarlyRevocationRetriesOnce() async {
        let stub = StubTransport(status: 401)
        let revivableSession = UsageSessions.KimiSession(
            accessToken: "kimi-revoked-token",
            expiresAt: Date().addingTimeInterval(600),
            refreshToken: "kimi-refresh-token",
            fileURL: Self.kimiCredentialFile
        )

        let result = await KimiUsageAdapter.fetch(
            session: revivableSession,
            transport: await stub.transport,
            refresh: { _ in Self.kimiSession }
        )

        // Both attempts 401 here; the point is exactly one retry, no loop.
        #expect(failureMessage(result) == "Kimi: session expired — re-run `kimi login` to sign in.")
        let requests = await stub.requests
        #expect(requests.count == 2)
        #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer kimi-token")
    }

    @Test("429 responses carry the server Retry-After hint to the backoff policy")
    func rateLimitCarriesRetryAfter() async {
        let stub = StubTransport(status: 429, headers: ["Retry-After": "900"])

        let result = await KimiUsageAdapter.fetch(session: Self.kimiSession, transport: await stub.transport)

        guard case .rateLimited(let retryAfter) = result else {
            Issue.record("Expected rateLimited, got \(result)")
            return
        }
        #expect(retryAfter == 900)
    }

    @Test("Rejected credentials name the CLI that re-authenticates each provider")
    func authenticationFailuresNameTheirCLI() async {
        let unauthorized = StubTransport(status: 401)
        let forbidden = StubTransport(status: 403)

        let codex = await CodexUsageAdapter.fetch(
            session: Self.codexSession,
            transport: await unauthorized.transport
        )
        let claude = await ClaudeUsageAdapter.fetch(
            session: Self.claudeSession,
            transport: await forbidden.transport
        )
        let grok = await GrokUsageAdapter.fetch(
            session: Self.grokSession,
            clientVersion: "1.0.0",
            transport: await unauthorized.transport
        )
        let kimi = await KimiUsageAdapter.fetch(
            session: Self.kimiSession,
            transport: await forbidden.transport
        )

        #expect(failureMessage(codex) == "Codex: session expired — re-run `codex` to sign in.")
        #expect(failureMessage(claude) == "Claude: session expired — re-run `claude` to sign in.")
        #expect(failureMessage(grok) == "Grok: session expired — re-run `grok` to sign in.")
        #expect(failureMessage(kimi) == "Kimi: session expired — re-run `kimi login` to sign in.")
    }

    @Test("Other HTTP failures and non-object bodies stay displayable failures")
    func otherFailures() async {
        let serverError = StubTransport(status: 503)
        let arrayBody = StubTransport(body: "[]")
        let invalidBody = StubTransport(body: "not json")

        let http = await CodexUsageAdapter.fetch(
            session: Self.codexSession,
            transport: await serverError.transport
        )
        let array = await CodexUsageAdapter.fetch(
            session: Self.codexSession,
            transport: await arrayBody.transport
        )
        let invalid = await CodexUsageAdapter.fetch(
            session: Self.codexSession,
            transport: await invalidBody.transport
        )

        #expect(failureMessage(http) == "Codex: request failed (HTTP 503).")
        #expect(failureMessage(array) == "Codex: couldn’t read the usage response.")
        #expect(failureMessage(invalid) == "Codex: couldn’t read the usage response.")
    }
}
