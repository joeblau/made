import SwiftUI
import Testing
import UIKit
@testable import Copilot

/// The iOS legible accent behind Walkie's and Kneeboard's prominent buttons
/// (`liquidGlassButtonStyle(prominent: true)`). White on the plain system
/// blue measured 3.5:1 (light) and 3.2:1 (dark) on screen, under TYPE-3.
@Suite("Legible accent fill (iOS)")
struct LegibleAccentTests {
    private static let traits: [UITraitCollection] = [
        UITraitCollection(userInterfaceStyle: .light),
        UITraitCollection(userInterfaceStyle: .dark),
        UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: .light),
            UITraitCollection(accessibilityContrast: .high)
        ]),
        UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: .dark),
            UITraitCollection(accessibilityContrast: .high)
        ])
    ]

    private static func components(_ color: UIColor) -> (red: Double, green: Double, blue: Double) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        _ = color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red, green, blue)
    }

    @Test func resolvedFillClearsTheFloorAndKeepsTheHue() {
        for traits in Self.traits {
            let fill = Self.components(LegibleAccent.uiColor.resolvedColor(with: traits))
            let contrast = LegibleAccent.contrastWithWhite(red: fill.red, green: fill.green, blue: fill.blue)
            #expect(contrast >= LegibleAccent.minimumContrast, "\(traits) -> \(contrast)")
            // Still the accent blue, not black or gray.
            #expect(fill.blue > fill.red + 0.3, "\(fill)")
        }
    }

    @Test func systemRedIsDarkenedToTheFloor() {
        for traits in Self.traits {
            let red = Self.components(UIColor.systemRed.resolvedColor(with: traits))
            let fill = LegibleAccent.legibleFill(red: red.red, green: red.green, blue: red.blue)
            #expect(LegibleAccent.contrastWithWhite(red: fill.red, green: fill.green, blue: fill.blue)
                >= LegibleAccent.minimumContrast)
        }
    }

    @Test func alreadyLegibleColorsAreUnchanged() {
        let fill = LegibleAccent.legibleFill(red: 0.1, green: 0.2, blue: 0.5)
        #expect(fill.red == 0.1 && fill.green == 0.2 && fill.blue == 0.5)
    }
}
