import AVFoundation
import AppKit
import SwiftUI

/// Tracks live SwiftUI presentations separately from the capture registry.
/// During a cross-window pane drop, SwiftUI can mount the destination before
/// unmounting the source (or vice versa); the short handoff delay prevents the
/// departing presentation from stopping the session now owned by the arrival.
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

struct DevicePaneView: View {
    let paneID: UUID
    let isActive: Bool
    let isSelected: Bool
    var isCollapsed: Bool = false

    @State private var toast: DeviceToast?
    @State private var toastDismissWorkItem: DispatchWorkItem?
    @State private var presentationID = UUID()

    var body: some View {
        Group {
            if isPresentationActive {
                activeContent
            } else {
                PreviewCanvasBackground()
            }
        }
        .onAppear {
            updatePresentation(isActive: isPresentationActive)
        }
        .onChange(of: isPresentationActive) { _, isPresented in
            updatePresentation(isActive: isPresented)
        }
        .onDisappear {
            DevicePanePresentationCoordinator.shared.deactivate(
                paneID: paneID,
                presentationID: presentationID
            )
            toastDismissWorkItem?.cancel()
        }
    }

    private var activeContent: some View {
        let session = DeviceCaptureRegistry.shared.session(for: paneID)
        let wireless = DeviceCaptureRegistry.shared.wirelessSession(for: paneID)
        return ZStack {
            PreviewCanvasBackground()
            if wireless.isEnabled {
                WirelessDeviceView(session: wireless) {
                    wireless.useUSB()
                    session.start()
                }
            } else {
                switch session.status {
                case .streaming:
                    DeviceCaptureContainerView(session: session)
                case .picking:
                    IOSDevicePickerView(session: session, isPolling: isActive && !isCollapsed) {
                        session.stop()
                        wireless.start()
                    }
                case .connecting, .failed:
                    DeviceStatusOverlay(session: session)
                        .safeAreaInset(edge: .top) {
                            Button {
                                session.stop()
                                wireless.start()
                            } label: {
                                Label("Share Wirelessly…", systemImage: "airplay.video")
                            }
                            .padding(12)
                        }
                }
            }

            if let toast {
                DeviceToastView(toast: toast)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    .allowsHitTesting(false)
                    .zIndex(20)
            }
        }
        .onChange(of: session.clipboardCopyCount) { _, _ in
            flash(DeviceToast(text: "Screenshot Copied", systemImage: "checkmark.circle.fill"))
        }
        .onChange(of: session.recordingWithoutAudioCount) { _, _ in
            // Held a touch longer than the copy toast since it's a heads-up, not
            // a confirmation.
            flash(
                DeviceToast(text: "Recording without audio", systemImage: "mic.slash.fill", tint: .orange),
                duration: 2.5
            )
        }
    }

    private var isPresentationActive: Bool {
        isActive && !isCollapsed
    }

    private func updatePresentation(isActive: Bool) {
        if isActive {
            DevicePanePresentationCoordinator.shared.activate(
                paneID: paneID,
                presentationID: presentationID
            )
            if !DeviceCaptureRegistry.shared.wirelessSession(for: paneID).isEnabled {
                DeviceCaptureRegistry.shared.session(for: paneID).start()
            }
        } else {
            DevicePanePresentationCoordinator.shared.deactivate(
                paneID: paneID,
                presentationID: presentationID
            )
            toastDismissWorkItem?.cancel()
            toast = nil
        }
    }

    private func flash(_ content: DeviceToast, duration: TimeInterval = 1.0) {
        toastDismissWorkItem?.cancel()
        withAnimation(.snappy(duration: 0.18)) {
            toast = content
        }
        let work = DispatchWorkItem {
            withAnimation(.snappy(duration: 0.3)) {
                toast = nil
            }
        }
        toastDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}

/// Shared iPhone/iPad capture controls used by both Pilot windows.
struct DeviceToolbarControls: View {
    let paneID: UUID

