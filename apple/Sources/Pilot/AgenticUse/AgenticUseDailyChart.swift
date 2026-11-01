import Charts
import SwiftUI

/// The dashboard centerpiece: per-provider stacked cost, tokens, or cache
/// savings over the range (hourly for 24h, daily or weekly otherwise), with a
/// hover tooltip and a share legend that isolates a provider on click.
///
/// Providers are stacked in `AgenticProvider.allCases` order and colored by
/// `AgenticUseModelPalette.providerColor`, the same identity the token-flow
/// diagram, provider breakdown, and Top Models table use.
struct AgenticUseDailyChartPanel: View {
    let snapshot: AgenticUseSnapshot

    @State private var metric: Metric = .cost
    @State private var granularity: Granularity = .daily
    @State private var style: Style = .area
    @State private var selection: Date?
    @State private var isolated: AgenticProvider?

    enum Metric: String, CaseIterable, Identifiable {
        case cost = "Cost"
        case tokens = "Tokens"
        case savings = "Cache Savings"

        var id: String { rawValue }
    }

    enum Granularity: String, CaseIterable, Identifiable {
        case daily = "Daily"
        case weekly = "Weekly"

        var id: String { rawValue }
    }

    enum Style: String, CaseIterable, Identifiable {
        case area = "Stacked Area"
        case bars = "Stacked Bars"

        var id: String { rawValue }
    }

    /// One plotted cell after granularity rollup.
    struct Cell: Identifiable, Equatable {
        let bucket: Date
        let provider: AgenticProvider
        let value: Double

        var id: String { "\(provider.rawValue)|\(bucket.timeIntervalSinceReferenceDate)" }
    }

