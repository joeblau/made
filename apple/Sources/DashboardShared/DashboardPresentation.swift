import Foundation
import SwiftUI
import WidgetKit

public struct ActionsDashboardWidgetView: View {
    @Environment(\.widgetFamily) private var family
    private let snapshot: ActionsDashboardSnapshot?

    public init(snapshot: ActionsDashboardSnapshot?) {
        self.snapshot = snapshot
    }

    public var body: some View {
        DashboardWidgetFrame(
            title: DashboardFamily.actions.title,
            systemImage: "arrow.triangle.2.circlepath",
            tint: .blue,
            updatedAt: snapshot?.updatedAt,
            isStale: snapshot?.isStale(at: Date().timeIntervalSince1970) == true
        ) {
            if let snapshot, !snapshot.runs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    let activeCount = snapshot.runs.filter(\.isActive).count
                    let failedCount = snapshot.runs.filter(\.isFailure).count
                    // Totals stay neutral; a state color appears only when that
                    // state is present, and matches the run-row glyph colors.
                    let runs = DashboardMetric(value: snapshot.runs.count, label: "Runs")
                    let active = DashboardMetric(value: activeCount, label: "Active", tint: activeCount > 0 ? .blue : nil)
                    let failed = DashboardMetric(value: failedCount, label: "Failed", tint: failedCount > 0 ? .red : nil)
                    if family == .systemSmall {
                        // A small widget has room for two labeled columns; the
                        // run total is the one that can go.
                        HStack(spacing: 8) { active; failed }
                    } else {
                        // One row of columns while every label fits; at
                        // accessibility sizes, wrap to a grid instead of
                        // truncating a label.
                        ViewThatFits(in: .horizontal) {
                            DashboardMetricColumns(spacing: 8) { runs; active; failed }
                            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                                GridRow { runs; active }
                                GridRow { failed }
                            }
                        }
                    }
                    ForEach(snapshot.runs.prefix(rowLimit), id: \.id) { run in
                        DashboardRunRow(run: run, detail: DashboardRowDetail(family))
                    }
                }
            } else {
                DashboardEmptyView(title: "No Actions yet", detail: "Runs from open workspaces will appear here.")
            }
        }
    }

    // Sized so header, metrics, rows, and timestamp fit each family on the
    // smallest iPhone/iPad widget canvases without clipping the last row.
    private var rowLimit: Int {
        switch family {
        case .systemSmall: 1
        case .systemLarge: 5
        default: 2
        }
    }
}

public struct UsageDashboardWidgetView: View {
    @Environment(\.widgetFamily) private var family
    private let snapshot: UsageDashboardSnapshot?

    public init(snapshot: UsageDashboardSnapshot?) {
        self.snapshot = snapshot
    }

    public var body: some View {
        DashboardWidgetFrame(
            title: DashboardFamily.usage.title,
            systemImage: "sparkles",
            tint: .purple,
            updatedAt: snapshot?.updatedAt,
            isStale: snapshot?.isStale(at: Date().timeIntervalSince1970) == true
        ) {
            if let snapshot {
                VStack(alignment: .leading, spacing: 8) {
                    // Keep cost and tokens on one baseline when they fit; a
                    // small widget stacks them instead of truncating tokens.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            usageCost(snapshot)
                            usageTokens(snapshot)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            usageCost(snapshot)
                            usageTokens(snapshot)
                        }
                    }
                    if snapshot.hasUnpricedModels {
                        DashboardWarningLabel(text: "Partial estimate · unpriced models", systemImage: "exclamationmark.triangle.fill")
                    } else {
                        Text("Estimated cost")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(snapshot.providers.prefix(rowLimit), id: \.id) { provider in
                        DashboardProviderRow(provider: provider, detail: DashboardRowDetail(family))
                    }
                    if snapshot.providers.isEmpty {
                        Text("No provider summaries")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                DashboardEmptyView(title: "No AI usage yet", detail: "Aggregate cost and token totals will appear here.")
            }
        }
    }

    private var rowLimit: Int {
        switch family {
        case .systemSmall: 1
        case .systemLarge: 5
        default: 2
        }
    }

    private func usageCost(_ snapshot: UsageDashboardSnapshot) -> some View {
        Text(DashboardFormat.cost(snapshot.estimatedCost))
            .font(family == .systemSmall ? .title2 : .title)
            .fontWeight(.semibold)
            .monospacedDigit()
            .contentTransition(.numericText(value: snapshot.estimatedCost))
            .minimumScaleFactor(0.7)
            .lineLimit(1)
            .widgetAccentable()
    }

    private func usageTokens(_ snapshot: UsageDashboardSnapshot) -> some View {
        Text("\(DashboardFormat.tokens(snapshot.totalTokens)) tokens")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }
}

public struct RunnersDashboardWidgetView: View {
    @Environment(\.widgetFamily) private var family
    private let snapshot: RunnersDashboardSnapshot?

