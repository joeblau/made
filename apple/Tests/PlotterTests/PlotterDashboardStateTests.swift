import Foundation
import Testing
@testable import Plotter

@Suite("Plotter dashboard integration", .serialized)
struct PlotterDashboardStateTests {
    @Test("Partial updates preserve last-good snapshots and report only received families")
    func partialUpdates() {
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
        var snapshots = PlotterDashboardSnapshots()

        #expect(snapshots.apply(DashboardSnapshotEnvelope(actions: actions)) == [.actions])
        #expect(snapshots.apply(DashboardSnapshotEnvelope()) == [])
        #expect(snapshots.actions == actions)
        #expect(snapshots.usage == nil)
        #expect(snapshots.runners == nil)

        #expect(snapshots.apply(usage: usage, runners: runners) == [.usage, .runners])
        #expect(snapshots.actions == actions)
        #expect(snapshots.usage == usage)
        #expect(snapshots.runners == runners)

        let replacement = ActionsDashboardSnapshot(updatedAt: 400, runs: [])
        #expect(snapshots.apply(actions: replacement, usage: nil, runners: nil) == [.actions])
        #expect(snapshots.actions == replacement)
        #expect(snapshots.usage == usage)
        #expect(snapshots.runners == runners)
    }

    @Test("Persisted family files restore independently at startup")
    func persistenceAndStartupRestore() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DashboardSnapshotStore(directory: directory)
        let actions = ActionsDashboardSnapshot(updatedAt: 100, runs: [])
        let usage = UsageDashboardSnapshot(updatedAt: 200, estimatedCost: 0, totalTokens: 0, providers: [])
        let runners = RunnersDashboardSnapshot(
            enterpriseID: "enterprise",
            enterpriseName: "Enterprise",
            totalCount: 0,
            idleCount: 0,
            busyCount: 0,
            offlineCount: 0,
            runners: [],
            updatedAt: 300
        )

        try store.write(actions, for: .actions)
        try store.write(usage, for: .usage)
        try store.write(runners, for: .runners)
        let restored = PlotterDashboardSnapshots(store: store)

        #expect(restored.actions == actions)
        #expect(restored.usage == usage)
        #expect(restored.runners == runners)
    }

    @Test("Dashboard deep links select their family", arguments: [
        DashboardFamily.actions, DashboardFamily.usage, DashboardFamily.runners,
    ])
    func dashboardDeepLinks(family: DashboardFamily) throws {
        let url = try #require(URL(string: "kneeboard://\(family.rawValue)"))
        #expect(PlotterDashboardRoute(url: url)?.family == family)
        let pathURL = try #require(URL(string: "kneeboard:///\(family.rawValue)"))
        #expect(PlotterDashboardRoute(url: pathURL)?.family == family)
    }

    @Test("Unrelated and malformed deep links are ignored")
    func invalidDeepLinks() throws {
        for string in [
            "https://actions",
            "kneeboard://unknown",
            "kneeboard://actions/extra",
            "kneeboard://actions?push=true",
            "kneeboard://user@actions",
            "kneeboard:",
        ] {
            let url = try #require(URL(string: string))
            #expect(PlotterDashboardRoute(url: url) == nil)
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PlotterDashboardStateTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
