import AppKit
import Foundation
import Network

struct CanonicalRepository: Hashable, Sendable {
    let id: String
    let rootURL: URL
    let remote: String?

    static func resolve(directory: String) async -> CanonicalRepository? {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let directoryURL = URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
        let rootInvocation = ProcessInvocation.developerTool(
            "git",
            arguments: ["-C", directoryURL.path, "rev-parse", "--show-toplevel"],
            timeout: .seconds(10),
            standardOutputLimit: 64 * 1_024
        )
        guard let rootResult = try? await ProcessRunner.run(rootInvocation) else { return nil }
        let rawRoot = rootResult.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawRoot.isEmpty else { return nil }
        let rootURL = URL(fileURLWithPath: rawRoot, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL

        let remoteInvocation = ProcessInvocation.developerTool(
            "git",
            arguments: ["-C", rootURL.path, "remote", "get-url", "origin"],
            timeout: .seconds(10),
            standardOutputLimit: 64 * 1_024
        )
        let remote = try? await ProcessRunner.run(remoteInvocation).standardOutputString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRemote = remote.flatMap(normalizeRemote)
        let identity = normalizedRemote ?? "local:\(rootURL.path.lowercased())"
        return CanonicalRepository(id: identity, rootURL: rootURL, remote: normalizedRemote)
    }

    /// Normalizes HTTPS, SSH URL, and scp-style remotes to one host/owner/repo.
    static func normalizeRemote(_ remote: String) -> String? {
        var value = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        var host: String?
        var path: String?
        if let url = URL(string: value), let urlHost = url.host, !urlHost.isEmpty {
            host = urlHost
            path = url.path
        } else if let at = value.lastIndex(of: "@"),
                  let colon = value[at...].firstIndex(of: ":") {
            host = String(value[value.index(after: at)..<colon])
            path = String(value[value.index(after: colon)...])
        } else if let colon = value.firstIndex(of: ":"), !value[..<colon].contains("/") {
            host = String(value[..<colon])
            path = String(value[value.index(after: colon)...])
        }

        guard let rawHost = host?.lowercased(), var rawPath = path else { return nil }
        rawPath = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if rawPath.hasSuffix(".git") { rawPath.removeLast(4) }
        let components = rawPath.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2 else { return nil }
        value = components.joined(separator: "/").lowercased()
        return "\(rawHost)/\(value)"
    }
}

enum RepositoryPollResource: String, Hashable, Sendable {
    case pullRequests
    case workflowRuns
    case issues

    var isGitHubNetworkRequest: Bool { true }

    var foregroundTTL: TimeInterval { 30 }
}

enum RepositoryRefreshPolicy: Sendable, Equatable {
    case automatic
    case manual
}

struct RepositoryPollingMetrics: Sendable, Equatable {
    enum RateLimitState: Sendable, Equatable {
        case unknown
        case healthy
        case limited(until: Date?)
    }

    var commandCount = 0
    var cacheHits = 0
    var coalescedRequests = 0
    var failures = 0
    var totalLatency: TimeInterval = 0
    var rateLimitState: RateLimitState = .unknown

    var averageLatency: TimeInterval {
        commandCount == 0 ? 0 : totalLatency / Double(commandCount)
    }
}

enum RepositoryPollingError: Error, Sendable, LocalizedError {
    case offline
    case backedOff(until: Date)

