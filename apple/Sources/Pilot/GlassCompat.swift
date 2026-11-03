import AppKit
import SwiftUI

/// Liquid Glass shipped in macOS 26, and Pilot deploys back to macOS 15.
/// These wrappers keep the glass look where it exists and fall back to a
/// material fill in the same shape (plus a tint wash) on older systems.
extension View {
    @ViewBuilder
    func compatGlassEffect(
        tint: Color? = nil,
        interactive: Bool = false,
        in shape: some Shape
    ) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    if let tint {
                        shape.fill(tint)
                    }
                }
            }
        }
    }

    /// A secondary glass button. Always a capsule: on macOS the glass styles
    /// otherwise default to a rounded rectangle, which reads as a squared
    /// control next to the capsule fields and chips. The shape is applied
    /// innermost, so it wins over any outer `buttonBorderShape`; icon-only
    /// circles use `compatGlassIconButton` instead.
    @ViewBuilder
    func compatGlassButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonBorderShape(.capsule).buttonStyle(.glass)
        } else {
            buttonBorderShape(.capsule).buttonStyle(.bordered)
        }
    }

    /// The single primary action in a view (BTN-1): tinted Liquid Glass on
    /// macOS 26, the prominent bordered style before it. Always a capsule,
    /// like `compatGlassButtonStyle`. The fill is the legible accent
    /// (`LegibleAccent`), so the white label clears TYPE-3 for every system
    /// accent; the tint sits innermost, so an outer `.tint` does not reach
    /// it. Destructive actions stay secondary glass with a red label.
    @ViewBuilder
    func compatGlassProminentButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonBorderShape(.capsule).buttonStyle(.glassProminent).tint(LegibleAccent.color)
        } else {
            buttonBorderShape(.capsule).buttonStyle(.borderedProminent).tint(LegibleAccent.color)
        }
    }

    /// The system segmented control with a selected segment whose white
    /// label stays legible. Use it for every segmented `Picker` in Cockpit.
    /// White on the plain accent measured 3.79:1 (dark) and 4.26:1 (light)
    /// on the inspector tabs; `.tint` on a segmented `Picker` sets the
    /// backing `NSSegmentedControl.selectedSegmentBezelColor`, so the
    /// selected fill becomes `LegibleAccent.color`.
    func legibleSegmentedPicker() -> some View {
        pickerStyle(.segmented)
            .tint(LegibleAccent.color)
    }
}

struct PilotSegmentedMenuItem {
    let title: String
    let isEnabled: Bool
    let isDestructive: Bool
    let action: () -> Void

    init(
        _ title: String,
        isEnabled: Bool = true,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.isEnabled = isEnabled
        self.isDestructive = isDestructive
        self.action = action
    }
}

@MainActor
final class PilotNativeSegmentedControl: NSSegmentedControl {
    var onDrop: ((NSPasteboard, Int) -> Bool)?
    /// When false, a click selects its segment on mouse-down instead of
    /// running AppKit's press tracking. That tracking lifts the pressed glass
    /// pill from 16pt to 26pt, past a small control's 20pt bounds, so the
    /// control appears to change height on every click. The pill still
    /// slides to its new segment. Opt-out only: it bypasses press-and-hold
    /// segment menus and drags that start on the control.
    var liftsOnPress = true
    var showsCloseButton = false
    var isCloseHovering = false
    var isCloseEnabled = true
    private var closeTrackingArea: NSTrackingArea?
    /// Alpha the close button is resting at or fading toward.
    private var closeButtonTargetAlpha: CGFloat = 0

    /// Side of the close button and of the transparent image slot reserved
    /// for it at the start of every segment.
    static let closeSlotSize: CGFloat = 16

    /// Where AppKit draws a left-aligned segment image, measured from the
    /// segment's leading edge (macOS 26+ capsule style, `.fillEqually`).
    private var imageLeadingInset: CGFloat {
        controlSize == .regular || controlSize == .large || controlSize == .extraLarge ? 14 : 12
    }

