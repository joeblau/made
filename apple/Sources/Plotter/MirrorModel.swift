import AVFoundation
import CoreMedia
import os
import SwiftUI
import UIKit
import VideoToolbox
import WidgetKit

/// Diagnostic logger for the iPad decode/display path. Filter Console on
/// subsystem `app.blau.plotter`.
let plotterMirrorLog = Logger(subsystem: "app.blau.plotter", category: "Mirror")

/// Receives HEVC media packets from Pilot over the ``FrameReceiver`` channel
/// and forwards them to an `AVSampleBufferDisplayLayer` for low-latency render.
@MainActor
@Observable
final class MirrorModel {
    private(set) var statusText = "Idle"
    private(set) var annotationStatusText = "Annotation idle"
    private(set) var frameCount = 0
    private(set) var videoSize: CGSize = .zero
    private(set) var pairingRequest: FrameLinkPairingRequest?

    /// True when launched with `-demoMode YES`. In demo mode the live decode /
    /// receive path is short-circuited and the view renders a representative
    /// still frame plus seeded annotation strokes, with NO network peer.
    let isDemoMode = UserDefaults.standard.bool(forKey: "demoMode")

    /// A representative still frame shown in place of the live video layer when
    /// ``isDemoMode`` is on. Generated programmatically so no PNG asset is
    /// required to author.
    private(set) var demoImage: UIImage?

    private var lastSentAnnotationSeq: UInt32 = 0

    /// Pilot's light/dark appearance while connected. `nil` when not connected
    /// so Plotter falls back to its own system appearance.
    private(set) var pilotColorScheme: ColorScheme?

    /// Invoked on the main actor for annotation commands sent BY Pilot (undo /
    /// clear). The view applies them to its authoritative PencilKit canvas,
    /// which then echoes the corrected drawing back to Pilot.
    var onRemoteAnnotation: ((AnnotationMessage) -> Void)?

    private let receiver = FrameReceiver()
    private let renderer = HEVCMirrorRenderer()

    /// Loss-tracking state for periodic link feedback (driven on the main
    /// actor from decoded sample frameIDs).
    private var highestFrameID: UInt32?
    private var expectedFrames = 0
    private var receivedFrames = 0
    private var feedbackTask: Task<Void, Never>?

    init() {
        receiver.onPacket = { [weak self] packet in
            self?.handle(packet)
        }
        receiver.onFrame = { [weak self] data in
            self?.handleLegacyJPEG(data)
        }
        receiver.onStatusChanged = { [weak self] status in
            Task { @MainActor in
                self?.statusText = status
            }
        }
        receiver.onFrameCountChanged = { [weak self] count in
            Task { @MainActor in
                self?.frameCount = count
            }
        }
        receiver.onConnectedChanged = { [weak self] connected in
            Task { @MainActor in
                // Drop Pilot's appearance on disconnect so Plotter returns to
                // its own system light/dark setting.
                if !connected { self?.pilotColorScheme = nil }
                // Drive the widget + Live Activity off connection state.
                PlotterSnapshotStore.writeStatus(
                    PlotterSnapshotStore.Status(isConnected: connected, title: "Cockpit", updatedAt: Date())
                )
                WidgetCenter.shared.reloadAllTimelines()
                PlotterActivityController.shared.setConnected(connected, title: "Cockpit")
            }
        }
        receiver.onPairingRequestChanged = { [weak self] request in
            Task { @MainActor in
                self?.pairingRequest = request
            }
        }
    }

    func start() {
        // Demo mode: skip the live receiver/decode path entirely and inject a
        // representative still frame so screenshots show real-looking content
        // with no peer on the network. A normal launch never enters here.
        if isDemoMode {
            startDemoMode()
            return
        }
        receiver.start()
        // Advertise decode capability to the sender so it can choose chroma.
        receiver.sendCapability(supports444: Self.supportsHEVC444Decode())
        startFeedbackLoop()
    }

    func stop() {
        if isDemoMode { return }
        receiver.stop()
        feedbackTask?.cancel()
        feedbackTask = nil
    }

    func resolvePairingRequest(approved: Bool) {
        pairingRequest = nil
        receiver.resolvePairingRequest(approved: approved)
    }

    func forgetPilot() {
        pairingRequest = nil
        receiver.revokePairing()
        frameCount = 0
        statusText = "Cockpit pairing revoked"
    }

