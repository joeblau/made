import SwiftUI

/// Detail-area view for the global Agentic Use mode: a historical Claude Code
/// cost dashboard parsed from the local `~/.claude/projects` transcripts.
///
/// Header bar over a scrolling stack of cards — hero total plus per-model
/// breakdown, the daily cost chart, a five-cell stat row, and the breakdown
/// table. All aggregation lives in `AgenticUsageStore`; this file only draws.
struct AgenticUseView: View {
    @Bindable var store: AgenticUsageStore

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            if let warning = store.scanWarning {
                warningBanner(warning)
            }
            content
        }
        .onAppear { store.start() }
        .onDisappear { store.stop() }
    }

    // MARK: - Header bar

    private var headerBar: some View {
        HStack(spacing: 10) {
            Text("Agentic Use")
                .scaledFont(size: 13, weight: .semibold)

            if let interval = store.snapshot?.interval {
                Text((interval.start..<interval.end).formatted(.interval.month(.abbreviated).day()))
                    .scaledFont(size: 12)
                    .foregroundStyle(.secondary)
            }

            if store.isRefreshing {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }

            Spacer(minLength: 12)

            Picker("Range", selection: $store.range) {
                ForEach(AgenticUseRange.allCases) { range in
                    Text(range.label).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .fixedSize()

            Button {
                store.rescan()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .scaledFont(size: 12, weight: .medium)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Rescan usage logs")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func warningBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .scaledFont(size: 12)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button {
                store.dismissScanWarning()
            } label: {
                Image(systemName: "xmark")
                    .scaledFont(size: 10, weight: .semibold)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .scanning(let scanned, let total):
            scanningState(scanned: scanned, total: total)
        case .empty:
            emptyState
        case .failed(let reason):
            failedState(reason)
        case .loaded:
            if let snapshot = store.snapshot {
                if snapshot.isEmpty {
                    rangeEmptyState
                } else {
                    dashboard(snapshot)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func dashboard(_ snapshot: AgenticUseSnapshot) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    AgenticUseHeroPanel(
                        totalCost: snapshot.totalCostUSD,
                        modelTotals: snapshot.modelTotals,
                        hasUnpricedModels: snapshot.hasUnpricedModels
                    )
                    .frame(width: 300)

                    AgenticUseDailyChartPanel(snapshot: snapshot)
                        .frame(maxWidth: .infinity)
                }
                AgenticUseStatRow(stats: snapshot.stats)
                AgenticUseBreakdownView(
                    modelTotals: snapshot.modelTotals,
                    dayTotals: snapshot.dayTotals
                )
            }
            .padding(12)
        }
    }

    // MARK: - States

    private func scanningState(scanned: Int, total: Int) -> some View {
        VStack(spacing: 12) {
            if let progress = store.scanProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 240)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Text("Scanning agent CLI logs…")
                .scaledFont(size: 12)
                .foregroundStyle(.secondary)
            if total > 0 {
                Text("\(scanned.formatted()) of \(total.formatted()) files")
                    .scaledFont(size: 11)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Usage Data", systemImage: "chart.line.uptrend.xyaxis")
        } description: {
            VStack(spacing: 6) {
                Text("No agent CLI logs were found (Claude Code, Codex, Grok, or Kimi).")
                Text("Run an agent session and this dashboard fills in.")
                    .foregroundStyle(.tertiary)
            }
        } actions: {
            Button("Rescan") { store.rescan() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var rangeEmptyState: some View {
        ContentUnavailableView {
            Label("Nothing in This Range", systemImage: "calendar.badge.exclamationmark")
        } description: {
            Text("No usage recorded in the last \(rangeDescription). Try a wider range.")
        }
    }

    private var rangeDescription: String {
        switch store.range {
        case .day: "24 hours"
        case .all: "log history"
        default: "\(store.range.dayCount) days"
        }
    }

    private func failedState(_ reason: String) -> some View {
        ContentUnavailableView {
            Label("Can't Read Usage Logs", systemImage: "exclamationmark.triangle")
        } description: {
            Text(reason)
        } actions: {
            Button("Retry") { store.rescan() }
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Shared card chrome

extension View {
    /// The dashboard's card treatment, matching the inspector card idiom
    /// (`.quaternary` fill, continuous 8pt corners).
    func agenticUseCard(minHeight: CGFloat? = nil) -> some View {
        padding(12)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .background(
                .quaternary.opacity(0.4),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
    }
}
