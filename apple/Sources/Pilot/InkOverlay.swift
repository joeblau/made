import AppKit
import Observation

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

/// Native freehand annotation overlay. Its canvas owns input only while this
/// controller is attached; removing the overlay restores the pane responder.
@MainActor
final class InkOverlayViewController: NSViewController {
    let model: InkModel
    private let onDismiss: () -> Void
    private let canvas = InkCanvasNSView()
    private let palette: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .white]
    private let names = ["Red", "Orange", "Yellow", "Green", "Blue", "White"]
    private var swatches: [NSButton] = []
    private var eraser: NSButton?
    private var undo: NSButton?
    private var clear: NSButton?
    private lazy var observation = CockpitObservation(owner: self) { $0.updateControls() }

    init(model: InkModel = InkModel(), onDismiss: @escaping () -> Void) {
        self.model = model
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        canvas.model = model
        canvas.onDismiss = { [weak self] in self?.dismissInk() }
        canvas.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: view.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let controls = NSStackView()
        controls.spacing = 5
        for (index, color) in palette.enumerated() {
            let button = CaptureActionButton(CapturePaneAction(title: names[index] + " ink", symbol: "circle.fill", perform: { [weak self] in
                self?.model.color = color
                self?.model.isEraser = false
                // A toggle button toggles off before its action. Reconcile
                // even when choosing the current color produces no model edit.
                self?.updateControls()
            }), iconOnly: true)
            button.contentTintColor = color
            button.setButtonType(.toggle)
            controls.addArrangedSubview(button)
            swatches.append(button)
        }
        let eraser = CaptureActionButton(CapturePaneAction(title: "Eraser", symbol: "eraser", perform: { [weak self] in self?.model.isEraser.toggle() }), iconOnly: true)
        eraser.setButtonType(.toggle)
        self.eraser = eraser
        controls.addArrangedSubview(eraser)
        let undo = CaptureActionButton(CapturePaneAction(title: "Undo last stroke", symbol: "arrow.uturn.backward", perform: { [weak self] in self?.model.undo() }), iconOnly: true)
        self.undo = undo
        controls.addArrangedSubview(undo)
        let clear = CaptureActionButton(CapturePaneAction(title: "Clear annotations", symbol: "trash", perform: { [weak self] in self?.model.clear() }), iconOnly: true)
        self.clear = clear
        controls.addArrangedSubview(clear)
        controls.addArrangedSubview(CaptureActionButton(CapturePaneAction(title: "Done", symbol: "checkmark", perform: { [weak self] in self?.dismissInk() })))
        let backdrop = inkControlsBackdrop(controls)
        view.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            backdrop.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 4),
            backdrop.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -4),
        ])
        updateControls()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        observation.start()
        view.window?.makeFirstResponder(canvas)
    }

    override func viewWillDisappear() {
        observation.stop()
        super.viewWillDisappear()
    }

    private func dismissInk() {
        model.clear()
        onDismiss()
    }

    private func updateControls() {
        for (index, button) in swatches.enumerated() {
            button.state = !model.isEraser && model.color == palette[index] ? .on : .off
        }
        eraser?.state = model.isEraser ? .on : .off
        undo?.isEnabled = !model.strokes.isEmpty
        clear?.isEnabled = !model.strokes.isEmpty
        canvas.needsDisplay = true
        canvas.refreshCursor()
    }
}

/// The normalized remote canvas is click-through. Only its undo/clear buttons
/// participate in hit testing; the paired iPad remains the drawing authority.
@MainActor
final class RemoteInkOverlayViewController: NSViewController {
    let model: RemoteInkModel
    private let canvas = RemoteInkCanvasNSView()
    private var controls: NSView?
    private lazy var observation = CockpitObservation(owner: self) { $0.refresh() }

    init(model: RemoteInkModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = InkPassThroughView()
        canvas.model = model
        canvas.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: view.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let row = NSStackView(views: [
            CaptureActionButton(CapturePaneAction(title: "Undo last Kneeboard stroke", symbol: "arrow.uturn.backward", perform: { [weak self] in self?.model.undo() }), iconOnly: true),
            CaptureActionButton(CapturePaneAction(title: "Clear Kneeboard annotations", symbol: "trash", perform: { [weak self] in self?.model.clear() }), iconOnly: true),
        ])
        row.spacing = 5
        let backdrop = inkControlsBackdrop(row)
        view.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])
        controls = backdrop
        refresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        observation.start()
    }

    override func viewWillDisappear() {
        observation.stop()
        super.viewWillDisappear()
    }

    private func refresh() {
        _ = model.changeID
        controls?.isHidden = !model.hasInk
        canvas.needsDisplay = true
    }
}

@MainActor
private final class InkPassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let target = super.hitTest(point)
        return target === self ? nil : target
    }
}

@MainActor
private func inkControlsBackdrop(_ controls: NSView) -> NSView {
    let backdrop = NSVisualEffectView()
    backdrop.material = .hudWindow
    backdrop.blendingMode = .withinWindow
    backdrop.state = .active
    backdrop.wantsLayer = true
    backdrop.layer?.cornerRadius = 16
    backdrop.translatesAutoresizingMaskIntoConstraints = false
    controls.translatesAutoresizingMaskIntoConstraints = false
    backdrop.addSubview(controls)
    NSLayoutConstraint.activate([
        controls.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 8),
        controls.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -8),
        controls.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 8),
        controls.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -8),
    ])
    return backdrop
}

final class RemoteInkCanvasNSView: NSView {
    weak var model: RemoteInkModel?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

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
