import Foundation

public struct UsageDashboardUtilization: Codable, Hashable, Sendable {
    public let utilization: Double?
    public let resetAt: Double?
    public let updatedAt: Double?

    public init(utilization: Double? = nil, resetAt: Double? = nil, updatedAt: Double? = nil) {
        self.utilization = DashboardBound.utilization(utilization)
        self.resetAt = DashboardBound.optionalEpoch(resetAt)
        self.updatedAt = DashboardBound.optionalEpoch(updatedAt)
    }

    public func isStale(at now: Double, after interval: Double = DashboardFreshness.defaultStaleInterval) -> Bool {
        guard let updatedAt else { return true }
        return DashboardFreshness.isStale(updatedAt: updatedAt, at: now, after: interval)
    }
}

public struct UsageDashboardProviderSummary: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let estimatedCost: Double
    public let totalTokens: Int
    public let planName: String?
    public let plan: UsageDashboardUtilization?
    public let windowName: String?
    public let window: UsageDashboardUtilization?

    public init(
        id: String,
        name: String,
        estimatedCost: Double = 0,
        totalTokens: Int = 0,
        planName: String? = nil,
        plan: UsageDashboardUtilization? = nil,
        windowName: String? = nil,
        window: UsageDashboardUtilization? = nil
    ) {
        self.id = DashboardBound.string(id, max: 48)
        self.name = DashboardBound.string(name, max: 64)
        self.estimatedCost = DashboardBound.finite(estimatedCost)
        self.totalTokens = DashboardBound.count(totalTokens)
        self.planName = DashboardBound.optionalString(planName, max: 64)
        self.plan = plan.map { UsageDashboardUtilization(utilization: $0.utilization, resetAt: $0.resetAt, updatedAt: $0.updatedAt) }
        self.windowName = DashboardBound.optionalString(windowName, max: 64)
        self.window = window.map { UsageDashboardUtilization(utilization: $0.utilization, resetAt: $0.resetAt, updatedAt: $0.updatedAt) }
    }

    var compact: Self {
        Self(
            id: DashboardBound.string(id, max: 32),
            name: DashboardBound.string(name, max: 40),
            estimatedCost: estimatedCost,
            totalTokens: totalTokens,
            planName: DashboardBound.optionalString(planName, max: 40),
            plan: plan,
            windowName: DashboardBound.optionalString(windowName, max: 40),
            window: window
        )
    }
}

public struct UsageDashboardSnapshot: Codable, Hashable, Sendable {
    public static let schemaVersion = 1
    public static let maxProviders = 5

    public let version: Int
    public let updatedAt: Double
    public let estimatedCost: Double
    public let inputTokens: Int
    public let outputTokens: Int
    public let totalTokens: Int
    public let hasUnpricedModels: Bool
    public let providers: [UsageDashboardProviderSummary]

    public init(
        updatedAt: Double,
        estimatedCost: Double,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        totalTokens: Int,
        hasUnpricedModels: Bool = false,
        providers: [UsageDashboardProviderSummary]
    ) {
        version = Self.schemaVersion
        self.updatedAt = DashboardBound.epoch(updatedAt)
        self.estimatedCost = DashboardBound.finite(estimatedCost)
        self.inputTokens = DashboardBound.count(inputTokens)
        self.outputTokens = DashboardBound.count(outputTokens)
        self.totalTokens = DashboardBound.count(totalTokens)
        self.hasUnpricedModels = hasUnpricedModels
        self.providers = Array(providers.map(\.compact).prefix(Self.maxProviders))
    }

    public var activityProjection: UsageDashboardActivityProjection {
        UsageDashboardActivityProjection(
            updatedAt: updatedAt,
            estimatedCost: estimatedCost,
            totalTokens: totalTokens,
            hasUnpricedModels: hasUnpricedModels,
            providers: Array(providers.prefix(UsageDashboardActivityProjection.maxProviders))
        )
    }

    public func isStale(at now: Double, after interval: Double = DashboardFreshness.defaultStaleInterval) -> Bool {
        DashboardFreshness.isStale(updatedAt: updatedAt, at: now, after: interval)
    }

    private enum CodingKeys: String, CodingKey {
        case version, updatedAt, estimatedCost, inputTokens, outputTokens, totalTokens, hasUnpricedModels, providers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "Unsupported usage dashboard schema version")
        }
        self.init(
            updatedAt: try container.decode(Double.self, forKey: .updatedAt),
            estimatedCost: try container.decode(Double.self, forKey: .estimatedCost),
            inputTokens: try container.decode(Int.self, forKey: .inputTokens),
            outputTokens: try container.decode(Int.self, forKey: .outputTokens),
            totalTokens: try container.decode(Int.self, forKey: .totalTokens),
            hasUnpricedModels: try container.decode(Bool.self, forKey: .hasUnpricedModels),
            providers: try container.decode([UsageDashboardProviderSummary].self, forKey: .providers)
        )
    }
}

public struct UsageDashboardActivityProjection: Codable, Hashable, Sendable {
    public static let schemaVersion = 1
    public static let maxProviders = 3

    public let version: Int
    public let updatedAt: Double
    public let estimatedCost: Double
    public let totalTokens: Int
    public let hasUnpricedModels: Bool
    public let providers: [UsageDashboardProviderSummary]

    public init(
        updatedAt: Double,
        estimatedCost: Double,
        totalTokens: Int,
        hasUnpricedModels: Bool,
        providers: [UsageDashboardProviderSummary]
    ) {
        version = Self.schemaVersion
        self.updatedAt = DashboardBound.epoch(updatedAt)
        self.estimatedCost = DashboardBound.finite(estimatedCost)
        self.totalTokens = DashboardBound.count(totalTokens)
        self.hasUnpricedModels = hasUnpricedModels
        self.providers = Array(providers.map(\.compact).prefix(Self.maxProviders))
    }

    public var staleDate: Date {
        Date(timeIntervalSince1970: updatedAt + DashboardFreshness.defaultStaleInterval)
    }

    private enum CodingKeys: String, CodingKey {
        case version, updatedAt, estimatedCost, totalTokens, hasUnpricedModels, providers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "Unsupported usage activity schema version")
        }
        self.init(
            updatedAt: try container.decode(Double.self, forKey: .updatedAt),
            estimatedCost: try container.decode(Double.self, forKey: .estimatedCost),
            totalTokens: try container.decode(Int.self, forKey: .totalTokens),
            hasUnpricedModels: try container.decode(Bool.self, forKey: .hasUnpricedModels),
            providers: try container.decode([UsageDashboardProviderSummary].self, forKey: .providers)
        )
    }
}