    /// Seeds representative state for screenshots: a 16:10 dark still, a
    /// matching `videoSize` so the annotation aspect-fit math is correct, and a
    /// non-zero frame count so the "Searching…" overlay is hidden.
    private func startDemoMode() {
        let size = CGSize(width: 1600, height: 1000)
        videoSize = size
        demoImage = Self.makeDemoFrame(size: size)
        statusText = "Connected to Cockpit (demo)"
        annotationStatusText = "Cockpit received your annotations"
        // Any non-zero value hides the SearchingOverlay (gated on == 0).
        frameCount = 1
    }

    /// Draws a dark, screenshot-like still resembling a mirrored editor window:
    /// a window chrome bar, a sidebar, and a few code-like lines. Used only in
    /// demo mode.
    private static func makeDemoFrame(size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext

            // Background gradient (deep slate -> near-black).
            let colors = [
                UIColor(red: 0.09, green: 0.10, blue: 0.13, alpha: 1).cgColor,
                UIColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1).cgColor
            ] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 1]
            ) {
                cg.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: 0, y: size.height),
                    options: []
                )
            }

            // Title bar.
            let barHeight: CGFloat = 60
            UIColor(red: 0.13, green: 0.14, blue: 0.18, alpha: 1).setFill()
            cg.fill(CGRect(x: 0, y: 0, width: size.width, height: barHeight))

            // Traffic-light dots.
            let dotColors = [
                UIColor(red: 0.99, green: 0.36, blue: 0.34, alpha: 1),
                UIColor(red: 1.00, green: 0.74, blue: 0.18, alpha: 1),
                UIColor(red: 0.24, green: 0.79, blue: 0.30, alpha: 1)
            ]
            for (i, color) in dotColors.enumerated() {
                color.setFill()
                let x = 24 + CGFloat(i) * 26
                cg.fillEllipse(in: CGRect(x: x, y: barHeight / 2 - 8, width: 16, height: 16))
            }

            // Sidebar.
            let sidebarWidth: CGFloat = 260
            UIColor(red: 0.11, green: 0.12, blue: 0.16, alpha: 1).setFill()
            cg.fill(CGRect(x: 0, y: barHeight, width: sidebarWidth, height: size.height - barHeight))

            // Sidebar rows.
            UIColor(white: 1, alpha: 0.14).setFill()
            for row in 0..<10 {
                let y = barHeight + 28 + CGFloat(row) * 40
                let w = CGFloat(120 + (row * 37) % 110)
                cg.fill(CGRect(x: 24, y: y, width: w, height: 12))
            }

            // Editor "code" lines with syntax-ish accent colors.
            let lineColors = [
                UIColor(red: 0.78, green: 0.57, blue: 0.96, alpha: 1),
                UIColor(red: 0.40, green: 0.78, blue: 0.96, alpha: 1),
                UIColor(red: 0.55, green: 0.86, blue: 0.55, alpha: 1),
                UIColor(white: 0.75, alpha: 1)
            ]
            let editorX = sidebarWidth + 48
            for row in 0..<18 {
                let y = barHeight + 40 + CGFloat(row) * 44
                let indent = CGFloat((row % 4) * 28)
                let w = CGFloat(180 + (row * 53) % 520)
                lineColors[row % lineColors.count].withAlphaComponent(0.55).setFill()
                cg.fill(CGRect(x: editorX + indent, y: y, width: w, height: 14))
            }
        }
    }

    func attach(_ displayLayer: AVSampleBufferDisplayLayer) {
        renderer.attach(displayLayer)
        renderer.onDecodeFailure = { [weak self] in
            // The display layer failed; flush and pull a fresh keyframe.
            self?.receiver.requestKeyframe()
        }
    }

    func sendAnnotation(_ message: AnnotationMessage) {
        lastSentAnnotationSeq &+= 1
        annotationStatusText = "Sending annotations over frame stream"
        receiver.sendAnnotation(message, seq: lastSentAnnotationSeq)
    }

    private func acknowledgeAnnotation(_ seq: UInt32) {
        annotationStatusText = "Cockpit received your annotations"
    }

    /// Called on the receiver's internal queue.
    private nonisolated func handle(_ packet: FrameLink.Packet) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch packet {
            case .annotationAck(let seq):
                self.acknowledgeAnnotation(seq)
                return
            case .configuration(let config):
                self.videoSize = CGSize(width: config.width, height: config.height)
            case .sample(let sample):
                self.trackForFeedback(sample.frameID)
            case .appearance(let isDark):
                self.pilotColorScheme = isDark ? .dark : .light
                return
            case .annotation(_, let message):
                // A command from Pilot (undo/clear) — apply to the local canvas.
                self.onRemoteAnnotation?(message)
                return
            default:
                break
            }
            self.renderer.handle(packet)
        }
    }

    /// Tracks received vs. expected frameIDs to derive a coarse loss percentage
    /// for link feedback. P-frames carry monotonic IDs; a jump implies loss.
    private func trackForFeedback(_ frameID: UInt32) {
        receivedFrames += 1
        if let highest = highestFrameID {
            if frameID &- highest < UInt32(1) << 31, frameID != highest {
                // Newer frame: count the IDs we expected to have seen.
                expectedFrames += Int(frameID &- highest)
                highestFrameID = frameID
            }
        } else {
            highestFrameID = frameID
            expectedFrames += 1
        }
    }

    private func startFeedbackLoop() {
        feedbackTask?.cancel()
        feedbackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.emitLinkFeedback()
            }
        }
    }

    private func emitLinkFeedback() {
        guard expectedFrames > 0 else { return }
        let lost = max(0, expectedFrames - receivedFrames)
        let lossPct = min(100, (Double(lost) / Double(expectedFrames)) * 100)
        let queueDepth = renderer.coarseQueueDepth
        receiver.sendLinkFeedback(lossPct: lossPct, rttMs: 0, queueDepth: queueDepth)
        // Reset the window so each report reflects the most recent interval.
        expectedFrames = 0
        receivedFrames = 0
    }

    /// Conservative HEVC 4:4:4 decode capability check.
    ///
    /// `VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)` is necessary but
    /// not sufficient for 4:4:4 — the hardware path is typically 4:2:0 (and
    /// sometimes 4:2:2). There is no public API that cleanly reports 4:4:4
    /// support, so we stay safe and report `false` unless we can positively
    /// justify it. This keeps the sender on the universally decodable 4:2:0
    /// path; 4:4:4 can be re-enabled here once a device allow-list is proven.
    private static func supportsHEVC444Decode() -> Bool {
        false
    }

    /// Compatibility with the original JPEG stream. New Pilot builds send
    /// HEVC packets, so this path only updates diagnostics.
    private nonisolated func handleLegacyJPEG(_ data: Data) {
        Task { @MainActor in
            guard UIImage(data: data) != nil else { return }
            // Pilot now sends a periodic downscaled JPEG of its screen here.
            // Stash it in the App Group so the widget + Live Activity can show
            // a recent still, and nudge them to refresh.
            PlotterSnapshotStore.writeSnapshot(
                jpeg: data,
                status: PlotterSnapshotStore.Status(isConnected: true, title: "Cockpit", updatedAt: Date())
            )
            WidgetCenter.shared.reloadAllTimelines()
            PlotterActivityController.shared.touch(title: "Cockpit")
        }
    }
}

