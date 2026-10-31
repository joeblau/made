import SwiftUI
import WidgetKit

@main
struct PilotWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ActionsDashboardWidget(appGroup: "group.app.blau.pilot", urlScheme: "cockpit")
        UsageDashboardWidget(appGroup: "group.app.blau.pilot", urlScheme: "cockpit")
        RunnersDashboardWidget(appGroup: "group.app.blau.pilot", urlScheme: "cockpit")
    }
}
