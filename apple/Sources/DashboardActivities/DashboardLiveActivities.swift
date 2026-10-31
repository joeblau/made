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
                    Label("Actions", systemImage: "arrow.triangle.2.circlepath")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.activeCount) active")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ActionsDashboardActivityCard(projection: context.state, isStale: context.isStale)
                }
            } compactLeading: {
                Image(systemName: "arrow.triangle.2.circlepath")
            } compactTrailing: {
                Text("\(context.state.activeCount) active")
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
                    Label("AI Usage", systemImage: "sparkles")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(DashboardFormat.cost(context.state.estimatedCost))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    UsageDashboardActivityCard(projection: context.state, isStale: context.isStale)
                }
            } compactLeading: {
                Image(systemName: context.state.hasUnpricedModels ? "exclamationmark.triangle.fill" : "sparkles")
                    .foregroundStyle(context.state.hasUnpricedModels ? .orange : .purple)
            } compactTrailing: {
                Text(DashboardFormat.cost(context.state.estimatedCost))
            } minimal: {
                Image(systemName: "sparkles")
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
                    Label("Runners", systemImage: "server.rack")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.idleCount) idle")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    RunnersDashboardActivityCard(projection: context.state, isStale: context.isStale)
                }
            } compactLeading: {
                Image(systemName: "server.rack")
            } compactTrailing: {
                Text("\(context.state.idleCount)/\(context.state.totalCount)")
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
