import AVFoundation
import AppKit
import AudioToolbox
import CoreMediaIO
import Foundation
import OSLog
import Observation

enum DeviceConnectionStatus: Sendable, Equatable {
    case picking
    case connecting
    case streaming
    case failed(String)
}

struct IOSCaptureDevice: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let modelID: String

    var detail: String? {
        let trimmedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty,
              trimmedModel.localizedCaseInsensitiveCompare(name) != .orderedSame else { return nil }
        return trimmedModel
    }
}

/// Conservative admission policy for the CMIO sources shown in the iOS
/// picker. AVFoundation does not expose a public "this is an iOS screen"
/// flag, so explicit iPhone/iPad identity metadata is the strongest signal.
/// A generic muxed source is admitted only when AVFoundation identifies its
/// manufacturer as Apple and its transport as USB; this keeps ordinary capture
/// cards and webcams out without dropping a renamed tethered iPhone whose
/// display/model name is generic.
enum IOSCaptureDiscoveryPolicy {
    /// `kIOAudioDeviceTransportTypeUSB` (`'usb '`). `AVCaptureDevice` exposes
    /// the value but AVFoundation does not provide a Swift-native enum for it.
    private static let usbTransportType = Int32(bitPattern: 0x7573_6220)

    static func includes(
        name: String,
        modelID: String,
        manufacturer: String,
        isMuxed: Bool,
        transportType: Int32
    ) -> Bool {
        let identity = "\(name) \(modelID)"
        let identityWords = identity.components(separatedBy: CharacterSet.alphanumerics.inverted)
        let hasIOSIdentity = identity.localizedCaseInsensitiveContains("iphone")
            || identity.localizedCaseInsensitiveContains("ipad")
            || identityWords.contains {
                $0.localizedCaseInsensitiveCompare("ios") == .orderedSame
            }
        if hasIOSIdentity { return true }

        let normalizedManufacturer = manufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
        return isMuxed
            && normalizedManufacturer.localizedCaseInsensitiveCompare("Apple Inc.") == .orderedSame
            && transportType == usbTransportType
    }
}

enum IOSCaptureAudioPairingPolicy {
    /// AVFoundation exposes no public relationship between separate video and
    /// audio capture devices. Only identical unique IDs are authoritative;
    /// names and model IDs are not unique when two phones are connected.
    static func matches(videoUniqueID: String, audioUniqueID: String) -> Bool {
        videoUniqueID == audioUniqueID
    }
}

enum CaptureFrameError: LocalizedError, Equatable {
    case timedOut
    case cancelled
    case sessionStopped
    case detached
    case coordinatorReleased

    var errorDescription: String? {
        switch self {
        case .timedOut:
            "No video frame arrived before the screenshot timed out. Wake the device and retry."
        case .cancelled:
            "The screenshot request was cancelled."
        case .sessionStopped:
            "The screenshot was cancelled because device capture stopped."
        case .detached:
            "The screenshot was cancelled because the device disconnected. Reconnect it and retry."
        case .coordinatorReleased:
            "The screenshot was cancelled because the capture pane closed."
        }
    }
}

// DeviceCaptureSession — drives an `AVCaptureSession` that mirrors a
// USB-tethered iPhone, the same way QuickTime's "Movie Recording" does:
// it flips the CMIO `AllowScreenCaptureDevices` switch so the iPhone
// shows up as an external AVCaptureDevice, then attaches video + audio
// inputs and exposes the session for an `AVCaptureVideoPreviewLayer`.
//
// Also exposes record-to-disk and one-shot screenshot, the two QuickTime
// affordances we want next to the preview.
@MainActor
@Observable
final class DeviceCaptureSession: NSObject {
    @ObservationIgnored let session = AVCaptureSession()

    var status: DeviceConnectionStatus = .picking
    var devices: [IOSCaptureDevice] = []
    var isRefreshing: Bool = false
    var deviceUniqueID: String?
    var deviceName: String?
    private(set) var preferredDeviceUniqueID: String?
    private(set) var preferredDeviceName: String?
    private(set) var isCameraPermissionDenied: Bool = false
    var isRecording: Bool = false
    var lastError: String?
    /// Increments on every successful clipboard write. UI binds `.onChange`
    /// to this to flash a "Copied" toast — counter instead of `Date?` so
    /// back-to-back copies still fire the observation.
    var clipboardCopyCount: Int = 0
    /// Whether the live capture has an audio input wired up, so recordings
    /// include sound. False when no paired audio device was found/added — a
    /// recording then comes out video-only.
    var hasAudioInput: Bool = false
    /// Increments when a recording starts with no audio track, so the UI can
    /// flash a one-time "recording without audio" notice. Counter (not a flag)
    /// so back-to-back silent recordings each fire the observation, same idiom
    /// as `clipboardCopyCount`.
    var recordingWithoutAudioCount: Int = 0

