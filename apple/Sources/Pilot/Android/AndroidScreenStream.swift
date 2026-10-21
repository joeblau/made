import AVFoundation
import CoreMedia
import Darwin
import Foundation
import OSLog

/// How one screenrecord invocation ended.
enum AndroidStreamExit: Sendable {
    /// EOF / clean exit: the 180 s cap, device disconnect, or `stop()`.
    case ended
    /// The parser hit an allocation bound or the stream produced garbage —
    /// treated like a death, but the reason is worth logging distinctly.
    case poisoned(String)
}

/// One `adb exec-out screenrecord` invocation: owns the child Process, drains
/// its stdout through `H264AnnexBAssembler` on a dedicated reader task, builds
/// AVCC `CMSampleBuffer`s, enqueues them into the display layer (with
/// backpressure), and tees every sample to the recorder callback. The restart
/// loop lives in `AndroidDeviceSession`; this type never respawns itself.
///
/// `@unchecked Sendable`: all mutable state is confined to `stateQueue`; the
/// display-layer renderer's `enqueue` is the supported off-main sink (the
/// `SimulatorFramebuffer` isolation pattern).
final class AndroidScreenStream: @unchecked Sendable {
    struct Configuration {
        var adbURL: URL
        var serial: String
        var size: CGSize?
        /// Deliberately high: screenrecord's pipeline flushes on byte count,
        /// so a higher bitrate measurably reduces frame batching (emulator
        /// probe: p90 inter-frame gap 72 ms at 20 Mbps vs 114 ms at 8 Mbps).
        /// USB bandwidth is far above this and decode is trivial.
        var bitRate: Int = 16_000_000
        var timeLimitZero: Bool
        /// Shared per-connection clock anchor so sample PTS stays monotonic
        /// across stream restarts — what lets a recording span respawns.
        var epoch: ContinuousClock.Instant
    }

    private let layer: AVSampleBufferDisplayLayer
    private let onFormat: @Sendable (CMVideoFormatDescription, CGSize) -> Void
    private let onSample: @Sendable (CMSampleBuffer, Bool) -> Void
    /// Fired when the display path needs a sync frame it cannot get from the
    /// stream soon (screenrecord's keyframe interval is ~10 s): the session
    /// restarts the stream, whose fresh SPS/PPS+IDR arrives in well under a
    /// second — a short freeze instead of a ten-second one.
    private let onNeedsSync: @Sendable () -> Void
    private let onExit: @Sendable (AndroidStreamExit, Duration, String) -> Void

    private let stateQueue = DispatchQueue(label: "app.blau.pilot.android.stream", qos: .userInteractive)
    private let logger = Logger(subsystem: "app.blau.pilot.android", category: "stream")

    private var process: Process?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var assembler = H264AnnexBAssembler()
    private var formatDescription: CMVideoFormatDescription?
    private var awaitingIDR = false
    /// Set after a backpressure drop or renderer flush: the decoder is missing
    /// references, so non-IDR frames are skipped until the next sync frame.
    private var awaitingDisplayIDR = false
    private var stopped = false
    private var exitReported = false
    private var startedAt: ContinuousClock.Instant?
    private var epoch: ContinuousClock.Instant?
    /// Bounded stderr tail for failure diagnostics; never parsed for control.
    private var stderrTail = Data()
    private static let stderrTailLimit = 4 * 1_024

    init(
        layer: AVSampleBufferDisplayLayer,
        onFormat: @escaping @Sendable (CMVideoFormatDescription, CGSize) -> Void,
        onSample: @escaping @Sendable (CMSampleBuffer, Bool) -> Void,
        onNeedsSync: @escaping @Sendable () -> Void,
        onExit: @escaping @Sendable (AndroidStreamExit, Duration, String) -> Void
    ) {
        self.layer = layer
        self.onFormat = onFormat
        self.onSample = onSample
        self.onNeedsSync = onNeedsSync
        self.onExit = onExit
    }