    /// Matches the workspace pane tabs: a small bold glyph on a circular
    /// tertiary fill, sized to the slot instead of scaled up to fill it.
    lazy var closeButton: NSButton = {
        let button = NSButton()
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .bold))
        button.image?.isTemplate = true
        button.imageScaling = .scaleNone
        button.contentTintColor = NSColor.secondaryLabelColor
        button.wantsLayer = true
        button.layer?.cornerRadius = Self.closeSlotSize / 2
        button.alphaValue = 0
        return button
    }()

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateCloseButtonFill()
    }

    private func updateCloseButtonFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            closeButton.layer?.backgroundColor = NSColor.tertiarySystemFill.cgColor
        }
    }

    override func layout() {
        super.layout()
        updateCloseButton()
    }

    override func mouseDown(with event: NSEvent) {
        guard !liftsOnPress else { return super.mouseDown(with: event) }
        guard isEnabled, segmentCount > 0, bounds.width > 0 else { return }
        let location = convert(event.locationInWindow, from: nil)
        let segment = min(max(0, Int(location.x * CGFloat(segmentCount) / bounds.width)), segmentCount - 1)
        guard isEnabled(forSegment: segment), segment != selectedSegment else { return }
        // Implicit animation keeps the glass pill's slide between segments.
        NSAnimationContext.runAnimationGroup { context in
            context.allowsImplicitAnimation = true
            selectedSegment = segment
        }
        sendAction(action, to: target)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateCloseButton()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let closeTrackingArea { removeTrackingArea(closeTrackingArea) }
        closeTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        if let closeTrackingArea { addTrackingArea(closeTrackingArea) }
    }

    override func mouseEntered(with event: NSEvent) {
        isCloseHovering = true
        updateCloseButton()
    }

    override func mouseExited(with event: NSEvent) {
        isCloseHovering = false
        updateCloseButton()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDrop == nil ? [] : .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDrop == nil ? [] : .move
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard segmentCount > 0, bounds.width > 0 else { return false }
        let location = convert(sender.draggingLocation, from: nil)
        let segment = min(max(0, Int(location.x * CGFloat(segmentCount) / bounds.width)), segmentCount - 1)
        return onDrop?(sender.draggingPasteboard, segment) ?? false
    }

    func updateCloseButton() {
        let isVisible = showsCloseButton && isCloseHovering && selectedSegment >= 0 && segmentCount > 0
        closeButton.isHidden = !showsCloseButton || selectedSegment < 0
        closeButton.isEnabled = isVisible && isCloseEnabled
        if isVisible {
            // Sits on the selected segment's reserved image slot, inside the
            // segment and to the left of its title.
            let segmentWidth = bounds.width / CGFloat(segmentCount)
            let side = Self.closeSlotSize
            closeButton.frame = NSRect(
                x: segmentWidth * CGFloat(selectedSegment) + imageLeadingInset,
                y: (bounds.height - side) / 2,
                width: side,
                height: side
            )
            updateCloseButtonFill()
        }
        // `layout()` and every SwiftUI update call this; start a fade only
        // when visibility actually flips.
        let targetAlpha: CGFloat = isVisible ? 1 : 0
        guard closeButtonTargetAlpha != targetAlpha else { return }
        closeButtonTargetAlpha = targetAlpha
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            closeButton.animator().alphaValue = targetAlpha
        }
    }
}

/// AppKit's native single-select segmented control, with the Liquid Glass
/// appearance supplied by macOS 26 and the standard bezel on earlier systems.
struct PilotSegmentedControl<Value: Hashable>: NSViewRepresentable {
    @Binding var selection: Value
    let accessibilityLabel: String
    let options: [Value]
    let title: (Value) -> String
    let systemImage: (Value) -> String?
    let showsTitles: Bool
    let controlSize: NSControl.ControlSize
    let liftsOnPress: Bool
    let menuItems: ((Value) -> [PilotSegmentedMenuItem])?
    let dropTypes: [NSPasteboard.PasteboardType]
    let onDrop: ((NSPasteboard, Int) -> Bool)?
    let closeLabel: String
    let canClose: ((Value) -> Bool)?
    let onClose: ((Value) -> Void)?

