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
        let minimumWidth = max(180 * AgenticUseLayout.zoom, cards.map(\.minimumWidth).max() ?? 0)
        let count = max(1, min(cards.count, Int((max(0, width) + 8) / (minimumWidth + 8))))
        // Avoid an isolated fifth card when a balanced three/two split fits.
        return count == 4 && cards.count == 5 ? 3 : count
    }
    func preferredHeight(for width: CGFloat) -> CGFloat {
        let rows = ceil(CGFloat(cards.count) / CGFloat(columns(for: width)))
        return rows * 96 * AgenticUseLayout.zoom + max(0, rows - 1) * 8
    }
    override func layout() {
        super.layout()
        let count = columns(for: bounds.width)
        let width = max(0, (bounds.width - CGFloat(count - 1) * 8) / CGFloat(count))
        let height = 96 * AgenticUseLayout.zoom
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
                number: snapshot.totalCostUSD,
                delta: relativeDelta(snapshot.totalCostUSD, previous?.totalCostUSD, polarity: .lowerIsBetter),
                fallbackCaption: fallbackCaption,
                sparkline: buckets.map(\.cost),
                help: "API-equivalent cost of the logged tokens at published per-token rates — not a subscription bill."
            ),
            AgenticUseKPIMetric(
                id: "tokens",
                title: "Processed Tokens",
                value: AgenticUseFormat.tokens(snapshot.stats.processedTokens),
                number: Double(snapshot.stats.processedTokens),
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
                number: snapshot.stats.cachedInputShare,
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
                number: snapshot.stats.cacheSavingsUSD,
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
                number: averageCost,
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
    let number: Double
    let delta: Delta?
    let fallbackCaption: String
    let sparkline: [Double]
    var anchorsAtZero = true
    let help: String
}

