import Foundation

enum ActionRunFetchError: Error, Sendable {
    case launchFailed(String)
    case commandFailed(Int32)
    case invalidJSON
}

struct ActionCompletionTracker {
    private(set) var seenCompleted: Set<Int> = []
    private(set) var hasBaseline = false

    /// Returns the number of genuinely new completions to badge. A failed fetch
    /// is not an empty snapshot: it leaves both baseline and history untouched.
    mutating func ingest(_ result: Result<Set<Int>, ActionRunFetchError>, isSelected: Bool) -> Int {
        guard case .success(let completed) = result else { return 0 }
        guard hasBaseline else {
            seenCompleted = completed
            hasBaseline = true
            return 0
        }
        let fresh = completed.subtracting(seenCompleted)
        seenCompleted.formUnion(completed)
        return isSelected ? 0 : fresh.count
    }
}

/// Background poller that badges a workspace when a GitHub Action run completes
/// for its repo while you're looking at a *different* workspace. Complements
/// the terminal-bell badge (which already covers "a CLI finished"). The active
/// `RepositoryStore` only polls the selected repo, so this sweeps them all.
@MainActor
final class WorkspaceActionWatcher {
    private(set) var workflowRuns: [UUID: [BuildWorkflowRun]] = [:]

    var recentRuns: [BuildWorkflowRun] {
        // Multiple worktrees can advertise the same GitHub attempt.
        let unique = Dictionary(grouping: workflowRuns.values.flatMap { $0 }, by: \.id).values.compactMap { matches in
            matches.sorted {
                if $0.state.checkedAt != $1.state.checkedAt { return $0.state.checkedAt > $1.state.checkedAt }
                return $0.workspaceID.uuidString < $1.workspaceID.uuidString
            }.first
        }
        return Array(unique.sorted {
            if $0.state.isComplete != $1.state.isComplete { return !$0.state.isComplete }
            if $0.runID != $1.runID { return $0.runID > $1.runID }
            return $0.id < $1.id
        }.prefix(60))
    }
    private weak var store: WorkspaceStore?
    private var timer: Timer?
    private var trackers: [UUID: ActionCompletionTracker] = [:]
    private var fetchTasks: [UUID: Task<Void, Never>] = [:]
    private var fetchGenerations: [UUID: Int] = [:]

    /// Cadence adapts to whether anything is actually running.
    ///
    /// A fixed 60s sweep meant a finished run could sit unbadged for a minute
    /// on top of the poll cache's own TTL — most visible exactly when you are
    /// watching CI. While any tracked repo has a queued or in-progress run the
    /// sweep tightens; once everything is idle it backs off again, so the
    /// steady-state cost of `gh` subprocesses and API calls is unchanged.
    ///
    /// The run status arrives in the response already being fetched, so knowing
    /// which mode to use costs no extra request.
    private static let activeInterval: TimeInterval = 10
    private static let idleInterval: TimeInterval = 60

    /// Workspaces whose most recent snapshot showed a run still in flight.
    /// Tracked per workspace rather than as one flag so a result arriving from
    /// one repo cannot clear what another repo just reported.
    private var workspacesWithActiveRuns: Set<UUID> = []

    private var hasActiveRun: Bool { !workspacesWithActiveRuns.isEmpty }

    /// GitHub's non-terminal run states. Anything outside this set and
    /// `completed` is treated as idle rather than assumed to be running.
    private nonisolated static let activeStatuses: Set<String> = [
        "queued", "in_progress", "waiting", "requested", "pending",
    ]

    func start(store: WorkspaceStore) {
        self.store = store
        timer?.invalidate()
        sweep()
        scheduleNextSweep()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        fetchTasks.values.forEach { $0.cancel() }
        fetchTasks.removeAll()
    }

