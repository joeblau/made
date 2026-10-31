import Foundation
import Observation
import WidgetKit

@MainActor
@Observable
final class CopilotDashboardModel {
    static let appGroup = "group.app.blau.copilot"

    private(set) var actions: ActionsDashboardSnapshot?
    private(set) var usage: UsageDashboardSnapshot?
    private(set) var runners: RunnersDashboardSnapshot?
    private(set) var persistenceError: String?

    @ObservationIgnored private let store: DashboardSnapshotStore
    @ObservationIgnored private weak var activities: DashboardActivityController?
    @ObservationIgnored private let reloadTimeline: (DashboardFamily) -> Void

    init(
        store: DashboardSnapshotStore = DashboardSnapshotStore(appGroup: CopilotDashboardModel.appGroup),
        activities: DashboardActivityController? = nil,
        reloadTimeline: @escaping (DashboardFamily) -> Void = { family in
            let kind: String
            switch family {
            case .actions: kind = DashboardWidgetKind.actions
            case .usage: kind = DashboardWidgetKind.usage
            case .runners: kind = DashboardWidgetKind.runners
            }
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
    ) {
        self.store = store
        self.activities = activities
        self.reloadTimeline = reloadTimeline
        actions = store.read(ActionsDashboardSnapshot.self, for: .actions)
        usage = store.read(UsageDashboardSnapshot.self, for: .usage)
        runners = store.read(RunnersDashboardSnapshot.self, for: .runners)
    }

    func receive(
        actions: ActionsDashboardSnapshot?,
        usage: UsageDashboardSnapshot?,
        runners: RunnersDashboardSnapshot?
    ) {
        var received: [DashboardFamily] = []
        var persistenceFailed = false

        if let actions {
            self.actions = actions
            received.append(.actions)
            persistenceFailed = !persist(actions, for: .actions) || persistenceFailed
        }
        if let usage {
            self.usage = usage
            received.append(.usage)
            persistenceFailed = !persist(usage, for: .usage) || persistenceFailed
        }
        if let runners {
            self.runners = runners
            received.append(.runners)
            persistenceFailed = !persist(runners, for: .runners) || persistenceFailed
        }

        guard !received.isEmpty else { return }
        persistenceError = persistenceFailed
            ? "Some dashboard data could not be saved for relaunch. Last-good data remains available."
            : nil
        received.forEach(reloadTimeline)
        updateActivities(for: received)
    }

    func restoreActivities() {
        activities?.restore()
        updateActivities(for: DashboardFamily.allCases)
    }

    private func persist<Snapshot: Encodable>(_ snapshot: Snapshot, for family: DashboardFamily) -> Bool {
        do {
            try store.write(snapshot, for: family)
            return true
        } catch {
            return false
        }
    }

    private func updateActivities(for families: [DashboardFamily]) {
        guard let activities else { return }
        let actions = actions
        let usage = usage
        let runners = runners
        Task {
            for family in families {
                switch family {
                case .actions:
                    if let actions { await activities.updateActions(actions) }
                case .usage:
                    if let usage { await activities.updateUsage(usage) }
                case .runners:
                    if let runners { await activities.updateRunners(runners) }
                }
            }
        }
    }
}
