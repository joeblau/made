import AppKit
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

    /// The comparison window named in KPI captions ("vs previous 30d");
    /// `nil` for `.all`, which has no earlier period to compare against.
    var comparisonLabel: String? {
        self == .all ? nil : "vs previous \(label)"
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

    /// Calendar days a presented window spans: 1 for 24h, the fixed count
    /// for 7/30/90 days, and oldest-record-day through today for All.
    func windowDayCount(of interval: DateInterval, calendar: Calendar) -> Int {
        switch self {
        case .day: return 1
        case .week, .month, .quarter: return dayCount
        case .all:
            let first = calendar.startOfDay(for: interval.start)
            let last = calendar.startOfDay(for: interval.end)
            return (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1
        }
    }

    /// The equally long window immediately before `interval(endingAt:)`, used
    /// for the KPI deltas. `nil` for `.all`.
    func previousInterval(endingAt now: Date, calendar: Calendar) -> DateInterval? {
        let current = interval(endingAt: now, calendar: calendar)
        switch self {
        case .day:
            return DateInterval(start: current.start.addingTimeInterval(-24 * 60 * 60), end: current.start)
        case .week, .month, .quarter:
            guard let start = calendar.date(byAdding: .day, value: -dayCount, to: current.start) else {
                return nil
            }
            return DateInterval(start: start, end: current.start)
        case .all:
            return nil
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
    /// The CLI or editor that logged the model's calls.
    let provider: AgenticProvider
    /// Token-type split for the token-flow diagram; sums to `tokens`.
    var inputTokens = 0
    var cacheWriteTokens = 0
    var cacheReadTokens = 0
    var outputTokens = 0

    var id: String { model }

    /// USD per million processed tokens; `nil` when unpriced or empty.
    var costPerMillionTokens: Double? {
        guard !isUnpriced, tokens > 0 else { return nil }
        return cost / Double(tokens) * 1_000_000
    }
}

/// One chart bucket for one provider, zero-filled like `AgenticDailyPoint`.
/// Drives the provider-stacked chart and the KPI sparklines.
struct AgenticProviderPoint: Sendable, Identifiable, Equatable {
    /// Bucket start (local midnight, or top of the hour for 24h).
    let day: Date
    let provider: AgenticProvider
    let cost: Double
    let tokens: Int
    /// Full-rate minus actual cost for priced records in the bucket.
    let cacheSavings: Double
    let cacheReadTokens: Int
    let observedInputTokens: Int

    var id: String { "\(provider.rawValue)|\(day.timeIntervalSinceReferenceDate)" }
}

/// Headline totals for one window. The selected range and the equally long
/// window before it both reduce to this so KPI deltas compare like for like.
struct AgenticUsePeriodSummary: Sendable, Equatable {
    let totalCostUSD: Double
    let processedTokens: Int
    /// cacheRead / observed input; 0 when nothing observed.
    let cachedInputShare: Double
    let cacheSavingsUSD: Double
    /// Calendar days the window spans (1 for the 24h range).
    let dayCount: Int

    var averageDailyCostUSD: Double {
        dayCount > 0 ? totalCostUSD / Double(dayCount) : 0
    }

    /// No tokens at all — a delta against this would be meaningless.
    var isEmpty: Bool { processedTokens == 0 }
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

struct AgenticProviderTotal: Sendable, Equatable {
    let provider: AgenticProvider
    let estimatedCost: Double
    let totalTokens: Int
}

/// Everything the dashboard renders for one (records, range) pair.
struct AgenticUseSnapshot: Sendable, Equatable {
    let range: AgenticUseRange
    /// The filtered window — drives the header's "Jul 11 – Aug 9" subtitle.
    let interval: DateInterval
    /// Actual cost of the range, USD (the hero number).
    let totalCostUSD: Double
    let providerTotals: [AgenticProviderTotal]
    /// Zero-filled provider series: every bucket x every provider present,
    /// sorted by bucket then `AgenticProvider.allCases` order.
    var providerSeries: [AgenticProviderPoint] = []
    /// The selected window's headline totals.
    var current: AgenticUsePeriodSummary?
    /// The equally long window before it; `nil` for `.all`.
    var previous: AgenticUsePeriodSummary?
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
    /// Informational freshness for cached Cursor history, separate from errors.
    private(set) var cursorLastUpdated: Date?
    private(set) var lastUpdatedAt: Date?

    var range: AgenticUseRange {
        didSet {
            guard range != oldValue else { return }
            defaults.set(range.rawValue, forKey: Self.rangeKey)
            recompute()
            if isRunning { load(initial: !hasLoadedOnce) }
        }
    }

    /// 0...1 while `.scanning` with a known total, else `nil`.
    var scanProgress: Double? {
        guard case .scanning(let scanned, let total) = phase, total > 0 else { return nil }
        return Double(scanned) / Double(total)
    }

    private let loader: AgenticUsageLoader
    private let pricingCatalog: AgenticPricingCatalog
    private let cursorHistory: CursorUsageHistory
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
    /// Identifies the newest load; progress and results from an older,
    /// cancelled load are ignored even if they arrive late.
    private(set) var loadGeneration = 0
    private var aggregateTask: Task<Void, Never>?
    private var hasLoadedOnce = false
    private var isRunning = false
    private var occlusionObserver: NSObjectProtocol?
    private var isDisplayVisible = true
    private var skippedRefreshWhileHidden = false

    private static let rangeKey = "agenticUse.range"

    init(
        defaults: UserDefaults = .standard,
        sources: [AgenticUsageLoader.Source]? = nil,
        pricingCatalog: AgenticPricingCatalog = AgenticPricingCatalog(),
        cursorHistory: CursorUsageHistory = CursorUsageHistory(),
        cacheURL: URL? = AgenticUsageLoader.defaultCacheURL()
    ) {
        self.defaults = defaults
        self.pricingCatalog = pricingCatalog
        self.cursorHistory = cursorHistory
        self.loader = AgenticUsageLoader(
            sources: sources ?? AgenticUsageLoader.defaultSources(),
            cacheURL: cacheURL
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
        isDisplayVisible = Self.hasVisibleWindow
        skippedRefreshWhileHidden = false
        observeWindowVisibility()
        load(initial: !hasLoadedOnce)
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self, isRunning else { return }
                // onDisappear never fires for minimize, Hide, or occlusion,
                // so the loop itself skips ticks nobody can see; the skipped
                // work runs once on unhide instead.
                guard isDisplayVisible else {
                    skippedRefreshWhileHidden = true
                    continue
                }
                if !isRefreshing, phase != .idle, hasLoadedOnce { load(initial: false) }
            }
        }
    }

    /// Cancel all work. The app owns the lifecycle so dashboard publication can continue while the section is hidden.
    func stop() {
        isRunning = false
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        aggregateTask?.cancel()
        aggregateTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
        }
        occlusionObserver = nil
        skippedRefreshWhileHidden = false
        isRefreshing = false
        if case .scanning = phase, !hasLoadedOnce {
            phase = .idle
        }
    }

    // MARK: Window visibility

    private func observeWindowVisibility() {
        guard occlusionObserver == nil else { return }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteWindowVisibilityChanged() }
        }
    }

    private func noteWindowVisibilityChanged() {
        guard isRunning else { return }
        let visible = Self.hasVisibleWindow
        guard visible != isDisplayVisible else { return }
        isDisplayVisible = visible
        if visible, skippedRefreshWhileHidden {
            skippedRefreshWhileHidden = false
            if !isRefreshing, phase != .idle, hasLoadedOnce { load(initial: false) }
        }
    }

    /// Whether any app window can actually be seen. Minimize, Hide, and full
    /// occlusion all clear `.visible`; the conservative any-window check
    /// never pauses while a Pilot window is still on screen.
    private static var hasVisibleWindow: Bool {
        guard let app = NSApp else { return true }
        return app.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) }
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
        loadGeneration += 1
        let generation = loadGeneration
        if initial {
            phase = .scanning(scanned: 0, total: 0)
        } else {
            isRefreshing = true
        }
        let cursorEnabled = UsageConsent.isCursorEnabled(defaults: defaults)
        let selectedRange = range
        loadTask = Task { [weak self, loader, pricingCatalog, cursorHistory] in
            do {
                async let pricing = pricingCatalog.load(force: forcePricing)
                async let cursor = cursorHistory.load(enabled: cursorEnabled, range: selectedRange)
                let result = try await loader.load { [weak self] scanned, total in
                    guard initial, let store = self else { return }
                    Task { @MainActor in
                        store.noteScanProgress(scanned: scanned, total: total, generation: generation)
                    }
                }
                let refreshedPricing = await pricing
                let cursorResult = try await cursor
                guard let self, !Task.isCancelled, generation == loadGeneration else { return }
                pricingRates = refreshedPricing.rates
                pricingFetchedAt = refreshedPricing.fetchedAt
                apply(result, pricingWarning: refreshedPricing.warning, cursorResult: cursorResult)
            } catch is CancellationError {
                // Whoever cancelled owns the state transition.
            } catch {
                guard let self, !Task.isCancelled, generation == loadGeneration else { return }
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
    func noteScanProgress(scanned: Int, total: Int, generation: Int) {
        guard generation == loadGeneration,
              case .scanning(let current, _) = phase, scanned >= current else { return }
        phase = .scanning(scanned: scanned, total: total)
    }

    private func apply(
        _ result: AgenticUsageLoader.LoadResult,
        pricingWarning: String?,
        cursorResult: CursorUsageHistory.Result
    ) {
        hasLoadedOnce = true
        isRefreshing = false
        lastUpdatedAt = Date()
        // Cursor history can change even when every local log is unchanged.
        let cursorRecords = UsageConsent.isCursorEnabled(defaults: defaults) ? cursorResult.records : []
        cursorLastUpdated = UsageConsent.isCursorEnabled(defaults: defaults) && cursorResult.isStale
            ? cursorResult.fetchedAt : nil
        records = result.records + cursorRecords
        scanWarning = Self.warningText(for: result, pricingWarning: pricingWarning)
        if UsageConsent.isCursorEnabled(defaults: defaults), let warning = cursorResult.warning {
            scanWarning = [scanWarning, warning].compactMap { $0 }.joined(separator: " ")
        }
        if records.isEmpty {
            snapshot = nil
            phase = .empty
        } else {
            phase = .loaded
            recompute()
        }
    }

    /// The non-fatal problems a load surfaced, joined for the warning banner;
    /// `nil` when there are none, so a resolved warning clears.
    private nonisolated static func warningText(
        for result: AgenticUsageLoader.LoadResult,
        pricingWarning: String?
    ) -> String? {
        var warnings: [String] = []
        if result.unreadableFileCount > 0 {
            let plural = result.unreadableFileCount == 1 ? "" : "s"
            warnings.append("Skipped \(result.unreadableFileCount) unreadable log file\(plural).")
        }
        if result.skippedLineCount > 0 {
            warnings.append("Skipped \(result.skippedLineCount) oversized log lines; usage may be incomplete.")
        }
        if let pricingWarning { warnings.append(pricingWarning) }
        return warnings.isEmpty ? nil : warnings.joined(separator: " ")
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
            guard let snapshot = AgenticUsageStore.makeSnapshot(
                records: records,
                range: range,
                now: Date(),
                calendar: Calendar.current,
                rates: rates,
                isCancelled: { Task.isCancelled }
            ), !Task.isCancelled else { return }
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
        // Never cancelled, so always produces a snapshot.
        makeSnapshot(records: records, range: range, now: now, calendar: calendar, rates: rates) { false }!
    }

    /// Cancellable aggregation: returns `nil` once `isCancelled` reports
    /// true at one of its periodic checkpoints.
    nonisolated static func makeSnapshot(
        records: [AgenticUsageRecord],
        range: AgenticUseRange,
        now: Date,
        calendar: Calendar,
        rates: [String: AgenticModelRate] = AgenticUsagePricing.rates,
        isCancelled: () -> Bool
    ) -> AgenticUseSnapshot? {
        var interval = range.interval(endingAt: now, calendar: calendar)
        let filtered = records.filter {
            $0.timestamp >= interval.start && $0.timestamp <= interval.end
        }
        // "All" is unbounded for filtering; clamp the presented window (the
        // header subtitle and the chart's zero-fill span) to the oldest
        // record across both local logs and Cursor history.
        if range == .all, let first = filtered.min(by: { $0.timestamp < $1.timestamp }) {
            interval = DateInterval(start: calendar.startOfDay(for: first.timestamp), end: interval.end)
        }

        var byModel: [String: ModelBucket] = [:]
        var byProvider: [AgenticProvider: (cost: Double, tokens: Int)] = [:]
        var byChartBucket: [Date: [String: (cost: Double, tokens: Int)]] = [:]
        var byProviderBucket: [Date: [AgenticProvider: ProviderCell]] = [:]
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

        for (index, record) in filtered.enumerated() {
            if index.isMultiple(of: 4096), isCancelled() { return nil }
            let cost = AgenticUsagePricing.cost(of: record, rates: rates)
            let tokens = record.totalTokens

            var model = byModel[record.model, default: ModelBucket()]
            var recordSavings = 0.0
            if let cost {
                model.cost += cost
                totalCost += cost
                if let baseline = AgenticUsagePricing.fullRateCost(of: record, rates: rates) {
                    fullRateCost += baseline
                    baselineCost += cost
                    recordSavings = baseline - cost
                }
            } else {
                model.isUnpriced = true
                unpricedTokens += tokens
            }
            model.tokens += tokens
            model.provider = record.provider
            model.inputTokens += record.inputTokens
            model.cacheWriteTokens += record.cacheWriteTokens
            model.cacheReadTokens += record.cacheReadTokens
            model.outputTokens += record.outputTokens
            byModel[record.model] = model
            var provider = byProvider[record.provider, default: (0, 0)]
            provider.cost += cost ?? 0
            provider.tokens += tokens
            byProvider[record.provider] = provider

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

            var providers = byProviderBucket[chartBucket, default: [:]]
            var providerCell = providers[record.provider, default: ProviderCell()]
            providerCell.cost += cost ?? 0
            providerCell.tokens += tokens
            providerCell.savings += recordSavings
            providerCell.cacheRead += record.cacheReadTokens
            providerCell.observedInput += record.observedInputTokens
            providers[record.provider] = providerCell
            byProviderBucket[chartBucket] = providers

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

        let modelTotals = makeModelTotals(byModel, totalCost: totalCost)

        if isCancelled() { return nil }

        // Zero-fill every bucket in the window for every model present so the
        // stacked area chart never interpolates across silent days.
        let presentProviders = AgenticProvider.allCases.filter { byProvider[$0] != nil }
        var series: [AgenticDailyPoint] = []
        var providerSeries: [AgenticProviderPoint] = []
        if !filtered.isEmpty {
            let buckets = chartBuckets(range: range, interval: interval, calendar: calendar)
            series.reserveCapacity(modelOrder.count * buckets.count)
            providerSeries.reserveCapacity(presentProviders.count * buckets.count)
            for bucket in buckets {
                let models = byChartBucket[bucket] ?? [:]
                for (index, model) in modelOrder.enumerated() {
                    let cell = models[model] ?? (0, 0)
                    series.append(AgenticDailyPoint(
                        day: bucket, model: model, displayName: displayNames[index],
                        cost: cell.cost, tokens: cell.tokens
                    ))
                }
                let providers = byProviderBucket[bucket] ?? [:]
                for provider in presentProviders {
                    let cell = providers[provider] ?? ProviderCell()
                    providerSeries.append(AgenticProviderPoint(
                        day: bucket, provider: provider, cost: cell.cost, tokens: cell.tokens,
                        cacheSavings: max(0, cell.savings), cacheReadTokens: cell.cacheRead,
                        observedInputTokens: cell.observedInput
                    ))
                }
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

        let providerTotals = AgenticProvider.allCases.compactMap { provider in
            byProvider[provider].map {
                AgenticProviderTotal(provider: provider, estimatedCost: $0.cost, totalTokens: $0.tokens)
            }
        }

        let current = AgenticUsePeriodSummary(
            totalCostUSD: totalCost,
            processedTokens: processed,
            cachedInputShare: stats.cachedInputShare,
            cacheSavingsUSD: savings,
            dayCount: range.windowDayCount(of: interval, calendar: calendar)
        )

        if isCancelled() { return nil }
        let previous = range.previousInterval(endingAt: now, calendar: calendar).map { window in
            summarize(
                records.lazy.filter { $0.timestamp >= window.start && $0.timestamp < window.end },
                dayCount: range == .day ? 1 : range.dayCount,
                rates: rates
            )
        }

        return AgenticUseSnapshot(
            range: range,
            interval: interval,
            totalCostUSD: totalCost,
            providerTotals: providerTotals,
            providerSeries: providerSeries,
            current: current,
            previous: previous,
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

    /// Per-model accumulator for `makeSnapshot`.
    struct ModelBucket {
        var cost = 0.0
        var tokens = 0
        var isUnpriced = false
        var provider: AgenticProvider = .claude
        var inputTokens = 0
        var cacheWriteTokens = 0
        var cacheReadTokens = 0
        var outputTokens = 0
    }

    /// Per-provider, per-bucket accumulator for `makeSnapshot`.
    struct ProviderCell {
        var cost = 0.0
        var tokens = 0
        var savings = 0.0
        var cacheRead = 0
        var observedInput = 0
    }

    /// Model accumulators to display totals, cost descending (ties by tokens).
    nonisolated static func makeModelTotals(
        _ byModel: [String: ModelBucket], totalCost: Double
    ) -> [AgenticModelTotal] {
        byModel
            .map { model, bucket in
                AgenticModelTotal(
                    model: model,
                    displayName: AgenticModel.displayName(for: model),
                    cost: bucket.cost,
                    tokens: bucket.tokens,
                    costShare: totalCost > 0 ? bucket.cost / totalCost : 0,
                    isUnpriced: bucket.isUnpriced,
                    provider: bucket.provider,
                    inputTokens: bucket.inputTokens,
                    cacheWriteTokens: bucket.cacheWriteTokens,
                    cacheReadTokens: bucket.cacheReadTokens,
                    outputTokens: bucket.outputTokens
                )
            }
            .sorted { lhs, rhs in
                lhs.cost == rhs.cost ? lhs.tokens > rhs.tokens : lhs.cost > rhs.cost
            }
    }

    /// Every chart bucket start in the window, oldest first: local midnights,
    /// or tops of hours for 24h. Capped so a corrupt timestamp far in the
    /// past can't allocate an unbounded series.
    nonisolated static func chartBuckets(
        range: AgenticUseRange, interval: DateInterval, calendar: Calendar
    ) -> [Date] {
        var bucket = range.bucketUnit == .day
            ? calendar.startOfDay(for: interval.start)
            : calendar.dateInterval(of: .hour, for: interval.start)?.start ?? interval.start
        let stepLimit = range == .all ? 2000 : 400
        var buckets: [Date] = []
        while bucket <= interval.end, buckets.count < stepLimit {
            buckets.append(bucket)
            guard let next = calendar.date(byAdding: range.bucketUnit, value: 1, to: bucket) else { break }
            bucket = next
        }
        return buckets
    }

    /// Headline totals for an arbitrary record window, priced the same way
    /// as the main aggregation so deltas compare like for like.
    nonisolated static func summarize(
        _ records: some Sequence<AgenticUsageRecord>,
        dayCount: Int,
        rates: [String: AgenticModelRate]
    ) -> AgenticUsePeriodSummary {
        var cost = 0.0
        var fullRate = 0.0
        var baseline = 0.0
        var processed = 0
        var cacheRead = 0
        var observedInput = 0
        for record in records {
            processed += record.totalTokens
            cacheRead += record.cacheReadTokens
            observedInput += record.observedInputTokens
            guard let recordCost = AgenticUsagePricing.cost(of: record, rates: rates) else { continue }
            cost += recordCost
            if let full = AgenticUsagePricing.fullRateCost(of: record, rates: rates) {
                fullRate += full
                baseline += recordCost
            }
        }
        return AgenticUsePeriodSummary(
            totalCostUSD: cost,
            processedTokens: processed,
            cachedInputShare: observedInput > 0 ? Double(cacheRead) / Double(observedInput) : 0,
            cacheSavingsUSD: max(0, fullRate - baseline),
            dayCount: dayCount
        )
    }
}
