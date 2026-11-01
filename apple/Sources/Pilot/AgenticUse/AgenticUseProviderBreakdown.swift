import SwiftUI

/// One full-width bar segmented by each provider's share of estimated cost,
/// with a share/cost legend underneath. Hovering a legend entry highlights it
/// and opens that provider's per-model breakdown. Falls back to token share when nothing in
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
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.medium) {
            HStack(alignment: .firstTextBaseline) {
                Text("Provider Breakdown").agenticUseCardTitle()
                Spacer(minLength: LiquidGlassMetrics.Spacing.xSmall)
                Text(usesCost ? "share of estimated cost" : "share of tokens (no priced usage)")
                    .agenticUseFont(.meta)
                    .foregroundStyle(.secondary)
            }
            bar(entries)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 104), spacing: LiquidGlassMetrics.Spacing.small, alignment: .topLeading)],
                alignment: .leading,
                spacing: LiquidGlassMetrics.Spacing.small
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
            .background(.fill.tertiary)
            .clipShape(Capsule())
        }
        .frame(height: 12)
    }
}

private struct AgenticUseProviderLegendEntry: View {
    let provider: AgenticProvider
    let share: Double
    let value: String
    let models: [AgenticModelTotal]

    @State private var showsModels = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LiquidGlassMetrics.Spacing.xSmall) {
            Circle()
                .fill(AgenticUseModelPalette.providerColor(for: provider))
                .frame(width: 8, height: 8)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: LiquidGlassMetrics.Spacing.xxSmall) {
                    Text(AgenticUseFormat.percent(share))
                        .agenticUseFont(.body, weight: .semibold)
                        .monospacedDigit()
                    Text(provider.displayName)
                        .agenticUseFont(.body)
                        .foregroundStyle(.secondary)
                }
                Text(value)
                    .agenticUseFont(.body, weight: .medium)
                    .monospacedDigit()
            }
            .lineLimit(1)
        }
        // Hover wash that bleeds past the entry without shifting the grid,
        // so the hover that opens the popover has a visible state (BTN-5).
        .background {
            RoundedRectangle(cornerRadius: LiquidGlassMetrics.Radius.control, style: .continuous)
                .fill(.fill.tertiary)
                .padding(-LiquidGlassMetrics.Spacing.xxSmall)
                .opacity(showsModels ? 1 : 0)
        }
        .contentShape(Rectangle())
        .animation(LiquidGlassMetrics.stateChange, value: showsModels)
        .onHover { showsModels = $0 && !models.isEmpty }
        .popover(isPresented: $showsModels, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xSmall) {
                Text(provider.displayName)
                    .agenticUseFont(.body, weight: .semibold)
                ForEach(models) { total in
                    HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(AgenticUseModelPalette.color(for: total.model))
                            .frame(width: 8, height: 8)
                        Text(total.displayName)
                            .agenticUseFont(.meta, weight: .medium)
                            .lineLimit(1)
                        if total.isUnpriced { AgenticUseUnpricedBadge() }
                        Spacer(minLength: LiquidGlassMetrics.Spacing.small)
                        Text(total.isUnpriced ? "—" : AgenticUseFormat.cost(total.cost))
                            .agenticUseFont(.meta)
                            .monospacedDigit()
                        Text(AgenticUseFormat.tokens(total.tokens))
                            .agenticUseFont(.meta)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(minWidth: 44, alignment: .trailing)
                    }
                }
            }
            .padding(LiquidGlassMetrics.Spacing.small)
            .frame(minWidth: 260, alignment: .leading)
        }
    }
}

/// Marks a model missing from the pricing table — its zero cost is a gap in
/// the table, not a real $0.
struct AgenticUseUnpricedBadge: View {
    var body: some View {
        Text("unpriced")
            .agenticUseFont(.caption, weight: .semibold)
            .foregroundStyle(.orange)
            .padding(.horizontal, LiquidGlassMetrics.Spacing.xxSmall)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.15), in: Capsule())
    }
}
