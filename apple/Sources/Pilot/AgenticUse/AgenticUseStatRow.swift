import SwiftUI

/// Five equal stat cells with divider rules, in one card. The store already
/// sums the numbers; this view only formats and lays them out.
struct AgenticUseStatRow: View {
    let stats: AgenticUseStats

    private struct Cell: Identifiable, Equatable {
        let label: String
        let value: String
        let caption: String

        var id: String { label }
    }

    var body: some View {
        let cells = cells
        return HStack(spacing: 24) {
            ForEach(cells) { cell in
                VStack(alignment: .leading, spacing: 3) {
                    Text(cell.label.uppercased())
                        .scaledFont(size: 10, weight: .semibold)
                        .kerning(0.6)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(cell.value)
                        .scaledFont(size: 20, weight: .semibold, design: .rounded)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(cell.caption)
                        .scaledFont(size: 10)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.7), value: cells)
        .agenticUseCard()
    }

    private var cells: [Cell] {
        [
            Cell(
                label: "Processed tokens",
                value: AgenticUseFormat.tokens(stats.processedTokens),
                caption: "\(AgenticUseFormat.tokens(stats.processedPerActiveDay)) per active day"
            ),
            Cell(
                label: "Cached input",
                value: AgenticUseFormat.tokens(stats.cachedInputTokens),
                caption: "\(AgenticUseFormat.percent(stats.cachedInputShare)) of observed input"
            ),
            Cell(
                label: "Uncached input",
                value: AgenticUseFormat.tokens(stats.uncachedInputTokens),
                caption: "\(AgenticUseFormat.tokens(stats.cacheWriteTokens)) cache write tokens"
            ),
            Cell(
                label: "Output",
                value: AgenticUseFormat.tokens(stats.outputTokens),
                caption: outputCaption
            ),
            Cell(
                label: "Cache savings",
                value: AgenticUseFormat.cost(stats.cacheSavingsUSD),
                caption: savingsCaption
            ),
        ]
    }

    /// Reasoning tokens are only logged by recent CLI versions, so the figure
    /// is a lower bound — caption it as such, and fall back to a per-day rate
    /// when nothing in range reported them.
    private var outputCaption: String {
        if let reasoning = stats.reasoningTokens {
            return "includes \(AgenticUseFormat.tokens(reasoning)) reasoning (where reported)"
        }
        guard stats.activeDays > 0 else { return "no active days" }
        return "\(AgenticUseFormat.tokens(stats.outputTokens / stats.activeDays)) per active day"
    }

    private var savingsCaption: String {
        guard let multiple = stats.cacheSavingsMultiple else { return "vs. full API rate" }
        return "\(AgenticUseFormat.multiple(multiple)) the raw token cost"
    }
}
