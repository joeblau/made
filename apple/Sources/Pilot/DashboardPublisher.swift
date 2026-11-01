import Foundation
import WidgetKit

struct UsageProviderProjection {
    let id: String
    let name: String
    let state: ProviderState
    let updatedAt: Date?
}

enum DashboardProjection {
    static func actions(
        runs: [BuildWorkflowRun],
        fallbackUpdatedAt: Date?
    ) -> ActionsDashboardSnapshot {
        let updatedAt = runs.map(\.state.checkedAt).max()
            ?? fallbackUpdatedAt?.timeIntervalSince1970
            ?? 0
        return ActionsDashboardSnapshot(runs: runs, updatedAt: updatedAt)
    }

    static func usage(
        agenticSnapshot: AgenticUseSnapshot?,
        agenticUpdatedAt: Date?,
        providers: [UsageProviderProjection]
    ) -> UsageDashboardSnapshot {
        let summaries = providers.compactMap { provider -> UsageDashboardProviderSummary? in
            let planUsage = provider.state.displayedUsage
            let totals = agenticSnapshot?.providerTotals.first { $0.provider.rawValue == provider.id }
            guard planUsage != nil || totals != nil else { return nil }
            let window = planUsage?.windowsInDisplayOrder.first
            return UsageDashboardProviderSummary(
                id: provider.id,
                name: provider.name,
                estimatedCost: totals?.estimatedCost ?? 0,
                totalTokens: totals?.totalTokens ?? 0,
                planName: planUsage?.planLabel,
                plan: planUsage?.credits?.utilization.map {
                    UsageDashboardUtilization(
                        utilization: $0,
                        updatedAt: provider.updatedAt?.timeIntervalSince1970
                    )
                },
                windowName: window?.name,
                window: window.map {
                    UsageDashboardUtilization(
                        utilization: $0.utilization,
                        resetAt: $0.resetsAt?.timeIntervalSince1970,
                        updatedAt: provider.updatedAt?.timeIntervalSince1970
                    )
                }
            )
        }
        var freshnessDates = providers.compactMap(\.updatedAt)
        if let agenticDate = agenticUpdatedAt ?? agenticSnapshot?.interval.end {
            freshnessDates.append(agenticDate)
        }
        let updatedAt = freshnessDates.max()?.timeIntervalSince1970 ?? 0
        return UsageDashboardSnapshot(
            updatedAt: updatedAt,
            estimatedCost: agenticSnapshot?.totalCostUSD ?? 0,
            inputTokens: (agenticSnapshot?.stats.uncachedInputTokens ?? 0)
                + (agenticSnapshot?.stats.cacheWriteTokens ?? 0)
                + (agenticSnapshot?.stats.cachedInputTokens ?? 0),
            outputTokens: agenticSnapshot?.stats.outputTokens ?? 0,
            totalTokens: agenticSnapshot?.stats.processedTokens ?? 0,
            hasUnpricedModels: agenticSnapshot?.hasUnpricedModels ?? false,
            providers: summaries
        )
    }

    static func runners(
        scope: RunnerScope?,
        snapshot: RunnersStore.Snapshot?
    ) -> RunnersDashboardSnapshot? {
        guard let scope, scope.kind == .enterprise,
              let snapshot, let updatedAt = snapshot.updatedAt else { return nil }
        let runners = snapshot.runners
        return RunnersDashboardSnapshot(
            enterpriseID: scope.id,
            enterpriseName: scope.name,
            totalCount: runners.count,
            idleCount: runners.count(where: { $0.state == .idle }),
            busyCount: runners.count(where: { $0.state == .busy }),
            offlineCount: runners.count(where: { $0.state == .offline }),
            runners: runners.prefix(RunnersDashboardSnapshot.maxRunners).map {
                RunnersDashboardRunner(
                    id: $0.id,
                    name: $0.name,
                    operatingSystem: $0.platform,
                    status: $0.status,
                    busy: $0.busy
                )
            },
            updatedAt: updatedAt.timeIntervalSince1970
        )
    }
}

@MainActor
enum DashboardDeepLink {
    static func open(_ url: URL, store: WorkspaceStore) -> Bool {
        guard url.scheme?.lowercased() == "cockpit",
              let host = url.host()?.lowercased(),
              let family = DashboardFamily(rawValue: host) else { return false }
        switch family {
        case .actions:
            guard let workspace = store.selectedWorkspace ?? store.workspaces.first else { return false }
            store.selectWorkspace(workspace.id)
            workspace.setInspectorTab(.actions)
            workspace.setInspectorPresented(true)
        case .usage:
            store.enterAgenticUseMode()
        case .runners:
            store.enterRunnersMode()
        }
        return true
    }
}

