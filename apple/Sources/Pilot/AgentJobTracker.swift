import AppKit
import Observation

/// Where an agentic job stands from the user's point of view. The raw order
/// is the Inbox's section order.
enum AgentJobState: Int, CaseIterable, Sendable {
    /// Blocked on the user, or idle at its prompt.
    case waiting
    /// A turn (or a background subagent) is running.
    case working
    /// A turn finished and its pane has not been looked at since.
    case completed

    var title: String {
        switch self {
        case .waiting: "Waiting for Input"
        case .working: "Working"
        case .completed: "Completed"
        }
    }
}

/// One poll's reading of an agent: a terminal agent or an Agent Chat session.
struct AgentJobObservation: Equatable, Sendable {
    enum Signal: Equatable, Sendable {
        case working
        case idle
        /// The agent cannot continue without the user; the reason is shown.
        case blocked(String)
    }

    let paneID: UUID
    let workspaceID: UUID
    let title: String
    let agentName: String
    let signal: Signal
}

struct AgentJob: Equatable, Identifiable, Sendable {
    let paneID: UUID
    let workspaceID: UUID
    var title: String
    var agentName: String
    var state: AgentJobState
    /// Why a waiting job is blocked ("Needs approval"); nil when it is only
    /// ready for the next prompt.
    var blocker: String?
    /// When the job entered `state`.
    var since: Date

    var id: UUID { paneID }
    /// Counted on the Inbox switcher: blocked on the user, or finished unseen.
    var needsAttention: Bool { state == .completed || blocker != nil }

    var statusText: String {
        switch state {
        case .waiting: blocker ?? "Ready for input"
        case .working: "Working"
        case .completed: "Finished"
        }
    }
}

/// Turns successive polls into job states. Pure, so the transitions are
/// testable without terminals or agent processes.
struct AgentJobLedger {
    /// A job missing from this many consecutive polls is forgotten. A cold
    /// terminal snapshot can drop a live agent from one or two polls, and
    /// that must not lose an unseen "Completed".
    static let missingPollLimit = 3

    private struct Entry {
        var job: AgentJob
        var missingPolls = 0
    }

    private var entries: [UUID: Entry] = [:]

    /// `focusedPaneID` is the pane the user is looking at: a turn finishing
    /// there needs no "Completed" notice.
    mutating func ingest(_ observations: [AgentJobObservation], focusedPaneID: UUID?, now: Date) -> [AgentJob] {
        var seen = Set<UUID>()
        for observation in observations where seen.insert(observation.paneID).inserted {
            let previous = entries[observation.paneID]?.job
            var state: AgentJobState
            var blocker: String?
            switch observation.signal {
            case .working: state = .working
            case .blocked(let reason): state = .waiting; blocker = reason
            case .idle:
                let finished = previous?.state == .working || previous?.state == .completed
                state = finished ? .completed : .waiting
            }
            if state == .completed, observation.paneID == focusedPaneID { state = .waiting }
            let unchanged = previous?.state == state && previous?.blocker == blocker
            entries[observation.paneID] = Entry(job: AgentJob(
                paneID: observation.paneID, workspaceID: observation.workspaceID, title: observation.title,
                agentName: observation.agentName, state: state, blocker: blocker,
                since: unchanged ? previous?.since ?? now : now
            ))
        }
        for id in entries.keys where !seen.contains(id) {
            entries[id]?.missingPolls += 1
            if entries[id]?.missingPolls ?? 0 >= Self.missingPollLimit { entries[id] = nil }
        }
        return jobs
    }

    /// The user opened the job's pane: a finished job is now only waiting.
    mutating func markSeen(_ paneID: UUID, now: Date) -> [AgentJob] {
        if entries[paneID]?.job.state == .completed {
            entries[paneID]?.job.state = .waiting
            entries[paneID]?.job.since = now
        }
        return jobs
    }

    /// Section order, blocked jobs first, then the most recent change first.
    var jobs: [AgentJob] {
        entries.values.map(\.job).sorted { lhs, rhs in
            if lhs.state != rhs.state { return lhs.state.rawValue < rhs.state.rawValue }
            if (lhs.blocker != nil) != (rhs.blocker != nil) { return lhs.blocker != nil }
            if lhs.since != rhs.since { return lhs.since > rhs.since }
            return lhs.paneID.uuidString < rhs.paneID.uuidString
        }
    }
}

/// Tracks every agentic job across all workspaces for the sidebar Inbox.
@MainActor
@Observable
final class AgentJobTracker {
    private(set) var jobs: [AgentJob] = []
    @ObservationIgnored private var ledger = AgentJobLedger()

    var attentionCount: Int { jobs.count(where: \.needsAttention) }

    /// Polls every workspace's agents. Terminal runtimes come from the shared
    /// per-tick tmux cache, so this adds no subprocess per pane.
    func refresh(store: WorkspaceStore, now: Date = Date()) {
        var focused: UUID?
        if NSApp.isActive, store.isWorkspaceDetailVisible { focused = store.selectedWorkspace?.selectedPaneID }
        ingest(store.workspaces.flatMap(Self.observations(in:)), focusedPaneID: focused, now: now)
    }

    func ingest(_ observations: [AgentJobObservation], focusedPaneID: UUID?, now: Date = Date()) {
        publish(ledger.ingest(observations, focusedPaneID: focusedPaneID, now: now))
    }

    func markSeen(_ paneID: UUID, now: Date = Date()) {
        publish(ledger.markSeen(paneID, now: now))
    }

    private func publish(_ next: [AgentJob]) {
        if next != jobs { jobs = next }
    }

    static func observations(in workspace: Workspace) -> [AgentJobObservation] {
        workspace.panes.compactMap { pane in
            let signal: AgentJobObservation.Signal
            let agentName: String
            switch pane.kind {
            case .terminal:
                guard let status = pane.liveShellAgentStatus() else { return nil }
                // Without the viewport these agents' activity cannot be read
                // yet; skipping the poll keeps the job's last known state.
                if status.agent.needsVisibleTerminalContentsForActivity, pane.visibleTerminalContents() == nil { return nil }
                agentName = status.agent.displayName
                signal = status.activity == .running ? .working : .idle
            case .agentChat:
                guard let session = AgentChatRegistry.shared.existingSession(for: pane.id),
                      let chatSignal = Self.signal(for: session) else { return nil }
                agentName = session.agent.displayName
                signal = chatSignal
            default: return nil
            }
            return AgentJobObservation(paneID: pane.id, workspaceID: workspace.id, title: pane.displayTitle,
                                       agentName: agentName, signal: signal)
        }
    }

    /// Nil for a session that was never started: there is no job yet.
    static func signal(for session: AgentChatSession) -> AgentJobObservation.Signal? {
        switch session.phase {
        case .idle: nil
        case .starting: .working
        case .prompting: session.pendingPermission == nil ? .working : .blocked("Needs approval")
        case .ready where session.pendingPermission != nil: .blocked("Needs approval")
        case .ready: session.hasBackgroundAgents ? .working : .idle
        case .needsSetup: .blocked("Needs setup")
        case .failed: .blocked("Failed")
        }
    }
}
