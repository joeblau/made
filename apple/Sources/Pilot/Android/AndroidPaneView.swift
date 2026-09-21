import AVFoundation
import AppKit
import SwiftUI

/// Reference-counted presentation state used during Main/Extension handoffs.
/// SwiftUI may mount the destination before unmounting the source, so one
/// departing presentation must not suspend a pane that is already live in the
/// other window.
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

/// The Android device pane. Switches on session status: a native device
/// picker, adb-install guidance, a connecting/failed overlay, or the live,
/// interactive mirror (just the device screen, gestures/keyboard replayed over
/// adb). Structural twin of `SimulatorPaneView`.
struct AndroidPaneView: View {
    let paneID: UUID
    let isActive: Bool
    let isSelected: Bool
    var isCollapsed: Bool = false

    @State private var showsCopiedToast = false
    @State private var showsDroppedTextToast = false
    @State private var copiedDismissWorkItem: DispatchWorkItem?
    @State private var droppedDismissWorkItem: DispatchWorkItem?
    @State private var presentationID = UUID()

    var body: some View {
        let session = AndroidDeviceRegistry.shared.session(for: paneID)
        ZStack {
            PreviewCanvasBackground()
            switch session.status {
            case .streaming:
                AndroidCaptureContainerView(session: session)
            case .picking:
                AndroidPickerView(session: session, isPolling: isActive && !isCollapsed)
            case .adbMissing:
                AndroidToolingMissingView(session: session)
            case .booting, .connecting, .failed:
                AndroidStatusOverlay(session: session)
            }

            if showsCopiedToast {
                toast(label: "Screenshot Copied", systemImage: "checkmark.circle.fill")
            }
            if showsDroppedTextToast {
                toast(label: "Some characters can't be typed over adb", systemImage: "keyboard.badge.ellipsis")
            }
        }
        .onChange(of: session.clipboardCopyCount) { _, _ in
            flash($showsCopiedToast, workItem: $copiedDismissWorkItem)
        }
        .onChange(of: session.droppedTextNoticeCount) { _, _ in
            flash($showsDroppedTextToast, workItem: $droppedDismissWorkItem, seconds: 2.5)
        }
        .onAppear {
            updatePresentation(isActive: isPresentationActive)
            if isPresentationActive, session.status == .picking, session.devices.isEmpty {
                session.refreshDevices()
            }
        }
        .onChange(of: isPresentationActive) { _, isPresented in
            updatePresentation(isActive: isPresented)
        }
        .onDisappear {
            AndroidPanePresentationCoordinator.shared.deactivate(
                paneID: paneID,
                presentationID: presentationID
            )
            copiedDismissWorkItem?.cancel()
            droppedDismissWorkItem?.cancel()
        }
    }

    private var isPresentationActive: Bool {
        isActive && !isCollapsed
    }

    private func updatePresentation(isActive: Bool) {
        if isActive {
            AndroidPanePresentationCoordinator.shared.activate(
                paneID: paneID,
                presentationID: presentationID
            )
        } else {
            AndroidPanePresentationCoordinator.shared.deactivate(
                paneID: paneID,
                presentationID: presentationID
            )
        }
    }

    private func toast(label: String, systemImage: String) -> some View {
        Label(label, systemImage: systemImage)
            .font(.headline)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
            .transition(.opacity.combined(with: .scale(scale: 0.85)))
            .allowsHitTesting(false)
            .zIndex(20)
    }

