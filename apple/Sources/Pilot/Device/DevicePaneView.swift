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
    /// The spinner is for the first scan only; the 2-second background polls
    /// keep the last result on screen so the empty state doesn't flash.
    private var hasListedDevices = false
    private var isManualRefresh = false
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
        if PhoneControl.shared.paneID == paneID { PhoneControl.shared.disable() }
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
            IOSCaptureServiceRestarter.shared.captureDidRecover()
            present(key: "streaming") {
                let host = captureHost ?? DeviceCaptureHostView(session: session)
                captureHost = host
                return host
            }
            let control = PhoneControl.shared
            captureHost?.controlStatus = control.paneID == paneID ? control.status : .off
        case .picking:
            renderPicker()
        case .connecting:
            present(key: "connecting-\(session.deviceName ?? "")") {
                CapturePaneMessage("Connecting…", symbol: "arrow.triangle.2.circlepath", detail: session.deviceName,
                    loading: true, dark: true, actions: [wirelessAction()])
            }
        case .failed(let message):
            let denied = session.isCameraPermissionDenied
            let restarter = IOSCaptureServiceRestarter.shared
            present(key: "failed-\(message)-\(denied)-\(restarter.isRestarting)-\(restarter.nextScope)") {
                var actions: [CapturePaneAction]
                if denied {
                    actions = [
                        CapturePaneAction(title: "Open Camera Settings", symbol: "gear", perform: { [weak self] in self?.session.openCameraPrivacySettings() }),
                        CapturePaneAction(title: "Check Again", symbol: "arrow.clockwise", perform: { [weak self] in self?.session.retry() }),
                    ]
                } else {
                    actions = [
                        CapturePaneAction(title: "Retry", symbol: "arrow.clockwise", perform: { [weak self] in self?.session.retry() }),
                        restartCaptureServiceAction(),
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
        if !session.isRefreshing { hasListedDevices = true; isManualRefresh = false }
        let message: NSView?
        if !items.isEmpty {
            message = nil
        } else if session.isRefreshing, !hasListedDevices {
            message = CapturePaneMessage("Looking for devices…", symbol: "apps.iphone", loading: true)
        } else if let error = session.lastError {
            message = CapturePaneMessage("Couldn't List Devices", symbol: "exclamationmark.triangle", detail: error)
        } else {
            message = CapturePaneMessage("No USB Devices Found", symbol: "apps.iphone", detail: "Connect an iPhone or iPad over USB, trust this Mac, and keep its screen awake. If it is connected and still missing, restart the capture service.")
        }
        // An iPhone that is plugged in but never listed usually means the
        // capture daemon is wedged, so the empty picker offers the restart too.
        let actions = items.isEmpty ? [restartCaptureServiceAction(), wirelessAction()] : [wirelessAction()]
        presentPicker(title: "iOS Device", refreshing: session.isRefreshing && (!hasListedDevices || isManualRefresh),
            refresh: { [weak self] in self?.isManualRefresh = true; self?.session.refreshDevices() }, actions: actions, items: items, message: message,
            detail: session.preferredDeviceName.map { "Waiting for \($0)" })
    }

    private func wirelessAction() -> CapturePaneAction {
        CapturePaneAction(title: "Share Wirelessly…", symbol: "airplay.video", perform: { [weak self] in
            self?.stopControlIfOwned()
            self?.session.stop()
            self?.wireless.start()
        })
    }

    /// Kills macOS's wedged iPhone capture daemon behind the administrator
    /// password prompt, then reconnects. Always a click, never automatic. If
    /// that did not bring the device back, the same button restarts `usbmuxd`
    /// too.
    private func restartCaptureServiceAction() -> CapturePaneAction {
        let restarter = IOSCaptureServiceRestarter.shared
        return CapturePaneAction(title: restarter.nextScope.actionTitle, symbol: "wrench.and.screwdriver",
            enabled: !restarter.isRestarting, perform: { [weak self] in self?.restartCaptureService() })
    }

    private func restartCaptureService() {
        Task { @MainActor [weak self] in
            let scope = IOSCaptureServiceRestarter.shared.nextScope
            let outcome = await IOSCaptureServiceRestarter.shared.restart()
            guard let self else { return }
            switch outcome {
            case .restarted:
                self.session.captureServiceDidRestart()
                self.showToast(scope == .captureService ? "Capture Service Restarted" : "USB & Capture Services Restarted")
            case .failed(let message):
                self.showToast(message, symbol: "exclamationmark.triangle.fill", duration: .seconds(4), color: .systemOrange)
            case .cancelled, nil:
                break
            }
        }
    }

    private func useUSB() {
        wireless.useUSB()
        session.start()
    }

    private func toggleControl() {
        let control = PhoneControl.shared
        if control.isActive(for: paneID) {
            control.disable()
        } else {
            control.enable(paneID: paneID, captureID: session.preferredDeviceUniqueID,
                           captureName: session.deviceName ?? session.preferredDeviceName)
        }
    }

    private func stopControlIfOwned() {
        if PhoneControl.shared.paneID == paneID { PhoneControl.shared.disable() }
    }

    /// Clicks become taps, drags become swipes, and typing goes to the phone
    /// while control is on; these reach what a click can't.
    private func controlActions(streaming: Bool) -> [CapturePaneAction] {
        let control = PhoneControl.shared
        let active = control.isActive(for: paneID)
        let connected = active && control.isConnected
        var actions = [
            CapturePaneAction(title: active ? "Stop Controlling iPhone" : "Control iPhone", symbol: "hand.tap",
                enabled: streaming || active, selected: active, perform: { [weak self] in self?.toggleControl() }),
        ]
        if active {
            actions += [
                CapturePaneAction(title: "Home", symbol: "house", enabled: connected,
                    perform: { PhoneControl.shared.send(.gesture(PhoneGesturePath.home())) }),
                CapturePaneAction(title: "App Switcher", symbol: "square.stack", enabled: connected,
                    perform: { PhoneControl.shared.send(.gesture(PhoneGesturePath.appSwitcher())) }),
                CapturePaneAction(title: "AssistiveTouch Menu", symbol: "circle.circle", enabled: connected,
                    perform: { PhoneControl.shared.send(.assistiveTouchMenu) }),
            ]
        }
        return actions
    }

    override func toolbarActions() -> [CapturePaneAction] {
        let streaming = session.status == .streaming && !wireless.isEnabled
        return controlActions(streaming: streaming) + [
            CapturePaneAction(title: session.isRecording ? "Stop Recording" : "Record Screen", symbol: session.isRecording ? "stop.circle.fill" : "record.circle", enabled: streaming || session.isRecording, perform: { [weak self] in self?.session.toggleRecording() }),
            CapturePaneAction(title: "Take Screenshot", symbol: "camera.viewfinder", enabled: streaming, perform: { [weak self] in self?.session.takeScreenshot() }),
            CapturePaneAction(title: "Copy Screenshot", symbol: "clipboard", enabled: streaming, perform: { [weak self] in self?.session.copyScreenshotToClipboard() }),
            CapturePaneAction(title: "Choose Device", symbol: "list.bullet", enabled: !session.isCameraPermissionDenied, perform: { [weak self] in
                self?.stopControlIfOwned()
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
    private let banner = DeviceControlBanner()
    private var controlPressed = false
    private var lastControlPoint: PhonePoint?
    private var scrollAnchor: PhonePoint?
    private var scrollOffset = CGSize.zero

    /// The phone-control state for this pane; `.off` when another pane or
    /// nobody controls the phone.
    var controlStatus: PhoneControl.Status = .off {
        didSet {
            guard controlStatus != oldValue else { return }
            banner.update(controlStatus)
            if !isControlling { controlPressed = false; scrollAnchor = nil }
            if isControlling { window?.makeFirstResponder(self) }
            window?.invalidateCursorRects(for: self)
        }
    }

    private var isControlling: Bool { if case .connected = controlStatus { true } else { false } }

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

        banner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(banner)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            banner.centerXAnchor.constraint(equalTo: centerXAnchor),
            banner.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            banner.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
        banner.update(.off)
    }

    @MainActor required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }

    override var acceptsFirstResponder: Bool { isControlling }

    override func resetCursorRects() {
        if isControlling, let rect = videoRect() { addCursorRect(rect, cursor: .pointingHand) }
    }

    /// The video's on-screen rect in this view's (unflipped) coordinates.
    private func videoRect() -> CGRect? {
        let rect = previewLayer.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
        return rect.width > 1 && rect.height > 1 && rect.minX.isFinite && rect.minY.isFinite ? rect : nil
    }

    /// The phone point under an event, or nil outside the video. `clamp`
    /// keeps a drag that leaves the video pinned to its edge.
    private func phonePoint(for event: NSEvent, clamp: Bool = false) -> PhonePoint? {
        guard let rect = videoRect() else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        let point = PhonePoint(x: Double((local.x - rect.minX) / rect.width), y: Double((rect.maxY - local.y) / rect.height))
        if clamp { return point.clamped }
        return point.isValid ? point : nil
    }

    // ⌘-drag always drags the screen image out. Otherwise, while control is
    // on, the mouse drives the phone; the wired mirror alone is view-only, so
    // a plain drag drags the screen image.
    override func mouseDown(with event: NSEvent) {
        if isControlling, !event.modifierFlags.contains(.command) {
            window?.makeFirstResponder(self)
            guard let point = phonePoint(for: event) else { return }
            controlPressed = true
            lastControlPoint = point
            PhoneControl.shared.send(.down(point))
            return
        }
        _ = screenDrag.press(at: event.locationInWindow, modifiers: event.modifierFlags, requiresCommand: isControlling)
    }

    override func mouseDragged(with event: NSEvent) {
        if controlPressed {
            if let point = phonePoint(for: event, clamp: true) {
                lastControlPoint = point
                PhoneControl.shared.send(.move(point))
            }
            return
        }
        guard screenDrag.drag(to: event.locationInWindow) else { return }
        DeviceScreenDrag.begin(from: self, event: event, frame: captureSession.currentFrame(), name: "iphone")
    }

    override func mouseUp(with event: NSEvent) {
        if controlPressed {
            controlPressed = false
            if let point = phonePoint(for: event, clamp: true) ?? lastControlPoint {
                PhoneControl.shared.send(.up(point))
            }
            lastControlPoint = nil
            return
        }
        screenDrag.release()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isControlling else { return super.rightMouseDown(with: event) }
        PhoneControl.shared.send(.assistiveTouchMenu)
    }

    /// Two-finger trackpad scrolling becomes a finger drag on the phone.
    override func scrollWheel(with event: NSEvent) {
        guard isControlling, !controlPressed, let rect = videoRect() else { return super.scrollWheel(with: event) }
        if event.phase.contains(.began), let anchor = phonePoint(for: event) {
            scrollAnchor = anchor
            scrollOffset = .zero
            PhoneControl.shared.send(.down(anchor))
            return
        }
        guard let anchor = scrollAnchor else { return }
        if event.phase.contains(.changed) {
            scrollOffset.width += event.scrollingDeltaX
            scrollOffset.height += event.scrollingDeltaY
            PhoneControl.shared.send(.move(Self.scrolled(anchor, by: scrollOffset, in: rect.size)))
        } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            PhoneControl.shared.send(.up(Self.scrolled(anchor, by: scrollOffset, in: rect.size)))
            scrollAnchor = nil
        }
    }

    /// Natural scrolling: content follows the fingers, so a positive delta
    /// moves the touch down/right.
    static func scrolled(_ anchor: PhonePoint, by offset: CGSize, in size: CGSize) -> PhonePoint {
        PhonePoint(x: anchor.x + Double(offset.width / max(size.width, 1)),
                   y: anchor.y + Double(offset.height / max(size.height, 1))).clamped
    }

    override func keyDown(with event: NSEvent) {
        guard isControlling, let usage = HIDKeyMap.usage(forKeyCode: event.keyCode), usage <= 0xFF else {
            return super.keyDown(with: event)
        }
        PhoneControl.shared.send(.key(modifiers: PhoneHIDReport.modifiers(event.modifierFlags), usage: UInt8(usage)))
    }

    override func keyUp(with event: NSEvent) {
        guard isControlling else { return super.keyUp(with: event) }
        PhoneControl.shared.send(.keyUp)
    }
}

/// Setup progress and instructions over the mirrored screen while phone
/// control is starting, waiting for the phone, or has failed.
@MainActor
private final class DeviceControlBanner: NSVisualEffectView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let icon = NSImageView()

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.preferredMaxLayoutWidth = 320
        icon.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        let stack = NSStackView(views: [icon, label])
        stack.alignment = .top
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])
        setAccessibilityIdentifier("device.control-status")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(_ status: PhoneControl.Status) {
        let message: (symbol: String, color: NSColor, text: String)?
        switch status {
        case .off, .connected:
            message = nil
        case .preparing(let step):
            message = ("hourglass", .secondaryLabelColor, step)
        case .waitingForPhone(let phone, let mac):
            message = ("dot.radiowaves.left.and.right", .systemBlue,
                "On \(phone), open Settings › Accessibility › Touch › AssistiveTouch › Devices › Bluetooth Devices and choose \(mac). Keep the phone unlocked.")
        case .failed(let reason):
            message = ("exclamationmark.triangle.fill", .systemOrange, reason)
        }
        isHidden = message == nil
        guard let message else { return }
        icon.image = NSImage(systemSymbolName: message.symbol, accessibilityDescription: nil)
        icon.contentTintColor = message.color
        label.stringValue = message.text
        setAccessibilityLabel(message.text)
    }
}
