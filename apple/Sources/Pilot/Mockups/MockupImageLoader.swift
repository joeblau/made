import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Loads user-supplied screenshots and backgrounds. Files, drags, and the
/// pasteboard are untrusted: size and pixel bounds are checked from the
/// container header before anything is decoded.
enum MockupImageLoader {
    static let maxBytes = 64 * 1024 * 1024
    static let maxPixelEdge = 12_000

    enum Failure: Error, Equatable {
        case tooLarge
        case unreadable
        case dimensions
    }

    static func load(contentsOf url: URL) -> Result<NSImage, Failure> {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true else { return .failure(.unreadable) }
        guard let size = values.fileSize, size <= maxBytes else { return .failure(.tooLarge) }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return .failure(.unreadable) }
        return load(data: data)
    }

    static func load(data: Data) -> Result<NSImage, Failure> {
        guard data.count <= maxBytes else { return .failure(.tooLarge) }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return .failure(.unreadable) }
        guard width > 0, height > 0, width <= maxPixelEdge, height <= maxPixelEdge else { return .failure(.dimensions) }
        let decode = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, decode) else { return .failure(.unreadable) }
        return .success(NSImage(cgImage: image, size: NSSize(width: width, height: height)))
    }

    /// First acceptable image on the pasteboard: a file URL, then raw image data.
    static func load(from pasteboard: NSPasteboard) -> Result<NSImage, Failure>? {
        let urlOptions: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self], options: urlOptions) as? [URL])?.first {
            return load(contentsOf: url)
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier),
                     NSPasteboard.PasteboardType(UTType.heic.identifier)] {
            if let data = pasteboard.data(forType: type) { return load(data: data) }
        }
        return nil
    }

    static var pasteboardTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier),
         NSPasteboard.PasteboardType(UTType.heic.identifier)]
    }
}
