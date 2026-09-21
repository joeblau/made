import AppKit
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
        receiverName = "made \(paneID.uuidString.prefix(4))"
    }

    func start() {
        stop()
        isEnabled = true
        guard let executable = Bundle.main.url(forAuxiliaryExecutable: "CockpitAirPlayReceiver"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            status = .failed("This build is missing the wireless receiver. Rebuild or update made.")
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
            HStack {
                Label("Wireless Device", systemImage: "airplay.video")
                    .font(.headline)
                Spacer()
                Button("Use USB", action: useUSB)
                    .buttonStyle(.borderless)
                if session.status != .stopped {
                    Button("Stop") { session.stop() }
                        .buttonStyle(.borderless)
                }
            }
            .padding(12)
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

    private var instructions: some View {
        VStack(spacing: 14) {
            Image(systemName: "airplay.video")
                .font(.system(size: 34))
            switch session.status {
            case .starting:
                ProgressView()
                Text("Starting wireless sharing…")
            case .waiting, .pairing:
                Text("Mirror your iPhone or iPad").font(.headline)
                Text("On the same Wi-Fi network, open Control Center → Screen Mirroring and choose:")
                Text(session.receiverName).font(.title2.bold()).textSelection(.enabled)
                if case .pairing(let code) = session.status {
                    Text("Enter this code on your device")
                    Text(code).font(.system(size: 36, weight: .medium, design: .monospaced))
                        .textSelection(.enabled)
                }
                Text("Video only. Keep this pane open while sharing.")
                    .font(.caption).foregroundStyle(.secondary)
            case .failed(let message):
                Text("Wireless sharing stopped").font(.headline)
                Text(message)
                Button("Try Again") { session.start() }
            case .stopped:
                Text("Wireless sharing is off").font(.headline)
                Button("Start Wireless Sharing") { session.start() }
            case .streaming:
                EmptyView()
            }
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.white)
        .padding(32)
        .frame(maxWidth: 480)
    }
}

private struct WirelessDeviceVideoView: NSViewRepresentable {
    let renderer: AirPlayVideoRenderer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer = renderer.layer
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if view.layer !== renderer.layer { view.layer = renderer.layer }
    }
}
