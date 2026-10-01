import Foundation
import Observation

// MARK: - Range

/// The dashboard's date-range picker options.
enum AgenticUseRange: String, CaseIterable, Sendable, Identifiable {
    case day
    case week
    case month
    case quarter
    case all

    var id: String { rawValue }

    /// Segmented-control label.
    var label: String {
        switch self {
        case .day: "24h"
        case .week: "7d"
        case .month: "30d"
        case .quarter: "90d"
        case .all: "All"
        }
    }

    /// Whole local days covered by the window. For `.all` this is only a
    /// capacity hint; the real span comes from the oldest record.
    var dayCount: Int {
        switch self {
        case .day: 1
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .all: 366
        }
    }

    /// Chart bucket granularity: hours for the 24h window, days otherwise.
    /// Pass this to `AreaMark(x: .value(_, point.day, unit:))`.
    var bucketUnit: Calendar.Component {
        self == .day ? .hour : .day
    }

    /// The filter window: exactly the trailing 24 hours, N whole local days
    /// ending now, or everything. Records are UTC; bucketing and filtering
    /// both use the supplied (local) calendar so day edges agree everywhere.
    func interval(endingAt now: Date, calendar: Calendar) -> DateInterval {
        switch self {
        case .day:
            return DateInterval(start: now.addingTimeInterval(-24 * 60 * 60), end: now)
        case .week, .month, .quarter:
            let today = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today) ?? today
            return DateInterval(start: start, end: now)
        case .all:
            return DateInterval(start: .distantPast, end: now)
        }
    }
}

// MARK: - Aggregates

/// One model's totals for the selected range — the hero breakdown list and
/// the Breakdown table's MODEL mode.
struct AgenticModelTotal: Sendable, Identifiable, Equatable {
    /// Canonical model id — the palette/legend key.
    let model: String
    /// "Opus 5", "Fable 5", …
    let displayName: String
    /// USD. Zero when `isUnpriced`.
    let cost: Double
    /// Processed tokens (input + cache write + cache read + output).
    let tokens: Int
    /// 0...1 fraction of the range's total cost.
    let costShare: Double
    /// True when the model has no pricing table entry; render the badge, do
    /// not present the zero cost as real.
    let isUnpriced: Bool

    var id: String { model }
}

/// One chart bucket for one model. Day granularity (hour for the 24h range),
/// zero-filled across the window so stacked areas don't interpolate gaps.
struct AgenticDailyPoint: Sendable, Identifiable, Equatable {
    /// Bucket start (local midnight, or top of the hour for 24h).
    let day: Date
    /// Canonical model id.
    let model: String
    let displayName: String
    let cost: Double
    let tokens: Int

    var id: String { "\(model)|\(day.timeIntervalSinceReferenceDate)" }
}

/// One calendar day's totals — the Breakdown table's DAY mode, newest first.
struct AgenticDayTotal: Sendable, Identifiable, Equatable {
    let day: Date
    let cost: Double
    let costShare: Double
    let tokens: Int

    var id: Date { day }
}

/// The five headline stats, pre-summed for the stat row.
struct AgenticUseStats: Sendable, Equatable {
    /// input + cache write + cache read + output.
    let processedTokens: Int
    let activeDays: Int
    /// processedTokens / activeDays (0 when no active days).
    let processedPerActiveDay: Int
    /// Cache-read tokens.
    let cachedInputTokens: Int
    /// cacheRead / (input + cacheWrite + cacheRead); 0 when nothing observed.
    let cachedInputShare: Double
    /// Plain input tokens.
    let uncachedInputTokens: Int
    /// Cache-write tokens (the "N cache writes" caption).
    let cacheWriteTokens: Int
    let outputTokens: Int
    /// Reported reasoning tokens. Only recent Claude Code versions log
    /// `thinking_tokens` (~7% of records), so this is a lower bound — and
    /// `nil` when no record in range reported it. Never extrapolated.
    let reasoningTokens: Int?
    /// Hypothetical full-rate cost minus actual cost, priced models only.
    let cacheSavingsUSD: Double
    /// cacheSavingsUSD / total cost; `nil` when total cost is zero.
    let cacheSavingsMultiple: Double?
}

