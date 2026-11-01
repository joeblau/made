import SwiftUI

/// The headline row: five metric cards, each with a delta against the
/// equally long previous window and a sparkline of the selected range.
///
/// Delta color is semantic — green when the change is an improvement (lower
/// cost, higher cache hit rate), red when it is a regression, secondary for
/// volume figures that are neither good nor bad. Sparklines stay neutral:
/// per-card hues collided with the provider colors used everywhere else.
struct AgenticUseKPICards: View {
    let snapshot: AgenticUseSnapshot
    /// Columns to lay the cards across; the dashboard picks this from width.
    let columns: Int

    var body: some View {
        let metrics = metrics
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: max(1, columns)),
            alignment: .leading,
            spacing: 12
        ) {
            ForEach(metrics) { metric in
                AgenticUseKPICard(metric: metric)
            }
        }
    }

    // MARK: - Metrics

    private var metrics: [AgenticUseKPIMetric] {
        let buckets = snapshot.bucketTotals
        let previous = snapshot.previous.flatMap { $0.isEmpty ? nil : $0 }
        let current = snapshot.current
        let isHourly = snapshot.range == .day
        let averageCost = isHourly
            ? snapshot.totalCostUSD / 24
            : (current?.averageDailyCostUSD ?? 0)
        let previousAverage = previous.map { isHourly ? $0.totalCostUSD / 24 : $0.averageDailyCostUSD }
        let unpricedMark = snapshot.hasUnpricedModels ? "*" : ""

        return [
            AgenticUseKPIMetric(
                id: "cost",
                title: "Estimated Cost",
                value: AgenticUseFormat.cost(snapshot.totalCostUSD) + unpricedMark,
                delta: relativeDelta(snapshot.totalCostUSD, previous?.totalCostUSD, polarity: .lowerIsBetter),
                fallbackCaption: fallbackCaption,
                sparkline: buckets.map(\.cost),
                help: "API-equivalent cost of the logged tokens at published per-token rates — not a subscription bill."
            ),
            AgenticUseKPIMetric(
                id: "tokens",
                title: "Processed Tokens",
                value: AgenticUseFormat.tokens(snapshot.stats.processedTokens),
                delta: relativeDelta(
                    Double(snapshot.stats.processedTokens),
                    previous.map { Double($0.processedTokens) },
                    polarity: .neutral
                ),
                fallbackCaption: fallbackCaption,
                sparkline: buckets.map { Double($0.tokens) },
                help: "Input, cache write, cache read, and output tokens across every agent."
            ),
            AgenticUseKPIMetric(
                id: "cache-rate",
                title: "Cache Hit Rate",
                value: AgenticUseFormat.percent(snapshot.stats.cachedInputShare),
                delta: pointsDelta(snapshot.stats.cachedInputShare, previous?.cachedInputShare),
                fallbackCaption: fallbackCaption,
                sparkline: buckets.compactMap(\.cachedInputShare),
                anchorsAtZero: false,
                help: "Cache reads as a share of all observed input tokens."
            ),
            AgenticUseKPIMetric(
                id: "savings",
                title: "Cache Savings",
                value: AgenticUseFormat.cost(snapshot.stats.cacheSavingsUSD),
                delta: relativeDelta(
                    snapshot.stats.cacheSavingsUSD, previous?.cacheSavingsUSD, polarity: .higherIsBetter
                ),
                fallbackCaption: fallbackCaption,
                sparkline: buckets.map(\.cacheSavings),
                help: "Estimated difference between full-rate input pricing and actual cached pricing."
            ),
            AgenticUseKPIMetric(
                id: "average",
                title: isHourly ? "Avg Hourly Cost" : "Avg Daily Cost",
                value: AgenticUseFormat.cost(averageCost) + unpricedMark,
                delta: relativeDelta(averageCost, previousAverage, polarity: .lowerIsBetter),
                fallbackCaption: fallbackCaption,
                sparkline: Self.movingAverage(buckets.map(\.cost), window: isHourly ? 3 : 7),
                help: isHourly
                    ? "Estimated cost divided by the 24 hours in range."
                    : "Estimated cost divided by every calendar day in range, active or not."
            ),
        ]
    }

    private var fallbackCaption: String {
        guard let label = snapshot.range.comparisonLabel else { return "across all history" }
        return "no usage " + label.replacingOccurrences(of: "vs ", with: "in ")
    }

    private enum Polarity {
        case higherIsBetter
        case lowerIsBetter
        case neutral
    }

    private func tone(for change: Double, polarity: Polarity) -> AgenticUseInsight.Tone {
        switch polarity {
        case .neutral: .neutral
        case .higherIsBetter: change >= 0 ? .positive : .negative
        case .lowerIsBetter: change <= 0 ? .positive : .negative
        }
    }

    private func relativeDelta(_ current: Double, _ previous: Double?, polarity: Polarity) -> AgenticUseKPIMetric.Delta? {
        guard let previous, let label = snapshot.range.comparisonLabel,
              let change = AgenticUseFormat.relativeChange(current: current, previous: previous) else { return nil }
        return .init(
            change: change,
            isFlat: abs(change) < 0.0005,
            text: AgenticUseFormat.deltaPercent(change),
            caption: label,
            tone: tone(for: change, polarity: polarity)
        )
    }

    private func pointsDelta(_ current: Double, _ previous: Double?) -> AgenticUseKPIMetric.Delta? {
        guard let previous, let label = snapshot.range.comparisonLabel else { return nil }
        let change = current - previous
        return .init(
            change: change,
            isFlat: abs(change) < 0.0005,
            text: AgenticUseFormat.deltaPoints(change),
            caption: label,
            tone: tone(for: change, polarity: .higherIsBetter)
        )
    }

    /// Trailing moving average, so the average-cost card reads as a smoothed
    /// trend rather than repeating the cost card's raw line.
    nonisolated static func movingAverage(_ values: [Double], window: Int) -> [Double] {
        guard window > 1, !values.isEmpty else { return values }
        var result: [Double] = []
        result.reserveCapacity(values.count)
        var running = 0.0
        for (index, value) in values.enumerated() {
            running += value
            if index >= window { running -= values[index - window] }
            result.append(running / Double(min(index + 1, window)))
        }
        return result
    }
}