    func start(configuration: Configuration) {
        stateQueue.async { [self] in
            guard process == nil, !stopped else { return }
            epoch = configuration.epoch
            startedAt = ContinuousClock.now

            let child = AdbBridge.makeScreenStreamProcess(
                adbURL: configuration.adbURL,
                serial: configuration.serial,
                size: configuration.size,
                bitRate: configuration.bitRate,
                timeLimitZero: configuration.timeLimitZero
            )
            let stdout = Pipe()
            let stderr = Pipe()
            child.standardOutput = stdout
            child.standardError = stderr
            child.terminationHandler = { [weak self] _ in
                self?.handleTermination()
            }

            stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    // EOF: a readability source is level-triggered and would
                    // fire forever; detach it here.
                    handle.readabilityHandler = nil
                    return
                }
                guard let self else {
                    handle.readabilityHandler = nil
                    return
                }
                self.stateQueue.async {
                    // Keep the LAST bytes — the fatal message arrives right
                    // before exit, after any startup chatter.
                    self.stderrTail.append(chunk)
                    if self.stderrTail.count > Self.stderrTailLimit {
                        self.stderrTail.removeFirst(self.stderrTail.count - Self.stderrTailLimit)
                    }
                }
            }

            do {
                try child.run()
            } catch {
                stderr.fileHandleForReading.readabilityHandler = nil
                reportExit(.poisoned("Couldn't launch adb: \(error.localizedDescription)"))
                return
            }
            process = child
            stdoutHandle = stdout.fileHandleForReading
            stderrHandle = stderr.fileHandleForReading

