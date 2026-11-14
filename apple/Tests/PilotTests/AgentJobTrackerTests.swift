import AppKit
import Testing
@testable import Pilot

@Suite("Agent job tracker")
@MainActor
struct AgentJobTrackerTests {
    private let workspace = UUID()
    private let start = Date(timeIntervalSince1970: 1_000)

    private func observation(_ pane: UUID, _ signal: AgentJobObservation.Signal, title: String = "Agent") -> AgentJobObservation {
        AgentJobObservation(paneID: pane, workspaceID: workspace, title: title, agentName: "Claude", signal: signal)
    }

    @Test("An idle agent seen for the first time is waiting for input")
    func firstIdleSightingWaits() {
        var ledger = AgentJobLedger()
        let pane = UUID()
        let jobs = ledger.ingest([observation(pane, .idle)], focusedPaneID: nil, now: start)
        #expect(jobs.map(\.state) == [.waiting])
        #expect(jobs.first?.statusText == "Ready for input")
        #expect(jobs.first?.needsAttention == false)
    }

    @Test("A finished turn stays completed until its pane is seen")
    func finishedTurnCompletesUntilSeen() {
        var ledger = AgentJobLedger()
        let pane = UUID()
        _ = ledger.ingest([observation(pane, .working)], focusedPaneID: nil, now: start)
        let finished = ledger.ingest([observation(pane, .idle)], focusedPaneID: nil, now: start + 10)
        #expect(finished.map(\.state) == [.completed])
        #expect(finished.first?.since == start + 10)
        #expect(finished.first?.needsAttention == true)
        let later = ledger.ingest([observation(pane, .idle)], focusedPaneID: nil, now: start + 20)
        #expect(later.first?.state == .completed)
        #expect(later.first?.since == start + 10, "an unchanged state keeps its timestamp")
        let seen = ledger.markSeen(pane, now: start + 30)
        #expect(seen.map(\.state) == [.waiting])
        #expect(ledger.ingest([observation(pane, .idle)], focusedPaneID: nil, now: start + 40).first?.state == .waiting)
    }

    @Test("A turn finishing in the focused pane needs no completed notice")
    func focusedPaneSkipsCompleted() {
        var ledger = AgentJobLedger()
        let pane = UUID()
        _ = ledger.ingest([observation(pane, .working)], focusedPaneID: pane, now: start)
        #expect(ledger.ingest([observation(pane, .idle)], focusedPaneID: pane, now: start + 1).first?.state == .waiting)
    }

    @Test("A blocked agent waits with its reason and sorts first")
    func blockedAgentsLeadTheWaitingSection() {
        var ledger = AgentJobLedger()
        let ready = UUID(), blocked = UUID(), working = UUID()
        let jobs = ledger.ingest([
            observation(working, .working), observation(ready, .idle), observation(blocked, .blocked("Needs approval")),
        ], focusedPaneID: nil, now: start)
        #expect(jobs.map(\.paneID) == [blocked, ready, working])
        #expect(jobs.first?.statusText == "Needs approval")
        #expect(jobs.first?.needsAttention == true)
    }

    @Test("A job survives a missed poll and is forgotten after the limit")
    func missingJobsExpire() {
        var ledger = AgentJobLedger()
        let pane = UUID()
        _ = ledger.ingest([observation(pane, .working)], focusedPaneID: nil, now: start)
        #expect(ledger.ingest([], focusedPaneID: nil, now: start + 2).count == 1)
        #expect(ledger.ingest([observation(pane, .idle)], focusedPaneID: nil, now: start + 4).first?.state == .completed)
        for _ in 0..<AgentJobLedger.missingPollLimit { _ = ledger.ingest([], focusedPaneID: nil, now: start + 6) }
        #expect(ledger.jobs.isEmpty)
    }

    @Test("The tracker counts jobs that need attention")
    func trackerPublishesAttention() {
        let tracker = AgentJobTracker()
        let done = UUID(), busy = UUID()
        tracker.ingest([observation(done, .working), observation(busy, .working)], focusedPaneID: nil, now: start)
        #expect(tracker.attentionCount == 0)
        tracker.ingest([observation(done, .idle), observation(busy, .working)], focusedPaneID: nil, now: start + 1)
        #expect(tracker.attentionCount == 1)
        tracker.markSeen(done, now: start + 2)
        #expect(tracker.attentionCount == 0)
    }
}
