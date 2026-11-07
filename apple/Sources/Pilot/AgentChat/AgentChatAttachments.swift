import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

struct AgentChatAttachment: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let url: URL
    let mimeType: String
    let byteCount: Int
    let thumbnail: Data?
    var isImage: Bool { mimeType.hasPrefix("image/") }

    func promptContent(supportsImages: Bool) throws -> JSONValue {
        if isImage, supportsImages {
            let data = try AgentChatAttachmentStore.read(url, limit: AgentChatAttachmentStore.maximumImageBytes)
            return ["type": "image", "mimeType": .string(mimeType), "data": .string(data.base64EncodedString()),
                    "uri": .string(url.absoluteString)]
        }
        return ["type": "resource_link", "uri": .string(url.absoluteString), "name": .string(name),
                "mimeType": .string(mimeType), "size": .number(Double(byteCount))]
    }
}

enum AgentChatAttachmentInput: Sendable {
    case file(URL)
    case image(Data, name: String)
}

enum AgentChatAttachmentError: LocalizedError {
    case unsupported, tooLarge, invalidImage, invalidVideo, tooMany

    var errorDescription: String? {
        switch self {
        case .unsupported: "Choose a photo or video file."
        case .tooLarge: "Choose an image under 20 MB or a video under 100 MB."
        case .invalidImage: "This image could not be opened. Try a PNG, JPEG, or HEIC image."
        case .invalidVideo: "This video could not be opened. Try a MOV or MP4 video."
        case .tooMany: "You can attach up to 8 photos or videos to a message."
        }
    }
}

/// User-selected media is copied into pane-owned storage before sending. The
/// agent can keep reading resource links after the original file is moved.
/// Decode/downsample and disk IO run outside the main actor.
enum AgentChatAttachmentStore {
    static let maximumCount = 8
    static let maximumImageBytes = 1_048_576
    static let maximumSourceImageBytes = 20 * 1_048_576
    static let maximumVideoBytes = 100 * 1_048_576

    static func directory(paneID: UUID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.blau.pilot/ChatAttachments", isDirectory: true)
            .appendingPathComponent(paneID.uuidString, isDirectory: true)
    }

    static func read(_ url: URL, limit: Int) throws -> Data {
        guard url.isFileURL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw AgentChatAttachmentError.unsupported
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw AgentChatAttachmentError.tooLarge }
        return data
    }

    static func importMedia(_ input: AgentChatAttachmentInput, into root: URL) async throws -> AgentChatAttachment {
        let id = UUID()
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: folder) } }
        let result: AgentChatAttachment
        switch input {
        case .image(let data, let name):
            result = try importImage(data, name: name, id: id, folder: folder)
        case .file(let source):
            guard source.isFileURL else { throw AgentChatAttachmentError.unsupported }
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            let type = UTType(filenameExtension: source.pathExtension)
            if type?.conforms(to: .image) == true {
                result = try importImage(read(source, limit: maximumSourceImageBytes), name: source.lastPathComponent,
                                         id: id, folder: folder)
            } else if type?.conforms(to: .movie) == true {
                result = try await importVideo(source, type: type!, id: id, folder: folder)
            } else { throw AgentChatAttachmentError.unsupported }
        }
        try Task.checkCancellation()
        retained = true
        return result
    }

    private static func importImage(_ data: Data, name: String, id: UUID, folder: URL) throws -> AgentChatAttachment {
        guard data.count <= maximumSourceImageBytes else { throw AgentChatAttachmentError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0, width.doubleValue * height.doubleValue <= 100_000_000,
              let image = thumbnail(source, size: 2_048) else { throw AgentChatAttachmentError.invalidImage }
        var type = UTType.png
        var encoded = try encode(image, type: type)
        if encoded.count > maximumImageBytes {
            type = .jpeg
            encoded = try encode(image, type: type)
        }
        if encoded.count > maximumImageBytes, let smaller = thumbnail(source, size: 1_024) {
            encoded = try encode(smaller, type: .jpeg)
        }
        guard encoded.count <= maximumImageBytes else { throw AgentChatAttachmentError.invalidImage }
        let url = folder.appendingPathComponent("image." + (type.preferredFilenameExtension ?? "png"))
        try encoded.write(to: url, options: .atomic)
        let preview = try thumbnail(source, size: 96).map { try encode($0, type: .png) }
        return AgentChatAttachment(id: id, name: name, url: url, mimeType: type.preferredMIMEType ?? "image/png",
                                   byteCount: encoded.count, thumbnail: preview)
    }

    private static func importVideo(_ source: URL, type: UTType, id: UUID, folder: URL) async throws -> AgentChatAttachment {
        let info = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true else { throw AgentChatAttachmentError.unsupported }
        guard let size = info.fileSize, size <= maximumVideoBytes else { throw AgentChatAttachmentError.tooLarge }
        let url = folder.appendingPathComponent("video." + source.pathExtension)
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: url)
        defer { try? input.close(); try? output.close() }
        var count = 0
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            count += chunk.count
            guard count <= maximumVideoBytes else { throw AgentChatAttachmentError.tooLarge }
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw AgentChatAttachmentError.invalidVideo }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 96, height: 96)
        let preview = try? await generator.image(at: .zero).image
        return AgentChatAttachment(id: id, name: source.lastPathComponent, url: url,
                                   mimeType: type.preferredMIMEType ?? "video/mp4", byteCount: count,
                                   thumbnail: try preview.map { try encode($0, type: .png) })
    }

    private static func thumbnail(_ source: CGImageSource, size: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: size, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
    }

    private static func encode(_ image: CGImage, type: UTType) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            throw AgentChatAttachmentError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AgentChatAttachmentError.invalidImage }
        return output as Data
    }

    static func remove(_ attachment: AgentChatAttachment) {
        try? FileManager.default.removeItem(at: attachment.url.deletingLastPathComponent())
    }
}