    @ObservationIgnored private let logger = Logger(subsystem: "app.blau.pilot.device", category: "capture")
    @ObservationIgnored private let audioPreview = AVCaptureAudioPreviewOutput()
    @ObservationIgnored private let videoDataOutput = AVCaptureVideoDataOutput()
    @ObservationIgnored private let audioDataOutput = AVCaptureAudioDataOutput()
    @ObservationIgnored private let frameQueue = DispatchQueue(label: "app.blau.pilot.device.frame")
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "app.blau.pilot.device.capture")
    @ObservationIgnored private let selectionDefaults: UserDefaults
    @ObservationIgnored private let selectionPreferenceKey: String
    @ObservationIgnored private let selectionPreferenceNameKey: String
    /// Drives the bounded rescan that catches an already-connected iPhone the
    /// one-shot discovery races against (see `scheduleRescan`).
    @ObservationIgnored private var rescanAttemptsRemaining = 0
    @ObservationIgnored private var rescanActive = false
    /// Invalidates camera-permission callbacks when a pane stops or the user
    /// deliberately returns to the picker. Without this, a late TCC callback
    /// can resurrect a capture after teardown.
    @ObservationIgnored private var lifecycleGeneration = 0
    @ObservationIgnored private var isStarted = false
    /// Invalidates the completion of queued session transactions. All
    /// `AVCaptureSession` configuration and start/stop calls run on
    /// `sessionQueue`; this token prevents an older attach from publishing
    /// `.streaming` after a newer detach has already reset the UI state.
    @ObservationIgnored private var sessionTransactionGeneration = 0

    /// Persistent, slow rescan that runs while `status == .failed`. A
    /// media-services reset can republish the capture device *without* firing
    /// `wasConnectedNotification` — from AVFoundation's view the device never
    /// "disconnected", the whole media stack reset — so `handleDeviceConnected`
    /// can't be our only escape from `.failed`. A genuine reset that outlasts the
    /// bounded recovery budget would otherwise strand the pane forever (the
    /// watchdog, recovery, and startup rescan are all torn down when we give up).
    /// This poll watches for the device to become discoverable again and
    /// re-attaches on the spot: no unplug/replug, no manual retry required.
    @ObservationIgnored private var failedRescanActive = false
    @ObservationIgnored private var failedRescanGeneration = 0

    /// Health watchdog. The capture session can die silently after extended use
    /// — most often a media-services reset (`mediaserverd` restarts under memory
    /// or thermal pressure) — which stops the session *without* firing a
    /// device-disconnect. `status` then stays `.streaming` while the preview goes
    /// black with no overlay and no way back short of relaunching. We catch this
    /// two ways: the session's `runtimeErrorNotification` (the immediate signal),
    /// and a polling watchdog that notices `session.isRunning` has gone false.
    ///
    /// We deliberately key on `isRunning`, not on frame delivery: an iPhone
    /// whose screen sleeps or locks legitimately stops sending frames while the
    /// session stays healthy and running, and QuickTime doesn't tear that down
    /// either — it resumes when the screen wakes. Treating a frame stall as
    /// death would spuriously rebuild (and ultimately fail) a perfectly good
    /// connection every time the phone auto-locks.
    @ObservationIgnored private var watchdogActive = false
    /// Monotonic time the current attach went `.streaming`, so the watchdog
    /// gives `startRunning()` a beat to take effect before trusting `isRunning`.
    @ObservationIgnored private var streamingSince: TimeInterval?
    /// True while a teardown+re-attach is in flight, so overlapping triggers
    /// (watchdog tick + runtime-error notification) don't stack.
    @ObservationIgnored private var recovering = false
    /// Cancellation token for the in-flight recovery's delayed re-attach. Bumped
    /// by `recover()` (superseding any prior attempt) and by `cancelRecovery()`
    /// (from `stop()`), so a queued re-attach can't resurrect a torn-down session.
    @ObservationIgnored private var recoveryGeneration = 0
    /// Counts deaths that happen almost immediately after a recovery re-attach. A
    /// stream that survives longer than `thrashWindow` resets it; exceeding
    /// `maxQuickFailures` stops the thrash and surfaces an actionable failure.
    @ObservationIgnored private var consecutiveQuickFailures = 0
    /// Cancellation token for the watchdog tick chain. Bumped on every
    /// start/stop so a tick scheduled before a teardown dies on its next fire
    /// even if a fresh attach has since set `watchdogActive` true again —
    /// guaranteeing exactly one live chain.
    @ObservationIgnored private var watchdogGeneration = 0
    private static let watchdogInterval: TimeInterval = 2
    /// Grace after an attach before the watchdog trusts `isRunning == false`,
    /// covering the async `startRunning()` latency.
    private static let recoveryStartupGrace: TimeInterval = 5
    private static let reattachDelay: TimeInterval = 0.5
    /// ~`maxReattachAttempts * reattachDelay` seconds of re-discovery before we
    /// give up and tell the user to replug.
    private static let maxReattachAttempts = 10
    private static let thrashWindow: TimeInterval = 10
    private static let maxQuickFailures = 3
    /// Cadence of the `.failed`-state self-heal poll. Slower than the startup
    /// rescan (0.5s): this is a passive background heal, not a launch race, so a
    /// gentle 2s beat is enough and keeps it from reading as a tight retry nag.
    private static let failedRescanInterval: TimeInterval = 2

    /// Grabs one-shot frames (screenshots) and writes recordings to disk via
    /// `AVAssetWriter`. We write the exact frames the session delivers — the
    /// same ones the preview shows — rather than routing through
    /// `AVCaptureMovieFileOutput`, whose output dimensions follow the session
    /// preset. On macOS the preset can't be `.inputPriority` (iOS-only), so a
    /// movie file output bakes a letterboxed 16:9 frame instead of the device's
    /// tall screen; writing the data-output buffers ourselves preserves the
    /// device's real aspect ratio (issue #56).
    @ObservationIgnored private let coordinator = CaptureCoordinator()

    init(paneID: UUID, defaults: UserDefaults = .standard) {
        selectionDefaults = defaults
        selectionPreferenceKey = Self.preferenceKey(for: paneID)
        selectionPreferenceNameKey = Self.preferenceNameKey(for: paneID)
        preferredDeviceUniqueID = defaults.string(forKey: selectionPreferenceKey)
        preferredDeviceName = defaults.string(forKey: selectionPreferenceNameKey)
        super.init()
        Self.enableScreenCaptureDevices()
        audioPreview.volume = 1.0
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.setSampleBufferDelegate(coordinator, queue: frameQueue)
        audioDataOutput.setSampleBufferDelegate(coordinator, queue: frameQueue)
        coordinator.onFinish = { [weak self] url, errorMessage in
            Task { @MainActor in
                self?.recordingDidFinish(url: url, errorMessage: errorMessage)
            }
        }
        observeConnections()
        observeSessionRuntime()
    }

    override convenience init() {
        self.init(paneID: UUID())
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        coordinator.shutdown()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        requestCaptureAccess()
    }

    func retry() {
        isStarted = true
        cancelRecovery()
        requestCaptureAccess()
    }

    private func requestCaptureAccess() {
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        // The CMIO `AllowScreenCaptureDevices` flag is the toggle that makes
        // QuickTime's iPhone source appear; it's also what surfaces the
        // device list under the camera TCC bucket. We need camera permission
        // before AVFoundation will hand us the device, so prompt up-front.
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isStarted,
                          generation == self.lifecycleGeneration else { return }
                    guard granted else {
                        self.isCameraPermissionDenied = true
                        self.status = .failed("Cockpit needs camera permission to mirror the iPhone screen.")
                        return
                    }
                    self.isCameraPermissionDenied = false
                    self.refreshDevices()
                }
            }
        }
    }

    func stop() {
        isStarted = false
        lifecycleGeneration &+= 1
        cancelRecovery()
        coordinator.cancelPendingFrames(reason: .sessionStopped)
        if isRecording {
            coordinator.stopRecording()
        }
        detach()
    }

    // MARK: - Device list

    static func preferenceKey(for paneID: UUID) -> String {
        "Pilot.DeviceCapture.preferredDevice.\(paneID.uuidString.lowercased())"
    }

    static func preferenceNameKey(for paneID: UUID) -> String {
        "Pilot.DeviceCapture.preferredDeviceName.\(paneID.uuidString.lowercased())"
    }

    /// Refresh the capture-source picker. A previously chosen device may
    /// reconnect automatically, but an unconfigured pane never grabs an
    /// arbitrary `AVCaptureDevice` just because it happens to sort first.
    func refreshDevices() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let attached = Self.attachedScreenCaptureDevices()
        devices = Self.sortedOptions(from: attached)
        isRefreshing = false
        lastError = nil

        guard deviceUniqueID == nil, isStarted else { return }
        guard let preferredDeviceUniqueID else {
            status = .picking
            return
        }
        if let preferred = attached.first(where: { $0.uniqueID == preferredDeviceUniqueID }) {
            attach(preferred)
        } else {
            status = .picking
            scheduleRescan()
        }
    }

    func connect(_ option: IOSCaptureDevice) {
        guard let device = Self.attachedScreenCaptureDevices().first(where: { $0.uniqueID == option.id }) else {
            status = .picking
            refreshDevices()
            lastError = "That device is no longer available. Reconnect it, then refresh the list."
            return
        }

        isStarted = true
        lifecycleGeneration &+= 1
        cancelRecovery()
        preferredDeviceUniqueID = option.id
        preferredDeviceName = option.name
        selectionDefaults.set(option.id, forKey: selectionPreferenceKey)
        selectionDefaults.set(option.name, forKey: selectionPreferenceNameKey)
        lastError = nil
        attach(device)
    }

    func chooseAnotherDevice() {
        guard !isCameraPermissionDenied else { return }
        lifecycleGeneration &+= 1
        cancelRecovery()
        if isRecording {
            coordinator.stopRecording()
            isRecording = false
        }
        detach()
        preferredDeviceUniqueID = nil
        preferredDeviceName = nil
        selectionDefaults.removeObject(forKey: selectionPreferenceKey)
        selectionDefaults.removeObject(forKey: selectionPreferenceNameKey)
        status = .picking
        refreshDevices()
    }

    func openCameraPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Recording

    func toggleRecording() {
        guard status == .streaming else { return }
        if isRecording {
            coordinator.stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard !isRecording else { return }
        guard videoDataOutput.connection(with: .video) != nil else {
            lastError = "No video stream available to record."
            return
        }
        let url = Self.timestampedURL(folder: "Desktop", name: "iPhone Recording", ext: "mov")
        guard coordinator.startRecording(to: url) else {
            lastError = "A recording is already being prepared or saved. Wait for it to finish and retry."
            return
        }
        isRecording = true
        lastError = nil
        // No paired audio device means the writer has no audio track to fill —
        // surface a one-time notice so the silent recording isn't a surprise.
        if !hasAudioInput {
            recordingWithoutAudioCount += 1
        }
    }

    fileprivate func recordingDidFinish(url: URL, errorMessage: String?) {
        isRecording = false
        if let errorMessage {
            lastError = "Recording failed: \(errorMessage)"
            logger.error("recording failed: \(errorMessage)")
            return
        }
        verifyNativeAspectRatio(of: url)
    }

    // MARK: - Screenshot

    func takeScreenshot() {
        guard status == .streaming else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let cgImage = try await self.coordinator.nextFrame()
                let url = Self.timestampedURL(folder: "Desktop", name: "iPhone Screenshot", ext: "png")
                self.write(cgImage: cgImage, to: url)
            } catch {
                self.lastError = error.localizedDescription
            }
        }
    }

    /// Copies a single frame of the live device feed to the general
    /// pasteboard as a PNG-backed `NSImage`, so it pastes into Messages,
    /// Notes, Preview, design tools, etc. Mirrors `takeScreenshot()`
    /// without touching disk.
    func copyScreenshotToClipboard() {
        guard status == .streaming else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let cgImage = try await self.coordinator.nextFrame()
                let image = NSImage(
                    cgImage: cgImage,
                    size: NSSize(width: cgImage.width, height: cgImage.height)
                )
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                // Write `NSImage` so paste targets that prefer image data get
                // it, and add an explicit PNG representation for clients that
                // ask for raw bytes (Slack, browsers, etc.).
                var wroteAny = pasteboard.writeObjects([image])
                let bitmap = NSBitmapImageRep(cgImage: cgImage)
                if let pngData = bitmap.representation(using: .png, properties: [:]) {
                    pasteboard.setData(pngData, forType: .png)
                    wroteAny = true
                }
                if !wroteAny {
                    self.lastError = "Couldn't put the screenshot on the clipboard."
                } else {
                    self.lastError = nil
                    self.clipboardCopyCount &+= 1
                }
            } catch {
                self.lastError = error.localizedDescription
            }
        }
    }

    private func write(cgImage: CGImage, to url: URL) {
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            lastError = "Couldn't encode screenshot as PNG."
            return
        }
        do {
            try data.write(to: url, options: .withoutOverwriting)
            lastError = nil
        } catch {
            lastError = "Couldn't save screenshot: \(error.localizedDescription)"
            logger.error("save screenshot failed: \(error.localizedDescription)")
        }
    }

    static func timestampedURL(
        folder: String,
        name: String,
        ext: String,
        date: Date = Date(),
        uniqueID: UUID = UUID()
    ) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        let stamp = formatter.string(from: date)
        let unique = uniqueID.uuidString.lowercased()
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return home.appendingPathComponent(folder).appendingPathComponent("\(name) \(stamp)-\(unique).\(ext)")
    }

    // MARK: - CMIO toggle

    /// Flip `kCMIOHardwarePropertyAllowScreenCaptureDevices` so the OS
    /// publishes USB-tethered iPhones as `AVCaptureDevice`s. This is the
    /// same flag QuickTime sets when it offers "iPhone" as a recording
    /// source. Idempotent — safe to call on every launch.
    private static func enableScreenCaptureDevices() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0, nil,
            UInt32(MemoryLayout.size(ofValue: allow)),
            &allow
        )
    }

    /// An iPhone that's already plugged in when the pane opens never fires
    /// `wasConnectedNotification`, and the OS needs a beat to publish the
    /// screen-capture device after the CMIO flag flips and camera access is
    /// granted — so the first exact-ID lookup can miss it. Poll a few times so
    /// a previously selected phone already on the cable reconnects without an
    /// unplug/replug, while never falling back to another attached device.
    private func scheduleRescan() {
        guard preferredDeviceUniqueID != nil else { return }
        rescanAttemptsRemaining = 10  // ~5s at a 0.5s cadence
        guard !rescanActive else { return }  // a poll chain is already running
        rescanActive = true
        rescanTick()
    }

    private func rescanTick() {
        guard deviceUniqueID == nil, rescanAttemptsRemaining > 0 else {
            rescanActive = false
            return
        }
        rescanAttemptsRemaining -= 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                // `rescanActive` gates the queued tick the same way the watchdog
                // and recovery generations gate theirs: `cancelRescan()` (from
                // `stop()`/`detach()`/`attach()`) clears it, so a tick queued
                // before the pane closed can't fire a stray attach() and
                // resurrect a torn-down session.
                guard let self, self.rescanActive, self.deviceUniqueID == nil else {
                    self?.rescanActive = false
                    return
                }
                if let device = self.preferredAttachedScreenCaptureDevice() {
                    self.attach(device)
                } else {
                    self.rescanTick()
                }
            }
        }
    }

    private func cancelRescan() {
        rescanAttemptsRemaining = 0
        rescanActive = false
    }

    // MARK: - Failed-state self-heal

    /// Begin polling for the device to reappear while we're stranded in
    /// `.failed`. Idempotent; superseded cleanly by `stopFailedRescan` (which
    /// `attach`/`detach` call), so exactly one chain is ever live.
    private func startFailedRescan() {
        guard preferredDeviceUniqueID != nil, !failedRescanActive else { return }
        failedRescanActive = true
        failedRescanGeneration &+= 1
        failedRescanTick(generation: failedRescanGeneration)
    }

    private func stopFailedRescan() {
        failedRescanActive = false
        failedRescanGeneration &+= 1
    }

    private func failedRescanTick(generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.failedRescanInterval) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.failedRescanActive,
                      generation == self.failedRescanGeneration else { return }
                if let device = self.preferredAttachedScreenCaptureDevice() {
                    // The device is discoverable again. Treat this like a physical
                    // replug: clear the thrash count so the reconnect gets a real
                    // chance instead of instantly re-tripping the quick-failure cap
                    // and bouncing straight back to `.failed`.
                    self.consecutiveQuickFailures = 0
                    self.attach(device)  // attach() calls stopFailedRescan()
                } else {
                    self.failedRescanTick(generation: generation)
                }
            }
        }
    }

    private static func attachedScreenCaptureDevices() -> [AVCaptureDevice] {
        // The CMIO screen-capture pathway publishes the iPhone as an
        // `.external` device that normally delivers `.muxed` video+audio.
        // Continuity Camera (which streams the phone's camera, not its screen)
        // reports as `.continuityCamera` and is always rejected. Some OS/device
        // combinations publish a video-only representation too, so query both
        // media types and apply the same conservative iOS identity policy.
        let muxed = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .muxed,
            position: .unspecified
        ).devices

        let video = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        ).devices

        // A source can be published in both sessions under the same unique ID.
        // Insert video first and let the muxed representation win so recordings
        // retain the device audio track. Importantly, muxed is not sufficient
        // evidence by itself: third-party HDMI/USB capture cards are muxed too.
        // AVFoundation exposes no signed iOS-device identity, so metadata can be
        // incomplete or spoofed; explicit iPhone/iPad names/models and generic
        // Apple-manufactured USB muxed devices are the most reliable public signals.
        var byUniqueID: [String: AVCaptureDevice] = [:]
        for device in video where Self.isEligibleIOSScreenCaptureDevice(device) {
            byUniqueID[device.uniqueID] = device
        }
        for device in muxed where Self.isEligibleIOSScreenCaptureDevice(device) {
            byUniqueID[device.uniqueID] = device
        }
        return Array(byUniqueID.values)
    }

    private static func captureDeviceOption(_ device: AVCaptureDevice) -> IOSCaptureDevice {
        IOSCaptureDevice(id: device.uniqueID, name: device.localizedName, modelID: device.modelID)
    }

    private static func sortedOptions(from devices: [AVCaptureDevice]) -> [IOSCaptureDevice] {
        devices.map(Self.captureDeviceOption).sorted {
            let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
            return nameOrder == .orderedSame ? $0.id < $1.id : nameOrder == .orderedAscending
        }
    }

    private func preferredAttachedScreenCaptureDevice() -> AVCaptureDevice? {
        guard let preferredDeviceUniqueID else { return nil }
        return Self.attachedScreenCaptureDevices().first { $0.uniqueID == preferredDeviceUniqueID }
    }

    private static func isEligibleIOSScreenCaptureDevice(_ device: AVCaptureDevice) -> Bool {
        guard device.deviceType != .continuityCamera else { return false }
        return IOSCaptureDiscoveryPolicy.includes(
            name: device.localizedName,
            modelID: device.modelID,
            manufacturer: device.manufacturer,
            isMuxed: device.hasMediaType(.muxed),
            transportType: device.transportType
        )
    }

    // MARK: - Hot-plug

    private func observeConnections() {
        let nc = NotificationCenter.default
        nc.addObserver(
            self,
            selector: #selector(handleDeviceConnected),
            name: AVCaptureDevice.wasConnectedNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(handleDeviceDisconnected(_:)),
            name: AVCaptureDevice.wasDisconnectedNotification,
            object: nil
        )
    }

    @objc nonisolated private func handleDeviceConnected() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isStarted, self.deviceUniqueID == nil,
                      !self.isCameraPermissionDenied else { return }
                let attached = Self.attachedScreenCaptureDevices()
                self.devices = Self.sortedOptions(from: attached)
                guard let preferredDeviceUniqueID = self.preferredDeviceUniqueID,
                      let device = attached.first(where: { $0.uniqueID == preferredDeviceUniqueID }) else {
                    self.status = .picking
                    return
                }
                // Only a genuine physical replug (not a re-enumeration mid-recovery)
                // is a clean slate — clearing strikes while recovering would let a
                // device that dies-and-re-enumerates every cycle dodge the thrash cap
                // forever. Check before `cancelRecovery()` flips the flag.
                if !self.recovering {
                    self.consecutiveQuickFailures = 0
                }
                // Supersede any in-flight recovery re-attach so it can't fire a
                // second, redundant attach() on the stream we're about to build.
                self.cancelRecovery()
                self.attach(device)
            }
        }
    }

    @objc nonisolated private func handleDeviceDisconnected(_ note: Notification) {
        let lostID = (note.object as? AVCaptureDevice)?.uniqueID
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let lostID, lostID == self.deviceUniqueID else { return }
                self.detach()
                self.refreshDevices()
            }
        }
    }

    // MARK: - Session health

    /// A device disconnect is only one way a stream dies. After extended use the
    /// session itself fails — most often a media-services reset — which stops it
    /// without firing a device-disconnect. AVFoundation reports that through the
    /// session's runtime-error notification, so observe it and rebuild on the
    /// spot. AVFoundation notifications may arrive on arbitrary queues, so all
    /// selector handlers explicitly hop to the main actor before touching state.
    private func observeSessionRuntime() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionRuntimeError(_:)),
            name: AVCaptureSession.runtimeErrorNotification,
            object: session
        )
    }

    @objc nonisolated private func handleSessionRuntimeError(_ note: Notification) {
        let description = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?
            .localizedDescription ?? "unknown"
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.status == .streaming else { return }
                self.logger.error("capture session runtime error: \(description)")
                self.recover(reason: "runtime error")
            }
        }
    }

    private func startWatchdog() {
        guard !watchdogActive else { return }
        watchdogActive = true
        watchdogGeneration &+= 1
        watchdogTick(generation: watchdogGeneration)
    }

    private func stopWatchdog() {
        watchdogActive = false
        watchdogGeneration &+= 1
    }

    private func watchdogTick(generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.watchdogInterval) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.watchdogActive, generation == self.watchdogGeneration else { return }
                self.checkStreamHealth()
                // checkStreamHealth() may have torn the session down; only the
                // current generation re-arms, so a superseded tick can't persist.
                guard self.watchdogActive, generation == self.watchdogGeneration else { return }
                self.watchdogTick(generation: generation)
            }
        }
    }

    /// Backstop for the runtime-error notification: while we believe we're
    /// `.streaming`, a session whose `isRunning` has gone false is dead (a
    /// media-services reset stops it), so rebuild. Frame delivery is *not* the
    /// signal — a sleeping/locked iPhone stops sending frames with the session
    /// still healthy, and rebuilding that would be a regression. We wait out a
    /// startup grace so the async `startRunning()` after an attach has time to
    /// flip `isRunning` true before we judge it.
    private func checkStreamHealth() {
        guard status == .streaming, !recovering, let since = streamingSince,
              ProcessInfo.processInfo.systemUptime - since > Self.recoveryStartupGrace else { return }
        let generation = sessionTransactionGeneration
        nonisolated(unsafe) let captureSession = session
        sessionQueue.async { [weak self] in
            guard !captureSession.isRunning else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.status == .streaming, !self.recovering,
                          generation == self.sessionTransactionGeneration else { return }
                    self.recover(reason: "session stopped running")
                }
            }
        }
    }

    /// Tear the dead session down and re-discover the device so capture restarts
    /// in place — no unplug/replug. We reuse the existing `AVCaptureSession`,
    /// re-adding fresh inputs/outputs, rather than a bare `startRunning()` retry:
    /// after a media-services reset the old device inputs are invalid and must be
    /// rebuilt. If the device keeps dying right after each rebuild
    /// (`maxQuickFailures`), or never re-enumerates, we stop and surface an
    /// actionable failure instead of thrashing or hanging on the wrong overlay.
    private func recover(reason: String) {
        guard !recovering else { return }

        // A stream that dropped almost immediately after the last rebuild is
        // thrashing; one that ran a while is a fresh, independent failure.
        let now = ProcessInfo.processInfo.systemUptime
        if let since = streamingSince, now - since < Self.thrashWindow {
            consecutiveQuickFailures += 1
        } else {
            consecutiveQuickFailures = 0
        }
        if consecutiveQuickFailures > Self.maxQuickFailures {
            logger.error("capture recovery gave up: feed keeps dropping")
            failRecovery("The iPhone video feed keeps dropping. Unplug the device and reconnect it.")
            return
        }

        recovering = true
        recoveryGeneration &+= 1
        let generation = recoveryGeneration
        logger.warning("recovering iPhone capture (\(reason))")

        if isRecording {
            coordinator.stopRecording()
            isRecording = false
        }
        detach()
        status = .connecting
        scheduleReattach(generation: generation, attempt: 1)
    }

    /// Re-discover and attach the device, retrying on `reattachDelay` so
    /// mediaserverd has time to republish it after a reset. Bails immediately if
    /// the recovery was superseded or cancelled (`generation` / `recovering`), so
    /// a queued re-attach can't revive a session that `stop()` already tore down.
    private func scheduleReattach(generation: Int, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reattachDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.recovering, generation == self.recoveryGeneration else { return }
                if let device = self.preferredAttachedScreenCaptureDevice() {
                    self.recovering = false
                    self.attach(device)
                } else if attempt >= Self.maxReattachAttempts {
                    self.logger.error("capture recovery gave up: device never re-enumerated")
                    self.recovering = false
                    self.failRecovery("Lost the iPhone video feed. Unplug the device and reconnect it.")
                } else {
                    self.scheduleReattach(generation: generation, attempt: attempt + 1)
                }
            }
        }
    }

    private func failRecovery(_ message: String) {
        cancelRecovery()
        consecutiveQuickFailures = 0
        detach()
        status = .failed(message)
        // The bounded recovery budget expired, but the device may still come back
        // (a slow media-services reset can outlast it, and won't fire a device
        // reconnect notification). Keep watching so we heal without a replug.
        startFailedRescan()
    }

    /// Invalidate any in-flight delayed re-attach so it can't run after teardown.
    private func cancelRecovery() {
        recovering = false
        recoveryGeneration &+= 1
    }

    // MARK: - Session wiring

    private enum SessionAttachResult: Sendable {
        case success(hasAudioInput: Bool, warnings: [String])
        case failure(String)
    }

    private func attach(_ device: AVCaptureDevice) {
        guard device.uniqueID == preferredDeviceUniqueID else {
            logger.error("refusing to attach an unselected iOS device")
            status = .picking
            return
        }
        cancelRescan()
        stopFailedRescan()
        status = .connecting
        hasAudioInput = false
        sessionTransactionGeneration &+= 1
        let generation = sessionTransactionGeneration
        let selectedID = device.uniqueID
        let selectedName = device.localizedName
        nonisolated(unsafe) let captureSession = session
        nonisolated(unsafe) let captureDevice = device
        nonisolated(unsafe) let captureVideoOutput = videoDataOutput
        nonisolated(unsafe) let captureAudioOutput = audioDataOutput
        nonisolated(unsafe) let captureAudioPreview = audioPreview

        sessionQueue.async { [weak self] in
            let result = Self.configureAndStart(
                captureSession,
                device: captureDevice,
                videoOutput: captureVideoOutput,
                audioOutput: captureAudioOutput,
                audioPreview: captureAudioPreview
            )
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.sessionTransactionGeneration else { return }
                    switch result {
                    case let .success(hasAudioInput, warnings):
                        guard self.isStarted, self.preferredDeviceUniqueID == selectedID else { return }
                        for warning in warnings {
                            self.logger.warning("\(warning)")
                        }
                        self.hasAudioInput = hasAudioInput
                        self.deviceUniqueID = selectedID
                        self.deviceName = selectedName
                        self.preferredDeviceName = selectedName
                        self.selectionDefaults.set(selectedName, forKey: self.selectionPreferenceNameKey)
                        self.status = .streaming
                        self.streamingSince = ProcessInfo.processInfo.systemUptime
                        self.startWatchdog()
                    case let .failure(message):
                        self.logger.error("iOS capture attach failed: \(message)")
                        self.hasAudioInput = false
                        self.deviceUniqueID = nil
                        self.deviceName = nil
                        self.streamingSince = nil
                        self.status = .failed(message)
                        // A media-services reset may make this same exact device
                        // usable again, so retain the selection and self-heal.
                        self.startFailedRescan()
                    }
                }
            }
        }
    }

    private func detach() {
        cancelRescan()
        stopFailedRescan()
        // The watchdog only makes sense while attached; stopping it here covers
        // every teardown path (unplug, recovery rebuild, an attach() that throws)
        // so no zombie tick survives. attach() restarts it.
        stopWatchdog()
        coordinator.cancelPendingFrames(reason: .detached)
        if isRecording {
            coordinator.stopRecording(reason: "Recording stopped because the capture device disconnected.")
        }
        hasAudioInput = false
        sessionTransactionGeneration &+= 1
        nonisolated(unsafe) let captureSession = session
        sessionQueue.async {
            Self.stopAndClear(captureSession)
        }

        deviceUniqueID = nil
        deviceName = nil
        isRecording = false
        streamingSince = nil
        status = .picking
    }

    /// Configure and start as one indivisible serial-queue transaction. Apple
    /// explicitly forbids `startRunning()` between `beginConfiguration()` and
    /// `commitConfiguration()`; keeping stop/configure/start here also prevents
    /// a MainActor detach from racing a slow, blocking start.
    nonisolated private static func configureAndStart(
        _ session: AVCaptureSession,
        device: AVCaptureDevice,
        videoOutput: AVCaptureVideoDataOutput,
        audioOutput: AVCaptureAudioDataOutput,
        audioPreview: AVCaptureAudioPreviewOutput
    ) -> SessionAttachResult {
        if session.isRunning { session.stopRunning() }

        var failure: String?
        var warnings: [String] = []
        var hasAudioSource = device.hasMediaType(.muxed)
        var hasUsableAudioOutput = false

        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }

        do {
            let videoInput = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(videoInput) {
                session.addInput(videoInput)
                if let formatWarning = configureHighestResolutionFormat(for: device) {
                    warnings.append(formatWarning)
                }
            } else {
                failure = "Cockpit couldn't add the selected iOS device as a video input."
            }
        } catch {
            failure = "Cockpit couldn't open the selected iOS device: \(error.localizedDescription)"
        }

        if failure == nil {
            guard session.canAddOutput(videoOutput) else {
                Self.abortConfiguration(session)
                return .failure("Cockpit couldn't add the required iOS video output.")
            }
            session.addOutput(videoOutput)

            // A muxed iPhone carries audio on its video input. A video-only
            // representation may expose a separate audio device; AVFoundation
            // provides no public pairing identifier beyond exact unique-ID
            // equality, so never guess by model or display name (which can
            // silently take audio from a different attached phone).
            if !hasAudioSource, let pairedAudio = pairedAudioDevice(forVideo: device) {
                do {
                    let audioInput = try AVCaptureDeviceInput(device: pairedAudio)
                    if session.canAddInput(audioInput) {
                        session.addInput(audioInput)
                        hasAudioSource = true
                    } else {
                        warnings.append("The exactly paired iOS audio input could not be added; recording video only.")
                    }
                } catch {
                    warnings.append("The exactly paired iOS audio input failed: \(error.localizedDescription)")
                }
            }

            if hasAudioSource {
                // Recording audio is useful only when its data output is live.
                // Preview monitoring is optional and must not make video fail.
                if session.canAddOutput(audioOutput) {
                    session.addOutput(audioOutput)
                    hasUsableAudioOutput = true
                } else {
                    warnings.append("The iOS audio data output could not be added; recording video only.")
                }
                if session.canAddOutput(audioPreview) {
                    session.addOutput(audioPreview)
                } else {
                    warnings.append("The iOS live audio monitor could not be added.")
                }
            }
        }

        if let failure {
            Self.abortConfiguration(session)
            return .failure(failure)
        }
        session.commitConfiguration()

        if !session.isRunning { session.startRunning() }
        guard session.isRunning else {
            Self.stopAndClear(session)
            return .failure("Cockpit configured the selected iOS device, but capture did not start.")
        }
        return .success(hasAudioInput: hasUsableAudioOutput, warnings: warnings)
    }

    nonisolated private static func abortConfiguration(_ session: AVCaptureSession) {
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        session.commitConfiguration()
    }

    nonisolated private static func stopAndClear(_ session: AVCaptureSession) {
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        session.commitConfiguration()
    }

    nonisolated private static func pairedAudioDevice(forVideo video: AVCaptureDevice) -> AVCaptureDevice? {
        let candidates = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .audio,
            position: .unspecified
        ).devices

        return candidates.first {
            IOSCaptureAudioPairingPolicy.matches(
                videoUniqueID: video.uniqueID,
                audioUniqueID: $0.uniqueID
            )
        }
    }

    /// Use the input device's own format instead of a fixed preset. A fixed
    /// resolution preset (e.g. `.hd1920x1080`) forces 16:9, which letterboxes a
    /// phone's taller screen in the recording. (`.inputPriority` would be ideal
    /// but is iOS-only.) `.high` adapts to the device's native format, and we
    /// then pin `activeFormat` via `configureHighestResolutionFormat`, so we
    /// record at the device's real resolution and aspect ratio.
    nonisolated private static func configureHighestResolutionFormat(for device: AVCaptureDevice) -> String? {
        let bestFormat = device.formats.max { lhs, rhs in
            let lhsSize = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let rhsSize = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            let lhsPixels = Int(lhsSize.width) * Int(lhsSize.height)
            let rhsPixels = Int(rhsSize.width) * Int(rhsSize.height)
            if lhsPixels != rhsPixels {
                return lhsPixels < rhsPixels
            }
            return lhs.videoSupportedFrameRateRanges.bestFrameRate
                < rhs.videoSupportedFrameRateRanges.bestFrameRate
        }

        guard let bestFormat else { return nil }
        do {
            try device.lockForConfiguration()
            device.activeFormat = bestFormat
            device.unlockForConfiguration()
            return nil
        } catch {
            return "Screen capture format selection failed: \(error.localizedDescription)"
        }
    }

    /// Log the saved recording's real dimensions so we can confirm it kept the
    /// device's native aspect ratio (a tall phone screen, not a 16:9 frame) —
    /// read from the finished file, independent of the live preview (issue #56).
    private func verifyNativeAspectRatio(of url: URL) {
        let logger = self.logger
        Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let size = try? await track.load(.naturalSize) else { return }
            let w = Int(size.width.rounded())
            let h = Int(size.height.rounded())
            logger.info("recording saved at \(w)x\(h) (\(h >= w ? "portrait" : "landscape"))")
        }
    }
}

