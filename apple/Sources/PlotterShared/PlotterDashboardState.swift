import Foundation

public struct PlotterDashboardSnapshots: Equatable, Sendable {
    public private(set) var actions: ActionsDashboardSnapshot?
    public private(set) var usage: UsageDashboardSnapshot?
    public private(set) var runners: RunnersDashboardSnapshot?

    public init(
        actions: ActionsDashboardSnapshot? = nil,
        usage: UsageDashboardSnapshot? = nil,
        runners: RunnersDashboardSnapshot? = nil
    ) {
        self.actions = actions
        self.usage = usage
        self.runners = runners
    }

    public init(store: DashboardSnapshotStore) {
        self.init(
            actions: store.read(ActionsDashboardSnapshot.self, for: .actions),
            usage: store.read(UsageDashboardSnapshot.self, for: .usage),
            runners: store.read(RunnersDashboardSnapshot.self, for: .runners)
        )
    }

    @discardableResult
    public mutating func apply(_ envelope: DashboardSnapshotEnvelope) -> Set<DashboardFamily> {
        apply(actions: envelope.actions, usage: envelope.usage, runners: envelope.runners)
    }

    @discardableResult
    public mutating func apply(
        actions: ActionsDashboardSnapshot? = nil,
        usage: UsageDashboardSnapshot? = nil,
        runners: RunnersDashboardSnapshot? = nil
    ) -> Set<DashboardFamily> {
        var updated: Set<DashboardFamily> = []
        if let actions {
            self.actions = actions
            updated.insert(.actions)
        }
        if let usage {
            self.usage = usage
            updated.insert(.usage)
        }
        if let runners {
            self.runners = runners
            updated.insert(.runners)
        }
        return updated
    }
}

public struct PlotterDashboardRoute: Equatable, Sendable {
    public static let urlScheme = "kneeboard"

    public let family: DashboardFamily

    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == Self.urlScheme,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil else { return nil }

        let route: String
        if let host = components.host, !host.isEmpty {
            guard components.path.isEmpty || components.path == "/" else { return nil }
            route = host
        } else {
            let components = components.path.split(separator: "/")
            guard components.count == 1 else { return nil }
            route = String(components[0])
        }

        guard let family = DashboardFamily(rawValue: route.lowercased()) else { return nil }
        self.family = family
    }
}
