import AVFoundation
import PencilKit
import SwiftUI
import UIKit

struct ContentView: View {
    var mirror: MirrorModel
    @State private var showsDashboard = false
    @State private var showsSettings = false
    @State private var dashboardFamily = DashboardFamily.actions
    /// How far the corner-adapted safe area reaches past the plain safe area
    /// on each edge, measured by the UIKit mirror view. When the app runs in
    /// a resizable window, the leading value clears the iPadOS window
    /// controls (close, minimize, tile) at top-leading.
    @State private var cornerInsets = EdgeInsets()

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            // A single transformable container holds BOTH the video layer and
            // the PencilKit canvas, so pinch-zoom/pan moves them together and
            // annotation strokes stay pixel-aligned with the mirrored window.
            // The PencilKit tool picker is a system palette above the app's
            // windows; hide it while a sheet covers the mirror so it never
            // floats over (and clips) the sheet's content.
            ZoomableMirrorView(
                mirror: mirror,
                isCovered: showsDashboard || showsSettings,
                onCornerInsetsChange: { cornerInsets = $0 }
            )
            .ignoresSafeArea()

            // Frame-count / status reads live in their own view so the 60fps
            // diagnostic ticks don't re-render the canvas or video reps.
            SearchingOverlay(mirror: mirror)
        }
        // Settings + Dashboard + Pilot (Mac) connection status, top-left. Clears
        // the annotation toolbar (undo/clear/reset), which sits top-trailing.
        // Both float over the mirror as Liquid Glass controls; the container
        // lets the neighboring glass shapes blend into one cluster.
        .overlay(alignment: .topLeading) {
            FloatingControlCluster(
                mirror: mirror,
                showsSettings: $showsSettings,
                showsDashboard: $showsDashboard
            )
            // Floating chrome over the mirror grows with Dynamic Type up to
            // AX2, in step with the UIKit annotation toolbar (which clamps at
            // the same category). Past that, the two clusters would collide
            // on an iPad mini in portrait (TYPE-4).
            .dynamicTypeSize(...FloatingChromeMetrics.maximumDynamicTypeSize)
            // The mirror stage is always black, so its floating chrome stays
            // dark in both appearances (like `SearchingOverlay`). Light glass
            // over black renders as flat gray disks that wash out the green
            // connected glyph (COL-2 dark-mode parity, contrast on glass).
            // Sheets are presented from the ZStack, so they keep the system
            // appearance.
            .environment(\.colorScheme, .dark)
            .padding(FloatingChromeMetrics.clusterPadding(cornerInsets: cornerInsets))
        }
        .sheet(isPresented: $showsSettings) {
            SettingsScreen()
        }
        .sheet(isPresented: $showsDashboard) {
            PlotterDashboardView(mirror: mirror, selectedFamily: $dashboardFamily)
        }
        .onOpenURL { url in
            guard let route = PlotterDashboardRoute(url: url) else { return }
            dashboardFamily = route.family
            showsDashboard = true
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

/// Dynamic Type sizing shared by both floating clusters over the mirror: the
/// SwiftUI Settings/Dashboard/status cluster and the UIKit annotation toolbar.
/// Both scale the same 48pt base relative to `.title3` (SwiftUI's
/// `@ScaledMetric` and `UIFontMetrics` produce identical values) and stop
/// growing at the same size, so the two clusters always share one height.
enum FloatingChromeMetrics {
    /// The control circle (and toolbar capsule height) at the default size.
    static let baseControlSide: CGFloat = 48
    /// Width of one annotation-toolbar button at the default size.
    static let baseToolbarButtonWidth: CGFloat = 44
    /// The regular `.glass` circle's padding around its label on each side.
    /// Fixed by the system across Dynamic Type sizes (measured on the 27.2
    /// iPadOS simulator: a 34pt label is a 48pt circle at every size).
    static let glassButtonPadding: CGFloat = 7
    /// The largest size the floating chrome grows to (SwiftUI side).
    static let maximumDynamicTypeSize = DynamicTypeSize.accessibility2
    /// The same limit for the UIKit side.
    static let maximumContentSizeCategory = UIContentSizeCategory.accessibilityLarge

    /// Circles in the leading SwiftUI cluster (Settings, Dashboard, status).
    static let clusterControlCount = 3

    /// Width of the leading SwiftUI cluster for a given circle size; the
    /// UIKit toolbar uses it to tell whether both clusters fit on one row.
    static func clusterWidth(controlSide: CGFloat) -> CGFloat {
        let count = CGFloat(clusterControlCount)
        return count * controlSide + (count - 1) * LiquidGlassMetrics.Spacing.xSmall
    }

    /// The leading cluster's inset from the safe area. Normally the 12pt that
    /// matches the UIKit annotation toolbar on the trailing side, so both
    /// clusters share one edge (LAY-3). Where the corner-adapted safe area
    /// reaches farther in (a resizable window's controls at top-leading),
    /// the cluster starts at that region's edge instead, exactly as the
    /// toolbar does on its side. Full screen, the region only rounds off the
    /// display corner (about 9pt), which the 12pt already clears, so the
    /// cluster stays put.
    ///
    /// SwiftUI's `containerCornerOffset` / `containerCornerInsets` do not
    /// report the window controls here, so `cornerInsets` comes from UIKit
    /// (``ZoomableMirrorUIView/cornerInsets``).
    static func clusterPadding(cornerInsets: EdgeInsets) -> EdgeInsets {
        let inset = LiquidGlassMetrics.Spacing.small
        return EdgeInsets(
            top: max(inset, cornerInsets.top),
            leading: max(inset, cornerInsets.leading),
            bottom: inset,
            trailing: inset
        )
    }

    /// `value` scaled like `.title3` for `traits`, rounded to whole points
    /// so circle edges stay crisp. Matches `@ScaledMetric(relativeTo: .title3)`
    /// rounded the same way.
    static func scaled(_ value: CGFloat, for traits: UITraitCollection) -> CGFloat {
        UIFontMetrics(forTextStyle: .title3).scaledValue(for: value, compatibleWith: traits).rounded()
    }
}

/// Settings + Dashboard + connection status. Owns the one `@ScaledMetric`
/// that sizes every circle in the cluster, so the buttons and the badge stay
/// identical at every Dynamic Type size (TYPE-4). It lives below the
/// caller's `dynamicTypeSize` clamp so the metric honors it.
private struct FloatingControlCluster: View {
    var mirror: MirrorModel
    @Binding var showsSettings: Bool
    @Binding var showsDashboard: Bool

    @ScaledMetric(relativeTo: .title3) private var scaledControlSide = FloatingChromeMetrics.baseControlSide

    var body: some View {
        let controlSide = scaledControlSide.rounded()
        GlassEffectContainer(spacing: LiquidGlassMetrics.Spacing.xSmall) {
            // `FloatingChromeMetrics.clusterWidth` mirrors this row (count
            // and spacing) so the UIKit toolbar can make room for it.
            HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                // Same "•••" entry as the shared `SettingsButton`, but the
                // sheet is presented outside this cluster's pinned-dark
                // environment so Settings follows the system appearance.
                Button {
                    showsSettings = true
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Settings")
                Button {
                    showsDashboard = true
                } label: {
                    // A titled Label keeps the spoken name with the glyph
                    // (IMG-1); only the symbol is drawn.
                    Label("Dashboard", systemImage: "square.grid.2x2")
                        .labelStyle(.iconOnly)
                }
                .help("Dashboard")
                .accessibilityLabel("Dashboard")
                ConnectionStatusBadge(mirror: mirror, diameter: controlSide)
            }
            .font(.title3)
            .buttonStyle(GlassCircleButtonStyle(diameter: controlSide))
        }
    }
}

/// System `.glass` circle buttons with a fixed glyph box, so symbols of
/// different heights (the ellipsis vs. the grid) produce identical circles.
/// A primitive style, so it wraps every button in the cluster uniformly.
private struct GlassCircleButtonStyle: PrimitiveButtonStyle {
    /// The rendered circle; the connection badge uses the same value so every
    /// circle in the cluster is identical. 48pt at the default size, matching
    /// the UIKit annotation toolbar capsule.
    let diameter: CGFloat

    /// The label box: the circle minus the system's regular glass padding.
    private var glyphSide: CGFloat {
        max(diameter - 2 * FloatingChromeMetrics.glassButtonPadding, 0)
    }

    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role) {
            configuration.trigger()
        } label: {
            configuration.label
                .frame(width: glyphSide, height: glyphSide)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
    }
}

