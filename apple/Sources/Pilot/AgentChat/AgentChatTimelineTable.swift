import AppKit

/// The transcript table: no type-select, a step cursor with a focus ring
/// over visible steps (a collapsed card is one stop), chips, and records.
/// j/k move only while the table is first responder; Enter opens the
/// Inspector; "/" focuses the composer; Esc closes the Inspector, else
/// cancels a running turn from an empty composer, else nothing.
final class AgentChatTimelineTableView: NSTableView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        allowsTypeSelect = false
    }

    required init?(coder: NSCoder) { nil }
}

/// Data source and delegate for `AgentChatTimelineTableView`: one reuse
/// identifier per row kind, arithmetic heights cached by (row id, revision,
/// width, zoom, expanded, state), and minimal diffs in `applyRows`.
@MainActor
final class AgentChatTimelineTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /// How the last `applyRows` updated the table (budget tests).
    enum ApplyPath: Equatable, Sendable {
        /// Identical IDs: changed cells reconfigured in place.
        case reconfigure
        /// Rows appended at the tail.
        case insert
        /// Rows removed from the head (transcript trim).
        case headTrim
        case reload
    }

    let tableView: AgentChatTimelineTableView
    var actions = AgentChatRowActions()
    private(set) var rows: [AgentTimelineRow] = []
    private(set) var lastApplyPath: ApplyPath?

    init(tableView: AgentChatTimelineTableView) {
        self.tableView = tableView
        super.init()
    }

    func applyRows(_ rows: [AgentTimelineRow], now: Date) {
        // WP6: implement
        self.rows = rows
        lastApplyPath = .reload
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
}
