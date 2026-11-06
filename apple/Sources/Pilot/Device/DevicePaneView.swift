import AVFoundation
import AppKit
import Observation

@MainActor
private final class DevicePanePresentationCoordinator {
    static let shared = DevicePanePresentationCoordinator()

    private var presentationIDsByPane: [UUID: Set<UUID>] = [:]
    private var pendingSuspensions: [UUID: Task<Void, Never>] = [:]

    func activate(paneID: UUID, presentationID: UUID) {
        pendingSuspensions.removeValue(forKey: paneID)?.cancel()
        presentationIDsByPane[paneID, default: []].insert(presentationID)
    }

    func deactivate(paneID: UUID, presentationID: UUID) {
        presentationIDsByPane[paneID]?.remove(presentationID)
        if presentationIDsByPane[paneID]?.isEmpty == true {
            presentationIDsByPane.removeValue(forKey: paneID)
        }
        guard presentationIDsByPane[paneID] == nil else { return }

        pendingSuspensions.removeValue(forKey: paneID)?.cancel()
        pendingSuspensions[paneID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled,
                  let self,
                  self.presentationIDsByPane[paneID] == nil else { return }
            self.pendingSuspensions.removeValue(forKey: paneID)
            DeviceCaptureRegistry.shared.suspend(paneID: paneID)
        }
    }
}

@MainActor
final class DevicePaneViewController: CapturePaneController {
    private let session: DeviceCaptureSession
    private let wireless: WirelessDeviceSession
    private let presentationID = UUID()
    private var polling: Task<Void, Never>?
    private var captureHost: DeviceCaptureHostView?
    private var copiedCount: Int
    private var silentRecordingCount: Int

    override init(pane: Pane) {
        session = DeviceCaptureRegistry.shared.session(for: pane.id)
        wireless = DeviceCaptureRegistry.shared.wirelessSession(for: pane.id)
        copiedCount = session.clipboardCopyCount
        silentRecordingCount = session.recordingWithoutAudioCount
        super.init(pane: pane)
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        polling?.cancel()
        if isPresentationActive {
            DevicePanePresentationCoordinator.shared.deactivate(paneID: paneID, presentationID: presentationID)
        }
    }