@MainActor
private final class HEVCMirrorRenderer {
    private weak var displayLayer: AVSampleBufferDisplayLayer?
    private var formatDescription: CMVideoFormatDescription?
    private var sampleIndex: Int64 = 0
    /// Monotonic decoder generation. Bumped on every new configuration so we can
    /// drop samples that predate the latest parameter sets (decoder generation).
    private var configGeneration: UInt64 = 0
    /// After a new configuration we wait for that GOP's keyframe before
    /// enqueuing, so the decoder never sees P-frames referencing frames it
    /// didn't decode. Gating on keyframe-seen (not frameID) is robust to TCP
    /// keyframes and UDP P-frames arriving out of order across the two channels.
    private var awaitingKeyframe = true
    /// Parameter sets of the configuration currently in force. The encoder
    /// resends configuration with every keyframe; we ignore byte-identical
    /// resends so we don't flush/flash the layer every ~2 seconds.
    private var lastVPS = Data()
    private var lastSPS = Data()
    private var lastPPS = Data()

    /// Invoked when the display layer reports a failed status so the model can
    /// flush and request a keyframe.
    var onDecodeFailure: (() -> Void)?

    /// A coarse proxy for receiver-side buffering pressure surfaced in link
    /// feedback. 0 when the layer is ready for data, 1 when it is backed up.
    var coarseQueueDepth: Int {
        guard let displayLayer else { return 0 }
        return displayLayer.isReadyForMoreMediaData ? 0 : 1
    }

    func attach(_ displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        displayLayer.preventsDisplaySleepDuringVideoPlayback = true
    }

