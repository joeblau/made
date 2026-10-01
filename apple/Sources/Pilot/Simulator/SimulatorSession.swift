import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import OSLog

/// Drives one iPhone Simulator pane via **direct simulator forwarding** (the
/// serve-sim technique): boots a device with `simctl`, captures its framebuffer
/// `IOSurface` straight from CoreSimulator/SimulatorKit (just the device screen —
/// no DeviceHub window, no Screen Recording), and injects touch/keyboard with
/// SimulatorKit's HID client.
///
/// Runtime-only (the registry keys it by `Pane.id`); no SwiftData. Async capture
/// work is tagged with a monotonic `captureGeneration` so a teardown or new boot
/// invalidates superseded work.
@MainActor
@Observable
final class SimulatorSession {
    enum Status: Equatable {
        case picking
        case booting(String)
        case starting(String)
        case streaming
        case failed(String)
        case toolingMissing
    }

    var status: Status = .picking
    var devices: [SimRuntimeGroup] = []
    var isRefreshing = false
    var lastError: String?
    var isRecording = false
    /// Increments after each successful clipboard write so the pane can show a
    /// confirmation even when screenshots are copied back-to-back.
    var clipboardCopyCount = 0

    private(set) var bootedDeviceName: String?
    private(set) var bootedUDID: String?

    /// Live video surface; hosted by `SimulatorCaptureHostView`.
    @ObservationIgnored let displayLayer = AVSampleBufferDisplayLayer()
    /// Framebuffer pixel size, for input coordinate mapping. Read directly by the
    /// (AppKit) host view, so it doesn't need SwiftUI observation.
    @ObservationIgnored private(set) var captureSize: CGSize?

    @ObservationIgnored private var framebuffer: SimulatorFramebuffer?
    @ObservationIgnored private var hid: SimulatorHID?
    @ObservationIgnored private var captureGeneration = 0
    @ObservationIgnored private var recordingProcess: Process?
    @ObservationIgnored private var recordingID: UUID?
    @ObservationIgnored private var recordingURL: URL?
    @ObservationIgnored private var recordingStopWasRequested = false
    @ObservationIgnored private let logger = Logger(subsystem: "app.blau.pilot.simulator", category: "session")

