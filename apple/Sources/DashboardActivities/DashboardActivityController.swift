import Combine
import Foundation
@preconcurrency import ActivityKit

public enum DashboardActivityError: Error, Equatable, LocalizedError {
    case activitiesDisabled

    public var errorDescription: String? {
        switch self {
        case .activitiesDisabled:
            "Enable Live Activities in Settings to start dashboard updates."
        }
    }
}

@MainActor
public final class DashboardActivityController: ObservableObject {
    @Published public private(set) var activeFamilies: Set<DashboardFamily> = []
    @Published public private(set) var lastError: String?

    public let urlScheme: String

    private var actionsActivity: Activity<ActionsDashboardActivityAttributes>?
    private var usageActivity: Activity<UsageDashboardActivityAttributes>?
    private var runnersActivity: Activity<RunnersDashboardActivityAttributes>?
    private var observationTasks: [DashboardFamily: Task<Void, Never>] = [:]

    public init(urlScheme: String) {
        self.urlScheme = DashboardBound.string(urlScheme, max: 32)
        restore()
    }

    public func restore() {
        restoreActions()
        restoreUsage()
        restoreRunners()
    }

    public func startActions(_ snapshot: ActionsDashboardSnapshot) async throws {
        if actionsActivity != nil {
            await updateActions(snapshot)
            lastError = nil
            return
        }
        try requireAuthorization()
        do {
            let projection = snapshot.activityProjection
            let activity = try Activity.request(
                attributes: ActionsDashboardActivityAttributes(urlScheme: urlScheme),
                content: ActivityContent(state: projection, staleDate: projection.staleDate)
            )
            actionsActivity = activity
            activeFamilies.insert(.actions)
            lastError = nil
            observe(activity, family: .actions)
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    public func startUsage(_ snapshot: UsageDashboardSnapshot) async throws {
        if usageActivity != nil {
            await updateUsage(snapshot)
            lastError = nil
            return
        }
        try requireAuthorization()
        do {
            let projection = snapshot.activityProjection
            let activity = try Activity.request(
                attributes: UsageDashboardActivityAttributes(urlScheme: urlScheme),
                content: ActivityContent(state: projection, staleDate: projection.staleDate)
            )
            usageActivity = activity
            activeFamilies.insert(.usage)
            lastError = nil
            observe(activity, family: .usage)
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    public func startRunners(_ snapshot: RunnersDashboardSnapshot) async throws {
        if runnersActivity != nil {
            await updateRunners(snapshot)
            lastError = nil
            return
        }
        try requireAuthorization()
        do {
            let projection = snapshot.activityProjection
            let activity = try Activity.request(
                attributes: RunnersDashboardActivityAttributes(urlScheme: urlScheme),
                content: ActivityContent(state: projection, staleDate: projection.staleDate)
            )
            runnersActivity = activity
            activeFamilies.insert(.runners)
            lastError = nil
            observe(activity, family: .runners)
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    public func toggleActions(_ snapshot: ActionsDashboardSnapshot) async throws {
        if activeFamilies.contains(.actions) {
            await stop(.actions)
        } else {
            try await startActions(snapshot)
        }
    }

    public func toggleUsage(_ snapshot: UsageDashboardSnapshot) async throws {
        if activeFamilies.contains(.usage) {
            await stop(.usage)
        } else {
            try await startUsage(snapshot)
        }
    }

    public func toggleRunners(_ snapshot: RunnersDashboardSnapshot) async throws {
        if activeFamilies.contains(.runners) {
            await stop(.runners)
        } else {
            try await startRunners(snapshot)
        }
    }

    public func stop(_ family: DashboardFamily) async {
        observationTasks[family]?.cancel()
        observationTasks[family] = nil
        activeFamilies.remove(family)

        switch family {
        case .actions:
            let activity = actionsActivity
            actionsActivity = nil
            await activity?.end(nil, dismissalPolicy: .immediate)
        case .usage:
            let activity = usageActivity
            usageActivity = nil
            await activity?.end(nil, dismissalPolicy: .immediate)
        case .runners:
            let activity = runnersActivity
            runnersActivity = nil
            await activity?.end(nil, dismissalPolicy: .immediate)
        }
    }

    public func stopAll() async {
        for family in DashboardFamily.allCases {
            await stop(family)
        }
    }

    public func updateActions(_ snapshot: ActionsDashboardSnapshot) async {
        guard let activity = actionsActivity, isActive(activity.activityState) else { return }
        let projection = snapshot.activityProjection
        guard projection.updatedAt > activity.content.state.updatedAt else { return }
        await activity.update(ActivityContent(state: projection, staleDate: projection.staleDate))
    }

    public func updateUsage(_ snapshot: UsageDashboardSnapshot) async {
        guard let activity = usageActivity, isActive(activity.activityState) else { return }
        let projection = snapshot.activityProjection
        guard projection.updatedAt > activity.content.state.updatedAt else { return }
        await activity.update(ActivityContent(state: projection, staleDate: projection.staleDate))
    }

    public func updateRunners(_ snapshot: RunnersDashboardSnapshot) async {
        guard let activity = runnersActivity, isActive(activity.activityState) else { return }
        let projection = snapshot.activityProjection
        guard projection.updatedAt > activity.content.state.updatedAt else { return }
        await activity.update(ActivityContent(state: projection, staleDate: projection.staleDate))
    }

    private func requireAuthorization() throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            let error = DashboardActivityError.activitiesDisabled
            lastError = error.errorDescription
            throw error
        }
    }

    private func isActive(_ state: ActivityState) -> Bool {
        state == .active || state == .stale
    }

    private func restoreActions() {
        guard actionsActivity == nil else { return }
        let activities = Activity<ActionsDashboardActivityAttributes>.activities.filter { isActive($0.activityState) }
        guard let activity = activities.first else { return }
        actionsActivity = activity
        activeFamilies.insert(.actions)
        observe(activity, family: .actions)
        for orphan in activities.dropFirst() {
            Task { await orphan.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func restoreUsage() {
        guard usageActivity == nil else { return }
        let activities = Activity<UsageDashboardActivityAttributes>.activities.filter { isActive($0.activityState) }
        guard let activity = activities.first else { return }
        usageActivity = activity
        activeFamilies.insert(.usage)
        observe(activity, family: .usage)
        for orphan in activities.dropFirst() {
            Task { await orphan.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func restoreRunners() {
        guard runnersActivity == nil else { return }
        let activities = Activity<RunnersDashboardActivityAttributes>.activities.filter { isActive($0.activityState) }
        guard let activity = activities.first else { return }
        runnersActivity = activity
        activeFamilies.insert(.runners)
        observe(activity, family: .runners)
        for orphan in activities.dropFirst() {
            Task { await orphan.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func observe<Attributes: ActivityAttributes>(
        _ activity: Activity<Attributes>,
        family: DashboardFamily
    ) {
        observationTasks[family]?.cancel()
        observationTasks[family] = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled else { return }
                if state == .ended || state == .dismissed {
                    self?.activityDidEnd(family, activityID: activity.id)
                    return
                }
            }
        }
    }

    private func activityDidEnd(_ family: DashboardFamily, activityID: String) {
        observationTasks[family] = nil
        switch family {
        case .actions:
            guard actionsActivity?.id == activityID else { return }
            actionsActivity = nil
        case .usage:
            guard usageActivity?.id == activityID else { return }
            usageActivity = nil
        case .runners:
            guard runnersActivity?.id == activityID else { return }
            runnersActivity = nil
        }
        activeFamilies.remove(family)
    }
}