@MainActor
final class AgenticUseKPICard: AgenticUseCardView {
    private var metric: AgenticUseKPIMetric
    let transition = AgenticUseDataTransition()
    private(set) var displayedNumber: Double
    private let valueLabel = AgenticUseNumericTextField(labelWithString: "")
    private let deltaLabel = NSTextField(labelWithString: "")
    private let caption = NSTextField(labelWithString: "")
    private let sparkline = AgenticUseSparkline(values: [], tint: .secondaryLabelColor)
    private var measuredZoom: CGFloat?
    private var measuredValueWidth: CGFloat = 0
    private var measuredDeltaWidth: CGFloat = 0
    var minimumWidth: CGFloat {
        measureTextIfNeeded()
        return measuredValueWidth + 24 * AgenticUseLayout.zoom
    }
    private func measureTextIfNeeded() {
        let zoom = AgenticUseLayout.zoom
        guard measuredZoom != zoom else { return }
        measuredZoom = zoom
        let valueFont = CockpitTypography.font(.metric)
        let deltaFont = AgenticUseLayout.font(.caption, weight: .semibold)
        measuredValueWidth = ceil(max((metric.value as NSString).size(withAttributes: [.font: valueFont]).width,
                                     valueLabel.transitionWidth)) + 6
        measuredDeltaWidth = ceil((deltaLabel.stringValue as NSString).size(withAttributes: [.font: deltaFont]).width) + 6
    }
    init(metric: AgenticUseKPIMetric) {
        self.metric = metric
        displayedNumber = metric.number
        super.init(title: metric.title)
        valueLabel.font = CockpitTypography.font(.metric)
        for child in [valueLabel, deltaLabel, caption, sparkline] { addSubview(child) }
        update(metric: metric)
    }
    required init?(coder: NSCoder) { nil }
    func update(metric: AgenticUseKPIMetric) {
        self.metric = metric
        measuredZoom = nil
        titleLabel.stringValue = metric.title
        let from = displayedNumber
        valueLabel.prepareTransition(to: metric.value, countsDown: metric.number < from)
        transition.start(in: self, animated: from != metric.number) { [weak self] progress in
            guard let self else { return }
            self.displayedNumber = AgenticUseDataTransition.mix(from, metric.number, progress)
            self.valueLabel.setTransitionProgress(progress)
        }
        if let delta = metric.delta {
            deltaLabel.stringValue = (delta.isFlat ? "− " : delta.change > 0 ? "↑ " : "↓ ") + delta.text
            deltaLabel.textColor = .labelColor
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
        measureTextIfNeeded()
        let inset = 12 * zoom
        let width = max(0, bounds.width - inset * 2)
        titleLabel.font = AgenticUseLayout.font(.body, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.frame = NSRect(x: inset, y: 10 * zoom, width: width, height: 18 * zoom)
        let valueFont = CockpitTypography.font(.metric)
        valueLabel.font = valueFont
        let valueWidth = min(width, measuredValueWidth)
        valueLabel.frame = NSRect(x: inset, y: 31 * zoom, width: valueWidth, height: 28 * zoom)
        valueLabel.lineBreakMode = .byTruncatingTail
        let sparkWidth = max(0, width - valueWidth - 8 * zoom)
        sparkline.isHidden = sparkWidth < 40 * zoom
        sparkline.frame = NSRect(x: valueLabel.frame.maxX + 8 * zoom, y: 34 * zoom, width: sparkWidth, height: 26 * zoom)
        let deltaFont = AgenticUseLayout.font(.caption, weight: .semibold)
        deltaLabel.font = deltaFont
        let deltaWidth = min(width, measuredDeltaWidth)
        deltaLabel.frame = NSRect(x: inset, y: 70 * zoom, width: deltaWidth, height: 16 * zoom)
        caption.font = AgenticUseLayout.font(.caption)
        caption.textColor = .secondaryLabelColor
        let captionX = metric.delta == nil ? inset : deltaLabel.frame.maxX + 4 * zoom
        caption.frame = NSRect(x: captionX, y: 70 * zoom, width: max(0, bounds.width - inset - captionX), height: 16 * zoom)
        caption.lineBreakMode = .byTruncatingTail
    }
}

/// AppKit's equivalent of a numeric-text content transition. Retain the native
/// text field (including its accessibility value), and roll only changed digits.
/// Coordinates use font units so zoom and resizing cannot stale the animation.
@MainActor
final class AgenticUseNumericTextField: NSTextField {
    struct Glyph: Equatable {
        let key: String
        let text: String
        var x: CGFloat
        var y: CGFloat = 0
        var opacity: Double = 1
    }
    private struct Movement {
        let from: Glyph
        let to: Glyph
    }
    private var movements: [Movement] = []
    private(set) var renderedGlyphs: [Glyph] = []
    private var targetGlyphs: [Glyph] = []
    private var transitionWidthInFontUnits: CGFloat = 0
    var transitionWidth: CGFloat { transitionWidthInFontUnits * (font?.pointSize ?? CockpitTypography.font(.metric).pointSize) }
    private(set) var isTransitioning = false

    func prepareTransition(to text: String, countsDown: Bool) {
        guard text != stringValue || isTransitioning else { return }
        let source = isTransitioning ? renderedGlyphs : glyphs(for: stringValue)
        targetGlyphs = glyphs(for: text)
        let font = font ?? CockpitTypography.font(.metric)
        transitionWidthInFontUnits = (source + targetGlyphs).map {
            $0.x + ($0.text as NSString).size(withAttributes: [.font: font]).width / font.pointSize
        }.max() ?? 0
        let direction: CGFloat = countsDown ? 1 : -1
        movements = []
        var remaining = source
        for target in targetGlyphs {
            if let index = remaining.firstIndex(where: { $0.key == target.key && $0.text == target.text }) {
                movements.append(Movement(from: remaining.remove(at: index), to: target))
            } else {
                var incoming = target
                incoming.x = source.first { $0.key == target.key }?.x ?? target.x
                incoming.y = target.text.first?.isNumber == true ? -direction : 0
                incoming.opacity = 0
                movements.append(Movement(from: incoming, to: target))
            }
        }
        for old in remaining {
            var outgoing = old
            outgoing.x = targetGlyphs.first { $0.key == old.key }?.x ?? old.x
            outgoing.y += old.text.first?.isNumber == true ? direction : 0
            outgoing.opacity = 0
            movements.append(Movement(from: old, to: outgoing))
        }
        stringValue = text
        isTransitioning = !source.isEmpty
        if !isTransitioning { renderedGlyphs = targetGlyphs }
        setTransitionProgress(isTransitioning ? 0 : 1)
    }

    func setTransitionProgress(_ progress: Double) {
        guard isTransitioning else { return }
        if progress >= 1 {
            isTransitioning = false
            movements.removeAll()
            renderedGlyphs = targetGlyphs
        } else {
            renderedGlyphs = movements.map { move in
                var glyph = move.to
                glyph.x = AgenticUseDataTransition.mix(move.from.x, move.to.x, progress)
                glyph.y = AgenticUseDataTransition.mix(move.from.y, move.to.y, progress)
                glyph.opacity = AgenticUseDataTransition.mix(move.from.opacity, move.to.opacity, progress)
                return glyph
            }
        }
        needsDisplay = true
    }

    private func glyphs(for text: String) -> [Glyph] {
        let characters = Array(text)
        let decimal = characters.firstIndex { String($0) == (Locale.current.decimalSeparator ?? ".") } ?? characters.count
        let firstDigit = characters.firstIndex(where: \.isNumber) ?? 0
        let lastDigit = characters.lastIndex(where: \.isNumber) ?? 0
        let font = font ?? CockpitTypography.font(.metric)
        var x: CGFloat = 0
        return characters.enumerated().map { index, character in
            let key: String
            if character.isNumber {
                key = index < decimal
                    ? "integer:\(characters[(index + 1)..<decimal].filter(\.isNumber).count)"
                    : "fraction:\(characters[decimal..<index].filter(\.isNumber).count)"
            } else if index < firstDigit {
                key = "prefix:\(index):\(character)"
            } else if index > lastDigit {
                key = "suffix:\(index - lastDigit):\(character)"
            } else {
                key = "separator:\(characters[(index + 1)...].filter(\.isNumber).count):\(character)"
            }
            let glyph = Glyph(key: key, text: String(character), x: x)
            x += (String(character) as NSString).size(withAttributes: [.font: font]).width / font.pointSize
            return glyph
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isTransitioning, let font else { super.draw(dirtyRect); return }
        NSGraphicsContext.saveGraphicsState()
        bounds.clip()
        let titleRect = cell?.titleRect(forBounds: bounds) ?? bounds
        for glyph in renderedGlyphs where glyph.opacity > 0 {
            // Match NSTextFieldCell's two-point horizontal text inset so the
            // first and final animated frames align with native text drawing.
            (glyph.text as NSString).draw(at: NSPoint(x: titleRect.minX + 2 + glyph.x * font.pointSize,
                                                     y: titleRect.minY + glyph.y * font.pointSize),
                                        withAttributes: [.font: font,
                                                         .foregroundColor: (textColor ?? .labelColor).withAlphaComponent(glyph.opacity)])
        }
        NSGraphicsContext.restoreGraphicsState()
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