/// Laptop (Pilot/Mac) connection indicator: green once we're receiving the
/// mirror, dim otherwise. Isolated into its own view so the per-frame
/// `frameCount` updates only re-render this small badge — not the video or
/// PencilKit canvas siblings.
private struct ConnectionStatusBadge: View {
    var mirror: MirrorModel
    /// Shared with `GlassCircleButtonStyle` so the badge matches its
    /// neighbors at every Dynamic Type size.
    let diameter: CGFloat

    var body: some View {
        let connected = mirror.frameCount > 0
        // A status readout, not a button: same circular glass footprint as the
        // neighboring controls, with green reserved for the connected signal.
        Image(systemName: connected ? "laptopcomputer" : "laptopcomputer.slash")
            .foregroundStyle(connected ? Color.green : Color.secondary)
            // The glyph morphs between states instead of hard-swapping (MOT-4).
            .contentTransition(.symbolEffect(.replace))
            .frame(width: diameter, height: diameter)
            // The whole circle is the long-press target, not just the glyph.
            .contentShape(Circle())
            // Long-press / secondary-click lifts a circle, not a squared-off
            // rectangle, for the context menu preview.
            .contentShape(.contextMenuPreview, Circle())
            // Attached inside the glass: with the menu outside it, the glass
            // layer took the long press and the menu never opened, leaving
            // Forget Paired Cockpit unreachable.
            .contextMenu {
                Button("Forget Paired Cockpit", role: .destructive) {
                    mirror.forgetPilot()
                }
            }
            .glassEffect(.regular.interactive(), in: Circle())
            .animation(LiquidGlassMetrics.stateChange, value: connected)
            .help(connected ? "Connected to Cockpit" : "Searching for Cockpit")
            .accessibilityLabel(connected ? "Connected to Cockpit" : "Not connected to Cockpit")
    }
}

