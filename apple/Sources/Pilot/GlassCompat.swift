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