@MainActor
enum AgentChatMediaPasteboard {
    static let types: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff, .init(UTType.jpeg.identifier), .init(UTType.heic.identifier)]

    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier, UTType.movie.identifier]])
            || pasteboard.availableType(from: Array(types.dropFirst())) != nil
    }

    static func inputs(_ pasteboard: NSPasteboard) -> [AgentChatAttachmentInput] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            return urls.filter {
                let type = UTType(filenameExtension: $0.pathExtension)
                return type?.conforms(to: .image) == true || type?.conforms(to: .movie) == true
            }.prefix(AgentChatAttachmentStore.maximumCount + 1).map { .file($0) }
        }
        return (pasteboard.pasteboardItems ?? []).prefix(AgentChatAttachmentStore.maximumCount + 1).compactMap { item in
            guard let type = item.availableType(from: Array(types.dropFirst())), let data = item.data(forType: type) else { return nil }
            return .image(data, name: "image.png")
        }
    }
}

/// A compact wrapping row of native thumbnail/name/remove controls.
@MainActor
final class AgentChatAttachmentStrip: NSView {
    var onRemove: ((UUID) -> Void)?
    private var attachments: [AgentChatAttachment] = []
    private var chips: [AgentChatAttachmentChip] = []
    private var measuredHeight: CGFloat = 0
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight) }
    override var isFlipped: Bool { true }

    func update(_ attachments: [AgentChatAttachment]) {
        guard self.attachments != attachments else { return }
        self.attachments = attachments
        chips.forEach { $0.removeFromSuperview() }
        chips = attachments.map { attachment in
            let chip = AgentChatAttachmentChip(attachment: attachment)
            chip.onRemove = { [weak self] in self?.onRemove?(attachment.id) }
            addSubview(chip)
            return chip
        }
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        var y: CGFloat = 0
        for chip in chips {
            let width = min(bounds.width, chip.preferredWidth)
            if x > 0, x + width > bounds.width { x = 0; y += 40 }
            chip.frame = NSRect(x: x, y: y, width: max(0, width), height: 34)
            x += width + 6
        }
        let height: CGFloat = chips.isEmpty ? 0 : y + 34
        if measuredHeight != height { measuredHeight = height; invalidateIntrinsicContentSize() }
    }
}

@MainActor
private final class AgentChatAttachmentChip: NSView {
    var onRemove: (() -> Void)?
    private let preview = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let remove = NSButton()
    var preferredWidth: CGFloat { min(240, name.intrinsicContentSize.width + 70) }

    init(attachment: AgentChatAttachment) {
        super.init(frame: .zero)
        name.stringValue = attachment.name
        name.font = CockpitTypography.font(size: 12)
        name.lineBreakMode = .byTruncatingMiddle
        preview.image = attachment.thumbnail.flatMap(NSImage.init(data:))
            ?? NSImage(systemSymbolName: attachment.isImage ? "photo" : "film", accessibilityDescription: nil)
        preview.imageScaling = .scaleProportionallyUpOrDown
        remove.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove attachment")
        remove.imagePosition = .imageOnly
        remove.isBordered = false
        remove.target = self
        remove.action = #selector(removeAttachment)
        remove.toolTip = "Remove \(attachment.name)"
        remove.setAccessibilityLabel("Remove \(attachment.name)")
        setAccessibilityIdentifier("agent-chat.attachment.\(attachment.id)")
        toolTip = attachment.name
        for child in [preview, name, remove] { addSubview(child) }
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        preview.frame = NSRect(x: 8, y: 6, width: 24, height: 22)
        name.frame = NSRect(x: 38, y: (bounds.height - name.intrinsicContentSize.height) / 2,
                            width: max(0, bounds.width - 64), height: name.intrinsicContentSize.height)
        remove.frame = NSRect(x: bounds.width - 24, y: 7, width: 18, height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 17, yRadius: 17).fill()
    }

    @objc private func removeAttachment() { onRemove?() }
}
