import Foundation
import Testing
@testable import Pilot

/// Folding, approval/plan transparency, roster, weight rules, stable IDs, and
/// projection budgets.
@Suite("Agent timeline")
struct AgentTimelineTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    // MARK: Fixtures

    private func user(_ id: String, turn: Int = 0) -> AgentChatItem {
        AgentChatItem(id: id, content: .user("hi"), turnIndex: turn)
    }

    private func prose(_ id: String, turn: Int = 0) -> AgentChatItem {
        AgentChatItem(id: id, content: .assistant("done"), turnIndex: turn)
    }

    private func notice(_ id: String) -> AgentChatItem {
        AgentChatItem(id: id, content: .notice("note"))
    }

    private func tool(
        _ callID: String,
        _ name: String = "Bash",
        status: ACPToolStatus = .completed,
        outcome: AgentChatItem.ToolCall.Outcome? = nil,
        start: TimeInterval? = nil,
        end: TimeInterval? = nil,
        revision: Int = 0,
        turn: Int = 0,
        replayed: Bool = false
    ) -> AgentChatItem {
        var call = AgentChatItem.ToolCall(title: "\(name) \(callID)", kind: nil, status: status, content: "")
        call.toolCallID = callID
        call.toolName = name
        call.outcome = outcome
        call.startedAt = start.map { now.addingTimeInterval($0) }
        call.endedAt = end.map { now.addingTimeInterval($0) }
        return AgentChatItem(id: "tool-\(callID)", content: .tool(call), revision: revision, turnIndex: turn, isReplayed: replayed)
    }

    private func thought(_ id: String, _ text: String, ended: Bool = false) -> AgentChatItem {
        AgentChatItem(id: id, content: .thought(.init(text: text, endedAt: ended ? now : nil)))
    }

    private func agent(_ child: String, state: String? = "running", stopReason: String? = nil, error: String? = nil) -> AgentChatItem {
        var card = AgentChatItem.Subagent(childSessionID: child, title: "Agent \(child)", detail: nil, state: state, error: error)
        card.stopReason = stopReason
        return AgentChatItem(id: "subagent-\(child)", content: .subagent(card))
    }

    private func approval(
        _ id: String,
        toolCallID: String?,
        decision: AgentChatItem.Approval.Decision,
        session: String = "s",
        revision: Int = 0
    ) -> AgentChatItem {
        let record = AgentChatItem.Approval(
            requestID: .string(id), sessionID: session, agentName: "Claude", toolCallID: toolCallID, title: "Run",
            kind: .execute, subject: nil, options: [], decision: decision
        )
        return AgentChatItem(id: id, content: .approval(record), revision: revision)
    }

    private func plan(done: Int, total: Int, turn: Int = 0, revision: Int = 0) -> AgentChatItem {
        let entries = (0..<total).map { ACPPlanEntry(content: "step \($0)", status: $0 < done ? "completed" : "pending") }
        return AgentChatItem(id: "plan-root", content: .plan(entries), revision: revision, turnIndex: turn)
    }

    private func project(
        _ items: [AgentChatItem],
        running: Bool = false,
        acknowledged: Set<String> = [],
        replaying: Bool = false,
        inputs: [String: JSONValue] = [:],
        stats: [String: (total: Int, failed: Int, running: Int)] = [:],
        repository: String? = nil
    ) -> [AgentTimelineRow] {
        AgentTimeline.project(
            items: items, isTurnRunning: running, acknowledgedSettles: acknowledged, now: now, isReplaying: replaying,
            stepInput: { inputs[$0] }, childStats: { stats[$0] ?? (0, 0, 0) }, repositoryName: repository
        )
    }

    private func groups(_ rows: [AgentTimelineRow]) -> [AgentActivityGroup] {
        rows.compactMap { if case .activity(let group) = $0 { group } else { nil } }
    }

    private func onlyGroup(_ rows: [AgentTimelineRow]) throws -> AgentActivityGroup {
        let found = groups(rows)
        try #require(found.count == 1)
        return found[0]
    }

    private func kinds(_ rows: [AgentTimelineRow]) -> [String] {
        rows.map { row in
            switch row {
            case .user: "user"
            case .prose: "prose"
            case .activity(let group): "activity(\(group.members.count))"
            case .approvalRecord: "record"
            case .plan: "plan"
            case .notice: "notice"
            }
        }
    }

    // MARK: Folding

    @Test
    func emptyTranscriptProjectsNoRows() {
        let rows = AgentTimeline.project(
            AgentTranscript(), isTurnRunning: false, acknowledgedSettles: [], now: Date(timeIntervalSince1970: 0)
        )
        #expect(rows.isEmpty)
    }

    @Test
    func narrativeRowsSplitActivityGroups() {
        let rows = project([user("u1"), tool("1"), thought("t1", "x", ended: true), tool("2"), prose("p1"), tool("3"), notice("n1"), tool("4")])
        #expect(kinds(rows) == ["user", "activity(3)", "prose", "activity(1)", "notice", "activity(1)"])
        #expect(groups(rows).map(\.id) == ["activity-root/tool-1", "activity-root/tool-3", "activity-root/tool-4"])
        #expect(rows.map(\.id).first == "root/u1")
    }

    @Test
    func approvalsAndPlansAreTransparent() throws {
        let items = [
            user("u1"), tool("1"), approval("a1", toolCallID: "1", decision: .chose(optionID: "o", name: "Allow", allows: true)),
            plan(done: 1, total: 3), tool("2"), prose("p1"),
        ]
        let rows = project(items)
        #expect(kinds(rows) == ["user", "activity(2)", "record", "prose", "plan"])
        #expect(try onlyGroup(rows).stepCount == 2)
    }

    @Test
    func decidedRecordsFollowTheGroupHoldingTheirToolCall() {
        let items = [user("u1"), tool("1"), prose("p1"), approval("a1", toolCallID: "1", decision: .cancelledByUser), user("u2")]
        let rows = project(items)
        #expect(kinds(rows) == ["user", "activity(1)", "record", "prose", "user"])
        let childItems = [
            user("u1"), agent("child-1", state: "idle", stopReason: "end_turn"), prose("p1"),
            approval("a2", toolCallID: "child-tool", decision: .agentStopped, session: "child-1"),
        ]
        #expect(kinds(project(childItems)) == ["user", "activity(1)", "record", "prose"])
    }

    @Test
    func unmatchedRecordsStayInOrder() {
        let items = [user("u1"), approval("a1", toolCallID: nil, decision: .withdrawnByAgent), prose("p1")]
        #expect(kinds(project(items)) == ["user", "record", "prose"])
        let open = [user("u1"), tool("1"), approval("a2", toolCallID: "unknown", decision: .autoCancelled), tool("2")]
        #expect(kinds(project(open)) == ["user", "activity(2)", "record"])
    }

    @Test
    func pendingApprovalsDockInsteadOfRendering() throws {
        let items = [user("u1"), tool("1", status: .pending), approval("a1", toolCallID: "1", decision: .pending, revision: 9)]
        let rows = project(items, running: true)
        #expect(kinds(rows) == ["user", "activity(1)"])
        let group = try onlyGroup(rows)
        #expect(group.hasPendingApproval)
        #expect(group.liveStatus == "Waiting for approval")
        #expect(group.revision == 9)
    }

    @Test
    func planSitsAtTheLatestPositionOfItsTurn() {
        let items = [
            user("u0", turn: 0), plan(done: 3, total: 7, turn: 0), tool("1", turn: 0), prose("p0", turn: 0),
            user("u1", turn: 1), tool("2", turn: 1), prose("p1", turn: 1),
        ]
        #expect(kinds(project(items)) == ["user", "activity(1)", "prose", "plan", "user", "activity(1)", "prose"])
        var later = items
        later[1] = plan(done: 3, total: 7, turn: 1)
        #expect(kinds(project(later)) == ["user", "activity(1)", "prose", "user", "activity(1)", "prose", "plan"])
    }

    @Test
    func liveCardsCarryThePlanProgress() throws {
        let items = [user("u0"), plan(done: 3, total: 7), tool("1", status: .inProgress)]
        let group = try onlyGroup(project(items, running: true))
        #expect(group.plan == AgentPlanProgress(done: 3, total: 7))
        #expect(group.plan?.label == "Plan · 3/7 done")
        #expect(try onlyGroup(project(items + [prose("p")])).plan == nil, "settled cards drop it")
        #expect(AgentPlanProgress(entries: []) == nil)
    }

    @Test
    func thePlanLineJoinsTheLiveCardRevision() throws {
        let running = tool("1", status: .inProgress, revision: 4)
        let withPlan = try onlyGroup(project([user("u0"), running, plan(done: 1, total: 2, revision: 11)], running: true))
        #expect(withPlan.revision == 11, "the plan line changes the card height")
        let settled = try onlyGroup(project([user("u0"), tool("1", revision: 4), plan(done: 1, total: 2, revision: 11), prose("p")]))
        #expect(settled.plan == nil)
        #expect(settled.revision == 4)
    }

    // MARK: Roster

    @Test
    func consecutiveSubagentsBecomeOneRoster() throws {
        let items = [
            user("u"), tool("1"), agent("a"), agent("b", state: "idle", stopReason: "end_turn"), tool("2"),
            agent("c", state: "idle", stopReason: "error"), prose("p"),
        ]
        let group = try onlyGroup(project(items, running: true, stats: ["a": (15, 1, 2), "c": (3, 3, 0)]))
        #expect(group.members.map(\.id) == ["root/tool-1", "roster-a", "root/tool-2", "roster-c"])
        guard case .agents(let first) = group.members[1], case .agents(let second) = group.members[3] else {
            Issue.record("expected rosters")
            return
        }
        #expect(first.map(\.id) == ["a", "b"])
        #expect(first[0] == AgentRosterEntry(id: "a", name: "Agent a", lifecycle: .running, steps: 15, failed: 1, startedAt: nil, endedAt: nil))
        #expect(first[1].lifecycle == .done)
        #expect(second[0].lifecycle == .failed)
        #expect(group.failedCount == 1)
        #expect(group.summary == "Coordinated agents", "3 agents of 5 counted steps dominate")
        #expect(group.rosterEntries.count == 3)
        #expect(group.hasAgents)
        #expect(group.failedMembers.map(\.id) == ["roster-c"])
    }

    @Test
    func runningAgentsAfterTheTurnAreBackgroundAndKeepTheCardLive() throws {
        let group = try onlyGroup(project([user("u"), agent("a")], running: false))
        guard case .agents(let entries) = group.members.first else {
            Issue.record("expected roster")
            return
        }
        #expect(entries[0].lifecycle == .background)
        #expect(group.state == .live)
        #expect(group.liveStatus == "Working…")
    }

    @Test
    func rosterNamesAreRedacted() throws {
        var card = AgentChatItem.Subagent(childSessionID: "x", title: "Use token=abc", detail: nil, state: "idle", error: nil)
        card.stopReason = "end_turn"
        let group = try onlyGroup(project([AgentChatItem(id: "subagent-x", content: .subagent(card))]))
        #expect(group.rosterEntries.first?.name == "Use token=••••")
    }

    // MARK: State

    @Test
    func stateFollowsTheTranscript() throws {
        let running = [user("u"), tool("1", status: .inProgress)]
        #expect(try onlyGroup(project(running, running: true)).state == .live)
        let done = [user("u"), tool("1")]
        #expect(try onlyGroup(project(done, running: true)).state == .live, "open until closed")
        #expect(try onlyGroup(project(done, running: false)).state == .settling)
        #expect(try onlyGroup(project(done + [prose("p")], running: true)).state == .settling)
        let id = "activity-root/tool-1"
        #expect(try onlyGroup(project(done, running: false, acknowledged: [id])).state == .settled)
        #expect(try onlyGroup(project(running, running: true, acknowledged: [id])).state == .live, "ack ignored while live")
    }

    @Test
    func replayedGroupsAreSettled() throws {
        let items = [user("u"), tool("1", status: .inProgress, replayed: true), thought("t", "x")]
        #expect(try onlyGroup(project(items, running: true, replaying: true)).state == .settled)
        let flagged = [user("u"), tool("1", status: .inProgress, replayed: true)]
        let group = try onlyGroup(project(flagged, running: true))
        #expect(group.state == .settled)
        #expect(group.liveStatus == nil)
    }

    @Test
    func thoughtsEndAtTheNextItemOrTheTurn() throws {
        let open = [user("u"), thought("t", "Checking the transport.")]
        #expect(try onlyGroup(project(open, running: true)).state == .live)
        #expect(try onlyGroup(project(open, running: false)).state == .settling)
        #expect(try onlyGroup(project(open + [tool("1")], running: true)).state == .live, "tool done, still open")
        #expect(try onlyGroup(project(open + [tool("1")], running: false)).state == .settling)
    }

    @Test
    func plansAndApprovalsAfterAThoughtDoNotEndIt() throws {
        let open = [user("u"), thought("t", "Checking the transport. Then")]
        let planned = try onlyGroup(project(open + [plan(done: 0, total: 2)], running: true))
        #expect(planned.state == .live)
        #expect(planned.liveStatus == "Checking the transport.")
        let asked = open + [approval("a", toolCallID: nil, decision: .chose(optionID: "o", name: "Allow", allows: true))]
        #expect(try onlyGroup(project(asked, running: true)).liveStatus == "Checking the transport.")
        let next = try onlyGroup(project(open + [plan(done: 0, total: 2), tool("1")], running: true))
        #expect(next.liveStatus == "Working…", "a step after the thought ends it")
    }

    // MARK: Live status

    @Test
    func liveStatusUsesTheLastCompleteSentenceOfTheThought() throws {
        let text = "## Plan\n**Checking transport**\n\nLooking at how `HyperEVM` handles [fallbacks](https://x.io). Then I will"
        let group = try onlyGroup(project([user("u"), thought("t", text)], running: true))
        #expect(group.liveStatus == "Looking at how HyperEVM handles fallbacks.")
        #expect(AgentActivityText.liveSentence("Partial thought with no end") == "Partial thought with no end")
        #expect(AgentActivityText.liveSentence("First line\nsecond") == "First line")
        #expect(AgentActivityText.liveSentence("One. Two! Three? four") == "Three?")
        #expect(AgentActivityText.liveSentence("Version 1.5 is out.") == "Version 1.5 is out.")
        #expect(AgentActivityText.liveSentence("   \n  ") == nil)
        let long = AgentActivityText.liveSentence(String(repeating: "word ", count: 40) + "end.")
        #expect(long?.count == 80)
        #expect(long?.hasSuffix("…") == true)
        #expect(AgentActivityText.liveSentence("- Using token=abc.\n") == "Using token=••••")
    }

    @Test
    func liveStatusFallsBackToTheLiveVerbThenWorking() throws {
        let items = [user("u"), tool("1"), tool("2", status: .inProgress)]
        let group = try onlyGroup(project(items, running: true, inputs: ["root/tool-2": ["command": "git status"]]))
        #expect(group.liveStatus == "Running git status")
        let idle = try onlyGroup(project([user("u"), tool("1")], running: true))
        #expect(idle.liveStatus == "Working…")
        let settled = try onlyGroup(project([user("u"), tool("1")]))
        #expect(settled.liveStatus == nil)
        let secret = try onlyGroup(project(
            [user("u"), tool("1", status: .inProgress)], running: true, inputs: ["root/tool-1": ["command": "export API_KEY=abc"]]
        ))
        #expect(secret.liveStatus == "Running export API_KEY=••••")
    }

    // MARK: Counts, times, summary

    @Test
    func countsTimesAndRevision() throws {
        let items = [
            user("u"), tool("1", start: 0, end: 5, revision: 3), tool("2", status: .failed, start: 2, end: 40, revision: 7),
            tool("3", outcome: .cancelled, start: 1, end: 3), thought("t", "x", ended: true), prose("p"),
        ]
        let group = try onlyGroup(project(items))
        #expect(group.stepCount == 3)
        #expect(group.failedCount == 1)
        #expect(group.stoppedCount == 1)
        #expect(group.revision == 7)
        #expect(group.startedAt == now)
        #expect(group.endedAt == now.addingTimeInterval(40))
        #expect(group.duration(now: now.addingTimeInterval(999)) == 40)
    }

    @Test
    func headerSegmentsAndTruncation() throws {
        let items = [
            user("u"), tool("1", "Read", start: 0, end: 10), tool("2", "Grep", status: .failed, start: 1, end: 42),
            tool("3", "Read", outcome: .rejected, start: 2, end: 3), prose("p"),
        ]
        let group = try onlyGroup(project(items, repository: "hyperevm"))
        let header = group.header(now: now)
        #expect(header.text == "Explored hyperevm · 3 steps · 1 failed · 1 stopped · 42s")
        #expect(header.segments.map(\.role) == [.summary, .steps, .failed, .stopped, .duration])
        #expect(header.segments.filter(\.isTruncatable).map(\.role) == [.summary])
        let live = try onlyGroup(project([user("u"), tool("1", status: .inProgress, start: 0)], running: true))
        #expect(live.header(now: now.addingTimeInterval(65)).text == "Ran commands · 1 step · 1m 05s")
        let replayed = try onlyGroup(project([user("u"), tool("1", start: 0, end: 9)], replaying: true))
        #expect(replayed.header(now: now).text == "Ran commands · 1 step", "no durations for replayed history")
        #expect(replayed.startedAt == nil)
        let flagged = try onlyGroup(project([user("u"), tool("1", start: 0, end: 9, replayed: true)]))
        #expect(flagged.duration(now: now) == nil)
    }

    @Test
    func summariesFollowTheDominantGlyph() throws {
        func summary(_ names: [String], repository: String? = nil) throws -> String {
            let items = [user("u")] + names.enumerated().map { tool("\($0.offset)", $0.element) } + [prose("p")]
            return try onlyGroup(project(items, repository: repository)).summary
        }
        #expect(try summary(["Read", "Grep", "Glob"]) == "Explored files")
        #expect(try summary(["Read", "Read", "Bash"], repository: "made") == "Explored made")
        #expect(try summary(["Edit", "Write", "Read"]) == "Edited files")
        #expect(try summary(["Bash", "Bash"]) == "Ran commands")
        #expect(try summary(["WebFetch", "WebSearch"]) == "Researched")
        #expect(try summary(["Task", "Task", "Read"]) == "Coordinated agents")
        #expect(try summary(["Read", "Edit"]) == "Worked")
        #expect(try summary(["Read", "Edit", "Bash", "WebFetch"]) == "Worked")
        #expect(try summary(["TodoWrite"]) == "Worked")
        let thoughts = try onlyGroup(project([user("u"), thought("t", "x", ended: true), prose("p")]))
        #expect(thoughts.summary == "Thought")
    }

    // MARK: Weight

    private func manyTools(_ count: Int, failing: Set<Int> = [], lastRunning: Bool = false) -> [AgentChatItem] {
        (0..<count).map { index in
            let status: ACPToolStatus = failing.contains(index) ? .failed : (lastRunning && index == count - 1 ? .inProgress : .completed)
            return tool("\(index)", status: status)
        }
    }

    @Test
    func smallSettledGroupsRenderInline() throws {
        let group = try onlyGroup(project([user("u")] + manyTools(3) + [prose("p")], acknowledged: ["activity-root/tool-0"]))
        #expect(group.rendersInline)
        let layout = group.layout(expandedOverride: nil, showAll: false)
        #expect(!layout.showsCardChrome)
        #expect(layout.entries.count == 3)
        let four = try onlyGroup(project([user("u")] + manyTools(4) + [prose("p")], acknowledged: ["activity-root/tool-0"]))
        #expect(!four.rendersInline)
        #expect(four.layout(expandedOverride: nil, showAll: false) == AgentActivityLayout(entries: [], showsCardChrome: true, isExpanded: false))
        #expect(!four.animatesSettle)
        let settling = try onlyGroup(project([user("u")] + manyTools(2) + [prose("p")]))
        #expect(settling.state == .settling)
        #expect(settling.rendersInline, "a small card settles straight into inline rows")
        #expect(!settling.animatesSettle, "nothing to animate: the controller acks at once")
        let settlingFour = try onlyGroup(project([user("u")] + manyTools(4) + [prose("p")]))
        #expect(settlingFour.animatesSettle)
        #expect(!settlingFour.rendersInline)
        let live = try onlyGroup(project([user("u")] + manyTools(2, lastRunning: true), running: true))
        #expect(!live.rendersInline)
        #expect(!live.animatesSettle)
    }

    @Test
    func failuresAndAgentsKeepTheCard() throws {
        let ack: Set<String> = ["activity-root/tool-0"]
        let failed = try onlyGroup(project([user("u")] + manyTools(2, failing: [1]) + [prose("p")], acknowledged: ack))
        #expect(!failed.rendersInline)
        let collapsed = failed.layout(expandedOverride: nil, showAll: false)
        #expect(collapsed.entries.map { if case .member(let m) = $0 { m.id } else { "" } } == ["root/tool-1"])
        #expect(failed.layout(expandedOverride: true, showAll: false).entries.count == 2)
        let withAgent = try onlyGroup(project(
            [user("u")] + manyTools(1) + [agent("a", state: "idle", stopReason: "end_turn"), prose("p")], acknowledged: ack
        ))
        #expect(!withAgent.rendersInline)
    }

    @Test
    func liveGroupsPastFifteenShowTheLastSix() throws {
        let group = try onlyGroup(project([user("u")] + manyTools(20, lastRunning: true), running: true))
        #expect(group.state == .live)
        let layout = group.layout(expandedOverride: nil, showAll: false)
        #expect(layout.isExpanded)
        #expect(layout.entries.first == .earlier(count: 14))
        #expect(layout.entries.dropFirst().map { if case .member(let m) = $0 { m.id } else { "" } } == (14..<20).map { "root/tool-\($0)" })
        let fifteen = try onlyGroup(project([user("u")] + manyTools(15, lastRunning: true), running: true))
        #expect(fifteen.layout(expandedOverride: nil, showAll: false).entries.count == 15)
        #expect(group.layout(expandedOverride: false, showAll: false).entries.isEmpty, "user collapse wins")
    }

    @Test
    func settledGroupsPastFifteenShowTwoAndTwo() throws {
        let group = try onlyGroup(project([user("u")] + manyTools(20) + [prose("p")], acknowledged: ["activity-root/tool-0"]))
        #expect(group.state == .settled)
        let collapsed = group.layout(expandedOverride: nil, showAll: false)
        #expect(!collapsed.isExpanded)
        let expanded = group.layout(expandedOverride: true, showAll: false)
        let ids = expanded.entries.map { entry -> String in
            switch entry {
            case .member(let member): member.id
            case .showMore(let count): "more \(count)"
            case .earlier(let count): "earlier \(count)"
            }
        }
        #expect(ids == ["root/tool-0", "root/tool-1", "more 16", "root/tool-18", "root/tool-19"])
        #expect(group.layout(expandedOverride: true, showAll: true).entries.count == 20)
    }

    @Test
    func rostersStayVisibleWhilePaging() throws {
        let items = [user("u")] + manyTools(10) + [agent("a")] + manyTools(10).map { item in
            var copy = item
            copy.id = "x" + item.id
            return copy
        }
        let group = try onlyGroup(project(items, running: true))
        let entries = group.layout(expandedOverride: nil, showAll: false).entries
        #expect(entries.contains(.member(group.members[10])))
        #expect(entries.first == .earlier(count: 14))
        #expect(entries.count == 1 + 1 + 6)
    }

    // MARK: Stable IDs and transcript input

    @Test
    func idsStayStableWhenTheHeadIsTrimmed() {
        var items: [AgentChatItem] = []
        for turn in 0..<500 {
            items += [user("u\(turn)"), tool("a\(turn)"), tool("b\(turn)"), prose("p\(turn)")]
        }
        #expect(items.count == 2_000)
        let before = project(items).map(\.id)
        let trimmed = Array(items.dropFirst(200))
        let after = project(trimmed).map(\.id)
        #expect(after == Array(before.suffix(after.count)))
        let midGroup = Array(items.dropFirst(2))
        let shifted = project(midGroup).map(\.id)
        #expect(shifted.first == "activity-root/tool-b0", "a group whose head was trimmed takes its new first key")
        #expect(Array(shifted.dropFirst()) == Array(before.suffix(shifted.count - 1)))
    }

    @Test
    func projectingATranscriptUsesItsItems() {
        var transcript = AgentTranscript()
        transcript.appendUser("go")
        let fields = ACPToolCallFields(toolCallID: "1", title: "git status", kind: .execute, status: .inProgress, content: nil)
        transcript.apply(ACPSessionNotification(sessionID: "s", update: .toolCall(fields)), rootSessionID: "s", now: now)
        let rows = AgentTimeline.project(transcript, isTurnRunning: true, acknowledgedSettles: [], now: now)
        #expect(kinds(rows) == ["user", "activity(1)"])
        #expect(groups(rows).first?.state == .live)
        #expect(groups(rows).first?.liveStatus == "Running git status")
    }

    // MARK: Budget

    @Test
    func largeTranscriptProjectsWithinBudget() {
        var items: [AgentChatItem] = [user("u-big")]
        for index in 0..<500 {
            items.append(tool("big-\(index)", ["Read", "Grep", "Edit", "Bash", "mcp__gh__x"][index % 5], start: 0, end: 1))
            if index % 50 == 0 { items.append(agent("child-\(index)", state: "idle", stopReason: "end_turn")) }
        }
        items.append(thought("t-big", String(repeating: "Reasoning about the plan. ", count: 400)))
        while items.count < 2_000 {
            let turn = items.count
            items += [user("u\(turn)"), tool("a\(turn)"), approval("r\(turn)", toolCallID: "a\(turn)", decision: .cancelledByUser), prose("p\(turn)")]
        }
        items = Array(items.prefix(2_000))
        var inputs: [String: JSONValue] = [:]
        for index in 0..<500 { inputs["root/tool-big-\(index)"] = ["command": .string("ls \(index)")] }
        _ = project(items, running: true, inputs: inputs)
        let clock = ContinuousClock()
        var best = Duration.seconds(60)
        var rows: [AgentTimelineRow] = []
        for _ in 0..<3 {
            let elapsed = clock.measure { rows = project(items, running: true, inputs: inputs) }
            best = min(best, elapsed)
        }
        #expect(groups(rows).first?.stepCount == 500)
        #expect(best < .milliseconds(50), "projection took \(best)")
    }
}
