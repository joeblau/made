import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The user's accent, darkened just enough that white label text on it stays
/// legible: the fill behind the selected segment of Cockpit's segmented
/// pickers and prominent controls, including the companion apps'
/// `liquidGlassButtonStyle(prominent: true)`. White on
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