    init(
        _ accessibilityLabel: String,
        selection: Binding<Value>,
        options: [Value],
        title: @escaping (Value) -> String,
        systemImage: @escaping (Value) -> String? = { _ in nil },
        showsTitles: Bool = true,
        controlSize: NSControl.ControlSize = .regular,
        liftsOnPress: Bool = true,
        menuItems: ((Value) -> [PilotSegmentedMenuItem])? = nil,
        dropTypes: [NSPasteboard.PasteboardType] = [.string],
        onDrop: ((NSPasteboard, Int) -> Bool)? = nil,
        closeLabel: String = "Close",
        canClose: ((Value) -> Bool)? = nil,
        onClose: ((Value) -> Void)? = nil
    ) {
        _selection = selection
        self.accessibilityLabel = accessibilityLabel
        self.options = options
        self.title = title
        self.systemImage = systemImage
        self.showsTitles = showsTitles
        self.controlSize = controlSize
        self.liftsOnPress = liftsOnPress
        self.menuItems = menuItems
        self.dropTypes = dropTypes
        self.onDrop = onDrop
        self.closeLabel = closeLabel
        self.canClose = canClose
        self.onClose = onClose
    }

    func makeNSView(context: Context) -> PilotNativeSegmentedControl {
        let control = PilotNativeSegmentedControl(
            labels: options.map { _ in "" },
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectSegment(_:))
        )
        control.segmentStyle = .capsule
        if #available(macOS 26.0, *) {
            control.borderShape = .capsule
        }
        // The tabs role is what draws the Liquid Glass track and pill; the
        // default role falls back to the flat bezel with separators.
        if #available(macOS 27.0, *) {
            control.role = .tabs
        }
        if onDrop != nil {
            control.registerForDraggedTypes(dropTypes)
        }
        if onClose != nil {
            control.closeButton.target = context.coordinator
            control.closeButton.action = #selector(Coordinator.closeSelected(_:))
            control.addSubview(control.closeButton)
        }
        control.segmentDistribution = .fillEqually
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        configure(control, coordinator: context.coordinator)
        return control
    }

    func updateNSView(_ control: PilotNativeSegmentedControl, context: Context) {
        configure(control, coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(options: options, selection: $selection, menuItems: menuItems)
    }

    private static var closeSlotImage: NSImage {
        let side = PilotNativeSegmentedControl.closeSlotSize
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in true }
    }

    /// What one segment draws. `configure` runs on every SwiftUI update,
    /// including the one a selection change causes, so segments are rewritten
    /// only when this changes. Re-setting labels, images and menus invalidated
    /// the control mid-switch and stalled the pill's slide.
    struct SegmentContent: Equatable {
        struct MenuItem: Equatable {
            let title: String
            let isEnabled: Bool
            let isDestructive: Bool
        }

        let title: String
        let systemImage: String?
        let menu: [MenuItem]?
    }

    struct AppliedContent: Equatable {
        let segments: [SegmentContent]
        let showsTitles: Bool
        let reservesCloseSlot: Bool
    }

    private func configure(_ control: PilotNativeSegmentedControl, coordinator: Coordinator) {
        coordinator.options = options
        coordinator.selection = $selection
        coordinator.menuItems = menuItems
        coordinator.onClose = onClose
        control.onDrop = onDrop
        control.liftsOnPress = liftsOnPress
        control.showsCloseButton = onClose != nil
        if control.controlSize != controlSize { control.controlSize = controlSize }
        control.setAccessibilityLabel(accessibilityLabel)

        let content = AppliedContent(
            segments: options.map { option in
                SegmentContent(
                    title: title(option),
                    systemImage: systemImage(option),
                    menu: menuItems.map { items in
                        items(option).map {
                            SegmentContent.MenuItem(
                                title: $0.title,
                                isEnabled: $0.isEnabled,
                                isDestructive: $0.isDestructive
                            )
                        }
                    }
                )
            },
            showsTitles: showsTitles,
            reservesCloseSlot: onClose != nil
        )
        if coordinator.appliedContent != content {
            coordinator.appliedContent = content
            applySegments(content, to: control, coordinator: coordinator)
        }

        let selectedIndex = options.firstIndex(of: selection) ?? -1
        if control.selectedSegment != selectedIndex { control.selectedSegment = selectedIndex }
        control.closeButton.setAccessibilityLabel(closeLabel)
        control.isCloseEnabled = canClose?(selection) ?? true
        control.updateCloseButton()
    }

    private func applySegments(
        _ content: AppliedContent,
        to control: PilotNativeSegmentedControl,
        coordinator: Coordinator
    ) {
        if control.segmentCount != content.segments.count { control.segmentCount = content.segments.count }
        for (index, segment) in content.segments.enumerated() {
            let title = segment.title
            control.setLabel(content.showsTitles ? title : "", forSegment: index)
            control.setToolTip(title, forSegment: index)
            if let symbol = segment.systemImage {
                let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
                image?.isTemplate = true
                control.setImage(image, forSegment: index)
            } else if content.reservesCloseSlot {
                // An empty slot the close button covers on hover. Every
                // segment reserves it, so titles never shift or overlap.
                control.setImage(Self.closeSlotImage, forSegment: index)
                control.setImageScaling(.scaleNone, forSegment: index)
            } else {
                control.setImage(nil, forSegment: index)
            }
            // Leading content, like the workspace pane tabs, so the slot sits
            // at a known offset from the segment's edge.
            control.setAlignment(content.reservesCloseSlot ? .left : .center, forSegment: index)
            if let items = segment.menu {
                let menu = NSMenu()
                for (itemIndex, item) in items.enumerated() {
                    let menuItem = NSMenuItem(
                        title: item.title,
                        action: #selector(Coordinator.selectMenuItem(_:)),
                        keyEquivalent: ""
                    )
                    menuItem.target = coordinator
                    menuItem.tag = index
                    menuItem.representedObject = itemIndex
                    menuItem.isEnabled = item.isEnabled
                    if item.isDestructive {
                        menuItem.attributedTitle = NSAttributedString(
                            string: item.title,
                            attributes: [.foregroundColor: NSColor.systemRed]
                        )
                    }
                    menu.addItem(menuItem)
                }
                control.setMenu(menu, forSegment: index)
            } else {
                control.setMenu(nil, forSegment: index)
            }
        }
    }

    @MainActor final class Coordinator: NSObject {
        var options: [Value]
        var selection: Binding<Value>
        var menuItems: ((Value) -> [PilotSegmentedMenuItem])?
        var onClose: ((Value) -> Void)?
        /// Last segment content written to the control; see `SegmentContent`.
        var appliedContent: AppliedContent?

        init(
            options: [Value],
            selection: Binding<Value>,
            menuItems: ((Value) -> [PilotSegmentedMenuItem])?
        ) {
            self.options = options
            self.selection = selection
            self.menuItems = menuItems
        }

        @objc func selectSegment(_ sender: NSSegmentedControl) {
            guard options.indices.contains(sender.selectedSegment) else { return }
            // Commit the pill's slide to the render server before the
            // selection change reaches SwiftUI. Whatever the new selection
            // rebuilds (the Notes editor restyles a whole document) then runs
            // after the animation has started instead of delaying its first
            // frame.
            sender.displayIfNeeded()
            CATransaction.flush()
            selection.wrappedValue = options[sender.selectedSegment]
        }

        @objc func selectMenuItem(_ sender: NSMenuItem) {
            guard options.indices.contains(sender.tag),
                  let itemIndex = sender.representedObject as? Int,
                  let items = menuItems?(options[sender.tag]),
                  items.indices.contains(itemIndex) else { return }
            items[itemIndex].action()
        }

        @objc func closeSelected(_ sender: NSButton) {
            guard let control = sender.superview as? PilotNativeSegmentedControl,
                  options.indices.contains(control.selectedSegment) else { return }
            onClose?(options[control.selectedSegment])
        }
    }
}