    /// One-shot timer rescheduled after every sweep, so the interval can change
    /// between ticks rather than being fixed when the watcher starts.
    private func scheduleNextSweep() {
        timer?.invalidate()
        let interval = hasActiveRun ? Self.activeInterval : Self.idleInterval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sweep()
                self.scheduleNextSweep()
            }
        }
    }

    private func sweep() {
        guard let store else { return }
        for workspace in store.workspaces {
            let dir = workspace.effectiveRootPath ?? ""
            guard !dir.isEmpty else { continue }
            let wsID = workspace.id
            let workspaceName = workspace.name
            fetchTasks[wsID]?.cancel()
            let generation = (fetchGenerations[wsID] ?? 0) + 1
            fetchGenerations[wsID] = generation
            fetchTasks[wsID] = Task { [weak self] in
                let result = await Self.runSnapshot(in: dir, workspaceID: wsID, workspaceName: workspaceName)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.fetchGenerations[wsID] == generation else { return }
                    self.fetchTasks[wsID] = nil
                    if case .success(let snapshot) = result {
                        self.workflowRuns[wsID] = snapshot.runs
                        // Cadence changes take effect immediately rather than
                        // waiting for the next tick, so a run starting shortens
                        // the wait and the last one finishing ends the fast poll.
                        let wasActive = self.hasActiveRun
                        if snapshot.hasActiveRun {
                            self.workspacesWithActiveRuns.insert(wsID)
                        } else {
                            self.workspacesWithActiveRuns.remove(wsID)
                        }
                        if self.hasActiveRun != wasActive { self.scheduleNextSweep() }
                    }
                    self.process(
                        workspaceID: wsID,
                        result: result.map(\.completedIDs)
                    )
                }
            }
        }
        // Workspaces that disappeared cannot keep the fast cadence alive.
        let liveIDs = Set(store.workspaces.map(\.id))
        workspacesWithActiveRuns.formIntersection(liveIDs)
        workflowRuns = workflowRuns.filter { liveIDs.contains($0.key) }
    }

    private func process(workspaceID: UUID, result: Result<Set<Int>, ActionRunFetchError>) {
        var tracker = trackers[workspaceID] ?? ActionCompletionTracker()
        let count = tracker.ingest(result, isSelected: store?.selectedWorkspaceID == workspaceID)
        trackers[workspaceID] = tracker
        for _ in 0..<count {
            store?.badgeActionCompletion(workspaceID: workspaceID)
        }
    }

    // MARK: - gh (off the main actor)

    /// What one sweep learns about a repo: which runs have finished, and
    /// whether anything is still in flight.
    struct RunSnapshot: Sendable {
        let completedIDs: Set<Int>
        let hasActiveRun: Bool
        let runs: [BuildWorkflowRun]
    }

    /// Runs for the repo at `dir`. Newly-completed runs (vs. the last sweep)
    /// are what we badge on; the active flag only drives the poll cadence.
    private nonisolated static func runSnapshot(
        in dir: String, workspaceID: UUID, workspaceName: String
    ) async -> Result<RunSnapshot, ActionRunFetchError> {
        guard let repository = await RepositoryPollingScheduler.shared.repository(for: dir) else {
            return .failure(.launchFailed("Not a Git repository"))
        }
        let data: Data
        do {
            data = try await RepositoryPollingScheduler.shared.data(
                for: .workflowRuns,
                repository: repository,
                policy: .automatic
            )
        } catch let error as ProcessRunnerError {
            if case .launch(_, let message) = error { return .failure(.launchFailed(message)) }
            let status: Int32
            switch error.result?.termination {
            case .exit(let code), .signal(let code): status = code
            case nil: status = -1
            }
            return .failure(.commandFailed(status))
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return .failure(.invalidJSON)
        }
        var ids: Set<Int> = []
        var hasActiveRun = false
        for item in items {
            let status = (item["status"] as? String) ?? ""
            if status == "completed" {
                if let id = item["databaseId"] as? Int { ids.insert(id) }
            } else if Self.activeStatuses.contains(status) {
                hasActiveRun = true
            }
        }
        let fetchedAt = await RepositoryPollingScheduler.shared.lastSuccessfulFetch(for: .workflowRuns, repository: repository)
        let runs = items.compactMap {
            BuildWorkflowRun.parse($0, workspaceID: workspaceID, workspaceName: workspaceName, checkedAt: fetchedAt ?? .distantPast)
        }
        return .success(RunSnapshot(completedIDs: ids, hasActiveRun: hasActiveRun, runs: runs))
    }

}
