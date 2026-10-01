import Foundation
import Testing
@testable import Pilot

/// Incremental parsing must always agree with a full rescan: appends resume
/// from the saved cursor, and anything else falls back to reparsing.
@Suite("Agentic usage incremental loading")
struct AgenticUsageIncrementalTests {
    // MARK: Fixtures

    private static func claude(_ serial: Int, output: Int = 40) -> String {
        """
        {"type":"assistant","requestId":"req_\(serial)","timestamp":"2026-08-14T10:00:\(String(format: "%02d", serial % 60)).000Z","message":{"id":"msg_\(serial)","model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":1000,"output_tokens":\(output)}}}
        """
    }

    private static func codexContext(_ model: String) -> String {
        """
        {"timestamp":"2026-08-14T02:34:00.000Z","ordinal":1,"type":"turn_context","payload":{"turn_id":"t1","model":"\(model)"}}
        """
    }

    private static func codexCount(ordinal: Int, total: Int, last: Int?) -> String {
        let lastUsage = last.map {
            #","last_token_usage":{"input_tokens":\#($0),"cached_input_tokens":0,"output_tokens":10}"#
        } ?? ""
        return """
        {"timestamp":"2026-08-14T02:35:\(String(format: "%02d", ordinal % 60)).000Z","ordinal":\(ordinal),"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(total),"cached_input_tokens":0,"output_tokens":\(total / 10)}\(lastUsage)}}}
        """
    }

    private static let grok = """
    {"timestamp":1784526657,"params":{"update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":300,"outputTokens":30,"totalTokens":330,"cachedReadTokens":100,"costUsdTicks":794792000}}}}
    """

    private static let kimi = """
    {"type":"usage.record","model":"kimi-code/k3","usage":{"inputOther":2134,"output":99,"inputCacheRead":18944,"inputCacheCreation":0},"usageScope":"turn","time":1786115071956}
    """

    private static let noise = #"{"type":"user","message":{"content":"not a usage record"}}"#

    private func makeDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentic-incremental-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func fullParse(_ url: URL, _ provider: AgenticProvider) throws -> [AgenticUsageRecord] {
        AgenticUsageLoader.parse(data: try Data(contentsOf: url), provider: provider)
    }

    private func scan(
        _ url: URL,
        _ provider: AgenticProvider,
        resuming previous: AgenticUsageLoader.FileCursor? = nil
    ) throws -> AgenticUsageLoader.FileScan {
        try #require(try AgenticUsageLoader.scanFile(at: url, provider: provider, resuming: previous))
    }

    // MARK: Chunked parsing

    @Test("Every chunking of a log yields the records of parsing it whole")
    func chunkingParity() {
        let text = [
            Self.claude(1), Self.noise, Self.claude(2, output: 90), "{malformed",
            Self.codexContext("gpt-5.6-sol"), Self.codexCount(ordinal: 2, total: 100, last: 100),
            Self.codexCount(ordinal: 3, total: 100, last: 100), Self.codexCount(ordinal: 4, total: 250, last: nil),
            Self.grok, Self.kimi, "",
        ].joined(separator: "\n") + Self.claude(3)
        let data = Data(text.utf8)

        for provider in AgenticProvider.allCases {
            let whole = AgenticUsageLoader.parse(data: data, provider: provider)
            for chunkSize in [1, 2, 3, 7, 23, 64, 511, data.count] {
                var parser = AgenticUsageLogParser(provider: provider)
                var offset = 0
                while offset < data.count {
                    let end = min(offset + chunkSize, data.count)
                    try? parser.consume(data.subdata(in: offset..<end), checkCancellation: false)
                    offset = end
                }
                let chunked = parser.records + parser.provisionalTailRecords()
                #expect(chunked == whole, "\(provider) chunk \(chunkSize)")
                #expect(parser.consumedBytes == data.count)
            }
        }
        #expect(AgenticUsageLoader.parse(data: data, provider: .claude).count == 3)
        #expect(AgenticUsageLoader.parse(data: data, provider: .codex).count == 2)
    }

