import Foundation
import Observation

enum RunnersAPI {
    struct Page: Decodable { let runners: [GitHubRunner] }

    static func fetch(_ scope: RunnerScope) async throws -> [GitHubRunner] {
        let result = try await ProcessRunner.run(.developerTool(
            "gh",
            arguments: ["api", "--hostname", "github.com", "--paginate", "--slurp", scope.endpoint],
            timeout: .seconds(30),
            standardOutputLimit: 8 * 1_024 * 1_024
        ))
        return try decode(result.standardOutput)
    }

    static func decode(_ data: Data) throws -> [GitHubRunner] {
        let pages = try JSONDecoder().decode([Page].self, from: data)
        var seen: Set<Int> = []
        return pages.flatMap(\.runners).filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func message(for error: Error, scope: RunnerScope) -> String {
        guard let processError = error as? ProcessRunnerError else {
            return "Couldn’t read the runners returned by GitHub. Try refreshing."
        }
        let detail = processError.result?.standardErrorString ?? ""
        if detail.contains("401") || detail.contains("gh auth login") || detail.contains("not logged") {
            return "Sign in to GitHub with gh auth login, then refresh."
        }
        if detail.contains("403") || detail.contains("404") {
            switch scope.kind {
            case .enterprise:
                return "Check the enterprise slug and your GitHub access. Enterprise runners require an OAuth token or classic personal access token with manage_runners:enterprise. Fine-grained tokens are not supported."
            case .organization:
                return "Check the organization name and your GitHub access. Organization runners require admin access and the admin:org token scope, or Self-hosted runners read permission."
            case .repository:
                return "Check the repository name and your GitHub access. Repository runners require admin access and Actions read permission."
            }
        }
        return "Couldn’t load runners. Check your connection and GitHub CLI sign-in, then refresh."
    }
}

@MainActor
@Observable
final class RunnersStore {
    struct Snapshot {
        var runners: [GitHubRunner] = []
        var updatedAt: Date?
        var error: String?
    }

    private(set) var scopes: [RunnerScope]
    var selectedScopeID: String? {
        didSet { defaults.set(selectedScopeID, forKey: "runners.selectedScope") }
    }
    private(set) var snapshots: [String: Snapshot] = [:]
    private(set) var refreshing: Set<String> = []
    private(set) var presentations: [String: RunnerPresentation]
    var searchText = ""

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fetch: @Sendable (RunnerScope) async throws -> [GitHubRunner]

    init(
        defaults: UserDefaults = .standard,
        fetch: @escaping @Sendable (RunnerScope) async throws -> [GitHubRunner] = { try await RunnersAPI.fetch($0) }
    ) {
        self.defaults = defaults
        self.fetch = fetch
        let stored = defaults.data(forKey: "runners.scopes")
            .flatMap { try? JSONDecoder().decode([RunnerScope].self, from: $0) } ?? []
        var seen: Set<String> = []
        let restoredScopes = stored.filter {
            RunnerScope.parse($0.name, kind: $0.kind) != nil && seen.insert($0.id).inserted
        }
        self.scopes = restoredScopes
        let selected = defaults.string(forKey: "runners.selectedScope")
        self.selectedScopeID = restoredScopes.first { $0.id == selected }?.id ?? restoredScopes.first?.id
        self.presentations = defaults.data(forKey: "runners.presentations")
            .flatMap { try? JSONDecoder().decode([String: RunnerPresentation].self, from: $0) } ?? [:]
    }

    var selectedScope: RunnerScope? { scopes.first { $0.id == selectedScopeID } }
    var snapshot: Snapshot { selectedScopeID.flatMap { snapshots[$0] } ?? Snapshot() }
    var isRefreshing: Bool { selectedScopeID.map { refreshing.contains($0) } ?? false }
    var visibleRunners: [GitHubRunner] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return snapshot.runners.filter { runner in
            query.isEmpty || ([displayName(for: runner), runner.name, runner.platform, runner.state.rawValue]
                + runner.labels.map(\.name)).contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    @discardableResult
    func add(_ scope: RunnerScope) -> Bool {
        guard RunnerScope.parse(scope.name, kind: scope.kind) != nil else { return false }
        let isNew = !scopes.contains { $0.id == scope.id }
        if isNew {
            scopes.append(scope)
            persistScopes()
        }
        selectedScopeID = scope.id
        searchText = ""
        return isNew
    }

    func remove(_ scope: RunnerScope) {
        scopes.removeAll { $0.id == scope.id }
        snapshots[scope.id] = nil
        if selectedScopeID == scope.id { selectedScopeID = scopes.first?.id }
        persistScopes()
    }

    func refreshSelected() async {
        guard let scope = selectedScope else { return }
        await refresh(scope)
    }

    func refresh(_ scope: RunnerScope) async {
        guard !refreshing.contains(scope.id) else { return }
        refreshing.insert(scope.id)
        defer { refreshing.remove(scope.id) }
        do {
            let runners = try await fetch(scope)
            try Task.checkCancellation()
            guard scopes.contains(where: { $0.id == scope.id }) else { return }
            snapshots[scope.id] = Snapshot(runners: runners, updatedAt: Date())
        } catch {
            guard !Task.isCancelled, scopes.contains(where: { $0.id == scope.id }) else { return }
            var previous = snapshots[scope.id] ?? Snapshot()
            previous.error = RunnersAPI.message(for: error, scope: scope)
            snapshots[scope.id] = previous
        }
    }

    func presentation(for runner: GitHubRunner) -> RunnerPresentation {
        guard let scope = selectedScope else { return RunnerPresentation() }
        return presentations["\(scope.id):\(runner.id)"] ?? RunnerPresentation()
    }

    func displayName(for runner: GitHubRunner) -> String {
        let name = presentation(for: runner).name
        return name.isEmpty ? runner.name : name
    }

    func hardware(for runner: GitHubRunner) -> RunnerHardware {
        presentation(for: runner).hardware ?? .inferred(for: runner)
    }

    func savePresentation(_ presentation: RunnerPresentation, runner: GitHubRunner, scope: RunnerScope) {
        var value = presentation
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        presentations["\(scope.id):\(runner.id)"] = value
        if let data = try? JSONEncoder().encode(presentations) {
            defaults.set(data, forKey: "runners.presentations")
        }
    }

    private func persistScopes() {
        if let data = try? JSONEncoder().encode(scopes) { defaults.set(data, forKey: "runners.scopes") }
    }
}
