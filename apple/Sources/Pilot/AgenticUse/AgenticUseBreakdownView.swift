import SwiftUI

/// The Breakdown table card: MODEL mode (per-model totals, cost descending)
/// or DAY mode (per-day totals, newest first). Hand-rolled `Grid` rows rather
/// than SwiftUI `Table` — the house style is chrome-free rows, and `Table`
/// brings selection chrome that doesn't fit the dashboard.
struct AgenticUseBreakdownView: View {
    let modelTotals: [AgenticModelTotal]
    let dayTotals: [AgenticDayTotal]

    @State private var mode: Mode = .model

    enum Mode: String, CaseIterable, Identifiable {
        case model = "Model"
        case day = "Day"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Breakdown")
                    .scaledFont(size: 13, weight: .semibold)
                Spacer(minLength: 8)
                Picker("Breakdown mode", selection: $mode) {
                    ForEach(Mode.allCases) { mode in
                        Text(mode.rawValue.uppercased()).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .fixedSize()
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                GridRow {
                    headerCell(mode == .model ? "MODEL" : "DAY")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    headerCell("COST")
                        .gridColumnAlignment(.trailing)
                    headerCell("SHARE")
                        .gridColumnAlignment(.trailing)
                    headerCell("TOKENS")
                        .gridColumnAlignment(.trailing)
                }
                switch mode {
                case .model:
                    ForEach(modelTotals) { total in
                        modelRow(total)
                    }
                case .day:
                    ForEach(dayTotals) { day in
                        dayRow(day)
                    }
                }
            }
        }
        .agenticUseCard()
    }

    // MARK: - Rows

    private func modelRow(_ total: AgenticModelTotal) -> some View {
        GridRow {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(AgenticUseModelPalette.color(for: total.model))
                    .frame(width: 8, height: 8)
                Text(total.displayName)
                    .scaledFont(size: 12, weight: .medium)
                    .lineLimit(1)
                if total.isUnpriced {
                    AgenticUseUnpricedBadge()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
            numberCell(total.isUnpriced ? "—" : AgenticUseFormat.cost(total.cost))
            numberCell(total.isUnpriced ? "—" : AgenticUseFormat.percent(total.costShare))
            numberCell(AgenticUseFormat.tokens(total.tokens))
        }
    }

    private func dayRow(_ day: AgenticDayTotal) -> some View {
        GridRow {
            Text(day.day, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                .scaledFont(size: 12, weight: .medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
            numberCell(AgenticUseFormat.cost(day.cost))
            numberCell(AgenticUseFormat.percent(day.costShare))
            numberCell(AgenticUseFormat.tokens(day.tokens))
        }
    }

    // MARK: - Cells

    private func headerCell(_ text: String) -> some View {
        Text(text)
            .scaledFont(size: 10, weight: .semibold)
            .kerning(0.6)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
    }

    private func numberCell(_ text: String) -> some View {
        Text(text)
            .scaledFont(size: 12)
            .monospacedDigit()
            .gridColumnAlignment(.trailing)
            .padding(.vertical, 5)
    }
}
