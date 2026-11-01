import Foundation
import Testing
@testable import Copilot

@Suite("Copilot dashboard integration", .serialized)
@MainActor
struct CopilotDashboardTests {
    @Test("Only received families persist and reload, and old-peer payloads retain last-good data")
    func persistenceAndTargetedReloads() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DashboardSnapshotStore(directory: directory)
        var reloaded: [DashboardFamily] = []
        let model = CopilotDashboardModel(store: store, reloadTimeline: { reloaded.append($0) })
        let actions = ActionsDashboardSnapshot(updatedAt: 100, runs: [])
        let usage = UsageDashboardSnapshot(updatedAt: 200, estimatedCost: 4.25, totalTokens: 800, providers: [])
        let runners = RunnersDashboardSnapshot(
            enterpriseID: "enterprise",
            enterpriseName: "Enterprise",
            totalCount: 3,
            idleCount: 1,
            busyCount: 1,
            offlineCount: 1,
            runners: [],
            updatedAt: 300
        )

        model.receive(actions: actions, usage: nil, runners: nil)
        #expect(model.actions == actions)
        #expect(store.read(ActionsDashboardSnapshot.self, for: .actions) == actions)
        #expect(reloaded == [.actions])

        model.receive(actions: nil, usage: usage, runners: runners)
        #expect(reloaded == [.actions, .usage, .runners])
        #expect(store.read(UsageDashboardSnapshot.self, for: .usage) == usage)
        #expect(store.read(RunnersDashboardSnapshot.self, for: .runners) == runners)

        model.receive(actions: nil, usage: nil, runners: nil)
        #expect(reloaded == [.actions, .usage, .runners])
        #expect(model.actions == actions)
        #expect(model.usage == usage)
        #expect(model.runners == runners)
        #expect(store.read(ActionsDashboardSnapshot.self, for: .actions) == actions)
        #expect(store.read(UsageDashboardSnapshot.self, for: .usage) == usage)
        #expect(store.read(RunnersDashboardSnapshot.self, for: .runners) == runners)

        let restored = CopilotDashboardModel(store: store, reloadTimeline: { _ in
            Issue.record("Launch restoration must not reload widget timelines")
        })
        #expect(restored.actions == actions)
        #expect(restored.usage == usage)
        #expect(restored.runners == runners)
    }

    @Test("Dashboard deep links select their family", arguments: [
        DashboardFamily.actions, DashboardFamily.usage, DashboardFamily.runners,
    ])
    func dashboardDeepLinks(family: DashboardFamily) throws {
        let url = try #require(URL(string: "walkie://\(family.rawValue)"))
        #expect(CopilotDeepLink(url: url) == .dashboard(family))
    }

    @Test("Build deep links remain distinct and unrelated URLs are ignored")
    func buildAndInvalidDeepLinks() throws {
        let build = try #require(URL(string: "walkie://build/repository/123"))
        #expect(CopilotDeepLink(url: build) == .build)
        for string in ["https://actions", "walkie://unknown", "walkie:actions"] {
            let url = try #require(URL(string: string))
            #expect(CopilotDeepLink(url: url) == nil)
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CopilotDashboardTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