@MainActor
final class DashboardPublisher {
    private let actionWatcher: WorkspaceActionWatcher
    private let usageStore: UsageStore
    private let agenticUsageStore: AgenticUsageStore
    private let runnersStore: RunnersStore
    private let defaults: UserDefaults
    private let snapshotStore: DashboardSnapshotStore
    private let notificationCenter: NotificationCenter
    private let reloadTimelines: (DashboardFamily) -> Void

    private var timer: Timer?
    private var sharingObserver: NSObjectProtocol?
    private var initializedFamilies: Set<DashboardFamily> = []
    private var persistedActions: ActionsDashboardSnapshot?
    private var persistedUsage: UsageDashboardSnapshot?
    private var persistedRunners: RunnersDashboardSnapshot?

    private(set) var envelope = DashboardSnapshotEnvelope()
    var onEnvelopeChange: ((DashboardSnapshotEnvelope) -> Void)?

    init(
        actionWatcher: WorkspaceActionWatcher,
        usageStore: UsageStore,
        agenticUsageStore: AgenticUsageStore,
        runnersStore: RunnersStore,
        defaults: UserDefaults = .standard,
        snapshotStore: DashboardSnapshotStore = DashboardSnapshotStore(appGroup: "group.app.blau.pilot"),
        notificationCenter: NotificationCenter = .default,
        reloadTimelines: @escaping (DashboardFamily) -> Void = { family in
            let kind = switch family {
            case .actions: DashboardWidgetKind.actions
            case .usage: DashboardWidgetKind.usage
            case .runners: DashboardWidgetKind.runners
            }
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
    ) {
        self.actionWatcher = actionWatcher
        self.usageStore = usageStore
        self.agenticUsageStore = agenticUsageStore
        self.runnersStore = runnersStore
        self.defaults = defaults
        self.snapshotStore = snapshotStore
        self.notificationCenter = notificationCenter
        self.reloadTimelines = reloadTimelines
    }

    func start() {
        guard timer == nil else { return }
        publish()
        sharingObserver = notificationCenter.addObserver(
            forName: UsageDashboardSharing.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let sharingObserver {
            notificationCenter.removeObserver(sharingObserver)
        }
        sharingObserver = nil
    }

    func republish() {
        onEnvelopeChange?(envelope)
    }

    func publish() {
        let next = DashboardSnapshotEnvelope(
            actions: DashboardProjection.actions(
                runs: actionWatcher.recentRuns,
                fallbackUpdatedAt: actionWatcher.lastSuccessfulFetchAt
            ),
            usage: UsageDashboardSharing.isEnabled(defaults: defaults)
                ? DashboardProjection.usage(
                    agenticSnapshot: agenticUsageStore.snapshot,
                    agenticUpdatedAt: agenticUsageStore.lastUpdatedAt,
                    providers: usageStore.dashboardProviders
                )
                : nil,
            runners: runnersStore.dashboardSnapshot
        )
        persist(next)
        guard next != envelope else { return }
        envelope = next
        onEnvelopeChange?(next)
    }

    private func persist(_ next: DashboardSnapshotEnvelope) {
        if !initializedFamilies.contains(.actions) || persistedActions != next.actions,
           persistValue(next.actions, for: .actions) {
            persistedActions = next.actions
            initializedFamilies.insert(.actions)
        }
        if !initializedFamilies.contains(.usage) || persistedUsage != next.usage,
           persistValue(next.usage, for: .usage) {
            persistedUsage = next.usage
            initializedFamilies.insert(.usage)
        }
        if !initializedFamilies.contains(.runners) || persistedRunners != next.runners,
           persistValue(next.runners, for: .runners) {
            persistedRunners = next.runners
            initializedFamilies.insert(.runners)
        }
    }

    private func persistValue<Snapshot: Encodable>(_ snapshot: Snapshot?, for family: DashboardFamily) -> Bool {
        do {
            if let snapshot {
                try snapshotStore.write(snapshot, for: family)
            } else {
                try snapshotStore.clear(family)
            }
            reloadTimelines(family)
            return true
        } catch {
            return false
        }
    }
}
