import AVFoundation
import AppKit
import Observation

struct AndroidPaneActivityState {
    private(set) var presentationIDs: Set<UUID> = []

    var isActive: Bool { !presentationIDs.isEmpty }

    /// Returns true only for the inactive -> active transition.
    mutating func activate(_ presentationID: UUID) -> Bool {
        let wasInactive = presentationIDs.isEmpty
        presentationIDs.insert(presentationID)
        return wasInactive
    }

    /// Returns true only when the last active presentation departed.
    mutating func deactivate(_ presentationID: UUID) -> Bool {
        presentationIDs.remove(presentationID)
        return presentationIDs.isEmpty
    }
}

@MainActor
private final class AndroidPanePresentationCoordinator {
    static let shared = AndroidPanePresentationCoordinator()

    private var activityByPane: [UUID: AndroidPaneActivityState] = [:]
    private var pendingSuspensions: [UUID: Task<Void, Never>] = [:]

    func activate(paneID: UUID, presentationID: UUID) {
        pendingSuspensions.removeValue(forKey: paneID)?.cancel()
        var activity = activityByPane[paneID] ?? AndroidPaneActivityState()
        let shouldResume = activity.activate(presentationID)
        activityByPane[paneID] = activity
        if shouldResume {
            AndroidDeviceRegistry.shared.resume(paneID: paneID)
        }
    }

    func deactivate(paneID: UUID, presentationID: UUID) {
        guard var activity = activityByPane[paneID] else { return }
        let shouldSuspend = activity.deactivate(presentationID)
        if activity.isActive {
            activityByPane[paneID] = activity
        } else {
            activityByPane.removeValue(forKey: paneID)
        }
        guard shouldSuspend else { return }

        pendingSuspensions.removeValue(forKey: paneID)?.cancel()
        pendingSuspensions[paneID] = Task { @MainActor [weak self] in
            // Covers the brief source/destination overlap during a pane drop.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled,
                  let self,
                  self.activityByPane[paneID]?.isActive != true else { return }
            self.pendingSuspensions.removeValue(forKey: paneID)
            AndroidDeviceRegistry.shared.suspend(paneID: paneID)
        }
    }
}

@MainActor
final class AndroidPaneViewController: CapturePaneController {
    private let session: AndroidDeviceSession
    private let presentationID = UUID()
    private var copiedCount: Int
    private var droppedCount: Int
    private var polling: Task<Void, Never>?
    private var captureHost: AndroidCaptureHostView?

    override init(pane: Pane) {
        session = AndroidDeviceRegistry.shared.session(for: pane.id)
        copiedCount = session.clipboardCopyCount
        droppedCount = session.droppedTextNoticeCount
        super.init(pane: pane)
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        polling?.cancel()
        if isPresentationActive {
            AndroidPanePresentationCoordinator.shared.deactivate(paneID: paneID, presentationID: presentationID)
        }
    }

