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

    @Test("Selected-workspace completions are recorded but never badge later")
    func selectedWorkspaceDoesNotDeferBadge() {
        var tracker = ActionCompletionTracker()
        #expect(tracker.ingest(.success([1]), isSelected: false) == 0)
        #expect(tracker.ingest(.success([1, 2]), isSelected: true) == 0)
        #expect(tracker.ingest(.success([1, 2]), isSelected: false) == 0)
    }
}