extension View {
    /// Glass for a floating control cluster in a capsule — toolbars, pane
    /// headers, and overlay controls. Never for content surfaces.
    func compatGlassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        compatGlassEffect(tint: tint, interactive: interactive, in: Capsule())
    }

    /// Glass for a control layer that floats over arbitrary content (ink
    /// toolbars, toasts, quick-open palettes). Liquid Glass casts its own
    /// depth, so macOS 26 adds no shadow; the macOS 15 fallback keeps the
    /// opaque-enough `.regularMaterial` plus drop shadow these overlays
    /// always used, so text stays legible over busy panes.
    @ViewBuilder
    func compatFloatingGlass(in shape: some Shape) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        }
    }

    func compatFloatingGlassCapsule() -> some View {
        compatFloatingGlass(in: Capsule())
    }

    /// Icon-only circular glass button with a consistent control size, for
    /// pane headers and overlay clusters (not toolbar items, which get system
    /// glass). Label the button with `Label(_:systemImage:)` so VoiceOver
    /// keeps a name. Delegates to the shared `liquidGlassIconButton`, which
    /// carries the same pre-26 bordered fallback as the helpers above.
    ///
    /// Fields, segmented controls, chips, and pressable rows use the shared
    /// helpers in Sources/Shared/LiquidGlassStyles.swift directly.
    func compatGlassIconButton(
        prominent: Bool = false,
        controlSize: ControlSize = .regular
    ) -> some View {
        liquidGlassIconButton(prominent: prominent, controlSize: controlSize)
    }
}

