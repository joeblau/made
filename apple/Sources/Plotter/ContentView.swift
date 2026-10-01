import AVFoundation
import PencilKit
import SwiftUI
import UIKit

struct ContentView: View {
    var mirror: MirrorModel

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            // A single transformable container holds BOTH the video layer and
            // the PencilKit canvas, so pinch-zoom/pan moves them together and
            // annotation strokes stay pixel-aligned with the mirrored window.
            ZoomableMirrorView(mirror: mirror)
                .ignoresSafeArea()

            // Frame-count / status reads live in their own view so the 60fps
            // diagnostic ticks don't re-render the canvas or video reps.
            SearchingOverlay(mirror: mirror)
        }
        // Settings gear + Pilot (Mac) connection status, top-left. Clears the
        // annotation toolbar (undo/clear/reset), which sits top-trailing.
        .overlay(alignment: .topLeading) {
            HStack(spacing: 10) {
                SettingsButton()
                    .font(.title2)
                    .tint(.white)
                ConnectionStatusBadge(mirror: mirror)
            }
            .padding()
        }
        .alert(
            mirror.pairingRequest?.isKeyChange == true
                ? "Trust New Cockpit Identity?"
                : "Pair with Cockpit?",
            isPresented: Binding(
                get: { mirror.pairingRequest != nil },
                set: { if !$0 { mirror.resolvePairingRequest(approved: false) } }
            )
        ) {
            Button("Reject", role: .cancel) {
                mirror.resolvePairingRequest(approved: false)
            }
            Button(mirror.pairingRequest?.isKeyChange == true ? "Trust New Key" : "Pair") {
                mirror.resolvePairingRequest(approved: true)
            }
        } message: {
            Text("Verify this fingerprint on Cockpit before approving:\n\n\(mirror.pairingRequest?.fingerprint ?? "")")
        }
    }
}

/// Laptop (Pilot/Mac) connection indicator: green once we're receiving the
/// mirror, dim otherwise. Isolated into its own view so the per-frame
/// `frameCount` updates only re-render this small badge — not the video or
/// PencilKit canvas siblings.
private struct ConnectionStatusBadge: View {
    var mirror: MirrorModel

    var body: some View {
        let connected = mirror.frameCount > 0
        Image(systemName: "laptopcomputer")
            .font(.title2)
            .foregroundStyle(connected ? Color.green : Color.white.opacity(0.5))
            .padding(8)
            .background(.black.opacity(0.42), in: Capsule())
            .help(connected ? "Connected to Cockpit" : "Searching for Cockpit")
            .accessibilityLabel(connected ? "Connected to Cockpit" : "Not connected to Cockpit")
            .contextMenu {
                Button("Forget Paired Cockpit", role: .destructive) {
                    mirror.forgetPilot()
                }
            }
    }
}

/// The "searching for Cockpit" placeholder. Isolated into its own view so the
/// per-frame `frameCount` updates only re-render this text — not the video or
/// PencilKit canvas siblings.
private struct SearchingOverlay: View {
    var mirror: MirrorModel

    var body: some View {
        if mirror.frameCount == 0 {
            ContentUnavailableView {
                Label("Searching for Cockpit", systemImage: "antenna.radiowaves.left.and.right")
            } description: {
                Text("Make sure Cockpit is running on your Mac, and that both devices are on the same Wi-Fi network with Local Network access enabled for Kneeboard.")
            } actions: {
                ProgressView()
            }
        }
    }
}

// MARK: - Zoomable container

/// Bridges the UIKit ``ZoomableMirrorUIView`` (which owns the video layer, the
/// PencilKit canvas, and the pinch/pan gestures) into SwiftUI.
private struct ZoomableMirrorView: UIViewRepresentable {
    var mirror: MirrorModel

    func makeUIView(context: Context) -> ZoomableMirrorUIView {
        let view = ZoomableMirrorUIView()
        mirror.attach(view.sampleBufferDisplayLayer)
        view.onStrokeAdded = { stroke, contentRect in
            guard let s = Self.annotationStroke(from: stroke, contentRect: contentRect) else { return }
            mirror.sendAnnotation(.addStroke(s))
        }
        view.onUndo = {
            mirror.sendAnnotation(.undo)
        }
        view.onResync = { drawing, contentRect in
            mirror.sendAnnotation(.replaceDrawing(Self.annotationDrawing(
                from: drawing,
                contentRect: contentRect
            )))
        }
        view.onClear = {
            mirror.sendAnnotation(.clear)
        }
        // Apply undo/clear commands that originate on Pilot to this canvas (the
        // authoritative drawing); the resulting change echoes back to Pilot.
        mirror.onRemoteAnnotation = { [weak view] message in
            view?.applyRemoteCommand(message)
        }
        view.videoSize = mirror.videoSize
        // Demo mode: show a representative still in place of the live video
        // layer and seed a couple of annotation strokes so the feature reads in
        // screenshots. A normal launch leaves the live decode path untouched.
        if mirror.isDemoMode {
            view.applyDemoContent(image: mirror.demoImage)
        }
        return view
    }

