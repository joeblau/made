import ActivityKit
import SwiftUI
import WidgetKit

public struct ActionsDashboardLiveActivity: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        ActivityConfiguration(for: ActionsDashboardActivityAttributes.self) { context in
            ActionsDashboardLockScreen(context: context)
                .widgetURL(context.attributes.deepLink)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    DashboardIslandLabel(title: "Actions", systemImage: "arrow.triangle.2.circlepath", tint: .blue)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.activeCount) active")
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(context.state.activeCount)))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ActionsDashboardActivityCard(projection: context.state, isStale: context.isStale)
                }
            } compactLeading: {
                // Same family tint as the minimal view and keyline.
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.blue)
            } compactTrailing: {
                Text("\(context.state.activeCount) active")
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(context.state.activeCount)))
            } minimal: {
                Image(systemName: context.state.failureCount > 0 ? "xmark.circle.fill" : "arrow.triangle.2.circlepath")
                    .foregroundStyle(context.state.failureCount > 0 ? .red : .blue)
            }
            .widgetURL(context.attributes.deepLink)
            .keylineTint(.blue)
        }
        .supplementalActivityFamilies([.small])
    }
}

public struct UsageDashboardLiveActivity: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        ActivityConfiguration(for: UsageDashboardActivityAttributes.self) { context in
            UsageDashboardLockScreen(context: context)
                .widgetURL(context.attributes.deepLink)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    DashboardIslandLabel(title: "AI Usage", systemImage: "sparkles", tint: .purple)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(DashboardFormat.cost(context.state.estimatedCost))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: context.state.estimatedCost))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    UsageDashboardActivityCard(projection: context.state, isStale: context.isStale)
                }
            } compactLeading: {
                Image(systemName: context.state.hasUnpricedModels ? "exclamationmark.triangle.fill" : "sparkles")
                    .foregroundStyle(context.state.hasUnpricedModels ? .orange : .purple)
            } compactTrailing: {
                Text(DashboardFormat.cost(context.state.estimatedCost))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: context.state.estimatedCost))
            } minimal: {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
            }
            .widgetURL(context.attributes.deepLink)
            .keylineTint(.purple)
        }
        .supplementalActivityFamilies([.small])
    }
}

public struct RunnersDashboardLiveActivity: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        ActivityConfiguration(for: RunnersDashboardActivityAttributes.self) { context in
            RunnersDashboardLockScreen(context: context)
                .widgetURL(context.attributes.deepLink)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    DashboardIslandLabel(title: "Runners", systemImage: "server.rack", tint: .blue)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.idleCount) idle")
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(context.state.idleCount)))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    RunnersDashboardActivityCard(projection: context.state, isStale: context.isStale)
                }
            } compactLeading: {
                Image(systemName: "server.rack")
                    .foregroundStyle(.blue)
            } compactTrailing: {
                Text("\(context.state.idleCount)/\(context.state.totalCount)")
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(context.state.idleCount)))
            } minimal: {
                Image(systemName: context.state.offlineCount > 0 ? "xmark.circle.fill" : "server.rack")
                    .foregroundStyle(context.state.offlineCount > 0 ? .red : .blue)
            }
            .widgetURL(context.attributes.deepLink)
            .keylineTint(.blue)
        }
        .supplementalActivityFamilies([.small])
    }
}

/// Expanded-region family label: the glyph carries the same family tint as
/// the compact, minimal, and keyline views; the title stays primary text so it
/// keeps contrast on the Island's black stage (HIER-3, COL-2).
private struct DashboardIslandLabel: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label {
            Text(title)
                .lineLimit(1)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
    }
}

private struct ActionsDashboardLockScreen: View {
    let context: ActivityViewContext<ActionsDashboardActivityAttributes>
    @Environment(\.activityFamily) private var family

    var body: some View {
        ActionsDashboardActivityCard(
            projection: context.state,
            isStale: context.isStale,
            compact: family == .small
        )
    }
}

private struct UsageDashboardLockScreen: View {
    let context: ActivityViewContext<UsageDashboardActivityAttributes>
    @Environment(\.activityFamily) private var family

    var body: some View {
        UsageDashboardActivityCard(
            projection: context.state,
            isStale: context.isStale,
            compact: family == .small
        )
    }
}

private struct RunnersDashboardLockScreen: View {
    let context: ActivityViewContext<RunnersDashboardActivityAttributes>
    @Environment(\.activityFamily) private var family

    var body: some View {
        RunnersDashboardActivityCard(
            projection: context.state,
            isStale: context.isStale,
            compact: family == .small
        )
    }
}
