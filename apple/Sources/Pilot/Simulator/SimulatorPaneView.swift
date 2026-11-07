import AVFoundation
import AppKit
import Observation

@MainActor
final class SimulatorPaneViewController: CapturePaneController {
    private let session: SimulatorSession
    private var copiedCount: Int
    private var captureHost: SimulatorCaptureHostView?

    override init(pane: Pane) {
        session = SimulatorRegistry.shared.session(for: pane.id)
        copiedCount = session.clipboardCopyCount
        super.init(pane: pane)
    }

    required init?(coder: NSCoder) { nil }

    override func presentationDidChange(isActive: Bool) {
        if isActive, session.status == .picking, session.devices.isEmpty { session.refreshDevices() }
        captureHost?.isHidden = !isActive
    }

    override func renderPresentation() {
        if copiedCount != session.clipboardCopyCount {
            copiedCount = session.clipboardCopyCount
            showToast("Screenshot Copied")
        }
        switch session.status {
        case .streaming:
            present(key: "streaming") {
                let host = captureHost ?? SimulatorCaptureHostView(session: session)
                captureHost = host
                return host
            }
        case .picking:
            renderPicker()
        case .toolingMissing:
            present(key: "tooling") {
                CapturePaneMessage("Full Xcode Required", symbol: "wrench.and.screwdriver",
                    detail: "The iOS Simulator needs a full Xcode install. Install Xcode, then run:\nsudo xcode-select -s /Applications/Xcode.app/Contents/Developer",
                    dark: true, actions: [CapturePaneAction(title: "Refresh", symbol: "arrow.clockwise", perform: { [weak self] in self?.session.refreshDevices() })])
            }
        case .booting(let name):
            present(key: "booting-\(name)") { CapturePaneMessage("Booting \(name)…", symbol: "iphone", loading: true, dark: true) }
        case .starting(let name):
            present(key: "starting-\(name)") { CapturePaneMessage("Connecting to \(name)…", symbol: "iphone", loading: true, dark: true) }
        case .failed(let message):
            present(key: "failed-\(message)") {
                CapturePaneMessage("Simulator Unavailable", symbol: "exclamationmark.triangle", detail: message, dark: true,
                    actions: [CapturePaneAction(title: "Back to Devices", symbol: "list.bullet", perform: { [weak self] in self?.session.chooseAnotherDevice() })])
            }
        }
    }

    private func renderPicker() {
        var items: [CapturePickerItem] = []
        for group in session.devices {
            items.append(CapturePickerItem(id: group.id, title: group.displayName, group: true))
            for device in group.devices {
                items.append(CapturePickerItem(id: device.id, title: device.name, detail: device.isBooted ? "Booted" : nil,
                    symbol: device.deviceTypeIdentifier?.contains("iPad") == true ? "ipad" : "iphone",
                    select: { [weak self] in self?.session.boot(device) }))
            }
        }
        let message: NSView?
        if !items.isEmpty {
            message = nil
        } else if session.isRefreshing {
            message = CapturePaneMessage("Looking for simulators…", symbol: "iphone", loading: true)
        } else if let error = session.lastError {
            message = CapturePaneMessage("Couldn't List Simulators", symbol: "exclamationmark.triangle", detail: error)
        } else {
            message = CapturePaneMessage("No Simulators Found", symbol: "iphone", detail: "Create one in Xcode (Window → Devices and Simulators), then Refresh.")
        }
        presentPicker(title: "iPhone Simulator", refreshing: session.isRefreshing,
            refresh: { [weak self] in self?.session.refreshDevices() }, items: items, message: message)
    }

    override func toolbarActions() -> [CapturePaneAction] {
        let streaming = session.status == .streaming
        return [
            CapturePaneAction(title: session.isRecording ? "Stop Recording" : "Record Screen", symbol: session.isRecording ? "stop.circle.fill" : "record.circle", enabled: streaming || session.isRecording, perform: { [weak self] in self?.session.toggleRecording() }),
            CapturePaneAction(title: "Home", symbol: "square.grid.3x3.fill", enabled: streaming, perform: { [weak self] in self?.session.goHome() }),
            CapturePaneAction(title: "Take Screenshot", symbol: "camera.viewfinder", enabled: streaming, perform: { [weak self] in self?.session.takeScreenshot() }),
            CapturePaneAction(title: "Copy Screenshot", symbol: "clipboard", enabled: streaming, perform: { [weak self] in self?.session.copyScreenshotToClipboard() }),
            CapturePaneAction(title: "Choose Device", symbol: "list.bullet", perform: { [weak self] in self?.session.chooseAnotherDevice() }),
            CapturePaneAction(title: "Shutdown Simulator", symbol: "power", enabled: session.bootedUDID != nil, perform: { [weak self] in self?.session.shutdownSimulator() }),
        ]
    }
}

