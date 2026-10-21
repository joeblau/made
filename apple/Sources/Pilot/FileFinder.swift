import Foundation

/// One indexed file in a workspace root.
struct FileItem: Identifiable, Hashable {
    var id: String { path }
    let path: String          // absolute
    let relativePath: String  // path relative to root, shown in the UI
    let name: String          // basename
    /// Case-folded forms, cached once at index time. Filtering runs over the
    /// whole index on every keystroke, so re-lowercasing up to 200k candidates
    /// per pass dominated finder latency; these are pure functions of the
    /// fields above and cost one extra copy of each string.
    let foldedRelativePath: String
    let foldedName: String

    init(path: String, relativePath: String, name: String) {
        self.path = path
        self.relativePath = relativePath
        self.name = name
        self.foldedRelativePath = relativePath.lowercased()
        self.foldedName = name.lowercased()
    }
}

/// In-memory file index + fuzzy search for the editor's "open file" finder.
///
/// `start(root:)` recursively builds or refreshes the index off the main actor,
/// then `setQuery(_:)` filters it off the main actor on every keystroke via
/// `FuzzyMatcher`. Obsolete scans are cancelled and only the best 300 results
/// are retained, keeping the 200k-file ceiling away from the MainActor. Indexing prefers
/// `git ls-files` so `.gitignore` is honored for free (plus a pruned scan that
/// adds back `.env*` / `.dev.vars` — gitignored, but exactly the files you open
/// by hand), and falls back to a pruned filesystem walk outside git repos.
@MainActor
@Observable
final class FileFinder {
    /// The current search results — already filtered, scored, sorted, and capped.
    private(set) var results: [FileItem] = []
    /// True while the background index is being built.
    private(set) var isIndexing: Bool = false

    /// The full, unfiltered index. Filtering reads from here on every keystroke.
    @ObservationIgnored private var index: [FileItem] = []
    /// The root the current `index` was (or is being) built for. Used both to
    /// make `start` idempotent and to drop results from a stale indexing task
    /// when the root changes mid-flight.
    @ObservationIgnored private var indexedRoot: String?
    /// The live query, retained so a freshly-built index can immediately reflect
    /// whatever the user has already typed.
    @ObservationIgnored private var query: String = ""
    /// Bumped on every query change (and refilter). The off-main filter task
    /// captures the value at dispatch time and only publishes its results if it
    /// still matches — so a slow scan for an old keystroke can't clobber a newer
    /// one (last-write-wins by generation, not by completion order).
    @ObservationIgnored private var queryGeneration = 0
    /// Handles let a new root/query stop obsolete work instead of merely hiding
    /// its eventual result. This is essential at the 200k-file ceiling: stale
    /// scans should not compete with the query the user is still typing.
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var filterTask: Task<Void, Never>?
    /// A separate scan generation also invalidates same-path refreshes.
    @ObservationIgnored private var indexGeneration = 0

    /// Caps:
    /// - `maxIndexedFiles` bounds memory and indexing time on huge trees.
    /// - `maxResults` bounds what we hand back to SwiftUI per keystroke.
    nonisolated private static let maxIndexedFiles = 200_000
    nonisolated private static let maxResults = 300

    // Ranking tiers. A compact filename hit beats a directory hit, while an
    // exact path component can still beat a very weak/scattered basename match.
    nonisolated private static let basenameLocationBonus = 240
    nonisolated private static let basenameExactBonus = 2_200
    nonisolated private static let basenameStemExactBonus = 1_900
    nonisolated private static let basenamePrefixBonus = 1_400
    nonisolated private static let basenameSubstringBonus = 800
    nonisolated private static let pathExactBonus = 1_800
    nonisolated private static let pathPrefixBonus = 900
    nonisolated private static let pathComponentExactBonus = 650
    nonisolated private static let pathComponentPrefixBonus = 450
    nonisolated private static let pathSubstringBonus = 250

