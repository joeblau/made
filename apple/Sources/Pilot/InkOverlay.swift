import AppKit
import SwiftUI

struct InkStroke {
    var color: NSColor
    var width: CGFloat
    var points: [CGPoint]
}

@MainActor
@Observable
final class InkModel {
    var strokes: [InkStroke] = []
    var color: NSColor = .systemRed
    var width: CGFloat = 3
    var isEraser = false

    func undo() { if !strokes.isEmpty { strokes.removeLast() } }
    func clear() { strokes.removeAll() }
}

struct RemoteInkStroke {
    var color: NSColor
    var width: CGFloat
    var points: [CGPoint]
}

@MainActor
@Observable
final class RemoteInkModel {
    private(set) var strokes: [RemoteInkStroke] = []
    private(set) var changeID = 0

    /// Called when Pilot edits the remote ink (undo/clear) so the change can be
    /// forwarded to the iPad, which owns the authoritative PencilKit drawing and
    /// echoes the corrected drawing back via `.replaceDrawing`.
    var onLocalEdit: ((AnnotationMessage) -> Void)?

    var hasInk: Bool {
        !strokes.isEmpty
    }

    func handle(_ message: AnnotationMessage) {
        switch message {
        case .replaceDrawing(let drawing):
            strokes = drawing.strokes.map(Self.makeStroke)
        case .addStroke(let stroke):
            // Each incoming line is its own undo-stack entry.
            strokes.append(Self.makeStroke(from: stroke))
        case .clear:
            strokes.removeAll()
        case .undo:
            if !strokes.isEmpty { strokes.removeLast() }
        }
        changeID += 1
    }

    /// Undo the last remote stroke. Optimistically drops it locally for instant
    /// feedback and asks the iPad to undo too; the iPad's echoed drawing
    /// reconciles any mismatch.
    func undo() {
        guard !strokes.isEmpty else { return }
        strokes.removeLast()
        changeID += 1
        onLocalEdit?(.undo)
    }

    /// Clear all remote ink on both Pilot and the iPad.
    func clear() {
        guard !strokes.isEmpty else { return }
        strokes.removeAll()
        changeID += 1
        onLocalEdit?(.clear)
    }

    private static func makeStroke(from stroke: AnnotationStroke) -> RemoteInkStroke {
        RemoteInkStroke(
            color: NSColor(
                calibratedRed: CGFloat(stroke.color.red),
                green: CGFloat(stroke.color.green),
                blue: CGFloat(stroke.color.blue),
                alpha: CGFloat(stroke.color.alpha)
            ),
            width: CGFloat(stroke.width),
            points: stroke.points.map { CGPoint(x: $0.x, y: $0.y) }
        )
    }
}

/// Freehand annotation layer drawn over the active pane (terminal/browser/
/// device). Used in place of PencilKit's `PKCanvasView`, which is iOS/Catalyst
/// only and unavailable in this native macOS app. Strokes clear when dismissed.
struct InkOverlay: View {
    @Binding var isActive: Bool
    @State private var model = InkModel()

    private let palette: [NSColor] = [.systemRed, .systemOrange, .systemYellow,
                                      .systemGreen, .systemBlue, .white]