    public init(snapshot: RunnersDashboardSnapshot?) {
        self.snapshot = snapshot
    }

    public var body: some View {
        DashboardWidgetFrame(
            title: snapshot?.enterpriseName.isEmpty == false ? snapshot!.enterpriseName : DashboardFamily.runners.title,
            systemImage: "server.rack",
            tint: .blue,
            updatedAt: snapshot?.updatedAt,
            isStale: snapshot?.isStale(at: Date().timeIntervalSince1970) == true
        ) {
            if let snapshot {
                VStack(alignment: .leading, spacing: 8) {
                    let fleet = DashboardMetric(value: snapshot.totalCount, label: "Fleet")
                    let idle = DashboardMetric(value: snapshot.idleCount, label: "Idle", tint: snapshot.idleCount > 0 ? .green : nil)
                    let busy = DashboardMetric(value: snapshot.busyCount, label: "Busy", tint: snapshot.busyCount > 0 ? .orange : nil)
                    let offline = DashboardMetric(value: snapshot.offlineCount, label: "Offline", tint: snapshot.offlineCount > 0 ? .red : nil)
                    // Four columns don't fit a small widget without wrapping
                    // "Offline"; use a 2 x 2 grid there instead.
                    // The same grid takes over in wider families once the
                    // labels no longer fit one row (accessibility sizes).
                    let grid = Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                        GridRow { fleet; idle }
                        GridRow { busy; offline }
                    }
                    if family == .systemSmall {
                        grid
                    } else {
                        ViewThatFits(in: .horizontal) {
                            DashboardMetricColumns(spacing: 12) { fleet; idle; busy; offline }
                            grid
                        }
                    }
                    ForEach(snapshot.runners.prefix(rowLimit), id: \.id) { runner in
                        DashboardRunnerRow(runner: runner, detail: DashboardRowDetail(family))
                    }
                    if snapshot.runners.isEmpty {
                        Text("No runners in the sample")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                DashboardEmptyView(title: "No runner data", detail: "Enterprise fleet status will appear here.")
            }
        }
    }

    private var rowLimit: Int {
        switch family {
        // The 2 x 2 metric grid fills a small widget; rows start at medium.
        case .systemSmall: 0
        case .systemLarge: 5
        default: 2
        }
    }
}

public struct ActionsDashboardActivityCard: View {
    private let projection: ActionsDashboardActivityProjection
    private let isStale: Bool
    private let compact: Bool
    private let islandExpanded: Bool
    /// The Lock Screen banner: a fixed 160pt-tall card, so the row list is
    /// trimmed to what fits under the header and any status lines.
    private let lockScreen: Bool

    /// - Parameter islandExpanded: The expanded Dynamic Island's bottom
    ///   region, whose leading/trailing regions already show the family title
    ///   and headline count. Drops the duplicate header, trades the card
    ///   padding for a corner-clearance inset, and caps the list at
    ///   ``DashboardActivityLayout/islandRowLimit`` single-line rows so
    ///   nothing clips at the Island's fixed height.
    public init(
        projection: ActionsDashboardActivityProjection,
        isStale: Bool = false,
        compact: Bool = false,
        islandExpanded: Bool = false,
        lockScreen: Bool = false
    ) {
        self.projection = projection
        self.isStale = isStale
        self.compact = compact
        self.islandExpanded = islandExpanded
        self.lockScreen = lockScreen
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DashboardActivityLayout.spacing(compact: compact)) {
            if !islandExpanded {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.blue)
                        .widgetAccentable()
                    Text("Actions")
                        .font(.headline)
                    Spacer()
                    Text("\(projection.activeCount) active · \(projection.runCount) runs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if isStale {
                DashboardStaleLabel()
            }
            if !compact {
                ForEach(DashboardActivityLayout.rows(
                    projection.runs, islandExpanded: islandExpanded,
                    lockScreenStatusLines: lockScreen ? (isStale ? 1 : 0) : nil
                ), id: \.id) { run in
                    DashboardRunRow(run: run, detail: DashboardActivityLayout.rowDetail(islandExpanded: islandExpanded))
                }
            }
        }
        .padding(DashboardActivityLayout.padding(compact: compact, islandExpanded: islandExpanded))
    }
}

public struct UsageDashboardActivityCard: View {
    private let projection: UsageDashboardActivityProjection
    private let isStale: Bool
    private let compact: Bool
    private let islandExpanded: Bool
    /// The Lock Screen banner: a fixed 160pt-tall card, so the row list is
    /// trimmed to what fits under the header and any status lines.
    private let lockScreen: Bool

