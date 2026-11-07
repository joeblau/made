import AppKit

/// One keyboard stop in the transcript (spec §3.8): a visible step or
/// thought, a collapsed card, an agent chip, or a record (approval or plan).
enum AgentChatCursorStop: Equatable, Sendable {
    case step(key: String, isThought: Bool)
    case card(groupID: String)
    case chip(childSessionID: String, groupID: String)
    case record(key: String)

    var id: String {
        switch self {
        case .step(let key, _): "step:" + key
        case .card(let id): "card:" + id
        case .chip(let child, let group): "chip:\(group)/\(child)"
        case .record(let key): "record:" + key
        }
    }
}

/// The transcript's step cursor and its focus ring. j/k move it only while
/// the table is first responder; Enter opens the stop in the Inspector.
@MainActor
final class AgentChatTimelineCursor {
    let tableView: AgentChatTimelineTableView
    weak var timeline: AgentChatTimelineTable?
    private(set) var stop: AgentChatCursorStop?
    let ring = AgentChatCursorRingView()

    init(tableView: AgentChatTimelineTableView) {
        self.tableView = tableView
        ring.isHidden = true
    }

    var isFocused: Bool { tableView.window?.firstResponder === tableView }

    /// Every stop in row order, with its row.
    func stops() -> [(row: Int, stop: AgentChatCursorStop)] {
        guard let timeline else { return [] }
        var stops: [(Int, AgentChatCursorStop)] = []
        for (index, row) in timeline.rows.enumerated() {
            switch row {
            case .activity(let group):
                let layout = group.layout(expandedOverride: timeline.expandedOverrides[group.id],
                                          showAll: timeline.showAllGroups.contains(group.id))
                if layout.showsCardChrome, !layout.isExpanded {
                    stops.append((index, .card(groupID: group.id)))
                    continue
                }
                for case .member(let member) in layout.entries {
                    switch member {
                    case .step(let item): stops.append((index, .step(key: item.key, isThought: false)))
                    case .thought(let item): stops.append((index, .step(key: item.key, isThought: true)))
                    case .agents(let entries):
                        let id = member.id
                        guard AgentRosterView.isExpanded(entries: entries, expandedOverride: timeline.rosterOverrides[id]) else { continue }
                        stops += entries.map { (index, .chip(childSessionID: $0.id, groupID: group.id)) }
                    }
                }
            case .approvalRecord(let item), .plan(let item):
                stops.append((index, .record(key: item.key)))
            case .user, .prose, .notice:
                continue
            }
        }
        return stops
    }

    /// Moves to the next (`delta` 1) or previous (-1) stop; with no stop yet,
    /// starts from the visible rows.
    @discardableResult
    func move(by delta: Int) -> Bool {
        let all = stops()
        guard !all.isEmpty else { return false }
        let target: Int
        if let stop, let current = all.firstIndex(where: { $0.stop == stop }) {
            target = min(max(0, current + delta), all.count - 1)
        } else {
            let visible = timeline?.visibleRows() ?? []
            if delta > 0 {
                target = all.firstIndex { $0.row >= (visible.first ?? 0) } ?? 0
            } else {
                target = all.lastIndex { $0.row <= (visible.last ?? Int.max) } ?? all.count - 1
            }
        }
        select(all[target].stop, row: all[target].row)
        return true
    }

    func select(_ stop: AgentChatCursorStop, row: Int) {
        self.stop = stop
        tableView.scrollRowToVisible(row)
        updateRing()
    }

    /// Places the cursor on the stop under a click, if any.
    func select(at point: NSPoint) {
        let row = tableView.row(at: point)
        guard row >= 0 else { return }
        for candidate in stops() where candidate.row == row {
            if let rect = rect(for: candidate.stop, row: row, create: false), rect.insetBy(dx: -2, dy: -2).contains(point) {
                stop = candidate.stop
                updateRing()
                return
            }
        }
    }

    /// The Inspector subject Enter opens for the current stop.
    func subject() -> AgentInspectorSubject? {
        switch stop {
        case .step(let key, let isThought)?: return isThought ? .thought(key: key) : .step(key: key)
        case .card(let id)?: return .group(id: id)
        case .chip(let child, _)?: return .agent(childSessionID: child)
        case .record(let key)?:
            guard let timeline, let row = timeline.rows.first(where: { $0.id == key }) else { return nil }
            switch row {
            case .plan: return .plan(key: key)
            case .approvalRecord(let item):
                guard case .approval(let approval) = item.content, let callID = approval.toolCallID else { return nil }
                for case .activity(let group) in timeline.rows {
                    for case .step(let step) in group.members {
                        if case .tool(let tool) = step.content, tool.toolCallID == callID { return .step(key: step.key) }
                    }
                }
                return nil
            default: return nil
            }
        case nil: return nil
        }
    }

    /// Rows changed: drop a stop that no longer exists and move the ring.
    /// Unfocused, nothing is drawn and `move` ignores a stale stop, so the
    /// full stop list (a layout per group) isn't rebuilt on every render.
    func rowsChanged() {
        guard isFocused else { return }
        if let stop, !stops().contains(where: { $0.stop == stop }) { self.stop = nil }
        updateRing()
    }

    func focusChanged() { updateRing() }

    func updateRing() {
        guard isFocused, let stop, let row = stops().first(where: { $0.stop == stop })?.row,
              let rect = rect(for: stop, row: row, create: true) else {
            ring.isHidden = true
            return
        }
        if ring.superview !== tableView || tableView.subviews.last !== ring {
            tableView.addSubview(ring, positioned: .above, relativeTo: nil)
        }
        ring.frame = rect.insetBy(dx: -2, dy: -2)
        ring.isHidden = false
    }

    /// The stop's frame in table coordinates.
    func rect(for stop: AgentChatCursorStop, row: Int, create: Bool) -> NSRect? {
        let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: create)
        cell?.layoutSubtreeIfNeeded()
        let view: NSView?
        switch stop {
        case .step(let key, _):
            view = (cell as? ActivityCardView)?.stepViews[key]
        case .card:
            let card = cell as? ActivityCardView
            view = card?.chrome.isHidden == false ? card?.chrome : card
        case .chip(let child, _):
            view = (cell as? ActivityCardView)?.rosterViews.values.compactMap { $0.chipViews[child] }.first
        case .record:
            return tableView.rect(ofRow: row).insetBy(dx: 6, dy: 0)
        }
        guard let view, view.superview != nil, !view.isHidden else { return nil }
        return tableView.convert(view.bounds, from: view)
    }
}

/// A rounded keyboard-focus ring drawn over the cursor's stop; never hit-tested.
final class AgentChatCursorRingView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.keyboardFocusIndicatorColor.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 6, yRadius: 6)
        path.lineWidth = 2.5
        path.stroke()
    }

    override func isAccessibilityElement() -> Bool { false }
}
