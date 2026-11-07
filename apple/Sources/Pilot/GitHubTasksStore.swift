import AppKit
import Observation

/// A GitHub account assigned to an issue. `gh` reports a login for every
/// assignee; the display name is optional and often empty for bot accounts.
struct GitHubTaskAssignee: Identifiable, Decodable, Equatable {
    let login: String
    let name: String?
    var id: String { login }

    /// The full name when GitHub has one, falling back to the handle. Used for
    /// tooltips and VoiceOver, where the extra width costs nothing.
    var fullDescription: String {
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return login }
        return "\(name) (\(login))"
    }
}

/// A GitHub issue surfaced as a "task" in the inspector.
struct GitHubTask: Identifiable, Decodable, Equatable {
    let number: Int
    let title: String
    let url: String
    let state: String
    let assignees: [GitHubTaskAssignee]
    let createdAt: String
    var id: Int { number }

    /// Formatted on demand rather than at decode time so the row stays honest
    /// between the 30s polls that refresh the list.
    var age: String {
        createdAt.isEmpty ? "" : RelativeTime.string(fromISO: createdAt)
    }

    private enum CodingKeys: String, CodingKey {
        case number, title, url, state, assignees, createdAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decode(Int.self, forKey: .number)
        title = try container.decode(String.self, forKey: .title)
        url = try container.decode(String.self, forKey: .url)
        state = try container.decode(String.self, forKey: .state)
        // Absent when the payload predates the assignee field. Unassigned is
        // the safe reading; a throw here would blank the whole tab.
        assignees = try container.decodeIfPresent(
            [GitHubTaskAssignee].self,
            forKey: .assignees
        ) ?? []
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }
}

/// Loads open GitHub issues for the active workspace's repo via the `gh` CLI.
@Observable
@MainActor
final class GitHubTasksStore {
    private(set) var tasks: [GitHubTask] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private var directory: String?
    private var loadTask: Task<Void, Never>?
    private var pollTimer: Timer?

    /// How often to re-poll `gh issue list` while the Tasks tab is showing.
    /// Matches `RepositoryStore`'s PR/Actions cadence.
    private static let pollInterval: TimeInterval = 30

    init(tasks: [GitHubTask] = []) {
        self.tasks = tasks
    }

    /// Point the store at a repo (or `nil` to clear). While the Tasks tab is
    /// visible this fetches immediately and keeps the list live via a
    /// background poll; while it's hidden the store only tracks the repo
    /// (still dropping a previous repo's issues on a switch) so a tab nobody
    /// is reading spends no `gh` round-trips.
    func load(directory: String?, isVisible: Bool = true) {
        let trimmed = directory?.trimmingCharacters(in: .whitespaces)
        guard let trimmed, !trimmed.isEmpty else {
            stopPolling()
            self.directory = nil
            tasks = []
            errorMessage = nil
            isLoading = false
            return
        }

        let isNewRepo = (trimmed != self.directory)
        self.directory = trimmed

        if isNewRepo {
            // Switching repos: drop the previous repo's issues and show the
            // spinner until the first fetch lands.
            tasks = []
            errorMessage = nil
        }

        guard isVisible else {
            stopPolling()
            isLoading = false
            return
        }

        startPolling()
        // Spinner only when we have nothing to show; background polls update
        // silently so the list doesn't flash.
        fetch(showSpinner: tasks.isEmpty, policy: .automatic)
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { _ in
            Task { @MainActor in
                self.fetch(showSpinner: false, policy: .automatic)
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        loadTask?.cancel()
        loadTask = nil
    }

    func refresh() {
        fetch(showSpinner: tasks.isEmpty, policy: .manual)
    }

    private func fetch(showSpinner: Bool, policy: RepositoryRefreshPolicy) {
        guard let directory else { return }
        loadTask?.cancel()
        if showSpinner { isLoading = true }
        loadTask = Task {
            let (issues, error) = await Self.fetch(in: directory, policy: policy)
            if Task.isCancelled { return }
            isLoading = false
            errorMessage = error
            // Keep the last good list on a transient poll failure; only swap
            // in new data on success so the inspector doesn't blink to an
            // error screen mid-poll. Insertions animate in the view layer.
            if error == nil {
                tasks = issues
            }
        }
    }

    nonisolated private static func fetch(
        in directory: String,
        policy: RepositoryRefreshPolicy
    ) async -> ([GitHubTask], String?) {
        let data: Data
        do {
            data = try await GitHubCLIFailure.read(.issues, in: directory, policy: policy)
        } catch {
            return ([], GitHubCLIFailure.message(for: error, reading: "issues"))
        }
        guard let issues = try? JSONDecoder().decode([GitHubTask].self, from: data) else {
            return ([], "Couldn’t read the issues returned by GitHub.")
        }
        return (issues, nil)
    }
}

extension Notification.Name {
    /// Posted by the Issues inspector when the user clicks an issue number;
    /// `userInfo["prompt"]` carries the text to paste into the active terminal.
    static let pilotSendIssuePrompt = Notification.Name("pilotSendIssuePrompt")
}