    /// Directory names skipped wholesale during the non-git filesystem walk.
    /// Build artifacts, dependency caches, and VCS metadata — none of which the
    /// user wants to open by hand.
    nonisolated private static let skippedDirectories: Set<String> = [
        ".git", "node_modules", ".build", "build", "DerivedData", "Pods",
        ".next", "dist", "out", "target", ".venv", "venv", "__pycache__",
        ".swiftpm", "vendor", "Carthage", ".gradle", ".idea", ".cache",
        ".turbo", ".vercel", "coverage",
    ]

    init() {}

    deinit {
        indexTask?.cancel()
        filterTask?.cancel()
    }

    /// Kicks off indexing of `root`. Duplicate calls are coalesced while a scan
    /// is running; a later call refreshes the completed index. Calling it with a
    /// different root replaces the index and invalidates old-root work.
    func start(root: String) {
        let normalized = Self.normalize(root)
        let isNewRoot = indexedRoot != normalized

        // Re-index on every explicit open so files created or removed since the
        // last scan show up — the index used to be built once per root and then
        // cached forever, which left the finder stale (e.g. an agent writes new
        // files in a sibling terminal and they never appear). Skip only when a
        // scan for this exact root is already in flight.
        if !isNewRoot && isIndexing { return }

        if isNewRoot {
            // A filter over the previous root must never publish into this one.
            queryGeneration += 1
            filterTask?.cancel()
            filterTask = nil
        }

        indexTask?.cancel()
        indexGeneration += 1
        let scanGeneration = indexGeneration
        indexedRoot = normalized
        if isNewRoot {
            // Switched workspaces: drop the previous project's files so they
            // don't linger while the first scan of the new root runs. On a
            // same-root refresh we keep the current results visible until the
            // rescan lands, avoiding an empty flash.
            index = []
            results = []
        }
        isIndexing = true

        indexTask = Task.detached(priority: .userInitiated) { [weak self] in
            let items = Self.buildIndex(root: normalized)
            guard !Task.isCancelled else { return }
            await self?.publishIndex(
                items,
                root: normalized,
                generation: scanGeneration
            )
        }
    }

    private func publishIndex(_ items: [FileItem], root: String, generation: Int) {
        // A newer root/refresh owns the finder now; discard this scan.
        guard indexedRoot == root, indexGeneration == generation else { return }
        indexTask = nil
        index = items
        isIndexing = false
        // Reflect whatever the user typed while indexing was in flight.
        refilter()
    }

    /// Clears the finder when an editor loses its workspace root.
    func reset() {
        indexTask?.cancel()
        filterTask?.cancel()
        indexTask = nil
        filterTask = nil
        indexGeneration += 1
        queryGeneration += 1
        indexedRoot = nil
        index = []
        results = []
        isIndexing = false
    }

