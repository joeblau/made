import SwiftUI

/// Ranked model table: cost, tokens, effective $/1M tokens, and a usage
/// sparkline per model over the selected range. Shows the top ten by cost,
/// with a toggle for the full list. Hand-rolled `Grid` rows rather than
/// SwiftUI `Table` — the house style is chrome-free rows.
struct AgenticUseTopModels: View {
    let snapshot: AgenticUseSnapshot

    @State private var showsAll = false

    private static let collapsedCount = 10

    var body: some View {
        let models = snapshot.modelTotals
        let visible = showsAll ? models : Array(models.prefix(Self.collapsedCount))
        let trends = snapshot.tokenTrends
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.small) {
            HStack {
                Text("Top Models").agenticUseCardTitle()
                Spacer(minLength: LiquidGlassMetrics.Spacing.xSmall)
                if models.count > Self.collapsedCount {
                    // Secondary glass: disclosure, not the view's primary action.
                    Button {
                        withAnimation(LiquidGlassMetrics.spring) { showsAll.toggle() }
                    } label: {
                        Label(
                            showsAll ? "Show Top \(Self.collapsedCount)" : "View All \(models.count) Models",
                            systemImage: showsAll ? "chevron.up" : "chevron.down"
                        )
                        .labelStyle(.titleAndIcon)
                        .contentTransition(.symbolEffect(.replace))
                    }
                    .compatGlassButtonStyle()
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                }
            }

            // One rule under the header; rows separate by spacing rather than a
            // divider on every line.
            Grid(alignment: .leading, horizontalSpacing: LiquidGlassMetrics.Spacing.medium, verticalSpacing: 0) {
                GridRow {
                    header("#")
                    header("Model").frame(maxWidth: .infinity, alignment: .leading)
                    header("Provider")
                    header("Cost").gridColumnAlignment(.trailing)
                    header("Tokens").gridColumnAlignment(.trailing)
                    header("$/1M").gridColumnAlignment(.trailing)
                    header(trendTitle)
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, total in
                    row(rank: index + 1, total: total, trend: trends[total.model] ?? [])
                }
            }
        }
        .agenticUseCard()
    }

    private var trendTitle: String {
        snapshot.range == .day ? "24h Trend" : "\(snapshot.range.label) Trend"
    }

    private func row(rank: Int, total: AgenticModelTotal, trend: [Double]) -> some View {
        let tint = AgenticUseModelPalette.providerColor(for: total.provider)
        return GridRow {
            Text("\(rank)")
                .agenticUseFont(.body)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                Text(total.displayName)
                    .agenticUseFont(.body, weight: .medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if total.isUnpriced { AgenticUseUnpricedBadge() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(total.model)
            HStack(spacing: LiquidGlassMetrics.Spacing.xxSmall) {
                Image(total.provider.brandSymbol)
                    .agenticUseFont(.meta, weight: .semibold)
                    .foregroundStyle(tint)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(total.provider.displayName)
                    .agenticUseFont(.body)
                    .lineLimit(1)
            }
            number(total.isUnpriced ? "—" : AgenticUseFormat.cost(total.cost))
            number(AgenticUseFormat.tokens(total.tokens))
            number(total.costPerMillionTokens.map(AgenticUseFormat.cost) ?? "—")
                .help("Effective cost per million processed tokens, cache reads included")
            AgenticUseSparkline(values: trend, tint: tint, lineWidth: 1.25)
                .frame(minWidth: 64, idealWidth: 120, maxWidth: 140)
                .frame(height: 24)
                .help("Tokens per \(snapshot.range.bucketUnit == .hour ? "hour" : "day")")
        }
        .padding(.vertical, LiquidGlassMetrics.Spacing.xSmall)
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .agenticUseFont(.meta, weight: .medium)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.bottom, LiquidGlassMetrics.Spacing.xSmall)
    }

    private func number(_ text: String) -> some View {
        Text(text)
            .agenticUseFont(.body)
            .monospacedDigit()
            .lineLimit(1)
    }
}