extension ToolbarContent {
    /// Hides the system toolbar capsule behind an item whose control carries
    /// its own glass (a `liquidGlassField`), so the toolbar never stacks glass
    /// on glass. Before macOS 26 toolbars draw no shared capsule, so the item
    /// is returned unchanged.
    @ToolbarContentBuilder
    func compatSharedBackgroundHidden() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

/// Text levels for copy that sits directly on Liquid Glass.
enum GlassLegibleText {
    case primary
    case secondary
}

extension View {
    /// Draws text on glass in a fixed gray per appearance instead of a
    /// vibrant label color. Glass blends `.primary` and `.secondary` toward
    /// whatever is behind it, which measured 4.2:1 for the unfocused URL text
    /// and 3.2:1 for quick-open paths in dark mode (TYPE-3 needs 4.5:1). The
    /// grays keep the two levels apart while clearing 4.5:1 on light and dark
    /// glass.
    func glassLegibleForeground(_ level: GlassLegibleText) -> some View {
        modifier(GlassLegibleForeground(level: level))
    }
}

private struct GlassLegibleForeground: ViewModifier {
    let level: GlassLegibleText
    @Environment(\.backgroundProminence) private var backgroundProminence

    func body(content: Content) -> some View {
        // On an emphasized selection (a key sidebar's accent row) the system
        // styles already switch to light text; a fixed gray would not.
        if backgroundProminence == .increased {
            switch level {
            case .primary: content.foregroundStyle(.primary)
            case .secondary: content.foregroundStyle(.secondary)
            }
        } else {
            switch level {
            case .primary: content.foregroundStyle(GlassLegibleText.primaryColor)
            case .secondary: content.foregroundStyle(GlassLegibleText.secondaryColor)
            }
        }
    }
}

extension GlassLegibleText {
    /// Appearance-resolved, so a subtree that forces the dark scheme (the
    /// device stage headers) still gets its own appearance's gray.
    static let primaryColor = Color(nsColor: NSColor(name: nil) { appearance in
        isDark(appearance) ? NSColor(white: 0.95, alpha: 1) : NSColor(white: 0.1, alpha: 1)
    })
    static let secondaryColor = Color(nsColor: NSColor(name: nil) { appearance in
        isDark(appearance) ? NSColor(white: 0.68, alpha: 1) : NSColor(white: 0.36, alpha: 1)
    })

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark,
                                    .accessibilityHighContrastAqua,
                                    .accessibilityHighContrastDarkAqua]).map {
            $0 == .darkAqua || $0 == .vibrantDark || $0 == .accessibilityHighContrastDarkAqua
        } ?? false
    }
}

extension View {
    /// Makes `.secondary` resolve to the legible gray for this subtree.
    /// System secondary text measured 3.1:1 on the inspector's glass and
    /// 3.95:1 on white, and `ContentUnavailableView` draws both its title and
    /// its description in it, so every empty and error state failed TYPE-3.
    /// Primary stays the system primary; views that set their own style keep it.
    func legibleSecondaryHierarchy() -> some View {
        foregroundStyle(HierarchicalShapeStyle.primary, GlassLegibleText.secondaryColor)
    }
}

extension View {
    /// Reports whether this `TextField` is being edited, read from AppKit's
    /// first responder. `@FocusState` never updates for a field hosted in an
    /// `NSToolbar` item (verified on macOS 27.2: clicking and typing in the
    /// field leaves it `false`), so toolbar glass fields drive their focus
    /// stroke (FORM-4) and editing state from this instead. Apply it directly
    /// to the `TextField`, before any padding, so the probe covers exactly
    /// the AppKit field it identifies.
    func toolbarFieldEditing(_ isEditing: Binding<Bool>) -> some View {
        background(ToolbarFieldEditingProbe(isEditing: isEditing))
    }

