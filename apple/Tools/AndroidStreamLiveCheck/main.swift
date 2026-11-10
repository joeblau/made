// Live Android mirror recording check (GitHub issue #265).
//
// Build and run with apple/bin/check-android-stream-live.sh against a real,
// unlocked device. Drives Cockpit's own AndroidScreenStream (adb exec-out
// screenrecord -> H264AnnexBAssembler -> CMSampleBuffer) and
// AndroidStreamRecorder exactly as AndroidDeviceSession wires them, through
// three stream lifetimes on one connection epoch:
//
//   1. first stream
//   2. in-place restart (what record-start and rotation do)
//   3. screenrecord killed on the device after a healthy run, then the
//      session's restart policy respawns it
//
// It then decodes every frame of the recording and fails unless the recording
// is one segment that starts on a sync frame, decodes without error, has
// strictly increasing timestamps across both respawn seams, and contains
// every sample the recorder accepted. Swipes in the Settings app provide
// motion; the device is left on the screen it started from.

import AVFoundation
import CoreMedia
import Foundation

final class Stats: @unchecked Sendable {
    private let lock = NSLock()
    private var _samples = 0
    private var _idr = 0
    private var _recorded = 0
    private var _exits: [String] = []
    private var _segments: [(URL, String?)] = []
    private var _needsSync = 0
    private var _runtimes: [Duration] = []

    func sample(isIDR: Bool, recorded: Bool) {
        lock.withLock {
            _samples += 1
            if isIDR { _idr += 1 }
            if recorded { _recorded += 1 }
        }
    }
    func exit(_ text: String, runtime: Duration) { lock.withLock { _exits.append(text); _runtimes.append(runtime) } }
    func segment(_ url: URL, _ error: String?) { lock.withLock { _segments.append((url, error)) } }
    func needsSync() { lock.withLock { _needsSync += 1 } }
    var samples: Int { lock.withLock { _samples } }
    var idr: Int { lock.withLock { _idr } }
    var recorded: Int { lock.withLock { _recorded } }
    var exits: [String] { lock.withLock { _exits } }
    var runtimes: [Duration] { lock.withLock { _runtimes } }
    var segments: [(URL, String?)] { lock.withLock { _segments } }
    var needsSyncCount: Int { lock.withLock { _needsSync } }
}

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

