import AppKit

/// Bounded native trend rendering. Values are binned when the model changes,
/// so resizing or hovering neighboring controls never scans the full history.
@MainActor
final class AgenticUseSparkline: NSView {
    private var points: [Double]
    private let transition = AgenticUseDataTransition()
    private var tint: NSColor
    private var anchorsAtZero: Bool
    var lineWidth: CGFloat
    init(values: [Double], tint: NSColor, anchorsAtZero: Bool = true, lineWidth: CGFloat = 1.5) {
        points = Self.normalized(values, anchorsAtZero: anchorsAtZero)
        self.tint = tint
        self.anchorsAtZero = anchorsAtZero
        self.lineWidth = lineWidth
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    func update(values: [Double], tint: NSColor, anchorsAtZero: Bool = true) {
        let from = points
        let to = Self.normalized(values, anchorsAtZero: anchorsAtZero)
        transition.start(in: self, animated: from != to) { [weak self] progress in
            self?.points = AgenticUseDataTransition.series(from, to, progress)
            self?.needsDisplay = true
        }
        self.tint = tint
        self.anchorsAtZero = anchorsAtZero
        needsDisplay = true
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard points.count > 1 else { return }
        let rect = bounds.insetBy(dx: lineWidth, dy: lineWidth)
        let path = NSBezierPath()
        for (index, value) in points.enumerated() {
            let point = NSPoint(x: rect.minX + CGFloat(index) / CGFloat(points.count - 1) * rect.width,
                               y: rect.minY + CGFloat(value) * rect.height)
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        let fill = path.copy() as! NSBezierPath
        fill.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        fill.line(to: NSPoint(x: rect.minX, y: rect.minY))
        fill.close()
        NSGradient(starting: tint.withAlphaComponent(0.02), ending: tint.withAlphaComponent(0.28))?.draw(in: fill, angle: 90)
        tint.setStroke()
        path.lineWidth = lineWidth
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        path.stroke()
    }
    nonisolated private static func normalized(_ values: [Double], anchorsAtZero: Bool) -> [Double] {
        let points = binned(values, limit: 45)
        let minimum = points.min() ?? 0
        let maximum = points.max() ?? 0
        let padding = max((maximum - minimum) * 0.15, abs(maximum) * 0.002, 0.000001)
        let low = anchorsAtZero ? 0 : minimum - padding
        let high = anchorsAtZero ? max(maximum * 1.08, 0.000001) : maximum + padding
        return points.map { ($0 - low) / (high - low) }
    }
    nonisolated static func binned(_ values: [Double], limit: Int) -> [Double] {
        guard limit > 0, values.count > limit else { return values }
        let size = Double(values.count) / Double(limit)
        return (0..<limit).map { index in
            let start = Int((Double(index) * size).rounded(.down))
            let end = max(start + 1, Int((Double(index + 1) * size).rounded(.down)))
            let slice = values[start..<min(end, values.count)]
            return slice.reduce(0, +) / Double(slice.count)
        }
    }
}
