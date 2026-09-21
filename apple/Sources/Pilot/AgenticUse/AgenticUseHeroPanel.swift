import SwiftUI

/// Left column of the dashboard: the raw-token-cost hero number over one
/// section per provider (Claude, Codex, Grok, Kimi), each led by a
/// storage-style stacked bar of that provider's models with the provider's
/// model rows below as its legend.
struct AgenticUseHeroPanel: View {
    let totalCost: Double
    let modelTotals: [AgenticModelTotal]
    let hasUnpricedModels: Bool

    /// Model totals grouped by provider, ordered by provider cost
    /// descending; models inside keep the incoming (cost descending) order.
    private var providerGroups: [AgenticProviderGroup] {
        var byProvider: [AgenticProvider?: [AgenticModelTotal]] = [:]
        for total in modelTotals {
            byProvider[AgenticUseModelPalette.provider(for: total.model), default: []].append(total)
        }
        return byProvider
            .map { provider, totals in
                AgenticProviderGroup(
                    name: provider?.displayName ?? "Other",
                    totals: totals,
                    cost: totals.reduce(0) { $0 + $1.cost },
                    tokens: totals.reduce(0) { $0 + $1.tokens },
                    costShare: totals.reduce(0) { $0 + $1.costShare }
                )
            }
            .sorted { lhs, rhs in
                lhs.cost == rhs.cost ? lhs.tokens > rhs.tokens : lhs.cost > rhs.cost
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("RAW TOKEN COST")
                    .scaledFont(size: 10, weight: .semibold)
                    .kerning(0.8)
                    .foregroundStyle(.secondary)
                Text(AgenticUseFormat.cost(totalCost) + "*")
                    .scaledFont(size: 34, weight: .bold, design: .rounded)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(
                        .interactiveSpring(response: 0.35, dampingFraction: 0.7),
                        value: totalCost
                    )
                Text("* if billed at full API rate")
                    .scaledFont(size: 10)
                    .foregroundStyle(.tertiary)
                if hasUnpricedModels {
                    Text("Some models have no pricing entry and are excluded from the total.")
                        .scaledFont(size: 10)
                        .foregroundStyle(.orange)
                }
            }

            ForEach(providerGroups) { group in
                AgenticUseProviderSection(group: group)
                    .padding(.top, 8)
            }

            Spacer(minLength: 0)
        }
        .agenticUseCard(minHeight: 280)
    }
}

/// One provider's slice of the hero panel: just the name, total, and the
/// provider's stacked bar. The per-model breakdown lives in a popover that
/// opens while the pointer hovers the row.
private struct AgenticUseProviderSection: View {
    let group: AgenticProviderGroup

    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(group.name)
                        .scaledFont(size: 13, weight: .semibold)
                    Spacer(minLength: 8)
                    Text(group.cost > 0 ? AgenticUseFormat.cost(group.cost) : "—")
                        .scaledFont(size: 13, weight: .semibold)
                        .monospacedDigit()
                }
                Text("\(AgenticUseFormat.percent(group.costShare)) of cost · \(AgenticUseFormat.tokens(group.tokens)) tokens")
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            AgenticUseStackedShareBar(modelTotals: group.totals)
        }
        .contentShape(Rectangle())
        .onHover { showsDetails = $0 }
        .popover(isPresented: $showsDetails, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(group.totals) { total in
                    AgenticUseModelCostRow(total: total)
                }
            }
            .padding(12)
            .frame(minWidth: 240, alignment: .leading)
        }
    }
}

/// A provider bucket of the hero list, keyed by display name ("Claude",
/// "Codex", "Grok", "Kimi", or "Other" for unrecognized models).
struct AgenticProviderGroup: Identifiable {
    let name: String
    let totals: [AgenticModelTotal]
    let cost: Double
    let tokens: Int
    /// Fraction of the whole range's cost (sum of member shares).
    let costShare: Double

    var id: String { name }
}

/// One horizontal bar segmented by each member model's share — the
/// iPhone-storage-widget idiom. Shares are normalized to the members passed
/// in, so a provider's bar always spans full width regardless of the
/// provider's share of the grand total. Segments follow `modelTotals` order
/// (cost descending, matching the legend rows below) with hairline gaps so
/// adjacent same-family shades stay distinguishable. Unpriced models have no
/// cost and therefore no segment.
struct AgenticUseStackedShareBar: View {
    let modelTotals: [AgenticModelTotal]

    private var segments: [(total: AgenticModelTotal, fraction: Double)] {
        let priced = modelTotals.filter { $0.cost > 0 }
        let sum = priced.reduce(0) { $0 + $1.cost }
        guard sum > 0 else { return [] }
        return priced.map { ($0, $0.cost / sum) }
    }

    private static let gap: CGFloat = 1.5

    var body: some View {
        GeometryReader { geo in
            let segments = segments
            let available = max(0, geo.size.width - Self.gap * CGFloat(max(0, segments.count - 1)))
            HStack(spacing: Self.gap) {
                ForEach(segments, id: \.total.id) { segment in
                    Rectangle()
                        .fill(AgenticUseModelPalette.color(for: segment.total.model))
                        .frame(width: max(2, available * min(max(segment.fraction, 0), 1)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .frame(height: 12)
    }
}

/// One model in a provider section — the stacked bar's legend: color chip,
/// name, right-aligned cost, and a share/tokens caption.
private struct AgenticUseModelCostRow: View {
    let total: AgenticModelTotal

    private var tint: Color { AgenticUseModelPalette.color(for: total.model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(tint)
                    .frame(width: 8, height: 8)
                Text(total.displayName)
                    .scaledFont(size: 12, weight: .medium)
                    .lineLimit(1)
                if total.isUnpriced {
                    AgenticUseUnpricedBadge()
                }
                Spacer(minLength: 8)
                Text(total.isUnpriced ? "—" : AgenticUseFormat.cost(total.cost))
                    .scaledFont(size: 12, weight: .medium)
                    .monospacedDigit()
            }
            Text("\(AgenticUseFormat.percent(total.costShare)) of cost · \(AgenticUseFormat.tokens(total.tokens)) tokens")
                .scaledFont(size: 10)
                .foregroundStyle(.secondary)
                .monospacedDigit()
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
