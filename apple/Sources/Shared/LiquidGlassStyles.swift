import SwiftUI

// Cross-platform Liquid Glass building blocks shared by Cockpit (Pilot,
// macOS), Walkie (Copilot, iOS), and Kneeboard (Plotter, iPadOS).
//
// Rules of thumb (zandesign checks in parentheses):
// - Glass is the control/navigation layer floating over content. Never put it
//   on content cards, and never stack glass on glass; group neighbors in a
//   `GlassEffectContainer` (or Pilot's `CompatGlassContainer`).
// - One primary action per view uses the prominent style (BTN-1).
// - Spacing sits on the 4pt grid (LAY-3); nested corners are concentric
//   (LAY-4) — prefer `ConcentricRectangle`/`containerShape`, otherwise
//   `LiquidGlassMetrics.Radius.inner(outer:padding:)`.
// - Prefer the system `Picker` with `.pickerStyle(.segmented)` (a capsule
//   glass control on 26+). Reach for `LiquidGlassSegmentedControl` only when
//   segments need icons, counts, or other custom content.
//
// Every 26-only API sits behind `#available(iOS 26.0, macOS 26.0, *)` with a
// material fallback in the same shape, matching Pilot's GlassCompat, so the
// macOS floor can drop to 15 without touching call sites.

// MARK: - Metrics

/// Shared spacing, radius, and motion tokens for glass surfaces.
enum LiquidGlassMetrics {
    /// 4pt spacing grid (LAY-3). Use these instead of one-off literals.
    enum Spacing {
        static let xxSmall: CGFloat = 4
        static let xSmall: CGFloat = 8
        static let small: CGFloat = 12
        static let medium: CGFloat = 16
        static let large: CGFloat = 20
        static let xLarge: CGFloat = 24
        static let xxLarge: CGFloat = 32
    }

    /// Corner radius tokens. Single-line controls are capsules and need no
    /// radius; these cover rounded rectangles.
    enum Radius {
        /// Small inset elements: thumbnails, row highlights, badges.
        static let control: CGFloat = 8
        /// Multi-line fields and composers (the minimum when concentric).
        static let field: CGFloat = 12
        /// Content cards and grouped surfaces.
        static let card: CGFloat = 16
        /// Floating panels, sheets, popovers, and large overlay surfaces.
        static let panel: CGFloat = 24

        /// The concentric inner radius for an element inset by `padding`
        /// inside a container of radius `outer` (LAY-4: outer = inner +
        /// padding). Clamped so tight insets never go negative.
        static func inner(outer: CGFloat, padding: CGFloat) -> CGFloat {
            max(outer - padding, 0)
        }
    }

    /// Spatial changes (selection pills, expanding panels): energetic start,
    /// gentle settle (MOT-4).
    static var spring: Animation { .spring(duration: 0.3, bounce: 0.15) }

    /// State feedback (hover, press, focus): quick ease-out (BTN-5).
    static var stateChange: Animation { .easeOut(duration: 0.15) }

    #if os(macOS)
    static let fieldVerticalPadding: CGFloat = 8
    static let segmentVerticalPadding: CGFloat = 4
    /// The height of the system Liquid Glass capsule behind toolbar items
    /// (measured on macOS 27.2). A glass field in its own toolbar item takes
    /// this height so its capsule lines up with the neighboring items; at the
    /// default field padding it would sit 3pt short.
    static let toolbarControlHeight: CGFloat = 36
    #else
    static let fieldVerticalPadding: CGFloat = 12
    static let segmentVerticalPadding: CGFloat = 8
    #endif
}

// MARK: - Input fields

