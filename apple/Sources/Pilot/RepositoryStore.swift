import Foundation

struct GitPullRequest: Identifiable {
    let id: Int // PR number
    let title: String
    let url: String
    /// GitHub's PR state: OPEN, MERGED, or CLOSED.
    let state: String
    let isDraft: Bool
    let author: String
    let headBranch: String
    let elapsed: String
}

struct GitAction: Identifiable {
    let id: Int
    let name: String
    let displayTitle: String
    let headBranch: String
    let headSha: String
    let status: String
    let conclusion: String
    let elapsed: String
    let url: String
    /// GitHub login of whoever triggered the run — the pusher for a normal
    /// commit, or whoever hit re-run. Empty when GitHub reports no actor.
    let actor: String
}

struct GitRun: Identifiable {
    let id: Int
    let name: String
    let title: String
    let branch: String
    let elapsed: String
    let status: Status

    enum Status: String {
        case success, failure, inProgress, queued, unknown
    }
}

struct FileSystemEntry: Identifiable {
    let id: String
    let name: String
    let path: String
    let relativePath: String
    let isDirectory: Bool
    let children: [FileSystemEntry]?
}

/// Which GitHub-backed lists the inspector's 30s refresh tick fetches, derived
/// from the visible inspector tab so a hidden tab spends no `gh` spawns or API
/// round-trips. Workflow runs stay badged for every workspace by
/// `WorkspaceActionWatcher` regardless of what polls here. A `nil` tab is a
/// host that doesn't gate by tab and keeps the legacy poll-both behavior.
enum RepositoryPolledResources: Equatable {
    case pullRequests
    case workflowRuns
    case both
    case none

    init(visibleTab: InspectorTab?) {
        switch visibleTab {
        case .pullRequests: self = .pullRequests
        case .actions: self = .workflowRuns
        case .tasks, .filesystem, .usage: self = .none
        case nil: self = .both
        }
    }
}

@MainActor
@Observable
final class RepositoryStore {
    var pullRequests: [GitPullRequest] = []
    var actions: [GitAction] = []
    var runs: [GitRun] = []
    var filesystem: [FileSystemEntry] = []
    var repoPath: String = ""
    var isLoading = false
    var isLoadingFilesystem = false
    private var refreshTimer: Timer?
    private var polledResources: RepositoryPolledResources = .both

    var repositoryName: String {
        guard !repoPath.isEmpty else { return "Repository" }
        let name = URL(fileURLWithPath: repoPath, isDirectory: true).lastPathComponent
        return name.isEmpty ? repoPath : name
    }

    func startWatching(directory: String, visibleTab: InspectorTab? = nil) {
        if repoPath == directory {
            setVisibleTab(visibleTab)
            if filesystem.isEmpty && !isLoadingFilesystem {
                fetchFilesystem()
            }
            return
        }

        repoPath = directory
        pullRequests = []
        actions = []
        runs = []
        filesystem = []
        fetchFilesystem()
        polledResources = RepositoryPolledResources(visibleTab: visibleTab)
        fetchPolledResources()
        rearmRefreshTimer()
    }

    /// Re-aim polling at the newly visible tab: fetch its list once (the shared
    /// scheduler cache makes the switch instant when the data is fresh) and
    /// keep the 30s tick only while a GitHub-backed tab is showing.
    func setVisibleTab(_ tab: InspectorTab?) {
        polledResources = RepositoryPolledResources(visibleTab: tab)
        guard !repoPath.isEmpty else { return }
        if tab == .filesystem, filesystem.isEmpty, !isLoadingFilesystem {
            fetchFilesystem()
        }
        fetchPolledResources()
        rearmRefreshTimer()
    }

    private func fetchPolledResources(policy: RepositoryRefreshPolicy = .automatic) {
        switch polledResources {
        case .pullRequests:
            fetchPullRequests(policy: policy)
        case .workflowRuns:
            fetchWorkflowRuns(policy: policy)
        case .both:
            fetchAll(policy: policy)
        case .none:
            break
        }
    }

