import AppKit

/// Parallel subagents as a wrapping row of chips. When none are running it
/// collapses to `{n} agents · {done} done · {failed} failed`; the chevron
/// (`actions.toggleExpanded(roster id)`) shows the chips again.
final class AgentRosterView: NSView {
    static let accessibilityIdentifierValue = "agent-chat.roster"

    init() {
        super.init(frame: .zero)
        setAccessibilityIdentifier(Self.accessibilityIdentifierValue)
    }

    required init?(coder: NSCoder) { nil }

    /// `expandedOverride` is the user's toggle (nil: expanded while any entry runs).
    func configure(entries: [AgentRosterEntry], expandedOverride: Bool?, now: Date, actions: AgentChatRowActions) {
        // WP4: implement
    }

    static func height(entries: [AgentRosterEntry], expandedOverride: Bool?, width: CGFloat) -> CGFloat {
        // WP4: implement
        24
    }
}

/// `{dot} {name} · {steps}`, ≤ 160 pt with tail truncation and a tooltip of
/// name, lifecycle, and elapsed time. Click opens the Inspector on
/// `.agent(childSessionID:)`; failed chips offer "Ask to continue…" in their
/// context menu (`actions.askToContinue`).
final class AgentChipView: NSView {
    static let accessibilityIdentifierValue = "agent-chat.chip"
    static let maximumWidth: CGFloat = 160

    init() {
        super.init(frame: .zero)
        setAccessibilityIdentifier(Self.accessibilityIdentifierValue)
    }

    required init?(coder: NSCoder) { nil }

    func configure(entry: AgentRosterEntry, now: Date, actions: AgentChatRowActions) {
        // WP4: implement
    }
}
