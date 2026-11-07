import Foundation

// MARK: - Agent Chat redesign contract index
//
// These contracts are frozen: work packages implement bodies, not shapes.
// Keys are namespaced "<sessionID or root>/<itemID>" (`AgentChatItem.key`).
//
// Model (WP1 owns ACPMessages.swift, AgentTranscript.swift):
// - ACPToolLocation, ACPToolContent, ACPBoundedJSON, ACPSteerOutcome,
//   ACP.Method.steer/.cancelRequest, ACP.steerParams(sessionID:text:),
//   new fields on ACPToolCallFields, ACPSubagentState, ACPPermissionRequest,
//   ACPAgentInfo.supportsSteering, ACPUpdate.agentThought(text:messageID:)
//   — ACPMessages.swift.
// - AgentEditSummary, AgentChatItem (revision, turnIndex, isReplayed,
//   sessionKey, key), ToolCall (+Outcome, isRunning), Thought,
//   Subagent (+Lifecycle), Approval (+Decision), Content.approval,
//   AgentStepDetail, AgentActivityEvent, AgentTranscript.apply(_:rootSessionID:now:),
//   finishTurn, recordApproval, resolveApproval, stepStats, stepDetails,
//   isReplaying, maximumChildSessions — AgentTranscript.swift.
// Session (WP2 owns AgentChatSession.swift, ACPConnection.swift):
// - init(now:), isTurnRunning, hasBackgroundAgents, canSteer, steer(_:),
//   queueForNextTurn(_:), queuedPrompt, prefillAskToRetry(stepKey:),
//   prefillAskToContinue(childSessionID:), sendAgain(), dismissPermission(_:),
//   recentEvents, eventSequence.
// Pure presentation (WP3):
// - AgentTimelineRow, AgentActivityGroup, AgentActivityMember,
//   AgentRosterEntry, AgentTimeline.project, AgentActivityState,
//   AgentActivityInput, AgentActivityMachine — this file.
//   Additive WP3 helpers: AgentActivityGroup.plan (AgentPlanProgress),
//   AgentTimeline.project(items:…) (for callers without a transcript),
//   AgentActivityMachine.reduce(_:_:runningCount:closed:),
//   AgentTimeline.machineInputs, AgentActivityGroup weight/layout/header
//   (rendersInline, animatesSettle, layout(expandedOverride:showAll:) → AgentActivityLayout,
//   header(now:) → AgentActivityHeader, failedMembers, duration(now:)),
//   AgentActivityFormat.duration, AgentActivityText.liveSentence.
// - AgentToolVerb (+Glyph), verbForTool(_:input:), verbForThought(_:now:)
//   — AgentToolVerb.swift. Additive: verbForItem(_:input:now:),
//   verbForTool(_:input:includeExactInput:) (labels only when false),
//   AgentToolVerb.glyph(for:input:) (cheap, label-free).
// - AgentRedaction, redactOutput(_:maximumLines:), redactJSON(_:),
//   redactInline(_:) — AgentOutputRedaction.swift. Additive: redactProse(_:),
//   redactFileContent(path:text:maximumLines:), isSecretLikePath(_:),
//   redactOutputInBackground(_:maximumLines:) (> 64 KiB off the main actor),
//   AgentRedactionCache (keyed by item key + revision + variant).
// Leaf views (WP4). Every view is @MainActor, created with `init()`, sets its
// accessibility identifier, takes value inputs plus `AgentChatRowActions`
// (never the session), and offers an arithmetic `height` for the table:
// - AgentChatGlyphs.swift: AgentChatPalette (Token + color(_:)),
//   AgentChatMotion (reduceMotion, duration), AgentChatGlyphs.image(for:pointSize:),
//   AgentChatRowActions (shared callbacks), AgentStatusDotView
//   — configure(status: AgentStatusDotView.Status).
// - AgentChatNarrativeView.swift (table cells):
//   ProseCellView — configure(item:isStreaming:followStreamingOutput:actions:),
//     height(item:width:);
//   UserBubbleCellView — configure(item:actions:), height(item:width:);
//   NoticeCellView — configure(item:offersSendAgain:actions:), height(item:width:);
//   PlanRowView — configure(item:actions:), height(item:width:).
// - AgentChatActivityView.swift:
//   ActivityCardView (table cell) — configure(group:expandedOverride:showAll:now:actions:),
//     tick(now:), height(group:expandedOverride:showAll:width:);
//   ActivityStepView — configure(item:verb:actions:), height(item:verb:width:).
// - AgentChatRosterView.swift:
//   AgentRosterView — configure(entries:expandedOverride:now:actions:),
//     height(entries:expandedOverride:width:);
//   AgentChipView — configure(entry:now:actions:), maximumWidth.
// - AgentChatApprovalView.swift:
//   ApprovalCardView (docked) — configure(approval:verb:moreCount:onChoose:onCancelRequest:),
//     height(approval:verb:width:);
//   ApprovalRecordView (table cell) — configure(item:actions:), height(item:width:).
// Inspector (WP5) — AgentChatInspectorView.swift:
// - AgentInspectorSubject, AgentInspectorTab, AgentInspectorContent,
//   AgentRunTrace (json, stepJSON), AgentInspectorViewController
//   — init(allowsReasoningExport:), present(_:tab:), update(_:), dismiss(),
//   onClose, makeRunTrace, isPresented, subject, minimumWidth/maximumWidth.
// Integration (WP6) — AgentChatTimelineTable.swift:
// - AgentChatTimelineTableView (NSTableView subclass, step cursor, keys),
//   AgentChatTimelineTable (data source/delegate) — init(tableView:),
//   applyRows(_:now:), rows, actions, lastApplyPath; disclosure state and the 1 Hz tick.
//   AgentChatTimelineCursor.swift (step cursor, focus ring); AgentChatPaneSupport.swift
//   (AgentChatPaneContent for Inspector/approval inputs, AgentChatAgentMenu, AgentChatFormat).

