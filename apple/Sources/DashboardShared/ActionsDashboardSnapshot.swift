import Foundation

public struct ActionsDashboardRun: Codable, Hashable, Sendable {
    public let workspaceName: String
    public let repository: String
    public let runID: Int
    public let attempt: Int
    public let branch: String
    public let workflow: String
    public let title: String
    public let status: String
    public let conclusion: String?
    public let startedAt: Double?
    public let finishedAt: Double?

    public var id: String { "\(repository.lowercased())/\(runID)/\(attempt)" }
    public var isComplete: Bool { status == "completed" }
    public var isActive: Bool { !isComplete }
    public var isFailure: Bool {
        isComplete && ["failure", "startup_failure", "timed_out"].contains(conclusion)
    }

    public var label: String {
        if isComplete {
            switch conclusion {
            case "success": return "Succeeded"
            case "failure", "startup_failure": return "Failed"
            case "cancelled": return "Cancelled"
            case "timed_out": return "Timed out"
            case "skipped": return "Skipped"
            case "neutral": return "Completed"
            case "action_required": return "Action required"
            default: return "Completed"
            }
        }
        switch status {
        case "in_progress": return "Running"
        case "waiting": return "Waiting"
        case "queued", "requested", "pending": return "Queued"
        default: return "Status unavailable"
        }
    }

    public var systemImage: String {
        guard isComplete else { return status == "in_progress" ? "gearshape.2" : "clock" }
        switch conclusion {
        case "success": return "checkmark.circle.fill"
        case "failure", "startup_failure", "timed_out": return "xmark.circle.fill"
        case "cancelled": return "minus.circle"
        default: return "checkmark.circle"
        }
    }

    public init(
        workspaceName: String,
        repository: String,
        runID: Int,
        attempt: Int = 1,
        branch: String,
        workflow: String,
        title: String = "",
        status: String,
        conclusion: String? = nil,
        startedAt: Double? = nil,
        finishedAt: Double? = nil
    ) {
        self.workspaceName = DashboardBound.string(workspaceName, max: 100)
        self.repository = DashboardBound.string(repository, max: 100)
        self.runID = max(0, runID)
        self.attempt = max(1, attempt)
        self.branch = DashboardBound.string(branch, max: 200)
        self.workflow = DashboardBound.string(workflow, max: 120)
        self.title = DashboardBound.string(title, max: 200)
        self.status = DashboardBound.string(status, max: 32)
        self.conclusion = DashboardBound.optionalString(conclusion, max: 32)
        self.startedAt = DashboardBound.optionalEpoch(startedAt)
        self.finishedAt = DashboardBound.optionalEpoch(finishedAt)
    }

    init(_ run: BuildWorkflowRun) {
        self.init(
            workspaceName: run.workspaceName,
            repository: run.repository,
            runID: run.runID,
            attempt: run.attempt,
            branch: run.branch,
            workflow: run.workflow,
            title: run.title,
            status: run.state.status,
            conclusion: run.state.conclusion,
            startedAt: run.state.startedAt,
            finishedAt: run.state.finishedAt
        )
    }

    var compact: Self {
        Self(
            workspaceName: DashboardBound.string(workspaceName, max: 40),
            repository: DashboardBound.string(repository, max: 80),
            runID: runID,
            attempt: attempt,
            branch: DashboardBound.string(branch, max: 60),
            workflow: DashboardBound.string(workflow, max: 80),
            title: DashboardBound.string(title, max: 80),
            status: status,
            conclusion: conclusion,
            startedAt: startedAt,
            finishedAt: finishedAt
        )
    }
}

public struct ActionsDashboardSnapshot: Codable, Hashable, Sendable {
    public static let schemaVersion = 1
    public static let maxRuns = 60

    public let version: Int
    public let updatedAt: Double
    public let runs: [ActionsDashboardRun]

    public init(updatedAt: Double, runs: [ActionsDashboardRun]) {
        version = Self.schemaVersion
        self.updatedAt = DashboardBound.epoch(updatedAt)
        self.runs = Array(runs.map(\.compact).prefix(Self.maxRuns))
    }

    init(runs: [BuildWorkflowRun], updatedAt: Double) {
        self.init(updatedAt: updatedAt, runs: runs.map(ActionsDashboardRun.init))
    }

    public var activityProjection: ActionsDashboardActivityProjection {
        ActionsDashboardActivityProjection(
            updatedAt: updatedAt,
            runCount: runs.count,
            activeCount: runs.filter(\.isActive).count,
            failureCount: runs.filter(\.isFailure).count,
            runs: Array(runs.prefix(ActionsDashboardActivityProjection.maxRuns))
        )
    }

    public func isStale(at now: Double, after interval: Double = DashboardFreshness.defaultStaleInterval) -> Bool {
        DashboardFreshness.isStale(updatedAt: updatedAt, at: now, after: interval)
    }

    private enum CodingKeys: String, CodingKey {
        case version, updatedAt, runs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "Unsupported Actions dashboard schema version")
        }
        self.init(
            updatedAt: try container.decode(Double.self, forKey: .updatedAt),
            runs: try container.decode([ActionsDashboardRun].self, forKey: .runs)
        )
    }
}

public struct ActionsDashboardActivityProjection: Codable, Hashable, Sendable {
    public static let schemaVersion = 1
    public static let maxRuns = 3

    public let version: Int
    public let updatedAt: Double
    public let runCount: Int
    public let activeCount: Int
    public let failureCount: Int
    public let runs: [ActionsDashboardRun]

    public init(
        updatedAt: Double,
        runCount: Int,
        activeCount: Int,
        failureCount: Int,
        runs: [ActionsDashboardRun]
    ) {
        version = Self.schemaVersion
        self.updatedAt = DashboardBound.epoch(updatedAt)
        self.runCount = DashboardBound.count(runCount)
        self.activeCount = DashboardBound.count(activeCount)
        self.failureCount = DashboardBound.count(failureCount)
        self.runs = Array(runs.map(\.compact).prefix(Self.maxRuns))
    }

    public var staleDate: Date {
        Date(timeIntervalSince1970: updatedAt + DashboardFreshness.defaultStaleInterval)
    }

    private enum CodingKeys: String, CodingKey {
        case version, updatedAt, runCount, activeCount, failureCount, runs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "Unsupported Actions activity schema version")
        }
        self.init(
            updatedAt: try container.decode(Double.self, forKey: .updatedAt),
            runCount: try container.decode(Int.self, forKey: .runCount),
            activeCount: try container.decode(Int.self, forKey: .activeCount),
            failureCount: try container.decode(Int.self, forKey: .failureCount),
            runs: try container.decode([ActionsDashboardRun].self, forKey: .runs)
        )
    }
}
