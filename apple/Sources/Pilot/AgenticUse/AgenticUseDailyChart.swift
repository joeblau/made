import Charts
import SwiftUI

/// The dashboard centerpiece: a stacked per-model chart of daily cost
/// (hourly for the 24h range) with a COST/TOKENS toggle and a hover tooltip.
///
/// Colors come from the snapshot's fixed `modelOrder` via
/// `AgenticUseModelPalette`, and the scale domain is built from the matching
/// `modelDisplayNames`, so the legend, stack order, and every other panel
/// stay in agreement as the range filter changes the visible series.
struct AgenticUseDailyChartPanel: View {
    let snapshot: AgenticUseSnapshot
    @Environment(\.uiZoom) private var uiZoom

    @State private var metric: Metric = .cost
    @State private var selection: Date?
    @State private var selectedModel: String = ""
    @State private var style: Style = .bars

    enum Style: String, CaseIterable, Identifiable {
        case bars = "Bars"
        case area = "Area"

        var id: String { rawValue }
    }

    enum Metric: String, CaseIterable, Identifiable {
        case cost = "Cost"
        case tokens = "Tokens"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    chartTitle
                    Spacer(minLength: 8)
                    chartControls
                }
                VStack(alignment: .leading, spacing: 8) {
                    chartTitle
                    chartControls
                }
            }
            HStack(spacing: 8) {
                Text("Model")
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                Picker("Model", selection: $selectedModel) {
                    Text("All models").tag("")
                    ForEach(snapshot.modelTotals) { model in
                        Text(model.displayName + (model.isUnpriced ? " (unpriced)" : ""))
                            .tag(model.model)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 280)
                .help(selectedModel.isEmpty ? "Select a model to inspect smaller values" : AgenticModel.displayName(for: selectedModel))
                Spacer(minLength: 0)
            }
            if visibleModels.isEmpty && metric == .cost {
                ContentUnavailableView(
                    "Pricing unavailable",
                    systemImage: "dollarsign.circle",
                    description: Text("Switch to Tokens to view this model’s usage.")
                )
                .frame(minHeight: 220)
            } else {
                legend
                chart
            }
            if metric == .cost && snapshot.hasUnpricedModels {
                Text("Models without pricing are excluded from cost; their usage is available in Tokens.")
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
            }
        }
        .agenticUseCard(minHeight: 280)
        .onChange(of: snapshot.modelOrder) { _, models in
            if !models.contains(selectedModel) { selectedModel = "" }
            selection = nil
        }
        .onChange(of: metric) { selection = nil }
        .onChange(of: selectedModel) { selection = nil }
    }

    private var title: String {
        let unit = snapshot.range == .day ? "Hourly" : "Daily"
        return metric == .cost ? "\(unit) cost" : "\(unit) tokens"
    }

    private var chartTitle: some View {
        Text(title)
            .scaledFont(size: 12, weight: .medium)
            .fixedSize()
    }

    private var chartControls: some View {
        HStack(spacing: 8) {
            Picker("Chart style", selection: $style) {
                ForEach(Style.allCases) { style in
                    Text(style.rawValue).tag(style)
                }
            }
            Picker("Metric", selection: $metric) {
                ForEach(Metric.allCases) { metric in
                    Text(metric.rawValue).tag(metric)
                }
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .labelsHidden()
        .fixedSize()
    }

    /// Charts' automatic legend can claim more width than the plot when many
    /// long model names are present. Constrain each entry to an adaptive column.
    private var legend: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 180 * uiZoom), spacing: 16, alignment: .leading)],
            alignment: .leading, spacing: 8
        ) {
            ForEach(visibleModels, id: \.self) { model in
                HStack(spacing: 6) {
                    Circle()
                        .fill(AgenticUseModelPalette.color(for: model))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(AgenticModel.displayName(for: model))
                        .scaledFont(size: 11)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(AgenticModel.displayName(for: model))
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Chart

    private var chart: some View {
        Chart {
            ForEach(visibleSeries) { point in
                if style == .bars {
                    BarMark(
                        x: .value("Day", point.day, unit: snapshot.range.bucketUnit),
                        y: .value(metric.rawValue, value(of: point)),
                        stacking: .standard
                    )
                    .foregroundStyle(by: .value("Model", point.displayName))
                } else {
                    AreaMark(
                        x: .value("Day", point.day, unit: snapshot.range.bucketUnit),
                        y: .value(metric.rawValue, value(of: point)),
                        series: .value("Model", point.displayName),
                        stacking: .standard
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(by: .value("Model", point.displayName))
                }
            }
            if let bucket = selectedBucket {
                RuleMark(x: .value("Day", bucket, unit: snapshot.range.bucketUnit))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(
                        position: .top,
                        alignment: .leading,
                        spacing: 8,
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                    ) {
                        tooltip(for: bucket)
                    }
            }
        }
        .chartForegroundStyleScale(domain: visibleModels.map(AgenticModel.displayName(for:)), range: seriesColors)
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
            AxisMarks(values: .automatic(desiredCount: snapshot.range == .quarter ? 6 : 5)) {
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel(format: xAxisFormat)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
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
        .frame(minHeight: 220)
    }

    private var visibleModels: [String] {
        snapshot.modelOrder.filter { model in
            (selectedModel.isEmpty || model == selectedModel)
                && (metric == .tokens || snapshot.modelTotals.contains { $0.model == model && !$0.isUnpriced })
        }
    }

    private var visibleSeries: [AgenticDailyPoint] {
        let models = Set(visibleModels)
        return snapshot.dailySeries.filter { models.contains($0.model) }
    }

    private var seriesColors: [Color] {
        visibleModels.map(AgenticUseModelPalette.color(for:))
    }

    private var xAxisFormat: Date.FormatStyle {
        snapshot.range == .day
            ? .dateTime.hour()
            : .dateTime.month(.abbreviated).day()
    }

    private func value(of point: AgenticDailyPoint) -> Double {
        metric == .cost ? point.cost : Double(point.tokens)
    }

    private func axisLabel(for number: Double) -> String {
        metric == .cost ? AgenticUseFormat.axisCost(number) : AgenticUseFormat.tokens(number)
    }

    // MARK: - Hover tooltip

    /// Hover and drag both land here snapped to the bucket grid, and only
    /// when the bucket changed — mouse-moves within one bucket would
    /// otherwise invalidate the chart body (and re-filter the whole series)
    /// at pointer-event rate.
    private func setSelection(_ raw: Date?) {
        let snapped = raw.flatMap {
            Self.snappedBucket(for: $0, range: snapshot.range, calendar: .current)
        }
        if selection != snapped { selection = snapped }
    }

    /// `chartXSelection` writes raw drag dates, so its binding snaps too.
    private var snappedSelection: Binding<Date?> {
        Binding(
            get: { selection },
            set: { setSelection($0) }
        )
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

    /// The snapped selection, and only when the bucket actually exists in
    /// the (zero-filled) series.
    private var selectedBucket: Date? {
        guard let selection,
              let bucket = Self.snappedBucket(for: selection, range: snapshot.range, calendar: .current),
              visibleSeries.contains(where: { $0.day == bucket }) else {
            return nil
        }
        return bucket
    }

    /// Most rows worth showing before the tooltip collapses the tail into a
    /// "+ n more" line — with every provider's models in one bucket the full
    /// list outgrows the chart's height.
    private static let tooltipRowLimit = 8

    private func tooltip(for bucket: Date) -> some View {
        let all = visibleSeries
            .filter { $0.day == bucket && value(of: $0) > 0 }
            .sorted { value(of: $0) > value(of: $1) }
        let total = all.reduce(0) { $0 + value(of: $1) }
        let points = Array(all.prefix(Self.tooltipRowLimit))
        let hiddenCount = all.count - points.count
        return VStack(alignment: .leading, spacing: 4) {
            Text(bucket, format: tooltipDateFormat)
                .scaledFont(size: 10, weight: .semibold)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            if points.isEmpty {
                Text("No usage")
                    .scaledFont(size: 10)
                    .foregroundStyle(.tertiary)
            } else {
                // Rows keep their model as identity across hover buckets so
                // values roll numerically instead of the row being rebuilt.
                ForEach(points, id: \.model) { point in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(AgenticUseModelPalette.color(for: point.model))
                            .frame(width: 7, height: 7)
                        Text(point.displayName)
                            .scaledFont(size: 10)
                        Spacer(minLength: 12)
                        Text(tooltipValue(value(of: point)))
                            .scaledFont(size: 10)
                            .monospacedDigit()
                            .contentTransition(.numericText(value: value(of: point)))
                    }
                }
                if hiddenCount > 0 {
                    Text("+ \(hiddenCount) more")
                        .scaledFont(size: 10)
                        .foregroundStyle(.tertiary)
                        .contentTransition(.numericText(value: Double(hiddenCount)))
                }
                HStack(spacing: 6) {
                    Text(selectedModel.isEmpty ? "Total" : "Model total")
                        .scaledFont(size: 10, weight: .medium)
                    Spacer(minLength: 12)
                    Text(tooltipValue(total))
                        .scaledFont(size: 10, weight: .medium)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: total))
                }
            }
        }
        .padding(8)
        .frame(minWidth: 150, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        // One animation context drives both the numeric transitions above and
        // the box growing/shrinking as the row count changes per bucket.
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.8), value: bucket)
    }

    private var tooltipDateFormat: Date.FormatStyle {
        snapshot.range == .day
            ? .dateTime.month(.abbreviated).day().hour()
            : .dateTime.weekday(.abbreviated).month(.abbreviated).day()
    }

    private func tooltipValue(_ number: Double) -> String {
        metric == .cost ? AgenticUseFormat.cost(number) : AgenticUseFormat.tokens(number)
    }
}
