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
            VStack(alignment: .leading, spacing: 4) {
                Text(attributes.workflow).font(.headline).lineLimit(1)
                Text(compact ? attributes.branch : "\(attributes.repository) · \(attributes.branch)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack {
                    Text(isStale && !state.isComplete ? "Updates delayed" : state.label)
                    Spacer(minLength: 4)
                    BuildElapsedTime(state: state)
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
