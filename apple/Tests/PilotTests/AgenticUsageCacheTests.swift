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

    @Test("A restored cache resumes an append by reading only its new bytes")
    func changedFileInvalidatesEntry() async throws {
        let corpus = try makeCorpus()
        defer { corpus.tearDown() }

        let first = AgenticUsageLoader(sources: [corpus.source], cacheURL: corpus.cacheURL)
        _ = try await first.load()
        await first.flushCacheWrites()

        let appended = Data((Self.kimiLine2 + "\n").utf8)
        let handle = try FileHandle(forWritingTo: corpus.logFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: appended)
        try handle.close()
        let progress = ProgressLog()
        let second = AgenticUsageLoader(sources: [corpus.source], cacheURL: corpus.cacheURL)
        let result = try await second.load { progress.record(scanned: $0, total: $1) }
        #expect(result.records.count == 2)
        #expect(result.parsedByteCount == appended.count)
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

@Suite("Agentic usage incremental parsing")
struct AgenticUsageIncrementalTests {
    private static func kimi(_ serial: Int) -> String {
        """
        {"type":"usage.record","model":"kimi-code/k3","usage":{"inputOther":\(serial),"output":\(serial + 1)},"usageScope":"turn","time":\(1786115071956 + serial * 1000)}
        """
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentic-incremental-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func source(_ root: URL, provider: AgenticProvider = .kimi) -> AgenticUsageLoader.Source {
        .init(provider: provider, rootDirectory: root)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    @discardableResult
    private func append(_ text: String, to url: URL) throws -> Int {
        let data = Data(text.utf8)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        return data.count
    }

    private func fullScan(
        _ root: URL, provider: AgenticProvider = .kimi
    ) async throws -> [AgenticUsageRecord] {
        try await AgenticUsageLoader(sources: [source(root, provider: provider)]).load().records
    }

    @Test("A small append to a large log reads only the appended region")
    func smallAppendReadsOnlyNewBytes() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.jsonl")
        let original = (0..<2_000).map { Self.kimi($0) }.joined(separator: "\n") + "\n"
        try write(original, to: url)
        let loader = AgenticUsageLoader(sources: [source(root)])

        let cold = try await loader.load()
        #expect(cold.records.count == 2_000)
        #expect(cold.parsedByteCount == Data(original.utf8).count)
        let unchanged = try await loader.load()
        #expect(!unchanged.changed)
        #expect(unchanged.parsedByteCount == 0)

        let appendedByteCount = try append(Self.kimi(2_000) + "\n", to: url)
        let appended = try await loader.load()
        #expect(appended.parsedByteCount == appendedByteCount)
        #expect(appended.records.count == 2_001)
        #expect(appended.records == (try await fullScan(root)))
    }

    @Test("Unterminated records stay visible without being committed twice")
    func partialLinesMatchFullScans() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.jsonl")
        try write(Self.kimi(1) + "\n" + Self.kimi(2), to: url)
        let loader = AgenticUsageLoader(sources: [source(root)])

        let first = try await loader.load()
        #expect(first.records.count == 2)
        #expect(first.records == (try await fullScan(root)))
        let unchanged = try await loader.load()
        #expect(unchanged.records == first.records)
        #expect(unchanged.parsedByteCount == 0)

        let malformed = #"{"type":"usage.record","model":"#
        let appendedByteCount = try append("\n" + malformed + "\n" + Self.kimi(3), to: url)
        let resumed = try await loader.load()
        #expect(resumed.parsedByteCount == appendedByteCount)
        #expect(resumed.records.count == 3)
        #expect(resumed.records == (try await fullScan(root)))

        let finalByteCount = try append("\n" + Self.kimi(4) + "\n", to: url)
        let completed = try await loader.load()
        #expect(completed.parsedByteCount == finalByteCount)
        #expect(completed.records.count == 4)
        #expect(completed.records == (try await fullScan(root)))
    }

    @Test("Codex appends retain the current model and cumulative token cursor")
    func codexStateMatchesFullScan() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rollout.jsonl")
        let context = """
        {"timestamp":"2026-08-14T02:34:00.000Z","ordinal":7,"type":"turn_context","payload":{"turn_id":"t1","model":"gpt-5.6-sol"}}
        """
        let firstUsage = """
        {"timestamp":"2026-08-14T02:34:35.653Z","ordinal":17,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":16433,"cached_input_tokens":11008,"cache_write_input_tokens":0,"output_tokens":219,"reasoning_output_tokens":71},"last_token_usage":{"input_tokens":16433,"cached_input_tokens":11008,"cache_write_input_tokens":0,"output_tokens":219,"reasoning_output_tokens":71}}}}
        """
        try write(context + "\n" + firstUsage + "\n", to: url)
        let cacheURL = root.appendingPathComponent("usage-cache.json")
        let initialLoader = AgenticUsageLoader(
            sources: [source(root, provider: .codex)], cacheURL: cacheURL
        )
        #expect(try await initialLoader.load().records.count == 1)
        await initialLoader.flushCacheWrites()

        let nextContext = context
            .replacingOccurrences(of: "gpt-5.6-sol", with: "gpt-6.1-sol")
            .replacingOccurrences(of: "02:34:00", with: "02:35:00")
        let nextUsage = """
        {"timestamp":"2026-08-14T02:35:10.000Z","ordinal":25,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":36433,"cached_input_tokens":27008,"cache_write_input_tokens":0,"output_tokens":519,"reasoning_output_tokens":171}}}}
        """
        let appendedByteCount = try append(nextContext + "\n" + nextUsage + "\n", to: url)
        let loader = AgenticUsageLoader(
            sources: [source(root, provider: .codex)], cacheURL: cacheURL
        )
        let result = try await loader.load()
        #expect(result.parsedByteCount == appendedByteCount)
        #expect(result.records.count == 2)
        #expect(result.records.last?.model == "gpt-6.1-sol")
        #expect(result.records.last?.inputTokens == (36433 - 16433) - (27008 - 11008))
        #expect(result.records.last?.cacheReadTokens == 27008 - 11008)
        #expect(result.records.last?.outputTokens == 300)
        #expect(result.records == (try await fullScan(root, provider: .codex)))
    }

    @Test("Moves, truncation, replacement, deletion, and provider changes rebuild exactly")
    func incompatibleFilesMatchFullScans() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("sessions/one.jsonl")
        try write(Self.kimi(1) + "\n" + Self.kimi(2) + "\n", to: original)
        let cacheURL = root.appendingPathComponent("usage-cache.json")
        let loader = AgenticUsageLoader(sources: [source(root)], cacheURL: cacheURL)
        _ = try await loader.load()

        let archived = root.appendingPathComponent("archived/one.jsonl")
        try FileManager.default.createDirectory(
            at: archived.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: original, to: archived)
        let moved = try await loader.load()
        #expect(moved.records == (try await fullScan(root)))
        let movedText = Self.kimi(1) + "\n" + Self.kimi(2) + "\n"
        #expect(moved.parsedByteCount == Data(movedText.utf8).count)

        _ = try append(#"{"type":"usage.record","model":"# + "\n", to: archived)
        let malformed = try await loader.load()
        #expect(!malformed.changed)
        #expect(malformed.records == (try await fullScan(root)))

        let truncatedText = Self.kimi(1) + "\n"
        try write(truncatedText, to: archived)
        let truncated = try await loader.load()
        #expect(truncated.parsedByteCount == Data(truncatedText.utf8).count)
        #expect(truncated.records == (try await fullScan(root)))

        let attributes = try FileManager.default.attributesOfItem(atPath: archived.path)
        let modificationDate = try #require(attributes[.modificationDate])
        let replacementText = Self.kimi(9) + "\n"
        let replacement = root.appendingPathComponent("replacement.tmp")
        try write(replacementText, to: replacement)
        try FileManager.default.removeItem(at: archived)
        try FileManager.default.moveItem(at: replacement, to: archived)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate], ofItemAtPath: archived.path
        )
        let replaced = try await loader.load()
        #expect(replaced.parsedByteCount == Data(replacementText.utf8).count)
        #expect(replaced.records == (try await fullScan(root)))

        await loader.flushCacheWrites()
        let claudeLoader = AgenticUsageLoader(
            sources: [source(root, provider: .claude)], cacheURL: cacheURL
        )
        let providerChanged = try await claudeLoader.load()
        #expect(providerChanged.parsedByteCount == Data(replacementText.utf8).count)
        #expect(providerChanged.records.isEmpty)
        #expect(providerChanged.records == (try await fullScan(root, provider: .claude)))

        try FileManager.default.removeItem(at: archived)
        let deleted = try await claudeLoader.load()
        #expect(deleted.records.isEmpty)
        #expect(deleted.fileCount == 0)
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
