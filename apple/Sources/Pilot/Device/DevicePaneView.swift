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
                            .compatGlassButtonStyle()
                            .buttonBorderShape(.capsule)
                            .environment(\.colorScheme, .dark)
                            .padding(LiquidGlassMetrics.Spacing.small)
                        }
                }
            }

            if let toast {
                DevicePaneToast(text: toast.text, systemImage: toast.systemImage, tint: toast.tint)
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

// MARK: - Shared pane chrome (iOS device, Simulator, Android)

/// Picker header shared by the iOS device, Simulator, and Android panes: the
/// title on the leading edge and a circular glass Refresh control on the
/// trailing edge (BTN-1 secondary tier, consistent control size).
struct DevicePickerHeader: View {
    let title: String
    let systemImage: String
    let isRefreshing: Bool
    let refreshHelp: String
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Spacer()
            if isRefreshing {
                ProgressView().controlSize(.small)
            }
            Button(action: refresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .compatGlassIconButton(controlSize: .small)
            .disabled(isRefreshing)
            .help(refreshHelp)
        }
        .padding(LiquidGlassMetrics.Spacing.small)
    }
}

/// One tappable picker row: a leading symbol column (HIER-3), title and
/// optional detail, an optional state badge, and a trailing affordance. Use
/// with `.buttonStyle(.liquidGlassPressable)` so the whole row gets hover and
/// press feedback (BTN-5); the horizontal inset keeps that wash off the text.
struct DevicePickerRow: View {
    let systemImage: String
    let title: String
    var detail: String?
    var badge: String?
    let trailingSystemImage: String

    var body: some View {
        HStack(spacing: LiquidGlassMetrics.Spacing.small) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: LiquidGlassMetrics.Spacing.large)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let badge {
                Text(badge)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            }
            Image(systemName: trailingSystemImage)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, LiquidGlassMetrics.Spacing.xSmall)
        .padding(.vertical, LiquidGlassMetrics.Spacing.xxSmall)
    }
}

/// Empty, loading, and failure message shared by the device panes: the
/// platform `ContentUnavailableView` (HIER-6) with a pulsing symbol plus a
/// small spinner while work is in flight (MOT-5) and the next actions grouped
/// as neighboring glass (MOT-6). `onCanvas` sets it on the dark preview
/// canvas with a dark color scheme so secondary text keeps its contrast in
/// both appearances (COL-2, TYPE-3). Text styles follow Pilot's text-size
/// ladder (TYPE-4).
struct DevicePaneMessage<Actions: View>: View {
    private let title: String
    private let systemImage: String
    private let detail: String?
    private let isLoading: Bool
    private let onCanvas: Bool
    private let hasActions: Bool
    private let actions: Actions

    init(
        _ title: String,
        systemImage: String,
        detail: String? = nil,
        isLoading: Bool = false,
        onCanvas: Bool = false,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.systemImage = systemImage
        self.detail = detail
        self.isLoading = isLoading
        self.onCanvas = onCanvas
        self.hasActions = Actions.self != EmptyView.self
        self.actions = actions()
    }

    var body: some View {
        let message = ContentUnavailableView {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
                    .symbolEffect(.pulse, isActive: isLoading)
            }
        } description: {
            if let detail, !detail.isEmpty {
                Text(detail)
            }
        } actions: {
            if isLoading {
                ProgressView().controlSize(.small)
            }
            if hasActions {
                // Side by side when the pane is wide enough, stacked when
                // it is narrow, so a label is never truncated ("Open Cam…").
                CompatGlassContainer(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                            actions
                        }
                        .fixedSize()
                        VStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                            actions
                        }
                    }
                }
            }
        }
        .uiZoomedDynamicType()
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        if onCanvas {
            message
                .environment(\.colorScheme, .dark)
                .background(PreviewCanvasBackground())
        } else {
            message
        }
    }
}

extension DevicePaneMessage where Actions == EmptyView {
    init(
        _ title: String,
        systemImage: String,
        detail: String? = nil,
        isLoading: Bool = false,
        onCanvas: Bool = false
    ) {
        self.init(
            title,
            systemImage: systemImage,
            detail: detail,
            isLoading: isLoading,
            onCanvas: onCanvas
        ) {
            EmptyView()
        }
    }
}

