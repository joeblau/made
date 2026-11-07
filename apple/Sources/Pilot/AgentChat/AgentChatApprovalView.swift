import AppKit

/// A pending permission request, docked above the composer (head of the
/// queue). Names the requesting agent (`approval.agentName`: root, child
/// title, or "untracked subagent"); shows the title, verb, and the full
/// `verb.exactInput` in a scrollable monospaced view with secrets masked and a
/// reveal affordance. One button per agent option in the agent's order with
/// names verbatim; never default/primary on allow_always or mode-changing
/// (exit-plan-*) options; plus "Cancel Request". Buttons wrap vertically when
/// narrow. Never takes first responder automatically; Return activates the
/// first option only when the card has explicit focus.
final class ApprovalCardView: NSView {
    static let accessibilityIdentifierValue = "agent-chat.approval"

    init() {
        super.init(frame: .zero)
        setAccessibilityIdentifier(Self.accessibilityIdentifierValue)
    }

    required init?(coder: NSCoder) { nil }

    /// `moreCount` requests wait behind this one ("N more"). `onChoose`
    /// receives the option ID.
    func configure(
        approval: AgentChatItem.Approval,
        verb: AgentToolVerb,
        moreCount: Int,
        onChoose: @escaping (String) -> Void,
        onCancelRequest: @escaping () -> Void
    ) {
        // WP4: implement
    }

    static func height(approval: AgentChatItem.Approval, verb: AgentToolVerb, width: CGFloat) -> CGFloat {
        // WP4: implement
        96
    }
}

/// A decided approval in the timeline: "Approved · <option name>",
/// "Rejected · <name>", "Cancelled", "Withdrawn by agent", or "Stopped".
final class ApprovalRecordView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("agent-chat.approval-record")

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        setAccessibilityIdentifier(Self.reuseIdentifier.rawValue)
    }

    required init?(coder: NSCoder) { nil }

    /// `item.content` is `.approval`.
    func configure(item: AgentChatItem, actions: AgentChatRowActions) {
        // WP4: implement
    }

    static func height(item: AgentChatItem, width: CGFloat) -> CGFloat {
        // WP4: implement
        24
    }
}