/// The "searching for Cockpit" placeholder. Isolated into its own view so the
/// per-frame `frameCount` updates only re-render this text — not the video or
/// PencilKit canvas siblings.
private struct SearchingOverlay: View {
    var mirror: MirrorModel

    var body: some View {
        let isSearching = mirror.frameCount == 0
        ZStack {
            if isSearching {
                // At large accessibility sizes the message is taller than
                // the band between the floating clusters (top) and the
                // PencilKit palette (bottom): it scrolls inside that band
                // instead of running under both (TYPE-4).
                ViewThatFits(in: .vertical) {
                    placeholder
                    ScrollView { placeholder }
                }
                .padding(.top, Self.topClearance)
                .padding(.bottom, Self.bottomClearance)
                // The mirror stage is always black (a video surface), so the
                // placeholder must stay light-on-dark regardless of system mode.
                .environment(\.colorScheme, .dark)
                .transition(.opacity)
            }
        }
        // Fade the placeholder out as the first frame lands instead of a hard
        // cut (MOT-1 context transition). Keyed on the Bool, so per-frame
        // `frameCount` ticks never start an animation.
        .animation(LiquidGlassMetrics.stateChange, value: isSearching)
    }

    /// Below the floating clusters (48pt circles, 12pt inset, 8pt gap).
    private static let topClearance: CGFloat = 72
    /// Above the PencilKit tool palette docked at the bottom edge.
    private static let bottomClearance: CGFloat = 104

    private var placeholder: some View {
        ContentUnavailableView {
            Label {
                Text("Searching for Cockpit")
            } icon: {
                // The antenna pulses outward while searching: the one
                // designed loading motion (MOT-5, MOT-3), replacing a
                // second competing spinner. Opacity-only, so it stays
                // calm with Reduce Motion.
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .symbolEffect(.variableColor.iterative)
            }
        } description: {
            Text("Make sure Cockpit is running on your Mac, and that both devices are on the same Wi-Fi network with Local Network access enabled for Kneeboard.")
        }
        // A readable measure on a wide iPad stage: the centered
        // description wraps to a few short lines instead of one
        // 110-character line (LAY-6, TYPE-1).
        .frame(maxWidth: 560)
    }
}

// MARK: - Zoomable container

/// Bridges the UIKit ``ZoomableMirrorUIView`` (which owns the video layer, the
/// PencilKit canvas, and the pinch/pan gestures) into SwiftUI.
private struct ZoomableMirrorView: UIViewRepresentable {
    var mirror: MirrorModel
    /// True while a sheet is presented over the mirror.
    var isCovered = false
    /// Receives how far the corner-adapted safe area extends past the plain
    /// safe area on each edge (see ``ZoomableMirrorUIView/cornerInsets``).
    var onCornerInsetsChange: (EdgeInsets) -> Void = { _ in }

