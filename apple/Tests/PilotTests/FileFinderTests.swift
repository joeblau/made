import Foundation
import Testing
@testable import Pilot

@Suite("File finder filtering")
struct FileFinderTests {

    private func item(_ relativePath: String) -> FileItem {
        FileItem(
            path: "/root/" + relativePath,
            relativePath: relativePath,
            name: (relativePath as NSString).lastPathComponent
        )
    }

    private func sample() -> [FileItem] {
        [
            "workers/rendezvous/src/index.ts",
            "workers/rendezvous/package.json",
            "workers/rendezvous/tsconfig.json",
            "workers/web/package.json",
            "apple/Sources/Pilot/EditorPaneView.swift",
            "apple/Sources/Pilot/FileFinder.swift",
            "apple/Tests/PilotTests/PaneCyclingTests.swift",
        ].map(item)
    }

    /// Regression: a query that only appears in the *directory* path (no file is
    /// named "rendezvous") must still surface the files inside that directory.
    /// The old name-only matcher returned nothing here.
    @Test("Files are findable by a directory-name substring")
    func findsByDirectorySubstring() {
        let results = FileFinder.filter(items: sample(), query: "rendezvous")
        #expect(!results.isEmpty)
        #expect(results.allSatisfy { $0.relativePath.contains("rendezvous") })
        #expect(results.contains { $0.name == "index.ts" })
        #expect(results.contains { $0.name == "package.json" })
    }

    /// Quick-open is preserved: a basename match outranks a path-only match of
    /// the same query, so typing a filename still lands that file first.
    @Test("A basename match outranks a path-only match")
    func basenameOutranksPath() {
        let files = [
            item("zoo/Sources/helpers/util.swift"),     // "pane" only via the dir? no — control row
            item("pane/Sources/helpers/util.swift"),    // "pane" only in the directory
            item("apple/Sources/Pilot/EditorPaneView.swift"), // "pane" in the basename
        ]
        let results = FileFinder.filter(items: files, query: "pane")
        #expect(results.first?.name == "EditorPaneView.swift")
    }

    /// Typing the semantic filename without its extension should beat a longer
    /// prefix match, just as quick-open does in full IDEs.
    @Test("An exact filename stem outranks a longer filename prefix")
    func exactFilenameStemOutranksLongerPrefix() {
        let files = [
            item("Sources/Production.generated.swift"),
            item(".github/workflows/production.yml"),
            item("docs/production-notes.md"),
        ]

        let results = FileFinder.filter(items: files, query: "production")

        #expect(results.first?.relativePath == ".github/workflows/production.yml")
    }

    /// A query containing "/" matches against the full relative path.
    @Test("A slash query matches the full path")
    func slashQueryMatchesPath() {
        let results = FileFinder.filter(items: sample(), query: "rendezvous/index")
        #expect(results.first?.relativePath == "workers/rendezvous/src/index.ts")
    }

    /// No query is the "browse" case: the whole list, alphabetized by path.
    @Test("Empty query returns the tree alphabetized")
    func emptyQueryAlphabetized() {
        let files = sample()
        let results = FileFinder.filter(items: files, query: "")
        #expect(results.count == files.count)
        let expected = files.map(\.relativePath)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        #expect(results.map(\.relativePath) == expected)
    }

    /// A greedy matcher commits to the first `a` and misses the stronger `ab`
    /// run later in the same candidate. The scorer should choose the best
    /// alignment, not merely the first valid subsequence.
    @Test("The best later fuzzy alignment wins")
    func bestLaterAlignmentWins() throws {
        let laterRun = try #require(FuzzyMatcher.score(query: "ab", candidate: "a---ab.swift"))
        let scattered = try #require(FuzzyMatcher.score(query: "ab", candidate: "axxb.swift"))

        #expect(laterRun > scattered)
    }

    /// Boundary bonuses make acronym-style matching useful, but they must not
    /// outweigh an exact contiguous filename match for the same query.
    @Test("A contiguous exact match outranks scattered boundary matches")
    func contiguousMatchOutranksScatteredBoundaries() throws {
        let contiguous = try #require(FuzzyMatcher.score(query: "abc", candidate: "abc.swift"))
        let boundaryScattered = try #require(FuzzyMatcher.score(query: "abc", candidate: "a_x_b_c.swift"))

        #expect(contiguous > boundaryScattered)
    }

    /// Space-separated terms may target different path components and need not
    /// be typed in path order. This is the common "project + filename" flow.
    @Test("Multiple search terms may match independently")
    func multipleTermsMatchIndependently() {
        let files = [
            item("apple/Sources/Pilot/EditorPaneView.swift"),
            item("apple/Sources/Pilot/FileFinder.swift"),
            item("docs/EditorPaneView.md"),
        ]

        let forward = FileFinder.filter(items: files, query: "pilot editor")
        let reversed = FileFinder.filter(items: files, query: "editor pilot")

        #expect(forward.map(\.relativePath) == ["apple/Sources/Pilot/EditorPaneView.swift"])
        #expect(reversed.map(\.relativePath) == ["apple/Sources/Pilot/EditorPaneView.swift"])
    }