    override func presentationDidChange(isActive: Bool) {
        polling?.cancel()
        polling = nil
        captureHost?.isHidden = !isActive
        if isActive {
            AndroidPanePresentationCoordinator.shared.activate(paneID: paneID, presentationID: presentationID)
            session.invalidateAVDSerialCache()
            if session.status == .picking, session.devices.isEmpty { session.refreshDevices() }
            polling = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard let self, self.isPresentationActive else { return }
                    if self.session.status == .picking, !self.session.isRefreshing { self.session.refreshDevices() }
                }
            }
        } else {
            AndroidPanePresentationCoordinator.shared.deactivate(paneID: paneID, presentationID: presentationID)
        }
    }

    override func renderPresentation() {
        if copiedCount != session.clipboardCopyCount {
            copiedCount = session.clipboardCopyCount
            showToast("Screenshot Copied")
        }
        if droppedCount != session.droppedTextNoticeCount {
            droppedCount = session.droppedTextNoticeCount
            showToast("Some characters can’t be typed over adb", symbol: "keyboard.badge.ellipsis", duration: .milliseconds(2500))
        }
        switch session.status {
        case .streaming:
            present(key: "streaming") {
                let host = captureHost ?? AndroidCaptureHostView(session: session)
                captureHost = host
                return host
            }
        case .picking:
            renderPicker()
        case .adbMissing:
            present(key: "adb") {
                CapturePaneMessage("adb Required", symbol: "wrench.and.screwdriver",
                    detail: "Mirroring needs Android platform-tools. Install with:\nbrew install --cask android-platform-tools\n\nor install Android Studio, then Refresh.", dark: true,
                    actions: [CapturePaneAction(title: "Refresh", symbol: "arrow.clockwise", perform: { [weak self] in self?.session.refreshDevices() })])
            }
        case .booting(let name):
            present(key: "booting-\(name)") {
                CapturePaneMessage("Starting \(name)…", symbol: "apps.iphone", detail: "The emulator can take a minute to boot.", loading: true, dark: true,
                    actions: [CapturePaneAction(title: "Back to Devices", symbol: "list.bullet", perform: { [weak self] in self?.session.chooseAnotherDevice() })])
            }
        case .connecting(let name):
            present(key: "connecting-\(name)") { CapturePaneMessage("Connecting to \(name)…", symbol: "smartphone", loading: true, dark: true) }
        case .failed(let message):
            present(key: "failed-\(message)") {
                CapturePaneMessage("Device Unavailable", symbol: "exclamationmark.triangle", detail: message, dark: true, actions: [
                    CapturePaneAction(title: "Retry", symbol: "arrow.clockwise", perform: { [weak self] in self?.session.retry() }),
                    CapturePaneAction(title: "Back to Devices", symbol: "list.bullet", perform: { [weak self] in self?.session.chooseAnotherDevice() }),
                ])
            }
        }
    }

    private func renderPicker() {
        let hasBootable = session.target == .simulator && !session.bootableAVDs.isEmpty
        var items: [CapturePickerItem] = []
        if hasBootable && !session.devices.isEmpty { items.append(CapturePickerItem(id: "running", title: "Running", group: true)) }
        for device in session.devices {
            let detail: String?
            switch device.state {
            case .device: detail = nil
            case .unauthorized: detail = "Unauthorized — accept the USB-debugging prompt on the phone"
            case .offline: detail = "Offline — reconnect the cable or re-enable debugging"
            case .other: detail = "Not ready"
            }
            items.append(CapturePickerItem(id: device.serial, title: session.displayName(for: device), detail: detail,
                symbol: device.isEmulator ? "apps.iphone" : "smartphone", enabled: device.isConnectable,
                select: { [weak self] in self?.session.connect(device) }))
        }
        if hasBootable {
            items.append(CapturePickerItem(id: "available", title: "Available", group: true))
            for avd in session.bootableAVDs {
                items.append(CapturePickerItem(id: "avd-\(avd)", title: EmulatorBridge.displayName(for: avd), detail: "Not running — select to boot", symbol: "play.circle", select: { [weak self] in self?.session.bootAVD(avd) }))
            }
        }
        let message: NSView?
        if !items.isEmpty {
            message = nil
        } else if session.isRefreshing {
            message = CapturePaneMessage("Looking for devices…", symbol: "smartphone", loading: true)
        } else if let error = session.lastError {
            message = CapturePaneMessage("Couldn't List Devices", symbol: "exclamationmark.triangle", detail: error)
        } else {
            let title: String
            let guidance: String
            switch session.target {
            case .simulator:
                title = "No Android Simulators Found"
                guidance = "Create an emulator in Android Studio's Device Manager, then Refresh."
            case .device:
                title = "No Android Devices Found"
                guidance = "Connect a device over USB with USB debugging enabled (Settings → Developer options)."
            case nil:
                title = "No Android Sources Found"
                guidance = "Connect a device with USB debugging enabled, or start an emulator."
            }
            message = CapturePaneMessage(title, symbol: "smartphone", detail: guidance)
        }
        presentPicker(title: session.target?.pickerTitle ?? "Android", refreshing: session.isRefreshing,
            refresh: { [weak self] in self?.session.refreshDevices() }, items: items, message: message)
    }

    override func toolbarActions() -> [CapturePaneAction] {
        let streaming = session.status == .streaming
        return [
            CapturePaneAction(title: session.isRecording ? "Stop Recording" : "Record Screen", symbol: session.isRecording ? "stop.circle.fill" : "record.circle", enabled: streaming || session.isRecording, perform: { [weak self] in self?.session.toggleRecording() }),
            CapturePaneAction(title: "Take Screenshot", symbol: "camera.viewfinder", enabled: streaming, perform: { [weak self] in self?.session.takeScreenshot() }),
            CapturePaneAction(title: "Copy Screenshot", symbol: "clipboard", enabled: streaming, perform: { [weak self] in self?.session.copyScreenshotToClipboard() }),
            CapturePaneAction(title: "Back", symbol: "arrow.uturn.backward", enabled: streaming, perform: { [weak self] in self?.session.sendKeycode(AndroidKeyMap.Keycode.back) }),
            CapturePaneAction(title: "Home", symbol: "square.on.square", enabled: streaming, perform: { [weak self] in self?.session.sendKeycode(AndroidKeyMap.Keycode.home) }),
            CapturePaneAction(title: "App Switch", symbol: "square.grid.2x2", enabled: streaming, perform: { [weak self] in self?.session.sendKeycode(AndroidKeyMap.Keycode.appSwitch) }),
            CapturePaneAction(title: "Choose Device", symbol: "list.bullet", perform: { [weak self] in self?.session.chooseAnotherDevice() }),
        ]
    }
}

