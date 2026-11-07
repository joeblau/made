import AppKit

/// A quiet checkerboard distinguishes the preview stage from true black pixels
/// in a device screen. Only damaged tiles are painted during live resize.
@MainActor
final class PreviewCanvasBackground: NSView {
    private static let tileSize: CGFloat = 12
    private static let base = NSColor(srgbRed: 0.045, green: 0.045, blue: 0.050, alpha: 1)
    private static let alternate = NSColor(srgbRed: 0.064, green: 0.064, blue: 0.072, alpha: 1)

    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        Self.base.setFill()
        let renderRect = bounds.intersection(dirtyRect)
        guard !renderRect.isEmpty else { return }
        renderRect.fill()
        let firstColumn = Int(floor(renderRect.minX / Self.tileSize))
        let lastColumn = Int(ceil(renderRect.maxX / Self.tileSize))
        let firstRow = Int(floor(renderRect.minY / Self.tileSize))
        let lastRow = Int(ceil(renderRect.maxY / Self.tileSize))
        let tiles = NSBezierPath()
        for row in firstRow..<lastRow {
            for column in firstColumn..<lastColumn where (row + column).isMultiple(of: 2) {
                tiles.appendRect(NSRect(
                    x: CGFloat(column) * Self.tileSize,
                    y: CGFloat(row) * Self.tileSize,
                    width: Self.tileSize,
                    height: Self.tileSize
                ))
            }
        }
        Self.alternate.setFill()
        tiles.fill()
    }
}