    /// Updates the query and recomputes `results` off the main actor. Cheap on
    /// the MainActor (just trims + bumps a counter); the scan happens elsewhere.
    func setQuery(_ query: String) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        refilter()
    }

    // MARK: - Filtering

    /// Dispatches a fresh filter pass for the current query/index off the main
    /// actor. Only immutable snapshots cross the actor boundary, and the result
    /// is published only if no newer query has superseded this one.
    private func refilter() {
        filterTask?.cancel()
        queryGeneration += 1
        let gen = queryGeneration
        let snapshot = index
        let q = self.query
        filterTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Brief debounce so a burst of keystrokes only scans once.
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let computed = Self.filter(items: snapshot, query: q)
            guard !Task.isCancelled else { return }
            await self?.publishResults(computed, generation: gen)
        }
    }

    private func publishResults(_ computed: [FileItem], generation: Int) {
        guard queryGeneration == generation else { return }
        filterTask = nil
        results = computed
    }

    /// Filters/sorts `items` against `query` and returns the top slice. Pure and
    /// `nonisolated` so it can run off the main actor over an immutable snapshot.
    nonisolated static func filter(items: [FileItem], query: String) -> [FileItem] {
        let normalizedQuery = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")

        if normalizedQuery.isEmpty {
            return topAlphabeticalItems(items)
        }

        // Whitespace creates independent terms. Every term must match, but they
        // may appear in any order and in different path components, so natural
        // queries such as "pilot editor pane" work without punctuation tricks.
        let terms = normalizedQuery
            .split(whereSeparator: \Character.isWhitespace)
            .map { SearchTerm(String($0)) }
        guard !terms.isEmpty else { return topAlphabeticalItems(items) }

        var ranked: [RankedItem] = []
        ranked.reserveCapacity(min(items.count, maxResults * 4))

        for (offset, item) in items.enumerated() {
            if offset.isMultiple(of: 256), currentTaskIsCancelled() { return [] }

            var totalScore = 0
            var matchesAllTerms = true
            for term in terms {
                guard let termScore = score(term: term, item: item) else {
                    matchesAllTerms = false
                    break
                }
                totalScore += termScore
            }
            guard matchesAllTerms else { continue }

            ranked.append(RankedItem(item: item, score: totalScore))

            // Keep only the best prefix periodically. Sorting all 200k matches
            // for a broad one-letter query wastes work when the UI shows 300.
            if ranked.count >= maxResults * 4 {
                ranked.sort(by: ranksBefore)
                ranked.removeSubrange(maxResults...)
            }
        }

        ranked.sort(by: ranksBefore)
        return ranked.prefix(maxResults).map(\.item)
    }

    private nonisolated struct SearchTerm: Sendable {
        let folded: String
        let fuzzy: FuzzyMatcher.PreparedQuery

        init(_ text: String) {
            folded = text.lowercased()
            fuzzy = FuzzyMatcher.PreparedQuery(text)
        }
    }

    private nonisolated struct RankedItem {
        let item: FileItem
        let score: Int
    }

    /// Evaluates both filename and relative path. Taking the stronger score fixes
    /// the old early-return behavior where any weak basename subsequence hid a
    /// much better exact directory/path match.
    private nonisolated static func score(term: SearchTerm, item: FileItem) -> Int? {
        let nameScore = smartScore(
            term: term,
            candidate: item.name,
            foldedCandidate: item.foldedName,
            isBasename: true
        )
        let pathScore = smartScore(
            term: term,
            candidate: item.relativePath,
            foldedCandidate: item.foldedRelativePath,
            isBasename: false
        )
        switch (nameScore, pathScore) {
        case let (name?, path?): return max(name, path)
        case let (name?, nil): return name
        case let (nil, path?): return path
        case (nil, nil): return nil
        }
    }

    private nonisolated static func smartScore(
        term: SearchTerm,
        candidate: String,
        foldedCandidate: String,
        isBasename: Bool
    ) -> Int? {
        guard let fuzzyScore = FuzzyMatcher.score(query: term.fuzzy, candidate: candidate) else {
            return nil
        }

        var tierBonus = 0

        if isBasename {
            if foldedCandidate == term.folded {
                tierBonus = basenameExactBonus
            } else if (foldedCandidate as NSString).deletingPathExtension == term.folded {
                tierBonus = basenameStemExactBonus
            } else if foldedCandidate.hasPrefix(term.folded) {
                tierBonus = basenamePrefixBonus
            } else if foldedCandidate.contains(term.folded) {
                tierBonus = basenameSubstringBonus
            }
            return fuzzyScore + basenameLocationBonus + tierBonus
        }

        if foldedCandidate == term.folded {
            tierBonus = pathExactBonus
        } else if foldedCandidate.hasPrefix(term.folded) {
            tierBonus = pathPrefixBonus
        } else if foldedCandidate.contains(term.folded) {
            tierBonus = pathSubstringBonus
        }

        // Component tiers make an exact directory name meaningful without
        // allowing it to beat a compact/contiguous basename match.
        for component in foldedCandidate.split(separator: "/") {
            if component == term.folded {
                tierBonus = max(tierBonus, pathComponentExactBonus)
            } else if component.hasPrefix(term.folded) {
                tierBonus = max(tierBonus, pathComponentPrefixBonus)
            }
        }
        return fuzzyScore + tierBonus
    }

    private nonisolated static func ranksBefore(_ lhs: RankedItem, _ rhs: RankedItem) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.item.relativePath.count != rhs.item.relativePath.count {
            return lhs.item.relativePath.count < rhs.item.relativePath.count
        }
        if lhs.item.foldedRelativePath != rhs.item.foldedRelativePath {
            return lhs.item.foldedRelativePath < rhs.item.foldedRelativePath
        }
        return lhs.item.relativePath < rhs.item.relativePath
    }

    private nonisolated static func topAlphabeticalItems(_ items: [FileItem]) -> [FileItem] {
        var top: [FileItem] = []
        top.reserveCapacity(min(items.count, maxResults * 4))

        for (offset, item) in items.enumerated() {
            if offset.isMultiple(of: 256), currentTaskIsCancelled() { return [] }
            top.append(item)
            if top.count >= maxResults * 4 {
                top.sort(by: alphabeticallyBefore)
                top.removeSubrange(maxResults...)
            }
        }
        top.sort(by: alphabeticallyBefore)
        return Array(top.prefix(maxResults))
    }

    private nonisolated static func alphabeticallyBefore(_ lhs: FileItem, _ rhs: FileItem) -> Bool {
        if lhs.foldedRelativePath != rhs.foldedRelativePath {
            return lhs.foldedRelativePath < rhs.foldedRelativePath
        }
        return lhs.relativePath < rhs.relativePath
    }

    private nonisolated static func currentTaskIsCancelled() -> Bool {
        withUnsafeCurrentTask { $0?.isCancelled ?? false }
    }

    // MARK: - Indexing (runs off the main actor)

    /// Builds the file list for `root`: git-aware first, filesystem walk second.
    /// Internal visibility keeps the recursive behavior integration-testable.
    nonisolated static func buildIndex(root: String) -> [FileItem] {
        if currentTaskIsCancelled() { return [] }
        // Keep this boundary correct for direct callers too. macOS exposes /tmp
        // and /var through symlinks while FileManager enumerates /private/…;
        // without normalization nested paths can collapse to bare basenames.
        let normalizedRoot = normalize(root)
        if let gitFiles = gitListFiles(root: normalizedRoot) {
            // git ls-files omits .gitignored files, but .env* / .dev.vars are
            // exactly the ignored files a developer opens by hand. Add them back
            // via a pruned walk (node_modules and friends stay skipped), deduped
            // against the git set so non-ignored env files aren't listed twice.
            var seen = Set(gitFiles.map(\.path))
            var merged = gitFiles
            for item in walkFilesystem(root: normalizedRoot, includeName: { Self.isDevConfigFile($0) })
            where merged.count < maxIndexedFiles && !seen.contains(item.path) {
                if currentTaskIsCancelled() { return [] }
                merged.append(item)
                seen.insert(item.path)
            }
            return merged
        }
        return walkFilesystem(root: normalizedRoot)
    }

    /// Gitignored files worth surfacing anyway: env files and wrangler's local
    /// secrets (`.dev.vars`). Matched by basename so they're found wherever they
    /// sit in the tree.
    private nonisolated static func isDevConfigFile(_ name: String) -> Bool {
        name.hasPrefix(".env") || name.hasPrefix(".dev.vars")
    }

    /// `git ls-files --cached --others --exclude-standard -z` enumerates tracked
    /// *and* untracked-but-not-ignored files, NUL-separated, relative to `root`.
    /// Returns `nil` when `root` isn't a git work tree or git fails/missing, so
    /// the caller can fall back to a filesystem walk.
    private nonisolated static func gitListFiles(root: String) -> [FileItem]? {
        if currentTaskIsCancelled() { return [] }
        let invocation = ProcessInvocation.developerTool(
            "git",
            arguments: [
                "-C", root,
                "ls-files", "--cached", "--others", "--exclude-standard", "-z",
            ],
            timeout: .seconds(30),
            standardOutputLimit: 32 * 1_024 * 1_024
        )
        guard let result = try? ProcessRunner.runBlocking(invocation) else {
            return nil   // git not found / not a repository — fall back to walking.
        }
        if currentTaskIsCancelled() { return [] }
        let data = result.standardOutput

        let prefix = root.hasSuffix("/") ? root : root + "/"
        var items: [FileItem] = []
        items.reserveCapacity(min(4096, maxIndexedFiles))

        // Split on the NUL separator at the byte level *before* decoding, then
        // decode each path lossily on its own. Whole-buffer UTF-8 decoding fails
        // outright if any single filename has invalid bytes (seen on SMB/exFAT),
        // which would throw away the entire git index; per-path decoding drops at
        // most the one bad entry.
        for chunk in data.split(separator: 0x00, omittingEmptySubsequences: true) {
            if items.count.isMultiple(of: 256), currentTaskIsCancelled() { return [] }
            let relativePath = String(decoding: chunk, as: UTF8.self)
            if relativePath.isEmpty { continue }
            items.append(FileItem(
                path: prefix + relativePath,
                relativePath: relativePath,
                name: (relativePath as NSString).lastPathComponent
            ))
            if items.count >= maxIndexedFiles { break }
        }
        return items
    }

    /// Filesystem fallback: a pruned recursive walk that skips known build/cache
    /// directories and collects regular files only.
    private nonisolated static func walkFilesystem(
        root: String,
        includeName: (@Sendable (String) -> Bool)? = nil
    ) -> [FileItem] {
        let fileManager = FileManager.default
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]

        // Don't skip hidden files: the git path surfaces non-ignored dotfiles
        // (.github/, .env, .gitignore, …), so the walk should too. The
        // `skippedDirectories` prune below still keeps .git/.idea/.build/etc out,
        // so only genuine dotfiles become reachable — not VCS/build junk.
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }   // skip unreadable entries, keep going
        ) else {
            return []
        }

        let prefix = root.hasSuffix("/") ? root : root + "/"
        var items: [FileItem] = []
        var visitedEntries = 0

        for case let url as URL in enumerator {
            if visitedEntries.isMultiple(of: 256), currentTaskIsCancelled() { return [] }
            visitedEntries += 1
            let values = try? url.resourceValues(forKeys: Set(keys))

            if values?.isDirectory == true {
                // Prune entire subtrees we never want to surface.
                if skippedDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values?.isRegularFile == true else { continue }

            let name = url.lastPathComponent
            if let includeName, !includeName(name) { continue }

            let absolute = url.path
            let relativePath = absolute.hasPrefix(prefix) ? String(absolute.dropFirst(prefix.count)) : name
            items.append(FileItem(
                path: absolute,
                relativePath: relativePath,
                name: name
            ))
            if items.count >= maxIndexedFiles { break }
        }
        return items
    }

    /// Standardizes the root so idempotency checks compare apples to apples
    /// (expands `~`, resolves symlinks, resolves `..`, strips a trailing slash).
    ///
    /// Resolving symlinks matters because roots under /tmp, /var, /etc are
    /// themselves symlinks into /private/…. The enumerator yields the resolved
    /// /private/… paths, so the walk's `prefix` must match — otherwise the
    /// `hasPrefix` check fails and every relativePath collapses to its basename.
    /// `git -C` works fine with the resolved path.
    private nonisolated static func normalize(_ root: String) -> String {
        let expanded = (root as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: true)
        // `resolvingSymlinksInPath()` preserves the spelling of /var on recent
        // Foundation releases even though enumeration returns /private/var.
        // canonicalPath is the filesystem spelling FileManager itself uses.
        let canonicalPath: String?
        do {
            canonicalPath = try url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath
        } catch {
            canonicalPath = nil
        }
        let resolved = canonicalPath ?? url.resolvingSymlinksInPath().path
        // Do not run NSString.standardizingPath after canonicalization: it maps
        // `/private/var` back to `/var`, recreating the prefix mismatch above.
        var path = resolved
        if path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
