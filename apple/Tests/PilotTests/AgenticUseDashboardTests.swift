import Foundation
import Testing
@testable import Pilot

@Suite("Agentic Use dashboard derivations")
struct AgenticUseDashboardTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    private func record(
        _ provider: AgenticProvider,
        _ model: String,
        daysAgo: Double,
        input: Int = 100,
        cacheWrite: Int = 0,
        cacheRead: Int = 1000,
        output: Int = 10,
        cost: Double? = nil
    ) -> AgenticUsageRecord {
        AgenticUsageRecord(
            provider: provider,
            dedupKey: nil,
            model: model,
            timestamp: now.addingTimeInterval(-daysAgo * 86_400 - 60),
            inputTokens: input,
            cacheWriteTokens: cacheWrite,
            cacheWrite1hTokens: 0,
            cacheReadTokens: cacheRead,
            outputTokens: output,
            thinkingTokens: nil,
            isFast: false,
            nativeCostUSD: cost
        )
    }

    private func snapshot(_ records: [AgenticUsageRecord], range: AgenticUseRange = .week) -> AgenticUseSnapshot {
        AgenticUsageStore.makeSnapshot(records: records, range: range, now: now, calendar: calendar)
    }

    // MARK: Store aggregation

    @Test("Provider series reconciles with totals and model token splits sum to tokens")
    func providerSeriesReconciles() {
        let snapshot = snapshot([
            record(.claude, "claude-opus-5-5", daysAgo: 1, cacheWrite: 50),
            record(.codex, "gpt-6.1-sol", daysAgo: 2),
            record(.claude, "claude-sonnet-5-5", daysAgo: 3, output: 40),
        ])
        #expect(abs(snapshot.providerSeries.reduce(0) { $0 + $1.cost } - snapshot.totalCostUSD) < 1e-9)
        #expect(snapshot.providerSeries.reduce(0) { $0 + $1.tokens } == snapshot.stats.processedTokens)
        #expect(Set(snapshot.providerSeries.map(\.provider)) == [.claude, .codex])
        // Zero-filled: every bucket carries every present provider.
        #expect(snapshot.providerSeries.count == snapshot.bucketTotals.count * 2)
        for total in snapshot.modelTotals {
            #expect(total.inputTokens + total.cacheWriteTokens + total.cacheReadTokens + total.outputTokens == total.tokens)
        }
        #expect(snapshot.modelTotals.first { $0.model == "gpt-6.1-sol" }?.provider == .codex)
        let savings = snapshot.bucketTotals.reduce(0) { $0 + $1.cacheSavings }
        #expect(abs(savings - snapshot.stats.cacheSavingsUSD) < 1e-9)
    }

    @Test("Previous window covers the equally long span before the range and excludes it")
    func previousWindow() throws {
        let snapshot = snapshot([
            record(.codex, "gpt-6.1-sol", daysAgo: 1, cost: 4),
            record(.codex, "gpt-6.1-sol", daysAgo: 9, cost: 10),
            record(.codex, "gpt-6.1-sol", daysAgo: 30, cost: 99),
        ])
        let previous = try #require(snapshot.previous)
        #expect(snapshot.totalCostUSD == 4)
        #expect(previous.totalCostUSD == 10)
        #expect(previous.dayCount == 7)
        #expect(snapshot.current?.dayCount == 7)
        #expect(abs((snapshot.current?.averageDailyCostUSD ?? 0) - 4.0 / 7) < 1e-9)
    }

    @Test("All-history range has no previous window")
    func allRangeHasNoPrevious() {
        let snapshot = snapshot([record(.claude, "claude-opus-5-5", daysAgo: 3)], range: .all)
        #expect(snapshot.previous == nil)
        #expect(AgenticUseRange.all.comparisonLabel == nil)
        #expect(snapshot.current?.dayCount == 4)
    }

    // MARK: Token flow

    @Test("Token flow conserves tokens and folds the long tail into Other models")
    func tokenFlowConservesTokens() {
        let models = (0..<10).map { index in
            AgenticModelTotal(
                model: "m\(index)", displayName: "M\(index)", cost: 1, tokens: 100 - index,
                costShare: 0.1, isUnpriced: false, provider: index.isMultiple(of: 2) ? .claude : .codex,
                inputTokens: 10, cacheWriteTokens: 0, cacheReadTokens: 80 - index, outputTokens: 10
            )
        }
        let graph = AgenticTokenFlowGraph.make(modelTotals: models, maxModels: 7)
        #expect(graph.models.count == 8)
        #expect(graph.models.last?.id == .otherModels)
        #expect(graph.otherModelNames == ["M7", "M8", "M9"])
        let total = models.reduce(0) { $0 + $1.tokens }
        #expect(graph.totalTokens == total)
        #expect(graph.tokenTypes.reduce(0) { $0 + $1.tokens } == total)
        for node in graph.providers {
            #expect(graph.links.filter { $0.source == node.id }.reduce(0) { $0 + $1.tokens } == node.tokens)
        }
        for node in graph.models {
            #expect(graph.links.filter { $0.target == node.id }.reduce(0) { $0 + $1.tokens } == node.tokens)
            #expect(graph.links.filter { $0.source == node.id }.reduce(0) { $0 + $1.tokens } == node.tokens)
        }
    }

    @Test("A single leftover model keeps its own node instead of an Other bucket")
    func tokenFlowNoSingleOther() {
        let models = (0..<8).map { index in
            AgenticModelTotal(
                model: "m\(index)", displayName: "M\(index)", cost: 0, tokens: 10, costShare: 0,
                isUnpriced: true, provider: .kimi, inputTokens: 10
            )
        }
        let graph = AgenticTokenFlowGraph.make(modelTotals: models, maxModels: 7)
        #expect(graph.models.count == 8)
        #expect(!graph.models.contains { $0.id == .otherModels })
    }

    // MARK: Insights

    @Test("Insights report cost change, a spike, and cache rate from real figures")
    func insights() throws {
        var records = (1...6).map { record(.codex, "gpt-6.1-sol", daysAgo: Double($0), cost: 1) }
        records.append(record(.claude, "claude-opus-5-5", daysAgo: 0, cost: 9))
        records.append(record(.codex, "gpt-6.1-sol", daysAgo: 10, cost: 30))
        let insights = AgenticUseInsights.make(from: snapshot(records), calendar: calendar)
        let spike = try #require(insights.first { $0.kind == .spike })
        #expect(spike.title == "Claude usage spike")
        #expect(spike.detail.contains("Opus 5.5"))
        let cost = try #require(insights.first { $0.kind == .costChange })
        #expect(cost.title == "Total cost down 50%")
        #expect(cost.tone == .positive)
        #expect(insights.contains { $0.kind == .cacheHitRate })
    }

    @Test("Without a previous window the cost insight names the leading model")
    func insightsWithoutPrevious() {
        let insights = AgenticUseInsights.make(
            from: snapshot([record(.claude, "claude-opus-5-5", daysAgo: 1, cost: 2)], range: .all),
            calendar: calendar
        )
        #expect(insights.contains { $0.kind == .topModel && $0.title == "Opus 5.5 leads cost" })
        #expect(!insights.contains { $0.kind == .spike })
    }

    // MARK: Formatting and sparklines

    @Test("Delta formatting and sparkline helpers")
    func formattingHelpers() {
        #expect(AgenticUseFormat.relativeChange(current: 72, previous: 100) == -0.28)
        #expect(AgenticUseFormat.relativeChange(current: 5, previous: 0) == nil)
        #expect(AgenticUseFormat.deltaPercent(-0.28) == "28%")
        #expect(AgenticUseFormat.deltaPercent(42) == ">999%")
        #expect(AgenticUseFormat.deltaPoints(0.031) == "3.1 pts")
        #expect(AgenticUseSparkline.binned([1, 2, 3, 4], limit: 2) == [1.5, 3.5])
        #expect(AgenticUseSparkline.binned([1, 2], limit: 5) == [1, 2])
        #expect(AgenticUseKPICards.movingAverage([2, 4, 6, 8], window: 2) == [2, 3, 5, 7])
    }
}
