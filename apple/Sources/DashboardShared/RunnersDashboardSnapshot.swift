import Foundation

public struct RunnersDashboardRunner: Codable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let operatingSystem: String
    public let status: String
    public let busy: Bool

    public var isOffline: Bool { status == "offline" }
    public var label: String {
        if isOffline { return "Offline" }
        return busy ? "Busy" : "Idle"
    }

    public var systemImage: String {
        if isOffline { return "xmark.circle.fill" }
        return busy ? "gearshape.2" : "checkmark.circle.fill"
    }

    public init(id: Int, name: String, operatingSystem: String = "", status: String, busy: Bool = false) {
        self.id = max(0, id)
        self.name = DashboardBound.string(name, max: 100)
        self.operatingSystem = DashboardBound.string(operatingSystem, max: 32)
        self.status = DashboardBound.string(status, max: 32)
        self.busy = busy
    }

    var compact: Self {
        Self(
            id: id,
            name: DashboardBound.string(name, max: 48),
            operatingSystem: DashboardBound.string(operatingSystem, max: 16),
            status: DashboardBound.string(status, max: 16),
            busy: busy
        )
    }
}

public struct RunnersDashboardSnapshot: Codable, Hashable, Sendable {
    public static let schemaVersion = 1
    public static let maxRunners = 100

    public let version: Int
    public let enterpriseID: String
    public let enterpriseName: String
    public let totalCount: Int
    public let idleCount: Int
    public let busyCount: Int
    public let offlineCount: Int
    public let runners: [RunnersDashboardRunner]
    public let updatedAt: Double

    public init(
        enterpriseID: String,
        enterpriseName: String,
        totalCount: Int,
        idleCount: Int,
        busyCount: Int,
        offlineCount: Int,
        runners: [RunnersDashboardRunner],
        updatedAt: Double
    ) {
        version = Self.schemaVersion
        self.enterpriseID = DashboardBound.string(enterpriseID, max: 100)
        self.enterpriseName = DashboardBound.string(enterpriseName, max: 100)
        self.totalCount = DashboardBound.count(totalCount)
        self.idleCount = DashboardBound.count(idleCount)
        self.busyCount = DashboardBound.count(busyCount)
        self.offlineCount = DashboardBound.count(offlineCount)
        self.runners = Array(runners.map(\.compact).prefix(Self.maxRunners))
        self.updatedAt = DashboardBound.epoch(updatedAt)
    }

    public var activityProjection: RunnersDashboardActivityProjection {
        RunnersDashboardActivityProjection(
            enterpriseName: enterpriseName,
            totalCount: totalCount,
            idleCount: idleCount,
            busyCount: busyCount,
            offlineCount: offlineCount,
            runners: Array(runners.prefix(RunnersDashboardActivityProjection.maxRunners)),
            updatedAt: updatedAt
        )
    }

    public func isStale(at now: Double, after interval: Double = DashboardFreshness.defaultStaleInterval) -> Bool {
        DashboardFreshness.isStale(updatedAt: updatedAt, at: now, after: interval)
    }

    private enum CodingKeys: String, CodingKey {
        case version, enterpriseID, enterpriseName, totalCount, idleCount, busyCount, offlineCount, runners, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "Unsupported runners dashboard schema version")
        }
        self.init(
            enterpriseID: try container.decode(String.self, forKey: .enterpriseID),
            enterpriseName: try container.decode(String.self, forKey: .enterpriseName),
            totalCount: try container.decode(Int.self, forKey: .totalCount),
            idleCount: try container.decode(Int.self, forKey: .idleCount),
            busyCount: try container.decode(Int.self, forKey: .busyCount),
            offlineCount: try container.decode(Int.self, forKey: .offlineCount),
            runners: try container.decode([RunnersDashboardRunner].self, forKey: .runners),
            updatedAt: try container.decode(Double.self, forKey: .updatedAt)
        )
    }
}

public struct RunnersDashboardActivityProjection: Codable, Hashable, Sendable {
    public static let schemaVersion = 1
    public static let maxRunners = 3

    public let version: Int
    public let enterpriseName: String
    public let totalCount: Int
    public let idleCount: Int
    public let busyCount: Int
    public let offlineCount: Int
    public let runners: [RunnersDashboardRunner]
    public let updatedAt: Double

    public init(
        enterpriseName: String,
        totalCount: Int,
        idleCount: Int,
        busyCount: Int,
        offlineCount: Int,
        runners: [RunnersDashboardRunner],
        updatedAt: Double
    ) {
        version = Self.schemaVersion
        self.enterpriseName = DashboardBound.string(enterpriseName, max: 60)
        self.totalCount = DashboardBound.count(totalCount)
        self.idleCount = DashboardBound.count(idleCount)
        self.busyCount = DashboardBound.count(busyCount)
        self.offlineCount = DashboardBound.count(offlineCount)
        self.runners = Array(runners.map(\.compact).prefix(Self.maxRunners))
        self.updatedAt = DashboardBound.epoch(updatedAt)
    }

    public var staleDate: Date {
        Date(timeIntervalSince1970: updatedAt + DashboardFreshness.defaultStaleInterval)
    }

    private enum CodingKeys: String, CodingKey {
        case version, enterpriseName, totalCount, idleCount, busyCount, offlineCount, runners, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "Unsupported runners activity schema version")
        }
        self.init(
            enterpriseName: try container.decode(String.self, forKey: .enterpriseName),
            totalCount: try container.decode(Int.self, forKey: .totalCount),
            idleCount: try container.decode(Int.self, forKey: .idleCount),
            busyCount: try container.decode(Int.self, forKey: .busyCount),
            offlineCount: try container.decode(Int.self, forKey: .offlineCount),
            runners: try container.decode([RunnersDashboardRunner].self, forKey: .runners),
            updatedAt: try container.decode(Double.self, forKey: .updatedAt)
        )
    }
}
