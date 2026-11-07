import AppKit
import Testing
@testable import Pilot

/// The integrated transcript table (spec §3.9): minimal diffs, arithmetic
/// heights, view reuse, settle acknowledgements, the 1 Hz tick, and CI
/// budgets for streaming and large conversations.
@Suite("Agent chat timeline table")
@MainActor
struct AgentChatTimelineTableTests {
    nonisolated static let origin = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("One streamed chunk reconfigures exactly one cell, keeps the selection, and follows the end")
    func streamedChunkReconfiguresOneCell() throws {
        let (timeline, scroll, window) = makeTimeline()
        defer { window.close() }
        var rows = conversation(pairs: 20)
        timeline.applyRows(rows, now: Self.origin)
        settle(scroll)
        let last = rows.count - 1
        let cell = try #require(timeline.tableView.view(atColumn: 0, row: last, makeIfNecessary: false) as? ProseCellView)
        cell.textView.setSelectedRange(NSRange(location: 0, length: 3))
        rows[last] = .prose(AgentChatItem(id: "a19", content: .assistant("Answer 19 with another streamed sentence."), revision: 9_000))
        timeline.applyRows(rows, now: Self.origin)
        #expect(timeline.lastApplyPath == .reconfigure)
        #expect(timeline.lastReconfiguredRows == [last])
        #expect(timeline.tableView.view(atColumn: 0, row: last, makeIfNecessary: false) === cell, "The streaming cell is reused")
        #expect(cell.textView.string.hasSuffix("another streamed sentence."))
        #expect(cell.textView.selectedRange() == NSRange(location: 0, length: 3))
        settle(scroll)
        #expect(scroll.contentView.bounds.maxY >= timeline.tableView.bounds.maxY - 1, "The transcript follows streaming output")
        // Identical rows touch nothing.
        timeline.applyRows(rows, now: Self.origin)
        #expect(timeline.lastReconfiguredRows == [last])
    }

    @Test("A tool update in a 9-step live card reuses the card and every existing step view")
    func toolUpdateReusesStepViews() throws {
        let (timeline, scroll, window) = makeTimeline()
        defer { window.close() }
        var tools = (0..<9).map { tool($0, running: $0 == 8, revision: 10 + $0) }
        func rows() -> [AgentTimelineRow] {
            AgentTimeline.project(items: [user(0)] + tools, isTurnRunning: true, acknowledgedSettles: [],
                                  now: Self.origin.addingTimeInterval(5), repositoryName: "made")
        }
        timeline.applyRows(rows(), now: Self.origin)
        settle(scroll)
        let card = try #require(timeline.tableView.view(atColumn: 0, row: 1, makeIfNecessary: false) as? ActivityCardView)
        #expect(card.stepViews.count == 9)
        let before = card.stepViews.mapValues(ObjectIdentifier.init)
        tools[8] = tool(8, running: true, revision: 40, title: "Read Sources/Updated.swift")
        timeline.applyRows(rows(), now: Self.origin)
        #expect(timeline.lastApplyPath == .reconfigure)
        #expect(timeline.lastReconfiguredRows == [1])
        #expect(timeline.tableView.view(atColumn: 0, row: 1, makeIfNecessary: false) === card)
        #expect(card.stepViews.mapValues(ObjectIdentifier.init) == before, "Step views are reused by member key")
        #expect(card.group?.summary == "Explored made")
    }

    @Test("A 1200-row conversation applies within budget, creates only visible cells, and diffs appends and trims")
    func largeConversationBudget() throws {
        let (timeline, scroll, window) = makeTimeline()
        defer { window.close() }
        let rows = conversation(pairs: 600)
        let start = ContinuousClock.now
        timeline.applyRows(rows, now: Self.origin)
        settle(scroll)
        #expect(ContinuousClock.now - start < .seconds(3), "1200 rows must apply and lay out quickly")
        let created = rows.indices.filter { timeline.tableView.view(atColumn: 0, row: $0, makeIfNecessary: false) != nil }
        #expect(!created.isEmpty && created.count < 100, "Only visible rows get cells (\(created.count))")
        let appended = rows + [.notice(AgentChatItem(id: "n", content: .notice("Stopped."), revision: 1))]
        timeline.applyRows(appended, now: Self.origin)
        #expect(timeline.lastApplyPath == .insert)
        timeline.applyRows(Array(appended.dropFirst(120)), now: Self.origin)
        #expect(timeline.lastApplyPath == .headTrim)
        #expect(timeline.tableView.numberOfRows == appended.count - 120)
        timeline.applyRows(Array(conversation(pairs: 3).reversed()), now: Self.origin)
        #expect(timeline.lastApplyPath == .reload)
    }