    /// - Parameter islandExpanded: The expanded Dynamic Island's bottom
    ///   region, whose leading/trailing regions already show the family title
    ///   and headline count. Drops the duplicate header, trades the card
    ///   padding for a corner-clearance inset, and caps the list at
    ///   ``DashboardActivityLayout/islandRowLimit`` single-line rows so
    ///   nothing clips at the Island's fixed height.
    public init(
        projection: UsageDashboardActivityProjection,
        isStale: Bool = false,
        compact: Bool = false,
        islandExpanded: Bool = false,
        lockScreen: Bool = false
    ) {
        self.projection = projection
        self.isStale = isStale
        self.compact = compact
        self.islandExpanded = islandExpanded
        self.lockScreen = lockScreen
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DashboardActivityLayout.spacing(compact: compact)) {
            if !islandExpanded {
                usageHeader
            }
            if projection.hasUnpricedModels {
                DashboardWarningLabel(text: "Partial estimate · unpriced models", systemImage: "exclamationmark.triangle.fill")
            }
            if isStale {
                DashboardStaleLabel()
            }
            if !compact {
                ForEach(DashboardActivityLayout.rows(
                    projection.providers, islandExpanded: islandExpanded,
                    lockScreenStatusLines: lockScreen
                        ? (isStale ? 1 : 0) + (projection.hasUnpricedModels ? 1 : 0) : nil
                ), id: \.id) { provider in
                    DashboardProviderRow(provider: provider, detail: DashboardActivityLayout.rowDetail(islandExpanded: islandExpanded))
                }
            }
        }
        .padding(DashboardActivityLayout.padding(compact: compact, islandExpanded: islandExpanded))
    }

    private var usageHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.purple)
                .widgetAccentable()
            Text("AI Usage")
                .font(.headline)
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text(DashboardFormat.cost(projection.estimatedCost))
                    .font(.headline)
                    .monospacedDigit()
                Text("\(DashboardFormat.tokens(projection.totalTokens)) tokens")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

public struct RunnersDashboardActivityCard: View {
    private let projection: RunnersDashboardActivityProjection
    private let isStale: Bool
    private let compact: Bool
    private let islandExpanded: Bool
    /// The Lock Screen banner: a fixed 160pt-tall card, so the row list is
    /// trimmed to what fits under the header and any status lines.
    private let lockScreen: Bool

