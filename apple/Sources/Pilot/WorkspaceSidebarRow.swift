import AppKit

/// A native path used by sidebar status rings. A zero fraction deliberately
/// produces no foreground path, so a rounded stroke has no detached dot.
struct WorkspaceGaugeArc {
    var fraction: Double
    private var insetAmount: CGFloat = 0
    init(fraction: Double) { self.fraction = fraction }
    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }
    func inset(by amount: CGFloat) -> Self {
        var result = self
        result.insetAmount += amount
        return result
    }
    func path(in rect: CGRect) -> NSBezierPath {
        let path = NSBezierPath()
        guard fraction > 0 else { return path }
        let radius = max(0, min(rect.width, rect.height) / 2 - insetAmount)
        path.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: radius,
                       startAngle: 225, endAngle: 225 - CGFloat(min(1, fraction)) * 270,
                       clockwise: true)
        return path
    }
}

@MainActor
final class WorkspaceGaugeView: NSButton {
    var running = 0 { didSet { needsDisplay = true } }
    var started = 0 { didSet { needsDisplay = true } }
    var onJump: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        title = ""
        target = self
        action = #selector(jump)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func jump() { if running > 0 { onJump?() } }
    override func draw(_ dirtyRect: NSRect) {
        guard started > 0 else { return }
        let track = WorkspaceGaugeArc(fraction: 1).inset(by: 2).path(in: bounds)
        track.lineWidth = 3
        track.lineCapStyle = .round
        NSColor.quaternaryLabelColor.setStroke()
        track.stroke()
        let fraction = Double(running) / Double(started)
        let path = WorkspaceGaugeArc(fraction: fraction).inset(by: 2).path(in: bounds)
        path.lineWidth = 3
        path.lineCapStyle = .round
        (running == started ? NSColor.systemGreen : NSColor.controlAccentColor).setStroke()
        path.stroke()
        let text = "\(running)/\(started)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium), .foregroundColor: NSColor.labelColor]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }
}
