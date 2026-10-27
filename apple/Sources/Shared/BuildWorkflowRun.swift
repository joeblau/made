import Foundation

/// Epoch seconds are explicit so Swift and the APNs provider encode identical content state.
struct BuildActivityState: Codable, Hashable, Sendable {
    var status: String
    var conclusion: String?
    var startedAt: Double?
    var finishedAt: Double?
    var checkedAt: Double

    var isComplete: Bool { status == "completed" }
    var label: String {
        if isComplete {
            switch conclusion {
            case "success": return "Succeeded"
            case "failure", "startup_failure": return "Failed"
            case "cancelled": return "Cancelled"
            case "timed_out": return "Timed out"
            case "skipped": return "Skipped"
            case "neutral": return "Completed · neutral"
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
    var symbol: String {
        guard isComplete else { return status == "in_progress" ? "gearshape.2" : "clock" }
        switch conclusion {
        case "success": return "checkmark.circle.fill"
        case "failure", "startup_failure", "timed_out": return "xmark.circle.fill"
        case "cancelled": return "minus.circle"
        default: return "checkmark.circle"
        }
    }
    var staleDate: Date { Date(timeIntervalSince1970: checkedAt + 120) }

    func canReplace(_ previous: Self) -> Bool {
        checkedAt >= previous.checkedAt && (!previous.isComplete || isComplete)
    }
}

struct BuildWorkflowRun: Codable, Hashable, Identifiable, Sendable {
    let workspaceID: UUID
    let workspaceName: String
    let repository: String
    let runID: Int
    let attempt: Int
    let branch: String
    let workflow: String
    let title: String
    var state: BuildActivityState

    var id: String { "\(repository.lowercased())/\(runID)/\(attempt)" }
    var url: URL { URL(string: "https://github.com/\(repository)/actions/runs/\(runID)/attempts/\(attempt)")! }

    /// Accepts the scheduler's projection and GitHub's individual-run response.
    static func parse(_ item: [String: Any], workspaceID: UUID, workspaceName: String, checkedAt: Date) -> Self? {
        guard let runID = (item["databaseId"] ?? item["id"]) as? Int, runID > 0,
              let rawURL = (item["html_url"] ?? item["url"]) as? String,
              let url = URL(string: rawURL), url.scheme == "https", url.host == "github.com" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 5, parts[2] == "actions", parts[3] == "runs", Int(parts[4]) == runID,
              parts.prefix(2).allSatisfy({ $0.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil }) else { return nil }
        let status = item["status"] as? String ?? "unknown"
        func timestamp(_ first: String, _ second: String) -> Double? {
            guard let value = (item[first] ?? item[second]) as? String else { return nil }
            return ISO8601DateFormatter().date(from: value)?.timeIntervalSince1970
        }
        let started = timestamp("startedAt", "run_started_at")
        return Self(
            workspaceID: workspaceID, workspaceName: String(workspaceName.prefix(100)),
            repository: parts.prefix(2).joined(separator: "/"), runID: runID,
            attempt: max(1, (item["attempt"] ?? item["run_attempt"]) as? Int ?? 1),
            branch: String(((item["headBranch"] ?? item["head_branch"]) as? String ?? "").prefix(200)),
            workflow: String((item["name"] as? String ?? "Workflow").prefix(120)),
            title: String(((item["displayTitle"] ?? item["display_title"]) as? String ?? "").prefix(200)),
            state: BuildActivityState(
                status: status, conclusion: status == "completed" ? (item["conclusion"] as? String).flatMap { $0.isEmpty ? nil : $0 } : nil,
                startedAt: status == "in_progress" || status == "completed" ? started : nil,
                finishedAt: status == "completed" ? timestamp("updatedAt", "updated_at") : nil,
                checkedAt: checkedAt.timeIntervalSince1970
            )
        )
    }
}

struct BuildFollowRequest: Codable, Sendable {
    let runKey: String
    /// A per-activity capability, exchanged only over the authenticated peer connection.
    let capability: String?
}

struct BuildUnfollowRequest: Codable, Sendable {
    let runKey: String
}
