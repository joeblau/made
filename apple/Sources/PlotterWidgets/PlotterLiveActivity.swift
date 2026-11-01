import ActivityKit
import WidgetKit
import SwiftUI

/// Live Activity for an active Plotter mirror session: a thumbnail + status on
/// the lock screen, and a compact presence indicator in the Dynamic Island.
struct PlotterLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PlotterActivityAttributes.self) { context in
            lockScreen(context.state)
                // The tint is a fixed dark stage for the mirror thumbnail, so
                // the text must resolve light-on-dark in either system mode.
                .environment(\.colorScheme, .dark)
                .activityBackgroundTint(.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    thumbnail(side: 44)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    statusDot(context.state.isConnected)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.sessionName)
                            .font(.caption).bold()
                        Text(stateLine(context.state))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "display")
            } compactTrailing: {
                statusDot(context.state.isConnected)
            } minimal: {
                Image(systemName: "display")
            }
        }
    }

    @ViewBuilder
    private func lockScreen(_ state: PlotterActivityAttributes.ContentState) -> some View {
        HStack(spacing: 12) {
            thumbnail(side: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.title.isEmpty ? "Kneeboard" : state.title)
                    .font(.headline)
                Text(stateLine(state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusDot(state.isConnected)
        }
        .padding()
    }

    @ViewBuilder
    private func thumbnail(side: CGFloat) -> some View {
        if let data = PlotterSnapshotStore.readImageData(), let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: side * 1.6, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.gray.opacity(0.3))
                .frame(width: side * 1.6, height: side)
                .overlay(Image(systemName: "display").foregroundStyle(.secondary))
        }
    }

    private func statusDot(_ connected: Bool) -> some View {
        Circle()
            .fill(connected ? Color.green : Color.secondary)
            .frame(width: 8, height: 8)
    }

    private func stateLine(_ state: PlotterActivityAttributes.ContentState) -> String {
        state.isConnected ? "Mirroring" : "Disconnected"
    }
}