/// One row of the redesigned transcript.
enum AgentTimelineRow: Equatable, Identifiable, Sendable {
    case user(AgentChatItem)
    case prose(AgentChatItem)
    case activity(AgentActivityGroup)
    case approvalRecord(AgentChatItem)
    case plan(AgentChatItem)
    case notice(AgentChatItem)

    var id: String {
        switch self {
        case .user(let item), .prose(let item), .approvalRecord(let item), .plan(let item), .notice(let item):
            item.key
        case .activity(let group):
            group.id
        }
    }
}

/// One member of an activity group.
enum AgentActivityMember: Equatable, Identifiable, Sendable {
    case step(AgentChatItem)
    case thought(AgentChatItem)
    /// Consecutive subagents, shown as one roster.
    case agents([AgentRosterEntry])

    var id: String {
        switch self {
        case .step(let item), .thought(let item): item.key
        case .agents(let entries): "roster-\(entries.first?.id ?? "empty")"
        }
    }
}

/// Consecutive steps, thoughts, and subagents between two narrative rows.
struct AgentActivityGroup: Equatable, Identifiable, Sendable {
    /// "activity-<key of the first member>".
    var id: String
    /// The highest member revision; the height-cache key.
    var revision = 0
    var members: [AgentActivityMember]
    var state: AgentActivityState = .idle
    var startedAt: Date?
    var endedAt: Date?
    var stepCount = 0
    var failedCount = 0
    var stoppedCount = 0
    /// Redacted live line: thought sentence, "Waiting for approval", live verb, or "Working…".
    var liveStatus: String?
    /// "Explored repo", "Edited files", …
    var summary = ""
    var hasPendingApproval = false
    /// The turn's plan progress, set while the group is live so the card can
    /// show "Plan · 3/7 done" beside the live line.
    var plan: AgentPlanProgress?
}

struct AgentRosterEntry: Equatable, Identifiable, Sendable {
    /// The child session ID.
    var id: String
    var name: String
    var lifecycle: AgentChatItem.Subagent.Lifecycle
    var steps: Int
    var failed: Int
    var startedAt: Date?
    var endedAt: Date?
}

/// "☰ Plan · 3/7 done".
struct AgentPlanProgress: Equatable, Sendable {
    var done: Int
    var total: Int

    init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }

    init?(entries: [ACPPlanEntry]) {
        guard !entries.isEmpty else { return nil }
        done = entries.filter { $0.status.lowercased() == "completed" }.count
        total = entries.count
    }

    var label: String { "Plan · \(done)/\(total) done" }
}