/// Transient confirmation toast for the device panes. Floating glass over the
/// mirrored screen (the control layer, never content); non-interactive.
struct DevicePaneToast: View {
    let text: String
    let systemImage: String
    var tint: Color = .primary

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(tint)
            .padding(.horizontal, LiquidGlassMetrics.Spacing.medium)
            .padding(.vertical, LiquidGlassMetrics.Spacing.small)
            .compatFloatingGlassCapsule()
    }
}

// MARK: - Picker

private struct IOSDevicePickerView: View {
    let session: DeviceCaptureSession
    let isPolling: Bool
    let startWireless: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DevicePickerHeader(
                title: "iOS Device",
                systemImage: "apps.iphone",
                isRefreshing: session.isRefreshing,
                refreshHelp: "Re-scan connected iPhones and iPads",
                refresh: { session.refreshDevices() }
            )

            Button(action: startWireless) {
                Label("Share Wirelessly…", systemImage: "airplay.video")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, LiquidGlassMetrics.Spacing.xxSmall)
            }
            .compatGlassButtonStyle()
            .buttonBorderShape(.capsule)
            .padding(.horizontal, LiquidGlassMetrics.Spacing.small)
            .padding(.bottom, LiquidGlassMetrics.Spacing.xSmall)

            if let preferredName = session.preferredDeviceName {
                Label("Waiting for \(preferredName)", systemImage: "cable.connector")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, LiquidGlassMetrics.Spacing.small)
                    .padding(.vertical, LiquidGlassMetrics.Spacing.xSmall)
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
                        .buttonStyle(.liquidGlassPressable)
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
        DevicePickerRow(
            systemImage: "apps.iphone",
            title: device.name,
            detail: device.detail,
            trailingSystemImage: "chevron.right"
        )
    }

    @ViewBuilder
    private var emptyState: some View {
        if session.isRefreshing {
            DevicePaneMessage("Looking for devices…", systemImage: "apps.iphone", isLoading: true)
        } else if let error = session.lastError {
            DevicePaneMessage("Couldn't List Devices", systemImage: "exclamationmark.triangle", detail: error)
        } else {
            DevicePaneMessage(
                "No USB Devices Found",
                systemImage: "apps.iphone",
                detail: "Connect an iPhone or iPad over USB, trust this Mac, and keep its screen awake."
            )
        }
    }
}

private struct DeviceToast {
    let text: String
    let systemImage: String
    var tint: Color = .primary
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
                    detail: session.deviceName,
                    isLoading: true
                )
            case .streaming:
                Color.clear
            case .failed(let message):
                if session.isCameraPermissionDenied {
                    permissionDeniedBlock(message: message)
                } else {
                    statusBlock(
                        icon: "exclamationmark.triangle",
                        title: "Capture Failed",
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
        DevicePaneMessage(
            "Camera Access Required",
            systemImage: "video.slash",
            detail: message,
            onCanvas: true
        ) {
            Button("Open Camera Settings") {
                session.openCameraPrivacySettings()
            }
            .compatGlassProminentButtonStyle()
            Button("Check Again") {
                session.retry()
            }
            .compatGlassButtonStyle()
        }
    }

    @ViewBuilder
    private func statusBlock(
        icon: String,
        title: String,
        detail: String?,
        isLoading: Bool = false,
        retry: (() -> Void)? = nil,
        chooseAnother: (() -> Void)? = nil
    ) -> some View {
        if retry == nil, chooseAnother == nil {
            DevicePaneMessage(title, systemImage: icon, detail: detail, isLoading: isLoading, onCanvas: true)
        } else {
            DevicePaneMessage(
                title,
                systemImage: icon,
                detail: detail,
                isLoading: isLoading,
                onCanvas: true
            ) {
                if let retry {
                    Button("Retry", action: retry)
                        .compatGlassProminentButtonStyle()
                }
                if let chooseAnother {
                    Button("Back to Devices", action: chooseAnother)
                        .compatGlassButtonStyle()
                }
            }
        }
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            captureSession.start()
        }
        // Don't tear down on window detach — the SwiftUI host view may be
        // briefly removed when the workspace re-renders. The registry owns
        // teardown when the pane itself is removed.
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
