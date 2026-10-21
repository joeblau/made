import Foundation
import Testing
@testable import Pilot

/// Thread-safe capture of the loader's `onProgress` callbacks. The first
/// call always reports how many files were served from cache without
/// parsing, which is exactly what these tests pin.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[Int]] = []

    func record(scanned: Int, total: Int) {
        lock.lock()
        defer { lock.unlock() }
        calls.append([scanned, total])
    }

    var first: [Int]? {
        lock.lock()
        defer { lock.unlock() }
        return calls.first
    }
}

@Suite("Agentic usage disk cache")
struct AgenticUsageCacheTests {
    private static let kimiLine = """
    {"type":"usage.record","model":"kimi-code/k3","usage":{"inputOther":1,"output":2},"usageScope":"turn","time":1786115071956}
    """
    private static let kimiLine2 = """
    {"type":"usage.record","model":"kimi-code/k3","usage":{"inputOther":5,"output":7},"usageScope":"turn","time":1786115072956}
    """

    private struct Corpus {
        let root: URL
        let logFile: URL
        let cacheURL: URL
        let source: AgenticUsageLoader.Source

        func tearDown() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeCorpus(lines: [String] = [kimiLine]) throws -> Corpus {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let logs = root.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let logFile = logs.appendingPathComponent("wire.jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: logFile)
        return Corpus(
            root: root,
            logFile: logFile,
            cacheURL: root.appendingPathComponent("cache/usage.json"),
            source: AgenticUsageLoader.Source(provider: .kimi, rootDirectory: logs, fileName: "wire.jsonl")
        )
    }

    @Test("A relaunch restores parsed records without re-parsing unchanged files")
    func persistedCacheRoundTrip() async throws {
        let corpus = try makeCorpus()
        defer { corpus.tearDown() }

        let first = AgenticUsageLoader(sources: [corpus.source], cacheURL: corpus.cacheURL)
        let original = try await first.load()
        #expect(original.records.count == 1)
        #expect(original.changed)
        await first.flushCacheWrites()
        #expect(FileManager.default.fileExists(atPath: corpus.cacheURL.path))

        // A fresh loader (a relaunch) serves the unchanged file from disk:
        // the initial progress report already covers every file.
        let progress = ProgressLog()
        let second = AgenticUsageLoader(sources: [corpus.source], cacheURL: corpus.cacheURL)
        let restored = try await second.load { progress.record(scanned: $0, total: $1) }
        #expect(restored.records == original.records)
        #expect(progress.first == [1, 1])
    }

    @Test("A changed source file re-parses instead of trusting its stale entry")
    func changedFileInvalidatesEntry() async throws {
        let corpus = try makeCorpus()
        defer { corpus.tearDown() }

        let first = AgenticUsageLoader(sources: [corpus.source], cacheURL: corpus.cacheURL)
        _ = try await first.load()
        await first.flushCacheWrites()

        try Data((Self.kimiLine + "\n" + Self.kimiLine2 + "\n").utf8).write(to: corpus.logFile)
        let progress = ProgressLog()
        let second = AgenticUsageLoader(sources: [corpus.source], cacheURL: corpus.cacheURL)
        let result = try await second.load { progress.record(scanned: $0, total: $1) }
        #expect(result.records.count == 2)
        #expect(progress.first == [0, 1])
    }

    @Test("Corrupt or stale-version cache blobs are a cold start, never an error")
    func rejectsCorruptAndStaleCaches() async throws {
        for blob in ["not json", #"{"version":0,"entries":{}}"#] {
            let corpus = try makeCorpus()
            defer { corpus.tearDown() }
            try FileManager.default.createDirectory(
                at: corpus.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(blob.utf8).write(to: corpus.cacheURL)

            let progress = ProgressLog()
            let loader = AgenticUsageLoader(sources: [corpus.source], cacheURL: corpus.cacheURL)
            let result = try await loader.load { progress.record(scanned: $0, total: $1) }
            #expect(result.records.count == 1)
            #expect(progress.first == [0, 1])
        }
    }

    @Test("An unreadable file never dirties the persisted cache")
    func unreadableFileDoesNotRewriteCache() async throws {
        let corpus = try makeCorpus()
        defer { corpus.tearDown() }

        let loader = AgenticUsageLoader(sources: [corpus.source], cacheURL: corpus.cacheURL)
        _ = try await loader.load()
        await loader.flushCacheWrites()
        #expect(FileManager.default.fileExists(atPath: corpus.cacheURL.path))

        // An unreadable file re-fails on every refresh, but it was never
        // cached, so removing its absent key mutates nothing: the blob must
        // not rewrite, tick after tick.
        let lockedDir = corpus.logFile.deletingLastPathComponent()
            .appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: lockedDir, withIntermediateDirectories: true)
        let lockedFile = lockedDir.appendingPathComponent("wire.jsonl")
        try Data((Self.kimiLine2 + "\n").utf8).write(to: lockedFile)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: lockedFile.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: lockedFile.path
            )
        }