struct AgenticUseKPIMetric: Identifiable {
    struct Delta {
        let change: Double
        /// Rounds to zero at display precision: drawn neutral with a dash
        /// rather than as a red or green "0.0".
        let isFlat: Bool
        let text: String
        let caption: String
        let tone: AgenticUseInsight.Tone

        var symbol: String { isFlat ? "minus" : (change > 0 ? "arrow.up" : "arrow.down") }
        var effectiveTone: AgenticUseInsight.Tone { isFlat ? .neutral : tone }
        var spokenDirection: String { isFlat ? "Unchanged" : (change > 0 ? "Up" : "Down") }
    }

    let id: String
    let title: String
    let value: String
    let delta: Delta?
    let fallbackCaption: String
    let sparkline: [Double]
    var anchorsAtZero = true
    let help: String
}

private struct AgenticUseKPICard: View {
    let metric: AgenticUseKPIMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(metric.title)
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(metric.value)
                .scaledFont(size: 26, weight: .bold, design: .rounded)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            HStack(alignment: .bottom, spacing: 8) {
                deltaLabel
                    .layoutPriority(1)
                Spacer(minLength: 4)
                if metric.sparkline.count > 1 {
                    AgenticUseSparkline(
                        values: metric.sparkline,
                        tint: .secondary,
                        anchorsAtZero: metric.anchorsAtZero
                    )
                    .frame(minWidth: 44, maxWidth: 110)
                    .frame(height: 30)
                }
            }
        }
        .agenticUseCard()
        .help(metric.help)
        .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.7), value: metric.value)
    }

    @ViewBuilder
    private var deltaLabel: some View {
        if let delta = metric.delta {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    deltaBadge(delta)
                    Text(delta.caption)
                        .scaledFont(size: 11)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                deltaBadge(delta)
            }
        } else {
            Text(metric.fallbackCaption)
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func deltaBadge(_ delta: AgenticUseKPIMetric.Delta) -> some View {
        HStack(spacing: 2) {
            Image(systemName: delta.symbol)
                .scaledFont(size: 11, weight: .bold)
            Text(delta.text)
                .scaledFont(size: 12, weight: .semibold)
                .monospacedDigit()
        }
        .foregroundStyle(AgenticUseTone.color(delta.effectiveTone))
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(delta.spokenDirection) \(delta.text) \(delta.caption)")
    }
}

/// Maps an insight/delta tone to its semantic color.
enum AgenticUseTone {
    static func color(_ tone: AgenticUseInsight.Tone) -> Color {
        switch tone {
        case .positive: .green
        case .negative: .red
        case .neutral: .secondary
        }
    }
}