@discardableResult
func adb(_ adbURL: URL, _ serial: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = adbURL
    process.arguments = ["-s", serial] + arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// Scrolls the Settings list for `seconds` so screenrecord emits a steady
/// stream of non-IDR frames between keyframes.
func motion(_ adbURL: URL, _ serial: String, seconds: Double, height: Int, width: Int) throws {
    let deadline = Date().addingTimeInterval(seconds)
    let x = width / 2
    var up = true
    while Date() < deadline {
        let (from, to) = up ? (height * 3 / 4, height / 4) : (height / 4, height * 3 / 4)
        try adb(adbURL, serial, ["shell", "input", "swipe", "\(x)", "\(from)", "\(x)", "\(to)", "250"])
        up.toggle()
    }
}

func waitUntil(timeout: Double, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

@main
struct AndroidStreamLiveCheck {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("android stream live check FAILED: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else {
            throw CheckFailure(description: "usage: android-stream-live-check <adb> <serial> <output-directory>")
        }
        let adbURL = URL(fileURLWithPath: arguments[1])
        let serial = arguments[2]
        let outputDirectory = URL(fileURLWithPath: arguments[3], isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let sizeLine = try adb(adbURL, serial, ["shell", "wm", "size"])
        let dimensions = sizeLine.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard dimensions.count >= 2 else { throw CheckFailure(description: "couldn't read wm size: \(sizeLine)") }
        let native = CGSize(width: dimensions[dimensions.count - 2], height: dimensions[dimensions.count - 1])
        print("device \(serial): \(Int(native.width))x\(Int(native.height))")

        try adb(adbURL, serial, ["shell", "am", "start", "-a", "android.settings.SETTINGS"])
        defer { _ = try? adb(adbURL, serial, ["shell", "input", "keyevent", "KEYCODE_BACK"]) }
        try await Task.sleep(for: .seconds(1))

        let stats = Stats()
        let recorder = AndroidStreamRecorder()
        recorder.onSegmentFinished = { url, error in stats.segment(url, error) }
        let epoch = ContinuousClock.now
        var policy = AndroidStreamPolicy()
        let layer = AVSampleBufferDisplayLayer()

        func makeStream() -> AndroidScreenStream {
            AndroidScreenStream(
                layer: layer,
                onFormat: { _, size in print("  format \(Int(size.width))x\(Int(size.height))") },
                onSample: { sample, isIDR in
                    // AndroidDeviceSession's tee, verbatim.
                    let active = recorder.isActive
                    if active, let format = CMSampleBufferGetFormatDescription(sample) {
                        recorder.append(sample, isIDR: isIDR, format: format)
                    }
                    stats.sample(isIDR: isIDR, recorded: active)
                },
                onNeedsSync: { stats.needsSync() },
                onExit: { exit, runtime, diagnostics in
                    let text: String
                    switch exit {
                    case .ended: text = "ended after \(runtime)"
                    case .poisoned(let reason): text = "POISONED after \(runtime): \(reason)"
                    }
                    stats.exit(text, runtime: runtime)
                }
            )
        }
        func start(_ stream: AndroidScreenStream, _ attempt: AndroidStreamPolicy.Attempt) {
            stream.start(configuration: AndroidScreenStream.Configuration(
                adbURL: adbURL,
                serial: serial,
                size: AdbBridge.cappedStreamSize(native: native, longEdge: attempt.longEdgeCap),
                timeLimitZero: attempt.timeLimitZero,
                epoch: epoch
            ))
        }
        let width = Int(native.width), height = Int(native.height)

        // Arm like toggleRecording(): the writer starts on the first IDR.
        let armed = recorder.arm { segment in outputDirectory.appendingPathComponent("segment-\(segment).mp4") }
        guard armed else { throw CheckFailure(description: "recorder refused to arm") }

        print("stage 1: first stream")
        var stream = makeStream()
        start(stream, policy.firstAttempt)
        try motion(adbURL, serial, seconds: 6, height: height, width: width)
        let stage1 = stats.samples

        print("stage 2: in-place restart (record-start / rotation path)")
        stream.stop()
        guard await waitUntil(timeout: 5, { stats.exits.count == 1 }) else {
            throw CheckFailure(description: "stream did not report its exit after stop()")
        }
        stream = makeStream()
        start(stream, policy.currentAttempt)
        try motion(adbURL, serial, seconds: 6, height: height, width: width)
        let stage2 = stats.samples - stage1

        print("stage 3: screenrecord killed on the device after a healthy run")
        try motion(adbURL, serial, seconds: 6, height: height, width: width)
        let beforeKill = stats.samples
        try adb(adbURL, serial, ["shell", "pkill", "screenrecord"])
        guard await waitUntil(timeout: 5, { stats.exits.count == 2 }) else {
            throw CheckFailure(description: "stream did not report the device-side kill")
        }
        // The killed child ran ~12 s, past the policy's 10 s healthy mark: the
        // genuine mid-flight failure branch, which respawns on proven settings.
        switch policy.nextDecision(runtime: stats.runtimes[1], diagnostics: "") {
        case .restart(let attempt):
            stream = makeStream()
            start(stream, attempt)
        case .fail(let message):
            throw CheckFailure(description: "restart policy gave up: \(message)")
        }
        try motion(adbURL, serial, seconds: 6, height: height, width: width)
        let stage3 = stats.samples - beforeKill

        stream.stop()
        _ = await waitUntil(timeout: 5, { stats.exits.count == 3 })
        recorder.stop()
        guard await waitUntil(timeout: 15, { !stats.segments.isEmpty }) else {
            throw CheckFailure(description: "recorder never finished its segment")
        }

        print("samples: total=\(stats.samples) idr=\(stats.idr) stage1=\(stage1) stage2=\(stage2) stage3-after-kill=\(stage3) recorded=\(stats.recorded) needsSync=\(stats.needsSyncCount)")
        for exit in stats.exits { print("  stream exit: \(exit)") }
        guard !stats.exits.contains(where: { $0.hasPrefix("POISONED") }) else {
            throw CheckFailure(description: "a stream was poisoned")
        }
        guard stage1 > 0, stage2 > 0, stage3 > 0 else {
            throw CheckFailure(description: "a stream lifetime produced no samples")
        }

        let segments = stats.segments
        for (url, error) in segments { print("  segment \(url.lastPathComponent) error=\(error ?? "none")") }
        guard segments.count == 1, segments[0].1 == nil else {
            throw CheckFailure(description: "expected one clean segment across both respawns, got \(segments.count)")
        }
        try await verify(segments[0].0, recorded: stats.recorded)
        print("android stream live check passed")
    }

    /// Decodes every frame and checks continuity across the respawn seams.
    static func verify(_ url: URL, recorded: Int) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CheckFailure(description: "recording has no video track")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        guard reader.startReading() else {
            throw CheckFailure(description: "reader failed to start: \(String(describing: reader.error))")
        }
        var frames = 0
        var previous: CMTime?
        var largestGap = CMTime.zero
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetImageBuffer(sample) != nil else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if let previous {
                guard pts > previous else {
                    throw CheckFailure(description: "timestamps went backwards at frame \(frames): \(pts.seconds) <= \(previous.seconds)")
                }
                largestGap = max(largestGap, pts - previous)
            }
            previous = pts
            frames += 1
        }
        guard reader.status == .completed else {
            throw CheckFailure(description: "decode failed after \(frames) frames: \(String(describing: reader.error))")
        }
        let fileBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        print(String(format: "recording: %d frames decoded, %.2f s, largest gap %.3f s, %d bytes",
                     frames, duration.seconds, largestGap.seconds, fileBytes))
        // Every stream lifetime opens on SPS/PPS + IDR and the stream drops
        // non-IDR frames until then, so the writer starts on the first teed
        // sample and must hold all of them: a shortfall is lost footage.
        guard frames == recorded else {
            throw CheckFailure(description: "decoded \(frames) frames; recorder was teed \(recorded)")
        }
        // Each seam is a short freeze while the respawned screenrecord sends
        // its SPS/PPS + IDR; anything near the 10 s keyframe interval means a
        // seam lost its sync frame.
        guard largestGap.seconds < 3 else {
            throw CheckFailure(description: "a respawn seam left a \(largestGap.seconds) s gap")
        }
    }
}