    var body: some View {
        let cells = cells
        VStack(alignment: .leading, spacing: 12) {
            header
            if cells.allSatisfy({ $0.value == 0 }) {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: "chart.xyaxis.line",
                    description: Text(emptyDescription)
                )
                .frame(minHeight: 240)
            } else {
                chart(cells)
                    .frame(minHeight: 240, idealHeight: 280)
            }
            legend
        }
        .agenticUseCard()
        .onChange(of: snapshot.range) { _, range in
            if !Self.offersWeekly(range) { granularity = .daily }
            selection = nil
        }
        .onChange(of: metric) { selection = nil }
        .onChange(of: granularity) { selection = nil }
        .onChange(of: snapshot.providerTotals.map(\.provider)) { _, providers in
            if let isolated, !providers.contains(isolated) { self.isolated = nil }
        }
    }

    // MARK: - Header

    private var title: String {
        let unit = switch (snapshot.range.bucketUnit, effectiveGranularity) {
        case (.hour, _): "Hourly"
        case (_, .weekly): "Weekly"
        default: "Daily"
        }
        return "\(unit) \(metric == .savings ? "Cache Savings" : metric.rawValue)"
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Text(title).agenticUseCardTitle().fixedSize()
                metricPicker
                Spacer(minLength: 8)
                trailingControls
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text(title).agenticUseCardTitle().fixedSize()
                    Spacer(minLength: 8)
                    trailingControls
                }
                metricPicker
            }
        }
    }

    private var metricPicker: some View {
        Picker("Metric", selection: $metric) {
            ForEach(Metric.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
    }

    private var trailingControls: some View {
        HStack(spacing: 8) {
            if Self.offersWeekly(snapshot.range) {
                Picker("Granularity", selection: $granularity) {
                    ForEach(Granularity.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Picker("Chart style", selection: $style) {
                ForEach(Style.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        .controlSize(.small)
    }

    /// Weekly rollup only helps once there are more than a couple of weeks.
    private static func offersWeekly(_ range: AgenticUseRange) -> Bool {
        range == .month || range == .quarter || range == .all
    }

    private var effectiveGranularity: Granularity {
        Self.offersWeekly(snapshot.range) ? granularity : .daily
    }

    private var emptyTitle: String {
        metric == .savings ? "No cache savings" : "Nothing to chart"
    }

    private var emptyDescription: String {
        switch metric {
        case .cost: "Models in this range have no published pricing. Switch to Tokens to view usage."
        case .savings: "No priced cache reads were recorded in this range."
        case .tokens: "No tokens were recorded in this range."
        }
    }

    // MARK: - Data

    private var providers: [AgenticProvider] {
        let present = snapshot.providerTotals.map(\.provider)
        if let isolated, present.contains(isolated) { return [isolated] }
        return present
    }

    private func value(of point: AgenticProviderPoint) -> Double {
        switch metric {
        case .cost: point.cost
        case .tokens: Double(point.tokens)
        case .savings: point.cacheSavings
        }
    }

    /// Provider series rolled up to the chosen granularity, ordered bucket
    /// then provider so stacking order matches the tooltip and legend.
    private var cells: [Cell] {
        let visible = Set(providers)
        let calendar = Calendar.current
        var order: [Date] = []
        var sums: [Date: [AgenticProvider: Double]] = [:]
        for point in snapshot.providerSeries where visible.contains(point.provider) {
            let bucket: Date
            if effectiveGranularity == .weekly {
                bucket = calendar.dateInterval(of: .weekOfYear, for: point.day)?.start ?? point.day
            } else {
                bucket = point.day
            }
            if sums[bucket] == nil { order.append(bucket) }
            sums[bucket, default: [:]][point.provider, default: 0] += value(of: point)
        }
        return order.flatMap { bucket in
            providers.map { provider in
                Cell(bucket: bucket, provider: provider, value: sums[bucket]?[provider] ?? 0)
            }
        }
    }

    private var bucketUnit: Calendar.Component {
        effectiveGranularity == .weekly ? .weekOfYear : snapshot.range.bucketUnit
    }

    // MARK: - Chart

    private func chart(_ cells: [Cell]) -> some View {
        let selected = selectedBucket(in: cells)
        return Chart {
            ForEach(cells) { cell in
                switch style {
                case .area:
                    AreaMark(
                        x: .value("Date", cell.bucket, unit: bucketUnit),
                        y: .value(metric.rawValue, cell.value),
                        stacking: .standard
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(by: .value("Provider", cell.provider.displayName))
                    .opacity(0.9)
                case .bars:
                    BarMark(
                        x: .value("Date", cell.bucket, unit: bucketUnit),
                        y: .value(metric.rawValue, cell.value),
                        stacking: .standard
                    )
                    .foregroundStyle(by: .value("Provider", cell.provider.displayName))
                }
            }
            if let selected {
                RuleMark(x: .value("Date", selected, unit: bucketUnit))
                    .foregroundStyle(.primary.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(
                        position: .top,
                        alignment: .leading,
                        spacing: 8,
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                    ) {
                        tooltip(for: selected, cells: cells)
                    }
                if style == .area {
                    ForEach(stackTops(at: selected, cells: cells), id: \.provider) { top in
                        PointMark(
                            x: .value("Date", selected, unit: bucketUnit),
                            y: .value(metric.rawValue, top.value)
                        )
                        .symbolSize(28)
                        .foregroundStyle(.white)
                    }
                }
            }
        }
        .chartForegroundStyleScale(
            domain: providers.map(\.displayName),
            range: providers.map(AgenticUseModelPalette.providerColor(for:))
        )
        .chartLegend(.hidden)
        .chartXSelection(value: snappedSelection)
        .chartOverlay { proxy in
            // `chartXSelection` alone only responds to drag on macOS; hover
            // is the expected tooltip gesture, so feed the same binding.
            GeometryReader { geometry in
                Color.clear.onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        guard let plotFrame = proxy.plotFrame else { return }
                        let frame = geometry[plotFrame]
                        guard frame.contains(location) else {
                            setSelection(nil)
                            return
                        }
                        setSelection(proxy.value(atX: location.x - frame.minX, as: Date.self))
                    case .ended:
                        setSelection(nil)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 8)) {
                AxisValueLabel(format: xAxisFormat)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(axisLabel(for: number))
                            .scaledFont(size: 10)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    /// Cumulative stack heights at one bucket, in stacking order — where the
    /// hover dots sit on each layer's upper edge.
    private func stackTops(at bucket: Date, cells: [Cell]) -> [(provider: AgenticProvider, value: Double)] {
        var running = 0.0
        return cells.filter { $0.bucket == bucket }.compactMap { cell in
            guard cell.value > 0 else { return nil }
            running += cell.value
            return (cell.provider, running)
        }
    }

    private var xAxisFormat: Date.FormatStyle {
        snapshot.range == .day ? .dateTime.hour() : .dateTime.month(.abbreviated).day()
    }

    private func axisLabel(for number: Double) -> String {
        metric == .tokens ? AgenticUseFormat.tokens(number) : AgenticUseFormat.axisCost(number)
    }

    private func formatted(_ number: Double) -> String {
        metric == .tokens ? AgenticUseFormat.tokens(number) : AgenticUseFormat.cost(number)
    }

    // MARK: - Legend

    /// Shares of the whole range for the current metric. Clicking an entry
    /// isolates that provider; clicking it again restores the stack.
    private var legend: some View {
        let shares = legendShares
        return HStack(spacing: 16) {
            Spacer(minLength: 0)
            ForEach(shares, id: \.provider) { entry in
                Button {
                    withAnimation(.snappy) {
                        isolated = isolated == entry.provider ? nil : entry.provider
                    }
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(AgenticUseModelPalette.providerColor(for: entry.provider))
                            .frame(width: 8, height: 8)
                        Text(entry.provider.displayName)
                            .scaledFont(size: 12, weight: .medium)
                        Text(AgenticUseFormat.percent(entry.share))
                            .scaledFont(size: 12)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .opacity(isolated == nil || isolated == entry.provider ? 1 : 0.4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isolated == entry.provider ? "Show all providers" : "Show only \(entry.provider.displayName)")
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var legendShares: [(provider: AgenticProvider, share: Double)] {
        var totals: [AgenticProvider: Double] = [:]
        for point in snapshot.providerSeries {
            totals[point.provider, default: 0] += value(of: point)
        }
        let sum = totals.values.reduce(0, +)
        return snapshot.providerTotals.map(\.provider).map { provider in
            (provider, sum > 0 ? (totals[provider] ?? 0) / sum : 0)
        }
    }

    // MARK: - Hover selection

    /// Hover and drag both land here snapped to the bucket grid, and only
    /// when the bucket changed — mouse-moves within one bucket would
    /// otherwise invalidate the chart body at pointer-event rate.
    private func setSelection(_ raw: Date?) {
        let snapped = raw.flatMap { date -> Date? in
            if effectiveGranularity == .weekly {
                return Calendar.current.dateInterval(of: .weekOfYear, for: date)?.start
            }
            return Self.snappedBucket(for: date, range: snapshot.range, calendar: .current)
        }
        if selection != snapped { selection = snapped }
    }

    /// `chartXSelection` writes raw drag dates, so its binding snaps too.
    private var snappedSelection: Binding<Date?> {
        Binding(get: { selection }, set: { setSelection($0) })
    }

    /// The chart's bucket grid: local midnight, or top of the hour for 24h.
    /// Static so unit tests can pin the snapping rule.
    nonisolated static func snappedBucket(
        for date: Date, range: AgenticUseRange, calendar: Calendar
    ) -> Date? {
        range.bucketUnit == .day
            ? calendar.startOfDay(for: date)
            : calendar.dateInterval(of: .hour, for: date)?.start
    }

    /// The selection, only when that bucket exists in the plotted series.
    private func selectedBucket(in cells: [Cell]) -> Date? {
        guard let selection, cells.contains(where: { $0.bucket == selection }) else { return nil }
        return selection
    }

    // MARK: - Tooltip

    private func tooltip(for bucket: Date, cells: [Cell]) -> some View {
        let rows = cells.filter { $0.bucket == bucket }.sorted { $0.value > $1.value }
        let total = rows.reduce(0) { $0 + $1.value }
        return VStack(alignment: .leading, spacing: 8) {
            Text(tooltipDate(bucket))
                .scaledFont(size: 11, weight: .medium)
                .foregroundStyle(.secondary)
            HStack {
                Text("Total").scaledFont(size: 12, weight: .semibold)
                Spacer(minLength: 16)
                Text(formatted(total))
                    .scaledFont(size: 12, weight: .semibold)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: total))
            }
            Divider()
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Circle()
                        .fill(AgenticUseModelPalette.providerColor(for: row.provider))
                        .frame(width: 8, height: 8)
                    Text(row.provider.displayName).scaledFont(size: 11)
                    Spacer(minLength: 16)
                    Text(formatted(row.value))
                        .scaledFont(size: 11)
                        .monospacedDigit()
                        .foregroundStyle(row.value > 0 ? .primary : .tertiary)
                        .contentTransition(.numericText(value: row.value))
                }
            }
        }
        .padding(12)
        .frame(minWidth: 180, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.8), value: bucket)
    }

    private func tooltipDate(_ bucket: Date) -> String {
        if snapshot.range == .day {
            return bucket.formatted(.dateTime.month(.abbreviated).day().hour())
        }
        if effectiveGranularity == .weekly {
            return "Week of " + bucket.formatted(.dateTime.month(.abbreviated).day().year())
        }
        return bucket.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
    }
}
