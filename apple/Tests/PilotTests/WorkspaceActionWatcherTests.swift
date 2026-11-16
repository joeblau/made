import Foundation
import Testing
@testable import Pilot

@Suite("Workspace repository watching")
struct WorkspaceActionWatcherTests {
    @Test("A failed first fetch does not create an empty baseline")
    func firstFailureThenRecovery() {
        var tracker = ActionCompletionTracker()
        #expect(tracker.ingest(.failure(.invalidJSON), isSelected: false) == 0)
        #expect(!tracker.hasBaseline)
        #expect(tracker.ingest(.success([10, 11]), isSelected: false) == 0)
        #expect(tracker.hasBaseline)
        #expect(tracker.seenCompleted == [10, 11])
    }

    @Test("Transient failures preserve the last successful snapshot")
    func transientFailureAfterBaseline() {
        var tracker = ActionCompletionTracker()
        #expect(tracker.ingest(.success([10]), isSelected: false) == 0)
        #expect(tracker.ingest(.failure(.invalidJSON), isSelected: false) == 0)
        #expect(tracker.seenCompleted == [10])
        #expect(tracker.ingest(.success([10, 11]), isSelected: false) == 1)
    }

    @Test("Open task snapshots decode counts and reject invalid payloads")
    func openTaskCountDecoding() throws {
        let data = Data(#"[{"number":1,"title":"One","url":"https://example.test/1","state":"OPEN","assignees":[],"createdAt":""},{"number":2,"title":"Two","url":"https://example.test/2","state":"OPEN","assignees":[],"createdAt":""}]"#.utf8)
        #expect(WorkspaceActionWatcher.openTaskCount(from: data) == 2)
        #expect(WorkspaceActionWatcher.openTaskCount(from: Data("[]".utf8)) == 0)
        #expect(WorkspaceActionWatcher.openTaskCount(from: Data("not json".utf8)) == nil)
    }

    @Test("Recent runs are deduplicated by attempt and ordered by activity")
    func recentRunProjection() {
        let first = UUID(), second = UUID(), other = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func run(workspaceID: UUID, runID: Int, status: String, checkedAt: Date) -> BuildWorkflowRun {
            BuildWorkflowRun(
                workspaceID: workspaceID, workspaceName: "Workspace", repository: "blau/made",
                runID: runID, attempt: 1, branch: "main", workflow: "CI", title: "Build",
                state: BuildActivityState(status: status, checkedAt: checkedAt.timeIntervalSince1970)
            )
        }
        let older = run(workspaceID: first, runID: 1, status: "completed", checkedAt: now.addingTimeInterval(-60))
        let newer = run(workspaceID: second, runID: 1, status: "completed", checkedAt: now)
        let active = run(workspaceID: other, runID: 2, status: "in_progress", checkedAt: now.addingTimeInterval(-120))
        let projected = WorkspaceActionWatcher.projectedRecentRuns(from: [
            first: [older], second: [newer], other: [active],
        ])
        #expect(projected.map(\.runID) == [2, 1])
        #expect(projected.last?.workspaceID == second)
    }

    @Test("Selected-workspace completions are recorded but never badge later")
    func selectedWorkspaceDoesNotDeferBadge() {
        var tracker = ActionCompletionTracker()
        #expect(tracker.ingest(.success([1]), isSelected: false) == 0)
        #expect(tracker.ingest(.success([1, 2]), isSelected: true) == 0)
        #expect(tracker.ingest(.success([1, 2]), isSelected: false) == 0)
    }
}
