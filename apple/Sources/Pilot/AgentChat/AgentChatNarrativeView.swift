import AppKit

/// Agent prose: no bubble, selectable text (capped 1200 pt inner scroll so
/// streaming and scroll-follow behave as before), hover-only "Copy" for the
/// whole message, bordered code blocks with per-block hover copy, colored
/// ```diff fences, and only http/https/mailto links.
final class ProseCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("agent-chat.prose")

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        setAccessibilityIdentifier(Self.reuseIdentifier.rawValue)
    }

    required init?(coder: NSCoder) { nil }

    /// `item.content` is `.assistant`. `followStreamingOutput` keeps the inner
    /// scroll pinned to the newest text while the reader is at the bottom.
    func configure(item: AgentChatItem, isStreaming: Bool, followStreamingOutput: Bool, actions: AgentChatRowActions) {
        // WP4: implement
    }

    static func height(item: AgentChatItem, width: CGFloat) -> CGFloat {
        // WP4: implement
        36
    }
}

/// User message: right-aligned bubble ≤ 75% width, accent-tinted surface,
/// attachments, no copy icon.
final class UserBubbleCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("agent-chat.user")

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        setAccessibilityIdentifier(Self.reuseIdentifier.rawValue)
    }

    required init?(coder: NSCoder) { nil }

    /// `item.content` is `.user`; attachments come from `item.attachments`.
    func configure(item: AgentChatItem, actions: AgentChatRowActions) {
        // WP4: implement
    }

    static func height(item: AgentChatItem, width: CGFloat) -> CGFloat {
        // WP4: implement
        36
    }
}

/// Notices such as stop reasons. No copy; a failed-turn notice offers "Send again".
final class NoticeCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("agent-chat.notice")

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        setAccessibilityIdentifier(Self.reuseIdentifier.rawValue)
    }

    required init?(coder: NSCoder) { nil }

    /// `item.content` is `.notice`. "Send again" calls `actions.sendAgain`.
    func configure(item: AgentChatItem, offersSendAgain: Bool, actions: AgentChatRowActions) {
        // WP4: implement
    }

    static func height(item: AgentChatItem, width: CGFloat) -> CGFloat {
        // WP4: implement
        28
    }
}

/// Compact `☰ Plan · 3/7 done` row; click opens the Inspector on `.plan(key:)`.
final class PlanRowView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("agent-chat.plan")

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        setAccessibilityIdentifier(Self.reuseIdentifier.rawValue)
    }

    required init?(coder: NSCoder) { nil }

    /// `item.content` is `.plan`.
    func configure(item: AgentChatItem, actions: AgentChatRowActions) {
        // WP4: implement
    }

    static func height(item: AgentChatItem, width: CGFloat) -> CGFloat {
        // WP4: implement
        28
    }
}
