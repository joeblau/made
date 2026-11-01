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
                    HStack(spacing: 8) {
                        // A small widget has room for two labeled columns; the
                        // run total is the one that can go.
                        if family != .systemSmall {
                            DashboardMetric(value: snapshot.runs.count, label: "Runs")
                        }
                        DashboardMetric(value: activeCount, label: "Active", tint: activeCount > 0 ? .blue : nil)
                        DashboardMetric(value: failedCount, label: "Failed", tint: failedCount > 0 ? .red : nil)
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
                    if family == .systemSmall {
                        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                            GridRow { fleet; idle }
                            GridRow { busy; offline }
                        }
                    } else {
                        HStack(spacing: 12) { fleet; idle; busy; offline }
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

    public init(projection: ActionsDashboardActivityProjection, isStale: Bool = false, compact: Bool = false) {
        self.projection = projection
        self.isStale = isStale
        self.compact = compact
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
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
            if isStale {
                DashboardStaleLabel()
            }
            if !compact {
                ForEach(projection.runs, id: \.id) { run in
                    DashboardRunRow(run: run, detail: .stacked)
                }
            }
        }
        .padding(compact ? 8 : 16)
    }
}

public struct UsageDashboardActivityCard: View {
    private let projection: UsageDashboardActivityProjection
    private let isStale: Bool
    private let compact: Bool

    public init(projection: UsageDashboardActivityProjection, isStale: Bool = false, compact: Bool = false) {
        self.projection = projection
        self.isStale = isStale
        self.compact = compact
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
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
            if projection.hasUnpricedModels {
                DashboardWarningLabel(text: "Partial estimate · unpriced models", systemImage: "exclamationmark.triangle.fill")
            }
            if isStale {
                DashboardStaleLabel()
            }
            if !compact {
                ForEach(projection.providers, id: \.id) { provider in
                    DashboardProviderRow(provider: provider, detail: .stacked)
                }
            }
        }
        .padding(compact ? 8 : 16)
    }
}

public struct RunnersDashboardActivityCard: View {
    private let projection: RunnersDashboardActivityProjection
    private let isStale: Bool
    private let compact: Bool

    public init(projection: RunnersDashboardActivityProjection, isStale: Bool = false, compact: Bool = false) {
        self.projection = projection
        self.isStale = isStale
        self.compact = compact
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
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
                ForEach(projection.runners, id: \.id) { runner in
                    DashboardRunnerRow(runner: runner, detail: .stacked)
                }
            }
        }
        .padding(compact ? 8 : 16)
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
            // The family glyph joins the accent group so tinted and vibrant
            // rendering modes keep one colored anchor per widget.
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .widgetAccentable()
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                // Wider families carry freshness in the header, trailing, so
                // the vertical space goes to rows instead of a footer line.
                if family != .systemSmall {
                    freshness
                        .layoutPriority(1)
                }
            }
            content
            Spacer(minLength: 0)
            if family == .systemSmall {
                freshness
            }
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
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DashboardRunRow: View {
    let run: ActionsDashboardRun
    let detail: DashboardRowDetail

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: run.systemImage)
                .foregroundStyle(run.dashboardTint)
                .frame(width: 16)
                // Speaks the status when the visible status text is hidden.
                .accessibilityLabel(run.label)
                .accessibilityHidden(detail != .hidden)
            DashboardRowText(
                title: run.workflow.isEmpty ? "Workflow" : run.workflow,
                subtitle: "\(run.repository) · \(run.branch)",
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

private struct DashboardProviderRow: View {
    let provider: UsageDashboardProviderSummary
    let detail: DashboardRowDetail

    var body: some View {
        HStack(spacing: 8) {
            DashboardRowText(
                title: provider.name.isEmpty ? "Provider" : provider.name,
                subtitle: utilizationText,
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
        HStack(spacing: 8) {
            Image(systemName: runner.systemImage)
                .foregroundStyle(runner.dashboardTint)
                .frame(width: 16)
            DashboardRowText(
                title: runner.name.isEmpty ? "Runner \(runner.id)" : runner.name,
                subtitle: runner.operatingSystem.isEmpty ? nil : runner.operatingSystem,
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
