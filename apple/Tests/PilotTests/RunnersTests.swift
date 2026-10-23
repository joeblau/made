import Foundation
import Testing
@testable import Pilot

@Suite("GitHub runner sources and responses")
struct RunnersTests {
    @Test("Source names cannot inject query parameters or traverse API paths")
    func validatesScope() throws {
        let org = try #require(RunnerScope.parse(" example-org ", kind: .organization))
        #expect(org.endpoint == "orgs/example-org/actions/runners?per_page=100")
        let repo = try #require(RunnerScope.parse("example-org/build_tools.swift", kind: .repository))
        #expect(repo.endpoint == "repos/example-org/build_tools.swift/actions/runners?per_page=100")
        for input in ["", "../repo", "org/..", "org/.", "org/repo/extra", "org/repo?per_page=1", "org/repo#fragment"] {
            #expect(RunnerScope.parse(input, kind: .repository) == nil)
        }
        #expect(RunnerScope.parse("org/repo", kind: .organization) == nil)
        #expect(RunnerScope.parse("-org", kind: .organization) == nil)
        #expect(RunnerScope.parse("ORG", kind: .organization)?.id == RunnerScope.parse("org", kind: .organization)?.id)
        #expect(org.settingsURL?.absoluteString == "https://github.com/organizations/example-org/settings/actions/runners")
    }

    @Test("Paginated responses combine runners and deduplicate moving page boundaries")
    func paginatedResponse() throws {
        let data = Data("""
        [
          {"runners":[{"id":1,"name":"zeta","os":"macos","status":"online","busy":true,"labels":[{"name":"ARM64","type":"read-only"}]}]},
          {"runners":[{"id":1,"name":"zeta","os":"macos","status":"online","busy":true,"labels":[]},
            {"id":2,"name":"alpha","os":"linux","status":"offline","busy":true,"labels":[]}]}
        ]
        """.utf8)
        let runners = try RunnersAPI.decode(data)
        #expect(runners.map(\.id) == [2, 1])
        #expect(runners[0].state == .offline)
        #expect(runners[1].state == .busy)
        #expect(runners[1].platform == "macOS")
        #expect(runners[1].architecture == "ARM64")
        #expect(throws: (any Error).self) { try RunnersAPI.decode(Data("{}".utf8)) }
    }

    @Test("Hardware is inferred from runner names and custom labels")
    func hardwareInference() {
        #expect(RunnerHardware.inferred(for: Self.runner(name: "build-mac-mini-m4")) == .macMini)
        #expect(RunnerHardware.inferred(for: Self.runner(name: "build", labels: ["mac-studio"])) == .macStudio)
        #expect(RunnerHardware.inferred(for: Self.runner(name: "MacPro-2013")) == .macProCylinder)
        #expect(RunnerHardware.inferred(for: Self.runner(name: "MacBook-Pro")) == .macBook)
        #expect(RunnerHardware.inferred(for: Self.runner(name: "unknown", os: "windows")) == .desktop)
        #expect(RunnerHardware.inferred(for: Self.runner(name: "unknown")) == .mac)
        #expect(RunnerHardware.inferred(for: Self.runner(name: "unknown", os: "linux")) == .server)
    }

    static func runner(id: Int = 1, name: String = "runner", os: String = "macos", labels: [String] = []) -> GitHubRunner {
        GitHubRunner(id: id, name: name, os: os, status: "online", busy: false,
                     labels: labels.map { GitHubRunner.Label(name: $0, type: "custom") })
    }
}

@Suite("Runner tracking", .serialized)
@MainActor
struct RunnersStoreTests {
    @Test("Tabs, selection, and per-source device names survive relaunch")
    func persistence() throws {
        let suite = "RunnersTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RunnersStore(defaults: defaults)
        let org = try #require(RunnerScope.parse("example", kind: .organization))
        let repo = try #require(RunnerScope.parse("example/repo", kind: .repository))
        #expect(store.add(org))
        #expect(!store.add(try #require(RunnerScope.parse("EXAMPLE", kind: .organization))))
        let runner = RunnersTests.runner()
        store.savePresentation(RunnerPresentation(name: " Build Mac ", hardware: .macMini), runner: runner, scope: org)
        #expect(store.displayName(for: runner) == "Build Mac")
        store.add(repo)
        #expect(store.displayName(for: runner) == runner.name)
        let restored = RunnersStore(defaults: defaults)
        #expect(restored.scopes.count == 2)
        #expect(restored.selectedScopeID == repo.id)
        restored.selectedScopeID = org.id
        #expect(restored.hardware(for: runner) == .macMini)
        #expect(restored.displayName(for: runner) == "Build Mac")
        restored.remove(org)
        #expect(restored.selectedScopeID == repo.id)
        #expect(RunnersStore(defaults: defaults).scopes == [repo])
    }

    @Test("A failed refresh keeps the last successful runner status with an error")
    func retainsLastSuccessfulRefresh() async throws {
        let suite = "RunnersTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = RunnerRefreshProbe()
        let store = RunnersStore(defaults: defaults) { _ in try await probe.fetch() }
        store.add(try #require(RunnerScope.parse("example", kind: .organization)))
        await store.refreshSelected()
        #expect(store.snapshot.runners.count == 1)
        #expect(store.snapshot.updatedAt != nil)
        await store.refreshSelected()
        #expect(store.snapshot.runners.count == 1)
        #expect(store.snapshot.error != nil)
        #expect(!store.isRefreshing)
        store.searchText = "nonexistent"
        #expect(store.visibleRunners.isEmpty)
    }

    @Test("A removed source cannot be repopulated by a late refresh")
    func removedSourceIgnoresLateResponse() async throws {
        let suite = "RunnersTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = SuspendedRunnerFetch()
        let store = RunnersStore(defaults: defaults) { _ in await probe.fetch() }
        let scope = try #require(RunnerScope.parse("example", kind: .organization))
        store.add(scope)
        let task = Task { await store.refreshSelected() }
        while !(await probe.started) { await Task.yield() }
        store.remove(scope)
        await probe.finish()
        await task.value
        #expect(store.snapshots[scope.id] == nil)
        #expect(store.refreshing.isEmpty)
    }
}

private actor RunnerRefreshProbe {
    private var calls = 0
    private enum Failure: Error { case offline }

    func fetch() throws -> [GitHubRunner] {
        calls += 1
        if calls > 1 { throw Failure.offline }
        return [RunnersTests.runner()]
    }
}

private actor SuspendedRunnerFetch {
    private var continuation: CheckedContinuation<[GitHubRunner], Never>?
    var started: Bool { continuation != nil }

    func fetch() async -> [GitHubRunner] {
        await withCheckedContinuation { continuation = $0 }
    }

    func finish() {
        continuation?.resume(returning: [RunnersTests.runner()])
        continuation = nil
    }
}