extension View {
    /// Styles a free-standing `TextField`, `SecureField`, or `TextEditor` as
    /// a Liquid Glass field: plain text style, 4pt-grid padding, interactive
    /// glass in a capsule (single-line) or a concentric rounded rectangle
    /// (`multiline: true`), and an accent stroke while focused (FORM-4).
    ///
    /// Every text input in the apps is glass, with no exceptions: fields
    /// inside glass panels, sheets, and popovers (the system 26+ precedent:
    /// glass sheets carry glass controls), `Form` rows, toolbar fields, and
    /// palette search fields. In a `Form`, stack a visible label above the
    /// field and hide the field's own row label (`.labelsHidden()` on macOS
    /// grouped `Form`s), as both Secure Messaging screens do. Never ask for
    /// text in a system `.alert`; present a small glass sheet instead
    /// (Pilot's `TextPromptSheet`). A host must never put this glass on
    /// glass: give a toolbar field its own item and hide that item's shared
    /// capsule (Pilot's `compatSharedBackgroundHidden()`), and make a palette
    /// field a sibling of the results card in one glass container rather
    /// than a child of a glass panel (Pilot's editor quick open). Pair the
    /// field with a persistent visible label; the placeholder is a hint, not
    /// the label (FORM-1/FORM-2).
    ///
    /// - Parameters:
    ///   - multiline: Use for `TextEditor` and `TextField(axis: .vertical)`.
    ///   - systemImage: Optional leading SF Symbol (e.g. `"magnifyingglass"`
    ///     for search). Decorative; hidden from VoiceOver.
    ///   - isFocused: Pass the caller's focus value when the field already
    ///     has its own `.focused(_:)` binding. When `nil`, the modifier
    ///     tracks focus itself.
    ///   - minHeight: A minimum height for the glass shape, such as
    ///     `LiquidGlassMetrics.toolbarControlHeight` for a toolbar field.
    func liquidGlassField(
        multiline: Bool = false,
        systemImage: String? = nil,
        isFocused: Bool? = nil,
        minHeight: CGFloat? = nil
    ) -> some View {
        modifier(LiquidGlassFieldModifier(
            multiline: multiline,
            systemImage: systemImage,
            externalFocus: isFocused,
            minHeight: minHeight
        ))
    }
}

private struct LiquidGlassFieldModifier: ViewModifier {
    let multiline: Bool
    let systemImage: String?
    let externalFocus: Bool?
    let minHeight: CGFloat?
    @FocusState private var internalFocus: Bool

    func body(content: Content) -> some View {
        let isFocused = externalFocus ?? internalFocus
        HStack(
            alignment: multiline ? .firstTextBaseline : .center,
            spacing: LiquidGlassMetrics.Spacing.xSmall
        ) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            if externalFocus == nil {
                content.focused($internalFocus)
            } else {
                content
            }
        }
        .textFieldStyle(.plain)
        .scrollContentBackground(multiline ? .hidden : .automatic)
        .padding(.horizontal, multiline ? LiquidGlassMetrics.Spacing.small : LiquidGlassMetrics.Spacing.medium)
        .padding(.vertical, multiline ? LiquidGlassMetrics.Spacing.small : LiquidGlassMetrics.fieldVerticalPadding)
        .frame(minHeight: minHeight)
        .modifier(LiquidGlassFieldSurface(multiline: multiline, isFocused: isFocused))
        .animation(LiquidGlassMetrics.stateChange, value: isFocused)
    }
}

private struct LiquidGlassFieldSurface: ViewModifier {
    let multiline: Bool
    let isFocused: Bool

