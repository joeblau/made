import Foundation
import Testing
@testable import Copilot

@Suite("Build monitoring")
struct BuildWorkflowRunTests {
    private let workspaceID = UUID()
    private let checkedAt = Date(timeIntervalSince1970: 1_792_900_000)
    private var response: [String: Any] {
        ["id": 123, "run_attempt": 2, "html_url": "https://github.com/blau/made/actions/runs/123",
         "url": "https://api.github.com/repos/blau/made/actions/runs/123", "status": "in_progress",
         "name": "Apple builds", "head_branch": "feature/build-monitor", "run_started_at": "2026-10-25T10:00:00Z"]
    }

    @Test("REST data prefers the human URL and preserves run attempt identity")
    func parseREST() throws {
        let run = try #require(BuildWorkflowRun.parse(response, workspaceID: workspaceID, workspaceName: "made", checkedAt: checkedAt))
        #expect(run.id == "blau/made/123/2")
        #expect(run.repository == "blau/made")
        #expect(run.branch == "feature/build-monitor")
        #expect(run.workflow == "Apple builds")
        #expect(run.state.label == "Running")
        #expect(run.state.startedAt != nil)
        #expect(run.state.checkedAt == checkedAt.timeIntervalSince1970)
        #expect(run.url.absoluteString == "https://github.com/blau/made/actions/runs/123/attempts/2")
    }

    @Test("Scheduler projection and REST data produce the same activity")
    func parseProjection() throws {
        let projected: [String: Any] = ["databaseId": 123, "attempt": 2, "url": "https://github.com/blau/made/actions/runs/123",
                                      "status": "in_progress", "name": "Apple builds", "headBranch": "feature/build-monitor",
                                      "startedAt": "2026-10-25T10:00:00Z"]
        let expected = BuildWorkflowRun.parse(response, workspaceID: workspaceID, workspaceName: "made", checkedAt: checkedAt)
        #expect(BuildWorkflowRun.parse(projected, workspaceID: workspaceID, workspaceName: "made", checkedAt: checkedAt) == expected)
    }

    @Test("Rejects untrusted hosts and mismatched run IDs")
    func rejectInvalidURL() {
        for url in ["http://github.com/blau/made/actions/runs/123", "https://evil.example/blau/made/actions/runs/123",
                    "https://github.com/blau/made/actions/runs/124", "https://github.com/blau/made/issues/123"] {
            var item = response
            item["html_url"] = url
            #expect(BuildWorkflowRun.parse(item, workspaceID: workspaceID, workspaceName: "made", checkedAt: checkedAt) == nil)
        }
    }

    @Test("Queued runs have no running timer; completion freezes the elapsed time")
    func timing() throws {
        var item = response
        item["status"] = "queued"
        let queued = try #require(BuildWorkflowRun.parse(item, workspaceID: workspaceID, workspaceName: "made", checkedAt: checkedAt))
        #expect(queued.state.startedAt == nil)
        item["status"] = "completed"
        item["conclusion"] = "failure"
        item["updated_at"] = "2026-10-25T10:05:00Z"
        let completed = try #require(BuildWorkflowRun.parse(item, workspaceID: workspaceID, workspaceName: "made", checkedAt: checkedAt))
        #expect(completed.state.label == "Failed")
        #expect(try #require(completed.state.finishedAt) - #require(completed.state.startedAt) == 300)
    }

    @Test("Older snapshots and running states cannot overwrite a terminal result")
    func ordering() {
        let running = BuildActivityState(status: "in_progress", checkedAt: 100)
        let completed = BuildActivityState(status: "completed", conclusion: "success", checkedAt: 101)
        #expect(completed.canReplace(running))
        #expect(!running.canReplace(completed))
        #expect(!BuildActivityState(status: "in_progress", checkedAt: 102).canReplace(completed))
        #expect(!BuildActivityState(status: "queued", checkedAt: 99).canReplace(running))
    }

    @Test("APNs content-state decodes with epoch-second timestamps")
    func wireFormat() throws {
        let data = Data(#"{"status":"completed","conclusion":"success","startedAt":1792900000,"finishedAt":1792900300,"checkedAt":1792900301}"#.utf8)
        let state = try JSONDecoder().decode(BuildActivityState.self, from: data)
        #expect(state.isComplete)
        #expect(state.startedAt == 1_792_900_000)
        #expect(state.staleDate.timeIntervalSince1970 == 1_792_900_421)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        #expect(encoded["startedAt"] as? Double == 1_792_900_000)
    }

    @Test("Legacy workspace snapshots decode without workflow runs")
    func oldSnapshot() throws {
        let state = try JSONDecoder().decode(WorkspaceState.self, from: Data(#"{"workspaces":[]}"#.utf8))
        #expect(state.workflowRuns == nil)
    }

    @Test("Workflow discovery and follow requests survive the encrypted-sync wire encoding")
    func syncRoundTrip() throws {
        let run = try #require(BuildWorkflowRun.parse(response, workspaceID: workspaceID, workspaceName: "made", checkedAt: checkedAt))
        var snapshot = WorkspaceState(workspaces: [], selectedWorkspaceID: nil)
        snapshot.workflowRuns = [run]
        let messages: [SyncMessage] = [.workspaceState(snapshot), .followBuild(BuildFollowRequest(runKey: run.id, capability: String(repeating: "ab", count: 32))), .unfollowBuild(BuildUnfollowRequest(runKey: run.id)), .buildRunUpdate(run)]
        for message in messages {
            let data = try JSONEncoder().encode(message)
            let decoded = try JSONDecoder().decode(SyncMessage.self, from: data)
            switch decoded {
            case .workspaceState(let value): #expect(value.workflowRuns == [run])
            case .followBuild(let value): #expect(value.runKey == run.id); #expect(value.capability?.count == 64)
            case .unfollowBuild(let value): #expect(value.runKey == run.id)
            case .buildRunUpdate(let value): #expect(value == run)
            default: Issue.record("Unexpected message")
            }
        }
    }
}
