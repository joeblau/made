import AVFoundation
import Foundation

/// App-wide last-known lists of iOS simulators, USB iPhones/iPads, and adb
/// devices, so a picker shows what is already there the moment it opens and
/// refreshes underneath instead of starting from an empty "Looking for…".
///
/// `warmUp()` runs at launch and whenever the New Tab root opens: each probe
/// is one bounded subprocess or AVFoundation query off the main actor, and
/// the CMIO screen-capture switch is flipped right away because macOS needs
/// a few seconds after it to publish an already-connected iPhone. Sessions
/// seed from this cache when created and write back after real scans.
@MainActor
final class MobileDeviceCache {
    static let shared = MobileDeviceCache()

    /// nil until the first scan completes; empty means "scanned, none found".
    private(set) var simulators: [SimRuntimeGroup]?
    private(set) var androidDevices: [AndroidDevice]?
    private(set) var appleDevices: [IOSCaptureDevice]?

    /// Hosted tests build their own sessions and must not spawn simctl/adb or
    /// touch capture hardware just because a New Tab view appeared.
    var isWarmUpEnabled = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil

    private var inFlight: Set<Source> = []
    private var lastWarmUp: ContinuousClock.Instant?
    private var observesCaptureHotPlug = false
    private static let warmUpInterval: Duration = .seconds(1)

    private enum Source { case simulators, android, apple }

    func warmUp() {
        guard isWarmUpEnabled else { return }
        let now = ContinuousClock.now
        if let lastWarmUp, now - lastWarmUp < Self.warmUpInterval { return }
        lastWarmUp = now
        DeviceCaptureSession.enableScreenCaptureDevices()
        observeCaptureHotPlug()
        warmSimulators()
        warmAndroid()
        warmAppleDevices()
    }

    func record(simulators groups: [SimRuntimeGroup]) { simulators = groups }
    func record(androidDevices devices: [AndroidDevice]) { androidDevices = devices }
    func record(appleDevices devices: [IOSCaptureDevice]) { appleDevices = devices }

    /// Forgets every list (tests restore a clean slate with this).
    func reset() {
        simulators = nil
        androidDevices = nil
        appleDevices = nil
    }

    private func warmSimulators() {
        guard inFlight.insert(.simulators).inserted else { return }
        Task {
            let groups = await Task.detached(priority: .userInitiated) { try? SimctlBridge.listDevices() }.value
            inFlight.remove(.simulators)
            if let groups { record(simulators: groups) }
        }
    }

    /// Only when the user's adb is installed; this starts their adb server
    /// daemon early, exactly as opening an Android picker would.
    private func warmAndroid() {
        guard inFlight.insert(.android).inserted else { return }
        Task {
            let devices = await Task.detached(priority: .userInitiated) { () -> [AndroidDevice]? in
                guard AdbBridge.resolveAdbURL() != nil else { return nil }
                return try? AdbBridge.listDevices()
            }.value
            inFlight.remove(.android)
            if let devices { record(androidDevices: devices) }
        }
    }

    /// Never prompts: without prior camera consent the picker's own request
    /// stays the only place that asks.
    private func warmAppleDevices() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              inFlight.insert(.apple).inserted else { return }
        Task {
            let result = await DeviceCaptureSession.loadDevices()
            inFlight.remove(.apple)
            record(appleDevices: result.options)
        }
    }

    /// Keeps the USB list current between pickers: macOS publishes a phone
    /// that was already plugged in a beat after the CMIO switch flips.
    private func observeCaptureHotPlug() {
        guard !observesCaptureHotPlug else { return }
        observesCaptureHotPlug = true
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MobileDeviceCache.shared.warmAppleDevices() }
            }
        }
    }
}
