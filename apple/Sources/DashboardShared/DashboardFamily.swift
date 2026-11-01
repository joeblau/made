import Foundation

public enum DashboardFamily: String, Codable, CaseIterable, Sendable {
    case actions
    case usage
    case runners

    public var title: String {
        switch self {
        case .actions: "Actions"
        case .usage: "AI Usage"
        case .runners: "Runners"
        }
    }

    public var urlPath: String { rawValue }
}

public enum DashboardWidgetKind {
    public static let actions = "app.blau.dashboard.actions"
    public static let usage = "app.blau.dashboard.usage"
    public static let runners = "app.blau.dashboard.runners"
}

public enum DashboardFreshness {
    public static let defaultStaleInterval: Double = 15 * 60

    public static func isStale(
        updatedAt: Double,
        at now: Double,
        after interval: Double = defaultStaleInterval
    ) -> Bool {
        now - updatedAt > max(0, interval)
    }
}

enum DashboardBound {
    static func string(_ value: String, max length: Int) -> String {
        String(value.prefix(length))
    }

    static func optionalString(_ value: String?, max length: Int) -> String? {
        value.map { string($0, max: length) }
    }

    static func count(_ value: Int) -> Int {
        max(0, value)
    }

    static func finite(_ value: Double, minimum: Double = 0) -> Double {
        value.isFinite ? max(minimum, value) : minimum
    }

    static func epoch(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }

    static func optionalEpoch(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    static func utilization(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(1, max(0, value))
    }
}