            // Blocking pipe reads live on a dedicated thread, never on the
            // width-limited Swift cooperative pool (the ProcessRunner/GCD
            // convention). stop()/reportExit close the handle, which unblocks
            // a wedged read, so the thread always exits.
            let handle = stdout.fileHandleForReading
            let reader = Thread { [weak self] in
                while true {
                    guard let chunk = try? handle.read(upToCount: 64 * 1_024), !chunk.isEmpty else { break }
                    guard let self else { return }
                    self.stateQueue.sync { self.consume(chunk) }
                }
                self?.stateQueue.async { self?.handleEOF() }
            }
            reader.name = "app.blau.pilot.android.stream-reader"
            reader.qualityOfService = .userInitiated
            reader.start()
        }
    }

    /// Terminate the child. The exit callback still fires (generation-checked
    /// by the session), reporting `.ended`.
    func stop() {
        stateQueue.async { [self] in
            stopped = true
            if let process, process.isRunning {
                process.terminate()
                let pid = process.processIdentifier
                stateQueue.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
                    if let current = self?.process, current.processIdentifier == pid, current.isRunning {
                        Darwin.kill(pid, SIGKILL)
                    }
                }
            }
        }
    }

    // MARK: - Reader path (stateQueue)

    private func consume(_ chunk: Data) {
        guard !stopped else { return }
        do {
            try handle(events: assembler.feed(chunk))
        } catch {
            poison("The device sent an invalid video stream (\(error)).")
        }
    }

    private func handleEOF() {
        guard !stopped else {
            reportExit(.ended)
            return
        }
        // Emit whatever frame is still buffered, then report.
        if let events = try? assembler.flushTrailing() {
            try? handle(events: events)
        }
        reportExit(.ended)
    }

    private func handleTermination() {
        // EOF on stdout is the primary exit signal (it fires after the pipe
        // drains); termination is the backstop for a child that dies without
        // ever producing output, where the reader may block forever.
        stateQueue.asyncAfter(deadline: .now() + .seconds(1)) { [weak self] in
            self?.reportExit(.ended)
        }
    }

    private func poison(_ reason: String) {
        logger.error("stream poisoned: \(reason, privacy: .public)")
        stopped = true
        if let process, process.isRunning {
            process.terminate()
        }
        reportExit(.poisoned(reason))
    }

    private func reportExit(_ exit: AndroidStreamExit) {
        guard !exitReported else { return }
        exitReported = true
        // Detach the stderr source and close stdout so a reader thread wedged
        // on a stuck pipe (a child that never wrote) gets unblocked instead
        // of leaking with the FileHandle.
        stderrHandle?.readabilityHandler = nil
        stderrHandle = nil
        try? stdoutHandle?.close()
        stdoutHandle = nil
        let runtime = startedAt.map { $0.duration(to: .now) } ?? .zero
        let diagnostics = String(decoding: stderrTail, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        onExit(exit, runtime, diagnostics)
    }

    // MARK: - Events → CoreMedia (stateQueue)

    private func handle(events: [H264AnnexBAssembler.Event]) throws {
        for event in events {
            switch event {
            case .parameterSets(let sps, let pps):
                guard let format = Self.makeFormatDescription(sps: sps, pps: pps) else {
                    poison("The device sent unparseable video parameters.")
                    return
                }
                let dimensions = CMVideoFormatDescriptionGetDimensions(format)
                guard (16...8_192).contains(dimensions.width), (16...8_192).contains(dimensions.height) else {
                    poison("The device reported an implausible video size.")
                    return
                }
                formatDescription = format
                // After a configuration change, drop VCL data until the paired
                // IDR so the decoder never references frames it didn't decode.
                awaitingIDR = true
                onFormat(format, CGSize(width: Int(dimensions.width), height: Int(dimensions.height)))
            case .accessUnit(let data, let isIDR):
                guard let formatDescription else { continue }
                if awaitingIDR {
                    guard isIDR else { continue }
                    awaitingIDR = false
                }
                guard let sample = makeSampleBuffer(data: data, isIDR: isIDR, format: formatDescription) else {
                    continue
                }
                enqueue(sample, isIDR: isIDR)
                onSample(sample, isIDR)
            }
        }
    }

    private func enqueue(_ sample: CMSampleBuffer, isIDR: Bool) {
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
            requestSyncFrame()
        }
        // After any drop or flush the decoder is missing references; feeding
        // it non-IDR frames would decode against frames it never saw. Wait
        // for the next sync frame.
        if awaitingDisplayIDR {
            guard isIDR else { return }
            awaitingDisplayIDR = false
        }
        // Backpressure: never queue unboundedly against a stalled renderer.
        // Non-IDR frames are droppable; an IDR is the recovery point, so make
        // room for it instead.
        if !renderer.isReadyForMoreMediaData {
            guard isIDR else {
                requestSyncFrame()
                return
            }
            renderer.flush()
        }
        renderer.enqueue(sample)
    }

    /// Gate the display on the next sync frame AND ask the session for one:
    /// waiting passively would freeze the mirror for up to screenrecord's
    /// ~10 s keyframe interval, while a stream restart delivers an IDR fast.
    private func requestSyncFrame() {
        guard !awaitingDisplayIDR else { return }
        awaitingDisplayIDR = true
        onNeedsSync()
    }

    private func makeSampleBuffer(data: Data, isIDR: Bool, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        guard let epoch else { return nil }

        // PTS = host arrival time against the per-connection epoch: monotonic
        // across restarts (recorder continuity), and screenrecord emits no
        // B-frames so decode order == display order.
        let elapsed = epoch.duration(to: .now)
        let nanoseconds = elapsed.components.seconds * 1_000_000_000
            + elapsed.components.attoseconds / 1_000_000_000
        let timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: nanoseconds, timescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )
        return try? EncodedVideoSample.make(
            payload: data,
            format: format,
            timing: timing,
            attachments: .displayImmediately(isSync: isIDR)
        )
    }

    private static func makeFormatDescription(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        sps.withUnsafeBytes { spsRawBuffer -> CMVideoFormatDescription? in
            pps.withUnsafeBytes { ppsRawBuffer -> CMVideoFormatDescription? in
                guard let spsBase = spsRawBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let ppsBase = ppsRawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return nil
                }
                let pointers = [spsBase, ppsBase]
                let sizes = [sps.count, pps.count]
                var formatDescription: CMVideoFormatDescription?
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDescription
                )
                return status == noErr ? formatDescription : nil
            }
        }
    }

}