    func updateUIView(_ uiView: ZoomableMirrorUIView, context: Context) {
        if mirror.isDemoMode {
            uiView.videoSize = mirror.videoSize
            uiView.applyDemoContent(image: mirror.demoImage)
            return
        }
        mirror.attach(uiView.sampleBufferDisplayLayer)
        uiView.videoSize = mirror.videoSize
    }

    /// Maps PencilKit strokes (in the canvas's own, un-zoomed coordinate space)
    /// into normalized [0,1] coordinates relative to the un-zoomed video
    /// content rect, so Pilot maps them back correctly regardless of how the
    /// iPad has locally zoomed/panned.
    private static func annotationDrawing(
        from drawing: PKDrawing,
        contentRect: CGRect
    ) -> AnnotationDrawing {
        AnnotationDrawing(strokes: drawing.strokes.compactMap {
            annotationStroke(from: $0, contentRect: contentRect)
        })
    }

    /// Normalizes a single PencilKit stroke to the video content rect, or nil if
    /// it has too few in-bounds points to be meaningful.
    static func annotationStroke(from stroke: PKStroke, contentRect: CGRect) -> AnnotationStroke? {
        let drawRect = contentRect
        let scaleBase = max(1, min(drawRect.width, drawRect.height))
        let points = stroke.path.compactMap { point -> AnnotationPoint? in
            guard let normalized = PlotterGeometry.normalizedPoint(point.location, in: drawRect) else {
                return nil
            }
            return AnnotationPoint(
                x: normalized.x,
                y: normalized.y
            )
        }
        guard points.count > 1 else { return nil }

        let rgba = stroke.ink.color.rgbaComponents
        let averageWidth = stroke.path.reduce(CGFloat(0)) { partial, point in
            partial + max(point.size.width, point.size.height)
        } / CGFloat(max(1, stroke.path.count))

        return AnnotationStroke(
            color: AnnotationColor(red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha),
            width: max(1.5, averageWidth) / scaleBase,
            points: points
        )
    }
}

/// Owns the mirrored video layer and the PencilKit canvas inside a single
/// `contentView`, applies a shared affine transform for local pinch-zoom + pan,
/// and reports annotation drawings in normalized coordinates relative to the
/// un-zoomed video content rect.
private final class ZoomableMirrorUIView: UIView, PKCanvasViewDelegate, UIGestureRecognizerDelegate {
    /// Everything that should zoom/pan together lives in here.
    private let contentView = UIView()
    private let videoView = SampleBufferVideoView()
    let canvasView = PKCanvasView()
    private let toolbar = UIStackView()

    /// Shown above the (empty) video layer only in demo mode; rides the same
    /// zoom/pan transform so seeded annotation strokes stay aligned.
    private let demoImageView = UIImageView()
    private var isDemoMode = false
    private var hasSeededDemoStrokes = false

    private var toolPicker: PKToolPicker?

    /// One completed stroke was added — sent incrementally so each line is a
    /// discrete entry on Pilot's undo stack.
    var onStrokeAdded: ((PKStroke, CGRect) -> Void)?
    /// The last stroke was removed (undo).
    var onUndo: (() -> Void)?
    /// Non-incremental change (multi-stroke, resize re-anchor) — resend the full
    /// drawing so Pilot resyncs.
    var onResync: ((PKDrawing, CGRect) -> Void)?
    var onClear: (() -> Void)?

    /// Stroke count at the last delivered change, to classify the next one as an
    /// add / undo / resync.
    private var lastStrokeCount = 0

    /// Native size of the mirrored window; used to compute the aspect-fit
    /// content rect that annotations normalize against.
    var videoSize: CGSize = .zero {
        didSet {
            guard videoSize != oldValue else { return }
            // Bounds may be unchanged, so explicitly request the layout pass
            // that compares the prior and current aspect-fit rects.
            setNeedsLayout()
        }
    }