    func makeUIView(context: Context) -> ZoomableMirrorUIView {
        let view = ZoomableMirrorUIView()
        mirror.attach(view.sampleBufferDisplayLayer)
        view.onAnnotation = { message in
            mirror.sendAnnotation(message)
        }
        view.onCornerInsetsChange = onCornerInsetsChange
        // Apply undo/clear commands that originate on Pilot to this canvas (the
        // authoritative drawing); the resulting drawing echoes back to Pilot.
        mirror.onRemoteAnnotation = { [weak view] message in
            view?.applyRemoteCommand(message)
        }
        // Every (re)authenticated Pilot session starts from the full drawing:
        // packets queued while disconnected can be dropped, and Pilot may hold
        // ink from an earlier session (issue #431).
        mirror.onCockpitAuthenticated = { [weak view] in
            view?.resyncPilot()
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
        uiView.onCornerInsetsChange = onCornerInsetsChange
        uiView.setToolPickerHidden(isCovered)
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
    static func annotationDrawing(
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
    /// Liquid Glass platter the annotation toolbar floats on.
    private let toolbarGlass = UIVisualEffectView()
    /// Size constraints of the toolbar buttons, rescaled when Dynamic Type
    /// changes (see `updateToolbarButtonSizes()`).
    private var toolbarButtonWidthConstraints: [NSLayoutConstraint] = []
    private var toolbarButtonHeightConstraints: [NSLayoutConstraint] = []
    /// The toolbar's preferred top (12pt below the safe area, level with the
    /// SwiftUI cluster); moved down a row by `updateToolbarRow()` when the
    /// window is too narrow for both clusters side by side.
    private var toolbarTopConstraint: NSLayoutConstraint?

    /// Shown above the (empty) video layer only in demo mode; rides the same
    /// zoom/pan transform so seeded annotation strokes stay aligned.
    private let demoImageView = UIImageView()
    private var isDemoMode = false
    private var hasSeededDemoStrokes = false

    private var toolPicker: PKToolPicker?
    /// Whether ``setToolPickerHidden(_:)`` currently has the picker hidden.
    private var isToolPickerCovered = false

    /// Sends the message that keeps Pilot's ink identical, stroke for stroke,
    /// to this canvas: `.addStroke` / `.undo` only for a provable append or
    /// last-stroke removal (so each line is a discrete entry on Pilot's undo
    /// stack), `.clear`, or a full `.replaceDrawing` for anything else.
    var onAnnotation: ((AnnotationMessage) -> Void)?
    /// The corner-adapted safe area changed; receives ``cornerInsets``.
    var onCornerInsetsChange: ((EdgeInsets) -> Void)?

    /// The safe area adapted (horizontally) to the window's corners, so
    /// floating controls clear the iPadOS window controls in a resizable
    /// window. The annotation toolbar is constrained inside it.
    private static let cornerAdaptedSafeArea = UIView.LayoutRegion.safeArea(cornerAdaptation: .horizontal)
    /// Last value delivered to `onCornerInsetsChange`, to report only changes.
    private var reportedCornerInsets: EdgeInsets?

    /// The normalized strokes Pilot holds after every message sent so far. Each
    /// change is diffed against this (not just the stroke count), so an eraser
    /// removing a middle stroke or an undone erase restoring one resends the
    /// whole drawing instead of being misreported as undo / add (issue #431).
    private var mirroredStrokes: [AnnotationStroke] = []

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
        // Before the constraint pass, so the toolbar lands in its row now.
        updateToolbarRow()
        super.layoutSubviews()
        // The content view fills us; the affine transform handles zoom/pan.
        contentView.frame = bounds
        videoView.frame = contentView.bounds
        demoImageView.frame = contentView.bounds
        canvasView.frame = contentView.bounds
        remapDrawingForCurrentLayoutIfNeeded()
        applyTransform()
        reportCornerInsetsIfChanged()
        // Seed demo strokes once we actually have a non-zero canvas to map
        // them into (layout has run and videoSize is known).
        if isDemoMode, !hasSeededDemoStrokes, videoSize != .zero,
           canvasView.bounds.width > 0 {
            seedDemoStrokes()
            hasSeededDemoStrokes = true
        }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    /// How far the corner-adapted safe area extends past the plain safe area
    /// on each edge, in layout direction. The SwiftUI cluster already honors
    /// the plain safe area, so it only needs this difference: about 66pt at
    /// top-leading in a resizable window (the window controls), and only the
    /// ~9pt display-corner rounding when the window fills the screen.
    var cornerInsets: EdgeInsets {
        let adapted = directionalEdgeInsets(for: Self.cornerAdaptedSafeArea)
        let plain = NSDirectionalEdgeInsets(
            top: safeAreaInsets.top,
            leading: effectiveUserInterfaceLayoutDirection == .rightToLeft ? safeAreaInsets.right : safeAreaInsets.left,
            bottom: safeAreaInsets.bottom,
            trailing: effectiveUserInterfaceLayoutDirection == .rightToLeft ? safeAreaInsets.left : safeAreaInsets.right
        )
        return EdgeInsets(
            top: max(0, adapted.top - plain.top),
            leading: max(0, adapted.leading - plain.leading),
            bottom: max(0, adapted.bottom - plain.bottom),
            trailing: max(0, adapted.trailing - plain.trailing)
        )
    }

    /// Delivers ``cornerInsets`` after a layout pass that changed them. The
    /// callback updates SwiftUI state, so it is deferred out of layout.
    private func reportCornerInsetsIfChanged() {
        guard window != nil else { return }
        let insets = cornerInsets
        guard insets != reportedCornerInsets else { return }
        reportedCornerInsets = insets
        DispatchQueue.main.async { [weak self] in
            self?.onCornerInsetsChange?(insets)
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
        mirroredStrokes = normalizedStrokes()
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

    /// Hides the tool picker while SwiftUI presents a sheet over the mirror,
    /// and restores it (with the canvas as first responder) afterwards. Acts
    /// only on cover/uncover transitions, so routine `updateUIView` passes
    /// never fight the picker's own state.
    func setToolPickerHidden(_ hidden: Bool) {
        guard hidden != isToolPickerCovered, let toolPicker else { return }
        isToolPickerCovered = hidden
        toolPicker.setVisible(!hidden, forFirstResponder: canvasView)
        if !hidden { canvasView.becomeFirstResponder() }
    }

    private func installToolPicker(for canvasView: PKCanvasView) {
        let picker = PKToolPicker()
        picker.addObserver(canvasView)
        picker.setVisible(true, forFirstResponder: canvasView)
        toolPicker = picker
    }

    private func setupToolbar() {
        toolbar.axis = .horizontal
        toolbar.spacing = 0
        toolbar.alignment = .center
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.isLayoutMarginsRelativeArrangement = true
        // No vertical margin: the buttons themselves are the capsule height
        // (48pt at the default size, on the 4pt grid), which keeps the
        // toolbar level with the SwiftUI cluster's 48pt circles.
        toolbar.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 0,
            leading: LiquidGlassMetrics.Spacing.xxSmall,
            bottom: 0,
            trailing: LiquidGlassMetrics.Spacing.xxSmall
        )

        // Floating controls over the mirror use interactive Liquid Glass in a
        // capsule, matching the SwiftUI settings cluster on the leading side.
        let glass = UIGlassEffect(style: .regular)
        glass.isInteractive = true
        toolbarGlass.effect = glass
        toolbarGlass.cornerConfiguration = .capsule()
        // Pinned dark like the SwiftUI cluster: the mirror stage behind it is
        // always black, and `.label` glyphs then resolve light on dark glass.
        toolbarGlass.overrideUserInterfaceStyle = .dark
        // Same Dynamic Type ceiling as the SwiftUI cluster, so both clusters
        // stop growing together; the glyphs' text-style symbol configuration
        // honors it too.
        toolbarGlass.maximumContentSizeCategory = FloatingChromeMetrics.maximumContentSizeCategory
        toolbarGlass.translatesAutoresizingMaskIntoConstraints = false
        toolbarGlass.contentView.addSubview(toolbar)

        let undoButton = button(systemName: "arrow.uturn.backward", label: "Undo") { [weak self] in
            self?.canvasView.undoManager?.undo()
        }
        let clearButton = button(systemName: "trash", label: "Clear Annotations") { [weak self] in
            self?.clearCanvas()
        }
        // Close: clears the canvas and dismisses the drawing pane on Pilot. The
        // remote-ink overlay on Pilot is shown only while ink is present, so the
        // `.clear` that `clearCanvas()` sends both empties and closes it.
        let closeButton = button(systemName: "xmark", label: "Close Drawing") { [weak self] in
            self?.clearCanvas()
        }
        let resetZoomButton = button(systemName: "arrow.up.left.and.arrow.down.right", label: "Reset Zoom") { [weak self] in
            self?.resetZoom()
        }
        toolbar.addArrangedSubview(resetZoomButton)
        toolbar.addArrangedSubview(undoButton)
        toolbar.addArrangedSubview(clearButton)
        toolbar.addArrangedSubview(closeButton)

        // The toolbar stays fixed (not inside the transformable content view).
        addSubview(toolbarGlass)
        let cornerSafeArea = layoutGuide(for: Self.cornerAdaptedSafeArea)
        let toolbarTop = toolbarGlass.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: LiquidGlassMetrics.Spacing.small)
        toolbarTopConstraint = toolbarTop
        let toolbarTrailing = toolbarGlass.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -LiquidGlassMetrics.Spacing.small)
        toolbarTop.priority = .defaultHigh
        toolbarTrailing.priority = .defaultHigh
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: toolbarGlass.contentView.topAnchor),
            toolbar.bottomAnchor.constraint(equalTo: toolbarGlass.contentView.bottomAnchor),
            toolbar.leadingAnchor.constraint(equalTo: toolbarGlass.contentView.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: toolbarGlass.contentView.trailingAnchor),
            // 12pt inside the safe area, matching the SwiftUI cluster, but
            // never outside the corner-adapted safe area: if a window corner
            // ever carries chrome on this side, the toolbar moves clear of it
            // (the same rule as `FloatingChromeMetrics.clusterPadding`). The
            // window controls sit top-leading today, so this side normally
            // only sees the ~9pt corner rounding, which the 12pt clears.
            toolbarTop,
            toolbarTrailing,
            toolbarGlass.topAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.topAnchor, constant: LiquidGlassMetrics.Spacing.small),
            toolbarGlass.topAnchor.constraint(greaterThanOrEqualTo: cornerSafeArea.topAnchor),
            toolbarGlass.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -LiquidGlassMetrics.Spacing.small),
            toolbarGlass.trailingAnchor.constraint(lessThanOrEqualTo: cornerSafeArea.trailingAnchor)
        ])

        updateToolbarButtonSizes()
        toolbarGlass.registerForTraitChanges(
            [UITraitPreferredContentSizeCategory.self]
        ) { [weak self] (_: UIVisualEffectView, _: UITraitCollection) in
            self?.updateToolbarButtonSizes()
            self?.setNeedsLayout()
        }
    }

    /// Scales the toolbar buttons with Dynamic Type exactly like the SwiftUI
    /// cluster's `@ScaledMetric`, using the glass view's (clamped) traits.
    private func updateToolbarButtonSizes() {
        let traits = toolbarGlass.traitCollection
        let width = FloatingChromeMetrics.scaled(FloatingChromeMetrics.baseToolbarButtonWidth, for: traits)
        let height = FloatingChromeMetrics.scaled(FloatingChromeMetrics.baseControlSide, for: traits)
        toolbarButtonWidthConstraints.forEach { $0.constant = width }
        toolbarButtonHeightConstraints.forEach { $0.constant = height }
    }

    /// Keeps the annotation toolbar level with the SwiftUI cluster when both
    /// fit across the window, and otherwise drops it to a second row just
    /// below the cluster. A narrow resizable window at the larger Dynamic
    /// Type sizes cannot hold both rows side by side, and the cluster also
    /// steps in past the window controls there; without this the two
    /// clusters overlap.
    private func updateToolbarRow() {
        guard let toolbarTopConstraint else { return }
        let traits = toolbarGlass.traitCollection
        let side = FloatingChromeMetrics.scaled(FloatingChromeMetrics.baseControlSide, for: traits)
        let buttonWidth = FloatingChromeMetrics.scaled(FloatingChromeMetrics.baseToolbarButtonWidth, for: traits)
        let toolbarWidth = CGFloat(toolbar.arrangedSubviews.count) * buttonWidth
            + toolbar.directionalLayoutMargins.leading + toolbar.directionalLayoutMargins.trailing
        let clusterPadding = FloatingChromeMetrics.clusterPadding(cornerInsets: cornerInsets)
        let spacing = LiquidGlassMetrics.Spacing.small
        let needed = clusterPadding.leading + FloatingChromeMetrics.clusterWidth(controlSide: side)
            + spacing + toolbarWidth + spacing
        let available = bounds.width - safeAreaInsets.left - safeAreaInsets.right
        let top = needed <= available
            ? spacing
            : clusterPadding.top + side + LiquidGlassMetrics.Spacing.xSmall
        if toolbarTopConstraint.constant != top {
            toolbarTopConstraint.constant = top
        }
    }

    /// Empties this canvas and tells Pilot to clear too (sends a single
    /// `.clear`). Used by both the trash and close buttons; the latter relies on
    /// the clear to also dismiss Pilot's ink overlay, which is ink-gated.
    private func clearCanvas() {
        // Suppress the diff handler so we send a single `.clear` rather than an
        // empty resync as well.
        isApplyingProgrammaticChange = true
        canvasView.drawing = PKDrawing()
        updateCanvasAccessibilityValue()
        isApplyingProgrammaticChange = false
        mirroredStrokes = []
        onAnnotation?(.clear)
    }

    /// An icon button for the glass toolbar (44 x 48pt at the default size,
    /// scaled by `updateToolbarButtonSizes()`): Dynamic Type symbol sizing, a
    /// label-colored glyph that adapts with the glass, a spoken name, and
    /// pointer hover on iPad trackpads.
    private func button(systemName: String, label: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(textStyle: .title3), forImageIn: .normal)
        button.tintColor = .label
        button.accessibilityLabel = label
        button.isPointerInteractionEnabled = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        let width = button.widthAnchor.constraint(equalToConstant: FloatingChromeMetrics.baseToolbarButtonWidth)
        let height = button.heightAnchor.constraint(equalToConstant: FloatingChromeMetrics.baseControlSide)
        NSLayoutConstraint.activate([width, height])
        toolbarButtonWidthConstraints.append(width)
        toolbarButtonHeightConstraints.append(height)
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
        updateCanvasAccessibilityValue()
        // Programmatic changes (remote command / layout remap) send their own
        // full resync once the mutation is complete.
        guard !isApplyingProgrammaticChange else { return }
        syncPilot()
    }

    /// Applies an annotation command sent by Pilot to this (authoritative)
    /// canvas, then echoes the resulting drawing. Pilot already changed its
    /// copy optimistically, but the canvas undo may not remove the newest
    /// stroke (it can undo an erase), and a stroke from this canvas may have
    /// crossed the command in flight, so only a full resync converges.
    func applyRemoteCommand(_ message: AnnotationMessage) {
        isApplyingProgrammaticChange = true
        switch message {
        case .undo:
            canvasView.undoManager?.undo()
        case .clear:
            canvasView.drawing = PKDrawing()
        case .addStroke, .replaceDrawing:
            // Pilot only sends undo / clear commands to the canvas.
            isApplyingProgrammaticChange = false
            return
        }
        updateCanvasAccessibilityValue()
        isApplyingProgrammaticChange = false
        resyncPilot()
    }

    /// The canvas drawing in Pilot's normalized annotation coordinates.
    private func normalizedStrokes() -> [AnnotationStroke] {
        let contentRect = PlotterGeometry.aspectFitRect(contentSize: videoSize, in: canvasView.bounds)
        return ZoomableMirrorView.annotationDrawing(from: canvasView.drawing, contentRect: contentRect).strokes
    }

    /// Sends the one message that makes Pilot's ink match this canvas, if any.
    private func syncPilot() {
        let current = normalizedStrokes()
        guard let message = AnnotationMirrorSync.message(from: mirroredStrokes, to: current) else { return }
        mirroredStrokes = current
        onAnnotation?(message)
    }

    /// Replaces Pilot's ink with this canvas's full drawing, unconditionally.
    /// Used after Pilot authenticates, after Pilot-originated edits, and after
    /// a layout re-anchor.
    func resyncPilot() {
        let current = normalizedStrokes()
        mirroredStrokes = current
        onAnnotation?(.replaceDrawing(AnnotationDrawing(strokes: current)))
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
        updateCanvasAccessibilityValue()
        isApplyingProgrammaticChange = false

        // Pilot stores normalized drawing data. Send exactly one replacement
        // after a real canvas mapping so both sides remain authoritative.
        resyncPilot()
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
