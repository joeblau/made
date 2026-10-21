import Foundation

/// Lightweight, on-demand git working-tree status for a directory. The terminal
/// tab header uses it to show whether the shell's current repo is Clean or
/// Dirty. Runs `git status --porcelain` off the main actor.
enum GitStatus {
    /// `true` if the work tree at `directory` has uncommitted changes (modified,
    /// staged, or untracked), `false` if it's clean, `nil` if `directory` isn't a
    /// git work tree or git can't be run.
    static func isDirty(directory: String) async -> Bool? {
        let dir = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty else { return nil }
        let invocation = ProcessInvocation.developerTool(
            "git",
            arguments: ["-C", dir, "status", "--porcelain"],
            timeout: .seconds(10),
            standardOutputLimit: 2 * 1_024 * 1_024
        )
        guard let result = try? await ProcessRunner.run(invocation) else { return nil }
        let output = result.standardOutputString
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Current branch for the work tree at `directory`, or nil when it isn't a
    /// git work tree. A detached HEAD reports no branch, so it falls back to the
    /// short commit — showing nothing there would read as "not a repo".
    static func currentBranch(directory: String) async -> String? {
        let dir = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty else { return nil }

        let branchInvocation = ProcessInvocation.developerTool(
            "git",
            arguments: ["-C", dir, "branch", "--show-current"],
            timeout: .seconds(10),
            standardOutputLimit: 64 * 1_024
        )
        guard let result = try? await ProcessRunner.run(branchInvocation) else { return nil }
        let branch = result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !branch.isEmpty { return sanitizedReference(branch) }

        // Empty output means either a detached HEAD or not a repository at all;
        // rev-parse distinguishes them.
        let headInvocation = ProcessInvocation.developerTool(
            "git",
            arguments: ["-C", dir, "rev-parse", "--short", "HEAD"],
            timeout: .seconds(10),
            standardOutputLimit: 64 * 1_024
        )
        guard let headResult = try? await ProcessRunner.run(headInvocation) else { return nil }
        let head = headResult.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        return head.isEmpty ? nil : sanitizedReference(head)
    }

    /// Branch names come from the repository, not from Pilot, and land directly
    /// in a sidebar row — strip control characters and bound the length.
    static func sanitizedReference(_ raw: String) -> String? {
        let cleaned = UntrustedText.sanitized(raw, limit: 60)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Nearest ancestor of `directory` (including itself) containing a `.git`
    /// entry, or `nil` when none does. A `.git` regular file counts as a root
    /// marker — linked worktrees and submodules mark theirs with a gitdir
    /// pointer file — matching `git rev-parse --show-toplevel`. Walks
    /// in-process so main-actor callers never block on a subprocess. Each
    /// step of the walk is a blocking stat, and a network/FUSE mount whose
    /// server has died blocks a stat until the mount's own timeout — minutes,
    /// with no kill the old 10s-bounded subprocess had — so directories off
    /// a local volume are never walked and resolve to `nil`; callers that
    /// want to preserve prior state instead should check `isOnLocalVolume`
    /// themselves first.
    static func findWorkTreeRoot(from directory: String) -> String? {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard isOnLocalVolume(path: trimmed) else { return nil }
        var url = URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return url.path
            }
            let parent = url.deletingLastPathComponent()
            guard parent.path != url.path else { return nil }
            url = parent
        }
    }

    /// `true` when `path` sits on a local volume according to the kernel's
    /// cached mount table. `getmntinfo_r_np` with `MNT_NOWAIT` never contacts
    /// a volume's server, and the path itself is never stat'd, so this cannot
    /// hang on a dead network mount. The deepest mount point containing the
    /// path decides; a path matching no mount conservatively reads non-local.
    static func isOnLocalVolume(path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        var mountsPointer: UnsafeMutablePointer<statfs>?
        let mountCount = getmntinfo_r_np(&mountsPointer, MNT_NOWAIT)
        guard mountCount > 0, let mounts = mountsPointer else { return false }
        defer { free(mounts) }

        var bestMatch: (depth: Int, isLocal: Bool)?
        for index in 0..<Int(mountCount) {
            let mountPoint = withUnsafeBytes(of: mounts[index].f_mntonname) { buffer in
                String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            guard standardized == mountPoint
                || standardized.hasPrefix(mountPoint.hasSuffix("/") ? mountPoint : mountPoint + "/")
            else { continue }
            if mountPoint.count > (bestMatch?.depth ?? -1) {
                bestMatch = (mountPoint.count, (mounts[index].f_flags & UInt32(MNT_LOCAL)) != 0)
            }
        }
        return bestMatch?.isLocal ?? false
    }
}

/// Shares one working-tree dirty probe per directory across callers. The
/// expanded terminal panes of a workspace usually share a cwd, so without
/// sharing each tab badge would spawn an identical `git status` subprocess per
/// polling tick. Fresh entries are served from cache and overlapping callers
/// coalesce onto one in-flight probe, mirroring RepositoryPollingScheduler.
actor GitDirtyStateCache {
    typealias Prober = @Sendable (String) async -> Bool?
    typealias Now = @Sendable () -> Date

    static let shared = GitDirtyStateCache()

    private struct Entry {
        let value: Bool?
        let expiresAt: Date
    }

    /// Keys come from live shell cwds, which change with every `cd` — bound
    /// how many stale directories one run can pin.
    private static let maximumEntries = 128

    private let probe: Prober
    private let now: Now
    private let timeToLive: TimeInterval
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<Bool?, Never>] = [:]

    init(
        timeToLive: TimeInterval = 4,
        now: @escaping Now = Date.init,
        probe: @escaping Prober = { await GitStatus.isDirty(directory: $0) }
    ) {
        self.timeToLive = timeToLive
        self.now = now
        self.probe = probe
    }

    func isDirty(directory: String) async -> Bool? {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.path
        if let entry = entries[key], now() < entry.expiresAt {
            return entry.value
        }
        if let task = inFlight[key] {
            return await task.value
        }
        let task = Task { await perform(key: key) }
        inFlight[key] = task
        return await task.value
    }

    private func perform(key: String) async -> Bool? {
        defer { inFlight[key] = nil }
        let value = await probe(key)
        pruneIfNeeded()
        entries[key] = Entry(value: value, expiresAt: now().addingTimeInterval(timeToLive))
        return value
    }

    private func pruneIfNeeded() {
        guard entries.count >= Self.maximumEntries else { return }
        let current = now()
        entries = entries.filter { current < $0.value.expiresAt }
        if entries.count >= Self.maximumEntries {
            entries.removeAll()
        }
    }
}
