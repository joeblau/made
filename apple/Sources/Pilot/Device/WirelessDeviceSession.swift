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
        // The pane's width is read from a GeometryReader, which always takes
        // the width it is offered. The stage content can't report it: the
        // full layout's fixed-size words and buttons overflow a narrow pane,
        // so the content's own width never dropped below the word floor and
        // a ~73pt pane kept the full layout, clipped ("haring Is Of").
        GeometryReader { proxy in
            let layout = instructionsLayout(paneWidth: proxy.size.width)
            VStack(spacing: 0) {
                header(paneWidth: proxy.size.width)
                ZStack {
                    Color.black
                    if let renderer = session.renderer {
                        WirelessDeviceVideoView(renderer: renderer)
                            .opacity(session.status == .streaming ? 1 : 0)
                    }
                    if session.status != .streaming {
                        Group {
                            switch layout {
                            case .compact:
                                compactInstructions
                            case .full(let margin):
                                instructions(probing: false, margin: margin)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background {
                            WordFloorProbe { instructionsProbeWidth = $0 } content: {
                                instructions(probing: true, margin: LiquidGlassMetrics.Spacing.small)
                            }
                            WordFloorProbe { receiverNameWidth = $0 } content: {
                                // Same zoom as inside `instructions`, applied once.
                                receiverName.uiZoomedDynamicType()
                            }
                        }
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    /// Ideal width of the instructions laid out one word per line at the
    /// narrow (`small`) margin: the widest word, code, or button plus margins.
    @State private var instructionsProbeWidth: CGFloat = 0
    /// Unscaled width of the receiver name, which may shrink to half size.
    @State private var receiverNameWidth: CGFloat = 0

    private func instructionsLayout(paneWidth: CGFloat) -> WirelessInstructionsLayout {
        WirelessInstructionsLayout.resolve(
            paneWidth: paneWidth,
            probeWidth: instructionsProbeWidth,
            receiverNameWidth: receiverNameWidth * Self.receiverNameMinimumScale
        )
    }

    /// The header floats on the dark stage, so it renders in the dark scheme
    /// in both appearances (COL-2). Its two secondary actions are neighboring
    /// glass buttons (BTN-1). A narrow pane steps down a whole row at a time:
    /// shorter title, then the glyph alone, then icon-only buttons, then the
    /// buttons stacked, so nothing clips at the pane edge. Offered exactly the
    /// pane width, so `ViewThatFits` compares against the real edge.
    private func header(paneWidth: CGFloat) -> some View {
        ViewThatFits(in: .horizontal) {
            header(title: "Wireless Device", iconOnlyButtons: false)
            header(title: "Wireless", iconOnlyButtons: false)
            header(title: nil, iconOnlyButtons: false)
            header(title: nil, iconOnlyButtons: true)
            header(title: nil, iconOnlyButtons: true, showsGlyph: false)
            stackedHeaderButtons
        }
        .padding(LiquidGlassMetrics.Spacing.small)
        .frame(width: paneWidth)
        .environment(\.colorScheme, .dark)
    }

    private static let receiverNameMinimumScale: CGFloat = 0.5

    /// The name the user picks in Screen Mirroring. It shrinks rather than
    /// breaking inside a word ("Cockpi / t F78D"); the word floor keeps the
    /// pane wide enough for it at half size.
    private var receiverName: some View {
        Text(session.receiverName).font(.title2.bold())
            .lineLimit(1).minimumScaleFactor(Self.receiverNameMinimumScale)
    }

    /// One full header row. `title` nil shows only the glyph (still named for
    /// VoiceOver); `iconOnlyButtons` turns the actions into circular icon
    /// buttons that keep their names in `.help` and the accessibility label.
    /// `showsGlyph` false is the last resort for a sliver-wide pane: just the
    /// two icon buttons.
    private func header(title: String?, iconOnlyButtons: Bool, showsGlyph: Bool = true) -> some View {
        HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
            if showsGlyph {
                Group {
                    if let title {
                        Label(title, systemImage: "airplay.video")
                    } else {
                        Image(systemName: "airplay.video")
                            .accessibilityLabel("Wireless Device")
                    }
                }
                .font(.headline)
                .lineLimit(1)
                .fixedSize()
            }
            Spacer(minLength: showsGlyph ? LiquidGlassMetrics.Spacing.xSmall : 0)
            CompatGlassContainer(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                    headerButton("Use USB", systemImage: "cable.connector", iconOnly: iconOnlyButtons, action: useUSB)
                    if session.status != .stopped {
                        headerButton("Stop", systemImage: "stop.fill", iconOnly: iconOnlyButtons) {
                            session.stop()
                        }
                    }
                }
                .controlSize(.small)
            }
            .fixedSize()
        }
        // No `.fixedSize()` on the row: the Spacer stretches it across the
        // pane, while `ViewThatFits` still compares each row's ideal width.
    }

    /// Last resort for a pane narrower than the two icon buttons side by
    /// side: one above the other, centered.
    private var stackedHeaderButtons: some View {
        CompatGlassContainer(spacing: LiquidGlassMetrics.Spacing.xSmall) {
            VStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                headerButton("Use USB", systemImage: "cable.connector", iconOnly: true, action: useUSB)
                if session.status != .stopped {
                    headerButton("Stop", systemImage: "stop.fill", iconOnly: true) {
                        session.stop()
                    }
                }
            }
            .controlSize(.small)
        }
        .fixedSize()
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func headerButton(
        _ title: String,
        systemImage: String,
        iconOnly: Bool,
        action: @escaping () -> Void
    ) -> some View {
        if iconOnly {
            Button(action: action) {
                // A fixed glyph box so both circles match: `cable.connector`
                // is narrower than `stop.fill`.
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: systemImage)
                        .frame(width: 14, height: 14)
                }
            }
            .compatGlassIconButton(controlSize: .small)
            .help(title)
        } else {
            Button(title, action: action)
                .compatGlassButtonStyle()
        }
    }

    private func startButton(_ title: String) -> some View {
        Button(title) { session.start() }
            .compatGlassProminentButtonStyle()
            .fixedSize()
            .accessibilityLabel("Start Wireless Sharing")
    }

    /// The full instructions. `probing` is the hidden measuring copy: one
    /// word per line, the receiver name left out (measured on its own), and
    /// the short Start button, at the narrow margin.
    private func instructions(probing: Bool, margin: CGFloat) -> some View {
        let words = { (text: String) in Text(WordFloorText.oneWordPerLine(text, probing: probing)) }
        return VStack(spacing: LiquidGlassMetrics.Spacing.medium) {
            Image(systemName: "airplay.video")
                .font(.largeTitle)
                // Pulses while the receiver is listening for a device (MOT-5).
                .symbolEffect(.pulse, isActive: isListening && !probing)
            switch session.status {
            case .starting:
                ProgressView()
                words("Starting wireless sharing…")
            case .waiting, .pairing:
                words("Mirror Your iPhone or iPad").font(.headline)
                // A non-breaking hyphen keeps "Wi‑Fi" on one line.
                words("On the same Wi\u{2011}Fi network, open Control Center → Screen Mirroring and choose:")
                if !probing {
                    receiverName.textSelection(.enabled)
                }
                if case .pairing(let code) = session.status {
                    words("Enter this code on your device")
                    Text(code)
                        .font(.largeTitle.monospaced().weight(.medium))
                        .textSelection(.enabled)
                }
                words("Video only. Keep this pane open while sharing.")
                    .font(.caption).foregroundStyle(.secondary)
            case .failed(let message):
                words("Wireless Sharing Stopped").font(.headline)
                words(message)
                Button("Try Again") { session.start() }
                    .compatGlassProminentButtonStyle()
            case .stopped:
                words("Wireless Sharing Is Off").font(.headline)
                // A narrow pane takes the short title instead of truncating
                // the button to "Start Wireless Sh…" (LAY-6).
                if probing {
                    startButton("Start Sharing")
                } else {
                    ViewThatFits(in: .horizontal) {
                        startButton("Start Wireless Sharing")
                        startButton("Start Sharing")
                    }
                }
            case .streaming:
                EmptyView()
            }
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .uiZoomedDynamicType()
        // A narrow pane trades the stage margin for text width, so the
        // receiver name ("Cockpit F78D") fits whole instead of losing the
        // suffix that tells receivers apart.
        .padding(margin)
        .frame(maxWidth: 480)
    }

    /// A pane too narrow for the instructions' words (a narrow window that
    /// can't give every pane its floor) keeps the glyph, the pairing code the
    /// user has to type, and icon-only actions; the full text moves to the
    /// tooltip and VoiceOver label instead of breaking mid-word.
    private var compactInstructions: some View {
        VStack(spacing: LiquidGlassMetrics.Spacing.small) {
            Image(systemName: "airplay.video")
                .font(.title2)
                .symbolEffect(.pulse, isActive: isListening)
                .accessibilityHidden(true)
            switch session.status {
            case .starting:
                ProgressView().controlSize(.small)
            case .pairing(let code):
                Text(code)
                    .font(.title2.monospaced().weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .textSelection(.enabled)
            case .failed:
                compactActionButton("Try Again", systemImage: "arrow.clockwise")
            case .stopped:
                compactActionButton("Start Wireless Sharing", systemImage: "play.fill")
            case .waiting, .streaming:
                EmptyView()
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .uiZoomedDynamicType()
        .padding(LiquidGlassMetrics.Spacing.xSmall)
        .help(compactInstructionsText)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(compactInstructionsText)
    }

    private func compactActionButton(_ title: String, systemImage: String) -> some View {
        Button { session.start() } label: {
            Label(title, systemImage: systemImage)
        }
        // The icon helper, not the prominent style plus an outer
        // `.buttonBorderShape(.circle)`: that style pins a capsule innermost,
        // which won and drew this glyph-only action as a pill.
        .compatGlassIconButton(prominent: true)
        .help(title)
    }

    private var compactInstructionsText: String {
        switch session.status {
        case .starting:
            "Starting wireless sharing…"
        case .waiting:
            "Mirror Your iPhone or iPad. On the same Wi-Fi network, open Control Center → Screen Mirroring and choose \(session.receiverName)."
        case .pairing(let code):
            "Choose \(session.receiverName) in Screen Mirroring and enter code \(code) on your device."
        case .failed(let message):
            "Wireless Sharing Stopped. \(message)"
        case .stopped:
            "Wireless Sharing Is Off"
        case .streaming:
            ""
        }
    }

    private var isListening: Bool {
        switch session.status {
        case .starting, .waiting: true
        default: false
        }
    }
}

/// Which instructions layout the wireless stage shows, decided from the
/// pane's offered width and the measured word floor. Pure, so the switch is
/// unit-tested without rendering.
enum WirelessInstructionsLayout: Equatable {
    /// The full text, inset by `margin` on every side.
    case full(margin: CGFloat)
    /// Glyph, pairing code, and icon-only action; the text moves to the
    /// tooltip and VoiceOver label.
    case compact

    static let narrowMargin = LiquidGlassMetrics.Spacing.small
    static let wideMargin = LiquidGlassMetrics.Spacing.xxLarge
    /// The wide margin also waits for a comfortable pane, not just a fit.
    static let wideMarginMinimumPaneWidth: CGFloat = 240

    /// - Parameters:
    ///   - paneWidth: the width offered to the stage, never the content's
    ///     own width (a clipped full layout reports its overflow width).
    ///   - probeWidth: the instructions' one-word-per-line ideal width at the
    ///     narrow margin, or 0 before the first measurement.
    ///   - receiverNameWidth: the receiver name at its minimum scale.
    static func resolve(paneWidth: CGFloat, probeWidth: CGFloat, receiverNameWidth: CGFloat) -> Self {
        let floor = wordFloor(probeWidth: probeWidth, receiverNameWidth: receiverNameWidth)
        guard paneWidth.isFinite, paneWidth >= floor else { return .compact }
        let wideMarginExtra = 2 * (wideMargin - narrowMargin)
        return paneWidth >= max(wideMarginMinimumPaneWidth, floor + wideMarginExtra)
            ? .full(margin: wideMargin)
            : .full(margin: narrowMargin)
    }

    /// The narrowest pane that shows the full instructions without breaking
    /// inside a word or the receiver name at the current UI zoom and Dynamic
    /// Type (TYPE-2). Below it the compact layout takes over.
    static func wordFloor(probeWidth: CGFloat, receiverNameWidth: CGFloat) -> CGFloat {
        max(probeWidth, receiverNameWidth + 2 * narrowMargin)
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
