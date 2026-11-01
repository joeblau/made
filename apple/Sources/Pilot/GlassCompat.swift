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

    @ViewBuilder
    func compatGlassButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// The single primary action in a view (BTN-1): tinted Liquid Glass on
    /// macOS 26, the prominent bordered style before it.
    @ViewBuilder
    func compatGlassProminentButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
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
