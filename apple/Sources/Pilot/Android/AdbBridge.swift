import CoreGraphics
import Foundation

/// Errors surfaced by `adb` invocations. `toolingMissing` is the friendly case
/// for a machine without Android platform-tools — the pane shows install
/// guidance instead of failing opaquely.
enum AdbError: Error {
    case toolingMissing
    case commandFailed(String)
    case invalidOutput(String)
}

/// Source category selected by the Android launcher. Both categories use the
/// same embedded ADB stream; this filter keeps each picker focused on the
/// destination the user requested.
enum AndroidPaneTarget: String, CaseIterable, Sendable {
    case simulator
    case device

    var pickerTitle: String {
        switch self {
        case .simulator: "Android Simulator"
        case .device: "Android Device"
        }
    }

    func includes(_ device: AndroidDevice) -> Bool {
        switch self {
        case .simulator: device.isEmulator
        case .device: !device.isEmulator
        }
    }
}

/// One Android device from `adb devices -l`.
struct AndroidDevice: Identifiable, Hashable, Sendable {
    /// adb connection states we act on. Anything unrecognized maps to `.other`
    /// and renders as a disabled row (never connect to an unknown state).
    enum State: String, Sendable {
        case device
        case unauthorized
        case offline
        case other
    }

    let serial: String
    let state: State
    let model: String?
    let product: String?

    var id: String { serial }
    var isConnectable: Bool { state == .device }
    var isEmulator: Bool { serial.hasPrefix("emulator-") }

    /// "sdk_gphone64_arm64" → "sdk gphone64 arm64"; falls back to the serial.
    var displayName: String {
        guard let model, !model.isEmpty else { return serial }
        return model.replacingOccurrences(of: "_", with: " ")
    }
}

/// Typed wrapper over the user's `adb` CLI. Pilot never bundles or downloads
/// adb (binary-provenance policy): it resolves the user's own install and
/// degrades to guidance when none exists. Bounded one-shot calls go through
/// `ProcessRunner`; the long-lived stream/shell/rotation children are raw
/// `Process` factories whose callers own the lifecycle (the
/// `SimctlBridge.makeVideoRecordingProcess` convention).
///
/// Note: any adb invocation auto-starts the user's adb server daemon on
/// localhost:5037. That is standard behavior of the user's own tool — Pilot
/// itself opens no sockets — but it is why first calls get generous timeouts.
enum AdbBridge {
    // MARK: - Executable resolution

