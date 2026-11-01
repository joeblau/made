import SwiftUI

/// Up to three plain-language observations derived by `AgenticUseInsights`.
/// Insights sit directly on the card, grouped by spacing — nested boxes made
/// the panel read as cards inside a card.
struct AgenticUseInsightsView: View {
    let insights: [AgenticUseInsight]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Insights").agenticUseCardTitle()
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 190), spacing: 16, alignment: .top)],
                alignment: .leading,
                spacing: 16
            ) {
                ForEach(insights) { insight in
                    card(insight)
                }
            }
        }
        .agenticUseCard()
    }

    private func card(_ insight: AgenticUseInsight) -> some View {
        let tint = Self.tint(for: insight.kind)
        // A soft tinted tile: a solid gradient with a white glyph read like a
        // small primary button competing with the real controls.
        return HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.16))
                .frame(width: 32, height: 32)
                .overlay {
                    Image(systemName: Self.symbol(for: insight.kind))
                        .scaledFont(size: 14, weight: .semibold)
                        .foregroundStyle(tint)
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(insight.title)
                    .scaledFont(size: 12, weight: .semibold)
                    .fixedSize(horizontal: false, vertical: true)
                Text(insight.detail)
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    static func symbol(for kind: AgenticUseInsight.Kind) -> String {
        switch kind {
        case .cacheHitRate: "arrow.triangle.2.circlepath"
        case .spike: "waveform.path.ecg"
        case .costChange: "dollarsign"
        case .topModel: "crown.fill"
        }
    }

    static func tint(for kind: AgenticUseInsight.Kind) -> Color {
        switch kind {
        case .cacheHitRate: .green
        case .spike: .orange
        case .costChange: .blue
        case .topModel: .purple
        }
    }
}
