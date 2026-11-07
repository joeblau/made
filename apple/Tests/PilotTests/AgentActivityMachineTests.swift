import Foundation
import Testing
@testable import Pilot

/// Every activity-card transition, fold, replay, and acknowledged settle.
@Suite("Agent activity machine")
struct AgentActivityMachineTests {
    private typealias Machine = AgentActivityMachine

    static let starts: [AgentActivityEvent] = [
        .stepStart(key: "root/a"), .agentSpawn(childSessionID: "c", parentKey: nil), .reasoningDelta(key: "root/t"),
    ]
    static let terminals: [AgentActivityEvent] = [
        .stepEnd(key: "root/a"), .stepFail(key: "root/a", summary: "boom"),
        .agentEnd(childSessionID: "c", lifecycle: "done"), .reasoningEnd(key: "root/t"),
    ]

    @Test
    func noInputsStayIdle() {
        #expect(AgentActivityMachine.fold([]) == .idle)
    }

    // MARK: reduce

    @Test(arguments: starts)
    func everyStartGoesLiveFromEveryState(event: AgentActivityEvent) {
        for state in [AgentActivityState.idle, .live, .settling, .settled] {
            #expect(Machine.reduce(state, .event(event), runningCount: 1, closed: false) == .live, "\(state)")
            #expect(Machine.reduce(state, .event(event), runningCount: 1, closed: true) == .live, "\(state) closed")
            #expect(Machine.reduce(state, .event(event), runningCount: 1) == .live, "\(state) 3-arg")
        }
    }

    @Test(arguments: terminals)
    func terminalEventsSettleOnlyWhenClosedAndIdle(event: AgentActivityEvent) {
        #expect(Machine.reduce(.live, .event(event), runningCount: 0, closed: true) == .settling)
        #expect(Machine.reduce(.live, .event(event), runningCount: 1, closed: true) == .live)
        #expect(Machine.reduce(.live, .event(event), runningCount: 0, closed: false) == .live)
        #expect(Machine.reduce(.live, .event(event), runningCount: 0) == .live, "3-arg reduce never assumes closed")
        #expect(Machine.reduce(.idle, .event(event), runningCount: 0, closed: true) == .idle)
        #expect(Machine.reduce(.settling, .event(event), runningCount: 0, closed: true) == .settling)
        #expect(Machine.reduce(.settled, .event(event), runningCount: 0, closed: true) == .settled)
    }

    @Test
    func closedTransitions() {
        #expect(Machine.reduce(.live, .closed, runningCount: 0) == .settling)
        #expect(Machine.reduce(.live, .closed, runningCount: 2) == .live)
        #expect(Machine.reduce(.idle, .closed, runningCount: 0) == .settled)
        #expect(Machine.reduce(.settling, .closed, runningCount: 0) == .settling)
        #expect(Machine.reduce(.settled, .closed, runningCount: 0) == .settled)
    }

    @Test
    func collapseFinishedOnlySettlesASettlingGroup() {
        #expect(Machine.reduce(.settling, .collapseFinished, runningCount: 0) == .settled)
        #expect(Machine.reduce(.live, .collapseFinished, runningCount: 0) == .live)
        #expect(Machine.reduce(.idle, .collapseFinished, runningCount: 0) == .idle)
        #expect(Machine.reduce(.settled, .collapseFinished, runningCount: 0) == .settled)
    }

    // MARK: fold

    @Test
    func aStepRunsSettlesAndCollapses() {
        let start = AgentActivityInput.event(.stepStart(key: "root/a"))
        let end = AgentActivityInput.event(.stepEnd(key: "root/a"))
        #expect(Machine.fold([start]) == .live)
        #expect(Machine.fold([start, end]) == .live, "open until closed")
        #expect(Machine.fold([start, end, .closed]) == .settling)
        #expect(Machine.fold([start, end, .closed, .collapseFinished]) == .settled)
    }

    @Test
    func closingWhileRunningWaitsForTheLastTerminalEvent() {
        let inputs: [AgentActivityInput] = [
            .event(.stepStart(key: "root/a")), .event(.stepStart(key: "root/b")), .closed,
            .event(.stepEnd(key: "root/a")),
        ]
        #expect(Machine.fold(inputs) == .live)
        #expect(Machine.fold(inputs + [.event(.stepFail(key: "root/b", summary: nil))]) == .settling)
        #expect(Machine.fold(inputs + [.collapseFinished]) == .live, "an early ack is ignored")
    }

    @Test
    func agentsAndReasoningCountAsRunning() {
        let agent: [AgentActivityInput] = [.event(.agentSpawn(childSessionID: "c1", parentKey: "root/tool-1")), .closed]
        #expect(Machine.fold(agent) == .live)
        #expect(Machine.fold(agent + [.event(.agentEnd(childSessionID: "c1", lifecycle: "done"))]) == .settling)
        let thought: [AgentActivityInput] = [.event(.reasoningDelta(key: "root/t")), .event(.reasoningDelta(key: "root/t")), .closed]
        #expect(Machine.fold(thought) == .live)
        #expect(Machine.fold(thought + [.event(.reasoningEnd(key: "root/t"))]) == .settling)
    }