/// Everything the dashboard renders for one (records, range) pair.
struct AgenticUseSnapshot: Sendable, Equatable {
    let range: AgenticUseRange
    /// The filtered window — drives the header's "Jul 11 – Aug 9" subtitle.
    let interval: DateInterval
    /// Actual cost of the range, USD (the hero number).
    let totalCostUSD: Double
    /// Sorted by cost descending (display order for lists).
    let modelTotals: [AgenticModelTotal]
    /// Canonical models present, in fixed presentation order — build the
    /// chart's color-scale domain and stacking order from this.
    let modelOrder: [String]
    /// Display names matching `modelOrder` index-for-index.
    let modelDisplayNames: [String]
    /// Zero-filled chart series: every bucket in the window x every model in
    /// `modelOrder`, sorted by bucket then presentation order.
    let dailySeries: [AgenticDailyPoint]
    /// Newest first.
    let dayTotals: [AgenticDayTotal]
    let stats: AgenticUseStats
    /// True when any model in range is missing from the pricing table.
    let hasUnpricedModels: Bool
    var unpricedTokens: Int = 0

    /// No records landed inside the selected range (the corpus itself may
    /// still have data — offer a wider range).
    var isEmpty: Bool { modelTotals.isEmpty }
}

// MARK: - Store

/// Live state behind the Agentic Use section.
///
/// Owns one `AgenticUsageLoader`, keeps the deduplicated record array in
/// memory, and re-aggregates it into an `AgenticUseSnapshot` whenever the
/// range changes. All parsing and aggregation happens off the main actor;
/// only published results land here.
@Observable
@MainActor
final class AgenticUsageStore {
    enum Phase: Equatable {
        case idle
        /// Initial full scan, with determinate progress.
        case scanning(scanned: Int, total: Int)
        /// Records loaded; `snapshot` is being kept in sync with `range`.
        case loaded
        /// The transcript tree exists but produced zero usage records (or
        /// does not exist at all).
        case empty
        /// The transcript directory could not be read.
        case failed(reason: String)
    }

    private(set) var phase: Phase = .idle
    /// The aggregates for the current range. `nil` until first load.
    private(set) var snapshot: AgenticUseSnapshot?
    /// A non-initial reload is in flight (header spinner, not the scan view).
    private(set) var isRefreshing = false
    /// Non-fatal problem from the last load (e.g. skipped unreadable files).
    private(set) var scanWarning: String?

    var range: AgenticUseRange {
        didSet {
            guard range != oldValue else { return }
            defaults.set(range.rawValue, forKey: Self.rangeKey)
            recompute()
        }
    }

    /// 0...1 while `.scanning` with a known total, else `nil`.
    var scanProgress: Double? {
        guard case .scanning(let scanned, let total) = phase, total > 0 else { return nil }
        return Double(scanned) / Double(total)
    }

    private let loader: AgenticUsageLoader
    private let pricingCatalog: AgenticPricingCatalog
    private var pricingRates = AgenticUsagePricing.rates
    private(set) var pricingFetchedAt: Date?
    private var refreshTask: Task<Void, Never>?

    var pricingStatus: String {
        if let pricingFetchedAt {
            return "Pricing updated " + pricingFetchedAt.formatted(date: .abbreviated, time: .shortened)
        }
        return "Bundled pricing · " + AgenticUsagePricing.reviewedDate
    }
    private let defaults: UserDefaults
    private var records: [AgenticUsageRecord] = []
    private var loadTask: Task<Void, Never>?
    private var aggregateTask: Task<Void, Never>?
    private var hasLoadedOnce = false
    private var isRunning = false

    private static let rangeKey = "agenticUse.range"

