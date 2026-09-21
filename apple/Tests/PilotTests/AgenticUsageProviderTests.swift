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

    @Test("Codex sessions without model context fall back to gpt-5")
    func codexFallbackModel() {
        let records = parse([codexTokenCount], provider: .codex)
        #expect(records.first?.model == "gpt-5")
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

    /// Codex models bill flat regardless of context size — the tiered
    /// long-context sheets belong to hosted variants, not the CLI's models.
    /// Verified against ccusage, which reproduces these rates to the cent.
    @Test("gpt-5.6-sol bills flat rates at any context size")
    func codexFlatPricing() throws {
        let small = record(model: "gpt-5.6-sol", input: 100_000, output: 1_000_000)
        let smallCost = try #require(AgenticUsagePricing.cost(of: small))
        #expect(abs(smallCost - (0.1 * 4.00 + 1.0 * 20.00)) < 1e-9)

        let large = record(model: "gpt-5.6-sol", input: 50_000, cacheRead: 250_000, output: 1_000_000)
        let largeCost = try #require(AgenticUsagePricing.cost(of: large))
        #expect(abs(largeCost - (0.05 * 4.00 + 0.25 * 0.40 + 1.0 * 20.00)) < 1e-9)
    }

    @Test("Cache reads default to 0.1x input unless overridden")
    func cacheReadRates() throws {
        let k3 = record(model: "k3", cacheRead: 1_000_000)
        #expect(try abs(#require(AgenticUsagePricing.cost(of: k3)) - 0.45) < 1e-9)
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
}