    init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.clear.cgColor
    }

    // MARK: - Device list

    private enum LoadResult: Sendable {
        case success([SimRuntimeGroup])
        case toolingMissing
        case failure(String)
    }

    func refreshDevices() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            let result = await Self.loadDevices()
            self.isRefreshing = false
            switch result {
            case .success(let groups):
                self.devices = groups
                self.lastError = nil
                if self.status == .toolingMissing { self.status = .picking }
            case .toolingMissing:
                self.status = .toolingMissing
            case .failure(let message):
                self.logger.error("simctl list failed: \(message, privacy: .public)")
                self.devices = []
                self.lastError = message
            }
        }
    }

    private static func loadDevices() async -> LoadResult {
        await Task.detached(priority: .userInitiated) {
            do { return .success(try SimctlBridge.listDevices()) }
            catch SimctlError.toolingMissing { return .toolingMissing }
            catch { return .failure(error.localizedDescription) }
        }.value
    }

    // MARK: - Boot + capture

    func boot(_ device: SimDevice) {
        captureGeneration &+= 1
        let generation = captureGeneration
        teardownCapture()

        bootedDeviceName = device.name
        bootedUDID = device.udid
        status = .booting(device.name)

        Task {
            let outcome = await Self.performBoot(device)
            guard generation == self.captureGeneration else { return }
            switch outcome {
            case .none:
                self.status = .starting(device.name)
                self.startCapture(device: device, generation: generation)
            case .toolingMissing:
                self.status = .toolingMissing
            case .message(let message):
                self.status = .failed(message)
            }
        }
    }

    private enum BootOutcome: Sendable { case none; case toolingMissing; case message(String) }

    private static func performBoot(_ device: SimDevice) async -> BootOutcome {
        await Task.detached(priority: .userInitiated) {
            do {
                if !device.isBooted { try SimctlBridge.boot(udid: device.udid) }
                SimctlBridge.bootStatus(udid: device.udid)
                return .none
            } catch SimctlError.toolingMissing {
                return .toolingMissing
            } catch SimctlError.commandFailed(let message) {
                return .message(message)
            } catch {
                return .message(error.localizedDescription)
            }
        }.value
    }

    private func startCapture(device: SimDevice, generation: Int) {
        guard generation == captureGeneration else { return }

        // HID is best-effort: capture can still show a read-only screen if the
        // SimulatorKit HID client can't be created.
        hid = try? SimulatorHID(deviceUDID: device.udid)

        let framebuffer = SimulatorFramebuffer(layer: displayLayer) { [weak self] width, height in
            Task { @MainActor in
                guard let self, generation == self.captureGeneration else { return }
                self.captureSize = CGSize(width: width, height: height)
            }
        }
        do {
            try framebuffer.start(deviceUDID: device.udid)
            self.framebuffer = framebuffer
            self.status = .streaming
        } catch {
            self.status = .failed(
                "Couldn't read the simulator framebuffer (\(error.localizedDescription)). This needs a full Xcode with the private CoreSimulator/SimulatorKit frameworks."
            )
        }
    }

    // MARK: - Teardown

    private func teardownCapture() {
        stopRecording()
        framebuffer?.stop()
        framebuffer = nil
        hid = nil
        captureSize = nil
        displayLayer.flushAndRemoveImage()
    }

    /// Stop capturing but leave the simulator booted. Called by the registry on
    /// pane removal.
    func stop() {
        captureGeneration &+= 1
        teardownCapture()
    }

    func chooseAnotherDevice() {
        stop()
        bootedDeviceName = nil
        bootedUDID = nil
        status = .picking
        refreshDevices()
    }

    func shutdownSimulator() {
        let udid = bootedUDID
        stop()
        bootedDeviceName = nil
        bootedUDID = nil
        status = .picking
        if let udid {
            Task {
                await Self.performShutdown(udid)
                self.refreshDevices()
            }
        } else {
            refreshDevices()
        }
    }

    private static func performShutdown(_ udid: String) async {
        await Task.detached(priority: .utility) { try? SimctlBridge.shutdown(udid: udid) }.value
    }

    // MARK: - Media capture

    func toggleRecording() {
        guard status == .streaming || isRecording else { return }
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard !isRecording, status == .streaming, let udid = bootedUDID else { return }

        let url = Self.timestampedURL(name: "Simulator Recording", ext: "mov")
        let process = SimctlBridge.makeVideoRecordingProcess(udid: udid, to: url)
        let id = UUID()
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor [weak self] in
                self?.recordingDidFinish(id: id, terminationStatus: status)
            }
        }

        // Install the identity before launch so even an immediate simctl exit
        // is matched by the termination callback. Roll it back if launch itself
        // throws before a child process exists.
        recordingProcess = process
        recordingID = id
        recordingURL = url
        recordingStopWasRequested = false
        isRecording = true
        lastError = nil

        do {
            try process.run()
        } catch {
            recordingProcess = nil
            recordingID = nil
            recordingURL = nil
            recordingStopWasRequested = false
            isRecording = false
            lastError = "Couldn't start recording: \(error.localizedDescription)"
            logger.error("start recording failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Send SIGINT instead of terminating the process so `simctl` writes the
    /// movie trailer and leaves a playable file on the Desktop.
    private func stopRecording() {
        guard let process = recordingProcess else { return }
        recordingStopWasRequested = true
        if process.isRunning {
            process.interrupt()
        }
    }

    private func recordingDidFinish(id: UUID, terminationStatus: Int32) {
        guard recordingID == id else { return }

        let stopWasRequested = recordingStopWasRequested
        let url = recordingURL
        recordingProcess = nil
        recordingID = nil
        recordingURL = nil
        recordingStopWasRequested = false
        isRecording = false

        let fileSize = url.flatMap { url -> Int64? in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes?[.size] as? NSNumber)?.int64Value
        } ?? 0
        guard fileSize > 0 else {
            lastError = "Recording ended without producing a video."
            logger.error("simulator recording produced no video")
            return
        }

        if !stopWasRequested, terminationStatus != 0 {
            lastError = "Recording stopped unexpectedly (simctl exited \(terminationStatus))."
            logger.error("simulator recording exited unexpectedly: \(terminationStatus)")
        } else {
            lastError = nil
        }
    }

    func takeScreenshot() {
        guard status == .streaming, let udid = bootedUDID else { return }
        let url = Self.timestampedURL(name: "Simulator Screenshot", ext: "png")
        Task { [weak self] in
            let errorMessage = await Self.saveScreenshot(udid: udid, to: url)
            guard let self, self.bootedUDID == udid else { return }
            if let errorMessage {
                self.lastError = "Couldn't save screenshot: \(errorMessage)"
                self.logger.error("save screenshot failed: \(errorMessage, privacy: .public)")
            } else {
                self.lastError = nil
            }
        }
    }

    func copyScreenshotToClipboard() {
        guard status == .streaming, let udid = bootedUDID else { return }
        Task { [weak self] in
            let result = await Self.captureScreenshotData(udid: udid)
            guard let self, self.bootedUDID == udid else { return }
            switch result {
            case .success(let pngData):
                guard let image = NSImage(data: pngData) else {
                    self.lastError = "Couldn't decode the simulator screenshot."
                    return
                }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                let wroteImage = pasteboard.writeObjects([image])
                let wrotePNG = pasteboard.setData(pngData, forType: .png)
                let wroteAny = wroteImage || wrotePNG
                if wroteAny {
                    self.lastError = nil
                    self.clipboardCopyCount &+= 1
                } else {
                    self.lastError = "Couldn't put the screenshot on the clipboard."
                }
            case .failure(let message):
                self.lastError = "Couldn't copy screenshot: \(message)"
                self.logger.error("copy screenshot failed: \(message, privacy: .public)")
            }
        }
    }

    private enum ScreenshotDataResult: Sendable {
        case success(Data)
        case failure(String)
    }

    private static func saveScreenshot(udid: String, to url: URL) async -> String? {
        await Task.detached(priority: .userInitiated) {
            do {
                try SimctlBridge.takeScreenshot(udid: udid, to: url)
                return nil
            } catch {
                return simctlErrorMessage(error)
            }
        }.value
    }

    private static func captureScreenshotData(udid: String) async -> ScreenshotDataResult {
        await Task.detached(priority: .userInitiated) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Cockpit Simulator Screenshot \(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                try SimctlBridge.takeScreenshot(udid: udid, to: url)
                return .success(try Data(contentsOf: url))
            } catch {
                return .failure(simctlErrorMessage(error))
            }
        }.value
    }

    nonisolated private static func simctlErrorMessage(_ error: Error) -> String {
        switch error {
        case SimctlError.toolingMissing:
            "Full Xcode is required to capture the simulator."
        case SimctlError.commandFailed(let message):
            message
        default:
            error.localizedDescription
        }
    }

    private static func timestampedURL(name: String, ext: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        let filename = "\(name) \(formatter.string(from: Date())).\(ext)"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
            .appendingPathComponent(filename)
    }

    // MARK: - Input (normalized 0…1 coords, forwarded straight to the simulator)

    func touch(_ phase: SimulatorHID.TouchPhase, normalizedX: Double, normalizedY: Double, edge: SimulatorHID.Edge = .none) {
        hid?.sendTouch(phase, x: normalizedX, y: normalizedY, edge: edge)
    }

    /// Two-finger pinch (normalized coords for each finger).
    func pinch(_ phase: SimulatorHID.TouchPhase, x1: Double, y1: Double, x2: Double, y2: Double) {
        hid?.sendMultiTouch(phase, x1: x1, y1: y1, x2: x2, y2: y2)
    }

    /// Trackpad scroll, as normalized deltas + the cursor anchor.
    func scroll(normalizedDX: Double, normalizedDY: Double, anchorX: Double, anchorY: Double) {
        hid?.sendScroll(normalizedDX: normalizedDX, normalizedDY: normalizedDY, anchorX: anchorX, anchorY: anchorY)
    }

    func goHome() {
        hid?.sendHome()
    }

    func keyUsage(_ usage: UInt32, down: Bool) {
        hid?.sendKeyUsage(usage, down: down)
    }
}
