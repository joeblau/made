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
    /// Speedometer geometry in unflipped (y-up) coordinates: the 90° gap sits
    /// at the bottom, and progress runs clockwise from the bottom-left end
    /// (225°) over the top to the bottom-right end (-45°). Callers must draw
    /// into an unflipped view; `WorkspaceGaugeView` pins `isFlipped` to false
    /// because NSButton is flipped by default, which would put the gap on top.
    static let startAngle: CGFloat = 225
    static let sweep: CGFloat = 270
    func path(in rect: CGRect) -> NSBezierPath {
        let path = NSBezierPath()
        guard fraction > 0 else { return path }
        let radius = max(0, min(rect.width, rect.height) / 2 - insetAmount)
        path.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: radius,
                       startAngle: Self.startAngle, endAngle: Self.startAngle - CGFloat(min(1, fraction)) * Self.sweep,
                       clockwise: true)
        return path
    }
}

@MainActor
final class WorkspaceGaugeView: NSButton {
    var running = 0 { didSet { needsDisplay = true } }
    var started = 0 { didSet { needsDisplay = true } }
    var onJump: (() -> Void)?
    /// True on a selected (accent-filled) sidebar row, where label colours
    /// switch to white so the fraction stays legible.
    var isEmphasized = false { didSet { if oldValue != isEmphasized { needsDisplay = true } } }
    /// The arc geometry is authored y-up; NSButton reports flipped, which
    /// would turn the gauge upside down (gap at the top).
    override var isFlipped: Bool { false }
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
        (isEmphasized ? NSColor.white.withAlphaComponent(0.3) : NSColor.quaternaryLabelColor).setStroke()
        track.stroke()
        let fraction = Double(running) / Double(started)
        let path = WorkspaceGaugeArc(fraction: fraction).inset(by: 2).path(in: bounds)
        path.lineWidth = 3
        path.lineCapStyle = .round
        let progressColor: NSColor = running == started ? .systemGreen : (isEmphasized ? .white : .controlAccentColor)
        progressColor.setStroke()
        path.stroke()
        let text = "\(running)/\(started)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium), .foregroundColor: isEmphasized ? NSColor.white : NSColor.labelColor]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }
}

/// The open-task count, drawn as a filled circle (one or two digits) or a
/// capsule ("99+"). The `.badge` bezel draws no visible fill in a sidebar
/// row, so the background is painted here.
@MainActor
final class WorkspaceOpenTaskBadgeView: NSButton {
    static let diameter: CGFloat = 18
    static let horizontalPadding: CGFloat = 5
    static let maximumDisplayedCount = 99

    var count = 0 { didSet { update() } }
    var onOpen: (() -> Void)?
    /// True on a selected (accent-filled) sidebar row: translucent white fill
    /// with white digits instead of the subtle label-tinted fill.
    var isEmphasized = false { didSet { if oldValue != isEmphasized { needsDisplay = true } } }

    static func displayText(for count: Int) -> String {
        let value = max(0, count)
        return value > maximumDisplayedCount ? "\(maximumDisplayedCount)+" : "\(value)"
    }

    private static var font: NSFont { NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        imagePosition = .noImage
        target = self
        action = #selector(openTasks)
        setAccessibilityIdentifier("workspace.open-tasks")
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        update()
    }

    required init?(coder: NSCoder) { nil }

    @objc private func openTasks() { onOpen?() }

    /// A circle while the text fits inside it, a capsule once it is wider.
    override var intrinsicContentSize: NSSize {
        let textWidth = ceil((title as NSString).size(withAttributes: [.font: Self.font]).width)
        let width = title.count <= 2 ? Self.diameter : max(Self.diameter, textWidth + Self.horizontalPadding * 2)
        return NSSize(width: width, height: Self.diameter)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isEnabled else { return }  // `update()` disables the badge at zero
        let side = min(bounds.height, Self.diameter)
        let width = min(bounds.width, intrinsicContentSize.width)
        let rect = NSRect(x: bounds.midX - width / 2, y: bounds.midY - side / 2, width: width, height: side)
        // Pressed state deepens the fill; alpha is computed up front because
        // reading `alphaComponent` from a dynamic system colour can throw.
        let alpha: CGFloat = (isEmphasized ? 0.25 : 0.1) * (isHighlighted ? 1.8 : 1)
        let fill = (isEmphasized ? NSColor.white : NSColor.labelColor).withAlphaComponent(alpha)
        let text: NSColor = isEmphasized ? .white : .secondaryLabelColor
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: side / 2, yRadius: side / 2).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: text]
        let string = title as NSString
        let size = string.size(withAttributes: attributes)
        string.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
    }

    private func update() {
        let value = max(0, count)
        title = Self.displayText(for: value)
        isHidden = value == 0
        isEnabled = value > 0
        let description = "\(value) open \(value == 1 ? "task" : "tasks")"
        toolTip = description
        setAccessibilityLabel(description)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
}
