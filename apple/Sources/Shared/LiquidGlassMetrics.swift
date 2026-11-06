import Foundation

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