    var body: some View {
        ZStack(alignment: .top) {
            InkCanvas(model: model, onDismiss: { isActive = false })
            toolbar.padding(.top, 14)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            ForEach(palette.indices, id: \.self) { index in
                let swatch = palette[index]
                Circle()
                    .fill(Color(nsColor: swatch))
                    .frame(width: 18, height: 18)
                    .overlay {
                        Circle().strokeBorder(
                            .primary.opacity(!model.isEraser && model.color == swatch ? 0.9 : 0),
                            lineWidth: 2
                        )
                    }
                    .contentShape(Circle())
                    .onTapGesture {
                        model.color = swatch
                        model.isEraser = false
                    }
            }

            Color.clear.frame(width: 4, height: 1)

            toolButton("eraser", active: model.isEraser) { model.isEraser.toggle() }
            toolButton("arrow.uturn.backward", disabled: model.strokes.isEmpty) { model.undo() }
            toolButton("trash", disabled: model.strokes.isEmpty) { model.clear() }

            Color.clear.frame(width: 4, height: 1)

            Button("Done") { isActive = false }
                .buttonStyle(.plain)
                .scaledFont(size: 12, weight: .semibold)
                .padding(.horizontal, 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .fixedSize()
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }

    private func toolButton(_ symbol: String, active: Bool = false,
                            disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(active ? Color.accentColor : .primary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

struct RemoteInkOverlay: View {
    var model: RemoteInkModel

    var body: some View {
        RemoteInkCanvas(model: model)
            .allowsHitTesting(false)
    }
}

/// Floating undo + clear controls for the Plotter-drawn ink. Shown on Pilot
/// while remote ink is present; actions round-trip to the iPad so both stay in
/// sync (see ``RemoteInkModel/onLocalEdit``).
struct RemoteInkControls: View {
    var model: RemoteInkModel

    var body: some View {
        HStack(spacing: 10) {
            button("arrow.uturn.backward", help: "Undo last Kneeboard stroke") { model.undo() }
            button("trash", help: "Clear Kneeboard annotations") { model.clear() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .scaledFont(size: 13, weight: .medium)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct RemoteInkCanvas: NSViewRepresentable {
    var model: RemoteInkModel

    func makeNSView(context: Context) -> RemoteInkCanvasNSView {
        let view = RemoteInkCanvasNSView()
        view.model = model
        return view
    }

    func updateNSView(_ nsView: RemoteInkCanvasNSView, context: Context) {
        nsView.model = model
        nsView.needsDisplay = true
    }
}

final class RemoteInkCanvasNSView: NSView {
    weak var model: RemoteInkModel?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let model else { return }

        for stroke in model.strokes where stroke.points.count > 1 {
            let path = NSBezierPath()
            path.lineWidth = max(1.5, stroke.width * min(bounds.width, bounds.height))
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            let first = denormalize(stroke.points[0])
            path.move(to: first)
            for point in stroke.points.dropFirst() {
                path.line(to: denormalize(point))
            }
            stroke.color.setStroke()
            path.stroke()
        }
    }

    private func denormalize(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * bounds.width, y: point.y * bounds.height)
    }
}

/// AppKit canvas capturing freehand strokes and rendering them transparently
/// on top of whatever pane is behind it.
private struct InkCanvas: NSViewRepresentable {
    var model: InkModel
    var onDismiss: (() -> Void)?

    func makeNSView(context: Context) -> InkCanvasNSView {
        let view = InkCanvasNSView()
        view.model = model
        view.onDismiss = onDismiss
        return view
    }

    func updateNSView(_ nsView: InkCanvasNSView, context: Context) {
        nsView.model = model
        nsView.onDismiss = onDismiss
        nsView.needsDisplay = true
        // Recolor the pencil/eraser cursor immediately when the tool/color changes.
        nsView.refreshCursor()
    }
}

final class InkCanvasNSView: NSView {
    weak var model: InkModel?
    /// Invoked when the user leaves drawing mode from the canvas (Escape) —
    /// wired to the same `isActive = false` the toolbar's "Done" button uses.
    var onDismiss: (() -> Void)?
    private var current: InkStroke?
    private var isMouseInside = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // Capture every click so the pane underneath stays untouched while drawing.
    override func hitTest(_ point: NSPoint) -> NSView? { self }

    // Take key focus the moment the overlay appears so Escape dismisses drawing
    // mode even before the first stroke. While drawing, keystrokes belong to the
    // annotation layer, not the terminal/browser underneath — which is also why
    // Escape can't be left to the pane (Ghostty would swallow it).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    // Escape leaves drawing mode, exactly like tapping "Done". Other keys fall
    // through to the default responder handling.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onDismiss?()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited],
            owner: self
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        currentCursor().set()
    }

    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
        currentCursor().set()
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
    }

    /// Re-apply the cursor immediately (e.g. when the ink color changes) when
    /// the pointer is over the canvas.
    func refreshCursor() {
        if isMouseInside { currentCursor().set() }
    }

    private func currentCursor() -> NSCursor {
        guard let model else { return .crosshair }
        return model.isEraser
            ? Self.makeCursor(symbol: "eraser.fill", color: .white, centerHotspot: true)
            : Self.makeCursor(symbol: "pencil", color: model.color, centerHotspot: false)
    }

    /// Builds an NSCursor from an SF Symbol, tinted to the ink color with a dark
    /// halo so it stays visible over any pane. The pencil's hot spot is its
    /// lower-left tip; the eraser's is its center.
    private static func makeCursor(symbol: String, color: NSColor, centerHotspot: Bool) -> NSCursor {
        let config = NSImage.SymbolConfiguration(pointSize: 28, weight: .medium)
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return .crosshair }

        // Tint the template symbol with the ink color.
        let size = base.size
        let tinted = NSImage(size: size)
        tinted.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: size))
        color.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        tinted.unlockFocus()

        // Composite with a soft dark halo for contrast.
        let pad: CGFloat = 3
        let canvasSize = NSSize(width: size.width + pad * 2, height: size.height + pad * 2)
        let image = NSImage(size: canvasSize)
        image.lockFocus()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = .zero
        shadow.set()
        tinted.draw(in: NSRect(x: pad, y: pad, width: size.width, height: size.height))
        image.unlockFocus()

        let hotSpot = centerHotspot
            ? NSPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            : NSPoint(x: pad + 1, y: canvasSize.height - pad - 1)
        return NSCursor(image: image, hotSpot: hotSpot)
    }

    override func mouseDown(with event: NSEvent) {
        guard let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        if model.isEraser {
            erase(near: point)
        } else {
            current = InkStroke(color: model.color, width: model.width, points: [point])
        }
        needsDisplay = true
        currentCursor().set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        if model.isEraser {
            erase(near: point)
        } else {
            current?.points.append(point)
        }
        needsDisplay = true
        currentCursor().set()
    }

    override func mouseUp(with event: NSEvent) {
        if let stroke = current, stroke.points.count > 1 {
            model?.strokes.append(stroke)
        }
        current = nil
        needsDisplay = true
    }

    private func erase(near point: CGPoint) {
        model?.strokes.removeAll { stroke in
            stroke.points.contains { hypot($0.x - point.x, $0.y - point.y) < max(14, stroke.width * 3) }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        var all = model?.strokes ?? []
        if let current { all.append(current) }
        for stroke in all where stroke.points.count > 1 {
            let path = NSBezierPath()
            path.lineWidth = stroke.width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: stroke.points[0])
            for point in stroke.points.dropFirst() { path.line(to: point) }
            stroke.color.setStroke()
            path.stroke()
        }
    }
}