    private func flash(
        _ flag: Binding<Bool>,
        workItem: Binding<DispatchWorkItem?>,
        seconds: TimeInterval = 1
    ) {
        workItem.wrappedValue?.cancel()
        withAnimation(.snappy(duration: 0.18)) {
            flag.wrappedValue = true
        }
        let work = DispatchWorkItem {
            withAnimation(.snappy(duration: 0.3)) {
                flag.wrappedValue = false
            }
        }
        workItem.wrappedValue = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

// MARK: - Picker

private struct AndroidPickerView: View {
    let session: AndroidDeviceSession
    /// Collapsed/background panes stay mounted (opacity 0), so the poll must
    /// be gated explicitly — `.task` alone would keep spawning `adb devices`
    /// forever behind an invisible pane.
    let isPolling: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(session.target?.pickerTitle ?? "Android Device", systemImage: pickerSystemImage)
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
                .help("Re-scan connected Android devices")
            }
            .padding(12)

            if session.devices.isEmpty && session.bootableAVDs.isEmpty {
                emptyState
            } else {
                List {
                    if !session.devices.isEmpty {
                        Section {
                            ForEach(session.devices) { device in
                                Button {
                                    session.connect(device)
                                } label: {
                                    deviceRow(device)
                                }
                                .buttonStyle(.plain)
                                .disabled(!device.isConnectable)
                            }
                        } header: {
                            if showsBootableSection { Text("Running") }
                        }
                    }

                    // Installed-but-stopped AVDs the picker can boot (Simulator
                    // target only), mirroring the iOS pane's shut-down sims.
                    if showsBootableSection {
                        Section("Available") {
                            ForEach(session.bootableAVDs, id: \.self) { avd in
                                Button {
                                    session.bootAVD(avd)
                                } label: {
                                    avdRow(avd)
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
        .task(id: isPolling) {
            // Devices come and go on the USB cable; keep the list fresh while
            // the picker is actually visible.
            guard isPolling else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard session.status == .picking, !session.isRefreshing else { continue }
                session.refreshDevices()
            }
        }
    }

    private func deviceRow(_ device: AndroidDevice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: device.isEmulator ? "apps.iphone" : "smartphone")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.displayName)
                if let hint = stateHint(device) {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: device.isConnectable ? "chevron.right" : "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 3)
    }

    /// Only the Simulator target lists bootable AVDs; the header text only earns
    /// its keep when running devices are also shown alongside them.
    private var showsBootableSection: Bool {
        session.target == .simulator && !session.bootableAVDs.isEmpty
    }

    private func avdRow(_ avd: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "play.circle")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(EmulatorBridge.displayName(for: avd))
                Text("Not running — tap to boot").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "power")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 3)
    }

    private func stateHint(_ device: AndroidDevice) -> String? {
        switch device.state {
        case .device: nil
        case .unauthorized: "Unauthorized — accept the USB-debugging prompt on the phone"
        case .offline: "Offline — reconnect the cable or re-enable debugging"
        case .other: "Not ready"
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            if session.isRefreshing {
                ProgressView()
                Text("Looking for devices…").foregroundStyle(.secondary)
            } else if let error = session.lastError {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 34)).foregroundStyle(.secondary)
                Text("Couldn't list devices").font(.headline)
                Text(error).font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
            } else {
                Image(systemName: "smartphone").font(.system(size: 34)).foregroundStyle(.secondary)
                Text(emptyTitle).font(.headline)
                Text(emptyGuidance)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pickerSystemImage: String {
        session.target == .simulator ? "apps.iphone" : "smartphone"
    }

    private var emptyTitle: String {
        switch session.target {
        case .simulator: "No Android simulators found"
        case .device: "No Android devices found"
        case nil: "No Android sources found"
        }
    }

    private var emptyGuidance: String {
        switch session.target {
        case .simulator: "Create an emulator in Android Studio's Device Manager, then Refresh."
        case .device: "Connect a device over USB with USB debugging enabled (Settings → Developer options)."
        case nil: "Connect a device over USB with USB debugging enabled, or start an emulator."
        }
    }
}

// MARK: - Tooling missing

private struct AndroidToolingMissingView: View {
    let session: AndroidDeviceSession

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "wrench.and.screwdriver").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("adb required").font(.headline)
            Text("Mirroring an Android device needs the adb tool from Android platform-tools.\n\nInstall it with:\nbrew install --cask android-platform-tools\n\nor install Android Studio, then Refresh.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            Button("Refresh") { session.refreshDevices() }
                .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PreviewCanvasBackground())
    }
}

// MARK: - Status overlay (connecting / failed)

private struct AndroidStatusOverlay: View {
    let session: AndroidDeviceSession

    var body: some View {
        VStack(spacing: 12) {
            switch session.status {
            case .booting(let name):
                ProgressView()
                Text("Starting \(name)…").font(.headline)
                Text("The emulator can take a minute to boot.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Back to Devices") { session.chooseAnotherDevice() }
                    .padding(.top, 4)
            case .connecting(let name):
                ProgressView()
                Text("Connecting to \(name)…").font(.headline)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle").font(.system(size: 36)).foregroundStyle(.secondary)
                Text("Device unavailable").font(.headline)
                Text(message).font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
                HStack {
                    Button("Retry") { session.retry() }
                        .buttonStyle(.borderedProminent)
                    Button("Back to Devices") { session.chooseAnotherDevice() }
                }
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

private struct AndroidCaptureContainerView: NSViewRepresentable {
    let session: AndroidDeviceSession

    func makeNSView(context: Context) -> AndroidCaptureHostView {
        AndroidCaptureHostView(session: session)
    }

    func updateNSView(_ nsView: AndroidCaptureHostView, context: Context) {}
}

/// Hosts the session's display layer and replays pointer/keyboard input to the
/// device over adb. Flipped so the local origin is top-left, matching the
/// video. Gestures are recorded and replayed on mouse-up (adb's `input` tool
/// has no live event channel), classified to preserve tap/long-press/swipe/
/// drag semantics; right-click sends Android Back.
final class AndroidCaptureHostView: NSView {
    private let session: AndroidDeviceSession
    private var classifier = AndroidGestureClassifier()
    private var pressed = false
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { window?.makeFirstResponder(self) }
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
        guard let point = normalized(for: event) else { return }
        pressed = true
        lastNormalized = point
        session.gestureBegan(&classifier, normalizedX: point.0, normalizedY: point.1)
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressed else { return }
        let point = normalized(for: event) ?? lastNormalized
        if let point {
            lastNormalized = point
            session.gestureMoved(&classifier, normalizedX: point.0, normalizedY: point.1)
        }
    }

    override func mouseUp(with event: NSEvent) {
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
