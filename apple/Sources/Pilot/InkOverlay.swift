import AppKit
import Observation
import PaperKit
import PencilKit

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

/// PaperKit owns the drawing tools, selection, and markup editing. Each overlay
/// has its own canvas and undo manager, so Main and Extendo remain independent.
@MainActor
final class InkOverlayViewController: NSViewController, @MainActor PaperMarkupViewController.Delegate {
    let markupController = PaperMarkupViewController(supportedFeatureSet: .latest)
    let toolPicker = MarkupToolbarViewController(supportedFeatureSet: .latest)
    private let annotationUndoManager = UndoManager()
    private let onDismiss: () -> Void
    private var undoButton: NSButton?
    private var clearButton: NSButton?
    private var keyMonitor: Any?
    private var undoObservers: [NSObjectProtocol] = []
    private var canvasBounds = CGRect.zero
    private var lastMarkup: PaperMarkup?
    private var dismissed = false

    override var undoManager: UndoManager? { annotationUndoManager }

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = InkAnnotationView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        root.annotationUndoManager = annotationUndoManager
        root.onLayout = { [weak self] bounds in self?.updateCanvasBounds(bounds) }
        view = root
        markupController.delegate = self
        markupController.isEditable = true
        markupController.zoomRange = 1...1
        markupController.indirectPointerTouchMode = .drawing
        markupController.drawingTool = PKInkingTool(.pen, color: .systemRed, width: 3)
        markupController.contentView = NSView()
        if #available(macOS 27.0, *) {
            markupController.scrollConfiguration.isScrollEnabled = false
            markupController.scrollConfiguration.visibleScrollIndicators = []
        }
        addChild(markupController)
        shellPin(markupController.view, to: view)
        markupController.view.layer?.backgroundColor = NSColor.clear.cgColor

        toolPicker.delegate = markupController
        toolPicker.indirectPointerTouchModes = [.drawing, .selection]
        toolPicker.selectedIndirectPointerTouchMode = .drawing
        toolPicker.selectedDrawingTool = markupController.drawingTool
        addChild(toolPicker)
        toolPicker.view.setAccessibilityLabel("Annotation tools")
        toolPicker.view.setAccessibilityIdentifier("annotation.native-tool-picker")

        let undo = CaptureActionButton(CapturePaneAction(title: "Undo annotation", symbol: "arrow.uturn.backward", perform: { [weak self] in
            self?.annotationUndoManager.undo()
            self?.updateControls()
        }), iconOnly: true)
        undoButton = undo
        let clear = CaptureActionButton(CapturePaneAction(title: "Clear annotations", symbol: "trash", perform: { [weak self] in
            self?.clearAnnotations()
        }), iconOnly: true)
        clearButton = clear
        let done = CaptureActionButton(CapturePaneAction(title: "Done", symbol: "checkmark", perform: { [weak self] in self?.dismissInk() }))
        let actions = CockpitUI.hStack([undo, clear, done], spacing: 5)
        let actionGlass = CockpitGlassView(content: actions, cornerRadius: 18)
        let controls = CockpitUI.vStack([toolPicker.view, actionGlass], spacing: 8)
        controls.alignment = .centerX
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            controls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            controls.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 4),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -4),
        ])
        for name in [Notification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            undoObservers.append(NotificationCenter.default.addObserver(forName: name, object: annotationUndoManager, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateControls() }
            })
        }
        updateCanvasBounds(root.bounds)
        updateControls()
    }

    private func updateCanvasBounds(_ bounds: CGRect) {
        markupController.view.layer?.backgroundColor = NSColor.clear.cgColor
        guard bounds.width > 0, bounds.height > 0, bounds != canvasBounds else { return }
        canvasBounds = bounds
        var markup = markupController.markup ?? PaperMarkup(bounds: bounds)
        markup.bounds = bounds
        if #available(macOS 27.0, *) { markup.backgroundColor = NSColor.clear.cgColor }
        applyMarkup(markup)
        markupController.contentView?.frame = bounds
        markupController.setContentVisibleFrame(bounds, animated: false)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(markupController)
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.view.window, event.window === window, event.keyCode == 53 else { return event }
            self.dismissInk()
            return nil
        }
    }

    override func viewWillDisappear() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        annotationUndoManager.removeAllActions()
        super.viewWillDisappear()
    }

    override func cancelOperation(_ sender: Any?) { dismissInk() }

    func clearAnnotations() {
        applyMarkup(PaperMarkup(bounds: canvasBounds))
        annotationUndoManager.removeAllActions()
        updateControls()
    }

    private func dismissInk() {
        guard !dismissed else { return }
        dismissed = true
        clearAnnotations()
        onDismiss()
    }

    func paperMarkupViewControllerDidChangeMarkup(_ paperMarkupViewController: PaperMarkupViewController) {
        // PaperKit reports edits asynchronously. A report still in flight when
        // the overlay is dismissed must not register undo on the cleared canvas.
        guard !dismissed else { return }
        guard let markup = paperMarkupViewController.markup, markup != lastMarkup else { return }
        if let previous = lastMarkup {
            annotationUndoManager.registerUndo(withTarget: self) { $0.restoreMarkup(previous) }
            annotationUndoManager.setActionName("Annotation")
        }
        lastMarkup = markup
        updateControls()
    }

    private func restoreMarkup(_ markup: PaperMarkup) {
        if let current = markupController.markup {
            annotationUndoManager.registerUndo(withTarget: self) { $0.restoreMarkup(current) }
        }
        var restored = markup
        restored.bounds = canvasBounds
        applyMarkup(restored)
    }

    private func applyMarkup(_ markup: PaperMarkup) {
        lastMarkup = markup
        markupController.markup = markup
        updateControls()
    }

    private func updateControls() {
        undoButton?.isEnabled = annotationUndoManager.canUndo
        clearButton?.isEnabled = markupController.markup.map { !$0.contentsRenderFrame.isEmpty } ?? false
    }

    isolated deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        for observer in undoObservers { NotificationCenter.default.removeObserver(observer) }
    }
}

@MainActor
private final class InkAnnotationView: NSView {
    var annotationUndoManager: UndoManager?
    var onLayout: ((CGRect) -> Void)?
    override var undoManager: UndoManager? { annotationUndoManager }
    override func layout() {
        onLayout?(bounds)
        super.layout()
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