    init(
        defaults: UserDefaults = .standard,
        sources: [AgenticUsageLoader.Source]? = nil,
        pricingCatalog: AgenticPricingCatalog = AgenticPricingCatalog()
    ) {
        self.defaults = defaults
        self.pricingCatalog = pricingCatalog
        self.loader = AgenticUsageLoader(
            sources: sources ?? AgenticUsageLoader.defaultSources()
        )
        self.range = defaults.string(forKey: Self.rangeKey)
            .flatMap(AgenticUseRange.init(rawValue:)) ?? .month
    }

    // MARK: Lifecycle

    /// Begin (or resume) loading. Idempotent — the view calls this every time
    /// the section appears. The first call runs the full scan; later calls
    /// refresh incrementally off the loader's file cache.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        load(initial: !hasLoadedOnce)
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self, isRunning else { return }
                if !isRefreshing, phase != .idle, hasLoadedOnce { load(initial: false) }
            }
        }
    }

    /// Cancel all work. Leaving the section leaves nothing running.
    func stop() {
        isRunning = false
        loadTask?.cancel()
        loadTask = nil
        aggregateTask?.cancel()
        aggregateTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
        if case .scanning = phase, !hasLoadedOnce {
            phase = .idle
        }
    }

    /// Manual refresh / the Retry and Rescan buttons.
    func rescan() {
        if !isRunning { start() }
        load(initial: !hasLoadedOnce, forcePricing: true)
    }

    func dismissScanWarning() {
        scanWarning = nil
    }

    // MARK: Loading

    private func load(initial: Bool, forcePricing: Bool = false) {
        loadTask?.cancel()
        if initial {
            phase = .scanning(scanned: 0, total: 0)
        } else {
            isRefreshing = true
        }
        loadTask = Task { [weak self, loader, pricingCatalog] in
            do {
                async let pricing = pricingCatalog.load(force: forcePricing)
                let result = try await loader.load { [weak self] scanned, total in
                    guard initial, let store = self else { return }
                    Task { @MainActor in
                        store.noteScanProgress(scanned: scanned, total: total)
                    }
                }
                let refreshedPricing = await pricing
                guard let self, !Task.isCancelled else { return }
                pricingRates = refreshedPricing.rates
                pricingFetchedAt = refreshedPricing.fetchedAt
                apply(result, pricingWarning: refreshedPricing.warning)
            } catch is CancellationError {
                // Whoever cancelled owns the state transition.
            } catch {
                guard let self, !Task.isCancelled else { return }
                isRefreshing = false
                if records.isEmpty {
                    phase = .failed(reason: error.localizedDescription)
                } else {
                    // Keep showing stale data; surface the problem softly.
                    scanWarning = error.localizedDescription
                }
            }
        }
    }

    /// Progress lands here from the loader's executor via a hop; loads report
    /// out of order under parallelism, so only monotonic updates apply.
    private func noteScanProgress(scanned: Int, total: Int) {
        guard case .scanning(let current, _) = phase, scanned >= current else { return }
        phase = .scanning(scanned: scanned, total: total)
    }

    private func apply(_ result: AgenticUsageLoader.LoadResult, pricingWarning: String?) {
        hasLoadedOnce = true
        isRefreshing = false
        records = result.records
        var warnings: [String] = []
        if result.unreadableFileCount > 0 {
            let plural = result.unreadableFileCount == 1 ? "" : "s"
            warnings.append("Skipped \(result.unreadableFileCount) unreadable log file\(plural).")
        }
        if result.skippedLineCount > 0 {
            warnings.append("Skipped \(result.skippedLineCount) oversized log lines; usage may be incomplete.")
        }
        if let pricingWarning { warnings.append(pricingWarning) }
        scanWarning = warnings.isEmpty ? nil : warnings.joined(separator: " ")
        if records.isEmpty {
            snapshot = nil
            phase = .empty
        } else {
            phase = .loaded
            recompute()
        }
    }

    // MARK: Aggregation

    /// Recompute the snapshot for the current range off the main actor.
    /// 60K+ records reduce in a few milliseconds, but not milliseconds the
    /// main thread needs to spend.
    private func recompute() {
        aggregateTask?.cancel()
        guard !records.isEmpty else { return }
        let records = records
        let range = range
        let rates = pricingRates
        aggregateTask = Task.detached(priority: .userInitiated) { [records, range, rates, weak self] in
            let snapshot = AgenticUsageStore.makeSnapshot(
                records: records,
                range: range,
                now: Date(),
                calendar: Calendar.current,
                rates: rates
            )
            guard !Task.isCancelled else { return }
            await self?.publish(snapshot)
        }
    }

    private func publish(_ snapshot: AgenticUseSnapshot) {
        guard !Task.isCancelled else { return }
        self.snapshot = snapshot
    }

    /// Pure aggregation: deduplicated records + range -> everything the UI
    /// draws. Nonisolated so it can run on a background task; also the seam
    /// unit tests use.
    nonisolated static func makeSnapshot(
        records: [AgenticUsageRecord],
        range: AgenticUseRange,
        now: Date,
        calendar: Calendar,
        rates: [String: AgenticModelRate] = AgenticUsagePricing.rates
    ) -> AgenticUseSnapshot {
        var interval = range.interval(endingAt: now, calendar: calendar)
        let filtered = records.filter {
            $0.timestamp >= interval.start && $0.timestamp <= interval.end
        }
        // "All" is unbounded for filtering; clamp the presented window (the
        // header subtitle and the chart's zero-fill span) to the oldest
        // record. `records` arrive sorted ascending, so first is oldest.
        if range == .all, let first = filtered.first {
            interval = DateInterval(start: calendar.startOfDay(for: first.timestamp), end: interval.end)
        }

        struct ModelBucket {
            var cost = 0.0
            var tokens = 0
            var isUnpriced = false
        }

        var byModel: [String: ModelBucket] = [:]
        var byChartBucket: [Date: [String: (cost: Double, tokens: Int)]] = [:]
        var byDay: [Date: (cost: Double, tokens: Int)] = [:]
        var activeDays: Set<Date> = []
        var inputTokens = 0
        var cacheWriteTokens = 0
        var cacheReadTokens = 0
        var outputTokens = 0
        var reasoningTokens = 0
        var hasReasoning = false
        var totalCost = 0.0
        var fullRateCost = 0.0
        var baselineCost = 0.0
        var unpricedTokens = 0

        for record in filtered {
            let cost = AgenticUsagePricing.cost(of: record, rates: rates)
            let tokens = record.totalTokens

            var model = byModel[record.model, default: ModelBucket()]
            if let cost {
                model.cost += cost
                totalCost += cost
                if let baseline = AgenticUsagePricing.fullRateCost(of: record, rates: rates) {
                    fullRateCost += baseline
                    baselineCost += cost
                }
            } else {
                model.isUnpriced = true
                unpricedTokens += tokens
            }
            model.tokens += tokens
            byModel[record.model] = model

            let day = calendar.startOfDay(for: record.timestamp)
            activeDays.insert(day)
            let chartBucket: Date
            if range.bucketUnit == .day {
                chartBucket = day
            } else {
                chartBucket = calendar.dateInterval(of: .hour, for: record.timestamp)?.start
                    ?? record.timestamp
            }
            var models = byChartBucket[chartBucket, default: [:]]
            var cell = models[record.model, default: (0, 0)]
            cell.cost += cost ?? 0
            cell.tokens += tokens
            models[record.model] = cell
            byChartBucket[chartBucket] = models

            var dayCell = byDay[day, default: (0, 0)]
            dayCell.cost += cost ?? 0
            dayCell.tokens += tokens
            byDay[day] = dayCell

            inputTokens += record.inputTokens
            cacheWriteTokens += record.cacheWriteTokens
            cacheReadTokens += record.cacheReadTokens
            outputTokens += record.outputTokens
            if let thinking = record.thinkingTokens {
                reasoningTokens += thinking
                hasReasoning = true
            }
        }

        let modelOrder = byModel.keys.sorted { lhs, rhs in
            let lhsIndex = AgenticModel.orderIndex(for: lhs)
            let rhsIndex = AgenticModel.orderIndex(for: rhs)
            return lhsIndex == rhsIndex ? lhs < rhs : lhsIndex < rhsIndex
        }
        let displayNames = modelOrder.map(AgenticModel.displayName(for:))

        let modelTotals = byModel
            .map { model, bucket in
                AgenticModelTotal(
                    model: model,
                    displayName: AgenticModel.displayName(for: model),
                    cost: bucket.cost,
                    tokens: bucket.tokens,
                    costShare: totalCost > 0 ? bucket.cost / totalCost : 0,
                    isUnpriced: bucket.isUnpriced
                )
            }
            .sorted { lhs, rhs in
                lhs.cost == rhs.cost ? lhs.tokens > rhs.tokens : lhs.cost > rhs.cost
            }

        // Zero-fill every bucket in the window for every model present so the
        // stacked area chart never interpolates across silent days.
        var series: [AgenticDailyPoint] = []
        if !filtered.isEmpty {
            var bucket: Date
            if range.bucketUnit == .day {
                bucket = calendar.startOfDay(for: interval.start)
            } else {
                bucket = calendar.dateInterval(of: .hour, for: interval.start)?.start
                    ?? interval.start
            }
            series.reserveCapacity(modelOrder.count * (range.dayCount == 1 ? 26 : range.dayCount + 1))
            let stepLimit = range == .all ? 2000 : 400
            var steps = 0
            while bucket <= interval.end, steps < stepLimit {
                let models = byChartBucket[bucket] ?? [:]
                for (index, model) in modelOrder.enumerated() {
                    let cell = models[model] ?? (0, 0)
                    series.append(
                        AgenticDailyPoint(
                            day: bucket,
                            model: model,
                            displayName: displayNames[index],
                            cost: cell.cost,
                            tokens: cell.tokens
                        )
                    )
                }
                guard let next = calendar.date(byAdding: range.bucketUnit, value: 1, to: bucket) else { break }
                bucket = next
                steps += 1
            }
        }

        let dayTotals = byDay
            .map { day, cell in
                AgenticDayTotal(
                    day: day,
                    cost: cell.cost,
                    costShare: totalCost > 0 ? cell.cost / totalCost : 0,
                    tokens: cell.tokens
                )
            }
            .sorted { $0.day > $1.day }

        let processed = inputTokens + cacheWriteTokens + cacheReadTokens + outputTokens
        let observedInput = inputTokens + cacheWriteTokens + cacheReadTokens
        let savings = max(0, fullRateCost - baselineCost)
        let stats = AgenticUseStats(
            processedTokens: processed,
            activeDays: activeDays.count,
            processedPerActiveDay: activeDays.isEmpty ? 0 : processed / activeDays.count,
            cachedInputTokens: cacheReadTokens,
            cachedInputShare: observedInput > 0 ? Double(cacheReadTokens) / Double(observedInput) : 0,
            uncachedInputTokens: inputTokens,
            cacheWriteTokens: cacheWriteTokens,
            outputTokens: outputTokens,
            reasoningTokens: hasReasoning ? reasoningTokens : nil,
            cacheSavingsUSD: savings,
            cacheSavingsMultiple: baselineCost > 0 ? savings / baselineCost : nil
        )

        return AgenticUseSnapshot(
            range: range,
            interval: interval,
            totalCostUSD: totalCost,
            modelTotals: modelTotals,
            modelOrder: modelOrder,
            modelDisplayNames: displayNames,
            dailySeries: series,
            dayTotals: dayTotals,
            stats: stats,
            hasUnpricedModels: modelTotals.contains(where: \.isUnpriced),
            unpricedTokens: unpricedTokens
        )
    }
}