    @Test("A line over the line bound is skipped even when split across chunks")
    func oversizedLineAcrossChunks() {
        let padding = String(repeating: "x", count: AgenticUsageLoader.maxLineBytes)
        let oversized = #"{"type":"assistant","pad":""# + padding + #""}"#
        let text = Self.claude(1) + "\n" + oversized + "\n" + Self.claude(2) + "\n"
        let data = Data(text.utf8)
        let whole = AgenticUsageLoader.parse(data: data, provider: .claude)
        #expect(whole.count == 2)

        for chunkSize in [1 << 20, 3 << 20, 5_000_001] {
            var parser = AgenticUsageLogParser(provider: .claude)
            var offset = 0
            while offset < data.count {
                let end = min(offset + chunkSize, data.count)
                try? parser.consume(data.subdata(in: offset..<end), checkCancellation: false)
                #expect(parser.pending.count <= AgenticUsageLoader.maxLineBytes)
                offset = end
            }
            #expect(parser.records == whole)
        }
    }

    // MARK: File cursors

    @Test("An append reads only the new bytes and matches a full rescan")
    func appendResumes() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.jsonl")
        try write((1...50).map { Self.claude($0) }.joined(separator: "\n") + "\n", to: url)
        let first = try scan(url, .claude)
        #expect(!first.resumed)
        #expect(first.cursor.records.count == 50)

        let appended = Self.claude(51) + "\n" + Self.noise + "\n" + Self.claude(52) + "\n"
        try append(appended, to: url)
        let second = try scan(url, .claude, resuming: first.cursor)

        #expect(second.resumed)
        #expect(second.bytesRead == appended.utf8.count)
        #expect(second.recordsChanged)
        #expect(second.cursor.records == (try fullParse(url, .claude)))
        #expect(second.cursor.records.count == 52)