    /// The aspect-fit rect used by the drawing in its current canvas coordinate
    /// space. Tracking the rect (rather than just `videoSize`) also catches
    /// rotation, Split View, Stage Manager, and other bounds-only changes.
    private var drawingContentRect: CGRect?

    /// True while we mutate `canvasView.drawing` programmatically so the
    /// delegate doesn't echo a redundant add/undo/resync message.
    private var isApplyingProgrammaticChange = false

    // Pinch/pan transform state.
    private var scale: CGFloat = 1.0
    private var translation: CGPoint = .zero
    private let minScale: CGFloat = 1.0
    private let maxScale: CGFloat = 4.0
    private var gestureStartScale: CGFloat = 1.0
    private var gestureStartTranslation: CGPoint = .zero

    var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer {
        videoView.sampleBufferDisplayLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        setupContent()
        setupCanvas()
        setupToolbar()
        setupGestures()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The content view fills us; the affine transform handles zoom/pan.
        contentView.frame = bounds
        videoView.frame = contentView.bounds
        demoImageView.frame = contentView.bounds
        canvasView.frame = contentView.bounds
        remapDrawingForCurrentLayoutIfNeeded()
        applyTransform()
        // Seed demo strokes once we actually have a non-zero canvas to map
        // them into (layout has run and videoSize is known).
        if isDemoMode, !hasSeededDemoStrokes, videoSize != .zero,
           canvasView.bounds.width > 0 {
            seedDemoStrokes()
            hasSeededDemoStrokes = true
        }
    }

    private func setupContent() {
        addSubview(contentView)
        contentView.backgroundColor = .clear
        contentView.addSubview(videoView)
        demoImageView.contentMode = .scaleAspectFit
        demoImageView.isHidden = true
        contentView.addSubview(demoImageView)
        contentView.addSubview(canvasView)
    }

    // MARK: Demo mode

    /// Renders the representative still in place of the live video layer.
    /// Idempotent so it is safe to call from `updateUIView`.
    func applyDemoContent(image: UIImage?) {
        isDemoMode = true
        demoImageView.image = image
        demoImageView.isHidden = (image == nil)
        setNeedsLayout()
    }

    /// Draws a couple of representative PencilKit strokes over the demo still so
    /// the annotation feature is visible in screenshots.
    private func seedDemoStrokes() {
        let rect = PlotterGeometry.aspectFitRect(contentSize: videoSize, in: canvasView.bounds)
        guard rect.width > 0, rect.height > 0 else { return }

        func point(_ nx: CGFloat, _ ny: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + nx * rect.width, y: rect.minY + ny * rect.height)
        }

        var strokes: [PKStroke] = []

        // A red circle-ish loop highlighting a region.
        let loop = stride(from: 0.0, through: 1.0, by: 0.04).map { t -> PKStrokePoint in
            let angle = t * 2 * .pi
            let p = point(0.62 + 0.10 * CGFloat(cos(angle)),
                          0.40 + 0.14 * CGFloat(sin(angle)))
            return PKStrokePoint(
                location: p, timeOffset: t * 0.5, size: CGSize(width: 8, height: 8),
                opacity: 1, force: 1, azimuth: 0, altitude: 0
            )
        }
        strokes.append(PKStroke(
            ink: PKInk(.pen, color: .systemRed),
            path: PKStrokePath(controlPoints: loop, creationDate: Date())
        ))

        // An underline beneath a line of "code".
        let underline = [point(0.38, 0.62), point(0.66, 0.62)].enumerated().map { idx, p in
            PKStrokePoint(
                location: p, timeOffset: Double(idx) * 0.1, size: CGSize(width: 7, height: 7),
                opacity: 1, force: 1, azimuth: 0, altitude: 0
            )
        }
        strokes.append(PKStroke(
            ink: PKInk(.pen, color: .systemYellow),
            path: PKStrokePath(controlPoints: underline, creationDate: Date())
        ))