enum AgentTimeline {
    /// Folds the root transcript into narrative rows and activity groups.
    /// Pure: state comes from `AgentActivityMachine.fold` over inputs derived
    /// from the transcript plus `acknowledgedSettles` (group IDs).
    static func project(
        _ transcript: AgentTranscript,
        isTurnRunning: Bool,
        acknowledgedSettles: Set<String>,
        now: Date
    ) -> [AgentTimelineRow] {
        project(
            items: transcript.items,
            isTurnRunning: isTurnRunning,
            acknowledgedSettles: acknowledgedSettles,
            now: now,
            isReplaying: transcript.isReplaying,
            stepInput: { transcript.stepDetails[$0]?.rawInput?.value },
            childStats: { transcript.stepStats(of: $0) }
        )
    }

    /// The same projection over a root item list. `stepInput` returns a step
    /// key's rawInput; `childStats` a child session's tool counts;
    /// `repositoryName` names "Explored <repo>" summaries.
    static func project(
        items: [AgentChatItem],
        isTurnRunning: Bool,
        acknowledgedSettles: Set<String>,
        now: Date,
        isReplaying: Bool = false,
        stepInput: @escaping (String) -> JSONValue? = { _ in nil },
        childStats: @escaping (String) -> (total: Int, failed: Int, running: Int) = { _ in (0, 0, 0) },
        repositoryName: String? = nil
    ) -> [AgentTimelineRow] {
        var folder = AgentTimelineFolder(items: items, isTurnRunning: isTurnRunning, isReplaying: isReplaying)
        folder.fold()
        let context = AgentGroupContext(
            isTurnRunning: isTurnRunning, isReplaying: isReplaying, acknowledgedSettles: acknowledgedSettles,
            now: now, stepInput: stepInput, childStats: childStats, repositoryName: repositoryName
        )
        let groups = folder.drafts.map { draft in
            var group = context.finalize(draft)
            if group.state == .live, let plan = folder.latestPlan(turn: draft.items.map(\.turnIndex).max() ?? 0) {
                group.plan = plan.progress
                // The plan line changes the card's height, so its revision
                // joins the height-cache key.
                group.revision = max(group.revision, plan.revision)
            }
            return group
        }
        return folder.assemble(groups: groups)
    }

    /// The machine inputs for one group: each member's lifecycle events in
    /// member order, then `.closed` when closed, then `.collapseFinished`
    /// when acknowledged. `isActive` says whether a member is still running.
    static func machineInputs(
        for members: [(item: AgentChatItem, isActive: Bool)],
        closed: Bool,
        acknowledged: Bool
    ) -> [AgentActivityInput] {
        var inputs: [AgentActivityInput] = []
        inputs.reserveCapacity(members.count * 2 + 2)
        for (item, isActive) in members {
            switch item.content {
            case .tool(let tool):
                inputs.append(.event(.stepStart(key: item.key)))
                guard !isActive else { continue }
                if tool.activityOutcome == .failed {
                    inputs.append(.event(.stepFail(key: item.key, summary: tool.errorSummary)))
                } else {
                    inputs.append(.event(.stepEnd(key: item.key)))
                }
            case .thought:
                inputs.append(.event(.reasoningDelta(key: item.key)))
                if !isActive { inputs.append(.event(.reasoningEnd(key: item.key))) }
            case .subagent(let agent):
                let parentKey = agent.spawnToolCallID.map { "\(item.sessionKey)/tool-\($0)" }
                inputs.append(.event(.agentSpawn(childSessionID: agent.childSessionID, parentKey: parentKey)))
                if !isActive {
                    inputs.append(.event(.agentEnd(childSessionID: agent.childSessionID, lifecycle: agent.lifecycle.rawValue)))
                }
            default:
                continue
            }
        }
        if closed { inputs.append(.closed) }
        if acknowledged { inputs.append(.collapseFinished) }
        return inputs
    }
}

// MARK: - Folding

/// One group before finalization: its member items, whether each is still
/// active, and the records that render after it.
struct AgentGroupDraft {
    var items: [AgentChatItem] = []
    var active: [Bool] = []
    var closed = false
    var replayed = true
    var pendingApprovals: [AgentChatItem] = []
    var records: [AgentChatItem] = []
}

/// Walks the root list once: narrative rows close the open group; steps,
/// thoughts, and subagents join it; approvals and plans are transparent.
struct AgentTimelineFolder {
    enum Slot {
        case row(AgentTimelineRow)
        case group(Int)
        case record(AgentChatItem)
    }

