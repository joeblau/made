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
            updatedAt: snapshot?.updatedAt,
            isStale: snapshot?.isStale(at: Date().timeIntervalSince1970) == true
        ) {
            if let snapshot, !snapshot.runs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        DashboardMetric(value: "\(snapshot.runs.count)", label: "Runs", tint: .blue)
                        DashboardMetric(value: "\(snapshot.runs.filter(\.isActive).count)", label: "Active", tint: .orange)
                        DashboardMetric(value: "\(snapshot.runs.filter(\.isFailure).count)", label: "Failed", tint: .red)
                    }
                    ForEach(snapshot.runs.prefix(rowLimit), id: \.id) { run in
                        DashboardRunRow(run: run, showsRepository: family != .systemSmall)
                    }
                }
            } else {
                DashboardEmptyView(title: "No Actions yet", detail: "Runs from open workspaces will appear here.")
            }
        }
    }

    private var rowLimit: Int {
        switch family {
        case .systemSmall: 1
        case .systemLarge: 6
        default: 3
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
            updatedAt: snapshot?.updatedAt,
            isStale: snapshot?.isStale(at: Date().timeIntervalSince1970) == true
        ) {
            if let snapshot {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(DashboardFormat.cost(snapshot.estimatedCost))
                            .font(family == .systemSmall ? .title2 : .title)
                            .fontWeight(.semibold)
                            .minimumScaleFactor(0.7)
                        Text("\(DashboardFormat.tokens(snapshot.totalTokens)) tokens")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if snapshot.hasUnpricedModels {
                        Label("Partial estimate · unpriced models", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    } else {
                        Text("Estimated cost")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(snapshot.providers.prefix(rowLimit), id: \.id) { provider in
                        DashboardProviderRow(provider: provider)
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
        default: 3
        }
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
            updatedAt: snapshot?.updatedAt,
            isStale: snapshot?.isStale(at: Date().timeIntervalSince1970) == true
        ) {
            if let snapshot {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        DashboardMetric(value: "\(snapshot.totalCount)", label: "Fleet", tint: .blue)
                        DashboardMetric(value: "\(snapshot.idleCount)", label: "Idle", tint: .green)
                        DashboardMetric(value: "\(snapshot.busyCount)", label: "Busy", tint: .orange)
                        DashboardMetric(value: "\(snapshot.offlineCount)", label: "Offline", tint: .red)
                    }
                    ForEach(snapshot.runners.prefix(rowLimit), id: \.id) { runner in
                        DashboardRunnerRow(runner: runner)
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
        case .systemSmall: 1
        case .systemLarge: 8
        default: 3
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
                    DashboardRunRow(run: run, showsRepository: true)
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
                Text("AI Usage")
                    .font(.headline)
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(DashboardFormat.cost(projection.estimatedCost))
                        .font(.headline)
                    Text("\(DashboardFormat.tokens(projection.totalTokens)) tokens")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if projection.hasUnpricedModels {
                Label("Partial estimate · unpriced models", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            if isStale {
                DashboardStaleLabel()
            }
            if !compact {
                ForEach(projection.providers, id: \.id) { provider in
                    DashboardProviderRow(provider: provider)
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
                Text(projection.enterpriseName.isEmpty ? "Runners" : projection.enterpriseName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text("\(projection.idleCount) idle / \(projection.totalCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Label("\(projection.busyCount) busy", systemImage: "gearshape.2")
                    .foregroundStyle(.orange)
                Label("\(projection.offlineCount) offline", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
            .font(.caption2)
            if isStale {
                DashboardStaleLabel()
            }
            if !compact {
                ForEach(projection.runners, id: \.id) { runner in
                    DashboardRunnerRow(runner: runner)
                }
            }
        }
        .padding(compact ? 8 : 16)
    }
}

private struct DashboardWidgetFrame<Content: View>: View {
    let title: String
    let systemImage: String
    let updatedAt: Double?
    let isStale: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(.blue)
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isStale {
                    Image(systemName: "wifi.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            content
            Spacer(minLength: 0)
            HStack {
                Text(isStale ? "Updates delayed" : footerText)
                    .font(.caption2)
                    .foregroundStyle(isStale ? .orange : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
    }

    private var footerText: String {
        guard let updatedAt else { return "Open the app to sync" }
        return "Updated \(Date(timeIntervalSince1970: updatedAt).formatted(.relative(presentation: .numeric)))"
    }
}

private struct DashboardMetric: View {
    let value: String
    let label: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.headline)
                .foregroundStyle(tint)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    let showsRepository: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: run.systemImage)
                .foregroundStyle(run.dashboardTint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(run.workflow.isEmpty ? "Workflow" : run.workflow)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if showsRepository {
                    Text("\(run.repository) · \(run.branch)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(run.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct DashboardProviderRow: View {
    let provider: UsageDashboardProviderSummary

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.name.isEmpty ? "Provider" : provider.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if let utilizationText {
                    Text(utilizationText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(DashboardFormat.cost(provider.estimatedCost))
                    .font(.caption)
                Text(DashboardFormat.tokens(provider.totalTokens))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: runner.systemImage)
                .foregroundStyle(runner.dashboardTint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(runner.name.isEmpty ? "Runner \(runner.id)" : runner.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if !runner.operatingSystem.isEmpty {
                    Text(runner.operatingSystem)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(runner.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DashboardStaleLabel: View {
    var body: some View {
        Label("Updates delayed · showing last good data", systemImage: "wifi.slash")
            .font(.caption2)
            .foregroundStyle(.orange)
            .lineLimit(1)
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
