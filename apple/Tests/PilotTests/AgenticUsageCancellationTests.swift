import Foundation
import Testing
@testable import Pilot

/// Cancelling a usage load must stop work promptly and leave the loader's
/// cache and merged records exactly as the last completed load left them —
/// never half-updated — and a superseded load's late progress or results
/// must not overwrite the newer load's state.
@Suite("Agentic usage cancellation")
struct AgenticUsageCancellationTests {
    // MARK: Fixtures

    private static func claude(_ serial: Int, output: Int = 40) -> String {
        """
        {"type":"assistant","requestId":"req_\(serial)","timestamp":"2026-08-14T10:00:\(String(format: "%02d", serial % 60)).000Z","message":{"id":"msg_\(serial)","model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":1000,"output_tokens":\(output)}}}
        """
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentic-cancellation-\(UUID().uuidString)", isDirectory: true)
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

    private func sources(_ root: URL) -> [AgenticUsageLoader.Source] {
        [.init(provider: .claude, rootDirectory: root.appendingPathComponent("claude"))]
    }

    /// A fresh loader's full parse of the corpus — the ground truth any
    /// cached or partially-cancelled loader must agree with.
    private func rescan(_ root: URL) async throws -> [AgenticUsageRecord] {
        try await AgenticUsageLoader(sources: sources(root)).load().records
    }

    /// A pricing catalog that never touches the network.
    private func offlineCatalog(in root: URL) -> AgenticPricingCatalog {
        AgenticPricingCatalog(
            cacheURL: root.appendingPathComponent("pricing.json"),
            fetch: { throw URLError(.notConnectedToInternet) }
        )
    }

    // MARK: Loader

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

        let after = try await loader.load()
        #expect(after.records == (try await rescan(root)))
        #expect(after.records.count == 200)
    }

    @Test("A load cancelled at the merge leaves no stale merged result behind")
    func cancellationAtMergeKeepsResultsExact() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let claudeA = root.appendingPathComponent("claude/a/one.jsonl")
        let claudeB = root.appendingPathComponent("claude/b/two.jsonl")
        try write(Self.claude(1) + "\n" + Self.claude(2) + "\n", to: claudeA)
        try write(Self.claude(10) + "\n", to: claudeB)
        let loader = AgenticUsageLoader(sources: sources(root))
        #expect(try await loader.load().records.count == 3)

        // Every file is scanned, then the load's own task is cancelled at the
        // merge (each load runs in a child Task so the test's task survives).
        let cancelAtMerge: @Sendable () -> Void = { withUnsafeCurrentTask { $0?.cancel() } }

        try append(Self.claude(3) + "\n", to: claudeA)
        await loader.setWillMergeHook(cancelAtMerge)
        await #expect(throws: CancellationError.self) { _ = try await Task { try await loader.load() }.value }
        await loader.setWillMergeHook(nil)
        let appended = try await loader.load()
        #expect(appended.changed)
        #expect(appended.records == (try await rescan(root)))
        #expect(appended.records.count == 4)

        try FileManager.default.removeItem(at: claudeB)
        await loader.setWillMergeHook(cancelAtMerge)
        await #expect(throws: CancellationError.self) { _ = try await Task { try await loader.load() }.value }
        await loader.setWillMergeHook(nil)
        let deleted = try await loader.load()
        #expect(deleted.changed)
        #expect(deleted.records == (try await rescan(root)))
        #expect(deleted.records.count == 3)
    }

    // MARK: Store

    @Test("Progress from a superseded load is ignored")
    @MainActor
    func staleProgressIsIgnored() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "AgenticUsageCancellationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AgenticUsageStore(
            defaults: defaults,
            sources: sources(root),
            pricingCatalog: offlineCatalog(in: root),
            cacheURL: nil
        )

        // Both loads are still initial scans, so both report progress.
        store.start()
        let superseded = store.loadGeneration
        store.rescan()
        let current = store.loadGeneration
        #expect(current != superseded)
        #expect(store.phase == .scanning(scanned: 0, total: 0))

        // A late report from the cancelled load would otherwise move the bar.
        store.noteScanProgress(scanned: 3, total: 4, generation: superseded)
        #expect(store.phase == .scanning(scanned: 0, total: 0))

        store.noteScanProgress(scanned: 1, total: 4, generation: current)
        #expect(store.phase == .scanning(scanned: 1, total: 4))
        store.stop()
    }

    @Test("A superseded load cannot overwrite the newer load's state")
    @MainActor
    func supersededLoadIsIgnored() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("claude/a/one.jsonl")
        try write((1...20).map { Self.claude($0) }.joined(separator: "\n") + "\n", to: url)
        let suiteName = "AgenticUsageCancellationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AgenticUseRange.all.rawValue, forKey: "agenticUse.range")
        let store = AgenticUsageStore(
            defaults: defaults,
            sources: sources(root),
            pricingCatalog: offlineCatalog(in: root),
            cacheURL: nil
        )

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
        store.stop()
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
