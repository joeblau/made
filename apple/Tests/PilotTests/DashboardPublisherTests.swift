import Foundation
import Testing
@testable import Pilot

@Suite("Dashboard projections and publication")
@MainActor
struct DashboardPublisherTests {
    @Test("Actions preserve the actual checked-at freshness")
    func actionsFreshness() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let older = now.addingTimeInterval(-30 * 60)
        let snapshot = DashboardProjection.actions(
            runs: [
                workflowRun(id: 1, checkedAt: older),
                workflowRun(id: 2, checkedAt: older.addingTimeInterval(60)),
            ],
            fallbackUpdatedAt: now
        )

        #expect(snapshot.updatedAt == older.addingTimeInterval(60).timeIntervalSince1970)
        #expect(snapshot.isStale(at: now.timeIntervalSince1970))
        #expect(snapshot.updatedAt != now.timeIntervalSince1970)
    }

    @Test("Usage exports only aggregates and preserves unpriced-model and plan state")
    func usageProjection() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let records = [
            usageRecord(provider: .claude, at: now.addingTimeInterval(-60), nativeCostUSD: 1.25),
            usageRecord(provider: .codex, at: now.addingTimeInterval(-60), nativeCostUSD: nil),
        ]
        let agentic = AgenticUsageStore.makeSnapshot(
            records: records,
            range: .day,
            now: now,
            calendar: calendar,
            rates: [:]
        )
        let resetAt = now.addingTimeInterval(3_600)
        let providerUpdatedAt = now.addingTimeInterval(-60)
        let snapshot = DashboardProjection.usage(
            agenticSnapshot: agentic,
            agenticUpdatedAt: now.addingTimeInterval(-120),
            providers: [
                UsageProviderProjection(
                    id: "claude",
                    name: "Claude",
                    state: .usage(ProviderUsage(
                        planLabel: "Max",
                        windows: [UsageWindow(
                            id: "five-hour",
                            name: "5-hour",
                            utilization: 0.42,
                            resetsAt: resetAt
                        )],
                        credits: CreditInfo(utilization: 0.25)
                    )),
                    updatedAt: providerUpdatedAt
                ),
                UsageProviderProjection(id: "codex", name: "Codex", state: .disabled, updatedAt: nil),
            ]
        )

        #expect(snapshot.estimatedCost == 1.25)
        #expect(snapshot.inputTokens == 300)
        #expect(snapshot.outputTokens == 100)
        #expect(snapshot.totalTokens == 400)
        #expect(snapshot.hasUnpricedModels)
        #expect(snapshot.updatedAt == providerUpdatedAt.timeIntervalSince1970)
        #expect(snapshot.providers.count == 2)
        #expect(snapshot.providers[0].estimatedCost == 1.25)
        #expect(snapshot.providers[0].totalTokens == 200)
        #expect(snapshot.providers[0].planName == "Max")
        #expect(snapshot.providers[0].plan?.utilization == 0.25)
        #expect(snapshot.providers[0].window?.utilization == 0.42)
        #expect(snapshot.providers[0].window?.resetAt == resetAt.timeIntervalSince1970)
        #expect(snapshot.providers[0].window?.updatedAt == providerUpdatedAt.timeIntervalSince1970)

        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        for forbidden in ["secret-session", "dedupKey", "rawRecords", "records", "model"] {
            #expect(!encoded.contains(forbidden))
        }
    }

    @Test("Usage sharing defaults off and revocation clears only the usage timeline")
    func usageRevocation() throws {
        let suite = "DashboardPublisherTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!UsageDashboardSharing.isEnabled(defaults: defaults))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshotStore = DashboardSnapshotStore(directory: directory)
        var reloadedFamilies: [DashboardFamily] = []
        var published: [DashboardSnapshotEnvelope] = []
        let publisher = DashboardPublisher(
            actionWatcher: WorkspaceActionWatcher(),
            usageStore: UsageStore(defaults: defaults),
            agenticUsageStore: AgenticUsageStore(
                defaults: defaults,
                sources: [],
                cacheURL: directory.appendingPathComponent("usage-cache")
            ),
            runnersStore: RunnersStore(defaults: defaults),
            defaults: defaults,
            snapshotStore: snapshotStore,
            reloadTimelines: { reloadedFamilies.append($0) }
        )
        publisher.onEnvelopeChange = { published.append($0) }

        defaults.set(true, forKey: UsageDashboardSharing.preferenceKey)
        publisher.publish()
        #expect(publisher.envelope.usage != nil)
        #expect(snapshotStore.read(UsageDashboardSnapshot.self, for: .usage) != nil)

        reloadedFamilies.removeAll()
        publisher.publish()
        #expect(reloadedFamilies.isEmpty)

        defaults.set(false, forKey: UsageDashboardSharing.preferenceKey)
        publisher.publish()
        #expect(publisher.envelope.usage == nil)
        #expect(snapshotStore.read(UsageDashboardSnapshot.self, for: .usage) == nil)
        #expect(reloadedFamilies == [.usage])
        #expect(published.count == 2)
        #expect(published.last?.usage == nil)
    }

    private func workflowRun(id: Int, checkedAt: Date) -> BuildWorkflowRun {
        BuildWorkflowRun(
            workspaceID: UUID(),
            workspaceName: "Workspace",
            repository: "blau/made",
            runID: id,
            attempt: 1,
            branch: "main",
            workflow: "CI",
            title: "Build",
            state: BuildActivityState(status: "completed", checkedAt: checkedAt.timeIntervalSince1970)
        )
    }

    private func usageRecord(
        provider: AgenticProvider,
        at timestamp: Date,
        nativeCostUSD: Double?
    ) -> AgenticUsageRecord {
        AgenticUsageRecord(
            provider: provider,
            dedupKey: "secret-session",
            model: "unpriced-test-model",
            timestamp: timestamp,
            inputTokens: 100,
            cacheWriteTokens: 20,
            cacheWrite1hTokens: 0,
            cacheReadTokens: 30,
            outputTokens: 50,
            thinkingTokens: nil,
            isFast: false,
            nativeCostUSD: nativeCostUSD
        )
    }
}