        canvasView.drawing = PKDrawing(strokes: strokes)
        lastStrokeCount = strokes.count
        updateCanvasAccessibilityValue()
    }

    private func setupCanvas() {
        canvasView.delegate = self
        canvasView.drawingPolicy = .anyInput
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.isAccessibilityElement = true
        canvasView.accessibilityIdentifier = "AnnotationCanvas"
        canvasView.accessibilityLabel = "Annotation canvas"
        canvasView.tool = PKInkingTool(.pen, color: .systemRed, width: 4)
        // PencilKit ships its own pan/zoom scroll behaviour; disable it so our
        // gestures drive the shared transform and strokes never desync.
        canvasView.isScrollEnabled = false
        canvasView.minimumZoomScale = 1
        canvasView.maximumZoomScale = 1
        canvasView.becomeFirstResponder()
        updateCanvasAccessibilityValue()
        installToolPicker(for: canvasView)
    }

    private func installToolPicker(for canvasView: PKCanvasView) {
        let picker = PKToolPicker()
        picker.addObserver(canvasView)
        picker.setVisible(true, forFirstResponder: canvasView)
        toolPicker = picker
    }

    private func setupToolbar() {
        toolbar.axis = .horizontal
        toolbar.spacing = 10
        toolbar.alignment = .center
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.backgroundColor = UIColor.black.withAlphaComponent(0.42)
        toolbar.layer.cornerRadius = 18
        toolbar.isLayoutMarginsRelativeArrangement = true
        toolbar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)

        let undoButton = button(systemName: "arrow.uturn.backward") { [weak self] in
            self?.canvasView.undoManager?.undo()
        }
        let clearButton = button(systemName: "trash") { [weak self] in
            self?.clearCanvas()
        }
        // Close: clears the canvas and dismisses the drawing pane on Pilot. The
        // remote-ink overlay on Pilot is shown only while ink is present, so the
        // `.clear` that `clearCanvas()` sends both empties and closes it.
        let closeButton = button(systemName: "xmark") { [weak self] in
            self?.clearCanvas()
        }
        let resetZoomButton = button(systemName: "arrow.up.left.and.arrow.down.right") { [weak self] in
            self?.resetZoom()
        }
        toolbar.addArrangedSubview(resetZoomButton)
        toolbar.addArrangedSubview(undoButton)
        toolbar.addArrangedSubview(clearButton)
        toolbar.addArrangedSubview(closeButton)

        // The toolbar stays fixed (not inside the transformable content view).
        addSubview(toolbar)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -12)
        ])
    }

    /// Empties this canvas and tells Pilot to clear too (`onClear` sends a single
    /// `.clear`). Used by both the trash and close buttons; the latter relies on
    /// the clear to also dismiss Pilot's ink overlay, which is ink-gated.
    private func clearCanvas() {
        // Suppress the diff handler so we send a single `.clear` rather than an
        // empty resync as well.
        isApplyingProgrammaticChange = true
        canvasView.drawing = PKDrawing()
        lastStrokeCount = 0
        updateCanvasAccessibilityValue()
        isApplyingProgrammaticChange = false
        onClear?()
    }

    private func button(systemName: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.tintColor = .white
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    // MARK: Gestures

    private func setupGestures() {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        // Two fingers so single-finger drawing on the canvas isn't hijacked.
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        addGestureRecognizer(pinch)
        addGestureRecognizer(pan)
    }

    /// Allow pinch + pan to run simultaneously for a natural zoom/pan feel.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        (gestureRecognizer is UIPinchGestureRecognizer || gestureRecognizer is UIPanGestureRecognizer)
            && (other is UIPinchGestureRecognizer || other is UIPanGestureRecognizer)
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            gestureStartScale = scale
        case .changed:
            scale = clampedScale(gestureStartScale * recognizer.scale)
            translation = clampedTranslation(translation)
            applyTransform()
        case .ended, .cancelled, .failed:
            applyTransform()
        default:
            break
        }
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            gestureStartTranslation = translation
        case .changed:
            let delta = recognizer.translation(in: self)
            translation = clampedTranslation(CGPoint(
                x: gestureStartTranslation.x + delta.x,
                y: gestureStartTranslation.y + delta.y
            ))
            applyTransform()
        case .ended, .cancelled, .failed:
            applyTransform()
        default:
            break
        }
    }

    private func resetZoom() {
        scale = 1
        translation = .zero
        UIView.animate(withDuration: 0.2) { self.applyTransform() }
    }

    private func clampedScale(_ value: CGFloat) -> CGFloat {
        min(maxScale, max(minScale, value))
    }

    /// Clamps the pan so the zoomed content can't be dragged off-screen: the
    /// max offset is half the overflow on each axis.
    private func clampedTranslation(_ value: CGPoint) -> CGPoint {
        let maxX = max(0, (bounds.width * scale - bounds.width) / 2)
        let maxY = max(0, (bounds.height * scale - bounds.height) / 2)
        return CGPoint(
            x: min(maxX, max(-maxX, value.x)),
            y: min(maxY, max(-maxY, value.y))
        )
    }

    private func applyTransform() {
        // Scale about the center, then translate. Both the video and the canvas
        // ride the same transform, so strokes stay aligned with the picture.
        let transform = CGAffineTransform(translationX: translation.x, y: translation.y)
            .scaledBy(x: scale, y: scale)
        contentView.transform = transform
    }

    // MARK: Drawing -> normalized annotation

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        let count = canvasView.drawing.strokes.count
        updateCanvasAccessibilityValue()
        guard !isApplyingProgrammaticChange else {
            // Programmatic change (remote command / layout remap): keep the
            // count in sync but don't echo a message back.
            lastStrokeCount = count
            return
        }
        let contentRect = PlotterGeometry.aspectFitRect(contentSize: videoSize, in: canvasView.bounds)
        if count == lastStrokeCount + 1, let stroke = canvasView.drawing.strokes.last {
            // One new line: send it incrementally so Pilot stacks it for undo.
            onStrokeAdded?(stroke, contentRect)
        } else if count == lastStrokeCount - 1 {
            onUndo?()
        } else {
            // Multi-stroke change / unexpected: resync the whole drawing.
            onResync?(canvasView.drawing, contentRect)
        }
        lastStrokeCount = count
    }

    /// Applies an annotation command sent by Pilot to this (authoritative)
    /// canvas. Suppressed from echoing back, since Pilot already applied it.
    func applyRemoteCommand(_ message: AnnotationMessage) {
        isApplyingProgrammaticChange = true
        defer {
            lastStrokeCount = canvasView.drawing.strokes.count
            updateCanvasAccessibilityValue()
            isApplyingProgrammaticChange = false
        }
        switch message {
        case .undo:
            canvasView.undoManager?.undo()
        case .clear:
            canvasView.drawing = PKDrawing()
        case .addStroke, .replaceDrawing:
            break // Pilot only sends undo / clear commands to the canvas.
        }
    }

    /// Re-anchors existing strokes whenever the aspect-fit rect changes. This
    /// runs after the canvas receives its new bounds, and records the new rect
    /// before assigning the drawing to prevent nested layout/delegate feedback
    /// from applying the same transform twice.
    private func remapDrawingForCurrentLayoutIfNeeded() {
        guard videoSize.width > 0,
              videoSize.height > 0,
              canvasView.bounds.width > 0,
              canvasView.bounds.height > 0 else { return }

        let currentRect = PlotterGeometry.aspectFitRect(
            contentSize: videoSize,
            in: canvasView.bounds
        )
        guard let previousRect = drawingContentRect else {
            drawingContentRect = currentRect
            return
        }

        // Commit the layout state before changing PencilKit. The drawing setter
        // can synchronously invoke its delegate and cause another layout pass.
        drawingContentRect = currentRect
        guard previousRect != currentRect,
              !canvasView.drawing.strokes.isEmpty,
              let transform = PlotterGeometry.drawingTransform(
                  from: previousRect,
                  to: currentRect
              ) else { return }

        isApplyingProgrammaticChange = true
        let undoManager = canvasView.undoManager
        let wasUndoRegistrationEnabled = undoManager?.isUndoRegistrationEnabled == true
        if wasUndoRegistrationEnabled {
            undoManager?.disableUndoRegistration()
        }
        canvasView.drawing = canvasView.drawing.transformed(using: transform)
        if wasUndoRegistrationEnabled {
            undoManager?.enableUndoRegistration()
        }
        lastStrokeCount = canvasView.drawing.strokes.count
        updateCanvasAccessibilityValue()
        isApplyingProgrammaticChange = false

        // Pilot stores normalized drawing data. Send exactly one replacement
        // after a real canvas mapping so both sides remain authoritative.
        reportResync(in: currentRect)
    }

    /// Resyncs the entire drawing to Pilot (used after a resize re-anchor or any
    /// non-incremental change). Coordinates are in the canvas's own un-zoomed
    /// space relative to the content rect, so they stay stable for Pilot.
    private func reportResync(in contentRect: CGRect) {
        onResync?(canvasView.drawing, contentRect)
        lastStrokeCount = canvasView.drawing.strokes.count
    }

    private func updateCanvasAccessibilityValue() {
        let count = canvasView.drawing.strokes.count
        canvasView.accessibilityValue = "\(count) annotation strokes"
    }
}

private extension UIColor {
    var rgbaComponents: (red: Double, green: Double, blue: Double, alpha: Double) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (Double(red), Double(green), Double(blue), Double(alpha))
    }
}

private final class SampleBufferVideoView: UIView {
    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }
}
