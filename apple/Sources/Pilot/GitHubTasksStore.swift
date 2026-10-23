import AppKit
import SwiftUI

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
        guard let repository = await RepositoryPollingScheduler.shared.repository(for: directory) else {
            return ([], "This folder is not a Git repository.")
        }
        do {
            let data = try await RepositoryPollingScheduler.shared.data(
                for: .issues,
                repository: repository,
                policy: policy
            )
            guard let issues = try? JSONDecoder().decode([GitHubTask].self, from: data) else {
                return ([], "Couldn’t parse gh output.")
            }
            return (issues, nil)
        } catch let error as RepositoryPollingError {
            return ([], error.localizedDescription)
        } catch let error as ProcessRunnerError {
            let detail = error.result?.standardErrorString
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let detail, !detail.isEmpty { return ([], detail) }
            return ([], "Couldn’t load GitHub issues.")
        } catch {
            return ([], "Couldn’t load GitHub issues.")
        }
    }
}

/// Inspector tab listing open GitHub issues. Click a title to open it on
/// GitHub; click the `#number` to copy it for handing to an LLM.
struct GitHubTasksView: View {
    var store: GitHubTasksStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            // Fill the remaining height so the header stays pinned to the top
            // and the empty/loading states center in the space below it.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        InspectorSectionHeader(
            title: store.tasks.isEmpty ? "Issues" : "\(store.tasks.count) open",
            systemImage: "checkmark.square",
            // Subtle activity hint on the initial load. Background polls are
            // silent — the list just auto-updates, no manual refresh.
            isLoading: store.isLoading && store.tasks.isEmpty,
            refreshHelp: "Refresh GitHub issues",
            isRefreshDisabled: store.isLoading,
            refresh: store.refresh
        )
    }

    @ViewBuilder
    private var content: some View {
        // Prefer showing data: once we have issues, keep showing them even if
        // a later poll errors out, so the inspector never blinks to an error
        // screen mid-poll.
        ScrollViewReader { proxy in
            ZStack {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(store.tasks) { task in
                            GitHubTaskRow(task: task)
                                .inspectorListCard()
                                .id(task.id)
                        }
                    }
                    .padding(12)
                }

                if store.tasks.isEmpty {
                    if store.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.opacity)
                    } else if let error = store.errorMessage {
                        ContentUnavailableView(
                            "No Issues",
                            systemImage: "exclamationmark.triangle",
                            description: Text(error)
                        )
                        .transition(.opacity)
                    } else {
                        ContentUnavailableView(
                            "No Open Issues",
                            systemImage: "checkmark.circle",
                            description: Text("This repo has no open GitHub issues.")
                        )
                        .transition(.opacity)
                    }
                }
            }
            .inspectorListAnimation(value: store.tasks.map(\.id))
            // Keep a newly injected first issue visible.
            .onChange(of: store.tasks.first?.id) { _, newFirstID in
                guard let newFirstID else { return }
                if reduceMotion {
                    proxy.scrollTo(newFirstID, anchor: .top)
                } else {
                    withAnimation(.snappy) {
                        proxy.scrollTo(newFirstID, anchor: .top)
                    }
                }
            }
        }
    }
}

private struct GitHubTaskRow: View {
    let task: GitHubTask
    @State private var sent = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: sendImplementPrompt) {
                Text("#\(task.number)")
                    .font(.system(.body, design: .monospaced, weight: .semibold))
                    .foregroundStyle(sent ? Color.green : Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Run an \u{201C}implement #\(task.number)\u{201D} task in the active terminal")

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.body)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: open)
                    .help("Open #\(task.number) on GitHub")

                metadata
            }
        }
    }

    /// User • time ago, mirroring the hash • user • time ago line the Commits
    /// and Actions tabs show. An issue has no hash, so the line starts at the
    /// assignee. Values sit at .tertiary with .quaternary separators, the
    /// metadata styling shared across the three tabs.
    @ViewBuilder
    private var metadata: some View {
        let age = task.age
        if !task.assignees.isEmpty || !age.isEmpty {
            HStack(spacing: 4) {
                if !task.assignees.isEmpty {
                    // Handles rather than full names: they stay readable in a
                    // narrow column. Full names live in the tooltip and the
                    // accessibility label, which no truncation reaches.
                    Text(assigneeSummary)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if !task.assignees.isEmpty && !age.isEmpty {
                    Text("•")
                        .font(.subheadline)
                        .foregroundStyle(.quaternary)
                }

                if !age.isEmpty {
                    Text(age)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .help(metadataHelp)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(metadataHelp)
        }
    }

    /// One handle plus an overflow count, so even a four-way assignment leaves
    /// room for the age at the end of the line.
    private var assigneeSummary: String {
        guard let first = task.assignees.first else { return "" }
        let others = task.assignees.count - 1
        return others > 0 ? "\(first.login) (+\(others))" : first.login
    }

    private var metadataHelp: String {
        var parts: [String] = []
        if !task.assignees.isEmpty {
            parts.append(
                "Assigned to " + task.assignees.map(\.fullDescription)
                    .formatted(.list(type: .and))
            )
        }
        if !task.age.isEmpty { parts.append("Opened \(task.age)") }
        return parts.joined(separator: " · ")
    }

    /// Click the number to drop an agent-ready prompt into the active terminal:
    /// fetch the issue from GitHub and build the fix. Pilot does the paste
    /// (it owns the terminal); we just announce the prompt.
    private func sendImplementPrompt() {
        let prompt = "Implement GitHub issue #\(task.number). "
            + "Read it first with `gh issue view \(task.number)`, then build and apply the fix. "
            + "When you open the pull request, include `fixes #\(task.number)` in the commit "
            + "message so merging auto-closes the issue."
        NotificationCenter.default.post(
            name: .pilotSendIssuePrompt,
            object: nil,
            userInfo: ["prompt": prompt]
        )
        sent = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { sent = false }
    }

    private func open() {
        guard let url = URL(string: task.url) else { return }
        NSWorkspace.shared.open(url)
    }
}

extension Notification.Name {
    /// Posted by the Issues inspector when the user clicks an issue number;
    /// `userInfo["prompt"]` carries the text to paste into the active terminal.
    static let pilotSendIssuePrompt = Notification.Name("pilotSendIssuePrompt")
}
