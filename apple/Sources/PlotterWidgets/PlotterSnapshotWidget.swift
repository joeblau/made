import ImageIO
import WidgetKit
import SwiftUI

/// Decodes the mirrored still for a widget or Live Activity at a bounded
/// size. WidgetKit refuses to archive an image larger than its family's pixel
/// budget (about 423k pixels for a small widget) and then shows only the
/// redacted placeholder; the still comes from the peer, so its size is not
/// ours to trust. ImageIO's thumbnail path also avoids decoding the full
/// frame in the extension's small memory budget.
enum PlotterSnapshotImage {
    static func thumbnail(_ data: Data, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    /// Long side for home-screen widgets: 640x400 for a 16:10 frame, and a
    /// tall frame still fits the small family's budget.
    static let widgetMaxPixelSize = 640
    /// Long side for the Live Activity thumbnail (at most about 84x52pt).
    static let activityMaxPixelSize = 320
}

/// Home/lock-screen widget showing the most recent frame Plotter received from
/// the connected Mac, plus connection status. Static (refreshed on the system
/// budget); the app nudges reloads as new frames arrive.
struct SnapshotEntry: TimelineEntry {
    let date: Date
    let imageData: Data?
    let status: PlotterSnapshotStore.Status?
}

struct PlotterSnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), imageData: nil, status: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        // Fallback refresh; the app calls reloadAllTimelines() when a fresh
        // frame lands, so this is just a safety net.
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [currentEntry()], policy: .after(next)))
    }

    private func currentEntry() -> SnapshotEntry {
        SnapshotEntry(
            date: Date(),
            imageData: PlotterSnapshotStore.readImageData(),
            status: PlotterSnapshotStore.readStatus()
        )
    }
}

struct PlotterSnapshotWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PlotterSnapshotWidget", provider: PlotterSnapshotProvider()) { entry in
            PlotterSnapshotView(entry: entry)
                .containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("Kneeboard Mirror")
        .description("The latest screen from the connected Mac.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        // The mirrored frame is the content; let it run edge to edge and
        // inset only the status line.
        .contentMarginsDisabled()
    }
}

struct PlotterSnapshotView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var connected: Bool { entry.status?.isConnected ?? false }

    var body: some View {
        // A flexible clear frame owns the layout so an aspect-fill frame is
        // cropped to the widget instead of widening it (which pushed the
        // status line past the leading edge).
        Color.clear
            .overlay {
                if let data = entry.imageData,
                   let image = PlotterSnapshotImage.thumbnail(data, maxPixelSize: PlotterSnapshotImage.widgetMaxPixelSize) {
                    Image(uiImage: image)
                        .resizable()
                        .widgetAccentedRenderingMode(.accentedDesaturated)
                        .aspectRatio(contentMode: .fill)
                } else {
                    ContentUnavailablePlaceholder()
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(connected ? Color.green : Color.white.opacity(0.6))
                        .frame(width: 8, height: 8)
                        .widgetAccentable()
                    Text(statusLine)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Gradient scrim keeps the white caption legible over any
                // mirrored frame without a hard-edged band (COL-6). Only in
                // full color: accented (tinted/clear glass) and vibrant modes
                // render by alpha, so a black scrim would become a light wash
                // over the caption instead of darkening the frame.
                .background {
                    if renderingMode == .fullColor {
                        LinearGradient(
                            colors: [.black.opacity(0), .black.opacity(0.7)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                }
            }
    }

    private var statusLine: String {
        guard let status = entry.status else { return "Not connected" }
        if status.isConnected {
            return status.title.isEmpty ? "Connected" : status.title
        }
        return "Last seen \(status.updatedAt.formatted(.relative(presentation: .numeric)))"
    }
}

private struct ContentUnavailablePlaceholder: View {
    var body: some View {
        // No opaque fill here: the black stage is the widget's
        // `containerBackground`, which the system removes for accented
        // (tinted/clear glass) and vibrant rendering. A `Color.black` layer
        // would instead render as a solid plate in those modes.
        VStack(spacing: 8) {
            Image(systemName: "display")
                .font(.title2)
                .widgetAccentable()
            Text("No mirror yet")
                .font(.caption2)
        }
        // Always light-on-black: the container is a fixed dark stage.
        .foregroundStyle(.white.opacity(0.6))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