    @Test
    func repeatedStartsOfOneKeyCountOnce() {
        let inputs: [AgentActivityInput] = [
            .event(.stepStart(key: "root/a")), .event(.stepStart(key: "root/a")), .event(.stepEnd(key: "root/a")), .closed,
        ]
        #expect(Machine.fold(inputs) == .settling)
    }

    @Test
    func lateStartsReopenSettlingAndSettledGroups() {
        let settling: [AgentActivityInput] = [.event(.stepStart(key: "root/a")), .event(.stepEnd(key: "root/a")), .closed]
        let reopened = settling + [.event(.stepStart(key: "root/b"))]
        #expect(Machine.fold(reopened) == .live)
        #expect(Machine.fold(reopened + [.event(.stepEnd(key: "root/b"))]) == .settling, "closure persists")
        let settled = settling + [.collapseFinished]
        #expect(Machine.fold(settled + [.event(.agentSpawn(childSessionID: "late", parentKey: nil))]) == .live)
    }

    @Test
    func anEmptyClosedGroupSettlesDirectly() {
        #expect(Machine.fold([.closed]) == .settled)
        #expect(Machine.fold([.closed, .collapseFinished]) == .settled)
    }

    @Test
    func terminalWithoutStartLeavesIdle() {
        #expect(Machine.fold([.event(.stepEnd(key: "root/x"))]) == .idle)
    }

    // MARK: Inputs derived from members

    private func toolItem(_ id: String, status: ACPToolStatus, outcome: AgentChatItem.ToolCall.Outcome? = nil) -> AgentChatItem {
        var tool = AgentChatItem.ToolCall(title: "t", kind: .execute, status: status, content: "")
        tool.outcome = outcome
        tool.errorSummary = status == .failed ? "exit 1" : nil
        return AgentChatItem(id: id, content: .tool(tool))
    }

    @Test
    func machineInputsFollowMemberOrderThenClosedThenAck() {
        let thought = AgentChatItem(id: "t1", content: .thought(.init(text: "hm")))
        var agent = AgentChatItem.Subagent(childSessionID: "c1", title: "Research", state: "idle", error: nil)
        agent.stopReason = "end_turn"
        agent.spawnToolCallID = "9"
        let agentItem = AgentChatItem(id: "subagent-c1", content: .subagent(agent))
        let members: [(item: AgentChatItem, isActive: Bool)] = [
            (thought, false), (toolItem("tool-1", status: .completed), false), (toolItem("tool-2", status: .failed), false),
            (agentItem, false), (toolItem("tool-3", status: .inProgress), true),
        ]
        let inputs = AgentTimeline.machineInputs(for: members, closed: true, acknowledged: true)
        #expect(inputs == [
            .event(.reasoningDelta(key: "root/t1")), .event(.reasoningEnd(key: "root/t1")),
            .event(.stepStart(key: "root/tool-1")), .event(.stepEnd(key: "root/tool-1")),
            .event(.stepStart(key: "root/tool-2")), .event(.stepFail(key: "root/tool-2", summary: "exit 1")),
            .event(.agentSpawn(childSessionID: "c1", parentKey: "root/tool-9")),
            .event(.agentEnd(childSessionID: "c1", lifecycle: "done")),
            .event(.stepStart(key: "root/tool-3")),
            .closed, .collapseFinished,
        ])
        #expect(Machine.fold(inputs) == .live, "a running member keeps the group live")
        let settledInputs = AgentTimeline.machineInputs(for: Array(members.dropLast()), closed: true, acknowledged: true)
        #expect(Machine.fold(settledInputs) == .settled)
        let unacknowledged = AgentTimeline.machineInputs(for: Array(members.dropLast()), closed: true, acknowledged: false)
        #expect(Machine.fold(unacknowledged) == .settling)
        #expect(AgentTimeline.machineInputs(for: [], closed: false, acknowledged: false).isEmpty)
    }

    @Test
    func cancelledAndRejectedStepsEndRatherThanFail() {
        for outcome in [AgentChatItem.ToolCall.Outcome.cancelled, .rejected, .interrupted, .notFinished] {
            let inputs = AgentTimeline.machineInputs(
                for: [(toolItem("tool-x", status: .completed, outcome: outcome), false)], closed: false, acknowledged: false
            )
            #expect(inputs.last == .event(.stepEnd(key: "root/tool-x")), "\(outcome)")
        }
    }

    @Test
    func foldIsDeterministic() {
        let inputs = AgentTimeline.machineInputs(
            for: (0..<50).map { (toolItem("tool-\($0)", status: $0 % 7 == 0 ? .failed : .completed), false) },
            closed: true, acknowledged: false
        )
        let first = Machine.fold(inputs)
        for _ in 0..<10 { #expect(Machine.fold(inputs) == first) }
        #expect(first == .settling)
    }
}