    private let focusLineWidth: CGFloat = 1.5

    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            if multiline {
                surface(content, shape: ConcentricRectangle(
                    corners: .concentric(minimum: .fixed(LiquidGlassMetrics.Radius.field)),
                    isUniform: true
                ))
            } else {
                surface(content, shape: Capsule())
            }
        } else if multiline {
            fallback(content, shape: RoundedRectangle(
                cornerRadius: LiquidGlassMetrics.Radius.field, style: .continuous
            ))
        } else {
            fallback(content, shape: Capsule())
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    private func surface(_ content: Content, shape: some Shape) -> some View {
        content
            .contentShape(shape)
            .glassEffect(.regular.interactive(), in: shape)
            .overlay {
                shape.stroke(.tint, lineWidth: focusLineWidth)
                    .opacity(isFocused ? 1 : 0)
                    .allowsHitTesting(false)
            }
    }

    private func fallback(_ content: Content, shape: some InsettableShape) -> some View {
        content
            .contentShape(shape)
            .background(.regularMaterial, in: shape)
            .overlay {
                shape.strokeBorder(isFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                                   lineWidth: isFocused ? focusLineWidth : 1)
                    .allowsHitTesting(false)
            }
    }
}

// MARK: - Segmented control

/// A capsule segmented control with a sliding glass selection pill, for
/// segments the system `Picker(.segmented)` cannot express (icons + counts,
/// custom content). Prefer `Picker` with `.pickerStyle(.segmented)` whenever
/// plain text or symbol segments are enough.
///
/// The track is a quiet semantic fill so the control can sit in content; the
/// pill is the only glass, so do not place this inside another glass surface
/// (no glass on glass). Each segment is a real `Button` — keyboard-focusable,
/// labeled by its content, and marked `.isSelected` for VoiceOver. For
/// icon-only segments, use `Label("Title", systemImage:)` so VoiceOver still
/// reads a name. Add `.accessibilityLabel(_:)` to the control to name the
/// group.
///
///     LiquidGlassSegmentedControl(selection: $filter, options: Filter.allCases) { filter in
///         Label("\(filter.title) \(counts[filter, default: 0])", systemImage: filter.symbol)
///     }
struct LiquidGlassSegmentedControl<Value: Hashable, SegmentLabel: View>: View {
    @Binding private var selection: Value
    private let options: [Value]
    private let fillsWidth: Bool
    private let segmentIdentifier: ((Value) -> String)?
    private let label: (Value) -> SegmentLabel

    @Namespace private var pillNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - selection: The selected option.
    ///   - options: Segments in display order.
    ///   - fillsWidth: Stretch segments to share the available width equally.
    ///   - segmentIdentifier: Optional accessibility identifier per segment,
    ///     for UI tests that address individual segments.
    ///   - label: The content for one segment.
    init(
        selection: Binding<Value>,
        options: [Value],
        fillsWidth: Bool = false,
        segmentIdentifier: ((Value) -> String)? = nil,
        @ViewBuilder label: @escaping (Value) -> SegmentLabel
    ) {
        _selection = selection
        self.options = options
        self.fillsWidth = fillsWidth
        self.segmentIdentifier = segmentIdentifier
        self.label = label
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                segment(option)
            }
        }
        .padding(LiquidGlassMetrics.Spacing.xxSmall)
        .background(.fill.tertiary, in: Capsule())
        .animation(reduceMotion ? nil : LiquidGlassMetrics.spring, value: selection)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func segment(_ option: Value) -> some View {
        let isSelected = option == selection
        let button = Button {
            selection = option
        } label: {
            label(option)
                // Constant weight: a bolder selected label would reflow the
                // segment widths while the pill slides.
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .padding(.horizontal, LiquidGlassMetrics.Spacing.small)
                .padding(.vertical, LiquidGlassMetrics.segmentVerticalPadding)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .contentShape(Capsule())
        }
        .buttonStyle(LiquidGlassSegmentButtonStyle(isSelected: isSelected))
        .background {
            if isSelected {
                SelectionPill()
                    .matchedGeometryEffect(id: "selection", in: pillNamespace)
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])

        if let segmentIdentifier {
            button.accessibilityIdentifier(segmentIdentifier(option))
        } else {
            button
        }
    }
}

private struct SelectionPill: View {
    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            Capsule()
                .fill(.clear)
                .glassEffect(.regular.interactive(), in: Capsule())
        } else {
            Capsule()
                .fill(.background)
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        }
    }
}