    let items: [AgentChatItem]
    let isTurnRunning: Bool
    let isReplaying: Bool
    private(set) var drafts: [AgentGroupDraft] = []
    private(set) var slots: [Slot] = []
    private(set) var plans: [AgentChatItem] = []
    private var groupForToolCall: [String: Int] = [:]
    private var groupForChild: [String: Int] = [:]

    init(items: [AgentChatItem], isTurnRunning: Bool, isReplaying: Bool) {
        self.items = items
        self.isTurnRunning = isTurnRunning
        self.isReplaying = isReplaying
    }

    mutating func fold() {
        var open: Int?
        // Approvals and plans are transparent, so a plan update or approval
        // request after a thought doesn't end it.
        let lastIndex = items.lastIndex { !Self.isTransparent($0) } ?? -1
        for (index, item) in items.enumerated() {
            switch item.content {
            case .user, .assistant, .notice:
                if let current = open { drafts[current].closed = true }
                open = nil
                slots.append(.row(Self.narrativeRow(item)))
            case .tool, .thought, .subagent:
                let target: Int
                if let current = open {
                    target = current
                } else {
                    target = drafts.count
                    drafts.append(AgentGroupDraft())
                    slots.append(.group(target))
                    open = target
                }
                register(item, in: target)
                drafts[target].items.append(item)
                drafts[target].active.append(isActive(item, isLast: index == lastIndex))
                if !(item.isReplayed || isReplaying) { drafts[target].replayed = false }
            case .approval(let approval):
                let target = owner(of: approval) ?? open
                if approval.decision == .pending {
                    if let target { drafts[target].pendingApprovals.append(item) }
                } else if let target {
                    drafts[target].records.append(item)
                } else {
                    slots.append(.record(item))
                }
            case .plan:
                plans.append(item)
            }
        }
        if let current = open, !isTurnRunning { drafts[current].closed = true }
    }

    private static func isTransparent(_ item: AgentChatItem) -> Bool {
        switch item.content {
        case .approval, .plan: true
        default: false
        }
    }

    private static func narrativeRow(_ item: AgentChatItem) -> AgentTimelineRow {
        switch item.content {
        case .user: .user(item)
        case .notice: .notice(item)
        default: .prose(item)
        }
    }

    private mutating func register(_ item: AgentChatItem, in group: Int) {
        switch item.content {
        case .tool(let tool):
            let callID = tool.toolCallID.isEmpty && item.id.hasPrefix("tool-") ? String(item.id.dropFirst(5)) : tool.toolCallID
            if !callID.isEmpty { groupForToolCall[callID] = group }
        case .subagent(let agent):
            groupForChild[agent.childSessionID] = group
        default:
            break
        }
    }

    private func owner(of approval: AgentChatItem.Approval) -> Int? {
        if let callID = approval.toolCallID, let group = groupForToolCall[callID] { return group }
        return groupForChild[approval.sessionID]
    }

    /// Whether a member still counts as running. Replayed history never does;
    /// a thought is open only as the newest root item of a running turn; a
    /// subagent the agent still reports running stays active past the turn
    /// (background).
    private func isActive(_ item: AgentChatItem, isLast: Bool) -> Bool {
        guard !(item.isReplayed || isReplaying) else { return false }
        switch item.content {
        case .tool(let tool):
            return tool.isRunning && isTurnRunning
        case .thought(let thought):
            return thought.endedAt == nil && isTurnRunning && isLast
        case .subagent(let agent):
            switch agent.lifecycle {
            case .queued, .running, .background: return true
            case .done, .failed, .cancelled, .ended: return false
            }
        default:
            return false
        }
    }

    /// Rows in order; decided records follow their group; each plan sits at
    /// the latest position of its turn.
    func assemble(groups: [AgentActivityGroup]) -> [AgentTimelineRow] {
        var rows: [AgentTimelineRow] = []
        var turns: [Int] = []
        rows.reserveCapacity(slots.count + plans.count)
        for slot in slots {
            switch slot {
            case .row(let row):
                rows.append(row)
                turns.append(Self.turn(of: row))
            case .group(let index):
                rows.append(.activity(groups[index]))
                turns.append(drafts[index].items.map(\.turnIndex).max() ?? 0)
                for record in drafts[index].records {
                    rows.append(.approvalRecord(record))
                    turns.append(record.turnIndex)
                }
            case .record(let item):
                rows.append(.approvalRecord(item))
                turns.append(item.turnIndex)
            }
        }
        for plan in plans {
            let position = (turns.lastIndex { $0 <= plan.turnIndex } ?? -1) + 1
            rows.insert(.plan(plan), at: position)
            turns.insert(plan.turnIndex, at: position)
        }
        return rows
    }

