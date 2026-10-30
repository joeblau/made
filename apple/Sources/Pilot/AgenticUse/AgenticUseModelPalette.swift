import SwiftUI

/// Fixed model-to-color mapping shared by the chart color scale, legend,
/// hero list, and breakdown table.
///
/// Each provider uses a standard system color — Claude orange, Codex green,
/// Kimi purple, Grok red, Cursor blue — and each model gets its own shade.
/// The flagship uses the system accent; adjacent models alternate lightness. Color
/// follows the canonical model id — never chart order — so a model keeps its
/// shade when the range filter changes which series are visible. Gray is
/// reserved for unknown models and always travels with the "unpriced" badge,
/// never color alone.
enum AgenticUseModelPalette {
    static func color(for canonicalModel: String) -> Color {
        guard let provider = provider(for: canonicalModel) else { return .gray }
        let family = familyOrder(for: provider)
        // Newly discovered priced models also get a stable provider color.
        let index = family.firstIndex(of: canonicalModel)
            ?? (canonicalModel.utf8.reduce(0) { ($0 * 31 + Int($1)) % 16 } + family.count)
        if index == 0 { return providerColor(for: provider) }
        return shade(provider: provider, step: index)
    }

    /// Standard system accent, shared by brand marks and Plan Usage cards.
    static func providerColor(for provider: AgenticProvider) -> Color {
        switch provider {
        case .claude: .orange
        case .codex: .green
        case .kimi: .purple
        case .grok: .red
        case .cursor: .blue
        }
    }

    /// Which provider's hue family a canonical model id belongs to.
    static func provider(for canonicalModel: String) -> AgenticProvider? {
        if canonicalModel.hasPrefix("cursor/") { return .cursor }
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

    /// Alternate high-contrast shades instead of spreading tiny increments
    /// across the entire catalog. The busiest adjacent models must remain
    /// distinguishable even when a provider has many older models.
    private static func shade(provider: AgenticProvider, step: Int) -> Color {
        let color = providerColor(for: provider)
        let cycle = Double(step / 4) * 0.035
        let white: Double
        let black: Double
        switch step % 4 {
        case 0: (white, black) = (0, min(0.22, cycle))
        case 1: (white, black) = (min(0.7, 0.42 + cycle), 0)
        case 2: (white, black) = (min(0.34, 0.18 + cycle), 0)
        default: (white, black) = (0, min(0.45, 0.25 + cycle))
        }
        return color.mix(with: white > 0 ? .white : .black, by: max(white, black))
    }
}