    /// Both common path separator styles should work, and omitted intermediate
    /// directories should not prevent a recursively indexed file from matching.
    @Test("Recursive path queries accept either separator style")
    func pathQueriesAcceptFlexibleSeparators() {
        let files = [
            item("packages/editor/Sources/Search/FileFinder.swift"),
            item("packages/terminal/Sources/Search/FileFinder.swift"),
        ]

        let slash = FileFinder.filter(items: files, query: "packages/editor/file")
        let backslash = FileFinder.filter(items: files, query: "packages\\editor\\file")

        #expect(slash.first?.relativePath == "packages/editor/Sources/Search/FileFinder.swift")
        #expect(backslash.first?.relativePath == "packages/editor/Sources/Search/FileFinder.swift")
    }

    /// Equal-scoring, equal-length paths need a stable lexical tiebreaker rather
    /// than inheriting filesystem enumeration or caller input order.
    @Test("Equal fuzzy matches have deterministic lexical ordering")
    func equalMatchesAreDeterministic() {
        let firstOrder = [item("zulu/Target.swift"), item("able/Target.swift")]
        let secondOrder = firstOrder.reversed()
        let expected = ["able/Target.swift", "zulu/Target.swift"]

        #expect(FileFinder.filter(items: firstOrder, query: "target").map(\.relativePath) == expected)
        #expect(FileFinder.filter(items: Array(secondOrder), query: "target").map(\.relativePath) == expected)
    }

    /// The folded forms are cached when the item is built (index time), so the
    /// per-keystroke filter never has to re-lowercase candidates.
    @Test("Case-folded forms are precomputed on FileItem")
    func foldedFormsArePrecomputed() {
        let file = item("Apple/Sources/Pilot/FileFinder.swift")
        #expect(file.foldedRelativePath == "apple/sources/pilot/filefinder.swift")
        #expect(file.foldedName == "filefinder.swift")
    }

    /// Tier bonuses compare the query against the *cached* folds, so matching
    /// must stay case-insensitive in both directions: an uppercase query still
    /// lands the mixed-case file, and the exact-stem tier still outranks a
    /// weaker path hit.
    @Test("Mixed-case queries rank via the cached folds")
    func mixedCaseQueriesRankViaCachedFolds() {
        let files = [
            item("docs/filefinder-notes.md"),
            item("apple/Sources/Pilot/FileFinder.swift"),
        ]

        let upper = FileFinder.filter(items: files, query: "FILEFINDER")
        let lower = FileFinder.filter(items: files, query: "filefinder")

        #expect(upper.first?.name == "FileFinder.swift")
        #expect(lower.first?.name == "FileFinder.swift")
    }

    /// The one-letter fast path streams the scalar view instead of building an
    /// array per candidate; its position bonuses (basename start beats an
    /// interior hit) must be unchanged.
    @Test("One-letter queries keep their position bonuses")
    func singleLetterQueriesKeepPositionBonuses() throws {
        let basenameStart = try #require(FuzzyMatcher.score(query: "f", candidate: "FileFinder.swift"))
        let afterSeparator = try #require(FuzzyMatcher.score(query: "f", candidate: "a/File.swift"))
        let interior = try #require(FuzzyMatcher.score(query: "f", candidate: "xf"))

        #expect(basenameStart > afterSeparator)
        #expect(afterSeparator > interior)
        #expect(FuzzyMatcher.score(query: "q", candidate: "FileFinder.swift") == nil)
    }

    /// Exercises indexing against a real nested tree so this catches regressions
    /// in the non-git recursive-walk fallback, not just the in-memory filter.
    @Test("A real nested directory is indexed recursively")
    func indexesRealNestedDirectory() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("BlauFileFinderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let nestedDirectory = root
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("Features", isDirectory: true)
            .appendingPathComponent("Search", isDirectory: true)
        try fileManager.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        let nestedFile = nestedDirectory.appendingPathComponent("NestedResult.swift")
        try "struct NestedResult {}\n".write(to: nestedFile, atomically: true, encoding: .utf8)

        let indexed = FileFinder.buildIndex(root: root.path)

        #expect(indexed.contains {
            $0.relativePath == "Sources/Features/Search/NestedResult.swift"
        }, "Indexed paths: \(indexed.map(\.relativePath))")
    }

    /// The fast Git-backed path must be just as recursive as the filesystem
    /// fallback and must include both tracked and new, untracked project files.
    @Test("A Git workspace indexes tracked and untracked nested files recursively")
    func indexesNestedGitWorkspace() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("BlauGitFileFinderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(["init", "--quiet"], at: root)

        let tracked = root.appendingPathComponent("Sources/App/Tracked.swift")
        let untracked = root.appendingPathComponent("Tests/Deep/UntrackedSpec.swift")
        try fileManager.createDirectory(
            at: tracked.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: untracked.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "struct Tracked {}\n".write(to: tracked, atomically: true, encoding: .utf8)
        try "struct UntrackedSpec {}\n".write(to: untracked, atomically: true, encoding: .utf8)
        try runGit(["add", "Sources/App/Tracked.swift"], at: root)

        let indexed = FileFinder.buildIndex(root: root.path)
        let paths = Set(indexed.map(\.relativePath))

        #expect(paths.contains("Sources/App/Tracked.swift"))
        #expect(paths.contains("Tests/Deep/UntrackedSpec.swift"))
    }

    private func runGit(_ arguments: [String], at root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