    private static func turn(of row: AgentTimelineRow) -> Int {
        switch row {
        case .user(let item), .prose(let item), .approvalRecord(let item), .plan(let item), .notice(let item):
            item.turnIndex
        case .activity:
            0
        }
    }

    /// The turn's latest plan progress and that plan item's revision, for
    /// live cards.
    func latestPlan(turn: Int) -> (progress: AgentPlanProgress, revision: Int)? {
        for plan in plans.reversed() where plan.turnIndex == turn {
            if case .plan(let entries) = plan.content, let progress = AgentPlanProgress(entries: entries) {
                return (progress, plan.revision)
            }
        }
        return nil
    }
}

// MARK: - Group finalization

struct AgentGroupContext {
    var isTurnRunning: Bool
    var isReplaying: Bool
    var acknowledgedSettles: Set<String>
    var now: Date
    var stepInput: (String) -> JSONValue?
    var childStats: (String) -> (total: Int, failed: Int, running: Int)
    var repositoryName: String?

    // Counting, roster building, and timing share one pass over the members.
    // swiftlint:disable:next function_body_length
    func finalize(_ draft: AgentGroupDraft) -> AgentActivityGroup {
        let firstKey = draft.items.first?.key ?? "empty"
        var group = AgentActivityGroup(id: "activity-\(firstKey)", members: [])
        group.members.reserveCapacity(draft.items.count)
        var tally = AgentGlyphTally()
        var roster: [AgentRosterEntry] = []
        var revision = 0
        var startedAt: Date?
        var endedAt: Date?
        func note(start: Date?, end: Date?) {
            if let start { startedAt = min(startedAt ?? start, start) }
            if let end { endedAt = max(endedAt ?? end, end) }
        }
        func flushRoster() {
            guard !roster.isEmpty else { return }
            group.members.append(.agents(roster))
            roster = []
        }
        for item in draft.items {
            revision = max(revision, item.revision)
            // Durations are client receive times; replayed history has none.
            let timed = !(item.isReplayed || isReplaying)
            switch item.content {
            case .tool(let tool):
                flushRoster()
                group.members.append(.step(item))
                group.stepCount += 1
                switch tool.activityOutcome {
                case .failed: group.failedCount += 1
                case .cancelled, .rejected, .interrupted, .notFinished: group.stoppedCount += 1
                case .completed, nil: break
                }
                tally.add(AgentToolVerb.glyph(for: tool, input: stepInput(item.key)))
                if timed { note(start: tool.startedAt, end: tool.endedAt) }
            case .thought(let thought):
                flushRoster()
                group.members.append(.thought(item))
                tally.thoughts += 1
                if timed { note(start: thought.startedAt, end: thought.endedAt) }
            case .subagent(let agent):
                let entry = rosterEntry(agent)
                if entry.lifecycle == .failed { group.failedCount += 1 }
                if entry.lifecycle == .cancelled { group.stoppedCount += 1 }
                tally.agents += 1
                roster.append(entry)
                if timed { note(start: agent.startedAt, end: agent.endedAt) }
            default:
                break
            }
        }
        flushRoster()
        for approval in draft.pendingApprovals { revision = max(revision, approval.revision) }
        group.revision = revision
        group.hasPendingApproval = !draft.pendingApprovals.isEmpty
        group.summary = tally.summary(repositoryName: repositoryName)
        group.state = state(of: draft, id: group.id)
        group.startedAt = startedAt
        group.endedAt = group.isLive ? nil : endedAt
        if group.state == .live { group.liveStatus = liveStatus(draft, hasPendingApproval: group.hasPendingApproval) }
        return group
    }

    private func state(of draft: AgentGroupDraft, id: String) -> AgentActivityState {
        if draft.replayed { return .settled }
        let members = Array(zip(draft.items, draft.active)).map { (item: $0.0, isActive: $0.1) }
        let inputs = AgentTimeline.machineInputs(
            for: members, closed: draft.closed, acknowledged: acknowledgedSettles.contains(id)
        )
        return AgentActivityMachine.fold(inputs)
    }

