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
// - AgentToolVerb (+Glyph), verbForTool(_:input:), verbForThought(_:now:)
//   — AgentToolVerb.swift.
// - AgentRedaction, redactOutput(_:maximumLines:), redactJSON(_:),
//   redactInline(_:) — AgentOutputRedaction.swift.
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
//   applyRows(_:now:), rows, actions, lastApplyPath.

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
        // WP3: implement (folding, roster, liveStatus, summary, weight)
        transcript.items.map { item in
            switch item.content {
            case .user: return .user(item)
            case .assistant: return .prose(item)
            case .notice: return .notice(item)
            case .plan: return .plan(item)
            case .approval: return .approvalRecord(item)
            case .tool(let tool):
                return .activity(placeholderGroup(item, member: .step(item), running: tool.isRunning))
            case .thought(let thought):
                return .activity(placeholderGroup(item, member: .thought(item), running: thought.endedAt == nil))
            case .subagent(let subagent):
                let entry = AgentRosterEntry(
                    id: subagent.childSessionID, name: subagent.title, lifecycle: subagent.lifecycle,
                    steps: 0, failed: 0, startedAt: subagent.startedAt, endedAt: subagent.endedAt
                )
                return .activity(placeholderGroup(item, member: .agents([entry]), running: subagent.isRunning))
            }
        }
    }

    private static func placeholderGroup(_ item: AgentChatItem, member: AgentActivityMember, running: Bool) -> AgentActivityGroup {
        AgentActivityGroup(
            id: "activity-\(item.key)", revision: item.revision, members: [member],
            state: running ? .live : .settled, stepCount: 1, summary: "Worked"
        )
    }
}

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

/// idle → live on any start/spawn/delta; live → settling when closed with
/// nothing running; settling → live on any start; settling → settled on
/// collapseFinished; settled → live on a late start; idle + closed → settled.
enum AgentActivityMachine {
    static func reduce(_ state: AgentActivityState, _ input: AgentActivityInput, runningCount: Int) -> AgentActivityState {
        // WP3: implement
        state
    }

    /// Folds inputs from `.idle`, tracking the running count from the events.
    static func fold(_ inputs: [AgentActivityInput]) -> AgentActivityState {
        // WP3: implement (running count)
        inputs.reduce(.idle) { reduce($0, $1, runningCount: 0) }
    }
}
