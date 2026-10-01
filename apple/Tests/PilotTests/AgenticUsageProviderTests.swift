import Foundation
import Testing
@testable import Pilot

@Suite("Agentic usage providers")
struct AgenticUsageProviderTests {
    private func parse(_ lines: [String], provider: AgenticProvider) -> [AgenticUsageRecord] {
        AgenticUsageLoader.parse(
            data: Data((lines.joined(separator: "\n") + "\n").utf8),
            provider: provider
        )
    }

    // MARK: Claude

    @Test("Claude dedup keeps the copy with the final output count")
    func claudeDedupKeepsMaxOutput() {
        let streamStart = """
        {"type":"assistant","requestId":"req_1","timestamp":"2026-08-14T10:00:00.000Z","message":{"id":"msg_1","model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":1000,"output_tokens":4}}}
        """
        let final = """
        {"type":"assistant","requestId":"req_1","timestamp":"2026-08-14T10:00:05.000Z","message":{"id":"msg_1","model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":1000,"output_tokens":323}}}
        """
        let records = AgenticUsageLoader.deduplicate(
            parse([streamStart, final], provider: .claude)
        )
        #expect(records.count == 1)
        #expect(records.first?.outputTokens == 323)
        #expect(records.first?.provider == .claude)
    }

    @Test("Claude records missing ids never deduplicate")
    func claudeMissingIdsAlwaysKept() {
        let line = """
        {"type":"assistant","timestamp":"2026-08-14T10:00:00.000Z","message":{"model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":5}}}
        """
        let records = AgenticUsageLoader.deduplicate(parse([line, line], provider: .claude))
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.dedupKey == nil })
    }

    // MARK: Codex

    private let codexTurnContext = """
    {"timestamp":"2026-08-14T02:34:00.000Z","ordinal":7,"type":"turn_context","payload":{"turn_id":"t1","model":"gpt-5.6-sol"}}
    """
    private let codexTokenCount = """
    {"timestamp":"2026-08-14T02:34:35.653Z","ordinal":17,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":16433,"cached_input_tokens":11008,"cache_write_input_tokens":0,"output_tokens":219,"reasoning_output_tokens":71,"total_tokens":16652},"last_token_usage":{"input_tokens":16433,"cached_input_tokens":11008,"cache_write_input_tokens":0,"output_tokens":219,"reasoning_output_tokens":71,"total_tokens":16652}}}}
    """

    @Test("Codex token counts attribute to the current turn's model and split cached input")
    func codexParsesTokenCounts() throws {
        let records = parse([codexTurnContext, codexTokenCount], provider: .codex)
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.provider == .codex)
        #expect(record.model == "gpt-5.6-sol")
        #expect(record.inputTokens == 16433 - 11008)
        #expect(record.cacheReadTokens == 11008)
        #expect(record.outputTokens == 219)
        #expect(record.thinkingTokens == 71)
    }

    @Test("Codex sessions without model context preserve usage as unattributed")
    func codexFallbackModel() {
        let records = parse([codexTokenCount], provider: .codex)
        #expect(records.first?.model == "gpt-unknown")
        #expect(records.first.flatMap { AgenticUsagePricing.cost(of: $0) } == nil)
    }

    @Test("Codex token counts whose cumulative totals did not advance are repeats")
    func codexRepeatedTotalsSkipped() {
        // Codex re-emits token_count at turn boundaries with the previous
        // call's last_token_usage and unchanged totals — no API call happened.
        let repeat1 = codexTokenCount
            .replacingOccurrences(of: "\"ordinal\":17", with: "\"ordinal\":18")
            .replacingOccurrences(of: "02:34:35.653Z", with: "02:34:36.100Z")
        let secondCall = """
        {"timestamp":"2026-08-14T02:35:10.000Z","ordinal":25,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":36433,"cached_input_tokens":27008,"cache_write_input_tokens":0,"output_tokens":519,"reasoning_output_tokens":171,"total_tokens":36952},"last_token_usage":{"input_tokens":20000,"cached_input_tokens":16000,"cache_write_input_tokens":0,"output_tokens":300,"reasoning_output_tokens":100,"total_tokens":20300}}}}
        """
        let records = parse(
            [codexTurnContext, codexTokenCount, repeat1, secondCall],
            provider: .codex
        )
        #expect(records.count == 2)
        #expect(records.first?.outputTokens == 219)
        #expect(records.last?.inputTokens == 20000 - 16000)
        #expect(records.last?.cacheReadTokens == 16000)
        #expect(records.last?.outputTokens == 300)
    }

    @Test("Codex token counts without last usage bill the delta of the totals")
    func codexTotalsDeltaFallback() {
        let totalsOnly = """
        {"timestamp":"2026-08-14T02:35:10.000Z","ordinal":25,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":36433,"cached_input_tokens":27008,"cache_write_input_tokens":0,"output_tokens":519,"reasoning_output_tokens":171,"total_tokens":36952}}}}
        """
        let records = parse([codexTurnContext, codexTokenCount, totalsOnly], provider: .codex)
        #expect(records.count == 2)
        #expect(records.last?.inputTokens == (36433 - 16433) - (27008 - 11008))
        #expect(records.last?.cacheReadTokens == 27008 - 11008)
        #expect(records.last?.outputTokens == 519 - 219)
        #expect(records.last?.thinkingTokens == 171 - 71)
    }

    @Test("Codex resume replays dedup despite rewritten timestamps")
    func codexReplayDedup() {
        let replayed = codexTokenCount.replacingOccurrences(
            of: "2026-08-14T02:34:35.653Z",
            with: "2026-08-15T09:00:00.000Z"
        )
        let original = parse([codexTurnContext, codexTokenCount], provider: .codex)
        let replay = parse([codexTurnContext, replayed], provider: .codex)
        let records = AgenticUsageLoader.deduplicate(original + replay)
        #expect(records.count == 1)
    }

    // MARK: Grok

    @Test("Grok turns carry per-model usage and an exact native cost")
    func grokParsesTurnCompleted() throws {
        let line = """
        {"timestamp":1784526657,"method":"_x.ai/session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":30596,"outputTokens":3338,"totalTokens":33934,"cachedReadTokens":1024,"reasoningTokens":307,"costUsdTicks":794792000,"modelUsage":{"grok-4.5-build":{"inputTokens":30596,"outputTokens":3338,"totalTokens":33934,"cachedReadTokens":1024,"reasoningTokens":307,"costUsdTicks":794792000}}}}}}
        """
        let records = parse([line], provider: .grok)
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.model == "grok-4.5-build")
        #expect(record.inputTokens == 30596 - 1024)
        #expect(record.cacheReadTokens == 1024)
        #expect(record.outputTokens == 3338)
        let native = try #require(record.nativeCostUSD)
        #expect(abs(native - 0.0794792) < 1e-9)
        #expect(AgenticUsagePricing.cost(of: record) == record.nativeCostUSD)
        #expect(record.timestamp == Date(timeIntervalSince1970: 1_784_526_657))
    }

    // MARK: Kimi

    @Test("Kimi usage records strip the routing prefix and use epoch-ms timestamps")
    func kimiParsesUsageRecords() throws {
        let line = """
        {"type":"usage.record","model":"kimi-code/k3-max","usage":{"inputOther":11213,"output":275,"inputCacheRead":18944,"inputCacheCreation":0},"usageScope":"turn","time":1785821544387}
        """
        let records = parse([line], provider: .kimi)
        let record = try #require(records.first)
        #expect(record.model == "k3-max")
        #expect(record.inputTokens == 11213)
        #expect(record.cacheReadTokens == 18944)
        #expect(record.outputTokens == 275)
        #expect(abs(record.timestamp.timeIntervalSince1970 - 1_785_821_544.387) < 0.001)
        // k3-max has no published rate: it must surface as unpriced, not $0.
        #expect(AgenticUsagePricing.cost(of: record) == nil)
    }

    @Test("Kimi session-scoped usage records are cumulative totals, not calls")
    func kimiSkipsSessionScope() {
        let turn = """
        {"type":"usage.record","model":"kimi-code/k3","usage":{"inputOther":2134,"output":99,"inputCacheRead":18944,"inputCacheCreation":0},"usageScope":"turn","time":1786115071956}
        """
        let session = """
        {"type":"usage.record","agentId":"main","model":"kimi-code/k3","usage":{"inputOther":302420,"output":1259,"inputCacheRead":19456,"inputCacheCreation":0},"usageScope":"session","time":1787540236494}
        """
        let records = parse([turn, session], provider: .kimi)
        #expect(records.count == 1)
        #expect(records.first?.inputTokens == 2134)
    }

    // MARK: Pricing

    private func record(
        model: String,
        input: Int = 0,
        cacheRead: Int = 0,
        output: Int = 0
    ) -> AgenticUsageRecord {
        AgenticUsageRecord(
            provider: .codex,
            dedupKey: nil,
            model: model,
            timestamp: Date(timeIntervalSince1970: 1_776_000_000),
            inputTokens: input,
            cacheWriteTokens: 0,
            cacheWrite1hTokens: 0,
            cacheReadTokens: cacheRead,
            outputTokens: output,
            thinkingTokens: nil,
            isFast: false,
            nativeCostUSD: nil
        )
    }

    @Test("OpenAI long-context pricing starts strictly above 272K prompt tokens")
    func codexContextPricing() throws {
        let small = record(model: "gpt-5.6-sol", input: 22_000, cacheRead: 250_000, output: 1000)
        #expect(try abs(#require(AgenticUsagePricing.cost(of: small)) - 0.208) < 1e-9)
        let large = record(model: "gpt-5.6-sol", input: 22_001, cacheRead: 250_000, output: 1000)
        #expect(try abs(#require(AgenticUsagePricing.cost(of: large)) - 0.406008) < 1e-9)
    }

    @Test("Cache reads default to 0.1x input unless overridden")
    func cacheReadRates() throws {
        let k3 = record(model: "k3", cacheRead: 1_000_000)
        #expect(try abs(#require(AgenticUsagePricing.cost(of: k3)) - 0.30) < 1e-9)
        let gpt5 = record(model: "gpt-5", cacheRead: 1_000_000)
        #expect(try abs(#require(AgenticUsagePricing.cost(of: gpt5)) - 0.125) < 1e-9)
        // Fable 5.1 bills cache reads at 0.025x input, not the usual 0.1x.
        let fable51 = record(model: "claude-fable-5-1", cacheRead: 1_000_000)
        #expect(try abs(#require(AgenticUsagePricing.cost(of: fable51)) - 0.25) < 1e-9)
        let fable5 = record(model: "claude-fable-5", cacheRead: 1_000_000)
        #expect(try abs(#require(AgenticUsagePricing.cost(of: fable5)) - 1.00) < 1e-9)
    }

    @Test("Rates ccusage changed since the table was first verified")
    func recentRateChanges() throws {
        let sonnet = record(model: "claude-sonnet-5", input: 1_000_000, output: 1_000_000)
        #expect(try abs(#require(AgenticUsagePricing.cost(of: sonnet)) - (2.00 + 10.00)) < 1e-9)
        let kimiForCoding = record(model: "kimi-for-coding", input: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
        #expect(try abs(#require(AgenticUsagePricing.cost(of: kimiForCoding)) - (0.95 + 0.16 + 4.00)) < 1e-9)
        #expect(AgenticModel.displayName(for: "claude-fable-5-1") == "Fable 5.1")
    }

    // MARK: All-time range

    @Test("The All range clamps its presented interval to the oldest record")
    func allRangeClampsInterval() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let old = record(model: "gpt-5", input: 5, output: 5)
        let snapshot = AgenticUsageStore.makeSnapshot(
            records: [old],
            range: .all,
            now: now,
            calendar: calendar
        )
        #expect(snapshot.interval.start == calendar.startOfDay(for: old.timestamp))
        #expect(snapshot.interval.end == now)
        #expect(snapshot.modelTotals.count == 1)
    }
    @Test("Screenshot models all have published rates and reconcile across the dashboard")
    func screenshotModelCoverage() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let models = ["claude-opus-5-5", "gpt-6-astra", "gpt-6.1-sol", "grok-4.7-build", "k3"]
        let records = models.map { record(model: $0, input: 100, cacheRead: 1000, output: 10) }
        let snapshot = AgenticUsageStore.makeSnapshot(
            records: records, range: .all, now: records[0].timestamp.addingTimeInterval(3600), calendar: calendar
        )
        #expect(!snapshot.hasUnpricedModels)
        #expect(snapshot.unpricedTokens == 0)
        #expect(snapshot.stats.processedTokens == 5550)
        #expect(abs(snapshot.modelTotals.reduce(0) { $0 + $1.cost } - snapshot.totalCostUSD) < 1e-9)
        #expect(abs(snapshot.dailySeries.reduce(0) { $0 + $1.cost } - snapshot.totalCostUSD) < 1e-9)
        #expect(snapshot.dailySeries.reduce(0) { $0 + $1.tokens } == snapshot.stats.processedTokens)
        #expect(abs(snapshot.dayTotals.reduce(0) { $0 + $1.cost } - snapshot.totalCostUSD) < 1e-9)
    }

    @Test("Opus 5.5 fast calls preserve its five-percent cache-read rate")
    func opusFastCachePricing() throws {
        var fast = record(model: "claude-opus-5-5", cacheRead: 1_000_000)
        fast.serviceTier = "fast"
        #expect(try abs(#require(AgenticUsagePricing.cost(of: fast)) - 0.4) < 1e-9)
        fast.inferenceGeo = "us"
        #expect(try abs(#require(AgenticUsagePricing.cost(of: fast)) - 0.44) < 1e-9)
    }

    @Test("K3 cache writes use their published rate rather than Claude's multiplier")
    func kimiCacheWrites() throws {
        let records = parse([
            """
            {"type":"usage.record","model":"kimi-code/k3","usage":{"inputOther":0,"output":0,"inputCacheRead":0,"inputCacheCreation":1000000},"usageScope":"turn","time":1786115071956}
            """
        ], provider: .kimi)
        let record = try #require(records.first)
        let cost = try #require(AgenticUsagePricing.cost(of: record))
        #expect(abs(cost - 3) < 1e-9)
    }

    @Test("Native-cost models without baselines do not subtract from cache savings")
    func savingsOnlyCompareMatchingRecords() {
        var native = record(model: "unlisted-grok-model", input: 100)
        native = AgenticUsageRecord(
            provider: .grok, dedupKey: nil, model: native.model, timestamp: native.timestamp,
            inputTokens: 100, cacheWriteTokens: 0, cacheWrite1hTokens: 0, cacheReadTokens: 0,
            outputTokens: 0, thinkingTokens: nil, isFast: false, nativeCostUSD: 100
        )
        let cached = record(model: "gpt-6.1-sol", cacheRead: 1000)
        let snapshot = AgenticUsageStore.makeSnapshot(
            records: [cached, native], range: .all,
            now: cached.timestamp.addingTimeInterval(1), calendar: Calendar(identifier: .gregorian)
        )
        #expect(abs(snapshot.stats.cacheSavingsUSD - 0.0019) < 1e-9)
        #expect(snapshot.totalCostUSD > 100)
    }

    @Test("Current Codex response records and legacy notifications count each call once")
    func codexResponseUsage() throws {
        let response = """
        {"type":"token_usage_record","timestamp":"2026-08-14T02:34:35.653Z","payload":{"thread_id":"thread-a","response_id":"response-a","usage":{"input_tokens":16433,"cached_input_tokens":11008,"cache_write_input_tokens":1000,"output_tokens":219,"reasoning_output_tokens":71},"thread_token_usage":{"input_tokens":16433,"cached_input_tokens":11008,"cache_write_input_tokens":1000,"output_tokens":219,"reasoning_output_tokens":71}}}
        """
        let notification = codexTokenCount.replacingOccurrences(of: "\"cache_write_input_tokens\":0", with: "\"cache_write_input_tokens\":1000")
        let records = parse([codexTurnContext, response, notification], provider: .codex)
        let first = try #require(records.first)
        #expect(records.count == 1)
        #expect(first.inputTokens == 4425)
        #expect(first.cacheWriteTokens == 1000)
        #expect(first.totalTokens == 16652)
        let other = parse([codexTurnContext, response.replacingOccurrences(of: "thread-a", with: "thread-b")], provider: .codex)
        #expect(AgenticUsageLoader.deduplicate(records + records + other).count == 2)
    }

    @Test("Response-only Codex logs remain billable without notifications")
    func codexResponseOnly() {
        let line = """
        {"type":"token_usage_record","timestamp":"2026-08-14T02:34:35.653Z","payload":{"model":"gpt-6.1-sol","response_id":"r1","usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10}}}
        """
        let records = parse([line], provider: .codex)
        #expect(records.count == 1)
        #expect(records.first?.model == "gpt-6.1-sol")
        #expect(records.first?.inputTokens == 80)
    }

    @Test("Overlapping scan roots do not duplicate append-only Kimi logs")
    func overlappingSources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let line = """
        {"type":"usage.record","model":"kimi-code/k3","usage":{"inputOther":1,"output":2},"usageScope":"turn","time":1786115071956}
        """
        try Data(line.utf8).write(to: root.appendingPathComponent("wire.jsonl"))
        let source = AgenticUsageLoader.Source(provider: .kimi, rootDirectory: root, fileName: "wire.jsonl")
        let result = try await AgenticUsageLoader(sources: [source, source]).load()
        #expect(result.fileCount == 1)
        #expect(result.records.count == 1)
    }

    @Test("Catalog imports future models with their explicit context thresholds")
    func catalogThresholdsAndValidation() throws {
        let data = Data("""
        {"openai":{"models":{
          "gpt-future":{"cost":{"input":2,"output":10,"cache_read":0.1,"tiers":[{"input":4,"output":15,"cache_read":0.2,"tier":{"type":"context","size":272000}}],"context_over_200k":{"input":99,"output":99}}},
          "gpt-6.1-sol":{"last_updated":"2026-09-29","cost":{"input":99,"output":99}},
          "gpt-bad":{"cost":{"input":true,"output":10}},
          "gpt-free":{"cost":{"input":0,"output":0}}
        }}}
        """.utf8)
        let rates = try AgenticPricingCatalog.decode(data)
        #expect(rates["gpt-bad"] == nil)
        #expect(rates["gpt-free"] == nil)
        #expect(rates["gpt-6.1-sol"] == nil)
        #expect(rates["gpt-future"]?.contextTiers.first?.threshold == 272_000)
        let small = record(model: "gpt-future", input: 210_000, output: 1000)
        let large = record(model: "gpt-future", input: 300_000, output: 1000)
        #expect(try abs(#require(AgenticUsagePricing.cost(of: small, rates: rates)) - 0.43) < 1e-9)
        #expect(try abs(#require(AgenticUsagePricing.cost(of: large, rates: rates)) - 1.215) < 1e-9)
    }

    @Test("A saved pricing catalog remains usable when the network fails")
    func catalogOfflineCache() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let catalog = AgenticPricingCatalog(cacheURL: url, fetch: {
            Data("""
            {"openai":{"models":{"gpt-future":{"cost":{"input":2,"output":10,"cache_read":0.1}}}}}
            """.utf8)
        })
        let first = await catalog.load(now: Date(timeIntervalSince1970: 1000))
        #expect(first.warning == nil)
        #expect(first.rates["gpt-future"] != nil)
        let offline = AgenticPricingCatalog(cacheURL: url, fetch: { throw URLError(.notConnectedToInternet) })
        let result = await offline.load(force: true, now: Date(timeIntervalSince1970: 100_000))
        #expect(result.warning != nil)
        #expect(result.rates["gpt-future"] == first.rates["gpt-future"])
        #expect(result.rates["claude-opus-5-5"] != nil)
    }

    @Test("Files beyond the former 512MB limit retain usage after oversized lines")
    func streamsLargeFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("large.jsonl")
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        let prefixSize: UInt64 = 513 * 1024 * 1024
        // A sparse oversized non-usage line avoids allocating a huge fixture.
        try handle.truncate(atOffset: prefixSize)
        try handle.seek(toOffset: prefixSize)
        try handle.write(contentsOf: Data(("\n" + codexTurnContext + "\n" + codexTokenCount).utf8))
        try handle.close()
        let source = AgenticUsageLoader.Source(provider: .codex, rootDirectory: root)
        let loader = AgenticUsageLoader(sources: [source])
        let result = try await loader.load()
        #expect(result.unreadableFileCount == 0)
        #expect(result.skippedLineCount == 1)
        #expect(result.records.count == 1)
        #expect(result.records.first?.outputTokens == 219)
        let cached = try await loader.load()
        #expect(cached.skippedLineCount == 1)
        #expect(cached.records == result.records)
    }

    @Test("Grok context pricing includes the 200K boundary and preserves older cache rates")
    func grokContextBoundary() throws {
        let small = record(model: "grok-4.7", input: 199_999, output: 1000)
        let boundary = record(model: "grok-4.7", input: 200_000, output: 1000)
        #expect(try abs(#require(AgenticUsagePricing.cost(of: small)) - 0.405998) < 1e-9)
        #expect(try abs(#require(AgenticUsagePricing.cost(of: boundary)) - 0.812) < 1e-9)
        let older = record(model: "grok-4.5", cacheRead: 100_000)
        #expect(try abs(#require(AgenticUsagePricing.cost(of: older)) - 0.03) < 1e-9)
    }

    @Test("Oversized compaction histories do not produce false usage-gap warnings")
    func oversizedHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.jsonl")
        var data = Data("{\"type\":\"compacted\",\"payload\":{\"history\":\"".utf8)
        data.append(Data(repeating: 0x61, count: 17 * 1024 * 1024))
        data.append(Data(("\"}}\n" + codexTurnContext + "\n" + codexTokenCount).utf8))
        try data.write(to: url)
        let result = try await AgenticUsageLoader(sources: [.init(provider: .codex, rootDirectory: root)]).load()
        #expect(result.skippedLineCount == 0)
        #expect(result.records.count == 1)
    }

    @Test("Provider date-stamped model identifiers resolve to the same published rate")
    func datedModelIdentifiers() {
        #expect(AgenticModel.canonicalize("gpt-6.1-sol-2026-09-29") == "gpt-6.1-sol")
        #expect(AgenticModel.canonicalize("claude-haiku-4-5-20251001") == "claude-haiku-4-5")
    }

}
