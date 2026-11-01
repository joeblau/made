import AppKit
import AVFoundation
import SwiftUI

@MainActor @Observable
final class WirelessDeviceSession {
    private(set) var isEnabled = false
    private(set) var status: AirPlayReceiverStatus = .stopped
    private(set) var renderer: AirPlayVideoRenderer?
    let receiverName: String
    @ObservationIgnored private var worker: AirPlayReceiverWorker?
    @ObservationIgnored private var polling: Task<Void, Never>?

    init(paneID: UUID) {
        // Unique Bonjour name for simultaneous Device panes, under 63 UTF-8 bytes.
        receiverName = "Cockpit \(paneID.uuidString.prefix(4))"
    }

    func start() {
        stop()
        isEnabled = true
        guard let executable = Bundle.main.url(forAuxiliaryExecutable: "CockpitAirPlayReceiver"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            status = .failed("This build is missing the wireless receiver. Rebuild or update Cockpit.")
            return
        }
        let renderer = AirPlayVideoRenderer()
        self.renderer = renderer
        let worker = AirPlayReceiverWorker()
        self.worker = worker
        status = .starting
        worker.start(executable: executable, name: receiverName, renderer: renderer)
        polling = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let snapshot = worker.snapshot
                if self.status != snapshot { self.status = snapshot }
                if worker.isFinished { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func stop() {
        polling?.cancel()
        polling = nil
        worker?.cancel()
        worker = nil
        status = .stopped
        renderer = nil
    }

    func useUSB() {
        stop()
        isEnabled = false
    }
}

struct WirelessDeviceView: View {
    let session: WirelessDeviceSession
    let useUSB: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // The header floats on the dark stage, so it renders in the dark
            // scheme in both appearances (COL-2). Its two secondary actions
            // are neighboring capsule glass buttons (BTN-1).
            HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                // A narrow pane drops to a shorter title, then to the glyph,
                // instead of wrapping the headline onto two lines.
                ViewThatFits(in: .horizontal) {
                    Label("Wireless Device", systemImage: "airplay.video")
                    Label("Wireless", systemImage: "airplay.video")
                    Image(systemName: "airplay.video")
                        .accessibilityLabel("Wireless Device")
                }
                .font(.headline)
                .lineLimit(1)
                Spacer(minLength: LiquidGlassMetrics.Spacing.xSmall)
                CompatGlassContainer(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                    HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                        Button("Use USB", action: useUSB)
                            .compatGlassButtonStyle()
                        if session.status != .stopped {
                            Button("Stop") { session.stop() }
                                .compatGlassButtonStyle()
                        }
                    }
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                }
                .fixedSize()
            }
            .padding(LiquidGlassMetrics.Spacing.small)
            .environment(\.colorScheme, .dark)
            ZStack {
                Color.black
                if let renderer = session.renderer {
                    WirelessDeviceVideoView(renderer: renderer)
                        .opacity(session.status == .streaming ? 1 : 0)
                }
                if session.status != .streaming { instructions }
            }
        }
    }

    private func startButton(_ title: String) -> some View {
        Button(title) { session.start() }
            .compatGlassProminentButtonStyle()
            .buttonBorderShape(.capsule)
            .fixedSize()
            .accessibilityLabel("Start Wireless Sharing")
    }

    private var instructions: some View {
        VStack(spacing: LiquidGlassMetrics.Spacing.medium) {
            Image(systemName: "airplay.video")
                .font(.largeTitle)
                // Pulses while the receiver is listening for a device (MOT-5).
                .symbolEffect(.pulse, isActive: isListening)
            switch session.status {
            case .starting:
                ProgressView()
                Text("Starting wireless sharing…")
            case .waiting, .pairing:
                Text("Mirror Your iPhone or iPad").font(.headline)
                Text("On the same Wi-Fi network, open Control Center → Screen Mirroring and choose:")
                Text(session.receiverName).font(.title2.bold()).textSelection(.enabled)
                if case .pairing(let code) = session.status {
                    Text("Enter this code on your device")
                    Text(code)
                        .font(.largeTitle.monospaced().weight(.medium))
                        .textSelection(.enabled)
                }
                Text("Video only. Keep this pane open while sharing.")
                    .font(.caption).foregroundStyle(.secondary)
            case .failed(let message):
                Text("Wireless Sharing Stopped").font(.headline)
                Text(message)
                Button("Try Again") { session.start() }
                    .compatGlassProminentButtonStyle()
                    .buttonBorderShape(.capsule)
            case .stopped:
                Text("Wireless Sharing Is Off").font(.headline)
                // A narrow pane takes the short title instead of truncating
                // the button to "Start Wireless Sh…" (LAY-6).
                ViewThatFits(in: .horizontal) {
                    startButton("Start Wireless Sharing")
                    startButton("Start Sharing")
                }
            case .streaming:
                EmptyView()
            }
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .uiZoomedDynamicType()
        .padding(LiquidGlassMetrics.Spacing.xxLarge)
        .frame(maxWidth: 480)
    }

    private var isListening: Bool {
        switch session.status {
        case .starting, .waiting: true
        default: false
        }
    }
}

private struct WirelessDeviceVideoView: NSViewRepresentable {
    let renderer: AirPlayVideoRenderer

    func makeNSView(context: Context) -> WirelessDeviceHostView {
        let view = WirelessDeviceHostView()
        view.wantsLayer = true
        view.layer = renderer.layer
        return view
    }

    func updateNSView(_ view: WirelessDeviceHostView, context: Context) {
        if view.layer !== renderer.layer { view.layer = renderer.layer }
    }
}

/// The AirPlay mirror is view-only, so a plain drag drags the screen image.
final class WirelessDeviceHostView: NSView {
    private var screenDrag = DeviceScreenDragGesture()

    override func mouseDown(with event: NSEvent) {
        _ = screenDrag.press(at: event.locationInWindow, modifiers: event.modifierFlags, requiresCommand: false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard screenDrag.drag(to: event.locationInWindow),
              let displayLayer = layer as? AVSampleBufferDisplayLayer else { return }
        DeviceScreenDrag.begin(
            from: self,
            event: event,
            frame: DeviceScreenDrag.displayedFrame(of: displayLayer),
            name: "iphone"
        )
    }

    override func mouseUp(with event: NSEvent) {
        screenDrag.release()
    }
}