        try FileManager.default.removeItem(at: corpus.cacheURL)
        let result = try await loader.load()
        #expect(result.unreadableFileCount == 1)
        await loader.flushCacheWrites()
        #expect(!FileManager.default.fileExists(atPath: corpus.cacheURL.path))
    }

    @Test("Flushing expedites a debounced write-back instead of waiting it out")
    func flushExpeditesDebouncedSave() async throws {
        let corpus = try makeCorpus()
        defer { corpus.tearDown() }

        let loader = AgenticUsageLoader(sources: [corpus.source], cacheURL: corpus.cacheURL)
        _ = try await loader.load()
        // The first write lands immediately and opens the debounce window.
        await loader.flushCacheWrites()

        try Data((Self.kimiLine + "\n" + Self.kimiLine2 + "\n").utf8).write(to: corpus.logFile)
        _ = try await loader.load()
        await loader.flushCacheWrites()

        // A fresh loader (a relaunch) must see the post-change entry.
        let progress = ProgressLog()
        let fresh = AgenticUsageLoader(sources: [corpus.source], cacheURL: corpus.cacheURL)
        let restored = try await fresh.load { progress.record(scanned: $0, total: $1) }
        #expect(restored.records.count == 2)
        #expect(progress.first == [1, 1])
    }

    @Test("Refreshes with no file changes return the previous records un-rebuilt")
    func unchangedRefreshShortCircuits() async throws {
        let corpus = try makeCorpus()
        defer { corpus.tearDown() }

        let loader = AgenticUsageLoader(sources: [corpus.source])
        let first = try await loader.load()
        #expect(first.changed)
        let second = try await loader.load()
        #expect(!second.changed)
        #expect(second.records == first.records)

        try Data((Self.kimiLine + "\n" + Self.kimiLine2 + "\n").utf8).write(to: corpus.logFile)
        let third = try await loader.load()
        #expect(third.changed)
        #expect(third.records.count == 2)
    }
}

@Suite("Agentic use chart hover snapping")
struct AgenticUseChartSelectionTests {
    @Test("Hover dates snap to hour buckets for 24h and day buckets otherwise")
    func snapsToBucketGrid() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let base = Date(timeIntervalSince1970: 1_786_000_000)

        let hour = AgenticUseDailyChartPanel.snappedBucket(for: base, range: .day, calendar: calendar)
        let sameHour = AgenticUseDailyChartPanel.snappedBucket(
            for: base.addingTimeInterval(59), range: .day, calendar: calendar
        )
        #expect(hour != nil)
        #expect(hour == sameHour)
        #expect(hour.map { calendar.component(.minute, from: $0) } == 0)
        let nextHour = AgenticUseDailyChartPanel.snappedBucket(
            for: base.addingTimeInterval(3600), range: .day, calendar: calendar
        )
        #expect(hour != nextHour)

        let day = AgenticUseDailyChartPanel.snappedBucket(for: base, range: .month, calendar: calendar)
        #expect(day == calendar.startOfDay(for: base))
        let sameDay = AgenticUseDailyChartPanel.snappedBucket(
            for: base.addingTimeInterval(3600), range: .month, calendar: calendar
        )
        #expect(day == sameDay)
    }
}