    func handle(_ packet: FrameLink.Packet) {
        switch packet {
        case .configuration(let config):
            // The encoder resends configuration with every keyframe (~2s). If the
            // parameter sets are byte-identical, keep playing — rebuilding the
            // format description and flushing on every routine keyframe blanks the
            // layer and causes a ~2s black flash.
            if formatDescription != nil,
               config.vps == lastVPS, config.sps == lastSPS, config.pps == lastPPS {
                break
            }
            formatDescription = Self.makeFormatDescription(from: config)
            lastVPS = config.vps
            lastSPS = config.sps
            lastPPS = config.pps
            plotterMirrorLog.log("renderer: NEW configuration \(config.width, privacy: .public)x\(config.height, privacy: .public) -> formatDesc \(self.formatDescription == nil ? "NIL (build failed)" : "ok", privacy: .public)")
            sampleIndex = 0
            configGeneration &+= 1
            // Wait for the keyframe that pairs with this configuration before
            // enqueuing again (the encoder forces one right after config).
            awaitingKeyframe = true
            displayLayer?.flushAndRemoveImage()
        case .sample(let sample):
            enqueue(sample)
        case .annotation:
            break
        case .annotationAck:
            break
        case .keyframeRequest:
            break
        case .linkFeedback:
            break
        case .capability:
            break
        case .appearance:
            break
        case .jpeg:
            break
        case .ping, .pong:
            break
        }
    }

    private func enqueue(_ sample: FrameLink.VideoSample) {
        guard let displayLayer, formatDescription != nil else { return }

        // Decoder generation: after a new configuration, start on that GOP's
        // keyframe. Drop P-frames until it arrives so the decoder never
        // references frames it didn't decode.
        if awaitingKeyframe {
            guard sample.isKeyFrame else { return }
            awaitingKeyframe = false
        }

        if displayLayer.status == .failed {
            plotterMirrorLog.error("renderer: displayLayer FAILED: \(String(describing: displayLayer.error), privacy: .public); flushing + requesting keyframe")
            displayLayer.flush()
            onDecodeFailure?()
            return
        }

        guard let sampleBuffer = makeSampleBuffer(from: sample),
              displayLayer.isReadyForMoreMediaData else { return }
        displayLayer.enqueue(sampleBuffer)
    }

    private func makeSampleBuffer(from sample: FrameLink.VideoSample) -> CMSampleBuffer? {
        guard let formatDescription else { return nil }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: sample.data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: sample.data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let copyStatus = sample.data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return kCMBlockBufferNoErr }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: sample.data.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(value: sampleIndex, timescale: 60),
            decodeTimeStamp: .invalid
        )
        var sampleSize = sample.data.count
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else { return nil }

        sampleIndex += 1
        Self.setDisplayImmediatelyAttachment(on: sampleBuffer, isKeyFrame: sample.isKeyFrame)
        return sampleBuffer
    }

    private static func makeFormatDescription(from config: FrameLink.VideoConfiguration) -> CMVideoFormatDescription? {
        config.vps.withUnsafeBytes { vpsRawBuffer in
            config.sps.withUnsafeBytes { spsRawBuffer in
                config.pps.withUnsafeBytes { ppsRawBuffer in
                    guard let vpsBaseAddress = vpsRawBuffer.bindMemory(to: UInt8.self).baseAddress,
                          let spsBaseAddress = spsRawBuffer.bindMemory(to: UInt8.self).baseAddress,
                          let ppsBaseAddress = ppsRawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                        return nil
                    }

                    let parameterSetPointers = [vpsBaseAddress, spsBaseAddress, ppsBaseAddress]
                    let parameterSetSizes = [config.vps.count, config.sps.count, config.pps.count]
                    var formatDescription: CMVideoFormatDescription?
                    let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: parameterSetPointers,
                        parameterSetSizes: parameterSetSizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &formatDescription
                    )

                    return status == noErr ? formatDescription : nil
                }
            }
        }
    }

    private static func setDisplayImmediatelyAttachment(on sampleBuffer: CMSampleBuffer, isKeyFrame: Bool) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ) else { return }

        let attachment = unsafeBitCast(
            CFArrayGetValueAtIndex(attachments, 0),
            to: CFMutableDictionary.self
        )
        CFDictionarySetValue(
            attachment,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )

        if !isKeyFrame {
            CFDictionarySetValue(
                attachment,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
    }
}
