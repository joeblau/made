import AppKit
import CodeEditSourceEditor
import SwiftUI

/// Syntax-highlighting themes for the editor pane, hand-tuned to read like
/// Xcode's Default Dark/Light presets. CodeEditSourceEditor wants an
/// `EditorTheme` of raw `NSColor` values (not SwiftUI `Color`), so everything
/// here is built from sRGB literals and resolved per `ColorScheme`.
@MainActor
enum PilotEditorTheme {
    /// Picks the dark or light variant for the current appearance.
    static func theme(for colorScheme: ColorScheme) -> EditorTheme {
        colorScheme == .dark ? dark : light
    }

    // MARK: - Dark (Xcode Default Dark Reminiscent)

    private static let dark: EditorTheme =
        EditorTheme(
            text: .init(color: srgb(0.86, 0.86, 0.86)),                 // near-white foreground
            insertionPoint: srgb(0.86, 0.86, 0.86),
            invisibles: .init(color: srgb(0.35, 0.35, 0.35)),
            background: srgb(0.13, 0.13, 0.14),                          // editor canvas
            lineHighlight: srgb(0.18, 0.18, 0.20),                      // current-line band
            selection: srgb(0.25, 0.31, 0.42),
            keywords: .init(color: srgb(0.98, 0.42, 0.71), bold: true),  // magenta/pink keywords
            commands: .init(color: srgb(0.40, 0.84, 0.78)),
            types: .init(color: srgb(0.42, 0.84, 0.78)),                // teal types
            attributes: .init(color: srgb(0.40, 0.84, 0.78)),
            variables: .init(color: srgb(0.42, 0.69, 0.96)),           // blue variables
            values: .init(color: srgb(0.65, 0.55, 0.96)),
            numbers: .init(color: srgb(0.60, 0.72, 1.0)),              // aqua numbers
            strings: .init(color: srgb(0.99, 0.42, 0.42)),            // red strings
            characters: .init(color: srgb(0.60, 0.72, 1.0)),
            comments: .init(color: srgb(0.46, 0.55, 0.46), italic: true) // muted green comments
        )

    // MARK: - Light (Xcode Default Light Reminiscent)

    private static let light: EditorTheme =
        EditorTheme(
            text: .init(color: srgb(0.0, 0.0, 0.0)),                   // black foreground
            insertionPoint: srgb(0.0, 0.0, 0.0),
            invisibles: .init(color: srgb(0.78, 0.78, 0.78)),
            background: srgb(1.0, 1.0, 1.0),                           // white canvas
            lineHighlight: srgb(0.93, 0.95, 1.0),                     // pale current-line band
            selection: srgb(0.70, 0.84, 1.0),
            keywords: .init(color: srgb(0.61, 0.14, 0.58), bold: true), // magenta keywords
            commands: .init(color: srgb(0.07, 0.43, 0.45)),
            types: .init(color: srgb(0.07, 0.43, 0.45)),               // teal types
            attributes: .init(color: srgb(0.07, 0.43, 0.45)),
            variables: .init(color: srgb(0.0, 0.32, 0.74)),          // blue variables
            values: .init(color: srgb(0.16, 0.16, 0.74)),
            numbers: .init(color: srgb(0.11, 0.0, 0.81)),            // blue numbers
            strings: .init(color: srgb(0.77, 0.10, 0.09)),          // red strings
            characters: .init(color: srgb(0.11, 0.0, 0.81)),
            comments: .init(color: srgb(0.0, 0.46, 0.17), italic: true) // green comments
        )

    private static func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
