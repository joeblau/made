import Foundation

/// Number formatting for the Agentic Use dashboard. Every figure the section
/// renders goes through one of these helpers so the hero total, chart axes,
/// stat row, and breakdown table always agree with each other.
enum AgenticUseFormat {
    /// Full-precision money: "$1,616.86".
    static func cost(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    /// Compact axis money: "$50", "$1.2K".
    static func axisCost(_ value: Double) -> String {
        value.formatted(
            .currency(code: "USD")
                .notation(.compactName)
                .precision(.fractionLength(0...1))
        )
    }

    /// Abbreviated token counts: "2.58B", "106M", "8.10M"; small values
    /// render plain ("512"). Three significant digits produce the trailing
    /// zero in "8.10M" — do not switch to fraction-length precision.
    static func tokens(_ value: Int) -> String {
        tokens(Double(value))
    }

    static func tokens(_ value: Double) -> String {
        guard abs(value) >= 1000 else {
            return value.formatted(.number.precision(.fractionLength(0)))
        }
        return value.formatted(
            .number.notation(.compactName).precision(.significantDigits(3))
        )
    }

    /// "94.1%" from a 0...1 fraction.
    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(1)))
    }

    /// "6.2x" from a ratio.
    static func multiple(_ ratio: Double) -> String {
        ratio.formatted(.number.precision(.fractionLength(1))) + "x"
    }

    /// Signed relative change for KPI deltas: "28%" (direction carried by
    /// the arrow glyph, not the sign). `nil` when there is no baseline.
    static func relativeChange(current: Double, previous: Double) -> Double? {
        guard previous > 0 else { return nil }
        return (current - previous) / previous
    }

    /// Compact money for prose: "$17.2K", "$412".
    static func compactCost(_ value: Double) -> String {
        axisCost(value)
    }

    /// Unsigned magnitude for a delta badge: "28%", or ">999%" past the cap
    /// so a near-zero baseline can't print an absurd figure.
    static func deltaPercent(_ change: Double) -> String {
        let magnitude = abs(change)
        if magnitude >= 9.99 { return ">999%" }
        return magnitude.formatted(.percent.precision(.fractionLength(magnitude < 0.1 ? 1 : 0)))
    }

    /// Percentage-point change for rates: "3.1 pts".
    static func deltaPoints(_ change: Double) -> String {
        (abs(change) * 100).formatted(.number.precision(.fractionLength(1))) + " pts"
    }
}