    var body: some View {
        let session = DeviceCaptureRegistry.shared.session(for: paneID)
        let wireless = DeviceCaptureRegistry.shared.wirelessSession(for: paneID)
        let isStreaming = session.status == .streaming

        Button {
            session.toggleRecording()
        } label: {
            Label(
                session.isRecording ? "Stop Recording" : "Record Screen",
                systemImage: session.isRecording ? "stop.circle.fill" : "record.circle"
            )
            .foregroundStyle(session.isRecording ? .red : .primary)
        }
        .disabled(!isStreaming)
        .help(session.isRecording ? "Stop recording" : "Record the iPhone screen")

        Button {
            session.takeScreenshot()
        } label: {
            Label("Take Screenshot", systemImage: "camera.viewfinder")
        }
        .disabled(!isStreaming)
        .help("Save a screenshot of the iPhone screen to the Desktop")

        Button {
            session.copyScreenshotToClipboard()
        } label: {
            Label("Copy Screenshot", systemImage: "clipboard")
        }
        .disabled(!isStreaming)
        .help("Copy a screenshot of the iPhone screen to the clipboard")

        Button {
            wireless.useUSB()
            session.chooseAnotherDevice()
        } label: {
            Label("Choose Device", systemImage: "list.bullet")
        }
        .disabled(session.isCameraPermissionDenied)
        .help("Pick a different iPhone or iPad")

        Button {
            session.stop()
            wireless.start()
        } label: {
            Label("Share Wirelessly…", systemImage: "airplay.video")
        }
        .help("Receive Screen Mirroring from an iPhone or iPad on Wi-Fi")

        Button {
            SafariWebInspector.open()
        } label: {
            Label("Developer Tools", systemImage: "hammer")
        }
        .help("Open Safari Web Inspector to debug this device")
    }
}

// MARK: - Picker

private struct IOSDevicePickerView: View {
    let session: DeviceCaptureSession
    let isPolling: Bool
    let startWireless: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("iOS Device", systemImage: "apps.iphone")
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
                .help("Re-scan connected iPhones and iPads")
            }
            .padding(12)

            Button(action: startWireless) {
                Label("Share Wirelessly…", systemImage: "airplay.video")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderless)
            .padding(8)

            if let preferredName = session.preferredDeviceName {
                Label("Waiting for \(preferredName)", systemImage: "cable.connector")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }

            if session.devices.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(session.devices) { device in
                        Button {
                            session.connect(device)
                        } label: {
                            deviceRow(device)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: isPolling) {
            guard isPolling else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard session.status == .picking, !session.isRefreshing else { continue }
                session.refreshDevices()
            }
        }
    }

    private func deviceRow(_ device: IOSCaptureDevice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "apps.iphone")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                if let detail = device.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 3)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if session.isRefreshing {
                ProgressView()
                Text("Looking for devices…")
                    .foregroundStyle(.secondary)
            } else if let error = session.lastError {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text("Couldn't list devices").font(.headline)
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            } else {
                Image(systemName: "apps.iphone")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text("No USB devices found").font(.headline)
                Text("Connect an iPhone or iPad over USB, trust this Mac, and keep its screen awake.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DeviceToast {
    let text: String
    let systemImage: String
    var tint: Color = .primary
}

private struct DeviceToastView: View {
    let toast: DeviceToast

    var body: some View {
        Label(toast.text, systemImage: toast.systemImage)
            .font(.headline)
            .foregroundStyle(toast.tint)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }
}

private struct DeviceStatusOverlay: View {
    let session: DeviceCaptureSession

    var body: some View {
        Group {
            switch session.status {
            case .picking:
                EmptyView()
            case .connecting:
                statusBlock(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Connecting…",
                    detail: session.deviceName
                )
            case .streaming:
                Color.clear
            case .failed(let message):
                if session.isCameraPermissionDenied {
                    permissionDeniedBlock(message: message)
                } else {
                    statusBlock(
                        icon: "exclamationmark.triangle",
                        title: "Capture failed",
                        detail: message,
                        // Self-heal polls in the background, but give the user
                        // an immediate exact-device retry too.
                        retry: { session.retry() },
                        chooseAnother: { session.chooseAnotherDevice() }
                    )
                }
            }
        }
    }

    private func permissionDeniedBlock(message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "video.slash")
                .scaledFont(size: 36)
                .foregroundStyle(.secondary)
            Text("Camera access required")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            HStack {
                Button("Open Camera Settings") {
                    session.openCameraPrivacySettings()
                }
                .buttonStyle(.borderedProminent)
                Button("Check Again") {
                    session.retry()
                }
            }
            .padding(.top, 8)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PreviewCanvasBackground())
    }

    private func statusBlock(
        icon: String,
        title: String,
        detail: String?,
        retry: (() -> Void)? = nil,
        chooseAnother: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .scaledFont(size: 36)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            if retry != nil || chooseAnother != nil {
                HStack {
                    if let retry {
                        Button("Retry", action: retry)
                            .buttonStyle(.borderedProminent)
                    }
                    if let chooseAnother {
                        Button("Back to Devices", action: chooseAnother)
                    }
                }
                .padding(.top, 8)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PreviewCanvasBackground())
    }
}

private struct DeviceCaptureContainerView: NSViewRepresentable {
    let session: DeviceCaptureSession

    func makeNSView(context: Context) -> DeviceCaptureHostView {
        DeviceCaptureHostView(session: session)
    }

    func updateNSView(_ nsView: DeviceCaptureHostView, context: Context) {}
}

final class DeviceCaptureHostView: NSView {
    private let captureSession: DeviceCaptureSession
    private let previewLayer = AVCaptureVideoPreviewLayer()

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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            captureSession.start()
        }
        // Don't tear down on window detach — the SwiftUI host view may be
        // briefly removed when the workspace re-renders. The registry owns
        // teardown when the pane itself is removed.
    }
}
