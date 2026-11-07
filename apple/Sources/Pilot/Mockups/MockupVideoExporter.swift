import AVFoundation
import CoreGraphics
import CoreVideo

/// Writes social-media-ready MP4: H.264 High, 8-bit 4:2:0, BT.709, constant
/// 30 fps, even dimensions, `moov` atom up front (faststart). That is the one
/// format X, Instagram, TikTok, LinkedIn, Threads, and YouTube all ingest
/// without re-encoding problems.
@MainActor
final class MockupVideoExporter {
    struct Settings: Equatable {
        var size: CGSize
        var duration: Double
        var fps: Int32 = 30

        var frameCount: Int { max(1, Int((duration * Double(fps)).rounded())) }

        /// Shorter side 1080, longer side capped at 1920, both even.
        static func social(ratio: CGFloat, duration: Double) -> Settings {
            var size = ratio >= 1 ? CGSize(width: 1080 * ratio, height: 1080) : CGSize(width: 1080, height: 1080 / ratio)
            let longest = max(size.width, size.height)
            if longest > 1920 { size = CGSize(width: size.width * 1920 / longest, height: size.height * 1920 / longest) }
            func even(_ value: CGFloat) -> CGFloat { max(2, (value / 2).rounded() * 2) }
            return Settings(size: CGSize(width: even(size.width), height: even(size.height)), duration: duration)
        }

        /// ~0.2 bits per pixel per frame: 1080×1920@30 ≈ 12 Mbps, under every
        /// platform's ingest ceiling and well above what they re-encode to.
        var bitRate: Int { Int(size.width * size.height * CGFloat(fps) * 0.2) }
    }

    enum Failure: Error, Equatable {
        case writer(String)
        case cancelled
        case frame(Int)
    }

    private(set) var isCancelled = false
    func cancel() { isCancelled = true }

    /// Renders `frameCount` frames through `render` (time in seconds → image)
    /// and writes them to `url`, replacing any existing file.
    func export(to url: URL, settings: Settings, progress: (Double) -> Void,
                render: (Double) -> CGImage?) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: url, fileType: .mp4) } catch { throw Failure.writer(error.localizedDescription) }
        writer.shouldOptimizeForNetworkUse = true
        let width = Int(settings.size.width), height = Int(settings.size.height)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: settings.bitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
                AVVideoExpectedSourceFrameRateKey: settings.fps,
                AVVideoMaxKeyFrameIntervalKey: settings.fps * 2,
                AVVideoAllowFrameReorderingKey: true,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw Failure.writer("The H.264 track could not be added.") }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "Writer failed to start.") }
        writer.startSession(atSourceTime: .zero)

        let total = settings.frameCount
        for index in 0..<total {
            if isCancelled {
                writer.cancelWriting()
                throw Failure.cancelled
            }
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            let time = Double(index) / Double(settings.fps)
            guard let image = render(time),
                  let pool = adaptor.pixelBufferPool,
                  let buffer = Self.pixelBuffer(from: image, pool: pool, width: width, height: height) else {
                writer.cancelWriting()
                throw Failure.frame(index)
            }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: settings.fps)) else {
                throw Failure.writer(writer.error?.localizedDescription ?? "Frame \(index) was rejected.")
            }
            progress(Double(index + 1) / Double(total))
            // Keep the window responsive between frames.
            await Task.yield()
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        if writer.status != .completed { throw Failure.writer(writer.error?.localizedDescription ?? "Writing did not complete.") }
    }

    /// Draws `image` aspect-filled into a pooled BGRA buffer. Video has no
    /// alpha, so transparency is flattened onto black.
    static func pixelBuffer(from image: CGImage, pool: CVPixelBufferPool, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let scale = max(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (CGFloat(width) - size.width) / 2, y: (CGFloat(height) - size.height) / 2,
                                       width: size.width, height: size.height))
        return buffer
    }
}
