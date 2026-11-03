import Charts
import SwiftUI

/// The dashboard centerpiece: per-provider stacked cost, tokens, or cache
/// savings over the range (hourly for 24h, daily or weekly otherwise), with a
/// hover tooltip and a share legend of capsule filter chips that isolates a
/// provider on click.
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
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.small) {
            header
            if cells.allSatisfy({ $0.value == 0 }) {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: "chart.xyaxis.line",
                    description: Text(emptyDescription)
                )
                .legibleSecondaryHierarchy()
                .frame(height: 280)
            } else {
                chart(cells)
                    .frame(height: 280)
            }
            legend
        }
        .agenticUseCard()
        .onChange(of: snapshot.range) { _, range in
            if !Self.offersWeekly(range) { granularity = .daily }
            selection = nil
        }
        .onChange(of: metric) { selection = nil }
        .onChange(of: style) { selection = nil }
        .onChange(of: granularity) { selection = nil }
        .onChange(of: snapshot.providerTotals.map(\.provider)) { _, providers in
            if let isolated, !providers.contains(isolated) { self.isolated = nil }
        }
    }

    // MARK: - Header

    private static let titleUnits = ["Hourly", "Daily", "Weekly"]

    private var title: String {
        let unit = switch (snapshot.range.bucketUnit, effectiveGranularity) {
        case (.hour, _): "Hourly"
        case (_, .weekly): "Weekly"
        default: "Daily"
        }
        return Self.title(unit: unit, metric: metric)
    }

    private static func title(unit: String, metric: Metric) -> String {
        "\(unit) \(metric == .savings ? "Cache Savings" : metric.rawValue)"
    }

    /// Holds the width of the longest possible title, so the segmented picker
    /// beside it stays put when the metric, range, or granularity changes. A
    /// title sized to fit moved the picker up to 68pt, out from under the
    /// pointer that had just clicked it.
    private var titleLabel: some View {
        ZStack(alignment: .leading) {
            ForEach(Self.titleUnits, id: \.self) { unit in
                ForEach(Metric.allCases) { candidate in
                    Text(Self.title(unit: unit, metric: candidate)).hidden()
                }
            }
            .accessibilityHidden(true)
            Text(title)
        }
        .agenticUseCardTitle()
        .fixedSize()
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: LiquidGlassMetrics.Spacing.small) {
                titleLabel
                metricPicker
                Spacer(minLength: LiquidGlassMetrics.Spacing.xSmall)
                trailingControls
            }
            VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xSmall) {
                HStack(spacing: LiquidGlassMetrics.Spacing.small) {
                    Text(title).agenticUseCardTitle().fixedSize()
                    Spacer(minLength: LiquidGlassMetrics.Spacing.xSmall)
                    trailingControls
                }
                metricPicker
            }
        }
    }

    /// No press lift: AppKit's press tracking grows the glass pill past the
    /// control's bounds, so the picker appeared to change height on click.
    private var metricPicker: some View {
        PilotSegmentedControl(
            "Metric",
            selection: $metric,
            options: Metric.allCases,
            title: { $0.rawValue },
            controlSize: .small,
            liftsOnPress: false
        )
        .fixedSize()
    }

    /// Secondary glass capsules beside the title. A plain menu `Picker` is an
    /// unglazed pop-up button on macOS 26+, so each is a glass `Menu` holding
    /// an inline picker (checkmarked choices); one container blends the pair.
    private var trailingControls: some View {
        CompatGlassContainer(spacing: LiquidGlassMetrics.Spacing.xSmall) {
            HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                if Self.offersWeekly(snapshot.range) {
                    glassMenuPicker("Granularity", selection: $granularity)
                }
                glassMenuPicker("Chart style", selection: $style)
            }
        }
        .controlSize(.small)
    }

    private func glassMenuPicker<Option: RawRepresentable<String> & CaseIterable & Identifiable & Hashable>(
        _ title: String,
        selection: Binding<Option>
    ) -> some View where Option.AllCases: RandomAccessCollection {
        Menu {
            Picker(title, selection: selection) {
                ForEach(Option.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(selection.wrappedValue.rawValue)
        }
        .menuStyle(.button)
        .compatGlassButtonStyle()
        .fixedSize()
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(selection.wrappedValue.rawValue)
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
                ZStack(alignment: .topLeading) {
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
                    // The tooltip lives in the overlay, not in a chart
                    // annotation: Swift Charts flattens annotation content,
                    // so glass there rendered as a faint empty box with no
                    // text. Here it is an ordinary view with a real backdrop.
                    if let selected, let plotFrame = proxy.plotFrame,
                       let ruleX = ruleX(for: selected, proxy: proxy) {
                        let frame = geometry[plotFrame]
                        let x = frame.minX + ruleX
                        let opensTrailing = x < frame.midX
                        tooltip(for: selected, cells: cells)
                            .fixedSize()
                            .alignmentGuide(.leading) { size in
                                opensTrailing
                                    ? -(x + LiquidGlassMetrics.Spacing.xSmall)
                                    : size.width - (x - LiquidGlassMetrics.Spacing.xSmall)
                            }
                            .alignmentGuide(.top) { _ in -frame.minY }
                            .allowsHitTesting(false)
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
                    // No extra `.secondary`: the axis label already draws in
                    // a secondary style, and dimming it again left the y
                    // labels at about 1.9:1 against the card (TYPE-3).
                    if let number = value.as(Double.self) {
                        Text(axisLabel(for: number))
                            .agenticUseFont(.caption)
                            .monospacedDigit()
                    }
                }
            }
        }
        .id(style)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.25), value: style)
        .animation(.easeInOut(duration: 0.25), value: metric)
    }

    /// The rule's x within the plot area. Marks with a date `unit` sit at the
    /// middle of their bucket, so the tooltip anchors there too.
    private func ruleX(for bucket: Date, proxy: ChartProxy) -> CGFloat? {
        guard let start = proxy.position(forX: bucket) else { return nil }
        guard let end = Calendar.current.date(byAdding: bucketUnit, value: 1, to: bucket),
              let endX = proxy.position(forX: end) else { return start }
        return (start + endX) / 2
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

    /// Shares of the whole range for the current metric, as capsule filter
    /// chips. Clicking a chip isolates that provider (the chip takes the
    /// selected tint); clicking it again restores the stack. Falls back to a
    /// horizontal scroller when the card is too narrow for one row.
    private var legend: some View {
        let shares = legendShares
        return ViewThatFits(in: .horizontal) {
            legendChips(shares)
                .frame(maxWidth: .infinity)
            ScrollView(.horizontal, showsIndicators: false) {
                legendChips(shares)
            }
        }
    }

    private func legendChips(_ shares: [(provider: AgenticProvider, share: Double)]) -> some View {
        CompatGlassContainer(spacing: LiquidGlassMetrics.Spacing.xSmall) {
            HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                ForEach(shares, id: \.provider) { entry in
                    legendChip(entry)
                }
            }
        }
    }

    private func legendChip(_ entry: (provider: AgenticProvider, share: Double)) -> some View {
        let isIsolated = isolated == entry.provider
        return Button {
            withAnimation(LiquidGlassMetrics.spring) {
                isolated = isIsolated ? nil : entry.provider
            }
        } label: {
            HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                Circle()
                    .fill(AgenticUseModelPalette.providerColor(for: entry.provider))
                    .frame(width: 8, height: 8)
                Text(entry.provider.displayName)
                    .agenticUseFont(.body, weight: .medium)
                    .foregroundStyle(.primary)
                Text(AgenticUseFormat.percent(entry.share))
                    .agenticUseFont(.body)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .opacity(isolated == nil || isIsolated ? 1 : 0.5)
        }
        .buttonStyle(.liquidGlassChip(isSelected: isIsolated))
        .help(isIsolated ? "Show all providers" : "Show only \(entry.provider.displayName)")
        .accessibilityAddTraits(isIsolated ? .isSelected : [])
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
        return VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xSmall) {
            Text(tooltipDate(bucket))
                .agenticUseFont(.meta, weight: .medium)
                .foregroundStyle(.secondary)
            HStack {
                Text("Total").agenticUseFont(.body, weight: .semibold)
                Spacer(minLength: LiquidGlassMetrics.Spacing.medium)
                Text(formatted(total))
                    .agenticUseFont(.body, weight: .semibold)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: total))
            }
            Divider()
            ForEach(rows) { row in
                HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                    Circle()
                        .fill(AgenticUseModelPalette.providerColor(for: row.provider))
                        .frame(width: 8, height: 8)
                    Text(row.provider.displayName).agenticUseFont(.meta)
                    Spacer(minLength: LiquidGlassMetrics.Spacing.medium)
                    Text(formatted(row.value))
                        .agenticUseFont(.meta)
                        .monospacedDigit()
                        .foregroundStyle(row.value > 0 ? .primary : .tertiary)
                        .contentTransition(.numericText(value: row.value))
                }
            }
        }
        .padding(LiquidGlassMetrics.Spacing.small)
        .frame(minWidth: 180, alignment: .leading)
        // The tooltip floats over the plot, so it is the one glass surface on
        // this card (control layer, not content). Glass draws its own edge, so
        // the old hairline stroke is gone (LAY-2).
        .compatFloatingGlass(
            in: RoundedRectangle(cornerRadius: LiquidGlassMetrics.Radius.field, style: .continuous)
        )
        .animation(LiquidGlassMetrics.spring, value: bucket)
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