final class SimulatorCaptureHostView: NSView {
    private let session: SimulatorSession
    private var pressed = false
    private var screenDrag = DeviceScreenDragGesture()
    private var lastNormalized: (Double, Double)?
    private var lastFlags: NSEvent.ModifierFlags = []
    /// Edge of the active single-finger drag — `.bottom` when it started at the
    /// bottom of the screen, so dragging up triggers the Home gesture.
    private var activeEdge: SimulatorHID.Edge = .none
    // Pinch (trackpad magnify) state.
    private var pinchActive = false
    private var pinchCenter: (Double, Double) = (0.5, 0.5)
    private var pinchSpan = 0.12

    init(session: SimulatorSession) {
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

    /// Map a local event point to normalized 0…1 within the displayed image, or
    /// nil for points in the letterbox.
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

    // MARK: input

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // ⌘-drag drags the screen image out instead of touching the device.
        if screenDrag.press(at: event.locationInWindow, modifiers: event.modifierFlags, requiresCommand: true) {
            return
        }
        guard let point = normalized(for: event) else { return }
        pressed = true
        lastNormalized = point
        // Starting at the very bottom = a swipe-up-from-home gesture.
        activeEdge = point.1 >= 0.97 ? .bottom : .none
        session.touch(.down, normalizedX: point.0, normalizedY: point.1, edge: activeEdge)
    }

    override func mouseDragged(with event: NSEvent) {
        if screenDrag.isTracking {
            if screenDrag.drag(to: event.locationInWindow) {
                DeviceScreenDrag.begin(
                    from: self,
                    event: event,
                    frame: DeviceScreenDrag.displayedFrame(of: session.displayLayer),
                    name: "simulator"
                )
            }
            return
        }
        guard pressed else { return }
        let point = normalized(for: event) ?? lastNormalized
        if let point {
            lastNormalized = point
            session.touch(.move, normalizedX: point.0, normalizedY: point.1, edge: activeEdge)
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
        if let point { session.touch(.up, normalizedX: point.0, normalizedY: point.1, edge: activeEdge) }
        lastNormalized = nil
        activeEdge = .none
    }

    // MARK: gestures

    override func scrollWheel(with event: NSEvent) {
        guard let anchor = normalized(for: event) else { return }
        let content = Self.aspectFit(source: session.captureSize ?? bounds.size, into: bounds)
        guard content.width > 0, content.height > 0 else { return }
        let dx = Double(event.scrollingDeltaX) / Double(content.width)
        let dy = Double(event.scrollingDeltaY) / Double(content.height)
        session.scroll(normalizedDX: dx, normalizedDY: dy, anchorX: anchor.0, anchorY: anchor.1)
    }

    override func magnify(with event: NSEvent) {
        switch event.phase {
        case .began:
            pinchCenter = normalized(for: event) ?? (0.5, 0.5)
            pinchSpan = 0.12
            pinchActive = true
            sendPinch(.down)
        case .changed:
            guard pinchActive else { return }
            pinchSpan = min(max(pinchSpan + Double(event.magnification) * 0.6, 0.02), 0.45)
            sendPinch(.move)
        case .ended, .cancelled:
            guard pinchActive else { return }
            pinchActive = false
            sendPinch(.up)
        default:
            break
        }
    }

    private func sendPinch(_ phase: SimulatorHID.TouchPhase) {
        let (cx, cy) = pinchCenter
        session.pinch(phase, x1: cx - pinchSpan, y1: cy, x2: cx + pinchSpan, y2: cy)
    }

    override func keyDown(with event: NSEvent) {
        if let usage = HIDKeyMap.usage(forKeyCode: event.keyCode) {
            session.keyUsage(usage, down: true)
        }
    }

    override func keyUp(with event: NSEvent) {
        if let usage = HIDKeyMap.usage(forKeyCode: event.keyCode) {
            session.keyUsage(usage, down: false)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        let flags = event.modifierFlags
        func sync(_ flag: NSEvent.ModifierFlags, _ usage: UInt32) {
            let was = lastFlags.contains(flag), now = flags.contains(flag)
            if was != now { session.keyUsage(usage, down: now) }
        }
        sync(.shift, HIDKeyMap.leftShift)
        sync(.control, HIDKeyMap.leftControl)
        sync(.option, HIDKeyMap.leftOption)
        sync(.command, HIDKeyMap.leftCommand)
        lastFlags = flags
    }
}
