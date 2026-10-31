import Foundation

public struct DashboardSnapshotEnvelope: Codable, Hashable, Sendable {
    public let actions: ActionsDashboardSnapshot?
    public let usage: UsageDashboardSnapshot?
    public let runners: RunnersDashboardSnapshot?

    public init(
        actions: ActionsDashboardSnapshot? = nil,
        usage: UsageDashboardSnapshot? = nil,
        runners: RunnersDashboardSnapshot? = nil
    ) {
        self.actions = actions
        self.usage = usage
        self.runners = runners
    }
}
