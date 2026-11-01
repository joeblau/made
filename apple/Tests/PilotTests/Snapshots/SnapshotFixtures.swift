import Foundation
import SwiftData
@testable import Pilot

@MainActor
final class SnapshotFixtures {
    static let date = Date(timeIntervalSince1970: 1_792_756_800) // 2026-10-23 12:00 UTC
    let suiteName = "app.blau.snapshots.\(UUID().uuidString)"
    let defaults: UserDefaults
    let container: ModelContainer
    let workspace: WorkspaceStore
    let docker: DockerStore
    let runners: RunnersStore
    let repository = RepositoryStore()
    let tasks: GitHubTasksStore
    let usage: UsageStore
    let history: AgenticUseSnapshot

    init() throws {
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(0, forKey: "notes.wordWrap")
        for key in [UsageConsent.claudeKey, UsageConsent.codexKey, UsageConsent.cursorKey,
                    UsageConsent.grokKey, UsageConsent.kimiKey] {
            defaults.set(true, forKey: key)
        }
        let schema = Schema(versionedSchema: PilotSchemaV3.self)
        container = try ModelContainer(
            for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        workspace = WorkspaceStore(
            modelContext: container.mainContext, workspaceGroups: WorkspaceGroups(defaults: defaults), defaults: defaults
        )
        docker = DockerStore(defaults: defaults, resolveSocketPath: { "/fixture/docker.sock" }, makeClient: { _ in
            SnapshotDockerEngine()
        })
        runners = RunnersStore(defaults: defaults, fetch: { _ in Self.runnerFleet })
        tasks = GitHubTasksStore(tasks: try Self.makeTasks())
        usage = UsageStore(defaults: defaults, fetchers: .init(
            claude: { .success(Self.plan("Max", fraction: 0.38, balance: 42.50)) },
            codex: { .success(Self.plan("Pro", fraction: 0.24, balance: 128.00)) },
            cursor: { .success(Self.plan("Ultra", fraction: 0.47, balance: 75.00)) },
            grok: { .success(Self.plan("SuperGrok", fraction: 0.16, balance: 30.00)) },
            kimi: { .success(Self.plan("Allegretto", fraction: 0.61, balance: 18.75)) }
        ), now: { Self.date })
        history = Self.makeHistory()
        seedWorkspace()
        seedRepository()
        runners.add(RunnerScope(kind: .organization, name: "orbit-studio"))
    }

    func prepare() async throws {
        docker.start()
        usage.reload()
        await runners.refreshSelected()
        for _ in 0..<200 {
            if docker.containers.count == SnapshotDockerEngine.items.count && !usage.isLoading {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SnapshotError.fixtureTimeout
    }

    func close() {
        docker.stop()
        usage.stop()
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func seedWorkspace() {
        let names = ["orbit-web", "atlas-api", "orbit-ios", "design-system", "documentation", "infrastructure", "playground"]
        for (index, name) in names.enumerated() {
            let item = Workspace(name: name)
            item.workspaceSortOrder = index
            item.isPinned = index < 2
            container.mainContext.insert(item)
        }
        for (index, text) in [Self.releaseNote, "# API design\n\n## Projects\n\nGET /v1/projects\nPOST /v1/projects\n\nUse cursor pagination for the activity feed.",
                              "# Sprint planning\n\n- [x] Ship team invitations\n- [ ] Review the mobile onboarding flow", "# Scratchpad\n\nIdeas for the next release."].enumerated() {
            let note = Note(body: text, sortOrder: index)
            container.mainContext.insert(note)
            if index == 0 { workspace.selectedNoteID = note.id }
        }
    }

    private func seedRepository() {
        repository.repoPath = "/demo/orbit-web"
        let changes = ["feat: ship the project activity timeline", "fix: preserve filters when switching projects",
                       "feat: add keyboard navigation to the command menu", "test: cover team invitation flows",
                       "perf: cache project summaries", "docs: update the contributor guide", "build: refresh preview assets"]
        repository.actions = changes.enumerated().map { index, title in
            GitAction(id: 420 - index, name: index == 0 ? "Preview" : "CI", displayTitle: title,
                      headBranch: index < 2 ? "feat/activity-timeline" : "main", headSha: "a4f2c8d",
                      status: "completed", conclusion: index == 3 ? "failure" : "success",
                      duration: "\(2 + index)m", elapsed: index == 0 ? "2 minutes ago" : "\(index + 1) hours ago",
                      url: "https://example.com/actions/\(index)", actor: ["alex", "sam", "morgan"][index % 3])
        }
        repository.pullRequests = changes.prefix(5).enumerated().map { index, title in
            GitPullRequest(id: 128 - index, title: title, url: "https://example.com/pull/\(128 - index)",
                           state: "OPEN", isDraft: index == 2, author: ["alex", "sam", "morgan"][index % 3],
                           headBranch: ["feat/activity-timeline", "fix/project-filters", "feat/command-menu"][index % 3],
                           elapsed: "\(index + 1) hours ago")
        }
        repository.filesystem = ["src", "components", "public", "tests", "package.json", "README.md", "tsconfig.json"].map { name in
            let directory = !name.contains(".")
            return FileSystemEntry(id: name, name: name, path: "/demo/orbit-web/\(name)", relativePath: name,
                                   isDirectory: directory, children: directory ? ["index.ts", "project.ts", "activity.ts"].map {
                FileSystemEntry(id: "\(name)/\($0)", name: $0, path: "/demo/orbit-web/\(name)/\($0)",
                                relativePath: "\(name)/\($0)", isDirectory: false, children: nil)
            } : nil)
        }
    }

    private static func makeTasks() throws -> [GitHubTask] {
        let titles = ["Add activity filters and saved views", "Polish the empty project state", "Support team invitation links",
                      "Add keyboard shortcuts to the project switcher", "Improve mobile navigation", "Document the public API",
                      "Add export to the activity timeline", "Test the release candidate"]
        let rows = titles.enumerated().map { index, title -> [String: Any] in
            ["number": 84 - index, "title": title, "state": "OPEN", "url": "https://example.com/issues/\(84 - index)",
             "assignees": [["login": ["alex", "sam", "morgan"][index % 3]]], "createdAt": ""]
        }
        return try JSONDecoder().decode([GitHubTask].self, from: JSONSerialization.data(withJSONObject: rows))
    }

    nonisolated private static func plan(_ label: String, fraction: Double, balance: Double) -> ProviderUsage {
        ProviderUsage(planLabel: label, windows: [
            UsageWindow(id: "short", name: "5-hour", utilization: fraction * 0.55, resetsAt: nil),
            UsageWindow(id: "week", name: "Weekly", utilization: fraction, resetsAt: nil)
        ], credits: CreditInfo(balance: balance, unit: .currency("USD")))
    }

    nonisolated static var runnerFleet: [GitHubRunner] {
        (0..<8).map { index in
            GitHubRunner(id: index + 1, name: index < 6 ? "mini-m4-0\(index + 1)" : "linux-build-0\(index - 5)",
                         os: index < 6 ? "macOS" : "linux", status: index == 7 ? "offline" : "online",
                         busy: [1, 4, 6].contains(index), labels: [
                            .init(name: "self-hosted", type: "read-only"),
                            .init(name: index < 6 ? "macOS" : "Linux", type: "read-only"),
                            .init(name: index < 6 ? "ARM64" : "X64", type: "read-only"),
                            .init(name: index < 6 ? "macmini" : "docker", type: "custom")
                         ])
        }
    }

    private static func makeHistory() -> AgenticUseSnapshot {
        // (provider, model, relative volume, cache-write share). Sixty days so
        // the 30-day capture has a previous window for its KPI deltas.
        let models: [(AgenticProvider, String, Double, Double)] = [
            (.claude, "claude-opus-5-5", 1.0, 0.04), (.claude, "claude-sonnet-5-5", 0.45, 0.04),
            (.claude, "claude-fable-5-1", 0.08, 0.03), (.codex, "gpt-6.1-sol", 0.7, 0),
            (.codex, "gpt-6-astra", 0.25, 0), (.cursor, "cursor/claude-opus-5-5", 0.3, 0.02),
            (.kimi, "k3", 0.18, 0.05), (.kimi, "kimi-for-coding", 0.1, 0), (.grok, "grok-4.7", 0.12, 0),
        ]
        var records: [AgenticUsageRecord] = []
        for day in 0..<60 {
            // Gentle weekly rhythm, a little heavier in the earlier window,
            // and one Claude-led spike for the insight card.
            let rhythm = Double((day * 7) % 11 + 4) / 8
            let era = day >= 30 ? 1.25 : 1
            for (index, model) in models.enumerated() {
                let spike = day == 6 && model.0 == .claude ? 3.2 : 1
                let volume = rhythm * era * spike * model.2 * Double((day + index * 5) % 6 + 7) / 9
                let input = Int(volume * 2_400_000)
                records.append(AgenticUsageRecord(
                    provider: model.0, dedupKey: "demo-\(day)-\(index)", model: model.1,
                    timestamp: date.addingTimeInterval(-Double(day) * 86_400),
                    inputTokens: Int(Double(input) * 0.06),
                    cacheWriteTokens: Int(Double(input) * model.3), cacheWrite1hTokens: 0,
                    cacheReadTokens: Int(Double(input) * (0.94 - model.3) * 10),
                    outputTokens: Int(Double(input) * 0.035), thinkingTokens: nil, isFast: false,
                    nativeCostUSD: nil
                ))
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return AgenticUsageStore.makeSnapshot(records: records, range: .month, now: date, calendar: calendar)
    }

    static let releaseNote = """
    # Orbit · Release checklist

    A shared home for the projects that move your team forward.

    ## Ready to ship

    - [x] Build the project activity timeline
    - [x] Add keyboard navigation to the command menu
    - [x] Connect the web and iOS previews
    - [x] Run the full test suite · 128 tests passing
    - [ ] Review the release candidate with the team
    - [ ] Publish the changelog

    ## Development

    Web preview       http://localhost:3000
    API playground    http://localhost:8080
    Current branch    feat/activity-timeline

    ## Design review

    Keep the navigation quiet. Make the next action obvious.
    Use the same project colors across web and mobile.

    ### Next sprint

    - Saved views for the activity feed
    - Team invitation links
    - Export project summaries

    ## Demo configuration

    ORBIT_API_KEY="demo_only_not_a_real_credential"
    ORBIT_WORKSPACE="orbit-studio"
    """
}

private struct SnapshotDockerEngine: DockerEngineAPI {
    static var items: [DockerContainerSummary] {
        let rows = [("orbit-web", "node:22-alpine", "orbit", 3000), ("orbit-api", "orbit/api:dev", "orbit", 8080),
                    ("orbit-db", "postgres:17-alpine", "orbit", 5432), ("orbit-cache", "redis:7-alpine", "orbit", 6379),
                    ("atlas-api", "atlas/api:dev", "atlas", 8081), ("atlas-db", "postgres:17-alpine", "atlas", 5433),
                    ("mail-preview", "mailpit:latest", "", 8025), ("integration-tests", "node:22-alpine", "", 0)]
        return rows.enumerated().map { index, row in
            DockerContainerSummary(id: String(repeating: "\(index + 1)", count: 64), name: row.0, image: row.1,
                                   command: "", createdAt: Date(timeIntervalSince1970: 1_792_670_400),
                                   state: index == 7 ? .exited : .running,
                                   status: index == 7 ? "Exited (0) 8 minutes ago" : "Up 3 hours (healthy)",
                                   ports: row.3 == 0 ? [] : [.init(privatePort: row.3, publicPort: row.3, networkProtocol: "tcp")],
                                   labels: row.2.isEmpty ? [:] : ["com.docker.compose.project": row.2])
        }
    }

    func version() async throws -> DockerEngineVersion {
        DockerEngineVersion(version: "29.0.0", apiVersion: "1.43", os: "linux")
    }
    func containers() async throws -> [DockerContainerSummary] { Self.items }
    func perform(_ action: DockerContainerAction, containerID: String) async throws {
        throw SnapshotError.invalidOption("Snapshot services are read-only")
    }
    func containerEvents() -> AsyncThrowingStream<DockerEngineEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
