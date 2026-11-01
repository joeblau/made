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
    /// Every text input in the apps is glass, including fields inside glass
    /// panels, sheets, and popovers (the system 26+ precedent: glass sheets
    /// carry glass controls) and `Form` rows. In a `Form`, stack a visible
    /// label above the field and hide the field's own row label
    /// (`.labelsHidden()` on macOS grouped `Form`s), as both Secure
    /// Messaging screens do. Never ask for text in a system `.alert`; present
    /// a small glass sheet instead (Pilot's `TextPromptSheet`). The only
    /// fields that keep the plain style are those hosted in a toolbar
    /// capsule or a glass palette: their host is already glass, so a glass
    /// field would stack glass on glass. Pair the field with a persistent
    /// visible label; the placeholder is a hint, not the label
    /// (FORM-1/FORM-2).
    ///
    /// - Parameters:
    ///   - multiline: Use for `TextEditor` and `TextField(axis: .vertical)`.
    ///   - systemImage: Optional leading SF Symbol (e.g. `"magnifyingglass"`
    ///     for search). Decorative; hidden from VoiceOver.
    ///   - isFocused: Pass the caller's focus value when the field already
    ///     has its own `.focused(_:)` binding. When `nil`, the modifier
    ///     tracks focus itself.
    func liquidGlassField(
        multiline: Bool = false,
        systemImage: String? = nil,
        isFocused: Bool? = nil
    ) -> some View {
        modifier(LiquidGlassFieldModifier(
            multiline: multiline,
            systemImage: systemImage,
            externalFocus: isFocused
        ))
    }
}

private struct LiquidGlassFieldModifier: ViewModifier {
    let multiline: Bool
    let systemImage: String?
    let externalFocus: Bool?
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
    @ViewBuilder
    func liquidGlassButtonStyle(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent)
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

    var body: some View {
        let isPressed = configuration.isPressed
        configuration.label
            .contentShape(shape)
            .background {
                shape.fill(.fill.tertiary)
                    .opacity(showsHighlight && (isHovered || isPressed) ? 1 : 0)
            }
            .opacity(isPressed ? 0.8 : 1)
            .scaleEffect(isPressed ? 0.98 : 1)
            .onHover { isHovered = $0 }
            .animation(LiquidGlassMetrics.stateChange, value: isHovered)
            .animation(LiquidGlassMetrics.stateChange, value: isPressed)
    }
}
