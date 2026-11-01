import Foundation
import Testing
@testable import Copilot

@Suite("Dashboard snapshots")
struct DashboardSnapshotTests {
    private let updatedAt = 1_792_900_000.0

    @Test("Actions reuse workflow runs, enforce bounds, and round-trip their activity projection")
    func actionsBoundsAndRoundTrip() throws {
        let workspaceID = UUID()
        let runs = (0..<65).map { index in
            BuildWorkflowRun(
                workspaceID: workspaceID,
                workspaceName: "Workspace \(index)",
                repository: "blau/repository-\(index)",
                runID: index + 1,
                attempt: 2,
                branch: String(repeating: "b", count: 180),
                workflow: String(repeating: "w", count: 150),
                title: "Build \(index)",
                state: BuildActivityState(
                    status: index == 0 ? "completed" : "in_progress",
                    conclusion: index == 0 ? "failure" : nil,
                    startedAt: updatedAt - 60,
                    checkedAt: updatedAt
                )
            )
        }

        let snapshot = ActionsDashboardSnapshot(runs: runs, updatedAt: updatedAt)
        #expect(snapshot.version == ActionsDashboardSnapshot.schemaVersion)
        #expect(snapshot.runs.count == ActionsDashboardSnapshot.maxRuns)
        #expect(snapshot.updatedAt == updatedAt)
        #expect(snapshot.runs.first?.runID == 1)
        #expect(snapshot.runs.last?.runID == 60)

        let decoded = try JSONDecoder().decode(ActionsDashboardSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)

        let projection = snapshot.activityProjection
        #expect(projection.runs.count == ActionsDashboardActivityProjection.maxRuns)
        #expect(projection.runCount == 60)
        #expect(projection.activeCount == 59)
        #expect(projection.failureCount == 1)
        #expect(projection.runs.allSatisfy { $0.branch.count <= 60 && $0.workflow.count <= 80 && $0.repository.count <= 80 })
        #expect(projection.staleDate.timeIntervalSince1970 == updatedAt + DashboardFreshness.defaultStaleInterval)
        let decodedProjection = try JSONDecoder().decode(
            ActionsDashboardActivityProjection.self,
            from: JSONEncoder().encode(projection)
        )
        #expect(decodedProjection == projection)
    }

    @Test("Usage exposes only aggregate fields and bounds providers and estimates")
    func usagePrivacyBoundsAndRoundTrip() throws {
        let providers = (0..<7).map { index in
            UsageDashboardProviderSummary(
                id: "provider-\(index)",
                name: "Provider \(index)",
                estimatedCost: Double(index) + 0.5,
                totalTokens: 1_000 * (index + 1),
                planName: "Pro",
                plan: UsageDashboardUtilization(utilization: 1.4, resetAt: updatedAt + 3_600, updatedAt: updatedAt),
                windowName: "Five hours",
                window: UsageDashboardUtilization(utilization: 0.25, resetAt: updatedAt + 1_800, updatedAt: updatedAt)
            )
        }
        let snapshot = UsageDashboardSnapshot(
            updatedAt: updatedAt,
            estimatedCost: 42.75,
            inputTokens: 4_000,
            outputTokens: 2_000,
            totalTokens: 6_000,
            hasUnpricedModels: true,
            providers: providers
        )

        #expect(snapshot.providers.count == UsageDashboardSnapshot.maxProviders)
        #expect(snapshot.providers.first?.plan?.utilization == 1)
        #expect(snapshot.activityProjection.providers.count == UsageDashboardActivityProjection.maxProviders)
        #expect(snapshot.activityProjection.hasUnpricedModels)
        let decoded = try JSONDecoder().decode(UsageDashboardSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
        let decodedProjection = try JSONDecoder().decode(
            UsageDashboardActivityProjection.self,
            from: JSONEncoder().encode(snapshot.activityProjection)
        )
        #expect(decodedProjection == snapshot.activityProjection)

        let data = try JSONEncoder().encode(snapshot)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == [
            "version", "updatedAt", "estimatedCost", "inputTokens", "outputTokens",
            "totalTokens", "hasUnpricedModels", "providers"
        ])
        let encodedProviders = try #require(object["providers"] as? [[String: Any]])
        #expect(Set(try #require(encodedProviders.first).keys) == [
            "id", "name", "estimatedCost", "totalTokens", "planName", "plan", "windowName", "window"
        ])
        let encoded = String(decoding: data, as: UTF8.self)
        for forbidden in ["credential", "sessionID", "filePath", "rawRecords", "records"] {
            #expect(!encoded.contains(forbidden))
        }
    }

    @Test("Runners preserve full-fleet counts while bounding the sample")
    func runnersBoundsAndRoundTrip() throws {
        let runners = (0..<105).map { index in
            RunnersDashboardRunner(
                id: index + 1,
                name: "runner-\(index)-" + String(repeating: "n", count: 80),
                operatingSystem: "macOS",
                status: index.isMultiple(of: 4) ? "offline" : "online",
                busy: index.isMultiple(of: 2)
            )
        }
        let snapshot = RunnersDashboardSnapshot(
            enterpriseID: "enterprise-1",
            enterpriseName: "Blau",
            totalCount: 250,
            idleCount: 100,
            busyCount: 120,
            offlineCount: 30,
            runners: runners,
            updatedAt: updatedAt
        )

        #expect(snapshot.runners.count == RunnersDashboardSnapshot.maxRunners)
        #expect(snapshot.totalCount == 250)
        #expect(snapshot.idleCount == 100)
        #expect(snapshot.busyCount == 120)
        #expect(snapshot.offlineCount == 30)
        #expect(snapshot.updatedAt == updatedAt)
        let decoded = try JSONDecoder().decode(RunnersDashboardSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)

        let projection = snapshot.activityProjection
        #expect(projection.runners.count == RunnersDashboardActivityProjection.maxRunners)
        #expect(projection.totalCount == 250)
        #expect(projection.enterpriseName == "Blau")
        #expect(projection.runners.allSatisfy { $0.name.count <= 48 })
        let decodedProjection = try JSONDecoder().decode(
            RunnersDashboardActivityProjection.self,
            from: JSONEncoder().encode(projection)
        )
        #expect(decodedProjection == projection)
    }

    @Test("Freshness drives stale presentation at the timeline boundary")
    func freshness() {
        let snapshot = UsageDashboardSnapshot(
            updatedAt: updatedAt,
            estimatedCost: 0,
            totalTokens: 0,
            providers: []
        )
        #expect(!snapshot.isStale(at: updatedAt + DashboardFreshness.defaultStaleInterval))
        #expect(snapshot.isStale(at: updatedAt + DashboardFreshness.defaultStaleInterval + 1))
        #expect(!snapshot.isStale(at: updatedAt - 60))

        let unknown = UsageDashboardUtilization()
        #expect(unknown.isStale(at: updatedAt))
        let fresh = UsageDashboardUtilization(utilization: 0.5, updatedAt: updatedAt)
        #expect(!fresh.isStale(at: updatedAt + 60))
    }

    @Test("Family and widget identifiers remain stable")
    func stableIdentifiers() {
        #expect(DashboardFamily.allCases.map(\.rawValue) == ["actions", "usage", "runners"])
        #expect(DashboardWidgetKind.actions == "app.blau.dashboard.actions")
        #expect(DashboardWidgetKind.usage == "app.blau.dashboard.usage")
        #expect(DashboardWidgetKind.runners == "app.blau.dashboard.runners")
    }
}