final class AndroidCaptureHostView: NSView {
    private let session: AndroidDeviceSession
    private var classifier = AndroidGestureClassifier()
    private var pressed = false
    private var screenDrag = DeviceScreenDragGesture()
    private var lastNormalized: (Double, Double)?

    init(session: AndroidDeviceSession) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        let host = CALayer()
        host.backgroundColor = NSColor.clear.cgColor
        layer = host
        let display = session.displayLayer
        display.removeFromSuperlayer()
        display.frame = bounds
        host.addSublayer(display)
    }

    @MainActor required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        session.displayLayer.frame = bounds
    }

    // MARK: coordinate mapping

    /// Map a local event point to normalized 0…1 within the displayed image,
    /// or nil for points in the letterbox.
    private func normalized(for event: NSEvent) -> (Double, Double)? {
        let source = session.captureSize ?? bounds.size
        let content = Self.aspectFit(source: source, into: bounds)
        guard content.width > 0, content.height > 0 else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        guard content.contains(local) else { return nil }
        let x = (local.x - content.minX) / content.width
        let y = (local.y - content.minY) / content.height
        return (Double(x), Double(y))
    }

    private static func aspectFit(source: CGSize, into bounds: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / source.width, bounds.height / source.height)
        let w = source.width * scale, h = source.height * scale
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    // MARK: pointer

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // ⌘-drag drags the screen image out instead of touching the device.
        if screenDrag.press(at: event.locationInWindow, modifiers: event.modifierFlags, requiresCommand: true) {
            return
        }
        guard let point = normalized(for: event) else { return }
        pressed = true
        lastNormalized = point
        session.gestureBegan(&classifier, normalizedX: point.0, normalizedY: point.1)
    }

    override func mouseDragged(with event: NSEvent) {
        if screenDrag.isTracking {
            if screenDrag.drag(to: event.locationInWindow) {
                DeviceScreenDrag.begin(
                    from: self,
                    event: event,
                    frame: DeviceScreenDrag.displayedFrame(of: session.displayLayer),
                    name: "android"
                )
            }
            return
        }
        guard pressed else { return }
        let point = normalized(for: event) ?? lastNormalized
        if let point {
            lastNormalized = point
            session.gestureMoved(&classifier, normalizedX: point.0, normalizedY: point.1)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if screenDrag.isTracking {
            screenDrag.release()
            return
        }
        guard pressed else { return }
        pressed = false
        let point = normalized(for: event) ?? lastNormalized
        if let point {
            session.gestureEnded(&classifier, normalizedX: point.0, normalizedY: point.1)
        }
        lastNormalized = nil
    }

    /// Right-click = Android Back, the scrcpy muscle-memory mapping.
    override func rightMouseDown(with event: NSEvent) {
        session.sendKeycode(AndroidKeyMap.Keycode.back)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let anchor = normalized(for: event) else { return }
        let content = Self.aspectFit(source: session.captureSize ?? bounds.size, into: bounds)
        guard content.width > 0, content.height > 0 else { return }
        let dx = Double(event.scrollingDeltaX) / Double(content.width)
        let dy = Double(event.scrollingDeltaY) / Double(content.height)
        session.scroll(normalizedDX: dx, normalizedDY: dy, anchorX: anchor.0, anchorY: anchor.1)
    }

    // MARK: keyboard

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers == "v" {
                session.pasteFromClipboard()
                return
            }
            super.keyDown(with: event)
            return
        }
        if session.keyDown(macKeyCode: event.keyCode) {
            return
        }
        if let characters = event.characters, !characters.isEmpty,
           characters.allSatisfy({ !$0.isNewline }) {
            session.type(characters)
        }
    }

    override func keyUp(with event: NSEvent) {}
}
