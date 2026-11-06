import AppKit
import AVFoundation
import Observation

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

/// Native receiver instructions and video hosting. Recreated only when the
/// receiver state changes; streaming frames never flow through UI observation.
@MainActor
final class WirelessDeviceView: NSView {
    init(session: WirelessDeviceSession, useUSB: @escaping () -> Void) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        appearance = NSAppearance(named: .darkAqua)
        let header = NSStackView()
        header.spacing = 8
        let title = CockpitUI.label("Wireless Device", size: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(title)
        header.addArrangedSubview(CaptureActionButton(CapturePaneAction(title: "Use USB", symbol: "cable.connector", perform: useUSB), iconOnly: true))
        if session.status != .stopped {
            header.addArrangedSubview(CaptureActionButton(CapturePaneAction(title: "Stop Sharing", symbol: "stop.fill", perform: { [weak session] in session?.stop() }), iconOnly: true))
        }
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        let content: NSView
        if session.status == .streaming, let renderer = session.renderer {
            let host = WirelessDeviceHostView()
            host.wantsLayer = true
            renderer.layer.removeFromSuperlayer()
            host.layer = renderer.layer
            content = host
        } else {
            content = WirelessInstructionsView(session: session)
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
final class WirelessInstructionsView: NSView {
    private let content: NSStackView
    private var fullLabels: [NSView] = []
    private let receiverName: NSTextField
    private var probeWidth: CGFloat = 0

    init(session: WirelessDeviceSession) {
        receiverName = CockpitUI.label(session.receiverName, size: 20, weight: .bold)
        receiverName.isSelectable = true
        receiverName.alignment = .center
        receiverName.lineBreakMode = .byTruncatingTail
        let icon = NSImageView(image: NSImage(systemSymbolName: "airplay.video", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 30, weight: .regular)
        content = NSStackView(views: [icon])
        content.orientation = .vertical
        content.spacing = 12
        content.alignment = .centerX
        super.init(frame: .zero)
        switch session.status {
        case .starting:
            addLabel("Starting wireless sharing…", headline: true)
            let progress = NSProgressIndicator()
            progress.style = .spinning
            progress.startAnimation(nil)
            content.addArrangedSubview(progress)
        case .waiting, .pairing:
            addLabel("Mirror Your iPhone or iPad", headline: true)
            addLabel("On the same Wi-Fi network, open Control Center → Screen Mirroring and choose:")
            content.addArrangedSubview(receiverName)
            fullLabels.append(receiverName)
            if case .pairing(let code) = session.status {
                addLabel("Enter this code on your device")
                let codeLabel = CockpitUI.label(code, size: 25, weight: .medium)
                codeLabel.usesMonospacedFont = true
                codeLabel.isSelectable = true
                codeLabel.setAccessibilityLabel("Pairing code \(code)")
                content.addArrangedSubview(codeLabel)
            }
            addLabel("Video only. Keep this pane open while sharing.")
        case .failed(let message):
            addLabel("Wireless Sharing Stopped", headline: true)
            addLabel(message)
            content.addArrangedSubview(CaptureActionButton(CapturePaneAction(title: "Try Again", symbol: "arrow.clockwise", perform: { [weak session] in session?.start() })))
        case .stopped:
            addLabel("Wireless Sharing Is Off", headline: true)
            content.addArrangedSubview(CaptureActionButton(CapturePaneAction(title: "Start Sharing", symbol: "play.fill", perform: { [weak session] in session?.start() })))
        case .streaming: break
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
        ])
        let detail = fullLabels.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: ". ")
        toolTip = detail
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { nil }

    private func addLabel(_ text: String, headline: Bool = false) {
        let label = CockpitUI.label(text, size: headline ? 15 : 12, weight: headline ? .semibold : .regular)
        label.alignment = .center
        content.addArrangedSubview(label)
        label.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor).isActive = true
        fullLabels.append(label)
        let width = text.split(whereSeparator: { $0.isWhitespace }).map {
            (String($0) as NSString).size(withAttributes: [.font: label.font!]).width
        }.max() ?? 0
        probeWidth = max(probeWidth, width + 16)
    }

    override func layout() {
        super.layout()
        let nameWidth = (receiverName.stringValue as NSString).size(withAttributes: [.font: receiverName.font!]).width / 2
        let compact = WirelessInstructionsLayout.resolve(paneWidth: bounds.width, probeWidth: probeWidth, receiverNameWidth: nameWidth) == .compact
        fullLabels.forEach { $0.isHidden = compact }
        setAccessibilityElement(compact)
        setAccessibilityLabel(compact ? toolTip : nil)
    }
}

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
