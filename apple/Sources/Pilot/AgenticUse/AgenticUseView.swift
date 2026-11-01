import SwiftUI

/// Historical agent usage from local CLI logs and opted-in Cursor history.
///
/// Header bar over the scrolling `AgenticUseDashboard`. All aggregation
/// lives in `AgenticUsageStore` and `AgenticUseDerived`; views only draw.
struct AgenticUseView: View {
    @Bindable var store: AgenticUsageStore

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            if let warning = store.scanWarning {
                warningBanner(warning)
            }
            // Fill the remaining height so the header bar stays pinned to the
            // top: a ContentUnavailableView only takes its ideal height, and
            // the VStack would otherwise center the header with it.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let updated = store.cursorLastUpdated {
                Text("Cursor last updated \(updated.formatted(date: .abbreviated, time: .shortened))")
                    .agenticUseFont(.meta)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, LiquidGlassMetrics.Spacing.medium)
                    .padding(.vertical, LiquidGlassMetrics.Spacing.xSmall)
            }
        }
        .onAppear { store.start() }
        .onReceive(NotificationCenter.default.publisher(for: UsageConsent.changedNotification)) { _ in
            store.rescan()
        }
    }

    // MARK: - Header bar

    private var headerBar: some View {
        // The window toolbar already titles the page, so the bar leads with the
        // date range instead of repeating "Agentic Use".
        HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
            if let interval = store.snapshot?.interval {
                Text((interval.start..<interval.end).formatted(.interval.month(.abbreviated).day()))
                    .agenticUseFont(.body, weight: .medium)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }

            if store.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .transition(.opacity)
            }

            Spacer(minLength: LiquidGlassMetrics.Spacing.small)

            // The range picker and refresh are one control cluster: the
            // system segmented control is a capsule on 26+, and the circular
            // glass refresh blends with it inside one container.
            CompatGlassContainer(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                    Picker("Range", selection: $store.range) {
                        ForEach(AgenticUseRange.allCases) { range in
                            Text(range.label).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .labelsHidden()
                    .fixedSize()

                    Button {
                        store.rescan()
                    } label: {
                        Label("Refresh usage and pricing", systemImage: "arrow.clockwise")
                    }
                    .compatGlassIconButton(controlSize: .small)
                    .disabled(store.isRefreshing)
                    .help("Refresh usage and pricing")
                    .accessibilityLabel("Refresh usage and pricing")
                }
            }
        }
        .padding(.horizontal, LiquidGlassMetrics.Spacing.medium)
        .padding(.vertical, LiquidGlassMetrics.Spacing.xSmall)
        .animation(LiquidGlassMetrics.stateChange, value: store.isRefreshing)
    }

    /// An inset, rounded warning strip aligned with the dashboard cards. The
    /// orange wash is content (a status message), so it stays a tinted fill;
    /// only the dismiss control is glass.
    private func warningBanner(_ message: String) -> some View {
        HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .agenticUseFont(.body)
                .lineLimit(2)
            Spacer(minLength: LiquidGlassMetrics.Spacing.xSmall)
            Button {
                store.dismissScanWarning()
            } label: {
                Label("Dismiss warning", systemImage: "xmark")
            }
            .compatGlassIconButton(controlSize: .mini)
            .help("Dismiss")
            .accessibilityLabel("Dismiss warning")
        }
        .padding(.leading, LiquidGlassMetrics.Spacing.small)
        .padding(.trailing, LiquidGlassMetrics.Spacing.xSmall)
        .padding(.vertical, LiquidGlassMetrics.Spacing.xSmall)
        .background(
            Color.orange.opacity(0.12),
            in: RoundedRectangle(cornerRadius: AgenticUseLayout.cardRadius, style: .continuous)
        )
        .padding(.horizontal, AgenticUseLayout.gap)
        .padding(.bottom, LiquidGlassMetrics.Spacing.xxSmall)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle:
            scanningState(scanned: 0, total: 0)
        case .scanning(let scanned, let total):
            scanningState(scanned: scanned, total: total)
        case .empty:
            emptyState
        case .failed(let reason):
            failedState(reason)
        case .loaded:
            if let snapshot = store.snapshot {
                if snapshot.isEmpty {
                    rangeEmptyState
                } else {
                    dashboard(snapshot)
                }
            } else {
                scanningState(scanned: 0, total: 0)
            }
        }
    }

    private func dashboard(_ snapshot: AgenticUseSnapshot) -> some View {
        AgenticUseDashboard(snapshot: snapshot, pricingStatus: store.pricingStatus)
    }

    // MARK: - States

    /// A skeleton of the dashboard (KPI row + chart) with the scan progress
    /// in the chart slot, so the page keeps its shape while logs load
    /// (MOT-5) instead of showing a lone spinner on a blank pane.
    private func scanningState(scanned: Int, total: Int) -> some View {
        VStack(spacing: AgenticUseLayout.gap) {
            HStack(spacing: AgenticUseLayout.gap) {
                ForEach(0..<5, id: \.self) { _ in
                    AgenticUseSkeletonBlock()
                        .frame(height: 96)
                }
            }
            AgenticUseSkeletonBlock()
                .frame(minHeight: 240, maxHeight: 320)
                .overlay {
                    scanningProgress(scanned: scanned, total: total)
                }
            Spacer(minLength: 0)
        }
        .padding(AgenticUseLayout.gap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func scanningProgress(scanned: Int, total: Int) -> some View {
        VStack(spacing: LiquidGlassMetrics.Spacing.small) {
            if let progress = store.scanProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 240)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Text("Loading agent usage…")
                .agenticUseFont(.body)
                .foregroundStyle(.secondary)
            if total > 0 {
                Text("\(scanned.formatted()) of \(total.formatted()) files")
                    .agenticUseFont(.meta)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .padding(LiquidGlassMetrics.Spacing.medium)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Usage Data", systemImage: "chart.line.uptrend.xyaxis")
        } description: {
            VStack(spacing: LiquidGlassMetrics.Spacing.xxSmall) {
                Text("No usage was found for Claude Code, Codex, Cursor, Grok, or Kimi.")
                Text("Run an agent session, or enable Cursor usage in Settings.")
            }
        } actions: {
            Button("Rescan") { store.rescan() }
                .compatGlassProminentButtonStyle()
        }
    }

    private var rangeEmptyState: some View {
        ContentUnavailableView {
            Label("Nothing in This Range", systemImage: "calendar.badge.exclamationmark")
        } description: {
            Text("No usage recorded in the last \(rangeDescription).")
        } actions: {
            if store.range != .all {
                Button("Show All History") { store.range = .all }
                    .compatGlassProminentButtonStyle()
            }
        }
    }

    private var rangeDescription: String {
        switch store.range {
        case .day: "24 hours"
        case .all: "log history"
        default: "\(store.range.dayCount) days"
        }
    }

    private func failedState(_ reason: String) -> some View {
        ContentUnavailableView {
            Label("Can't Read Usage Logs", systemImage: "exclamationmark.triangle")
        } description: {
            Text(reason)
        } actions: {
            Button("Retry") { store.rescan() }
                .compatGlassProminentButtonStyle()
        }
    }
}

// MARK: - Shared card chrome

/// Dashboard spacing, radius, and type tokens. Spacing sits on the shared 4pt
/// grid (LAY-3) and cards use the shared card radius, so the dashboard matches
/// every other Liquid Glass surface.
enum AgenticUseLayout {
    static let cardPadding: CGFloat = LiquidGlassMetrics.Spacing.medium
    static let cardRadius: CGFloat = LiquidGlassMetrics.Radius.card
    /// Gap between cards and around the page.
    static let gap: CGFloat = LiquidGlassMetrics.Spacing.small

    /// The dashboard's five named text sizes (TYPE-4): display (KPI values),
    /// title (card headings), body, meta (supporting labels), and caption
    /// (axis labels). Every size follows Pilot's ⌘+/⌘- text zoom through
    /// `scaledFont`. Icon glyphs sized to their tiles are not text and keep
    /// their own sizes.
    enum TextStyle {
        case display
        case title
        case body
        case meta
        case caption

        var size: CGFloat {
            switch self {
            case .display: 26
            case .title: 14
            case .body: 12
            case .meta: 11
            case .caption: 10
            }
        }
    }
}

extension View {
    /// The dashboard's card treatment: a quiet `.quaternary` fill, no border.
    /// Cards are content, so they never take glass (glass is the control
    /// layer). The gaps between cards separate them; a hairline on every card
    /// made the page read as border soup (LAY-2). The card also declares its
    /// shape as the container shape, so concentric children nest (LAY-4).
    func agenticUseCard(minHeight: CGFloat? = nil, padding inset: CGFloat = AgenticUseLayout.cardPadding) -> some View {
        padding(inset)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .background(
                .quaternary.opacity(0.5),
                in: RoundedRectangle(cornerRadius: AgenticUseLayout.cardRadius, style: .continuous)
            )
            .liquidGlassContainerShape(cornerRadius: AgenticUseLayout.cardRadius)
    }

    /// Card heading: the title style every panel shares.
    func agenticUseCardTitle() -> some View {
        agenticUseFont(.title, weight: .semibold)
    }

    /// A named dashboard text style that scales with Pilot's text zoom.
    func agenticUseFont(
        _ style: AgenticUseLayout.TextStyle,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        scaledFont(size: style.size, weight: weight, design: design)
    }
}

/// One placeholder card in the loading skeleton: the card fill, breathing
/// slowly (held still with Reduce Motion).
private struct AgenticUseSkeletonBlock: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDimmed = false

    var body: some View {
        RoundedRectangle(cornerRadius: AgenticUseLayout.cardRadius, style: .continuous)
            .fill(.quaternary.opacity(0.5))
            .opacity(isDimmed ? 0.45 : 1)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                value: isDimmed
            )
            .onAppear { isDimmed = !reduceMotion }
            .accessibilityHidden(true)
    }
}

