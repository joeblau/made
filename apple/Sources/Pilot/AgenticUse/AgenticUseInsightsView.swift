import SwiftUI

/// Up to three plain-language observations derived by `AgenticUseInsights`.
struct AgenticUseInsightsView: View {
    let insights: [AgenticUseInsight]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Insights").agenticUseCardTitle()
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 190), spacing: 10, alignment: .top)],
                alignment: .leading,
                spacing: 10
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
        return HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.gradient)
                .frame(width: 32, height: 32)
                .overlay {
                    Image(systemName: Self.symbol(for: insight.kind))
                        .scaledFont(size: 14, weight: .semibold)
                        .foregroundStyle(.white)
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
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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
