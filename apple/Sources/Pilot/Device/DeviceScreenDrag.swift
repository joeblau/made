import AppKit
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Tracks a pointer press that may become a drag of the device screen image.
/// Panes whose plain drags are touch input require ⌘; view-only panes do not.
struct DeviceScreenDragGesture {
    /// Matches the terminal's selection threshold so a click never drags.
    static let threshold: CGFloat = 3

    private var origin: CGPoint?
    private var didBegin = false

    /// True from an accepted press until release; the pane must not forward
    /// these events as touch input.
    var isTracking: Bool { origin != nil }

    /// Returns true when the press belongs to a screen drag.
    mutating func press(at point: CGPoint, modifiers: NSEvent.ModifierFlags, requiresCommand: Bool) -> Bool {
        didBegin = false
        origin = !requiresCommand || modifiers.contains(.command) ? point : nil
        return origin != nil
    }

    /// Returns true exactly once, when the pointer has moved far enough to
    /// start the drag session.
    mutating func drag(to point: CGPoint) -> Bool {
        guard let origin, !didBegin,
              hypot(point.x - origin.x, point.y - origin.y) >= Self.threshold else { return false }
        didBegin = true
        return true
    }

    mutating func release() {
        origin = nil
        didBegin = false
    }
}

/// Drags the frame a device pane is showing out as a PNG file. Dropping it on
/// a terminal pastes the file path, which Claude Code attaches as an image.
@MainActor
enum DeviceScreenDrag {
    private static let ciContext = CIContext()
    private static let source = DeviceScreenDragSource()
    private static let previewMaxSide: CGFloat = 160

    /// The frame an `AVSampleBufferDisplayLayer` is currently showing.
    static func displayedFrame(of layer: AVSampleBufferDisplayLayer) -> CGImage? {
        guard let pixelBuffer = layer.sampleBufferRenderer.displayedPixelBuffer() else { return nil }
        return image(from: pixelBuffer)
    }

    static func image(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        return ciContext.createCGImage(image, from: image.extent)
    }

    /// Writes `frame` to a PNG and starts the drag. Beeps when the pane has no
    /// frame yet or the file cannot be written.
    static func begin(from view: NSView, event: NSEvent, frame: CGImage?, name: String) {
        guard let frame, let url = try? DeviceScreenDragFiles.write(frame, name: name) else {
            NSSound.beep()
            return
        }
        let scale = min(1, previewMaxSide / CGFloat(max(frame.width, frame.height, 1)))
        let size = NSSize(width: CGFloat(frame.width) * scale, height: CGFloat(frame.height) * scale)
        let location = view.convert(event.locationInWindow, from: nil)
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(
            NSRect(x: location.x - size.width / 2, y: location.y - size.height / 2,
                   width: size.width, height: size.height),
            contents: NSImage(cgImage: frame, size: size)
        )
        view.beginDraggingSession(with: [item], event: event, source: source)
    }
}

private final class DeviceScreenDragSource: NSObject, NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }
}

/// Dragged screenshots must outlive the drag: the drop target (or an agent
/// reading the pasted path) opens the file afterwards. Files older than a day
/// are pruned on each write so the folder cannot grow without bound.
enum DeviceScreenDragFiles {
    static let maxAge: TimeInterval = 24 * 60 * 60

    static var defaultDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CockpitDeviceDrags", isDirectory: true)
    }

    static func write(
        _ image: CGImage,
        name: String,
        now: Date = Date(),
        directory: URL = defaultDirectory
    ) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        prune(directory: directory, olderThan: now.addingTimeInterval(-maxAge))

        let url = directory.appendingPathComponent(fileName(name: name, date: now))
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    /// No spaces, so the pasted path needs no shell escaping, and a random
    /// suffix so two drags in the same second never collide.
    static func fileName(name: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = UUID().uuidString.prefix(6).lowercased()
        return "\(name)-screen-\(formatter.string(from: date))-\(suffix).png"
    }

    static func prune(directory: URL, olderThan cutoff: Date) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries where entry.pathExtension == "png" {
            let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if let modified, modified < cutoff {
                try? fileManager.removeItem(at: entry)
            }
        }
    }
}
