import Foundation
import SwiftUI
import WidgetKit

public struct DashboardTimelineEntry: TimelineEntry {
    public let date: Date
    public let actions: ActionsDashboardSnapshot?
    public let usage: UsageDashboardSnapshot?
    public let runners: RunnersDashboardSnapshot?

    public init(
        date: Date,
        actions: ActionsDashboardSnapshot? = nil,
        usage: UsageDashboardSnapshot? = nil,
        runners: RunnersDashboardSnapshot? = nil
    ) {
        self.date = date
        self.actions = actions
        self.usage = usage
        self.runners = runners
    }
}

public struct DashboardTimelineProvider: TimelineProvider {
    private let appGroup: String
    private let family: DashboardFamily

    public init(appGroup: String, family: DashboardFamily) {
        self.appGroup = appGroup
        self.family = family
    }

    public func placeholder(in context: Context) -> DashboardTimelineEntry {
        DashboardTimelineEntry(date: Date())
    }

    public func getSnapshot(in context: Context, completion: @escaping (DashboardTimelineEntry) -> Void) {
        completion(currentEntry())
    }

    public func getTimeline(in context: Context, completion: @escaping (Timeline<DashboardTimelineEntry>) -> Void) {
        let nextRefresh = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [currentEntry()], policy: .after(nextRefresh)))
    }

    private func currentEntry() -> DashboardTimelineEntry {
        let store = DashboardSnapshotStore(appGroup: appGroup)
        let now = Date()
        switch family {
        case .actions:
            return DashboardTimelineEntry(date: now, actions: store.read(ActionsDashboardSnapshot.self, for: .actions))
        case .usage:
            return DashboardTimelineEntry(date: now, usage: store.read(UsageDashboardSnapshot.self, for: .usage))
        case .runners:
            return DashboardTimelineEntry(date: now, runners: store.read(RunnersDashboardSnapshot.self, for: .runners))
        }
    }
}

public struct ActionsDashboardWidget: Widget {
    private let appGroup: String
    private let urlScheme: String

    public init() {
        self.init(appGroup: "group.app.blau.pilot", urlScheme: "cockpit")
    }

    public init(appGroup: String, urlScheme: String) {
        self.appGroup = appGroup
        self.urlScheme = urlScheme
    }

    public var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: DashboardWidgetKind.actions,
            provider: DashboardTimelineProvider(appGroup: appGroup, family: .actions)
        ) { entry in
            ActionsDashboardWidgetView(snapshot: entry.actions)
                .containerBackground(.background, for: .widget)
                .widgetURL(URL(string: "\(urlScheme)://\(DashboardFamily.actions.urlPath)"))
        }
        .configurationDisplayName("Actions")
        .description("GitHub Actions across open workspaces.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

public struct UsageDashboardWidget: Widget {
    private let appGroup: String
    private let urlScheme: String

    public init() {
        self.init(appGroup: "group.app.blau.pilot", urlScheme: "cockpit")
    }

    public init(appGroup: String, urlScheme: String) {
        self.appGroup = appGroup
        self.urlScheme = urlScheme
    }

    public var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: DashboardWidgetKind.usage,
            provider: DashboardTimelineProvider(appGroup: appGroup, family: .usage)
        ) { entry in
            UsageDashboardWidgetView(snapshot: entry.usage)
                .containerBackground(.background, for: .widget)
                .widgetURL(URL(string: "\(urlScheme)://\(DashboardFamily.usage.urlPath)"))
        }
        .configurationDisplayName("AI Usage")
        .description("Estimated AI cost, tokens, and plan utilization.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

public struct RunnersDashboardWidget: Widget {
    private let appGroup: String
    private let urlScheme: String

    public init() {
        self.init(appGroup: "group.app.blau.pilot", urlScheme: "cockpit")
    }

    public init(appGroup: String, urlScheme: String) {
        self.appGroup = appGroup
        self.urlScheme = urlScheme
    }

    public var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: DashboardWidgetKind.runners,
            provider: DashboardTimelineProvider(appGroup: appGroup, family: .runners)
        ) { entry in
            RunnersDashboardWidgetView(snapshot: entry.runners)
                .containerBackground(.background, for: .widget)
                .widgetURL(URL(string: "\(urlScheme)://\(DashboardFamily.runners.urlPath)"))
        }
        .configurationDisplayName("GitHub Runners")
        .description("Enterprise runner fleet counts and status.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
