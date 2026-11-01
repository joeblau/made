import SwiftUI

/// One full-width bar segmented by each provider's share of estimated cost,
/// with a share/cost legend underneath. Hovering a legend entry opens that
/// provider's per-model breakdown. Falls back to token share when nothing in
/// range is priced, and says so.
struct AgenticUseProviderBreakdown: View {
    let snapshot: AgenticUseSnapshot

    private struct Entry: Identifiable {
        let provider: AgenticProvider
        let share: Double
        let cost: Double
        let tokens: Int

        var id: AgenticProvider { provider }
    }

    private var usesCost: Bool { snapshot.totalCostUSD > 0 }

    private var entries: [Entry] {
        let totalTokens = snapshot.providerTotals.reduce(0) { $0 + $1.totalTokens }
        return snapshot.providerTotals
            .map { total in
                let share = usesCost
                    ? total.estimatedCost / snapshot.totalCostUSD
                    : (totalTokens > 0 ? Double(total.totalTokens) / Double(totalTokens) : 0)
                return Entry(provider: total.provider, share: share, cost: total.estimatedCost, tokens: total.totalTokens)
            }
            .sorted { $0.share == $1.share ? $0.tokens > $1.tokens : $0.share > $1.share }
    }

    var body: some View {
        let entries = entries
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Provider Breakdown").agenticUseCardTitle()
                Spacer(minLength: 8)
                Text(usesCost ? "share of estimated cost" : "share of tokens (no priced usage)")
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
            }
            bar(entries)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 104), spacing: 12, alignment: .topLeading)],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(entries) { entry in
                    AgenticUseProviderLegendEntry(
                        provider: entry.provider,
                        share: entry.share,
                        value: usesCost ? AgenticUseFormat.cost(entry.cost) : AgenticUseFormat.tokens(entry.tokens) + " tokens",
                        models: snapshot.modelTotals.filter { $0.provider == entry.provider }
                    )
                }
            }
        }
        .agenticUseCard()
    }

    private static let gap: CGFloat = 2

    private func bar(_ entries: [Entry]) -> some View {
        GeometryReader { geometry in
            let visible = entries.filter { $0.share > 0 }
            let available = max(0, geometry.size.width - Self.gap * CGFloat(max(0, visible.count - 1)))
            HStack(spacing: Self.gap) {
                ForEach(visible) { entry in
                    Rectangle()
                        .fill(AgenticUseModelPalette.providerColor(for: entry.provider).gradient)
                        .frame(width: max(3, available * entry.share))
                        .help("\(entry.provider.displayName): \(AgenticUseFormat.percent(entry.share))")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.1))
            .clipShape(Capsule())
        }
        .frame(height: 14)
    }
}

private struct AgenticUseProviderLegendEntry: View {
    let provider: AgenticProvider
    let share: Double
    let value: String
    let models: [AgenticModelTotal]

    @State private var showsModels = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle()
                .fill(AgenticUseModelPalette.providerColor(for: provider))
                .frame(width: 9, height: 9)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(AgenticUseFormat.percent(share))
                        .scaledFont(size: 12, weight: .semibold)
                        .monospacedDigit()
                    Text(provider.displayName)
                        .scaledFont(size: 12)
                        .foregroundStyle(.secondary)
                }
                Text(value)
                    .scaledFont(size: 12, weight: .medium)
                    .monospacedDigit()
            }
            .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { showsModels = $0 && !models.isEmpty }
        .popover(isPresented: $showsModels, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(provider.displayName)
                    .scaledFont(size: 12, weight: .semibold)
                ForEach(models) { total in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(AgenticUseModelPalette.color(for: total.model))
                            .frame(width: 8, height: 8)
                        Text(total.displayName)
                            .scaledFont(size: 11, weight: .medium)
                            .lineLimit(1)
                        if total.isUnpriced { AgenticUseUnpricedBadge() }
                        Spacer(minLength: 12)
                        Text(total.isUnpriced ? "—" : AgenticUseFormat.cost(total.cost))
                            .scaledFont(size: 11)
                            .monospacedDigit()
                        Text(AgenticUseFormat.tokens(total.tokens))
                            .scaledFont(size: 11)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(minWidth: 44, alignment: .trailing)
                    }
                }
            }
            .padding(12)
            .frame(minWidth: 260, alignment: .leading)
        }
    }
}

/// Marks a model missing from the pricing table — its zero cost is a gap in
/// the table, not a real $0.
struct AgenticUseUnpricedBadge: View {
    var body: some View {
        Text("unpriced")
            .scaledFont(size: 9, weight: .semibold)
            .foregroundStyle(.orange)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.orange.opacity(0.15), in: Capsule())
    }
}