    var errorDescription: String? {
        switch self {
        case .offline: "GitHub polling is paused while offline."
        case .backedOff(let until): "GitHub polling is retrying after \(until.formatted())."
        }
    }
}

struct RepositoryPollCommand: Sendable {
    let repository: CanonicalRepository
    let resource: RepositoryPollResource
}

/// One cache and scheduling boundary for all repository-backed inspector data.
/// Overlapping callers share a task, and at most two `gh` children run globally.
actor RepositoryPollingScheduler {
    typealias CommandExecutor = @Sendable (RepositoryPollCommand) async throws -> Data
    typealias Now = @Sendable () -> Date
    typealias Jitter = @Sendable () -> Double

    static let shared = RepositoryPollingScheduler()

    private struct CacheKey: Hashable, Sendable {
        let repositoryID: String
        let resource: RepositoryPollResource
    }

    private struct CacheEntry: Sendable {
        let data: Data
        let fetchedAt: Date
        let expiresAt: Date
    }

    private struct FailureState: Sendable {
        var count: Int
        var retryAt: Date
    }

    private let executor: CommandExecutor
    private let now: Now
    private let jitter: Jitter
    private let githubPermits: AsyncPermitPool
    private var cache: [CacheKey: CacheEntry] = [:]
    private var failures: [CacheKey: FailureState] = [:]
    private var inFlight: [CacheKey: Task<Data, Error>] = [:]
    private var resolvedRepositories: [String: CanonicalRepository] = [:]
    private var repositoryResolutions: [String: Task<CanonicalRepository?, Never>] = [:]
    private var applicationActive = true
    private var networkAvailable = true
    private(set) var metrics = RepositoryPollingMetrics()

    init(
        maximumConcurrentGitHubCommands: Int = 2,
        now: @escaping Now = Date.init,
        jitter: @escaping Jitter = { Double.random(in: 0...1) },
        executor: CommandExecutor? = nil
    ) {
        self.now = now
        self.jitter = jitter
        self.githubPermits = AsyncPermitPool(limit: maximumConcurrentGitHubCommands)
        self.executor = executor ?? Self.execute
    }

    func setEnvironment(applicationActive: Bool? = nil, networkAvailable: Bool? = nil) {
        if let applicationActive { self.applicationActive = applicationActive }
        if let networkAvailable { self.networkAvailable = networkAvailable }
    }

    func repository(for directory: String) async -> CanonicalRepository? {
        let key = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL.path
        if let cached = resolvedRepositories[key] { return cached }
        if let task = repositoryResolutions[key] { return await task.value }
        let task = Task { await CanonicalRepository.resolve(directory: key) }
        repositoryResolutions[key] = task
        let repository = await task.value
        repositoryResolutions[key] = nil
        if let repository { resolvedRepositories[key] = repository }
        return repository
    }

    func data(
        for resource: RepositoryPollResource,
        repository: CanonicalRepository,
        policy: RepositoryRefreshPolicy = .automatic
    ) async throws -> Data {
        let key = CacheKey(repositoryID: repository.id, resource: resource)
        let current = now()
        if policy == .automatic {
            if resource.isGitHubNetworkRequest && !networkAvailable {
                if let cached = cache[key] {
                    metrics.cacheHits += 1
                    return cached.data
                }
                throw RepositoryPollingError.offline
            }
            if let cached = cache[key], current < effectiveExpiration(for: cached, resource: resource) {
                metrics.cacheHits += 1
                return cached.data
            }
            if let failure = failures[key], current < failure.retryAt {
                if let cached = cache[key] {
                    metrics.cacheHits += 1
                    return cached.data
                }
                throw RepositoryPollingError.backedOff(until: failure.retryAt)
            }
        }

        if let task = inFlight[key] {
            metrics.coalescedRequests += 1
            return try await task.value
        }

        let task = Task { try await perform(resource: resource, repository: repository, key: key) }
        inFlight[key] = task
        return try await task.value
    }

    func invalidate(repository: CanonicalRepository, resource: RepositoryPollResource? = nil) {
        if let resource {
            let key = CacheKey(repositoryID: repository.id, resource: resource)
            cache[key] = nil
            failures[key] = nil
            return
        }
        cache = cache.filter { key, _ in key.repositoryID != repository.id }
        failures = failures.filter { $0.key.repositoryID != repository.id }
    }

    private func effectiveExpiration(
        for entry: CacheEntry,
        resource: RepositoryPollResource
    ) -> Date {
        guard !applicationActive, resource.isGitHubNetworkRequest else { return entry.expiresAt }
        // Timer callers can keep asking in the background, but cached GitHub
        // data is considered fresh for five minutes instead of 30 seconds.
        return max(entry.expiresAt, entry.fetchedAt.addingTimeInterval(5 * 60))
    }

    private func perform(
        resource: RepositoryPollResource,
        repository: CanonicalRepository,
        key: CacheKey
    ) async throws -> Data {
        defer { inFlight[key] = nil }
        let command = RepositoryPollCommand(repository: repository, resource: resource)
        let started = ContinuousClock.now
        metrics.commandCount += 1
        do {
            let data: Data
            if resource.isGitHubNetworkRequest {
                data = try await githubPermits.withPermit { [executor] in
                    try await executor(command)
                }
            } else {
                data = try await executor(command)
            }
            let fetchedAt = now()
            let ttl = resource.foregroundTTL * (0.85 + min(max(jitter(), 0), 1) * 0.3)
            cache[key] = CacheEntry(
                data: data,
                fetchedAt: fetchedAt,
                expiresAt: fetchedAt.addingTimeInterval(ttl)
            )
            failures[key] = nil
            metrics.totalLatency += started.duration(to: .now).timeInterval
            if resource.isGitHubNetworkRequest { metrics.rateLimitState = .healthy }
            return data
        } catch {
            metrics.failures += 1
            metrics.totalLatency += started.duration(to: .now).timeInterval
            let previousCount = failures[key]?.count ?? 0
            let count = min(previousCount + 1, 7)
            let base = min(15 * pow(2, Double(count - 1)), 15 * 60)
            let delay = base * (0.8 + min(max(jitter(), 0), 1) * 0.4)
            let retryAt = now().addingTimeInterval(delay)
            failures[key] = FailureState(count: count, retryAt: retryAt)
            if resource.isGitHubNetworkRequest && Self.looksRateLimited(error) {
                metrics.rateLimitState = .limited(until: retryAt)
            }
            if let cached = cache[key] { return cached.data }
            throw error
        }
    }

    /// Reshapes `/actions/runs` into the flat `gh run list --json` field names
    /// the workflow parser already reads, plus the triggering actor's login.
    private static let workflowRunProjection = """
        [.workflow_runs[] | {
          databaseId: .id,
          status,
          conclusion,
          displayTitle: .display_title,
          headBranch: .head_branch,
          headSha: .head_sha,
          name,
          createdAt: .created_at,
          startedAt: .run_started_at,
          updatedAt: .updated_at,
          url: .html_url,
          actor: .actor.login
        }]
        """

    private static func execute(_ command: RepositoryPollCommand) async throws -> Data {
        let root = command.repository.rootURL
        let invocation: ProcessInvocation = switch command.resource {
        case .pullRequests:
            // All states, not just open: in a merge-fast workflow the open list
            // is usually empty, and the recent-history view is the useful one.
            .developerTool(
                "gh",
                arguments: [
                    "pr", "list", "--state", "all", "--limit", "20",
                    "--json", "number,title,url,state,isDraft,author,headRefName,createdAt",
                ],
                currentDirectoryURL: root,
                timeout: .seconds(30),
                standardOutputLimit: 4 * 1_024 * 1_024
            )
        case .workflowRuns:
            // `gh run list --json` has no field for who triggered a run, so this
            // goes to the REST endpoint and projects the same field names back
            // out with `--jq`. `exclude_pull_requests` drops the largest part of
            // the payload; the projection keeps what reaches us small.
            .developerTool(
                "gh",
                arguments: [
                    "api", "repos/{owner}/{repo}/actions/runs?per_page=30&exclude_pull_requests=true",
                    "--jq", Self.workflowRunProjection,
                ],
                currentDirectoryURL: root,
                timeout: .seconds(30),
                standardOutputLimit: 4 * 1_024 * 1_024
            )
        case .issues:
            .developerTool(
                "gh",
                arguments: [
                    "issue", "list", "--state", "open", "--limit", "100",
                    "--json", "number,title,url,state,assignees,createdAt",
                ],
                currentDirectoryURL: root,
                timeout: .seconds(30),
                standardOutputLimit: 4 * 1_024 * 1_024
            )
        }
        return try await ProcessRunner.run(invocation).standardOutput
    }

    private static func looksRateLimited(_ error: Error) -> Bool {
        let text: String
        if let processError = error as? ProcessRunnerError {
            text = processError.result?.standardErrorString ?? ""
        } else {
            text = error.localizedDescription
        }
        return text.localizedCaseInsensitiveContains("rate limit")
            || text.localizedCaseInsensitiveContains("secondary rate")
            || text.contains("HTTP 429")
    }
}

private actor AsyncPermitPool {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        available = max(1, limit)
    }

    func withPermit<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        await acquire()
        do {
            let value = try await operation()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Feeds app activation and network reachability into the shared scheduler.
@MainActor
final class RepositoryPollingEnvironmentMonitor {
    static let shared = RepositoryPollingEnvironmentMonitor()

    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "app.blau.repository-network")
    private var observers: [NSObjectProtocol] = []
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { await RepositoryPollingScheduler.shared.setEnvironment(applicationActive: true) }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { await RepositoryPollingScheduler.shared.setEnvironment(applicationActive: false) }
        })
        pathMonitor.pathUpdateHandler = { path in
            Task {
                await RepositoryPollingScheduler.shared.setEnvironment(
                    networkAvailable: path.status == .satisfied
                )
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