        let third = try scan(url, .claude, resuming: second.cursor)
        #expect(third.resumed)
        #expect(third.bytesRead == 0)
        #expect(!third.recordsChanged)
    }

    @Test("A partial trailing line is provisional until it is completed")
    func partialLineCompletes() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.jsonl")
        let complete = Self.claude(1)
        let split = complete.utf8.count / 2
        try write(Self.claude(0) + "\n" + String(complete.prefix(split)), to: url)

        let partial = try scan(url, .claude)
        #expect(partial.cursor.records == (try fullParse(url, .claude)))
        #expect(partial.cursor.records.count == 1)

        try append(String(complete.dropFirst(split)), to: url)
        let unterminated = try scan(url, .claude, resuming: partial.cursor)
        #expect(unterminated.resumed)
        // A complete record without its newline counts, exactly as a rescan
        // would count it, but is not committed yet.
        #expect(unterminated.cursor.records == (try fullParse(url, .claude)))
        #expect(unterminated.cursor.records.count == 2)
        #expect(unterminated.cursor.parser.records.count == 1)

        try append("\n" + Self.claude(2) + "\n", to: url)
        let terminated = try scan(url, .claude, resuming: unterminated.cursor)
        #expect(terminated.resumed)
        #expect(terminated.cursor.records == (try fullParse(url, .claude)))
        #expect(terminated.cursor.records.count == 3)
    }

    @Test("Codex model context and cumulative totals carry across an append")
    func codexContextAcrossAppend() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rollout.jsonl")
        try write(
            Self.codexContext("gpt-5.6-sol") + "\n"
                + Self.codexCount(ordinal: 2, total: 100, last: 100) + "\n",
            to: url
        )
        let first = try scan(url, .codex)

        // A repeat with unchanged totals, then a totals-only delta.
        try append(
            Self.codexCount(ordinal: 3, total: 100, last: 100) + "\n"
                + Self.codexCount(ordinal: 4, total: 250, last: nil) + "\n",
            to: url
        )
        let second = try scan(url, .codex, resuming: first.cursor)

        #expect(second.resumed)
        let records = second.cursor.records
        #expect(records == (try fullParse(url, .codex)))
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.model == "gpt-5.6-sol" })
        #expect(records.last?.inputTokens == 150)
    }

    @Test("Truncation, replacement, in-place rewrites, and provider changes rescan")
    func incompatibleChangesRescan() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.jsonl")
        try write((1...20).map { Self.claude($0) }.joined(separator: "\n") + "\n", to: url)
        let original = try scan(url, .claude)

        // Truncated to a shorter file.
        try FileHandle(forWritingTo: url).truncate(atOffset: 100)
        let truncated = try scan(url, .claude, resuming: original.cursor)
        #expect(!truncated.resumed)
        #expect(truncated.cursor.records == (try fullParse(url, .claude)))

        // Rewritten in place (same inode) with a different, longer prefix.
        let rewritten = (100...140).map { Self.claude($0, output: 7) }.joined(separator: "\n") + "\n"
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(rewritten.utf8))
        try handle.close()
        let inPlace = try scan(url, .claude, resuming: original.cursor)
        #expect(!inPlace.resumed)
        #expect(inPlace.cursor.records == (try fullParse(url, .claude)))

        // Replaced by a different file at the same path.
        let replacement = directory.appendingPathComponent("replacement.jsonl")
        try write((300...340).map { Self.claude($0) }.joined(separator: "\n") + "\n", to: replacement)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)
        let replaced = try scan(url, .claude, resuming: inPlace.cursor)
        #expect(!replaced.resumed)
        #expect(replaced.cursor.records == (try fullParse(url, .claude)))

        // The same bytes attributed to another provider.
        let otherProvider = try scan(url, .codex, resuming: replaced.cursor)
        #expect(!otherProvider.resumed)
        #expect(otherProvider.cursor.records.isEmpty)
    }

    // MARK: Loader

    private func sources(_ root: URL) -> [AgenticUsageLoader.Source] {
        [
            .init(provider: .claude, rootDirectory: root.appendingPathComponent("claude")),
            .init(provider: .codex, rootDirectory: root.appendingPathComponent("codex/sessions")),
            .init(provider: .codex, rootDirectory: root.appendingPathComponent("codex/archived_sessions")),
            .init(provider: .grok, rootDirectory: root.appendingPathComponent("grok"), fileName: "updates.jsonl"),
            .init(provider: .kimi, rootDirectory: root.appendingPathComponent("kimi"), fileName: "wire.jsonl"),
        ]
    }

    private func rescan(_ root: URL) async throws -> [AgenticUsageRecord] {
        try await AgenticUsageLoader(sources: sources(root)).load().records
    }

    @Test("Appends, deletions, archive moves, and malformed lines match a full rescan")
    func loaderParity() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let claudeA = root.appendingPathComponent("claude/a/one.jsonl")
        let claudeB = root.appendingPathComponent("claude/b/two.jsonl")
        let codex = root.appendingPathComponent("codex/sessions/2026/rollout-1.jsonl")
        let archived = root.appendingPathComponent("codex/archived_sessions/rollout-1.jsonl")
        let grok = root.appendingPathComponent("grok/s1/updates.jsonl")
        let kimi = root.appendingPathComponent("kimi/s1/wire.jsonl")
        try write(Self.claude(1) + "\n" + Self.claude(2) + "\n", to: claudeA)
        // A replayed copy of call 2 with its final output count.
        try write(Self.claude(2, output: 400) + "\n{broken\n", to: claudeB)
        try write(
            Self.codexContext("gpt-5.6-sol") + "\n" + Self.codexCount(ordinal: 2, total: 100, last: 100) + "\n",
            to: codex
        )
        try write(Self.grok + "\n", to: grok)
        try write(Self.kimi + "\n", to: kimi)

        let loader = AgenticUsageLoader(sources: sources(root))
        let initial = try await loader.load()
        #expect(initial.records == (try await rescan(root)))
        #expect(initial.records.count == 5)
        #expect(initial.records.first { $0.dedupKey?.contains("msg_2") == true }?.outputTokens == 400)

        let unchanged = try await loader.load()
        #expect(unchanged.records == initial.records)

        try append(Self.claude(3) + "\n" + String(Self.claude(4).prefix(30)), to: claudeA)
        try append(Self.codexCount(ordinal: 3, total: 300, last: 200) + "\n", to: codex)
        let appended = try await loader.load()
        #expect(appended.records == (try await rescan(root)))
        #expect(appended.records.count == 7)

        try FileManager.default.createDirectory(
            at: archived.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: codex, to: archived)
        try append(Self.codexCount(ordinal: 4, total: 450, last: 150) + "\n", to: archived)
        try FileManager.default.removeItem(at: claudeB)
        let moved = try await loader.load()
        #expect(moved.records == (try await rescan(root)))
        #expect(moved.records.count == 8)
        #expect(moved.records.first { $0.dedupKey?.contains("msg_2") == true }?.outputTokens == 40)
    }

    @Test("A cancelled load stops with CancellationError and leaves the cache usable")
    func cancellationLeavesCacheConsistent() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("claude/a/one.jsonl")
        try write((1...200).map { Self.claude($0) }.joined(separator: "\n") + "\n", to: url)
        let loader = AgenticUsageLoader(sources: sources(root))

        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await loader.load()
        }
        await #expect(throws: CancellationError.self) {
            _ = try await cancelled.value
        }

        let scanCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try AgenticUsageLoader.scanFile(at: url, provider: .claude, resuming: nil)
        }
        await #expect(throws: CancellationError.self) {
            _ = try await scanCancelled.value
        }

        let after = try await loader.load()
        #expect(after.records == (try await rescan(root)))
        #expect(after.records.count == 200)
    }

    @Test("A superseded load cannot overwrite the newer load's state")
    @MainActor
    func supersededLoadIsIgnored() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("claude/a/one.jsonl")
        try write((1...20).map { Self.claude($0) }.joined(separator: "\n") + "\n", to: url)
        let suiteName = "AgenticUsageIncrementalTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AgenticUseRange.all.rawValue, forKey: "agenticUse.range")
        let store = AgenticUsageStore(defaults: defaults, sources: sources(root))

        store.start()
        try append(Self.claude(21) + "\n", to: url)
        store.rescan()
        store.rescan()

        let deadline = ContinuousClock.now + .seconds(20)
        while store.snapshot == nil || store.phase != .loaded || store.isRefreshing {
            #expect(ContinuousClock.now < deadline)
            if ContinuousClock.now >= deadline { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        let tokens = store.snapshot?.modelTotals.reduce(0) { $0 + $1.tokens }
        let expected = try await rescan(root).reduce(0) { $0 + $1.totalTokens }
        #expect(tokens == expected)
        #expect(store.scanProgress == nil)
    }

    @Test("Snapshot aggregation stops when cancelled")
    func snapshotCancellation() {
        let records = AgenticUsageLoader.parse(
            data: Data(((1...10).map { Self.claude($0) }.joined(separator: "\n")).utf8),
            provider: .claude
        )
        let cancelled = AgenticUsageStore.makeSnapshot(
            records: records,
            range: .all,
            now: Date(timeIntervalSince1970: 1_790_000_000),
            calendar: Calendar(identifier: .gregorian)
        ) { true }
        #expect(cancelled == nil)
        let completed = AgenticUsageStore.makeSnapshot(
            records: records,
            range: .all,
            now: Date(timeIntervalSince1970: 1_790_000_000),
            calendar: Calendar(identifier: .gregorian)
        ) { false }
        #expect(completed?.modelTotals.count == 1)
    }
}
