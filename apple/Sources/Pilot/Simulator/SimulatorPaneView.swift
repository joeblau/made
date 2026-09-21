import AVFoundation
import AppKit
import SwiftUI

/// The iPhone Simulator pane. Switches on session status: a native picker, a
/// "needs full Xcode" notice, a boot/start overlay, or the live, interactive
/// framebuffer (just the device screen, touch/keyboard forwarded via HID).
struct SimulatorPaneView: View {
    let paneID: UUID
    let isActive: Bool
    let isSelected: Bool

    @State private var showsCopiedToast = false
    @State private var toastDismissWorkItem: DispatchWorkItem?

    var body: some View {
        let session = SimulatorRegistry.shared.session(for: paneID)
        ZStack {
            PreviewCanvasBackground()
            switch session.status {
            case .streaming:
                SimulatorCaptureContainerView(session: session)
            case .picking:
                SimulatorPickerView(session: session)
            case .toolingMissing:
                SimulatorToolingMissingView()
            case .booting, .starting, .failed:
                SimulatorStatusOverlay(session: session)
            }

            if showsCopiedToast {
                Label("Screenshot Copied", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    .allowsHitTesting(false)
                    .zIndex(20)
            }
        }
        .onChange(of: session.clipboardCopyCount) { _, _ in
            flashCopiedToast()
        }
        .onAppear {
            if session.status == .picking, session.devices.isEmpty {
                session.refreshDevices()
            }
        }
        .onDisappear {
            toastDismissWorkItem?.cancel()
        }
    }

    private func flashCopiedToast() {
        toastDismissWorkItem?.cancel()
        withAnimation(.snappy(duration: 0.18)) {
            showsCopiedToast = true
        }
        let work = DispatchWorkItem {
            withAnimation(.snappy(duration: 0.3)) {
                showsCopiedToast = false
            }
        }
        toastDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
}

// MARK: - Picker

private struct SimulatorPickerView: View {
    let session: SimulatorSession

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("iPhone Simulator", systemImage: "ipad.landscape.and.ipod")
                    .font(.headline)
                Spacer()
                if session.isRefreshing {
                    ProgressView().controlSize(.small)
                }
                Button {
                    session.refreshDevices()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(session.isRefreshing)
                .help("Re-scan installed simulators")
            }
            .padding(12)

            if session.devices.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(session.devices) { group in
                        Section(group.displayName) {
                            ForEach(group.devices) { device in
                                Button {
                                    session.boot(device)
                                } label: {
                                    deviceRow(device)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func deviceRow(_ device: SimDevice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: device.deviceTypeIdentifier?.contains("iPad") == true ? "ipad" : "iphone")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(device.name)
            Spacer()
            if device.isBooted {
                Text("Booted")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            }
            Image(systemName: device.isBooted ? "play.fill" : "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            if session.isRefreshing {
                ProgressView()
                Text("Looking for simulators…").foregroundStyle(.secondary)
            } else if let error = session.lastError {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 34)).foregroundStyle(.secondary)
                Text("Couldn't list simulators").font(.headline)
                Text(error).font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
            } else {
                Image(systemName: "iphone").font(.system(size: 34)).foregroundStyle(.secondary)
                Text("No simulators found").font(.headline)
                Text("Create one in Xcode (Window → Devices and Simulators), then Refresh.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Tooling missing

private struct SimulatorToolingMissingView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "wrench.and.screwdriver").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("Full Xcode required").font(.headline)
            Text("The iOS Simulator needs a full Xcode install (the Command Line Tools alone can't run simctl).\n\nInstall Xcode, then run:\nsudo xcode-select -s /Applications/Xcode.app/Contents/Developer")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PreviewCanvasBackground())
    }
}

// MARK: - Status overlay (booting / starting / failed)

private struct SimulatorStatusOverlay: View {
    let session: SimulatorSession

    var body: some View {
        VStack(spacing: 12) {
            switch session.status {
            case .booting(let name):
                ProgressView()
                Text("Booting \(name)…").font(.headline)
            case .starting(let name):
                ProgressView()
                Text("Connecting to \(name)…").font(.headline)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle").font(.system(size: 36)).foregroundStyle(.secondary)
                Text("Simulator unavailable").font(.headline)
                Text(message).font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
                Button("Back to Devices") { session.chooseAnotherDevice() }
                    .buttonStyle(.borderedProminent)
            default:
                EmptyView()
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PreviewCanvasBackground())
    }
}

// MARK: - Live capture host (interactive)

private struct SimulatorCaptureContainerView: NSViewRepresentable {
    let session: SimulatorSession

    func makeNSView(context: Context) -> SimulatorCaptureHostView {
        SimulatorCaptureHostView(session: session)
    }

    func updateNSView(_ nsView: SimulatorCaptureHostView, context: Context) {}
}

/// Hosts the session's display layer and forwards pointer/keyboard input to the
/// simulator as normalized 0…1 coordinates (via HID). Flipped so the local
/// origin is top-left, matching the framebuffer.
final class SimulatorCaptureHostView: NSView {
    private let session: SimulatorSession
    private var pressed = false
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { window?.makeFirstResponder(self) }
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
        guard let point = normalized(for: event) else { return }
        pressed = true
        lastNormalized = point
        // Starting at the very bottom = a swipe-up-from-home gesture.
        activeEdge = point.1 >= 0.97 ? .bottom : .none
        session.touch(.down, normalizedX: point.0, normalizedY: point.1, edge: activeEdge)
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressed else { return }
        let point = normalized(for: event) ?? lastNormalized
        if let point {
            lastNormalized = point
            session.touch(.move, normalizedX: point.0, normalizedY: point.1, edge: activeEdge)
        }
    }

    override func mouseUp(with event: NSEvent) {
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
