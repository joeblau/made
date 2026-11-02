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
                    // The center region already speaks the state line.
                    statusDot(context.state.isConnected, speaksState: false)
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
                statusDot(context.state.isConnected, speaksState: true)
            } minimal: {
                Image(systemName: "display")
            }
            // Same connected signal as the status dot, so the Island keyline
            // reads as one state color rather than a stray accent.
            .keylineTint(context.state.isConnected ? Color.green : nil)
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
            statusDot(state.isConnected, speaksState: false)
        }
        .padding()
    }

    /// The lock-screen card is ~24pt-radius with a 16pt inset, so the
    /// thumbnail's 8pt radius stays concentric (outer - padding, LAY-4).
    private static let thumbnailRadius: CGFloat = 8

    @ViewBuilder
    private func thumbnail(side: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.thumbnailRadius, style: .continuous)
        if let data = PlotterSnapshotStore.readImageData(),
           let image = PlotterSnapshotImage.thumbnail(data, maxPixelSize: PlotterSnapshotImage.activityMaxPixelSize) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: side * 1.6, height: side)
                .clipShape(shape)
        } else {
            // Semantic fill: resolves to a soft light plate on the forced-dark
            // stage instead of a raw gray literal (COL-1).
            shape
                .fill(.quaternary)
                .frame(width: side * 1.6, height: side)
                .overlay(Image(systemName: "display").foregroundStyle(.secondary))
        }
    }

    /// - Parameter speaksState: `true` only where the dot stands alone (the
    ///   compact Island). Next to the visible state line it is decorative, so
    ///   VoiceOver does not read "Disconnected" twice.
    @ViewBuilder
    private func statusDot(_ connected: Bool, speaksState: Bool) -> some View {
        let dot = Circle()
            .fill(connected ? Color.green : Color.secondary)
            .frame(width: 8, height: 8)
        if speaksState {
            dot
                .accessibilityElement()
                .accessibilityLabel(connected ? "Connected" : "Disconnected")
        } else {
            dot.accessibilityHidden(true)
        }
    }

    private func stateLine(_ state: PlotterActivityAttributes.ContentState) -> String {
        state.isConnected ? "Mirroring" : "Disconnected"
    }
}
