import SwiftUI

/// Fixed model-to-color mapping shared by the chart color scale, legend,
/// hero list, and breakdown table.
///
/// Each provider owns one hue family — Claude orange, Codex blue, Grok
/// purple, Kimi green — and every model inside a family gets its own shade
/// of that hue, iPhone-storage-bar style: the flagship model takes the
/// deepest, most saturated step and adjacent models alternate lightness. Color
/// follows the canonical model id — never chart order — so a model keeps its
/// shade when the range filter changes which series are visible. Gray is
/// reserved for unknown models and always travels with the "unpriced" badge,
/// never color alone.
enum AgenticUseModelPalette {
    static func color(for canonicalModel: String) -> Color {
        guard let provider = provider(for: canonicalModel) else { return .gray }
        let family = familyOrder(for: provider)
        guard let index = family.firstIndex(of: canonicalModel) else { return .gray }
        return shade(hue: hue(for: provider), step: index)
    }

    /// Which provider's hue family a canonical model id belongs to.
    static func provider(for canonicalModel: String) -> AgenticProvider? {
        if canonicalModel.hasPrefix("claude-") { return .claude }
        if canonicalModel.hasPrefix("gpt-") { return .codex }
        if canonicalModel.hasPrefix("grok") { return .grok }
        if kimiModels.contains(canonicalModel) || canonicalModel.contains("kimi") { return .kimi }
        return nil
    }

    // MARK: - Families

    private static let kimiModels: Set<String> = [
        "k3", "k3-256k", "k3-max", "moonshot-ai/kimi-k3", "kimi-for-coding",
    ]

    /// The provider's models in `AgenticModel.presentationOrder` — flagship
    /// first, so shade steps track prominence.
    private static func familyOrder(for provider: AgenticProvider) -> [String] {
        AgenticModel.presentationOrder.filter { Self.provider(for: $0) == provider }
    }

    /// Base hue (degrees) per provider.
    private static func hue(for provider: AgenticProvider) -> Double {
        switch provider {
        case .claude: 27
        case .codex: 214
        case .grok: 275
        case .kimi: 138
        }
    }

    /// Alternate high-contrast shades instead of spreading tiny increments
    /// across the entire catalog. The busiest adjacent models must remain
    /// distinguishable even when a provider has many older models.
    private static func shade(hue degrees: Double, step: Int) -> Color {
        let shades: [(saturation: Double, brightness: Double)] = [
            (0.92, 0.82), (0.38, 1.00), (0.72, 0.96), (0.52, 0.72),
        ]
        let shade = shades[step % shades.count]
        let hueOffset = Double(step / shades.count) * 6
        return Color(
            hue: (degrees + hueOffset) / 360,
            saturation: shade.saturation,
            brightness: shade.brightness
        )
    }
}
