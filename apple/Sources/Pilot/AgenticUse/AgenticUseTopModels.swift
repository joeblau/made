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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Top Models").agenticUseCardTitle()
                Spacer(minLength: 8)
                if models.count > Self.collapsedCount {
                    Button {
                        withAnimation(.snappy) { showsAll.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(showsAll ? "Show Top \(Self.collapsedCount)" : "View All \(models.count) Models")
                            Image(systemName: showsAll ? "chevron.up" : "arrow.right")
                        }
                    }
                    .compatGlassButtonStyle()
                    .controlSize(.small)
                }
            }

            // One rule under the header; rows separate by spacing rather than a
            // divider on every line.
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
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
                    row(rank: index + 1, total: total)
                }
            }
        }
        .agenticUseCard()
    }

    private var trendTitle: String {
        snapshot.range == .day ? "24h Trend" : "\(snapshot.range.label) Trend"
    }

    private func row(rank: Int, total: AgenticModelTotal) -> some View {
        let tint = AgenticUseModelPalette.providerColor(for: total.provider)
        return GridRow {
            Text("\(rank)")
                .scaledFont(size: 12)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            HStack(spacing: 8) {
                Text(total.displayName)
                    .scaledFont(size: 12, weight: .medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if total.isUnpriced { AgenticUseUnpricedBadge() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(total.model)
            HStack(spacing: 4) {
                Image(total.provider.brandSymbol)
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(tint)
                    .frame(width: 14)
                Text(total.provider.displayName)
                    .scaledFont(size: 12)
                    .lineLimit(1)
            }
            number(total.isUnpriced ? "—" : AgenticUseFormat.cost(total.cost))
            number(AgenticUseFormat.tokens(total.tokens))
            number(total.costPerMillionTokens.map(AgenticUseFormat.cost) ?? "—")
                .help("Effective cost per million processed tokens, cache reads included")
            AgenticUseSparkline(values: snapshot.tokenTrend(for: total.model), tint: tint, lineWidth: 1.25)
                .frame(minWidth: 64, idealWidth: 120, maxWidth: 140)
                .frame(height: 22)
                .help("Tokens per \(snapshot.range.bucketUnit == .hour ? "hour" : "day")")
        }
        .padding(.vertical, 8)
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .scaledFont(size: 11, weight: .medium)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.bottom, 8)
    }

    private func number(_ text: String) -> some View {
        Text(text)
            .scaledFont(size: 12)
            .monospacedDigit()
            .lineLimit(1)
    }
}
