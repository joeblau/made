import ActivityKit
import Foundation

public struct ActionsDashboardActivityAttributes: ActivityAttributes {
    public typealias ContentState = ActionsDashboardActivityProjection

    public let urlScheme: String

    public init(urlScheme: String) {
        self.urlScheme = DashboardBound.string(urlScheme, max: 32)
    }

    public var deepLink: URL? {
        URL(string: "\(urlScheme)://\(DashboardFamily.actions.urlPath)")
    }
}

public struct UsageDashboardActivityAttributes: ActivityAttributes {
    public typealias ContentState = UsageDashboardActivityProjection

    public let urlScheme: String

    public init(urlScheme: String) {
        self.urlScheme = DashboardBound.string(urlScheme, max: 32)
    }

    public var deepLink: URL? {
        URL(string: "\(urlScheme)://\(DashboardFamily.usage.urlPath)")
    }
}

public struct RunnersDashboardActivityAttributes: ActivityAttributes {
    public typealias ContentState = RunnersDashboardActivityProjection

    public let urlScheme: String

    public init(urlScheme: String) {
        self.urlScheme = DashboardBound.string(urlScheme, max: 32)
    }

    public var deepLink: URL? {
        URL(string: "\(urlScheme)://\(DashboardFamily.runners.urlPath)")
    }
}
