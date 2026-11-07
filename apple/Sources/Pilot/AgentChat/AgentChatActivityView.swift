import AppKit

/// One activity group. Header: the chevron toggles disclosure
/// (`actions.toggleExpanded(group.id)`); the label opens the Inspector on
/// `.group(id:)`. Label: `{summary} · {n} steps · {k} failed · {n} stopped ·
/// {duration}`, truncating the summary first. Live: shimmer liveStatus line
/// and steps streaming newest at the bottom (last 6 + "N earlier" past 15).
/// Settling: animates closed, then calls `actions.collapseFinished(group.id)`
/// (immediately under Reduce Motion or a hidden window). Settled: one line
/// plus failed rows beneath; expanded past 15 steps shows first 2 + last 2 +
/// "Show N more" (`actions.showAll(group.id)`). Settled groups of ≤ 3 steps
/// with no failures or agents render inline without card chrome.
final class ActivityCardView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("agent-chat.activity")

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        setAccessibilityIdentifier(Self.reuseIdentifier.rawValue)
    }

    required init?(coder: NSCoder) { nil }

    /// `expandedOverride` is the user's toggle for this group (nil follows
    /// `group.state`). `showAll` expands a long settled group fully. `now`
    /// drives the live elapsed duration.
    func configure(
        group: AgentActivityGroup,
        expandedOverride: Bool?,
        showAll: Bool,
        now: Date,
        actions: AgentChatRowActions
    ) {
        // WP4: implement
    }

    /// Updates only the ticking duration (the controller's 1 Hz timer while a
    /// live group and its window are visible).
    func tick(now: Date) {
        // WP4: implement
    }

    static func height(group: AgentActivityGroup, expandedOverride: Bool?, showAll: Bool, width: CGFloat) -> CGFloat {
        // WP4: implement
        32
    }
}

/// One step: glyph + verb (13 pt) + muted detail line. Failed: red dot,
/// inline errorSummary, "Ask to retry…" (hidden for replayed, cancelled, and
/// rejected steps). Hover shows `verb.exactInput` in a tooltip and a "Copy
/// command" button. Click opens the Inspector (`.step`, or `.thought` on the
/// Reasoning tab). Thoughts are never copyable from the thread. Exposes AX
/// custom actions: Copy command, Open in Inspector, Ask to retry.
final class ActivityStepView: NSView {
    static let accessibilityIdentifierValue = "agent-chat.step"

    init() {
        super.init(frame: .zero)
        setAccessibilityIdentifier(Self.accessibilityIdentifierValue)
    }

    required init?(coder: NSCoder) { nil }

    /// `item.content` is `.tool` or `.thought`; `verb` comes from
    /// `verbForTool(_:input:)` or `verbForThought(_:now:)`.
    func configure(item: AgentChatItem, verb: AgentToolVerb, actions: AgentChatRowActions) {
        // WP4: implement
    }

    static func height(item: AgentChatItem, verb: AgentToolVerb, width: CGFloat) -> CGFloat {
        // WP4: implement
        22
    }
}
