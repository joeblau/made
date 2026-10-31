import Foundation

/// Directory index + fuzzy search for choosing a new workspace's folder.
///
/// `start()` walks `root` (default `~/Developer`) off the main actor and
/// `setQuery(_:)` ranks the indexed directories with `FileFinder.filter`, so
/// folder search behaves like the editor's file finder. The walk skips hidden
/// entries, packages, and `FileFinder.skippedDirectories`, and stops at
/// `maxDepth` and `maxIndexedDirectories` to bound time and memory.
@MainActor
@Observable
final class DirectoryFinder {
    /// Ranked matches for the current query; empty while the query is empty.
    private(set) var results: [FileItem] = []
    /// True while the background index is being built.
    private(set) var isIndexing = false

    let root: String

    @ObservationIgnored private var index: [FileItem] = []
    @ObservationIgnored private var query = ""
    /// Last-write-wins guard so a slow filter for an old keystroke never
    /// replaces the results for a newer one.
    @ObservationIgnored private var queryGeneration = 0
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var filterTask: Task<Void, Never>?

    /// Project roots sit a few levels down (`owner/src/project`); deeper
    /// directories are source trees, not workspace destinations.
    nonisolated static let maxDepth = 6
    nonisolated static let maxIndexedDirectories = 100_000
    nonisolated static let maxResults = 50

    init(root: String = (NSHomeDirectory() as NSString).appendingPathComponent("Developer")) {
        self.root = root
    }

    deinit {
        indexTask?.cancel()
        filterTask?.cancel()
    }

    /// Builds or refreshes the index. The previous index stays searchable until
    /// the refresh lands, and calls while a scan is running are coalesced.
    func start() {
        guard !isIndexing else { return }
        isIndexing = true
        let root = self.root
        indexTask = Task.detached(priority: .userInitiated) { [weak self] in
            let items = Self.buildIndex(root: root)
            guard !Task.isCancelled else { return }
            await self?.publishIndex(items)
        }
    }

    private func publishIndex(_ items: [FileItem]) {
        indexTask = nil
        index = items
        isIndexing = false
        refilter()
    }

    func setQuery(_ query: String) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        refilter()
    }

    private func refilter() {
        filterTask?.cancel()
        queryGeneration += 1
        let generation = queryGeneration
        let query = self.query
        guard !query.isEmpty else {
            filterTask = nil
            results = []
            return
        }
        let snapshot = index
        filterTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Brief debounce so a burst of keystrokes only scans once.
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return
            }
            let computed = Array(FileFinder.filter(items: snapshot, query: query).prefix(Self.maxResults))
            guard !Task.isCancelled else { return }
            await self?.publishResults(computed, generation: generation)
        }
    }

    private func publishResults(_ computed: [FileItem], generation: Int) {
        guard queryGeneration == generation else { return }
        filterTask = nil
        results = computed
    }

    // MARK: - Indexing (runs off the main actor)

    /// Lists directories under `root`, excluding `root` itself. Symlinks are not
    /// followed, so a link cycle cannot extend the walk.
    nonisolated static func buildIndex(root: String) -> [FileItem] {
        let normalizedRoot = FileFinder.normalize(root)
        let rootURL = URL(fileURLWithPath: normalizedRoot, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }   // skip unreadable entries, keep going
        ) else {
            return []
        }

        let prefix = normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"
        var items: [FileItem] = []
        var visitedEntries = 0

        for case let url as URL in enumerator {
            if visitedEntries.isMultiple(of: 256), Task.isCancelled { return [] }
            visitedEntries += 1

            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true else { continue }

            let name = url.lastPathComponent
            // App bundles, Xcode projects, and asset catalogs are directories on
            // disk but never a workspace destination.
            if values?.isPackage == true || FileFinder.skippedDirectories.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            if enumerator.level >= maxDepth {
                enumerator.skipDescendants()
            }

            let absolute = url.path
            guard absolute.hasPrefix(prefix) else { continue }
            items.append(FileItem(
                path: absolute,
                relativePath: String(absolute.dropFirst(prefix.count)),
                name: name
            ))
            if items.count >= maxIndexedDirectories { break }
        }
        return items
    }
}