    /// Keeps AppKit's field editor from painting an opaque rectangle inside a
    /// glass capsule while this `TextField` is edited. In a sidebar `List`
    /// row the shared field editor draws the text background color, which
    /// showed as a black (dark) or white (light) box inside the inline rename
    /// capsule. Apply it directly to the `TextField`, like
    /// `toolbarFieldEditing(_:)`.
    func clearsFieldEditorBackground() -> some View {
        background(ToolbarFieldEditingProbe(isEditing: nil, clearsEditorBackground: true))
    }
}

/// A click-through view behind a toolbar `TextField` that watches its
/// window's first responder (KVO-compliant per NSWindow.h). The field is
/// editing when the first responder is the AppKit text field under the
/// probe, or the field editor working for it.
private struct ToolbarFieldEditingProbe: NSViewRepresentable {
    let isEditing: Binding<Bool>?
    var clearsEditorBackground = false

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onChange = isEditing.map { binding in { binding.wrappedValue = $0 } }
        view.clearsEditorBackground = clearsEditorBackground
    }

    final class ProbeView: NSView {
        var onChange: ((Bool) -> Void)?
        var clearsEditorBackground = false
        private var observation: NSKeyValueObservation?
        private var reported = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation?.invalidate()
            observation = window?.observe(\.firstResponder, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
            // Leaving the window ends editing; refresh after this layout pass
            // so the binding is never written during a view update.
            Task { @MainActor [weak self] in self?.refresh() }
        }

        private func refresh() {
            let editing = window.flatMap { Self.editedField(of: $0.firstResponder) }
                .map(isUnderProbe) ?? false
            // AppKit configures the shared field editor when editing begins,
            // so clear its background only after it is working for this field.
            if editing, clearsEditorBackground,
               let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor {
                editor.drawsBackground = false
                editor.backgroundColor = .clear
            }
            guard editing != reported else { return }
            reported = editing
            onChange?(editing)
        }

        private static func editedField(of responder: NSResponder?) -> NSTextField? {
            if let field = responder as? NSTextField { return field }
            if let editor = responder as? NSTextView, editor.isFieldEditor {
                return editor.delegate as? NSTextField
            }
            return nil
        }

        private func isUnderProbe(_ field: NSTextField) -> Bool {
            guard field.window === window else { return false }
            let probe = convert(bounds, to: nil)
            return field.convert(field.bounds, to: nil)
                .contains(CGPoint(x: probe.midX, y: probe.midY))
        }
    }
}

/// A horizontally scrolling strip of glass chips (note tabs, remote desktop
/// groups, runner sources). A scroll view clips to its bounds, which cut the
/// chips' glass shadow into a hard-edged gray rectangle in light mode. The
/// content is inset by the shadow's reach and the scroll view is pulled back
/// out by the same amount, so the shadow fades out naturally and the strip
/// keeps its layout. The trailing edge stays put so overflowing chips never
/// draw over the controls beside the strip.
struct GlassChipScroller<Content: View>: View {
    var spacing: CGFloat? = LiquidGlassMetrics.Spacing.xSmall
    @ViewBuilder var content: Content

    private let bleed = LiquidGlassMetrics.Spacing.medium

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            CompatGlassContainer(spacing: spacing) { content }
                .padding(bleed)
        }
        .padding(.vertical, -bleed)
        .padding(.leading, -bleed)
    }
}

/// `GlassEffectContainer` only coordinates blending between neighboring glass
/// shapes, so the macOS 15 fallback is simply the content itself.
struct CompatGlassContainer<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// The shared glass tab/chip shape used by tab strips (Remote Desktop groups,
/// Notes), so tabs, icon buttons, and labeled actions share one height and radius.
struct GlassChip: ViewModifier {
    var tint: Color?
    static let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Self.shape)
            .compatGlassEffect(tint: tint, interactive: true, in: Self.shape)
    }
}

extension View {
    func glassChip(tint: Color? = nil) -> some View { modifier(GlassChip(tint: tint)) }
}

/// An icon sized to a text line, so icon-only chips match labeled ones.
struct GlassChipIcon: View {
    let systemName: String

    var body: some View {
        Text(verbatim: "M")
            .hidden()
            .overlay { Image(systemName: systemName) }
            .accessibilityHidden(true)
    }
}