/// Hover and press feedback for unselected segments (BTN-5).
private struct LiquidGlassSegmentButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        HoverHighlight(
            configuration: configuration,
            shape: Capsule(),
            showsHighlight: !isSelected
        )
    }
}

// MARK: - Buttons

extension View {
    /// Liquid Glass button style; `prominent: true` for the single primary
    /// action in a view (BTN-1). Falls back to bordered styles before 26.
    /// The prominent fill is `LegibleAccent.color`, so its white label clears
    /// TYPE-3; the tint sits innermost, so an outer `.tint` does not reach it.
    @ViewBuilder
    func liquidGlassButtonStyle(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent).tint(LegibleAccent.color)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent).tint(LegibleAccent.color)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// An icon-only circular glass button with a consistent control size.
    /// Use `Label("Title", systemImage:)` as the button label: the title is
    /// hidden visually but stays the VoiceOver name. Do not apply to toolbar
    /// items — the system already gives them glass on 26+.
    func liquidGlassIconButton(
        prominent: Bool = false,
        controlSize: ControlSize = .regular
    ) -> some View {
        labelStyle(.iconOnly)
            .liquidGlassButtonStyle(prominent: prominent)
            .buttonBorderShape(.circle)
            .controlSize(controlSize)
    }

    /// Declares a rounded-rectangle container shape so `ConcentricRectangle`
    /// descendants (fields, inset thumbnails, buttons) nest concentrically
    /// (LAY-4).
    func liquidGlassContainerShape(cornerRadius: CGFloat = LiquidGlassMetrics.Radius.card) -> some View {
        containerShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// A capsule filter chip or tab: interactive glass, accent tint when
/// selected (a state signal, COL-4), a pointer hover wash and press
/// feedback (BTN-5, matching `LiquidGlassPressableButtonStyle`). Add
/// `.accessibilityAddTraits(isSelected ? .isSelected : [])` on the button.
///
///     Button(scope.name) { select(scope) }
///         .buttonStyle(.liquidGlassChip(isSelected: scope == selected))
struct LiquidGlassChipButtonStyle: ButtonStyle {
    var isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration, isSelected: isSelected)
    }
}

/// The chip's body: a view (not the style) so it can own hover state.
private struct ChipBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool

    @State private var isHovered = false

    /// On macOS the hierarchical `.fill.tertiary` turns vibrant inside glass
    /// and sidebar materials and composited as a near-black hole under a
    /// hovered inspector card in dark mode. A plain primary tint lifts in
    /// dark and dims in light, like the system's own row hover.
    #if os(macOS)
    private static var wash: some ShapeStyle { Color.primary.opacity(0.08) }
    #else
    private static var wash: some ShapeStyle { .fill.tertiary }
    #endif

    var body: some View {
        let isPressed = configuration.isPressed
        configuration.label
            .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .padding(.horizontal, LiquidGlassMetrics.Spacing.small)
            .padding(.vertical, LiquidGlassMetrics.Spacing.xSmall)
            .contentShape(Capsule())
            // The same quiet wash as `HoverHighlight`, inside the glass so
            // the chip keeps one capsule silhouette. Selected chips get it
            // too: chips toggle, so the selected one is still actionable.
            .background {
                Capsule().fill(.fill.tertiary)
                    .opacity(isHovered || isPressed ? 1 : 0)
            }
            .modifier(ChipSurface(isSelected: isSelected))
            .scaleEffect(isPressed ? 0.97 : 1)
            .onHover { isHovered = $0 }
            .animation(LiquidGlassMetrics.stateChange, value: isHovered)
            .animation(LiquidGlassMetrics.stateChange, value: isPressed)
    }
}

private struct ChipSurface: ViewModifier {
    let isSelected: Bool

