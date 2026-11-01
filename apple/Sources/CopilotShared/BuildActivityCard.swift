import SwiftUI

/// Shared with presentation tests so the Lock Screen layout is rendered directly.
struct BuildActivityCard: View {
    let attributes: BuildActivityAttributes
    let state: BuildActivityState
    let isStale: Bool
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 8 : 12) {
            Image(systemName: state.symbol)
                .font(compact ? .body : .title2).foregroundStyle(state.buildTint)
                // Status changes swap the glyph in place rather than cutting (MOT-4).
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 4) {
                Text(attributes.workflow).font(.headline).lineLimit(1)
                Text(compact ? attributes.branch : "\(attributes.repository) · \(attributes.branch)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack {
                    if isStale && !state.isComplete {
                        // Same caution treatment as the dashboard activities:
                        // the glyph carries the orange signal, the copy stays
                        // secondary so caption text keeps contrast (COL-2).
                        Label {
                            Text("Updates delayed")
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "wifi.slash")
                                .foregroundStyle(.orange)
                        }
                        .lineLimit(1)
                    } else {
                        Text(state.label)
                            .contentTransition(.opacity)
                    }
                    Spacer(minLength: 4)
                    // Queued runs have no clock; the status text already
                    // reads "Queued", so the trailing slot stays empty.
                    if state.startedAt != nil {
                        BuildElapsedTime(state: state)
                    }
                }
                .font(.caption)
            }
        }
        .padding(compact ? 8 : 16)
    }
}

extension BuildActivityState {
    var buildTint: Color {
        guard isComplete else { return .blue }
        switch conclusion {
        case "success": return .green
        case "failure", "startup_failure", "timed_out": return .red
        default: return .secondary
        }
    }
}