/// Shared presentation for live usage and deterministic product captures.
///
/// KPI cards across the top, the provider-stacked time series below, then
/// two columns — token flow and insights on the left, provider breakdown and
/// the Top Models table on the right — collapsing to one column when narrow.
struct AgenticUseDashboard: View {
    let snapshot: AgenticUseSnapshot
    let pricingStatus: String

    @State private var width: CGFloat = 1200

    private static let twoColumnWidth: CGFloat = 1080

    private var kpiColumns: Int {
        switch width {
        case 1000...: 5
        case 640...: 3
        default: 2
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: AgenticUseLayout.gap) {
                AgenticUseKPICards(snapshot: snapshot, columns: kpiColumns)
                AgenticUseDailyChartPanel(snapshot: snapshot)
                if width >= Self.twoColumnWidth {
                    HStack(alignment: .top, spacing: AgenticUseLayout.gap) {
                        VStack(spacing: AgenticUseLayout.gap) {
                            AgenticUseTokenFlowPanel(snapshot: snapshot)
                            insights
                        }
                        .frame(maxWidth: .infinity)
                        VStack(spacing: AgenticUseLayout.gap) {
                            AgenticUseProviderBreakdown(snapshot: snapshot)
                            AgenticUseTopModels(snapshot: snapshot)
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    AgenticUseTokenFlowPanel(snapshot: snapshot)
                    AgenticUseProviderBreakdown(snapshot: snapshot)
                    AgenticUseTopModels(snapshot: snapshot)
                    insights
                }
                footnote
            }
            .padding(AgenticUseLayout.gap)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            width = newWidth
        }
    }

    @ViewBuilder
    private var insights: some View {
        let insights = AgenticUseInsights.make(from: snapshot)
        if !insights.isEmpty {
            AgenticUseInsightsView(insights: insights)
        }
    }

    /// Costs are estimates; keep the pricing source and any unpriced gap
    /// visible on the page rather than buried in a tooltip.
    private var footnote: some View {
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xxSmall) {
            Text("Costs are API-equivalent estimates at published per-token rates. \(pricingStatus).")
            if snapshot.hasUnpricedModels {
                Text("* Partial total: \(AgenticUseFormat.tokens(snapshot.unpricedTokens)) tokens have no published rate.")
                    .foregroundStyle(.orange)
            }
        }
        // Secondary, not tertiary: the pricing caveat is content and has to
        // pass contrast at this size.
        .agenticUseFont(.meta)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, LiquidGlassMetrics.Spacing.xxSmall)
    }
}