    @Test("Projecting 2000 items with a 500-step group stays under budget")
    func projectionBudget() {
        var items: [AgentChatItem] = []
        for index in 0..<750 {
            items.append(user(index))
            items.append(AgentChatItem(id: "a\(index)", content: .assistant("Answer \(index)"), revision: 5_000 + index))
        }
        items.append(user(9_999))
        items += (0..<499).map { tool($0, running: false, revision: 20_000 + $0) }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let rows = AgentTimeline.project(items: items, isTurnRunning: false, acknowledgedSettles: [], now: Self.origin,
                                             repositoryName: "made")
            #expect(rows.count == 1_502)
        }
        #expect(elapsed < .milliseconds(250), "project() over 2000 items took \(elapsed)")
    }

    @Test("Settles are acknowledged at once off screen, when inline, or in a hidden window; live groups drop their ack")
    func settleAcknowledgements() {
        let timeline = AgentChatTimelineTable(tableView: AgentChatTimelineTableView())
        let tools = (0..<5).map { tool($0, running: false, revision: 10 + $0) }
        func rows(_ items: [AgentChatItem], running: Bool) -> [AgentTimelineRow] {
            AgentTimeline.project(items: items, isTurnRunning: running, acknowledgedSettles: timeline.acknowledgedSettles,
                                  now: Self.origin)
        }
        let live = rows([user(0)] + tools.dropLast() + [tool(4, running: true, revision: 30)], running: true)
        timeline.applyRows(live, now: Self.origin)
        let settling = rows([user(0)] + tools, running: false)
        guard case .activity(let group)? = settling.last else { Issue.record("expected a group"); return }
        #expect(group.state == .settling && group.animatesSettle)
        #expect(timeline.acknowledgeSettles(in: settling), "No window: the settle is acknowledged without animating")
        #expect(timeline.acknowledgedSettles.contains(group.id))
        guard case .activity(let settled)? = rows([user(0)] + tools, running: false).last else { return }
        #expect(settled.state == .settled)
        timeline.applyRows(rows([user(0)] + tools, running: false), now: Self.origin)
        // A late start reopens the group: its old acknowledgement must not skip the next settle.
        let reopened = rows([user(0)] + tools + [tool(5, running: true, revision: 50)], running: true)
        #expect(!timeline.acknowledgeSettles(in: reopened))
        #expect(!timeline.acknowledgedSettles.contains(group.id))
        let small = rows([user(1)] + (10..<12).map { tool($0, running: false, revision: 60 + $0) }, running: false)
        guard case .activity(let inline)? = small.last else { return }
        #expect(inline.state == .settling && !inline.animatesSettle)
        #expect(timeline.acknowledgeSettles(in: small))
    }

    @Test("The 1 Hz tick runs only while a live group is visible in a visible window")
    func tickFollowsVisibleLiveGroups() {
        let (timeline, scroll, window) = makeTimeline()
        defer { window.close() }
        let live = AgentTimeline.project(items: [user(0), tool(0, running: true, revision: 3)], isTurnRunning: true,
                                         acknowledgedSettles: [], now: Self.origin)
        timeline.applyRows(live, now: Self.origin)
        settle(scroll)
        #expect(!timeline.isTicking, "An offscreen window never ticks")
        window.orderFront(nil)
        timeline.updateTimer()
        if window.occlusionState.contains(.visible) { #expect(timeline.isTicking) }
        let settled = AgentTimeline.project(items: [user(0), tool(0, running: false, revision: 4)], isTurnRunning: false,
                                            acknowledgedSettles: ["activity-root/tool-t0"], now: Self.origin)
        timeline.applyRows(settled, now: Self.origin)
        #expect(!timeline.isTicking, "Nothing live: no timer")
        window.orderOut(nil)
    }

    @Test("Expansion toggles, roster toggles, and show-all change only the touched row")
    func disclosureOverrides() throws {
        let (timeline, scroll, window) = makeTimeline()
        defer { window.close() }
        let tools = (0..<20).map { tool($0, running: false, revision: 10 + $0) }
        let rows = AgentTimeline.project(items: [user(0)] + tools + [AgentChatItem(id: "a", content: .assistant("Done"), revision: 99)],
                                         isTurnRunning: false, acknowledgedSettles: ["activity-root/tool-t0"], now: Self.origin)
        timeline.applyRows(rows, now: Self.origin)
        settle(scroll)
        let collapsed = timeline.tableView.rect(ofRow: 1).height
        timeline.toggleExpanded("activity-root/tool-t0")
        settle(scroll)
        #expect(timeline.expandedOverrides["activity-root/tool-t0"] == true)
        let expanded = timeline.tableView.rect(ofRow: 1).height
        #expect(expanded > collapsed)
        let card = try #require(timeline.tableView.view(atColumn: 0, row: 1, makeIfNecessary: false) as? ActivityCardView)
        #expect(card.stepViews.count == 4, "Settled past 15: first 2 + last 2")
        timeline.showAll("activity-root/tool-t0")
        settle(scroll)
        #expect(card.stepViews.count == 20)
        #expect(timeline.tableView.rect(ofRow: 1).height > expanded)
    }

    @Test("A message over 64 KiB redacts off the main actor: never raw text, then the redacted rendering and its height")
    func largeProseRedactsOffTheMainActor() async throws {
        let (timeline, scroll, window) = makeTimeline()
        defer { window.close() }
        let secret = "ghp_" + String(repeating: "A1b2C3d4", count: 5)
        let body = (0..<1_500).map { "Line \($0) of a long streamed answer that keeps going." }.joined(separator: "\n")
        let text = body + "\nexport GITHUB_TOKEN=\(secret)\n" + "Done."
        #expect(text.utf8.count > AgentRedactionPolicy.offMainThresholdBytes)
        let rows: [AgentTimelineRow] = [.user(user(0)), .prose(AgentChatItem(id: "big", content: .assistant(text), revision: 77_001))]
        timeline.applyRows(rows, now: Self.origin)
        settle(scroll)
        let cell = try #require(timeline.tableView.view(atColumn: 0, row: 1, makeIfNecessary: true) as? ProseCellView)
        #expect(!cell.textView.string.contains(secret), "Raw text never reaches the cell while it redacts")
        let placeholderHeight = timeline.tableView.rect(ofRow: 1).height
        func shownText() -> String {
            (timeline.tableView.view(atColumn: 0, row: 1, makeIfNecessary: true) as? ProseCellView)?.textView.string ?? ""
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while !shownText().contains("Done."), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        settle(scroll)
        let shown = try #require(timeline.tableView.view(atColumn: 0, row: 1, makeIfNecessary: true) as? ProseCellView)
        #expect(shown.textView.string.contains("Done."))
        #expect(!shown.textView.string.contains(secret))
        #expect(timeline.tableView.rect(ofRow: 1).height > placeholderHeight, "The row is remeasured for the redacted text")
    }

    @Test("User bubbles carry a steer caption that changes their height")
    func steerCaptionsResizeTheBubble() throws {
        let (timeline, scroll, window) = makeTimeline()
        defer { window.close() }
        let rows = conversation(pairs: 2)
        timeline.applyRows(rows, now: Self.origin)
        settle(scroll)
        let plain = timeline.tableView.rect(ofRow: 2).height
        timeline.userCaptions = [user(1).key: "Sent to running turn"]
        settle(scroll)
        let cell = try #require(timeline.tableView.view(atColumn: 0, row: 2, makeIfNecessary: false) as? UserBubbleCellView)
        #expect(cell.captionLabel.stringValue == "Sent to running turn" && !cell.captionLabel.isHidden)
        #expect(timeline.tableView.rect(ofRow: 2).height > plain)
        timeline.userCaptions = [:]
        settle(scroll)
        #expect(cell.captionLabel.isHidden)
        #expect(abs(timeline.tableView.rect(ofRow: 2).height - plain) < 0.5)
    }

    // MARK: - Fixtures

    private func makeTimeline() -> (AgentChatTimelineTable, NSScrollView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let table = AgentChatTimelineTableView()
        let timeline = AgentChatTimelineTable(tableView: table)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        scroll.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(scroll)
        table.frame = scroll.contentView.bounds
        table.sizeLastColumnToFit()
        timeline.observeScrolling(scroll)
        return (timeline, scroll, window)
    }

    private func settle(_ scroll: NSScrollView) {
        scroll.layoutSubtreeIfNeeded()
        (scroll.documentView as? NSTableView)?.layoutSubtreeIfNeeded()
    }

    private func conversation(pairs: Int) -> [AgentTimelineRow] {
        (0..<pairs).flatMap { index -> [AgentTimelineRow] in
            [.user(user(index)), .prose(AgentChatItem(id: "a\(index)", content: .assistant("Answer \(index)"), revision: 1_000 + index))]
        }
    }

    private func user(_ index: Int) -> AgentChatItem {
        AgentChatItem(id: "u\(index)", content: .user("Question \(index)"), revision: index)
    }

    private func tool(_ index: Int, running: Bool, revision: Int, title: String? = nil) -> AgentChatItem {
        var call = AgentChatItem.ToolCall(title: title ?? "Read file\(index).swift", kind: .read,
                                          status: running ? .inProgress : .completed, content: "", toolCallID: "t\(index)")
        call.startedAt = Self.origin
        call.endedAt = running ? nil : Self.origin.addingTimeInterval(1)
        call.outcome = running ? nil : .completed
        return AgentChatItem(id: "tool-t\(index)", content: .tool(call), revision: revision)
    }
}