    private func rearmRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard polledResources != .none, !repoPath.isEmpty else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in
                self.fetchPolledResources()
            }
        }
    }

    func stopWatching() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        repoPath = ""
        pullRequests = []
        actions = []
        runs = []
        filesystem = []
        isLoading = false
        isLoadingFilesystem = false
    }

    func fetchAll(policy: RepositoryRefreshPolicy = .automatic) {
        fetchPullRequests(policy: policy)
        fetchWorkflowRuns(policy: policy)
    }

    func fetchPullRequests(policy: RepositoryRefreshPolicy = .automatic) {
        guard !repoPath.isEmpty else { return }
        isLoading = true
        let dir = repoPath

        Task {
            let result = await Self.fetchPullRequestData(directory: dir, policy: policy)
            // Drop stale results: the user may have switched workspaces while
            // the shell command ran, and these would clobber the new repo's data.
            guard self.repoPath == dir else { return }
            self.pullRequests = result
            self.isLoading = false
        }
    }

    /// Actions and runs both come from `gh run list`; one invocation (one
    /// GitHub API round-trip) feeds both instead of two per refresh tick.
    func fetchWorkflowRuns(policy: RepositoryRefreshPolicy = .automatic) {
        guard !repoPath.isEmpty else { return }
        let dir = repoPath

        Task {
            let (actions, runs) = await Self.fetchWorkflowData(directory: dir, policy: policy)
            guard self.repoPath == dir else { return }
            self.actions = actions
            self.runs = runs
        }
    }

    func fetchFilesystem() {
        guard !repoPath.isEmpty else { return }
        isLoadingFilesystem = true
        let dir = repoPath

        Task {
            let result = await Self.fetchFilesystemData(directory: dir)
            guard self.repoPath == dir else { return }
            self.filesystem = result
            self.isLoadingFilesystem = false
        }
    }

    private nonisolated static func fetchPullRequestData(
        directory: String,
        policy: RepositoryRefreshPolicy
    ) async -> [GitPullRequest] {
        guard let repository = await RepositoryPollingScheduler.shared.repository(for: directory),
              let data = try? await RepositoryPollingScheduler.shared.data(
                for: .pullRequests,
                repository: repository,
                policy: policy
              ),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item -> GitPullRequest? in
            guard let number = item["number"] as? Int else { return nil }
            let author = item["author"] as? [String: Any]
            let createdAt = item["createdAt"] as? String ?? ""
            return GitPullRequest(
                id: number,
                title: item["title"] as? String ?? "",
                url: item["url"] as? String ?? "",
                state: item["state"] as? String ?? "",
                isDraft: item["isDraft"] as? Bool ?? false,
                author: author?["login"] as? String ?? "",
                headBranch: item["headRefName"] as? String ?? "",
                elapsed: createdAt.isEmpty ? "" : Self.relativeTime(from: createdAt)
            )
        }
    }

    private nonisolated static func fetchWorkflowData(
        directory: String,
        policy: RepositoryRefreshPolicy
    ) async -> ([GitAction], [GitRun]) {
        guard let repository = await RepositoryPollingScheduler.shared.repository(for: directory),
              let data = try? await RepositoryPollingScheduler.shared.data(
                for: .workflowRuns,
                repository: repository,
                policy: policy
              ),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return ([], [])
        }

        var actions: [GitAction] = []
        var runs: [GitRun] = []
        for item in items.prefix(20) {
            guard let databaseID = item["databaseId"] as? Int else { continue }
            let name = item["name"] as? String ?? ""
            let title = item["displayTitle"] as? String ?? ""
            let branch = item["headBranch"] as? String ?? ""
            let conclusionStr = item["conclusion"] as? String ?? ""
            let statusStr = item["status"] as? String ?? ""
            let createdAt = item["createdAt"] as? String ?? ""

            actions.append(GitAction(
                id: databaseID,
                name: name,
                displayTitle: title,
                headBranch: branch,
                headSha: item["headSha"] as? String ?? "",
                status: statusStr,
                conclusion: conclusionStr,
                elapsed: createdAt.isEmpty ? "" : Self.relativeTime(from: createdAt),
                url: item["url"] as? String ?? "",
                actor: item["actor"] as? String ?? ""
            ))

            let status: GitRun.Status
            if conclusionStr == "success" {
                status = .success
            } else if conclusionStr == "failure" {
                status = .failure
            } else if statusStr == "in_progress" {
                status = .inProgress
            } else if statusStr == "queued" {
                status = .queued
            } else {
                status = .unknown
            }

            let updatedAt = item["updatedAt"] as? String ?? ""
            runs.append(GitRun(
                id: databaseID,
                name: name,
                title: title,
                branch: branch,
                elapsed: Self.relativeTime(from: updatedAt),
                status: status
            ))
        }
        return (actions, runs)
    }

    private nonisolated static func fetchFilesystemData(directory: String) async -> [FileSystemEntry] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let rootURL = URL(fileURLWithPath: directory, isDirectory: true)
                let entries = listFilesystemEntries(at: rootURL, rootURL: rootURL)
                continuation.resume(returning: entries)
            }
        }
    }

    private nonisolated static func relativeTime(from iso: String) -> String {
        RelativeTime.string(fromISO: iso)
    }

    private nonisolated static func relativeTime(from date: Date) -> String {
        RelativeTime.string(from: date)
    }

    private nonisolated static func parseISODate(_ value: String) -> Date? {
        RelativeTime.parseISODate(value)
    }

    nonisolated static func findGitRoot(from directory: String) -> String? {
        let invocation = ProcessInvocation.developerTool(
            "git",
            arguments: ["rev-parse", "--show-toplevel"],
            currentDirectoryURL: URL(fileURLWithPath: directory, isDirectory: true),
            timeout: .seconds(10),
            standardOutputLimit: 64 * 1_024
        )
        guard let result = try? ProcessRunner.runBlocking(invocation) else { return nil }
        let root = result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        return root.isEmpty ? nil : root
    }

    nonisolated static func listFilesystemEntries(at directoryURL: URL, rootURL: URL) -> [FileSystemEntry] {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]

        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else {
            return []
        }

        let sortedEntries = urls.compactMap { url -> (url: URL, isDirectory: Bool, isSymbolicLink: Bool)? in
            guard url.lastPathComponent != ".git" else { return nil }
            let values = try? url.resourceValues(forKeys: keys)
            return (
                url: url,
                isDirectory: values?.isDirectory ?? false,
                isSymbolicLink: values?.isSymbolicLink ?? false
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }

            return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
        }

        return sortedEntries.map { entry in
            let relativePath = relativePath(for: entry.url, rootURL: rootURL)
            return FileSystemEntry(
                id: relativePath,
                name: entry.url.lastPathComponent,
                path: entry.url.path,
                relativePath: relativePath,
                isDirectory: entry.isDirectory,
                children: nil
            )
        }
    }

    private nonisolated static func relativePath(for fileURL: URL, rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        guard filePath.hasPrefix(prefix) else {
            return fileURL.lastPathComponent
        }

        return String(filePath.dropFirst(prefix.count))
    }

}