    private func rosterEntry(_ agent: AgentChatItem.Subagent) -> AgentRosterEntry {
        var lifecycle = agent.lifecycle
        if lifecycle == .running, !isTurnRunning { lifecycle = .background }
        let stats = childStats(agent.childSessionID)
        return AgentRosterEntry(
            id: agent.childSessionID,
            name: redactInline(agent.title),
            lifecycle: lifecycle,
            steps: stats.total,
            failed: stats.failed,
            startedAt: agent.startedAt,
            endedAt: agent.endedAt
        )
    }

    /// Current thought sentence → "Waiting for approval" → live step verb →
    /// "Working…". Always redacted.
    private func liveStatus(_ draft: AgentGroupDraft, hasPendingApproval: Bool) -> String {
        if let last = draft.items.last, draft.active.last == true, case .thought(let thought) = last.content,
           let sentence = AgentActivityText.liveSentence(thought.text) {
            return sentence
        }
        if hasPendingApproval { return "Waiting for approval" }
        for (item, isActive) in zip(draft.items, draft.active).reversed() where isActive {
            if case .tool(let tool) = item.content {
                // Labels only: this runs on every projection, so it skips
                // redacting and rendering the full input for the tooltip.
                return verbForTool(tool, input: stepInput(item.key), includeExactInput: false).live
            }
        }
        return "Working…"
    }
}

/// Counts steps per summary family for "dominant glyph" summaries.
struct AgentGlyphTally {
    enum Family: CaseIterable { case explore, edit, shell, research, agents }

    var counts: [Family: Int] = [:]
    var thoughts = 0
    var agents = 0

    mutating func add(_ glyph: AgentToolVerb.Glyph) {
        let family: Family?
        switch glyph {
        case .read, .search: family = .explore
        case .edit, .create, .delete, .move: family = .edit
        case .shell: family = .shell
        case .fetch, .web: family = .research
        case .agent: family = .agents
        case .think, .plan, .mcp, .other: family = nil
        }
        if let family { counts[family, default: 0] += 1 }
    }

    /// The family with a unique maximum covering at least half the counted
    /// steps names the group; otherwise "Worked".
    func summary(repositoryName: String?) -> String {
        var all = counts
        all[.agents, default: 0] += agents
        let total = all.values.reduce(0, +)
        guard total > 0 else { return thoughts > 0 ? "Thought" : "Worked" }
        let top = all.values.max() ?? 0
        let leaders = Family.allCases.filter { all[$0] == top }
        guard leaders.count == 1, let leader = leaders.first, top * 2 >= total else { return "Worked" }
        switch leader {
        case .explore:
            let name = repositoryName.map(redactInline).flatMap { $0.isEmpty ? nil : $0 } ?? "files"
            return "Explored \(AgentToolResolver.clip(name, 40))"
        case .edit: return "Edited files"
        case .shell: return "Ran commands"
        case .research: return "Researched"
        case .agents: return "Coordinated agents"
        }
    }
}

extension AgentChatItem.ToolCall {
    /// `outcome`, else derived from status and `nonExecutionKind` for items
    /// that predate outcome tracking; nil while running.
    var activityOutcome: Outcome? {
        if let outcome { return outcome }
        switch nonExecutionKind?.lowercased() {
        case "interrupted", "cancelled", "canceled": return .cancelled
        case "rejected": return .rejected
        default: break
        }
        switch status {
        case .failed: return .failed
        case .completed: return .completed
        case .pending, .inProgress, nil: return endedAt == nil ? nil : .notFinished
        }
    }
}

// MARK: - State machine

enum AgentActivityState: Equatable, Sendable {
    case idle, live, settling, settled
}

enum AgentActivityInput: Equatable, Sendable {
    /// Typed events for this group's members, in order.
    case event(AgentActivityEvent)
    /// A narrative row follows the group, or the turn ended.
    case closed
    /// The view finished the settle animation (immediate under Reduce Motion
    /// or a hidden window).
    case collapseFinished
}

extension AgentActivityEvent {
    /// stepStart, agentSpawn, reasoningDelta.
    var isStart: Bool {
        switch self {
        case .stepStart, .agentSpawn, .reasoningDelta: true
        case .stepEnd, .stepFail, .agentEnd, .reasoningEnd: false
        }
    }

    /// The running-set key this event adds or removes.
    var runningKey: String {
        switch self {
        case .stepStart(let key), .stepEnd(let key), .stepFail(let key, _), .reasoningDelta(let key), .reasoningEnd(let key):
            key
        case .agentSpawn(let child, _), .agentEnd(let child, _):
            "agent:\(child)"
        }
    }
}

