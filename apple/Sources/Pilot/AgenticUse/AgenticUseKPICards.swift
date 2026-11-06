import AppKit

@MainActor
final class AgenticUseKPICards: AgenticUseFlippedView {
    private var snapshot: AgenticUseSnapshot
    private var cards: [AgenticUseKPICard] = []

    init(snapshot: AgenticUseSnapshot, columns: Int = 5) {
        self.snapshot = snapshot
        super.init(frame: .zero)
        rebuild()
    }
    required init?(coder: NSCoder) { nil }
    func update(snapshot: AgenticUseSnapshot) {
        self.snapshot = snapshot
        rebuild()
    }
    private func rebuild() {
        let values = metrics
        if cards.count != values.count {
            cards.forEach { $0.removeFromSuperview() }
            cards = values.map { AgenticUseKPICard(metric: $0) }
            cards.forEach(addSubview)
        } else {
            for (card, metric) in zip(cards, values) { card.update(metric: metric) }
        }
        needsLayout = true
    }
    private func columns(for width: CGFloat) -> Int {
        let scaled = width / AgenticUseLayout.zoom
        return scaled >= 1000 ? 5 : (scaled >= 640 ? 3 : (scaled >= 350 ? 2 : 1))
    }
    func preferredHeight(for width: CGFloat) -> CGFloat {
        let rows = ceil(CGFloat(cards.count) / CGFloat(columns(for: width)))
        return rows * 140 * AgenticUseLayout.zoom + max(0, rows - 1) * 8
    }
    override func layout() {
        super.layout()
        let count = columns(for: bounds.width)
        let width = max(0, (bounds.width - CGFloat(count - 1) * 8) / CGFloat(count))
        let height = 140 * AgenticUseLayout.zoom
        for (index, card) in cards.enumerated() {
            card.frame = NSRect(x: CGFloat(index % count) * (width + 8), y: CGFloat(index / count) * (height + 8), width: width, height: height)
            card.needsLayout = true
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

@MainActor
private final class AgenticUseKPICard: AgenticUseCardView {
    private var metric: AgenticUseKPIMetric
    private let valueLabel = NSTextField(labelWithString: "")
    private let deltaLabel = NSTextField(labelWithString: "")
    private let caption = NSTextField(labelWithString: "")
    private let sparkline = AgenticUseSparkline(values: [], tint: .secondaryLabelColor)
    init(metric: AgenticUseKPIMetric) {
        self.metric = metric
        super.init(title: metric.title)
        for child in [valueLabel, deltaLabel, caption, sparkline] { addSubview(child) }
        update(metric: metric)
    }
    required init?(coder: NSCoder) { nil }
    func update(metric: AgenticUseKPIMetric) {
        self.metric = metric
        titleLabel.stringValue = metric.title
        valueLabel.stringValue = metric.value
        if let delta = metric.delta {
            deltaLabel.stringValue = (delta.isFlat ? "− " : delta.change > 0 ? "↑ " : "↓ ") + delta.text
            deltaLabel.textColor = AgenticUseTone.color(delta.effectiveTone)
            deltaLabel.setAccessibilityLabel("\(delta.spokenDirection) \(delta.text)")
            caption.stringValue = delta.caption
        } else {
            deltaLabel.stringValue = ""
            caption.stringValue = metric.fallbackCaption
        }
        sparkline.update(values: metric.sparkline, tint: .secondaryLabelColor, anchorsAtZero: metric.anchorsAtZero)
        toolTip = metric.help
        setAccessibilityLabel("\(metric.title), \(metric.value), \(deltaLabel.stringValue), \(caption.stringValue)")
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let zoom = AgenticUseLayout.zoom
        titleLabel.font = AgenticUseLayout.font(.body, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.frame = NSRect(x: 14, y: 12, width: max(0, bounds.width - 28), height: 22 * zoom)
        valueLabel.font = AgenticUseLayout.font(.display, weight: .bold, monospaced: true)
        valueLabel.frame = NSRect(x: 14, y: 38 * zoom, width: max(0, bounds.width - 28), height: 36 * zoom)
        valueLabel.lineBreakMode = .byTruncatingTail
        deltaLabel.font = AgenticUseLayout.font(.body, weight: .semibold)
        deltaLabel.frame = NSRect(x: 14, y: 80 * zoom, width: max(0, bounds.width * 0.5 - 14), height: 22 * zoom)
        sparkline.frame = NSRect(x: bounds.width * 0.5, y: 80 * zoom, width: max(0, bounds.width * 0.5 - 14), height: 30 * zoom)
        caption.font = AgenticUseLayout.font(.caption)
        caption.textColor = .secondaryLabelColor
        caption.frame = NSRect(x: 14, y: 112 * zoom, width: max(0, bounds.width - 28), height: 18 * zoom)
    }
}

enum AgenticUseTone {
    static func color(_ tone: AgenticUseInsight.Tone) -> NSColor {
        switch tone {
        case .positive: .systemGreen
        case .negative: .systemRed
        case .neutral: .secondaryLabelColor
        }
    }
}
