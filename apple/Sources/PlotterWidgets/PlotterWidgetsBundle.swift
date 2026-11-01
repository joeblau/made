import WidgetKit
import SwiftUI

@main
struct PlotterWidgetsBundle: WidgetBundle {
    var body: some Widget {
        PlotterSnapshotWidget()
        ActionsDashboardWidget(appGroup: PlotterSnapshotStore.appGroupID, urlScheme: PlotterDashboardRoute.urlScheme)
        UsageDashboardWidget(appGroup: PlotterSnapshotStore.appGroupID, urlScheme: PlotterDashboardRoute.urlScheme)
        RunnersDashboardWidget(appGroup: PlotterSnapshotStore.appGroupID, urlScheme: PlotterDashboardRoute.urlScheme)
        PlotterLiveActivity()
        ActionsDashboardLiveActivity()
        UsageDashboardLiveActivity()
        RunnersDashboardLiveActivity()
    }
}
