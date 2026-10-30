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

    @Test("BLAU enterprise sources use the enterprise API and settings page")
    func enterpriseRouting() throws {
        let enterprise = try #require(RunnerScope.parse(" BLAU ", kind: .enterprise))
        #expect(enterprise == RunnerScope(kind: .enterprise, name: "BLAU"))
        #expect(enterprise.endpoint == "enterprises/blau/actions/runners?per_page=100")
        #expect(enterprise.settingsURL?.absoluteString == "https://github.com/enterprises/blau/settings/actions/runners")
        #expect(enterprise.id == RunnerScope.parse("blau", kind: .enterprise)?.id)
        #expect(enterprise.id != RunnerScope.parse("BLAU", kind: .organization)?.id)
        for input in ["", "../blau", "blau/actions", "blau?per_page=1", "blau#fragment", "bl au", "-blau"] {
            #expect(RunnerScope.parse(input, kind: .enterprise) == nil)
        }
    }

    @Test("Enterprise access failures explain the enterprise token scope", arguments: [403, 404])
    func enterpriseAccessGuidance(status: Int) {
        let result = ProcessRunResult(
            termination: .exit(1), standardOutput: Data(), standardError: Data("HTTP \(status)".utf8),
            standardOutputTruncated: false, standardErrorTruncated: false,
            elapsed: .zero, redactedCommand: "gh api"
        )
        let message = RunnersAPI.message(for: ProcessRunnerError.nonZeroExit(result), scope: RunnerScope(kind: .enterprise, name: "BLAU"))
        #expect(message.contains("manage_runners:enterprise"))
        #expect(!message.contains("admin:org"))
        #expect(!message.contains("Actions read"))
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
        #expect(restored.scopes == [org, repo])
        #expect(restored.selectedScopeID == repo.id)
        restored.selectedScopeID = org.id
        #expect(restored.hardware(for: runner) == .macMini)
        #expect(restored.displayName(for: runner) == "Build Mac")
        restored.remove(org)
        #expect(restored.selectedScopeID == repo.id)
        #expect(RunnersStore(defaults: defaults).scopes == [repo])
    }

    @Test("An empty fleet makes no runner requests", arguments: [false, true])
    func emptyFleetDoesNotFetch(restored: Bool) async throws {
        let suite = "RunnersTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        if restored {
            defaults.set(try JSONEncoder().encode([RunnerScope]()), forKey: "runners.scopes")
        }
        let probe = RunnerScopeFetchProbe()
        let store = RunnersStore(defaults: defaults) { scope in await probe.fetch(scope) }
        #expect(store.scopes.isEmpty)
        #expect(store.selectedScope == nil)
        await store.refreshSelected()
        #expect(await probe.scopes.isEmpty)
    }

    @Test("Enterprise, organization, and repository sources are independently added, scanned, and restored")
    func supportsAllSourceTypes() async throws {
        let suite = "RunnersTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = RunnerScopeFetchProbe()
        let store = RunnersStore(defaults: defaults) { scope in await probe.fetch(scope) }
        let scopes = [
            RunnerScope(kind: .enterprise, name: "BLAU"),
            RunnerScope(kind: .organization, name: "bloxwap"),
            RunnerScope(kind: .repository, name: "bloxwap/build"),
        ]
        for scope in scopes {
            #expect(store.add(scope))
            await store.refreshSelected()
        }
        #expect(await probe.scopes == scopes)
        #expect(store.scopes == scopes)
        let restored = RunnersStore(defaults: defaults)
        #expect(restored.scopes == scopes)
        #expect(restored.selectedScope == scopes.last)
        #expect(!restored.add(RunnerScope(kind: .enterprise, name: "blau")))
        #expect(restored.scopes == scopes)
        #expect(restored.selectedScopeID == scopes.first?.id)
    }

    @Test("Existing Bloxwap and BLAU sources keep their selection and separate device customizations")
    func savedSourcesAreUnchanged() throws {
        let suite = "RunnersTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let organization = RunnerScope(kind: .organization, name: "bloxwap")
        let enterprise = RunnerScope(kind: .enterprise, name: "BLAU")
        let scopes = [organization, enterprise, RunnerScope(kind: .repository, name: "bloxwap/build")]
        let appearances = [
            "\(organization.id):1": RunnerPresentation(name: "Organization Mac", hardware: .macMini),
            "\(enterprise.id):2": RunnerPresentation(name: "Enterprise Mac", hardware: .macStudio),
        ]
        defaults.set(try JSONEncoder().encode(scopes), forKey: "runners.scopes")
        defaults.set(organization.id, forKey: "runners.selectedScope")
        defaults.set(try JSONEncoder().encode(appearances), forKey: "runners.presentations")

        let store = RunnersStore(defaults: defaults)
        #expect(store.scopes == scopes)
        #expect(store.selectedScope == organization)
        #expect(store.presentations == appearances)
        store.selectedScopeID = enterprise.id
        #expect(store.presentation(for: RunnersTests.runner()) == RunnerPresentation())
        #expect(store.displayName(for: RunnersTests.runner(id: 2)) == "Enterprise Mac")
    }

    @Test("A removed enterprise is not automatically re-added")
    func removedEnterpriseStaysRemoved() throws {
        let suite = "RunnersTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RunnersStore(defaults: defaults)
        let organization = RunnerScope(kind: .organization, name: "bloxwap")
        let enterprise = RunnerScope(kind: .enterprise, name: "BLAU")
        store.add(organization)
        store.add(enterprise)
        store.remove(enterprise)

        let restored = RunnersStore(defaults: defaults)
        #expect(restored.scopes == [organization])
        #expect(restored.selectedScope == organization)
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

private actor RunnerScopeFetchProbe {
    private(set) var scopes: [RunnerScope] = []

    func fetch(_ scope: RunnerScope) -> [GitHubRunner] {
        scopes.append(scope)
        return [RunnersTests.runner()]
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