    private var tint: Color? { isSelected ? Color.accentColor.opacity(0.22) : nil }

    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular.tint(tint).interactive(), in: Capsule())
        } else {
            content.background {
                ZStack {
                    Capsule().fill(.ultraThinMaterial)
                    if let tint {
                        Capsule().fill(tint)
                    }
                }
            }
        }
    }
}

extension ButtonStyle where Self == LiquidGlassChipButtonStyle {
    static func liquidGlassChip(isSelected: Bool) -> LiquidGlassChipButtonStyle {
        LiquidGlassChipButtonStyle(isSelected: isSelected)
    }
}

/// For `.plain` buttons that are the tap target of a whole list row, card,
/// sidebar row, or tile: keeps the content unstyled but adds a hover wash
/// (pointer platforms) and a press dim/scale (BTN-5). Not glass — rows are
/// content, not controls.
///
///     Button { open(item) } label: { ItemRow(item) }
///         .buttonStyle(.liquidGlassPressable)
struct LiquidGlassPressableButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = LiquidGlassMetrics.Radius.control

    func makeBody(configuration: Configuration) -> some View {
        HoverHighlight(
            configuration: configuration,
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            showsHighlight: true
        )
    }
}

extension ButtonStyle where Self == LiquidGlassPressableButtonStyle {
    static var liquidGlassPressable: LiquidGlassPressableButtonStyle { LiquidGlassPressableButtonStyle() }

    static func liquidGlassPressable(cornerRadius: CGFloat) -> LiquidGlassPressableButtonStyle {
        LiquidGlassPressableButtonStyle(cornerRadius: cornerRadius)
    }
}

/// Shared hover wash + press feedback body for the plain-looking styles.
private struct HoverHighlight<S: Shape>: View {
    let configuration: ButtonStyleConfiguration
    let shape: S
    let showsHighlight: Bool

    @State private var isHovered = false

    /// On macOS the hierarchical `.fill.tertiary` turns vibrant inside glass
    /// and sidebar materials and composited as a near-black hole under a
    /// hovered inspector card in dark mode. A plain primary tint lifts in
    /// dark and dims in light, like the system's own row hover.
    #if os(macOS)
    private static var wash: some ShapeStyle { Color.primary.opacity(0.08) }
    #else
    private static var wash: some ShapeStyle { .fill.tertiary }
    #endif

    var body: some View {
        let isPressed = configuration.isPressed
        configuration.label
            .contentShape(shape)
            .background {
                shape.fill(Self.wash)
                    .opacity(showsHighlight && (isHovered || isPressed) ? 1 : 0)
            }
            .opacity(isPressed ? 0.8 : 1)
            .scaleEffect(isPressed ? 0.98 : 1)
            .onHover { isHovered = $0 }
            .animation(LiquidGlassMetrics.stateChange, value: isHovered)
            .animation(LiquidGlassMetrics.stateChange, value: isPressed)
    }
}

// MARK: - Legible secondary text

#if os(iOS)
/// The iOS counterpart of Pilot's `GlassLegibleText.secondaryColor`, for
/// secondary text in light grouped `Form`s. On iOS 27 the system grays all
/// measured under TYPE-3's 4.5:1: `.secondary` (127,127,127) 4.0:1 and
/// `LabeledContent` values (138,138,142) 3.5:1 on a white row, section
/// headers and footers (133,133,139) 3.3:1 on the grouped background. Light mode uses Pilot's 0.36 gray (6.7:1 on white, 6.0:1 on the
/// grouped background), still clearly below primary; dark mode keeps the
/// system secondary label, which already passes.
enum LegibleSecondaryText {
    static let color = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.secondaryLabel.resolvedColor(with: traits)
            : UIColor(white: 0.36, alpha: 1)
    })
}
#endif