    /// - Parameter islandExpanded: The expanded Dynamic Island's bottom
    ///   region, whose leading/trailing regions already show the family title
    ///   and headline count. Drops the duplicate header, trades the card
    ///   padding for a corner-clearance inset, and caps the list at
    ///   ``DashboardActivityLayout/islandRowLimit`` single-line rows so
    ///   nothing clips at the Island's fixed height.
    public init(
        projection: RunnersDashboardActivityProjection,
        isStale: Bool = false,
        compact: Bool = false,
        islandExpanded: Bool = false,
        lockScreen: Bool = false
    ) {
        self.projection = projection
        self.isStale = isStale
        self.compact = compact
        self.islandExpanded = islandExpanded
        self.lockScreen = lockScreen
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DashboardActivityLayout.spacing(compact: compact)) {
            if !islandExpanded {
                HStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .foregroundStyle(.blue)
                        .widgetAccentable()
                    Text(projection.enterpriseName.isEmpty ? "Runners" : projection.enterpriseName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text("\(projection.idleCount) idle / \(projection.totalCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            // State colors live on the glyphs; the counts stay secondary text
            // so caption-size copy keeps contrast in both modes.
            HStack(spacing: 12) {
                DashboardStatusLabel(
                    text: "\(projection.busyCount) busy",
                    systemImage: "gearshape.2",
                    tint: projection.busyCount > 0 ? .orange : .secondary
                )
                DashboardStatusLabel(
                    text: "\(projection.offlineCount) offline",
                    systemImage: "xmark.circle.fill",
                    tint: projection.offlineCount > 0 ? .red : .secondary
                )
            }
            if isStale {
                DashboardStaleLabel()
            }
            if !compact {
                // The busy/offline line always shows, so it counts as one.
                ForEach(DashboardActivityLayout.rows(
                    projection.runners, islandExpanded: islandExpanded,
                    lockScreenStatusLines: lockScreen ? 1 + (isStale ? 1 : 0) : nil
                ), id: \.id) { runner in
                    DashboardRunnerRow(runner: runner, detail: DashboardActivityLayout.rowDetail(islandExpanded: islandExpanded))
                }
            }
        }
        .padding(DashboardActivityLayout.padding(compact: compact, islandExpanded: islandExpanded))
    }
}

/// Shared sizing for the three Live Activity cards across their Lock Screen,
/// small (Watch Smart Stack / CarPlay), and expanded Dynamic Island layouts.
enum DashboardActivityLayout {
    /// Rows that fit the expanded Island's bottom region below its
    /// leading/trailing header without clipping.
    static let islandRowLimit = 2

    static func spacing(compact: Bool) -> CGFloat { compact ? 4 : 8 }

    /// The Island supplies its own outer margins, but its bottom corners are
    /// tightly curved: the last row needs a little inset so leading glyphs
    /// and trailing status text clear the curve instead of clipping.
    static func padding(compact: Bool, islandExpanded: Bool) -> EdgeInsets {
        if islandExpanded { return EdgeInsets(top: 0, leading: 8, bottom: 8, trailing: 8) }
        let inset: CGFloat = compact ? 8 : 16
        return EdgeInsets(top: inset, leading: inset, bottom: inset, trailing: inset)
    }

    static func rowDetail(islandExpanded: Bool) -> DashboardRowDetail {
        islandExpanded ? .inline : .stacked
    }

    /// Two-line rows that fit the 160pt Lock Screen card under its header
    /// when no status line is showing.
    static let lockScreenRowLimit = 2

    /// - Parameter lockScreenStatusLines: On the Lock Screen, how many status
    ///   lines (stale, partial estimate, busy/offline) sit above the rows;
    ///   each one costs a row, down to one. `nil` elsewhere (the in-app
    ///   panels show every row). Without this the Runners card ran past the
    ///   fixed card height and lost its top and bottom padding (LAY-3).
    static func rows<Row>(_ rows: [Row], islandExpanded: Bool, lockScreenStatusLines: Int? = nil) -> [Row] {
        if islandExpanded { return Array(rows.prefix(islandRowLimit)) }
        if let lines = lockScreenStatusLines {
            return Array(rows.prefix(max(1, lockScreenRowLimit - lines)))
        }
        return rows
    }
}

/// How much secondary detail a list row shows: none in a small widget, on
/// the same line in a medium widget, and on a second line where height allows.
enum DashboardRowDetail {
    case hidden
    case inline
    case stacked

    init(_ family: WidgetFamily) {
        switch family {
        case .systemSmall: self = .hidden
        case .systemMedium: self = .inline
        default: self = .stacked
        }
    }
}

private struct DashboardWidgetFrame<Content: View>: View {
    @Environment(\.widgetFamily) private var family
    let title: String
    let systemImage: String
    let tint: Color
    let updatedAt: Double?
    let isStale: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if family == .systemSmall {
                titleLabel
            } else {
                // Wider families carry freshness in the header, trailing, so
                // the vertical space goes to rows instead of a footer line.
                // When both no longer fit on one line (accessibility sizes in
                // the in-app dashboards), freshness drops below the title
                // instead of truncating the title away (HIER-3).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        titleLabel
                        Spacer(minLength: 8)
                        freshness
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        titleLabel
                        freshness
                    }
                }
            }
            content
            Spacer(minLength: 0)
            if family == .systemSmall {
                freshness
            }
        }
    }

    /// The family glyph joins the accent group so tinted and vibrant
    /// rendering modes keep one colored anchor per widget.
    private var titleLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .widgetAccentable()
            Text(title)
                .font(.headline)
                .lineLimit(1)
        }
    }

    /// Staleness is reported once, in place of the timestamp, rather than in
    /// both the header and the footer.
    @ViewBuilder
    private var freshness: some View {
        if isStale {
            DashboardWarningLabel(text: "Updates delayed", systemImage: "wifi.slash")
        } else {
            Text(footerText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }

    private var footerText: String {
        guard let updatedAt else { return "Open the app to sync" }
        let relative = Date(timeIntervalSince1970: updatedAt)
            .formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
        return "Updated \(relative)"
    }
}

private struct DashboardMetric: View {
    let value: Int
    let label: String
    /// A state color, or `nil` for a neutral total / an absent state.
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(value)")
                .font(.headline)
                .monospacedDigit()
                // Timeline reloads roll the count instead of hard-cutting (MOT-4).
                .contentTransition(.numericText(value: Double(value)))
                .foregroundStyle(tint ?? Color.primary)
                .lineLimit(1)
                .widgetAccentable()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Equal-width metric columns, laid out like an `HStack` of
/// `.frame(maxWidth: .infinity)` cells. Unlike that stack, its ideal width is
/// what equal columns really need (widest cell × count), so the
/// `ViewThatFits` around it switches to the grid before any label truncates.
private struct DashboardMetricColumns: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let gaps = spacing * CGFloat(subviews.count - 1)
        let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let needed = widest * CGFloat(subviews.count) + gaps
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? needed
        let column = columnWidth(in: width, count: subviews.count)
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let column = columnWidth(in: bounds.width, count: subviews.count)
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + CGFloat(index) * (column + spacing), y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: column, height: bounds.height)
            )
        }
    }

    private func columnWidth(in width: CGFloat, count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return max(0, (width - spacing * CGFloat(count - 1)) / CGFloat(count))
    }
}

