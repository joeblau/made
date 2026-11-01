import ActivityKit
import SwiftUI
import WidgetKit

@main
struct CopilotWidgets: WidgetBundle {
    private static let appGroup = "group.app.blau.copilot"
    private static let urlScheme = "walkie"

    var body: some Widget {
        BuildLiveActivity()
        ActionsDashboardWidget(appGroup: Self.appGroup, urlScheme: Self.urlScheme)
        UsageDashboardWidget(appGroup: Self.appGroup, urlScheme: Self.urlScheme)
        RunnersDashboardWidget(appGroup: Self.appGroup, urlScheme: Self.urlScheme)
        ActionsDashboardLiveActivity()
        UsageDashboardLiveActivity()
        RunnersDashboardLiveActivity()
    }
}

struct BuildLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BuildActivityAttributes.self) { context in
            BuildActivityLockScreen(context: context)
            .widgetURL(context.attributes.deepLink)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.label, systemImage: context.state.symbol).foregroundStyle(context.state.buildTint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    BuildElapsedTime(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.attributes.workflow).font(.headline).lineLimit(1)
                        Text("\(context.attributes.repository) · \(context.attributes.branch)").font(.caption).lineLimit(1)
                        if context.isStale && !context.state.isComplete {
                            // Same caution label as the Lock Screen card: orange
                            // glyph, secondary copy (COL-2, IMG-1).
                            Label {
                                Text("Updates delayed · check Cockpit")
                                    .foregroundStyle(.secondary)
                            } icon: {
                                Image(systemName: "wifi.slash")
                                    .foregroundStyle(.orange)
                            }
                            .font(.caption)
                            .lineLimit(1)
                        }
                        Link("View on GitHub", destination: context.attributes.runURL).font(.caption)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.symbol).foregroundStyle(context.state.buildTint)
                    .contentTransition(.symbolEffect(.replace))
            } compactTrailing: {
                if context.isStale && !context.state.isComplete {
                    Image(systemName: "wifi.slash")
                } else {
                    BuildElapsedTime(state: context.state).frame(maxWidth: 60)
                }
            } minimal: {
                Image(systemName: context.isStale && !context.state.isComplete ? "wifi.slash" : context.state.symbol)
                    .foregroundStyle(context.state.buildTint)
            }
            .widgetURL(context.attributes.deepLink)
            .keylineTint(context.state.buildTint)
        }
        .supplementalActivityFamilies([.small])
    }

}

private struct BuildActivityLockScreen: View {
    let context: ActivityViewContext<BuildActivityAttributes>
    @Environment(\.activityFamily) private var family

    var body: some View {
        BuildActivityCard(attributes: context.attributes, state: context.state, isStale: context.isStale, compact: family == .small)
    }
}