extension View {
    /// A grouped `List`/`Form` section header or footer in the legible
    /// secondary gray on iOS: the system header gray (133,133,139) is 3.3:1
    /// on the light grouped background, this is 6.0:1 (TYPE-3). Dark mode
    /// keeps the system secondary label. macOS keeps its own header styling.
    @ViewBuilder
    func legibleSectionText() -> some View {
        #if os(iOS)
        foregroundStyle(LegibleSecondaryText.color)
        #else
        self
        #endif
    }

    /// Secondary text inside a grouped `List`/`Form` row. On iOS it uses the
    /// legible gray (`.secondary` is 4.0:1 on a white row); elsewhere it stays
    /// the platform `.secondary`.
    @ViewBuilder
    func legibleSecondaryRowText() -> some View {
        #if os(iOS)
        foregroundStyle(LegibleSecondaryText.color)
        #else
        foregroundStyle(.secondary)
        #endif
    }
}

// MARK: - Legible accent fill

/// The user's accent, darkened just enough that white label text on it stays
/// legible: the fill behind the selected segment of Cockpit's segmented
/// pickers and behind every prominent button (`liquidGlassButtonStyle(
/// prominent: true)`, Pilot's `compatGlassProminentButtonStyle()`). White on
/// the system blue measured 3.5:1 (light) and 3.2:1 (dark) on Walkie and
/// Kneeboard's prominent glass, and 3.8–4.0:1 on Cockpit's, under TYPE-3's
/// 4.5:1. A hue that already clears the floor is returned unchanged.
enum LegibleAccent {
    /// Above 4.5:1 because rendering lightens the fill a little: Cockpit's
    /// dark-appearance segmented bezel draws lighter than its fill (a 4.8:1
    /// fill measured 4.65:1 on screen). One floor for every use keeps the
    /// selected segment and the primary button the same shade.
    static let minimumContrast = 5.2

    /// `red`/`green`/`blue` (sRGB, 0...1) mixed toward black in small steps
    /// until white text on it reaches `minimumContrast`; a color that already
    /// does is returned unchanged, so the hue stays the user's accent.
    static func legibleFill(
        red: Double,
        green: Double,
        blue: Double
    ) -> (red: Double, green: Double, blue: Double) {
        let (red, green, blue) = (clamp(red), clamp(green), clamp(blue))
        var scale = 1.0
        while scale > 0, contrastWithWhite(red: red * scale, green: green * scale, blue: blue * scale) < minimumContrast {
            scale -= 0.01
        }
        scale = max(0, scale)
        return (red * scale, green * scale, blue * scale)
    }

    /// WCAG 2 contrast ratio of white against an sRGB color.
    static func contrastWithWhite(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        return 1.05 / (luminance + 0.05)
    }

    /// Extended-range components (Display P3 accents) are clamped into sRGB.
    private static func clamp(_ channel: Double) -> Double {
        min(max(channel, 0), 1)
    }

    static let color: Color = {
        #if os(macOS)
        Color(nsColor: nsColor)
        #else
        Color(uiColor: uiColor)
        #endif
    }()

    #if os(macOS)
    /// Resolved per appearance from the user's System Settings accent.
    static let nsColor = NSColor(name: nil) { appearance in
        var accent = NSColor.systemBlue
        appearance.performAsCurrentDrawingAppearance {
            accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        }
        let fill = legibleFill(red: accent.redComponent, green: accent.greenComponent, blue: accent.blueComponent)
        return NSColor(srgbRed: fill.red, green: fill.green, blue: fill.blue, alpha: 1)
    }
    #else
    /// Resolved per trait collection (light, dark, increased contrast) from
    /// the app's AccentColor asset, which the apps leave unset, so it is the
    /// system blue the prominent styles would otherwise draw.
    static let uiColor = UIColor { traits in
        let accent = (UIColor(named: "AccentColor") ?? .systemBlue).resolvedColor(with: traits)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard accent.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return accent }
        let fill = legibleFill(red: red, green: green, blue: blue)
        return UIColor(red: fill.red, green: fill.green, blue: fill.blue, alpha: 1)
    }
    #endif
}
