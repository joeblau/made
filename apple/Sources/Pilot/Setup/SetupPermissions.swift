import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Network
import Observation

enum SetupPermission: String, CaseIterable, Identifiable {
    case localNetwork, accessibility, screenRecording, camera, microphone

    var id: String { rawValue }
    var title: String {
        switch self {
        case .localNetwork: "Local network"
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen recording"
        case .camera: "Camera & wired devices"
        case .microphone: "Microphone"
        }
    }
    var detail: String {
        switch self {
        case .localNetwork: "Connect Walkie and Kneeboard, discover remote Macs, and share device screens."
        case .accessibility: "Let Walkie's trackpad move and click the pointer on this Mac."
        case .screenRecording: "Share the Cockpit window with Kneeboard on your iPad."
        case .camera: "Preview a connected iPhone screen and allow camera use in browser previews."
        case .microphone: "Allow microphone use in browser previews. Walkie dictation records on your iPhone."
        }
    }
    var symbol: String {
        switch self {
        case .localNetwork: "network"
        case .accessibility: "hand.point.up.left"
        case .screenRecording: "rectangle.inset.filled.and.person.filled"
        case .camera: "camera"
        case .microphone: "mic"
        }
    }
    var settingsPane: String {
        switch self {
        case .localNetwork: "Privacy_LocalNetwork"
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        case .camera: "Privacy_Camera"
        case .microphone: "Privacy_Microphone"
        }
    }
}

enum SetupAccess: Equatable {
    case notRequested, checking, allowed, needsSettings, restricted, unverified

    var label: String {
        switch self {
        case .notRequested: "Optional"
        case .checking: "Waiting for approval…"
        case .allowed: "Allowed"
        case .needsSettings: "Review in System Settings"
        case .restricted: "Restricted by this Mac"
        case .unverified: "Could not verify access"
        }
    }
}

@MainActor
@Observable
final class SetupPermissions {
    private(set) var access: [SetupPermission: SetupAccess] = [:]
    private var requested: Set<SetupPermission> = []
    private var browser: NWBrowser?
    private var listener: NWListener?
    private var probeID: UUID?
    private var timeout: Task<Void, Never>?

    func status(_ permission: SetupPermission) -> SetupAccess {
        access[permission] ?? .notRequested
    }

    /// These preflights never ask for permission. Local Network has no public
    /// preflight API; only an explicit request starts a Bonjour operation.
    func refresh() {
        access[.accessibility] = AXIsProcessTrusted() ? .allowed
            : (requested.contains(.accessibility) ? .needsSettings : .notRequested)
        access[.screenRecording] = CGPreflightScreenCaptureAccess() ? .allowed
            : (requested.contains(.screenRecording) ? .needsSettings : .notRequested)
        access[.camera] = Self.mediaAccess(AVCaptureDevice.authorizationStatus(for: .video))
        access[.microphone] = Self.mediaAccess(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    static func mediaAccess(_ status: AVAuthorizationStatus) -> SetupAccess {
        switch status {
        case .authorized: .allowed
        case .notDetermined: .notRequested
        case .denied: .needsSettings
        case .restricted: .restricted
        @unknown default: .unverified
        }
    }

    func request(_ permission: SetupPermission) async {
        guard status(permission) != .checking, status(permission) != .restricted else { return }
        if status(permission) == .needsSettings {
            openSettings(permission)
            return
        }
        requested.insert(permission)
        switch permission {
        case .localNetwork:
            requestLocalNetwork()
        case .accessibility:
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .camera, .microphone:
            access[permission] = .checking
            _ = await AVCaptureDevice.requestAccess(for: permission == .camera ? .video : .audio)
        }
        refresh()
    }

    func openSettings(_ permission: SetupPermission) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(permission.settingsPane)") else { return }
        NSWorkspace.shared.open(url)
    }

    func verifyLocalNetwork() {
        requestLocalNetwork()
    }

    func stopProbe() {
        probeID = nil
        timeout?.cancel()
        timeout = nil
        browser?.cancel()
        listener?.cancel()
        browser = nil
        listener = nil
        if access[.localNetwork] == .checking { access[.localNetwork] = .unverified }
    }

    private func requestLocalNetwork() {
        stopProbe()
        let id = UUID()
        probeID = id
        access[.localNetwork] = .checking
        // Discover our own temporary service, so success does not require a
        // companion to be online. NWBrowser.ready alone is not proof of access.
        let serviceName = "Cockpit-Setup-\(id.uuidString)"
        do {
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(name: serviceName, type: "_blau-sync._tcp")
            listener.newConnectionHandler = { $0.cancel() }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.probeID == id else { return }
                    if case .failed = state { self.finishProbe(.unverified) }
                }
            }
            self.listener = listener
            let browser = NWBrowser(for: .bonjour(type: "_blau-sync._tcp", domain: nil), using: .tcp)
            browser.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.probeID == id else { return }
                    // TN3179: PolicyDenied is the documented denial signal.
                    // Keep browsing while the OS prompt is open; granting it
                    // can resume the operation without a second request.
                    if case .waiting(.dns(-65570)) = state {
                        self.access[.localNetwork] = .needsSettings
                    } else if case .failed = state {
                        self.finishProbe(.unverified)
                    }
                }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let found = results.contains {
                    if case .service(let name, _, _, _) = $0.endpoint { return name == serviceName }
                    return false
                }
                guard found else { return }
                Task { @MainActor in
                    guard let self, self.probeID == id else { return }
                    self.finishProbe(.allowed)
                }
            }
            self.browser = browser
            listener.start(queue: .main)
            browser.start(queue: .main)
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(45))
                guard !Task.isCancelled, let self, self.probeID == id else { return }
                self.finishProbe(self.access[.localNetwork] == .needsSettings ? .needsSettings : .unverified)
            }
        } catch {
            finishProbe(.unverified)
        }
    }

    private func finishProbe(_ result: SetupAccess) {
        stopProbe()
        access[.localNetwork] = result
    }
}