    override func presentationDidChange(isActive: Bool) {
        polling?.cancel()
        polling = nil
        captureHost?.isHidden = !isActive
        if isActive {
            DevicePanePresentationCoordinator.shared.activate(paneID: paneID, presentationID: presentationID)
            if !wireless.isEnabled { session.start() }
            polling = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard let self, self.isPresentationActive else { return }
                    if !self.wireless.isEnabled, self.session.status == .picking, !self.session.isRefreshing {
                        self.session.refreshDevices()
                    }
                }
            }
        } else {
            DevicePanePresentationCoordinator.shared.deactivate(paneID: paneID, presentationID: presentationID)
        }
    }

    override func renderPresentation() {
        if copiedCount != session.clipboardCopyCount {
            copiedCount = session.clipboardCopyCount
            showToast("Screenshot Copied")
        }
        if silentRecordingCount != session.recordingWithoutAudioCount {
            silentRecordingCount = session.recordingWithoutAudioCount
            showToast("Recording without audio", symbol: "mic.slash.fill", duration: .milliseconds(2500), color: .systemOrange)
        }
        if wireless.isEnabled {
            let rendererID = wireless.renderer.map { String(describing: ObjectIdentifier($0)) } ?? "none"
            present(key: "wireless-\(wireless.status)-\(rendererID)") {
                WirelessDeviceView(session: wireless, useUSB: { [weak self] in self?.useUSB() })
            }
            return
        }
        switch session.status {
        case .streaming:
            present(key: "streaming") {
                let host = captureHost ?? DeviceCaptureHostView(session: session)
                captureHost = host
                return host
            }
        case .picking:
            renderPicker()
        case .connecting:
            present(key: "connecting-\(session.deviceName ?? "")") {
                CapturePaneMessage("Connecting…", symbol: "arrow.triangle.2.circlepath", detail: session.deviceName,
                    loading: true, dark: true, actions: [wirelessAction()])
            }
        case .failed(let message):
            let denied = session.isCameraPermissionDenied
            present(key: "failed-\(message)-\(denied)") {
                var actions: [CapturePaneAction]
                if denied {
                    actions = [
                        CapturePaneAction(title: "Open Camera Settings", symbol: "gear", perform: { [weak self] in self?.session.openCameraPrivacySettings() }),
                        CapturePaneAction(title: "Check Again", symbol: "arrow.clockwise", perform: { [weak self] in self?.session.retry() }),
                    ]
                } else {
                    actions = [
                        CapturePaneAction(title: "Retry", symbol: "arrow.clockwise", perform: { [weak self] in self?.session.retry() }),
                        CapturePaneAction(title: "Back to Devices", symbol: "list.bullet", perform: { [weak self] in self?.session.chooseAnotherDevice() }),
                    ]
                }
                actions.append(wirelessAction())
                return CapturePaneMessage(denied ? "Camera Access Required" : "Capture Failed", symbol: denied ? "video.slash" : "exclamationmark.triangle", detail: message, dark: true, actions: actions)
            }
        }
    }

    private func renderPicker() {
        let items = session.devices.map { device in
            CapturePickerItem(id: device.id, title: device.name, detail: device.detail, symbol: "apps.iphone",
                select: { [weak self] in self?.session.connect(device) })
        }
        let message: NSView?
        if !items.isEmpty {
            message = nil
        } else if session.isRefreshing {
            message = CapturePaneMessage("Looking for devices…", symbol: "apps.iphone", loading: true)
        } else if let error = session.lastError {
            message = CapturePaneMessage("Couldn't List Devices", symbol: "exclamationmark.triangle", detail: error)
        } else {
            message = CapturePaneMessage("No USB Devices Found", symbol: "apps.iphone", detail: "Connect an iPhone or iPad over USB, trust this Mac, and keep its screen awake.")
        }
        presentPicker(title: "iOS Device", refreshing: session.isRefreshing,
            refresh: { [weak self] in self?.session.refreshDevices() }, actions: [wirelessAction()], items: items, message: message,
            detail: session.preferredDeviceName.map { "Waiting for \($0)" })
    }

    private func wirelessAction() -> CapturePaneAction {
        CapturePaneAction(title: "Share Wirelessly…", symbol: "airplay.video", perform: { [weak self] in
            self?.session.stop()
            self?.wireless.start()
        })
    }

    private func useUSB() {
        wireless.useUSB()
        session.start()
    }

    override func toolbarActions() -> [CapturePaneAction] {
        let streaming = session.status == .streaming && !wireless.isEnabled
        return [
            CapturePaneAction(title: session.isRecording ? "Stop Recording" : "Record Screen", symbol: session.isRecording ? "stop.circle.fill" : "record.circle", enabled: streaming || session.isRecording, perform: { [weak self] in self?.session.toggleRecording() }),
            CapturePaneAction(title: "Take Screenshot", symbol: "camera.viewfinder", enabled: streaming, perform: { [weak self] in self?.session.takeScreenshot() }),
            CapturePaneAction(title: "Copy Screenshot", symbol: "clipboard", enabled: streaming, perform: { [weak self] in self?.session.copyScreenshotToClipboard() }),
            CapturePaneAction(title: "Choose Device", symbol: "list.bullet", enabled: !session.isCameraPermissionDenied, perform: { [weak self] in
                self?.wireless.useUSB()
                self?.session.chooseAnotherDevice()
            }),
            wirelessAction(),
            CapturePaneAction(title: "Developer Tools", symbol: "hammer", perform: { SafariWebInspector.open() }),
        ]
    }
}

final class DeviceCaptureHostView: NSView {
    private let captureSession: DeviceCaptureSession
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private var screenDrag = DeviceScreenDragGesture()

    init(session: DeviceCaptureSession) {
        self.captureSession = session
        super.init(frame: .zero)
        wantsLayer = true
        let host = CALayer()
        host.backgroundColor = NSColor.clear.cgColor
        layer = host

        previewLayer.session = captureSession.session
        previewLayer.videoGravity = .resizeAspect
        previewLayer.backgroundColor = NSColor.clear.cgColor
        host.addSublayer(previewLayer)
    }

    @MainActor required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }

    // The wired mirror is view-only, so a plain drag drags the screen image.
    override func mouseDown(with event: NSEvent) {
        _ = screenDrag.press(at: event.locationInWindow, modifiers: event.modifierFlags, requiresCommand: false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard screenDrag.drag(to: event.locationInWindow) else { return }
        DeviceScreenDrag.begin(from: self, event: event, frame: captureSession.currentFrame(), name: "iphone")
    }

    override func mouseUp(with event: NSEvent) {
        screenDrag.release()
    }
}