private extension [AVFrameRateRange] {
    var bestFrameRate: Double {
        map(\.maxFrameRate).max() ?? 0
    }
}

// MARK: - Capture coordinator

/// Receives video + audio sample buffers off the capture queue and does two
/// jobs: hand back a single frame for screenshots, and write recordings to
/// disk with `AVAssetWriter`. Writing the buffers ourselves (rather than via
/// `AVCaptureMovieFileOutput`) is what keeps the recording at the device's
/// native dimensions: the writer is sized from the first video frame's real
/// `CMVideoFormatDescription`, so the file is exactly what the session
/// delivers — the same frames the preview shows (issue #56).
///
/// All mutable state is guarded by `lock`. The two data outputs share one
/// serial delivery queue, so video/audio callbacks never overlap; only
/// `start`/`stopRecording` (called from the main actor) race them, and the
/// lock serializes that.
final class CaptureCoordinator: NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate,
    @unchecked Sendable {
    private let lock = NSLock()
    private let ciContext = CIContext()
    private var pending: [UUID: CheckedContinuation<CGImage, Error>] = [:]

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var recordingURL: URL?
    private var armed = false      // start requested; writer is built on the first frame
    private var finishing = false

    /// Called on completion with the saved URL and an error description (if any).
    var onFinish: (@Sendable (URL, String?) -> Void)?

    deinit {
        shutdown()
    }

    func shutdown() {
        cancelPendingFrames(reason: .coordinatorReleased)
        stopRecording(reason: "Recording stopped because the capture coordinator closed.")
    }

    // MARK: Screenshot

    func nextFrame(timeout: TimeInterval = 2) async throws -> CGImage {
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                pending[requestID] = continuation
                lock.unlock()

                if Task.isCancelled {
                    resolveFrameRequest(requestID, result: .failure(CaptureFrameError.cancelled))
                    return
                }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.resolveFrameRequest(requestID, result: .failure(CaptureFrameError.timedOut))
                }
            }
        } onCancel: { [weak self] in
            self?.resolveFrameRequest(requestID, result: .failure(CaptureFrameError.cancelled))
        }
    }

    func cancelPendingFrames(reason: CaptureFrameError) {
        lock.lock()
        let continuations = Array(pending.values)
        pending.removeAll()
        lock.unlock()
        continuations.forEach { $0.resume(throwing: reason) }
    }

    private func resolveFrameRequest(_ id: UUID, result: Result<CGImage, Error>) {
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(with: result)
    }

    // MARK: Recording control

    @discardableResult
    func startRecording(to url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard writer == nil, !armed, !finishing else { return false }
        recordingURL = url
        armed = true
        finishing = false
        return true
    }

    func stopRecording(reason: String? = nil) {
        lock.lock()
        if finishing {
            lock.unlock()
            return
        }
        guard let writer else {
            // An armed/no-frame recording still has to finish the public state
            // machine; otherwise DeviceCaptureSession stays "recording" forever.
            let wasArmed = armed
            let url = recordingURL
            let callback = onFinish
            armed = false
            recordingURL = nil
            lock.unlock()
            if wasArmed, let url {
                callback?(url, reason ?? "Recording stopped before the first video frame arrived.")
            }
            return
        }
        finishing = true
        let url = recordingURL ?? writer.outputURL
        let callback = onFinish
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        lock.unlock()

        writer.finishWriting { [weak self] in
            self?.recordingWriterDidFinish(url: url, callback: callback)
        }
    }

    /// `AVAssetWriter` is explicitly non-Sendable. Keep it behind this
    /// coordinator's lock instead of capturing it in `finishWriting`'s
    /// `@Sendable` callback.
    private func recordingWriterDidFinish(
        url: URL,
        callback: (@Sendable (URL, String?) -> Void)?
    ) {
        lock.lock()
        let message = writer?.status == .failed ? writer?.error?.localizedDescription : nil
        writer = nil
        videoInput = nil
        audioInput = nil
        recordingURL = nil
        armed = false
        finishing = false
        lock.unlock()
        callback?(url, message)
    }

    // MARK: Sample delegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output is AVCaptureVideoDataOutput {
            serveScreenshot(sampleBuffer)
            appendVideo(sampleBuffer)
        } else if output is AVCaptureAudioDataOutput {
            appendAudio(sampleBuffer)
        }
    }

    private func serveScreenshot(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let continuations = Array(pending.values)
        pending.removeAll()
        lock.unlock()

        guard !continuations.isEmpty else { return }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            continuations.forEach {
                $0.resume(throwing: CaptureFrameError.timedOut)
            }
            return
        }
        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        let image = ciContext.createCGImage(ciImage, from: ciImage.extent)
        guard let image else {
            continuations.forEach { $0.resume(throwing: CaptureFrameError.timedOut) }
            return
        }
        continuations.forEach { $0.resume(returning: image) }
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        if armed, writer == nil {
            buildWriter(from: sampleBuffer)
        }
        guard let writer, let videoInput, !finishing else {
            lock.unlock()
            return
        }
        if writer.status == .unknown {
            guard writer.startWriting() else {
                let failure = takeRecordingFailureLocked(
                    writer.error?.localizedDescription ?? "The recording writer could not start."
                )
                lock.unlock()
                notifyRecordingFailure(failure)
                return
            }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }
        if writer.status == .writing, videoInput.isReadyForMoreMediaData {
            guard videoInput.append(sampleBuffer) else {
                let failure = takeRecordingFailureLocked(
                    writer.error?.localizedDescription ?? "The recording writer rejected a video frame."
                )
                lock.unlock()
                notifyRecordingFailure(failure)
                return
            }
        }
        lock.unlock()
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        // Only once the writer is live (video frame started the session) —
        // appending audio before `startSession` would fail.
        guard let writer, let audioInput, !finishing,
              writer.status == .writing, audioInput.isReadyForMoreMediaData else {
            lock.unlock()
            return
        }
        guard audioInput.append(sampleBuffer) else {
            let failure = takeRecordingFailureLocked(
                writer.error?.localizedDescription ?? "The recording writer rejected an audio frame."
            )
            lock.unlock()
            notifyRecordingFailure(failure)
            return
        }
        lock.unlock()
    }

    /// Build the writer sized to the device's real frame dimensions. Called
    /// with `lock` held, on the first video sample of a recording.
    private func buildWriter(from sampleBuffer: CMSampleBuffer) {
        guard let url = recordingURL else { return }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            let callback = onFinish
            armed = false
            recordingURL = nil
            DispatchQueue.global(qos: .userInitiated).async {
                callback?(url, "Could not read the first video frame's format.")
            }
            return
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(dimensions.width),
                AVVideoHeightKey: Int(dimensions.height),
            ])
            videoInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(videoInput) else {
                throw NSError(
                    domain: "app.blau.pilot.capture",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The recording writer cannot accept the video format."]
                )
            }
            writer.add(videoInput)

            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: 128_000,
            ])
            audioInput.expectsMediaDataInRealTime = true
            if writer.canAdd(audioInput) { writer.add(audioInput) }

            self.writer = writer
            self.videoInput = videoInput
            self.audioInput = audioInput
        } catch {
            let callback = onFinish
            let failedURL = recordingURL
            armed = false
            recordingURL = nil
            if let failedURL {
                DispatchQueue.global(qos: .userInitiated).async {
                    callback?(failedURL, "Could not create recording: \(error.localizedDescription)")
                }
            }
        }
    }

    private typealias RecordingFailure = (
        url: URL,
        callback: @Sendable (URL, String?) -> Void,
        message: String
    )

    /// Takes and clears recording state while `lock` is held. The callback is
    /// always invoked after unlocking so UI work can never re-enter the writer.
    private func takeRecordingFailureLocked(_ message: String) -> RecordingFailure? {
        guard let url = recordingURL ?? writer?.outputURL, let callback = onFinish else {
            writer?.cancelWriting()
            writer = nil
            videoInput = nil
            audioInput = nil
            recordingURL = nil
            armed = false
            finishing = false
            return nil
        }
        writer?.cancelWriting()
        writer = nil
        videoInput = nil
        audioInput = nil
        recordingURL = nil
        armed = false
        finishing = false
        return (url, callback, message)
    }

    private func notifyRecordingFailure(_ failure: RecordingFailure?) {
        guard let failure else { return }
        failure.callback(failure.url, failure.message)
    }
}