/// idle → live on any start/spawn/delta; live → settling when closed with
/// nothing running; settling → live on any start; settling → settled on
/// collapseFinished; settled → live on a late start; idle + closed → settled.
enum AgentActivityMachine {
    /// Without a closed flag, only a `.closed` input counts as closed, so a
    /// terminal event alone never settles. `fold` tracks closure and uses
    /// `reduce(_:_:runningCount:closed:)`.
    static func reduce(_ state: AgentActivityState, _ input: AgentActivityInput, runningCount: Int) -> AgentActivityState {
        reduce(state, input, runningCount: runningCount, closed: input == .closed)
    }

    /// `runningCount` is the number of members still running after `input`;
    /// `closed` whether the group has been closed by now.
    static func reduce(
        _ state: AgentActivityState,
        _ input: AgentActivityInput,
        runningCount: Int,
        closed: Bool
    ) -> AgentActivityState {
        switch (state, input) {
        case (_, .event(let event)) where event.isStart:
            return .live
        case (.live, .event):
            return closed && runningCount == 0 ? .settling : .live
        case (.live, .closed):
            return runningCount == 0 ? .settling : .live
        case (.idle, .closed):
            return .settled
        case (.settling, .collapseFinished):
            return .settled
        default:
            return state
        }
    }

    /// Folds inputs from `.idle`, tracking the running count from the events.
    static func fold(_ inputs: [AgentActivityInput]) -> AgentActivityState {
        var running = Set<String>()
        var closed = false
        var state = AgentActivityState.idle
        for input in inputs {
            switch input {
            case .event(let event):
                if event.isStart {
                    running.insert(event.runningKey)
                } else {
                    running.remove(event.runningKey)
                }
            case .closed:
                closed = true
            case .collapseFinished:
                break
            }
            state = reduce(state, input, runningCount: running.count, closed: closed)
        }
        return state
    }
}

// MARK: - Weight, layout, header

/// What an activity card shows for one disclosure state.
struct AgentActivityLayout: Equatable, Sendable {
    enum Entry: Equatable, Sendable {
        case member(AgentActivityMember)
        /// Live, > 15 rows: "N earlier" above the last 6.
        case earlier(count: Int)
        /// Settled and expanded, > 15 rows: "Show N more" between the first 2
        /// and last 2.
        case showMore(count: Int)
        /// Collapsed, > 6 failed members: "N earlier failures" above the last 6.
        case earlierFailures(count: Int)

        var id: String {
            switch self {
            case .member(let member): member.id
            case .earlier: "earlier"
            case .showMore: "show-more"
            case .earlierFailures: "earlier-failures"
            }
        }
    }

    var entries: [Entry]
    /// False for an inline settled group (≤ 3 rows, no failures, no agents).
    var showsCardChrome: Bool
    var isExpanded: Bool
}

/// The header label split into segments; only `.summary` may truncate.
struct AgentActivityHeader: Equatable, Sendable {
    enum Role: Equatable, Sendable {
        case summary, steps, failed, stopped, duration
    }

    struct Segment: Equatable, Sendable {
        var role: Role
        var text: String
        var isTruncatable: Bool { role == .summary }
    }

    var segments: [Segment]
    var text: String { segments.map(\.text).joined(separator: " · ") }
}

extension AgentActivityGroup {
    static let inlineRowLimit = 3
    static let longGroupThreshold = 15
    static let liveTailCount = 6
    static let settledHeadCount = 2
    static let settledTailCount = 2

    /// idle or live: expanded and streaming.
    var isLive: Bool { state == .idle || state == .live }

    /// Step and thought rows (rosters are counted separately).
    var rowCount: Int {
        members.reduce(0) { count, member in
            if case .agents = member { return count }
            return count + 1
        }
    }

    var rosterEntries: [AgentRosterEntry] {
        members.flatMap { member -> [AgentRosterEntry] in
            if case .agents(let entries) = member { return entries }
            return []
        }
    }

    var hasAgents: Bool { members.contains { if case .agents = $0 { true } else { false } } }

    /// Settling or settled, ≤ 3 rows, no failures, no agents, no pending
    /// approval: inline rows without chrome. Settling counts so a small card
    /// doesn't animate closed and then reopen as inline rows.
    var rendersInline: Bool {
        (state == .settled || state == .settling) && rowCount <= Self.inlineRowLimit && failedCount == 0
            && !hasAgents && !hasPendingApproval
    }

