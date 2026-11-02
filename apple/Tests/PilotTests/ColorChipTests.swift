import AppKit
import Testing
@testable import Pilot

@Suite("Color chip parsing")
struct ColorChipTests {

    /// Rounded 0–255 sRGB components + alpha, for stable comparisons.
    private func rgba(_ color: NSColor) -> (r: Int, g: Int, b: Int, a: Double) {
        let s = color.usingColorSpace(.sRGB)!
        return (Int((s.redComponent * 255).rounded()),
                Int((s.greenComponent * 255).rounded()),
                Int((s.blueComponent * 255).rounded()),
                (s.alphaComponent * 100).rounded() / 100)
    }

    @Test("The four documented formats all resolve to the same green")
    func documentedFormatsAgree() throws {
        // #00FF3F == rgb(0,255,63) == oklch(86.8% 0.279 144.3) == cmyk(100% 0% 75% 0%)
        for input in ["#00FF3F", "rgb(0, 255, 63)", "oklch(86.8% 0.279 144.3)", "cmyk(100%, 0%, 75%, 0%)"] {
            let c = try #require(ColorChip.parse(input), "should parse \(input)")
            let (r, g, b, a) = rgba(c)
            // OKLCH/CMYK round-trips land within 1/255 of the target green.
            #expect(abs(r - 0) <= 1, "\(input) red")
            #expect(abs(g - 255) <= 1, "\(input) green")
            #expect(abs(b - 63) <= 2, "\(input) blue")
            #expect(a == 1, "\(input) alpha")
        }
    }

    @Test("Hex shorthand and alpha")
    func hexVariants() throws {
        #expect(rgba(try #require(ColorChip.parse("#0F3"))) == (0, 255, 51, 1))      // #0F3 -> #00FF33
        #expect(rgba(try #require(ColorChip.parse("#00FF3F80"))).a == 0.5)            // 8-digit alpha
        #expect(rgba(try #require(ColorChip.parse("#FFFFFF"))) == (255, 255, 255, 1))
    }

    @Test("rgb percentages and rgba alpha")
    func rgbVariants() throws {
        #expect(rgba(try #require(ColorChip.parse("rgb(100%, 0%, 0%)"))) == (255, 0, 0, 1))
        #expect(rgba(try #require(ColorChip.parse("rgba(0,255,63,0.5)"))).a == 0.5)
    }

    @Test("oklch accepts L as 0–1 or a percentage")
    func oklchLightnessForms() throws {
        let pct = rgba(try #require(ColorChip.parse("oklch(86.8% 0.279 144.3)")))
        let unit = rgba(try #require(ColorChip.parse("oklch(0.868 0.279 144.3)")))
        #expect(pct == unit)
    }

    @Test("Out-of-range channels clamp into gamut")
    func clamping() throws {
        #expect(rgba(try #require(ColorChip.parse("rgb(300, -5, 999)"))) == (255, 0, 255, 1))
    }

    @Test("Non-colors and partial-content spans are rejected")
    func rejectsNonColors() {
        for input in ["not a color", "color: #00FF3F", "#zzz", "#12", "rgb(1,2)", "", "   ", "hello world"] {
            #expect(ColorChip.parse(input) == nil, "should reject \(input)")
        }
    }

    @Test("matches() finds only inline-code spans whose whole content is a color")
    func matchesScansInlineCode() {
        let body = """
        brand: `#00FF3F`
        plain text, no code
        accent `rgb(0, 255, 63)` here
        not a color: `let x = 1`
        bad hex: `#zzz`
        bare #00FF3F is not in code
        """
        let found = ColorChip.matches(in: body)
        #expect(found.count == 2)
        #expect(found.map(\.value) == ["#00FF3F", "rgb(0, 255, 63)"])
    }
}

@Suite("Segmented picker selection tint")
struct SegmentedSelectionTintTests {
    /// The system accent colors (light and dark variants, sRGB) plus white
    /// and black: every selected segment must keep its white label at or
    /// above 4.5:1 (TYPE-3) after `legibleFill`.
    private static let accents: [(Double, Double, Double)] = [
        (0.0, 0.533, 1.0), (0.039, 0.518, 1.0),      // blue
        (0.584, 0.239, 0.588), (0.749, 0.353, 0.949), // purple
        (0.969, 0.31, 0.62), (1.0, 0.216, 0.373),    // pink
        (0.878, 0.22, 0.243), (1.0, 0.271, 0.227),   // red
        (0.969, 0.51, 0.106), (1.0, 0.624, 0.039),   // orange
        (1.0, 0.784, 0.0), (1.0, 0.839, 0.039),      // yellow
        (0.384, 0.729, 0.275), (0.196, 0.843, 0.294), // green
        (0.549, 0.549, 0.549), (0.596, 0.596, 0.616), // graphite
        (1, 1, 1), (0, 0, 0),
    ]

    @Test func everyAccentClearsTheContrastFloorWithWhite() {
        for (red, green, blue) in Self.accents {
            let fill = SegmentedSelectionTint.legibleFill(red: red, green: green, blue: blue)
            let contrast = SegmentedSelectionTint.contrastWithWhite(red: fill.red, green: fill.green, blue: fill.blue)
            #expect(contrast >= SegmentedSelectionTint.minimumContrast, "\(red), \(green), \(blue) -> \(contrast)")
            #expect(contrast >= 4.5)
        }
    }

    @Test func darkeningKeepsTheHueAndStopsAtTheFloor() {
        let fill = SegmentedSelectionTint.legibleFill(red: 0, green: 0.533, blue: 1)
        #expect(fill.red == 0)
        #expect(abs(fill.green / fill.blue - 0.533) < 0.0001)
        // One more step lighter would fall below the floor.
        let lighter = (fill.blue + 0.01) / fill.blue
        let contrast = SegmentedSelectionTint.contrastWithWhite(
            red: 0, green: fill.green * lighter, blue: fill.blue * lighter
        )
        #expect(contrast < SegmentedSelectionTint.minimumContrast)
    }

    @Test func alreadyLegibleColorsAreUnchanged() {
        let fill = SegmentedSelectionTint.legibleFill(red: 0.1, green: 0.2, blue: 0.5)
        #expect(fill.red == 0.1 && fill.green == 0.2 && fill.blue == 0.5)
    }

    @Test func contrastMatchesWCAG() {
        #expect(abs(SegmentedSelectionTint.contrastWithWhite(red: 0, green: 0, blue: 0) - 21) < 0.001)
        #expect(abs(SegmentedSelectionTint.contrastWithWhite(red: 1, green: 1, blue: 1) - 1) < 0.001)
    }
}
