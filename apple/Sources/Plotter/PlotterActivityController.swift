import Foundation
@preconcurrency import ActivityKit

/// Owns the single Plotter mirror Live Activity: starts it when a Pilot
/// connects, refreshes its state as snapshots arrive, and ends it on
/// disconnect. No-ops gracefully if Live Activities are disabled by the user.
@MainActor
final class PlotterActivityController {
    static let shared = PlotterActivityController()

    private var activity: Activity<PlotterActivityAttributes>?

    private func makeState(connected: Bool, title: String) -> PlotterActivityAttributes.ContentState {
        PlotterActivityAttributes.ContentState(isConnected: connected, title: title, updatedAt: Date())
    }

    /// Start (or refresh) the activity when connected; end it when not.
    func setConnected(_ connected: Bool, title: String) {
        guard connected else {
            end()
            return
        }
        if activity != nil {
            Task { @MainActor in
                await self.activity?.update(ActivityContent(state: self.makeState(connected: true, title: title), staleDate: nil))
            }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activity = try? Activity.request(
            attributes: PlotterActivityAttributes(sessionName: title.isEmpty ? "Cockpit" : title),
            content: ActivityContent(state: makeState(connected: true, title: title), staleDate: nil)
        )
    }

    /// Bump the activity's timestamp when a fresh snapshot lands.
    func touch(title: String) {
        guard activity != nil else { return }
        Task { @MainActor in
            await self.activity?.update(ActivityContent(state: self.makeState(connected: true, title: title), staleDate: nil))
        }
    }

    func end() {
        guard activity != nil else { return }
        Task { @MainActor in
            await self.activity?.end(
                ActivityContent(state: self.makeState(connected: false, title: ""), staleDate: nil),
                dismissalPolicy: .immediate
            )
            self.activity = nil
        }
    }
}