    /// Explicit candidates first: Finder-launched apps get a minimal PATH, so
    /// the well-known install locations must not depend on it.
    static var adbCandidatePaths: [String] {
        var candidates: [String] = []
        let environment = ProcessInfo.processInfo.environment
        for variable in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let root = environment[variable], !root.isEmpty {
                candidates.append((root as NSString).appendingPathComponent("platform-tools/adb"))
            }
        }
        candidates.append(("~/Library/Android/sdk/platform-tools/adb" as NSString).expandingTildeInPath)
        candidates.append("/opt/homebrew/bin/adb")
        candidates.append("/usr/local/bin/adb")
        for entry in (environment["PATH"] ?? "").split(separator: ":") where !entry.isEmpty {
            candidates.append((String(entry) as NSString).appendingPathComponent("adb"))
        }
        return candidates
    }

    /// First executable candidate wins. Deliberately not cached: the pane
    /// re-resolves on every refresh so installing adb doesn't need a relaunch.
    static func resolveAdbURL() -> URL? {
        for path in adbCandidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    // MARK: - Bounded one-shot commands

    private static func run(
        adbURL: URL,
        arguments: [String],
        timeout: Duration = .seconds(15),
        standardOutputLimit: Int = 1 * 1_024 * 1_024
    ) throws -> Data {
        let invocation = ProcessInvocation(
            executableURL: adbURL,
            arguments: arguments,
            timeout: timeout,
            standardOutputLimit: standardOutputLimit,
            standardErrorLimit: 256 * 1_024
        )
        do {
            return try ProcessRunner.runBlocking(invocation).standardOutput
        } catch let error as ProcessRunnerError {
            let message = error.result?.standardErrorString ?? error.localizedDescription
            throw AdbError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - Device listing

    /// Serials become `-s` argv elements (never shell-interpolated) and render
    /// in UI, so validate them anyway — an adversarial adb server must not be
    /// able to smuggle arbitrary strings into either place.
    static func isValidSerial(_ serial: String) -> Bool {
        guard (1...128).contains(serial.count) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:-"))
        return serial.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func listDevices() throws -> [AndroidDevice] {
        guard let adbURL = resolveAdbURL() else { throw AdbError.toolingMissing }
        let data = try run(adbURL: adbURL, arguments: ["devices", "-l"])
        return parseDevicesOutput(String(decoding: data, as: UTF8.self))
    }

    /// Parse `adb devices -l`. Bounded: at most 64 devices, fields truncated.
    /// Lines before the "List of devices attached" header (daemon-start noise)
    /// and unparseable lines are skipped.
    static func parseDevicesOutput(_ output: String) -> [AndroidDevice] {
        var devices: [AndroidDevice] = []
        var sawHeader = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if devices.count >= 64 { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !sawHeader {
                if trimmed.hasPrefix("List of devices attached") { sawHeader = true }
                continue
            }
            let fields = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 2 else { continue }
            let serial = fields[0]
            guard isValidSerial(serial) else { continue }
            let state = AndroidDevice.State(rawValue: fields[1]) ?? .other
            var model: String?
            var product: String?
            for field in fields.dropFirst(2) {
                if field.hasPrefix("model:") { model = String(field.dropFirst("model:".count).prefix(128)) }
                if field.hasPrefix("product:") { product = String(field.dropFirst("product:".count).prefix(128)) }
            }
            devices.append(AndroidDevice(serial: serial, state: state, model: model, product: product))
        }
        return devices.sorted { lhs, rhs in
            if lhs.isConnectable != rhs.isConnectable { return lhs.isConnectable }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    // MARK: - Emulator correlation

    /// The AVD backing a running emulator, via `adb -s <serial> emu avd name`
    /// (output is the AVD id on its own line, followed by an `OK` line). Returns
    /// nil for physical devices or on any error. Lets the Simulator picker hide
    /// AVDs that are already running from its "boot one" list.
    static func emulatorAVDName(adbURL: URL, serial: String) -> String? {
        guard let data = try? run(
            adbURL: adbURL,
            arguments: ["-s", serial, "emu", "avd", "name"],
            timeout: .seconds(5)
        ) else { return nil }
        return parseAVDNameOutput(String(decoding: data, as: UTF8.self))
    }

    /// The emulator console answers in CRLF lines ("Pixel_9_API_36\r\nOK\r\n").
    /// Swift treats "\r\n" as one Character, so splitting on "\n" alone kept
    /// the whole reply as one line and returned "Pixel_9_API_36\r\nOK" — which
    /// never matched an installed AVD and leaked "OK" into the picker title.
    static func parseAVDNameOutput(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let name = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty || name == "OK" { continue }
            // The name now renders in the picker, so hold it to the same
            // allowlist as `-list-avds` output (untrusted device input).
            return EmulatorBridge.isValidAVDName(name) ? name : nil
        }
        return nil
    }

    /// Whether `sys.boot_completed` is set — the emulator has finished booting
    /// and its screen/services are up. Used to wait out a fresh emulator boot
    /// before connecting the mirror.
    static func isBootCompleted(adbURL: URL, serial: String) -> Bool {
        guard let data = try? run(
            adbURL: adbURL,
            arguments: ["-s", serial, "shell", "getprop", "sys.boot_completed"],
            timeout: .seconds(5)
        ) else { return false }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    // MARK: - Display size

    /// Current display size from `adb shell wm size`, in the device's natural
    /// (portrait) orientation. Prefers "Override size" when present.
    static func displaySize(adbURL: URL, serial: String) throws -> CGSize {
        let data = try run(adbURL: adbURL, arguments: ["-s", serial, "shell", "wm", "size"])
        guard let size = parseWindowSize(String(decoding: data, as: UTF8.self)) else {
            throw AdbError.invalidOutput("Couldn't read the device display size.")
        }
        return size
    }

    static func parseWindowSize(_ output: String) -> CGSize? {
        var physical: CGSize?
        var override: CGSize?
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parsed: CGSize?
            if trimmed.hasPrefix("Physical size:") {
                parsed = parseSizeValue(trimmed.dropFirst("Physical size:".count))
                physical = parsed ?? physical
            } else if trimmed.hasPrefix("Override size:") {
                parsed = parseSizeValue(trimmed.dropFirst("Override size:".count))
                override = parsed ?? override
            }
        }
        return override ?? physical
    }

    private static func parseSizeValue(_ value: Substring) -> CGSize? {
        let parts = value.trimmingCharacters(in: .whitespaces).split(separator: "x")
        guard parts.count == 2,
              let width = Int(parts[0]), let height = Int(parts[1]),
              (16...16_384).contains(width), (16...16_384).contains(height) else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Scale a native size down so the long edge fits `longEdge`, both
    /// dimensions rounded down to multiples of 8: hardware AVC encoders want
    /// aligned dimensions, and an odd size like 718 wide can push an OEM
    /// encoder onto a slow software path. The ≤1% aspect shift is invisible,
    /// and input mapping uses `wm size`, not the video size, so it is exact
    /// either way.
    static func cappedStreamSize(native: CGSize, longEdge: Int = 1_600) -> CGSize {
        let longest = max(native.width, native.height)
        var scaled = native
        if longest > CGFloat(longEdge) {
            let scale = CGFloat(longEdge) / longest
            scaled = CGSize(width: native.width * scale, height: native.height * scale)
        }
        let alignedWidth = max(16, Int(scaled.width) & ~7)
        let alignedHeight = max(16, Int(scaled.height) & ~7)
        return CGSize(width: alignedWidth, height: alignedHeight)
    }

    // MARK: - Rotation

    /// One-shot rotation probe, used at connect time so a device already in
    /// landscape streams and maps input correctly from the first frame.
    static func currentRotation(adbURL: URL, serial: String) -> Int? {
        let script = "dumpsys window displays 2>/dev/null | grep -m1 -o 'rotation=[0-9]'"
        guard let data = try? run(adbURL: adbURL, arguments: ["-s", serial, "shell", script]),
              let line = String(decoding: data, as: UTF8.self)
                  .split(separator: "\n").first else { return nil }
        return parseRotationLine(String(line))
    }

    /// Parse a `rotation=N` line from the rotation watch loop.
    static func parseRotationLine(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("rotation="), trimmed.count == "rotation=".count + 1,
              let digit = trimmed.last?.wholeNumberValue, (0...3).contains(digit) else { return nil }
        return digit
    }

    // MARK: - Screenshot

    private static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    /// Full-resolution PNG of the device screen via `screencap`. The 32 MiB
    /// stdout cap is enforced by ProcessRunner during the pipe drain, so an
    /// adversarial device cannot balloon memory; the PNG signature is checked
    /// before ImageIO ever sees the bytes.
    static func screenshotPNG(adbURL: URL, serial: String) throws -> Data {
        let data = try run(
            adbURL: adbURL,
            arguments: ["-s", serial, "exec-out", "screencap", "-p"],
            standardOutputLimit: 32 * 1_024 * 1_024
        )
        guard data.count > pngSignature.count, data.prefix(pngSignature.count) == pngSignature else {
            throw AdbError.invalidOutput("The device returned an invalid screenshot.")
        }
        return data
    }

    // MARK: - Long-lived child factories (callers own the lifecycle)

    /// The live mirror stream: raw H.264 Annex-B on stdout. `exec-out` gives
    /// clean binary output (plain `adb shell` mangles newlines through a pty).
    static func makeScreenStreamProcess(
        adbURL: URL,
        serial: String,
        size: CGSize?,
        bitRate: Int,
        timeLimitZero: Bool
    ) -> Process {
        var arguments = ["-s", serial, "exec-out", "screenrecord", "--output-format=h264"]
        arguments.append("--bit-rate")
        arguments.append(String(min(max(bitRate, 1_000_000), 50_000_000)))
        if let size {
            arguments.append("--size")
            arguments.append("\(Int(size.width))x\(Int(size.height))")
        }
        if timeLimitZero {
            // Android 10+ accepts 0 = unlimited; older screenrecord rejects it
            // and exits immediately, which the restart policy detects and
            // retries without the flag (falling back to 180 s + auto-respawn).
            arguments.append("--time-limit")
            arguments.append("0")
        }
        arguments.append("-")
        let process = Process()
        process.executableURL = adbURL
        process.arguments = arguments
        return process
    }

    /// The persistent input shell. Commands are newline-terminated `input …`
    /// lines written to stdin, amortizing the ~100 ms per-invocation adb spawn
    /// cost; stdout/stderr are drained and discarded, never parsed.
    static func makeInteractiveShellProcess(adbURL: URL, serial: String) -> Process {
        let process = Process()
        process.executableURL = adbURL
        process.arguments = ["-s", serial, "shell"]
        return process
    }

    /// The rotation watcher: screenrecord does NOT reliably exit when the
    /// device rotates (it keeps encoding with the stale projection), so the
    /// session polls rotation on-device and force-restarts the stream on
    /// change. One long-lived child emitting one tiny `rotation=N` line every
    /// 2 s beats spawning a fresh adb process per poll.
    static func makeRotationWatchProcess(adbURL: URL, serial: String) -> Process {
        let loop = "while true; do dumpsys window displays 2>/dev/null | grep -m1 -o 'rotation=[0-9]'; sleep 2; done"
        let process = Process()
        process.executableURL = adbURL
        process.arguments = ["-s", serial, "shell", loop]
        return process
    }
}
