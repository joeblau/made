import Foundation
import Testing
@testable import Pilot

@Suite("Workspace directory finder")
struct DirectoryFinderTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlauDirectoryFinderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeDirectory(_ relativePath: String, in root: URL) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(relativePath, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    @Test("Nested directories are indexed and files are not")
    func indexesNestedDirectoriesOnly() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeDirectory("joeblau/src/made/apple", in: root)
        try "readme\n".write(
            to: root.appendingPathComponent("joeblau/src/made/README.md"),
            atomically: true,
            encoding: .utf8
        )

        let paths = Set(DirectoryFinder.buildIndex(root: root.path).map(\.relativePath))

        #expect(paths.contains("joeblau"))
        #expect(paths.contains("joeblau/src/made"))
        #expect(paths.contains("joeblau/src/made/apple"))
        #expect(!paths.contains("joeblau/src/made/README.md"))
        #expect(!paths.contains(""), "The root itself is not a search result")
    }

    @Test("Hidden, build-output, and package directories are pruned")
    func prunesNoise() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeDirectory("web/node_modules/left-pad", in: root)
        try makeDirectory("web/.git/objects", in: root)
        try makeDirectory("app/Cockpit.app/Contents", in: root)
        try makeDirectory("app/Sources", in: root)

        let paths = Set(DirectoryFinder.buildIndex(root: root.path).map(\.relativePath))

        #expect(paths.contains("web"))
        #expect(paths.contains("app/Sources"))
        #expect(!paths.contains { $0.contains("node_modules") })
        #expect(!paths.contains { $0.contains(".git") })
        #expect(!paths.contains { $0.contains("Cockpit.app") })
    }

    @Test("The walk stops at the maximum depth")
    func stopsAtMaxDepth() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let components = (1...(DirectoryFinder.maxDepth + 2)).map { "d\($0)" }
        try makeDirectory(components.joined(separator: "/"), in: root)

        let depths = DirectoryFinder.buildIndex(root: root.path)
            .map { $0.relativePath.split(separator: "/").count }

        #expect(depths.max() == DirectoryFinder.maxDepth)
    }

    @Test("A project folder name ranks ahead of folders that only contain it")
    func ranksProjectFolderFirst() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeDirectory("joeblau/src/made/apple", in: root)
        try makeDirectory("archive/made-old", in: root)

        let items = DirectoryFinder.buildIndex(root: root.path)
        let results = FileFinder.filter(items: items, query: "made")

        #expect(results.first?.relativePath == "joeblau/src/made")
    }
}