/// A caution line: the glyph carries the orange signal, the copy stays
/// secondary text so caption sizes keep contrast in light and dark mode.
private struct DashboardWarningLabel: View {
    let text: String
    let systemImage: String

    var body: some View {
        DashboardStatusLabel(text: text, systemImage: systemImage, tint: .orange)
    }
}

private struct DashboardStatusLabel: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label {
            Text(text)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
        .font(.caption2)
        .lineLimit(1)
    }
}

private struct DashboardEmptyView: View {
    @Environment(\.widgetFamily) private var family
    let title: String
    let detail: String

    var body: some View {
        if family == .systemLarge {
            // A large widget is mostly empty space before the first sync:
            // anchor the message with a glyph and sit it in the middle of
            // that space instead of a two-line note under the header with
            // three quarters of the widget blank (MOT-6, HIER-3). Text stays
            // leading-aligned (TYPE-1).
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "tray")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                message
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            message
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var message: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct DashboardRunRow: View {
    let run: ActionsDashboardRun
    let detail: DashboardRowDetail

    var body: some View {
        DashboardRowFit(detail: detail) { showsSubtitle in
            HStack(spacing: 8) {
                DashboardRowGlyph(systemName: run.systemImage, tint: run.dashboardTint)
                    // Speaks the status when the visible status text is hidden.
                    .accessibilityLabel(run.label)
                    .accessibilityHidden(detail != .hidden)
                DashboardRowText(
                    title: run.workflow.isEmpty ? "Workflow" : run.workflow,
                    subtitle: showsSubtitle ? "\(run.repository) · \(run.branch)" : nil,
                    detail: detail
                )
                Spacer(minLength: 4)
                // In a small widget the status glyph alone carries the state so
                // the workflow name keeps the width.
                if detail != .hidden {
                    Text(run.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

private struct DashboardProviderRow: View {
    let provider: UsageDashboardProviderSummary
    let detail: DashboardRowDetail

    var body: some View {
        DashboardRowFit(detail: detail) { showsSubtitle in
            HStack(spacing: 8) {
                DashboardRowText(
                    title: provider.name.isEmpty ? "Provider" : provider.name,
                    subtitle: showsSubtitle ? utilizationText : nil,
                    detail: detail
                )
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(DashboardFormat.cost(provider.estimatedCost))
                        .font(.caption)
                        .monospacedDigit()
                    if detail == .stacked {
                        Text(DashboardFormat.tokens(provider.totalTokens))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var utilizationText: String? {
        if let value = provider.window?.utilization {
            return "\(provider.windowName ?? "Window") · \(DashboardFormat.percent(value))"
        }
        if let value = provider.plan?.utilization {
            return "\(provider.planName ?? "Plan") · \(DashboardFormat.percent(value))"
        }
        return nil
    }
}

private struct DashboardRunnerRow: View {
    let runner: RunnersDashboardRunner
    let detail: DashboardRowDetail

    var body: some View {
        DashboardRowFit(detail: detail) { showsSubtitle in
            HStack(spacing: 8) {
                DashboardRowGlyph(systemName: runner.systemImage, tint: runner.dashboardTint)
                DashboardRowText(
                    title: runner.name.isEmpty ? "Runner \(runner.id)" : runner.name,
                    subtitle: showsSubtitle && !runner.operatingSystem.isEmpty ? runner.operatingSystem : nil,
                    detail: detail
                )
                Spacer(minLength: 4)
                Text(runner.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// A row's state glyph, fitted into a square that scales with the row text.
/// Wide symbols (`gearshape.2`) shrink to the column instead of spilling into
/// the title, so every row's title starts on the same edge at every Dynamic
/// Type size.
private struct DashboardRowGlyph: View {
    let systemName: String
    let tint: Color
    @ScaledMetric(relativeTo: .caption) private var side: CGFloat = 16

    var body: some View {
        Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .foregroundStyle(tint)
            .frame(width: side, height: side)
    }
}

/// Lays out a whole row with its subtitle, and for ``DashboardRowDetail/inline``
/// rows falls back to the title alone when the full row no longer fits on one
/// line (long names, accessibility sizes). Measuring the complete row, rather
/// than the title text inside it, keeps the subtitle from being squeezed to a
/// bare ellipsis beside the trailing status.
private struct DashboardRowFit<Row: View>: View {
    let detail: DashboardRowDetail
    @ViewBuilder let row: (_ showsSubtitle: Bool) -> Row

    var body: some View {
        if detail == .inline {
            ViewThatFits(in: .horizontal) {
                row(true)
                row(false)
            }
        } else {
            row(true)
        }
    }
}

/// A row's title plus optional secondary line, laid out per ``DashboardRowDetail``.
private struct DashboardRowText: View {
    let title: String
    let subtitle: String?
    let detail: DashboardRowDetail

    var body: some View {
        switch detail {
        case .stacked:
            VStack(alignment: .leading, spacing: 1) {
                titleText
                subtitleText
            }
        case .inline:
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                titleText
                    .layoutPriority(1)
                subtitleText
            }
        case .hidden:
            titleText
        }
    }

    private var titleText: some View {
        Text(title)
            .font(.caption)
            .fontWeight(.medium)
            .lineLimit(1)
    }

    @ViewBuilder
    private var subtitleText: some View {
        if let subtitle {
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct DashboardStaleLabel: View {
    var body: some View {
        DashboardWarningLabel(text: "Updates delayed · showing last good data", systemImage: "wifi.slash")
    }
}

enum DashboardFormat {
    static func cost(_ value: Double) -> String {
        value >= 100 ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
    }

    static func tokens(_ value: Int) -> String {
        switch value {
        case 1_000_000_000...: return String(format: "%.1fB", Double(value) / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...: return String(format: "%.1fK", Double(value) / 1_000)
        default: return "\(value)"
        }
    }

    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

extension ActionsDashboardRun {
    var dashboardTint: Color {
        guard isComplete else { return isActive ? .blue : .secondary }
        if isFailure { return .red }
        switch conclusion {
        case "success": return .green
        case "cancelled", "skipped", "neutral": return .secondary
        default: return .orange
        }
    }
}

extension RunnersDashboardRunner {
    var dashboardTint: Color {
        if isOffline { return .red }
        return busy ? .orange : .green
    }
}