    /// A settling card that animates closed. A settling group that renders
    /// inline has nothing to animate: the controller records its
    /// `collapseFinished` immediately, as under Reduce Motion.
    var animatesSettle: Bool { state == .settling && !rendersInline }

    /// Live groups open; settling and settled groups close.
    var isExpandedByDefault: Bool { isLive }

    /// Failed steps and rosters with a failed agent, shown beneath a
    /// collapsed label.
    var failedMembers: [AgentActivityMember] {
        members.compactMap { member in
            switch member {
            case .step(let item):
                guard case .tool(let tool) = item.content, tool.activityOutcome == .failed else { return nil }
                return member
            case .thought:
                return nil
            case .agents(let entries):
                // The whole roster, so its summary counts every agent
                // ("12 agents · 11 done · 1 failed"), not just the failures.
                return entries.contains { $0.lifecycle == .failed } ? member : nil
            }
        }
    }

    /// `expandedOverride` is the user's toggle (nil follows the state);
    /// `showAll` expands a long settled group fully.
    func layout(expandedOverride: Bool?, showAll: Bool) -> AgentActivityLayout {
        if rendersInline {
            return AgentActivityLayout(entries: members.map { .member($0) }, showsCardChrome: false, isExpanded: true)
        }
        let expanded = expandedOverride ?? isExpandedByDefault
        guard expanded else {
            // Bounded: an agent failing hundreds of steps can't grow one row without limit.
            let failed = failedMembers, hidden = failed.count - Self.liveTailCount
            let entries: [AgentActivityLayout.Entry] = failed.suffix(Self.liveTailCount).map { .member($0) }
            return AgentActivityLayout(entries: hidden > 0 ? [.earlierFailures(count: hidden)] + entries : entries,
                                       showsCardChrome: true, isExpanded: false)
        }
        let rows = rowCount
        let entries: [AgentActivityLayout.Entry]
        if rows > Self.longGroupThreshold, isLive {
            let hidden = rows - Self.liveTailCount
            entries = paged(visible: { $0 >= hidden }, marker: .earlier(count: hidden))
        } else if rows > Self.longGroupThreshold, !showAll {
            let tailStart = rows - Self.settledTailCount
            let hidden = rows - Self.settledHeadCount - Self.settledTailCount
            entries = paged(visible: { $0 < Self.settledHeadCount || $0 >= tailStart }, marker: .showMore(count: hidden))
        } else {
            entries = members.map { .member($0) }
        }
        return AgentActivityLayout(entries: entries, showsCardChrome: true, isExpanded: true)
    }

    /// Members whose row index passes `visible` (rosters always), with
    /// `marker` in place of the first hidden run.
    private func paged(visible: (Int) -> Bool, marker: AgentActivityLayout.Entry) -> [AgentActivityLayout.Entry] {
        var entries: [AgentActivityLayout.Entry] = []
        var rowIndex = 0
        var placedMarker = false
        for member in members {
            if case .agents = member {
                entries.append(.member(member))
                continue
            }
            if visible(rowIndex) {
                entries.append(.member(member))
            } else if !placedMarker {
                entries.append(marker)
                placedMarker = true
            }
            rowIndex += 1
        }
        return entries
    }

    /// Live: since the first start; settled: first start to last end; nil
    /// without times (replayed history).
    func duration(now: Date) -> TimeInterval? {
        guard let startedAt else { return nil }
        if isLive { return max(0, now.timeIntervalSince(startedAt)) }
        guard let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }

    /// `{summary} · {n} steps · {k} failed · {n} stopped · {duration}`.
    func header(now: Date) -> AgentActivityHeader {
        var segments = [AgentActivityHeader.Segment(role: .summary, text: summary)]
        if stepCount > 0 {
            segments.append(.init(role: .steps, text: stepCount == 1 ? "1 step" : "\(stepCount) steps"))
        }
        if failedCount > 0 { segments.append(.init(role: .failed, text: "\(failedCount) failed")) }
        if stoppedCount > 0 { segments.append(.init(role: .stopped, text: "\(stoppedCount) stopped")) }
        if let duration = duration(now: now) {
            segments.append(.init(role: .duration, text: AgentActivityFormat.duration(duration)))
        }
        return AgentActivityHeader(segments: segments)
    }
}
