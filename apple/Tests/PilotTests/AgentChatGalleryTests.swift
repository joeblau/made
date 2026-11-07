import AppKit
import Testing
@testable import Pilot

/// Gallery fixtures (fixed clock, light and dark, widths 360/560/900). Asserts
/// structure always; writes PNGs when MADE_TOOL_REVIEW_OUTPUT is set.
@Suite("Agent chat gallery")
@MainActor
struct AgentChatGalleryTests {
    nonisolated static let widths: [CGFloat] = [360, 560, 900]

    @Test
    func everyViewKindCarriesItsIdentifier() {
        #expect(ProseCellView().identifier == ProseCellView.reuseIdentifier)
        #expect(ActivityCardView().accessibilityIdentifier() == "agent-chat.activity")
        #expect(ActivityStepView().accessibilityIdentifier() == "agent-chat.step")
        #expect(AgentRosterView().accessibilityIdentifier() == "agent-chat.roster")
        #expect(AgentChipView().accessibilityIdentifier() == "agent-chat.chip")
        #expect(ApprovalCardView().accessibilityIdentifier() == "agent-chat.approval")
        #expect(AgentInspectorViewController().view.accessibilityIdentifier() == "agent-chat.inspector")
    }

    // MARK: - Palette, glyphs, status dots

    @Test("Palette text tokens meet 4.5:1 on their surfaces in light and dark")
    func paletteContrast() {
        for pair in AgentChatPalette.textPairs {
            for dark in [false, true] {
                let ratio = AgentChatPalette.contrastRatio(pair.text, on: pair.surface, dark: dark)
                #expect(ratio >= 4.5, "\(pair.name) (\(dark ? "dark" : "light")) is \(ratio):1")
            }
        }
        #expect(AgentChatPalette.contrastRatio(.cardBorder, on: .thread, dark: true) >= 1.5)
        #expect(abs(AgentChatPalette.contrastRatio(0x000000, 0xFFFFFF) - 21) < 0.01)
    }

    @Test("Every tool glyph is a distinct 14 pt template image")
    func glyphsAreDistinctTemplates() throws {
        var renderings: [Data] = []
        for glyph in AgentToolVerb.Glyph.allCases {
            let image = AgentChatGlyphs.image(for: glyph)
            #expect(image.isTemplate)
            #expect(image.size == NSSize(width: 14, height: 14))
            let data = try #require(render(image))
            #expect(!renderings.contains(data), "\(glyph) duplicates another glyph")
            renderings.append(data)
        }
    }

    @Test("Status dots draw a distinct shape per state and pulse only while running without Reduce Motion")
    func statusDots() throws {
        let previous = AgentChatMotion.reduceMotion
        defer { AgentChatMotion.reduceMotion = previous }
        AgentChatMotion.reduceMotion = { false }
        let statuses: [AgentStatusDotView.Status] = [.queued, .running, .done, .failed, .stopped, .background]
        var renderings: [Data] = []
        for status in statuses {
            let dot = AgentStatusDotView()
            dot.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
            dot.configure(status: status)
            #expect(dot.isPulsing == (status == .running))
            #expect(dot.accessibilityLabel() == status.accessibilityName)
            let data = try #require(snapshotData(dot))
            #expect(!renderings.contains(data), "\(status) is not visually distinct")
            renderings.append(data)
        }
        AgentChatMotion.reduceMotion = { true }
        let still = AgentStatusDotView()
        still.configure(status: .running)
        #expect(!still.isPulsing)
    }

    // MARK: - Activity cards

    @Test("Live group with 9 steps streams newest at the bottom with a live line", arguments: widths)
    func liveGroupWithNineSteps(width: CGFloat) throws {
        let fixture = Gallery.steps(count: 9, failing: [4], runningLast: true)
        let group = Gallery.group(fixture.items, state: .live, liveStatus: "Running bun test transport")
        for dark in [false, true] {
            let (card, host) = try renderCard(group, verbs: fixture.verbs, width: width, dark: dark)
            #expect(card.presentation?.inline == false)
            let steps = visibleSteps(in: card)
            #expect(steps.count == 9)
            #expect(steps.last?.item?.id == fixture.items.last?.id, "The newest step must be at the bottom")
            #expect(!card.liveLine.isHidden)
            #expect(card.liveLine.text == "Running bun test transport")
            #expect(!card.header.failedLabel.isHidden)
            #expect(card.header.failedLabel.stringValue.hasSuffix("1 failed"))
            #expect(card.header.durationLabel.stringValue.hasSuffix("1m 30s"))
            try capture(host, name: "activity-live-9-\(Int(width))-\(dark ? "dark" : "light")")
        }
    }

    @Test("Settled group with one failure keeps the failed row beneath its one-line label", arguments: widths)
    func settledGroupWithOneFailure(width: CGFloat) throws {
        let fixture = Gallery.steps(count: 9, failing: [4], runningLast: false)
        let group = Gallery.group(fixture.items, state: .settled)
        for dark in [false, true] {
            let (card, host) = try renderCard(group, verbs: fixture.verbs, width: width, dark: dark)
            let steps = visibleSteps(in: card)
            #expect(steps.count == 1)
            #expect(steps.first?.content?.status == .failed)
            #expect(steps.first?.retryButton.isHidden == false)
            #expect(steps.first?.errorLabel.stringValue.contains("2 tests failed") == true)
            #expect(card.liveLine.isHidden)
            #expect(card.header.failedLabel.stringValue.hasSuffix("1 failed"))
            try capture(host, name: "activity-settled-failure-\(Int(width))-\(dark ? "dark" : "light")")
            let (expanded, _) = try renderCard(group, expandedOverride: true, verbs: fixture.verbs, width: width, dark: dark)
            #expect(visibleSteps(in: expanded).count == 9)
        }
    }

    @Test("Settled groups of three quiet steps render inline without card chrome")
    func inlineWeight() throws {
        let fixture = Gallery.steps(count: 3, failing: [], runningLast: false)
        let (card, _) = try renderCard(Gallery.group(fixture.items, state: .settled), verbs: fixture.verbs, width: 560, dark: false)
        #expect(card.presentation?.inline == true)
        #expect(card.chrome.isHidden && card.header.isHidden)
        #expect(visibleSteps(in: card).count == 3)
        let four = Gallery.steps(count: 4, failing: [], runningLast: false)
        let (cardFour, _) = try renderCard(Gallery.group(four.items, state: .settled), verbs: four.verbs, width: 560, dark: false)
        #expect(cardFour.presentation?.inline == false)
        #expect(visibleSteps(in: cardFour).isEmpty)
    }

    @Test("Long groups show the last 6 while live and first 2 + last 2 when expanded settled")
    func longGroups() throws {
        let fixture = Gallery.steps(count: 20, failing: [], runningLast: true)
        let (live, _) = try renderCard(Gallery.group(fixture.items, state: .live), verbs: fixture.verbs, width: 560, dark: false)
        #expect(live.presentation?.rows.first == .earlier(14))
        #expect(visibleSteps(in: live).count == 6)
        let settled = Gallery.steps(count: 20, failing: [], runningLast: false)
        let group = Gallery.group(settled.items, state: .settled)
        var shown: [String] = []
        var actions = AgentChatRowActions()
        actions.showAll = { shown.append($0) }
        let (card, _) = try renderCard(group, expandedOverride: true, verbs: settled.verbs, width: 560, dark: false, actions: actions)
        #expect(visibleSteps(in: card).count == 4)
        #expect(card.presentation?.rows[2] == .showMore(16))
        let more = try #require(descendants(of: card).compactMap { $0 as? AgentChatClosureButton }.first { $0.title == "Show 16 more" })
        more.performClick(nil)
        #expect(shown == [group.id])
        let (all, _) = try renderCard(group, expandedOverride: true, showAll: true, verbs: settled.verbs, width: 560, dark: false)
        #expect(visibleSteps(in: all).count == 20)
        let failing = Gallery.steps(count: 30, failing: Set(0..<20), runningLast: false)
        let (collapsed, _) = try renderCard(Gallery.group(failing.items, state: .settled), verbs: failing.verbs, width: 360, dark: false)
        #expect(collapsed.presentation?.rows.first == .earlierFailures(14), "Collapsed failure rows are bounded")
        #expect(visibleSteps(in: collapsed).count == 6)
    }

    @Test("The header never truncates failed, stopped, or duration before the summary")
    func headerTruncationOrder() {
        let parts = ActivityHeaderParts(summary: "Explored a very long repository name that keeps going", steps: "12 steps",
                                        failed: "2 failed", stopped: "1 stopped", duration: "1m 42s")
        let frames = ActivityHeaderView.labelFrames(parts: parts, width: 300, height: 24)
        let font = ActivityHeaderView.detailFont
        #expect(frames[2].width == AgentChatText.width(" · 2 failed", font: font))
        #expect(frames[3].width == AgentChatText.width(" · 1 stopped", font: font))
        #expect(frames[4].width == AgentChatText.width(" · 1m 42s", font: font))
        #expect(frames[0].width < AgentChatText.width(parts.summary, font: ActivityHeaderView.summaryFont))
        #expect(frames.last.map(\.maxX) ?? 0 <= 300)
    }

    @Test("A live card grows from 3 to 9 steps and settles at 360 pt without clipping")
    func liveCardGrowsAndSettles() async throws {
        let fixture = Gallery.steps(count: 9, failing: [4], runningLast: true)
        var acknowledged: [String] = []
        var actions = AgentChatRowActions()
        actions.collapseFinished = { acknowledged.append($0) }
        let card = ActivityCardView()
        let host = Gallery.host(dark: true)
        host.addSubview(card)
        for count in [3, 5, 7, 9] {
            let items = Array(fixture.items.prefix(count))
            let group = Gallery.group(items, state: .live)
            try place(card, in: host, group: group, verbs: fixture.verbs, width: 360, actions: actions)
            #expect(visibleSteps(in: card).count == count)
            try capture(host, name: "activity-growing-\(count)-360-dark")
        }
        var finished = fixture.items
        if case .tool(var tool) = finished[8].content {
            tool.status = .completed
            tool.outcome = .completed
            tool.endedAt = Gallery.at(95)
            finished[8].content = .tool(tool)
        }
        let settling = Gallery.group(finished, state: .settling)
        try place(card, in: host, group: settling, verbs: fixture.verbs, width: 360, actions: actions)
        let deadline = ContinuousClock.now + .seconds(2)
        while acknowledged.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        #expect(acknowledged == [settling.id], "Without a visible window the settle is acknowledged immediately")
        var settled = settling
        settled.state = .settled
        try place(card, in: host, group: settled, verbs: fixture.verbs, width: 360, actions: actions)
        #expect(visibleSteps(in: card).count == 1)
        #expect(acknowledged.count == 1)
        try capture(host, name: "activity-settled-360-dark")
    }

    @Test("Settling animates closed in a visible window and acknowledges on completion, immediately under Reduce Motion",
          arguments: [false, true])
    func settleAnimation(reduceMotion: Bool) async throws {
        let previous = AgentChatMotion.reduceMotion
        defer { AgentChatMotion.reduceMotion = previous }
        AgentChatMotion.reduceMotion = { reduceMotion }
        let window = Gallery.window(width: 560, height: 600)
        defer { window.close() }
        let host = Gallery.host(dark: false)
        window.contentView = host
        window.orderFront(nil)
        var acknowledged: [String] = []
        var actions = AgentChatRowActions()
        actions.collapseFinished = { acknowledged.append($0) }
        let card = ActivityCardView()
        host.addSubview(card)
        let fixture = Gallery.steps(count: 6, failing: [], runningLast: false)
        try place(card, in: host, group: Gallery.group(fixture.items, state: .live), verbs: fixture.verbs, width: 560, actions: actions)
        let settling = Gallery.group(fixture.items, state: .settling)
        card.configure(group: settling, expandedOverride: nil, showAll: false, now: Gallery.at(90), actions: actions,
                       verbs: fixture.verbs)
        #expect(card.isAnimatingTransition == !reduceMotion)
        if !reduceMotion {
            // A late start re-opens the group mid-animation: no stale acknowledgement.
            card.configure(group: Gallery.group(fixture.items, state: .live), expandedOverride: nil, showAll: false,
                           now: Gallery.at(90), actions: actions, verbs: fixture.verbs)
            #expect(!card.isAnimatingTransition)
            try await Task.sleep(for: .seconds(AgentChatMotion.duration + 0.3))
            #expect(acknowledged.isEmpty)
            card.configure(group: settling, expandedOverride: nil, showAll: false, now: Gallery.at(90), actions: actions,
                           verbs: fixture.verbs)
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while acknowledged.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(acknowledged == [settling.id])
        #expect(!card.isAnimatingTransition)
        layout(host)
        #expect(visibleSteps(in: card).isEmpty)
    }

    @Test("Reasoning streams as a live shimmer line that is static under Reduce Motion")
    func reasoningStreaming() throws {
        let previous = AgentChatMotion.reduceMotion
        defer { AgentChatMotion.reduceMotion = previous }
        let thought = AgentChatItem(id: "thought-1", content: .thought(.init(text: "Checking how the HyperEVM transport…",
                                                                           startedAt: Gallery.at(0))), revision: 3)
        let status = "Checking how the HyperEVM transport handles RPC fallbacks…"
        let group = Gallery.group([thought], state: .live, liveStatus: status)
        let verbs = [thought.key: AgentToolVerb(glyph: .think, live: "Thinking", settled: "Thought for 12s", detail: nil, exactInput: nil)]
        var opened: [(AgentInspectorSubject, AgentInspectorTab?)] = []
        var actions = AgentChatRowActions()
        actions.openInspector = { opened.append(($0, $1)) }
        for width in Self.widths {
            for dark in [false, true] {
                AgentChatMotion.reduceMotion = { false }
                let (card, host) = try renderCard(group, verbs: verbs, width: width, dark: dark, actions: actions)
                #expect(card.liveLine.text == status)
                #expect(card.liveLine.isShimmering)
                try capture(host, name: "activity-reasoning-\(Int(width))-\(dark ? "dark" : "light")")
                AgentChatMotion.reduceMotion = { true }
                let (still, _) = try renderCard(group, verbs: verbs, width: width, dark: dark)
                #expect(!still.liveLine.isShimmering)
            }
        }
        let (card, _) = try renderCard(group, verbs: verbs, width: 560, dark: false, actions: actions)
        var other = Gallery.group(Gallery.steps(count: 4, failing: [], runningLast: true).items, state: .live, liveStatus: "Running tests")
        other.id = "activity-other"
        card.configure(group: other, expandedOverride: nil, showAll: false, now: Gallery.at(90), actions: actions)
        #expect(card.liveLine.text == "Running tests", "A reused card never shows another group's live line")
        card.configure(group: group, expandedOverride: nil, showAll: false, now: Gallery.at(90), actions: actions, verbs: verbs)
        let step = try #require(visibleSteps(in: card).first)
        #expect(step.content?.isThought == true)
        #expect(step.content?.copyText == nil, "Reasoning is never copyable from the thread")
        #expect(step.accessibilityCustomActions()?.map(\.name).contains("Copy command") == false)
        step.openInspector()
        #expect(opened.last?.0 == .thought(key: thought.key))
        #expect(opened.last?.1 == .reasoning)
    }

    @Test("A step whose command carries a secret shows only redacted text in label, tooltip, copy, and accessibility")
    func secretBearingStep() throws {
        let secret = "sk-ant-api03-SECRETSECRETSECRETSECRET"
        let command = "curl -H 'Authorization: Bearer \(secret)' https://api.example.com/v1/messages"
        let item = Gallery.tool("secret", title: command, kind: .execute, status: .completed, outcome: .completed, start: 0, end: 2)
        let verb = AgentToolVerb(glyph: .shell, live: "Running curl", settled: "Ran curl -H 'Authorization: Bearer \(secret)'",
                                 detail: "api.example.com", exactInput: command)
        var copied: [String] = []
        var actions = AgentChatRowActions()
        actions.copyText = { copied.append($0) }
        for width in Self.widths {
            for dark in [false, true] {
                let step = ActivityStepView()
                step.configure(item: item, verb: verb, actions: actions)
                step.setHovering(true)
                let host = try mount(step, height: ActivityStepView.height(item: item, verb: verb, width: width), width: width, dark: dark)
                #expect(step.label.stringValue == redactInline(verb.settled))
                #expect(step.toolTip == redactInline(command))
                #expect(!step.copyButton.isHidden)
                step.copyButton.performClick(nil)
                #expect(copied.last == redactOutput(command, maximumLines: nil).text)
                let surfaces = [step.label.stringValue, step.toolTip ?? "", copied.last ?? "", step.accessibilityLabel() ?? "",
                                step.accessibilityHelp() ?? ""]
                // Strong assertion once the redaction policy (WP3) is merged.
                if redactInline(secret) != secret {
                    for text in surfaces { #expect(!text.contains(secret)) }
                }
                try capture(host, name: "step-secret-\(Int(width))-\(dark ? "dark" : "light")")
            }
        }
    }

    @Test("Failed steps expose retry only when it can apply, plus accessibility actions")
    func stepActions() throws {
        var retried: [String] = []
        var opened: [AgentInspectorSubject] = []
        var actions = AgentChatRowActions()
        actions.askToRetry = { retried.append($0) }
        actions.openInspector = { subject, _ in opened.append(subject) }
        let failed = Gallery.tool("f", title: "bun test", kind: .execute, status: .failed, outcome: .failed, start: 0, end: 3,
                                  error: "2 tests failed")
        let verb = AgentToolVerb(glyph: .shell, live: "Running bun test", settled: "Ran bun test", detail: nil, exactInput: "bun test")
        let step = ActivityStepView()
        step.configure(item: failed, verb: verb, actions: actions)
        #expect(step.accessibilityCustomActions()?.map(\.name) == ["Copy command", "Open in Inspector", "Ask to retry"])
        step.retryButton.performClick(nil)
        #expect(retried == [failed.key])
        #expect(step.accessibilityPerformPress())
        #expect(opened == [.step(key: failed.key)])
        var replayed = failed
        replayed.isReplayed = true
        step.configure(item: replayed, verb: verb, actions: actions)
        #expect(step.retryButton.isHidden)
        let rejected = Gallery.tool("r", title: "rm -rf", kind: .execute, status: .failed, outcome: .rejected, start: 0, end: 1)
        step.configure(item: rejected, verb: verb, actions: actions)
        #expect(step.retryButton.isHidden)
        #expect(step.content?.status == .stopped)
    }

    // MARK: - Roster

    @Test("A 12-agent roster wraps chips while live and collapses to a summary when settled", arguments: widths)
    func twelveAgentRoster(width: CGFloat) throws {
        var continued: [String] = []
        var actions = AgentChatRowActions()
        actions.askToContinue = { continued.append($0) }
        for dark in [false, true] {
            let live = Gallery.roster(live: true)
            let liveGroup = Gallery.group([], extra: [.agents(live)], state: .live, liveStatus: "Coordinating 12 agents")
            let (card, host) = try renderCard(liveGroup, verbs: [:], width: width, dark: dark)
            let chips = descendants(of: card).compactMap { $0 as? AgentChipView }.filter { isVisible($0) }
            #expect(chips.count == 12)
            #expect(chips.allSatisfy { $0.bounds.width <= AgentChipView.maximumWidth })
            #expect(chips.contains { $0.dot.isPulsing || AgentChatMotion.reduceMotion() })
            let running = try #require(chips.first { $0.entry?.lifecycle == .running })
            card.tick(now: try #require(running.entry?.startedAt).addingTimeInterval(200))
            #expect(running.toolTip?.contains("Running · 3m 20s") == true, "Chip elapsed time follows the 1 Hz tick")
            try capture(host, name: "roster-live-\(Int(width))-\(dark ? "dark" : "light")")

            let settled = Gallery.roster(live: false)
            let settledGroup = Gallery.group([], extra: [.agents(settled)], state: .settled)
            let (settledCard, settledHost) = try renderCard(settledGroup, expandedOverride: true, verbs: [:], width: width, dark: dark)
            let roster = try #require(descendants(of: settledCard).compactMap { $0 as? AgentRosterView }.first)
            #expect(roster.summaryLabel.stringValue == "12 agents · 10 done · 2 failed")
            #expect(descendants(of: settledCard).compactMap { $0 as? AgentChipView }.filter { isVisible($0) }.isEmpty)
            try capture(settledHost, name: "roster-settled-\(Int(width))-\(dark ? "dark" : "light")")

            let id = AgentRosterView.rosterID(settled)
            let (expandedCard, _) = try renderCard(settledGroup, expandedOverride: true, verbs: [:], rosterOverrides: [id: true],
                                                   width: width, dark: dark, actions: actions)
            let failedChip = try #require(descendants(of: expandedCard).compactMap { $0 as? AgentChipView }
                .first { $0.entry?.lifecycle == .failed })
            #expect(failedChip.toolTip?.contains("Failed") == true)
            let menu = try #require(failedChip.contextMenu())
            #expect(menu.items.map(\.title) == [AgentChipView.continueTitle])
            failedChip.askToContinue()
        }
        #expect(continued.count == 2)
    }

    // MARK: - Approval

    @Test("The approval card shows every agent option verbatim in order, wraps when narrow, and never auto-focuses", arguments: widths)
    func approvalCard(width: CGFloat) throws {
        let secret = "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
        let raw = "git push https://x-access-token:\(secret)@github.com/acme/app.git main\u{202E}"
        let shown = ApprovalCardView.escapedForReview(raw)
        #expect(shown.hasSuffix("main\\u{202E}"), "Bidi and control characters are shown, never applied")
        let approval = Gallery.approval(options: [
            .init(id: "allow", name: "Allow", kind: .allowOnce),
            .init(id: "always", name: "Always allow for this session", kind: .allowAlways),
            .init(id: "reject", name: "Reject", kind: .rejectOnce),
        ])
        let verb = AgentToolVerb(glyph: .shell, live: "Running git push", settled: "Ran git push", detail: nil, exactInput: raw)
        for dark in [false, true] {
            var chosen: [String] = []
            var cancelled = 0
            let window = Gallery.window(width: width, height: 400)
            defer { window.close() }
            let host = Gallery.host(dark: dark)
            window.contentView = host
            let card = ApprovalCardView()
            host.addSubview(card)
            card.configure(approval: approval, verb: verb, moreCount: 2, onChoose: { chosen.append($0) },
                           onCancelRequest: { cancelled += 1 }, unredactedInput: raw)
            let height = ApprovalCardView.height(approval: approval, verb: verb, width: width, unredactedInput: raw)
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            card.frame = host.bounds
            layout(host)
            try expectFits(card, height: height, "approval \(width)")
            let titles = card.optionButtons.map(\.title) + [card.cancelButton.title]
            #expect(titles == ["Allow", "Always allow for this session", "Reject", "Cancel Request"])
            #expect(card.content?.defaultOptionID == "allow")
            #expect(card.optionButtons[1].bezelColor == nil, "allow_always is never primary")
            #expect(card.optionButtons.allSatisfy { $0.keyEquivalent.isEmpty })
            #expect(card.headerLabel.stringValue.hasSuffix("· 2 more"))
            let frames = ApprovalCardView.frames(content: try #require(card.content), width: width)
            #expect(frames.buttonsVertical == (width < 500))
            #expect(card.inputText.string == redactOutput(shown, maximumLines: nil).text)
            let responder = window.firstResponder as? NSView
            #expect(responder.map { $0 === card || $0.isDescendant(of: card) } != true, "The card must never take focus by itself")
            try capture(host, name: "approval-\(Int(width))-\(dark ? "dark" : "light")")
            #expect(window.makeFirstResponder(card))
            var next = approval
            next.requestID = .number(8)
            card.configure(approval: next, verb: verb, moreCount: 1, onChoose: { chosen.append($0) },
                           onCancelRequest: { cancelled += 1 }, unredactedInput: raw)
            card.keyDown(with: try returnKey())
            #expect(chosen.isEmpty, "Return never answers a request that arrived while the card had focus")
            #expect(window.makeFirstResponder(nil) && window.makeFirstResponder(card))
            card.keyDown(with: try returnKey())
            #expect(chosen == ["allow"])
            card.cancelButton.performClick(nil)
            #expect(cancelled == 1)
            if card.content?.revealedInput != nil {
                card.toggleReveal()
                #expect(card.inputText.string == shown)
                #expect(!card.inputText.isSelectable, "Revealed secrets are not copyable from the card")
                card.toggleReveal()
            }
        }
    }

    @Test("Return never chooses allow_always, an exit-plan option, or any option of a switch_mode request")
    func approvalNeverDefaultsToPersistentOrModeOptions() throws {
        let verb = AgentToolVerb(glyph: .plan, live: "Exiting plan mode", settled: "Exited plan mode", detail: nil, exactInput: nil)
        for first in [ACPPermissionRequest.Option(id: "always", name: "Always", kind: .allowAlways),
                      ACPPermissionRequest.Option(id: "exit-plan-auto", name: "Yes, and auto-accept", kind: .allowOnce)] {
            var chosen: [String] = []
            let card = ApprovalCardView()
            let approval = Gallery.approval(options: [first, .init(id: "no", name: "No", kind: .rejectOnce)])
            card.configure(approval: approval, verb: verb, moreCount: 0, onChoose: { chosen.append($0) }, onCancelRequest: {})
            card.keyDown(with: try returnKey())
            #expect(chosen.isEmpty)
            #expect(card.content?.defaultOptionID == nil)
        }
        var modeChange = Gallery.approval(options: [.init(id: "default", name: "Yes", kind: .allowOnce)])
        modeChange.kind = .switchMode
        #expect(ApprovalCardView.content(approval: modeChange, verb: verb, moreCount: 0, unredactedInput: nil).defaultOptionID == nil)
    }

    // MARK: - Narrative

    @Test("Prose renders bordered code blocks with language labels, colored diffs, and only safe links", arguments: widths)
    func proseBlocksAndLinks(width: CGFloat) throws {
        let message = """
        I mapped the transport layer. See [the docs](https://docs.example.com/rpc), \
        [local](file:///etc/passwd) and [script](javascript:alert(1)).

        ```swift
        let fallback = transport.secondary
        ```

        ```diff
        -retry(primary)
        +retry(secondary)
        ```
        """
        let item = AgentChatItem(id: "prose", content: .assistant(message), revision: 1)
        var copied: [String] = []
        var actions = AgentChatRowActions()
        actions.copyText = { copied.append($0) }
        for dark in [false, true] {
            let cell = ProseCellView()
            cell.configure(item: item, isStreaming: false, followStreamingOutput: false, actions: actions)
            let host = try mount(cell, height: ProseCellView.height(item: item, width: width), width: width, dark: dark)
            let storage = try #require(cell.textView.textStorage)
            var links: [URL] = []
            storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                if let url = value as? URL { links.append(url) }
            }
            #expect(links.map(\.absoluteString) == ["https://docs.example.com/rpc"])
            let text = storage.string as NSString
            #expect(text.range(of: "swift\n").location != NSNotFound, "The fence language is kept as the block label")
            let added = text.range(of: "+retry(secondary)")
            let color = try #require(storage.attribute(.foregroundColor, at: added.location, effectiveRange: nil) as? NSColor)
            #expect(hex(color, dark: dark) == (dark ? AgentChatPalette.Token.success.dark : AgentChatPalette.Token.success.light))
            #expect(cell.textView.blockRects().count == 2)
            #expect(cell.copyButton.isHidden, "Copy is hover-only")
            cell.setHover(true, block: 0)
            #expect(!cell.copyButton.isHidden)
            try capture(host, name: "prose-\(Int(width))-\(dark ? "dark" : "light")")
            cell.copyButton.performClick(nil)
            #expect(copied.last == redactOutput(message, maximumLines: nil).text)
            let blockCopy = try #require(descendants(of: cell.textView).compactMap { $0 as? AgentChatClosureButton }.first { !$0.isHidden })
            blockCopy.performClick(nil)
            #expect(copied.last == "let fallback = transport.secondary")
        }
    }

    @Test("Streaming prose can restyle earlier Markdown and preserves the reader's selection")
    func proseStreamingRestylesPrefix() throws {
        let cell = ProseCellView()
        cell.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        var revision = 0
        func stream(_ message: String) {
            revision += 1
            cell.configure(item: AgentChatItem(id: "stream", content: .assistant(message), revision: revision),
                           isStreaming: true, followStreamingOutput: false, actions: AgentChatRowActions())
            cell.layoutSubtreeIfNeeded()
        }
        stream("A **bold")
        cell.textView.setSelectedRange(NSRange(location: 0, length: 1))
        stream("A **bold** answer")
        #expect(cell.textView.string == "A bold answer")
        #expect(cell.textView.selectedRange() == NSRange(location: 0, length: 1))
        let bold = (cell.textView.string as NSString).range(of: "bold")
        let font = try #require(cell.textView.textStorage?.attribute(.font, at: bold.location, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        stream("A **bold** answer with more text.")
        #expect(cell.textView.string == "A bold answer with more text.")
        #expect(cell.textView.selectedRange() == NSRange(location: 0, length: 1))
    }

    @Test("Long streamed prose follows the end only while the reader follows")
    func proseLongStreamFollows() throws {
        let window = Gallery.window(width: 800, height: 600)
        defer { window.close() }
        let cell = ProseCellView()
        cell.frame = NSRect(x: 0, y: 0, width: 752, height: 1_208)
        window.contentView?.addSubview(cell)
        var message = (0..<150).map { "Line \($0)" }.joined(separator: "\n\n")
        var revision = 0
        func stream(follow: Bool) {
            revision += 1
            cell.configure(item: AgentChatItem(id: "stream", content: .assistant(message), revision: revision),
                           isStreaming: true, followStreamingOutput: follow, actions: AgentChatRowActions())
            cell.layoutSubtreeIfNeeded()
        }
        stream(follow: true)
        let scroll = cell.textScroll
        #expect(cell.textView.bounds.height > 1_200)
        #expect(abs(scroll.contentView.bounds.maxY - cell.textView.bounds.maxY) <= ProseCellView.textInset + 1)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        let selection = NSRange(location: 2, length: 5)
        cell.textView.setSelectedRange(selection)
        message += "\n\nBackground stream while reading earlier text"
        stream(follow: true)
        #expect(scroll.contentView.bounds.origin.y == 0)
        #expect(cell.textView.selectedRange() == selection)
        #expect(ProseCellView.height(item: AgentChatItem(id: "stream", content: .assistant(message), revision: revision), width: 752)
            == ProseCellView.maximumTextHeight + ProseCellView.verticalInset * 2)
    }

    @Test("User bubbles are right-aligned, at most 75% wide, and carry no copy affordance", arguments: widths)
    func userBubble(width: CGFloat) throws {
        let item = AgentChatItem(id: "user", content: .user(
            "Fix the HyperEVM fallback ordering so the secondary RPC is tried before giving up, and add a regression test."))
        for dark in [false, true] {
            let cell = UserBubbleCellView()
            cell.configure(item: item, actions: AgentChatRowActions())
            let host = try mount(cell, height: UserBubbleCellView.height(item: item, width: width), width: width, dark: dark)
            #expect(abs(cell.bubble.frame.maxX - (width - UserBubbleCellView.sideInset)) < 0.5)
            #expect(cell.bubble.frame.width <= (width - 16) * 0.75 + 0.5)
            #expect(descendants(of: cell).compactMap { $0 as? NSButton }.isEmpty)
            #expect(cell.messageLabel.isSelectable)
            try capture(host, name: "user-\(Int(width))-\(dark ? "dark" : "light")")
        }
    }

    @Test("Notices offer Send again only for failed turns; plan rows summarize progress and open the Inspector")
    func noticesAndPlans() throws {
        var sent = 0
        var opened: [AgentInspectorSubject] = []
        var actions = AgentChatRowActions()
        actions.sendAgain = { sent += 1 }
        actions.openInspector = { subject, _ in opened.append(subject) }
        let notice = AgentChatItem(id: "notice", content: .notice("The turn failed: connection reset by the agent process."))
        let cell = NoticeCellView()
        cell.configure(item: notice, offersSendAgain: true, actions: actions)
        try mount(cell, height: NoticeCellView.height(item: notice, width: 360, offersSendAgain: true), width: 360, dark: false)
        cell.sendAgainButton.performClick(nil)
        #expect(sent == 1)
        cell.configure(item: notice, offersSendAgain: false, actions: actions)
        #expect(cell.sendAgainButton.isHidden)

        let plan = AgentChatItem(id: "plan-root", content: .plan([
            .init(content: "Map transport", status: "completed"), .init(content: "Fix fallback", status: "in_progress"),
            .init(content: "Add test", status: "pending"),
        ]))
        let row = PlanRowView()
        row.configure(item: plan, actions: actions)
        #expect(row.label.stringValue == "Plan · 1/3 done · Fix fallback")
        #expect(row.accessibilityPerformPress())
        #expect(opened == [.plan(key: plan.key)])
    }
}

// MARK: - Harness (shared with the Inspector gallery suite)

@MainActor private func renderCard(_ group: AgentActivityGroup, expandedOverride: Bool? = nil, showAll: Bool = false,
                        verbs: [String: AgentToolVerb], rosterOverrides: [String: Bool] = [:], width: CGFloat, dark: Bool,
                        actions: AgentChatRowActions = AgentChatRowActions()) throws -> (ActivityCardView, NSView) {
    let card = ActivityCardView()
    let host = Gallery.host(dark: dark)
    host.addSubview(card)
    try place(card, in: host, group: group, expandedOverride: expandedOverride, showAll: showAll, verbs: verbs,
              rosterOverrides: rosterOverrides, width: width, actions: actions)
    return (card, host)
}

@MainActor private func place(_ card: ActivityCardView, in host: NSView, group: AgentActivityGroup, expandedOverride: Bool? = nil,
                   showAll: Bool = false, verbs: [String: AgentToolVerb], rosterOverrides: [String: Bool] = [:],
                   width: CGFloat, actions: AgentChatRowActions) throws {
    card.configure(group: group, expandedOverride: expandedOverride, showAll: showAll, now: Gallery.at(90), actions: actions,
                   verbs: verbs, rosterOverrides: rosterOverrides)
    let height = ActivityCardView.height(group: group, expandedOverride: expandedOverride, showAll: showAll, width: width,
                                         verbs: verbs, rosterOverrides: rosterOverrides)
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    card.frame = host.bounds
    layout(host)
    try expectFits(card, height: height, "\(group.id) \(group.state) \(width)")
}

/// Hosts `view` at `width` × its static `height` on the thread surface and checks it fits.
@MainActor @discardableResult private func mount(_ view: NSView, height: CGFloat, width: CGFloat, dark: Bool) throws -> NSView {
    let host = Gallery.host(dark: dark)
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    view.frame = host.bounds
    host.addSubview(view)
    layout(host)
    try expectFits(view, height: height, "\(type(of: view)) at \(width)")
    return host
}

@MainActor private func layout(_ view: NSView) {
    view.needsLayout = true
    for child in view.subviews { layout(child) }
    view.layoutSubtreeIfNeeded()
}

/// No clipping: the static height is the view's height, every visible
/// piece lies inside it with room for its text, and no blank tail remains.
@MainActor private func expectFits(_ root: NSView, height: CGFloat, _ context: String) throws {
    #expect(abs(root.bounds.height - height) < 0.5, "\(context)")
    var bottom: CGFloat = 0
    for view in descendants(of: root, stopAtScrollViews: true) where view !== root && isVisible(view, within: root) {
        let frame = root.convert(view.bounds, from: view)
        guard frame.width > 0.5, frame.height > 0.5 else { continue }
        #expect(root.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                "\(context): \(type(of: view)) \(frame) escapes \(root.bounds)")
        if let field = view as? NSTextField, !field.stringValue.isEmpty, let cell = field.cell {
            let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: field.bounds.width, height: .greatestFiniteMagnitude)).height
            #expect(field.bounds.height + 0.5 >= needed, "\(context): '\(field.stringValue.prefix(40))' clipped")
        }
        if view is AgentChatSurfaceView { continue }
        bottom = max(bottom, frame.maxY)
    }
    #expect(height - bottom <= 16, "\(context): \(height - bottom) pt of blank space below the content")
}

@MainActor private func visibleSteps(in card: ActivityCardView) -> [ActivityStepView] {
    descendants(of: card).compactMap { $0 as? ActivityStepView }
        .filter { isVisible($0, within: card) }
        .sorted { card.convert($0.bounds, from: $0).minY < card.convert($1.bounds, from: $1).minY }
}

@MainActor private func isVisible(_ view: NSView, within root: NSView? = nil) -> Bool {
    var current: NSView? = view
    while let node = current {
        if node.isHidden || node.alphaValue < 0.01 { return false }
        if node === root { return true }
        current = node.superview
    }
    return true
}

@MainActor private func descendants(of view: NSView, stopAtScrollViews: Bool = false) -> [NSView] {
    if stopAtScrollViews, view is NSScrollView { return [view] }
    return [view] + view.subviews.flatMap { descendants(of: $0, stopAtScrollViews: stopAtScrollViews) }
}

/// The sRGB hex a dynamic color resolves to in light or dark.
@MainActor private func hex(_ color: NSColor, dark: Bool) -> UInt32? {
    var resolved: NSColor?
    NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
        resolved = color.usingColorSpace(.sRGB)
    }
    guard let resolved else { return nil }
    func byte(_ value: CGFloat) -> UInt32 { UInt32((value * 255).rounded()) }
    return byte(resolved.redComponent) << 16 | byte(resolved.greenComponent) << 8 | byte(resolved.blueComponent)
}

@MainActor private func returnKey() throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                  context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
                                  keyCode: 36))
}

@MainActor private func render(_ image: NSImage) -> Data? {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 28, pixelsHigh: 28, bitsPerSample: 8, samplesPerPixel: 4,
                                  hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    guard let bitmap, let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    image.draw(in: NSRect(x: 0, y: 0, width: 28, height: 28))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
}

@MainActor private func snapshotData(_ view: NSView) -> Data? {
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return bitmap.representation(using: .png, properties: [:])
}

@MainActor private func capture(_ view: NSView, name: String) throws {
    guard let destination = ProcessInfo.processInfo.environment["MADE_TOOL_REVIEW_OUTPUT"] else { return }
    let output = URL(fileURLWithPath: destination).appendingPathComponent("agent-chat-gallery")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
}

/// Fixed-clock fixtures modeled on the showcase scenario (HyperEVM transport fix).
@MainActor
private enum Gallery {
    static let origin = Date(timeIntervalSince1970: 1_800_000_000)

    static func at(_ seconds: TimeInterval) -> Date { origin.addingTimeInterval(seconds) }

    static func window(width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    static func host(dark: Bool) -> NSView {
        let host = AgentChatSurfaceView(fill: .thread, cornerRadius: 0)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        return host
    }

    static func tool(
        _ id: String, title: String, kind: ACPToolKind, status: ACPToolStatus, outcome: AgentChatItem.ToolCall.Outcome?,
        start: TimeInterval, end: TimeInterval?, error: String? = nil
    ) -> AgentChatItem {
        var tool = AgentChatItem.ToolCall(title: title, kind: kind, status: status, content: "")
        tool.toolCallID = id
        tool.errorSummary = error
        tool.startedAt = at(start)
        tool.endedAt = end.map(at)
        tool.outcome = outcome
        return AgentChatItem(id: "tool-\(id)", content: .tool(tool), revision: 2)
    }

    private static func verb(_ glyph: AgentToolVerb.Glyph, _ live: String, _ settled: String, _ exact: String,
                             detail: String? = nil) -> AgentToolVerb {
        AgentToolVerb(glyph: glyph, live: live, settled: settled, detail: detail, exactInput: exact)
    }

    private static let script: [(title: String, kind: ACPToolKind, verb: AgentToolVerb)] = [
        ("git status", .execute, verb(.shell, "Running git status", "Ran git status", "git status --short")),
        ("Read transport.ts", .read, verb(.read, "Reading transport.ts", "Read transport.ts", "/repo/src/transport.ts", detail: "src/transport.ts")),
        ("Read 3 files", .read, verb(.read, "Reading 3 files", "Read 3 files", "/repo/src/chain.ts /repo/src/rpc.ts", detail: "chain.ts, rpc.ts +1")),
        ("grep chain|protocol", .search, verb(.search, "Searching \"chain|protocol\"", "Searched \"chain|protocol\" in hyperevm",
                                              "rg -n 'chain|protocol' /repo/hyperevm")),
        ("bun test transport", .execute, verb(.shell, "Running bun test transport", "Ran bun test transport", "bun test transport")),
        ("Read fallback.ts", .read, verb(.read, "Reading fallback.ts", "Read fallback.ts", "/repo/src/fallback.ts")),
        ("Edit transport.ts", .edit, verb(.edit, "Editing transport.ts", "Edited transport.ts (+42 −7)", "/repo/src/transport.ts")),
        ("Fetch rpc docs", .fetch, verb(.fetch, "Fetching docs.hyperliquid.xyz", "Fetched docs.hyperliquid.xyz/rpc", "https://docs.hyperliquid.xyz/hyperevm/rpc")),
        ("bun test transport", .execute, verb(.shell, "Running bun test transport", "Ran bun test transport", "bun test transport")),
    ]

    /// `count` steps ten seconds apart; `failing` indexes fail; the last runs when `runningLast`.
    static func steps(count: Int, failing: Set<Int>, runningLast: Bool) -> (items: [AgentChatItem], verbs: [String: AgentToolVerb]) {
        var items: [AgentChatItem] = []
        var verbs: [String: AgentToolVerb] = [:]
        for index in 0..<count {
            let entry = script[index % script.count]
            let running = runningLast && index == count - 1
            let failed = failing.contains(index)
            let item = tool(
                "t\(index + 1)", title: entry.title, kind: entry.kind,
                status: running ? .inProgress : failed ? .failed : .completed,
                outcome: running ? nil : failed ? .failed : .completed,
                start: TimeInterval(index * 10), end: running ? nil : TimeInterval(index * 10 + 8),
                error: failed ? "2 tests failed: transport › falls back to secondary RPC" : nil
            )
            items.append(item)
            verbs[item.key] = entry.verb
        }
        return (items, verbs)
    }

    static func group(
        _ items: [AgentChatItem], extra: [AgentActivityMember] = [], state: AgentActivityState, liveStatus: String? = nil
    ) -> AgentActivityGroup {
        let members = items.map { item -> AgentActivityMember in
            if case .thought = item.content { return .thought(item) }
            return .step(item)
        } + extra
        let tools = items.compactMap { item -> AgentChatItem.ToolCall? in
            if case .tool(let tool) = item.content { return tool }
            return nil
        }
        let live = state == .live || state == .idle
        return AgentActivityGroup(
            id: "activity-\(members.first?.id ?? "empty")", revision: items.map(\.revision).max() ?? 0, members: members,
            state: state, startedAt: origin, endedAt: live ? nil : at(95), stepCount: tools.count,
            failedCount: tools.filter { AgentStatusDotView.Status($0) == .failed }.count,
            stoppedCount: tools.filter { AgentStatusDotView.Status($0) == .stopped }.count,
            liveStatus: live ? liveStatus : nil, summary: extra.isEmpty ? "Explored hyperevm" : "Coordinated agents"
        )
    }

    static func roster(live: Bool) -> [AgentRosterEntry] {
        let names = ["Research ethereum", "Audit transport", "Map RPC providers", "Review fallback tests", "Profile retries",
                     "Check chain IDs", "Scan configs", "Trace websocket reconnects", "Compare viem clients", "Draft changelog",
                     "Measure latency", "Verify signatures"]
        return names.enumerated().map { index, name in
            let lifecycle: AgentChatItem.Subagent.Lifecycle = if live {
                index < 4 ? .done : index == 11 ? .queued : index == 5 ? .failed : .running
            } else {
                index == 5 || index == 9 ? .failed : .done
            }
            return AgentRosterEntry(id: "child-\(index)", name: name, lifecycle: lifecycle, steps: 3 + index * 2,
                                    failed: lifecycle == .failed ? 1 : 0, startedAt: at(TimeInterval(index)),
                                    endedAt: lifecycle == .running || lifecycle == .queued ? nil : at(TimeInterval(40 + index)))
        }
    }

    static func approval(options: [ACPPermissionRequest.Option]) -> AgentChatItem.Approval {
        AgentChatItem.Approval(requestID: .number(7), sessionID: "showcase", agentName: "Claude", toolCallID: "t10",
                               title: "git push origin main", kind: .execute, subject: "git push origin main",
                               options: options, decision: .pending)
    }
}

// MARK: - Inspector gallery (WP5)
// WP5 adds "inspector with redacted output" as its own @Suite below, reusing the
// file-level harness (`mount`, `layout`, `expectFits`, `capture`, `descendants`,
// `isVisible`) and `Gallery` fixtures (fixed clock, light/dark, 360/560/900).


/// WP5: the Inspector drawer (§3.6) and run-trace export. A fake redactor
/// stands in for the §2.4 policy so masking, chips, and copy paths are
/// asserted deterministically; separate checks prove the defaults route
/// through `redactOutput`/`redactJSON`/`redactInline`.
@Suite("Agent chat inspector gallery")
@MainActor
struct AgentChatInspectorGalleryTests {
    nonisolated private static let secret = "sk-test-SECRET0123456789abcdef"
    nonisolated private static let fake = AgentInspectorRedactor(
        output: { text, limit in
            let masked = text.replacingOccurrences(of: secret, with: "••••")
            var lines = masked.components(separatedBy: "\n")
            let dropped = limit.map { max(0, lines.count - $0) } ?? 0
            if let limit { lines = Array(lines.prefix(limit)) }
            return AgentRedaction(text: lines.joined(separator: "\n"), redacted: masked != text, truncatedLines: dropped)
        },
        json: { value in
            let masked = maskJSON(value)
            return (masked, masked != value)
        },
        inline: { $0.replacingOccurrences(of: secret, with: "••••") }
    )

    nonisolated private static func maskJSON(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let text): .string(text.replacingOccurrences(of: secret, with: "••••"))
        case .array(let values): .array(values.map(maskJSON))
        case .object(let object): .object(object.mapValues(maskJSON))
        case .null, .bool, .number: value
        }
    }

    private final class Recorder {
        var copies: [(text: String, concealed: Bool)] = []
        var suggestedNames: [String] = []
        var saved: [(data: Data, url: URL)] = []
        var answer: URL?
    }

    private func makeInspector(allowsReasoning: Bool = false) -> (AgentInspectorViewController, Recorder) {
        let recorder = Recorder()
        let inspector = AgentInspectorViewController(allowsReasoningExport: { allowsReasoning })
        inspector.redactor = Self.fake
        inspector.now = { Date(timeIntervalSince1970: 1_800_000_060) }
        inspector.writePasteboard = { recorder.copies.append(($0, $1)) }
        inspector.chooseSaveURL = { name, completion in
            recorder.suggestedNames.append(name)
            completion(recorder.answer)
        }
        inspector.writeFile = { recorder.saved.append(($0, $1)) }
        inspector.loadViewIfNeeded()
        inspector.view.frame = NSRect(x: 0, y: 0, width: 360, height: 600)
        return (inspector, recorder)
    }

    private func toolItem(id: String = "tool-1", title: String = "Run tests", status: ACPToolStatus = .completed) -> AgentChatItem {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let tool = AgentChatItem.ToolCall(
            title: title, kind: .execute, status: status, content: "", toolName: "Bash",
            startedAt: start, endedAt: start.addingTimeInterval(42), outcome: status == .failed ? .failed : .completed
        )
        return AgentChatItem(id: id, content: .tool(tool))
    }

    private func stepContent(output: String, input: JSONValue? = ["command": .string("deploy --token \(secret)")], evicted: Bool = false) -> AgentInspectorContent {
        let item = toolItem()
        var detail = AgentStepDetail(rawInput: input.map(ACPBoundedJSON.init), rawOutput: ACPBoundedJSON(.string(output)))
        detail.evicted = evicted
        return AgentInspectorContent(subject: .step(key: item.key), title: "Run tests", agentName: "Claude", item: item, detail: detail)
    }

    private func thoughtContent(_ text: String = "Checking the transport fallback with \(secret)") -> AgentInspectorContent {
        let item = AgentChatItem(id: "local-7", content: .thought(.init(text: text)))
        return AgentInspectorContent(subject: .thought(key: item.key), title: "Thought", agentName: "Claude", item: item)
    }

    private func chipIDs(_ inspector: AgentInspectorViewController) -> [String] {
        inspector.chips.compactMap { $0.accessibilityIdentifier().split(separator: ".").last.map(String.init) }
    }

    @Test("Redacted output masks secrets, shows the chip, and copies safely")
    func redactedOutput() throws {
        let (inspector, recorder) = makeInspector()
        inspector.present(stepContent(output: "Deploying\nAPI_KEY=\(Self.secret)\nDone"), tab: nil)
        #expect(inspector.selectedTab == .output)
        #expect(!inspector.textView.string.contains(Self.secret))
        #expect(inspector.textView.string.contains("API_KEY=••••"))
        #expect(chipIDs(inspector).contains("redacted"))
        inspector.perform(.copyOutput)
        inspector.perform(.copyInput)
        inspector.perform(.copyUnredacted)
        try #require(recorder.copies.count == 3)
        #expect(recorder.copies[0].concealed == false && !recorder.copies[0].text.contains(Self.secret))
        #expect(recorder.copies[1].concealed == false && !recorder.copies[1].text.contains(Self.secret))
        #expect(recorder.copies[2].concealed && recorder.copies[2].text.contains(Self.secret))
        inspector.select(.input)
        #expect(inspector.textView.string.contains("--token ••••"))
        #expect(chipIDs(inspector).contains("redacted"))

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        AgentInspectorViewController.write("plain", concealed: false, to: pasteboard)
        #expect(pasteboard.types?.contains(AgentInspectorViewController.concealedType) == false)
        AgentInspectorViewController.write(Self.secret, concealed: true, to: pasteboard)
        #expect(pasteboard.types?.contains(AgentInspectorViewController.concealedType) == true)
        #expect(AgentInspectorViewController.concealedType.rawValue == "org.nspasteboard.ConcealedType")
        #expect(pasteboard.string(forType: .string) == Self.secret)
    }

    @Test("Default redaction routes every Inspector sink through the policy functions")
    func defaultRedactorRouting() {
        let inspector = AgentInspectorViewController(allowsReasoningExport: { false })
        let raw = "line\nAuthorization: Bearer \(Self.secret)"
        inspector.present(stepContent(output: raw), tab: .output)
        #expect(inspector.textView.string == redactOutput(raw, maximumLines: 200).text)
        #expect(inspector.titleLabel.stringValue == redactInline("Run tests"))
        inspector.select(.input)
        let input: JSONValue = ["command": .string("deploy --token \(Self.secret)")]
        let expected = redactOutput(AgentRunTrace.prettyText(redactJSON(input).value), maximumLines: 200).text
        #expect(inspector.textView.string == expected)
    }

    @Test("Long output truncates at 200 lines and show all re-redacts the full text")
    func truncatedOutputShowAll() throws {
        let (inspector, recorder) = makeInspector()
        let lines = (1...300).map { $0 == 250 ? "TOKEN=\(Self.secret)" : "line \($0)" }
        inspector.present(stepContent(output: lines.joined(separator: "\n")), tab: .output)
        #expect(inspector.page?.truncatedLines == 100)
        #expect(inspector.textView.string.components(separatedBy: "\n").count == 200)
        let chip = try #require(inspector.chips.first { $0.accessibilityIdentifier().hasSuffix(".truncated") })
        #expect(chip.title == "truncated · show all")
        chip.performClick(nil)
        #expect(inspector.showsAll)
        #expect(inspector.textView.string.components(separatedBy: "\n").count == 300)
        #expect(!inspector.textView.string.contains(Self.secret))
        #expect(chipIDs(inspector).contains("redacted"))
        #expect(!chipIDs(inspector).contains("truncated"))
        inspector.perform(.copyOutput)
        #expect(recorder.copies.last?.text.components(separatedBy: "\n").count == 300)
        // A new subject starts truncated again.
        inspector.present(thoughtContent(), tab: nil)
        #expect(!inspector.showsAll)
    }

    @Test("Each subject offers its tabs, chips, and meta")
    func tabsPerSubject() {
        let (inspector, _) = makeInspector()
        inspector.present(stepContent(output: "ok"), tab: .reasoning)
        #expect(inspector.tabs == [.input, .output, .meta])
        #expect(inspector.selectedTab == .output, "an unavailable tab falls back to the default")
        #expect(!inspector.tabControl.isHidden)
        var noInput = stepContent(output: "ok", input: nil)
        noInput.detail?.rawInput = nil
        inspector.present(noInput, tab: .input)
        #expect(chipIDs(inspector) == ["no-input"])
        #expect(inspector.chips.first?.title == "No input reported by Claude")
        inspector.present(stepContent(output: "ok", evicted: true), tab: .output)
        #expect(chipIDs(inspector).contains("evicted"))

        inspector.present(thoughtContent(), tab: nil)
        #expect(inspector.tabs == [.reasoning, .meta])
        #expect(inspector.selectedTab == .reasoning)

        let thought = AgentChatItem(id: "local-9", content: .thought(.init(text: "Plan the fix")), sessionKey: "child-1")
        let group = AgentActivityGroup(id: "activity-child-1/tool-1", members: [.step(toolItem()), .thought(thought)], stepCount: 1)
        let card = AgentChatItem(id: "subagent-child-1", content: .subagent(.init(childSessionID: "child-1", title: "Research", detail: nil, state: "idle", error: nil)))
        let agent = AgentInspectorContent(subject: .agent(childSessionID: "child-1"), title: "Research", agentName: "Claude",
                                          item: card, group: group, finalProse: "Found the fallback.")
        inspector.present(agent, tab: nil)
        #expect(inspector.tabs == [.output, .reasoning, .meta])
        #expect(!inspector.nestedCard.isHidden)
        #expect(inspector.textView.string == "Found the fallback.")
        inspector.select(.meta)
        #expect(inspector.nestedCard.isHidden)
        #expect(inspector.textView.string.contains("Steps: 1"))

        inspector.present(AgentInspectorContent(subject: .group(id: group.id), title: "Explored repo", agentName: "Claude", group: group), tab: nil)
        #expect(inspector.tabs == [.meta])
        #expect(inspector.tabControl.isHidden)
        #expect(inspector.textView.string.contains("Failed: 0"))
        #expect(inspector.textView.string.contains("\nSteps\n"))

        let plan = AgentChatItem(id: "plan-root", content: .plan([.init(content: "Read code", status: "completed"), .init(content: "Fix", status: "pending")]))
        inspector.present(AgentInspectorContent(subject: .plan(key: plan.key), title: "Plan", agentName: "Claude", item: plan), tab: nil)
        #expect(inspector.tabs == [.output, .meta])
        #expect(inspector.textView.string == "[x] Read code\n[ ] Fix")

        let usage = NormalizedTurnUsage(uncachedInputTokens: 1_000, cacheReadTokens: 97_000, cacheWriteTokens: 2_000, outputTokens: 500)
        let context = ACPContextUsage(usedTokens: 58_100, windowTokens: 258_400, costAmount: nil, costCurrency: nil)
        inspector.present(AgentInspectorContent(subject: .run, title: "Run", agentName: "Claude", model: "opus",
                                                turnUsage: usage, context: context), tab: nil)
        #expect(inspector.tabs == [.meta])
        #expect(inspector.textView.string.contains("Context: 58.1k / 258.4k · Cache 97%"))
        #expect(inspector.textView.string.contains("Last turn (reported by Claude)"))
        #expect(inspector.textView.string.contains("Model: opus"))
        #expect(inspector.availableActions == [.exportRunTrace])
    }

    @Test("Reasoning is selectable and exportable only when allowed")
    func reasoningGating() async throws {
        let (blocked, blockedRecorder) = makeInspector(allowsReasoning: false)
        blocked.present(thoughtContent(), tab: nil)
        #expect(!blocked.textView.isSelectable)
        #expect(!blocked.textView.string.contains(Self.secret))
        #expect(!blocked.availableActions.contains(.exportReasoning))
        #expect(!blocked.availableActions.contains(.copyUnredacted))
        blocked.perform(.exportReasoning)
        #expect(blockedRecorder.suggestedNames.isEmpty)
        blockedRecorder.answer = FileManager.default.temporaryDirectory.appendingPathComponent("step.json")
        blocked.perform(.exportStepJSON)
        await waitUntil { !blockedRecorder.saved.isEmpty }
        let blockedStep = try JSONValue.parse(try #require(blockedRecorder.saved.first?.data))
        #expect(blockedStep["step"]?["reasoningExcluded"] == true)
        #expect(blockedStep["step"]?["text"] == nil)

        let (allowed, recorder) = makeInspector(allowsReasoning: true)
        allowed.present(thoughtContent(), tab: nil)
        #expect(allowed.textView.isSelectable)
        #expect(allowed.availableActions.contains(.exportReasoning))
        recorder.answer = FileManager.default.temporaryDirectory.appendingPathComponent("reasoning.txt")
        allowed.perform(.exportReasoning)
        await waitUntil { !recorder.saved.isEmpty }
        #expect(recorder.suggestedNames.last == "Thought reasoning.txt")
        let text = try #require(recorder.saved.last.flatMap { String(data: $0.data, encoding: .utf8) })
        #expect(text.contains("transport fallback") && !text.contains(Self.secret))
        // Step output stays selectable regardless of the reasoning flag.
        blocked.present(stepContent(output: "ok"), tab: .output)
        #expect(blocked.textView.isSelectable)
    }

    @Test("The run trace is versioned, redacted, and excludes reasoning by default")
    func runTraceSchema() throws {
        var transcript = AgentTranscript()
        transcript.appendUser("Deploy with \(Self.secret)")
        transcript.apply(.init(sessionID: "root", update: .agentThought(text: "Secret is \(Self.secret)", messageID: nil)), rootSessionID: "root")
        transcript.apply(.init(sessionID: "root", update: .toolCall(.init(toolCallID: "t1", title: "Run \(Self.secret)", kind: .execute,
                                                                         status: .completed, content: "out \(Self.secret)"))), rootSessionID: "root")
        let trace = AgentRunTrace.json(transcript: transcript, agentName: "Claude", includeReasoning: false, redactor: Self.fake)
        #expect(trace["schema"] == "cockpit.agent-chat.trace/1")
        #expect(trace["redacted"] == true)
        #expect(trace["reasoningIncluded"] == false)
        let items = try #require(trace["items"]?.arrayValue)
        #expect(items.compactMap { $0["type"]?.stringValue } == ["user", "thought", "step"])
        #expect(items[1]["reasoningExcluded"] == true && items[1]["text"] == nil)
        let text = try #require(String(data: AgentRunTrace.prettyData(trace), encoding: .utf8))
        #expect(!text.contains(Self.secret))
        #expect(text.contains("\"schema\" : \"cockpit.agent-chat.trace/1\""))
        #expect(try JSONValue.parse(AgentRunTrace.prettyData(trace)) == trace)

        let withReasoning = AgentRunTrace.json(transcript: transcript, agentName: "Claude", includeReasoning: true, redactor: Self.fake)
        #expect(withReasoning["reasoningIncluded"] == true)
        #expect(withReasoning["items"]?.arrayValue?[1]["text"] == "Secret is ••••")

        let step = AgentRunTrace.stepJSON(item: transcript.items[2], detail: AgentStepDetail(rawOutput: ACPBoundedJSON(.string("x"))))
        #expect(step["schema"] == "cockpit.agent-chat.trace/1" && step["redacted"] == true)
        #expect(step["step"]?["output"] == redactJSON(.string("x")).value)
        // The frozen entry point uses the production policy.
        let production = AgentRunTrace.json(transcript: transcript, agentName: "Claude", includeReasoning: false)
        #expect(production["items"]?.arrayValue?[0]["text"] == .string(redactOutput("Deploy with \(Self.secret)", maximumLines: nil).text))
    }

    @Test("Exports use sanitized names and write only after the user chooses")
    func exportNamesAndConsent() async throws {
        #expect(AgentInspectorFormatter.sanitizedFileName("../.env:prod/key", pathExtension: "json") == "env-prod-key.json")
        for raw in ["../.env:prod/key", ".hidden", "a\u{202E}b\nc", "   ", "x/y:z"] {
            let name = AgentInspectorFormatter.sanitizedFileName(raw, pathExtension: "json")
            #expect(!name.contains("/") && !name.contains(":") && !name.hasPrefix(".") && !name.contains("\u{202E}"))
            #expect(name.hasSuffix(".json"))
        }
        #expect(AgentInspectorFormatter.sanitizedFileName("...", pathExtension: "txt") == "agent-chat.txt")

        let (inspector, recorder) = makeInspector()
        inspector.makeRunTrace = { AgentRunTrace.json(transcript: AgentTranscript(), agentName: "Claude/Code", includeReasoning: $0) }
        var content = stepContent(output: "ok")
        content.agentName = "Claude/Code"
        inspector.present(content, tab: nil)
        recorder.answer = nil
        inspector.perform(.exportRunTrace)
        #expect(recorder.suggestedNames == ["Claude-Code run trace.json"])
        #expect(recorder.saved.isEmpty, "cancelling the panel writes nothing")
        recorder.answer = FileManager.default.temporaryDirectory.appendingPathComponent("trace.json")
        inspector.perform(.exportRunTrace)
        await waitUntil { !recorder.saved.isEmpty }
        let saved = try #require(recorder.saved.first)
        #expect(saved.url == recorder.answer)
        let trace = try JSONValue.parse(saved.data)
        #expect(trace["schema"] == "cockpit.agent-chat.trace/1" && trace["reasoningIncluded"] == false)
    }

    @Test("The drawer overlays the transcript at 360 and 900 points", arguments: [360.0, 900.0])
    func overlayWidths(argument: Double) throws {
        let width = CGFloat(argument)
        for (appearance, label) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 560))
            host.appearance = NSAppearance(named: appearance)
            host.wantsLayer = true
            host.effectiveAppearance.performAsCurrentDrawingAppearance { host.layer?.backgroundColor = AgentChatPalette.color(.thread).cgColor }
            let table = NSView(frame: host.bounds)
            host.addSubview(table)
            let (inspector, _) = makeInspector()
            var closes = 0
            inspector.onClose = { closes += 1 }
            inspector.mount(in: host)
            #expect(inspector.view.isHidden)
            let lines = (1...40).map { $0 == 3 ? "export TOKEN=\(Self.secret)" : "output line \($0)" }
            inspector.present(stepContent(output: lines.joined(separator: "\n")), tab: .output)
            host.layoutSubtreeIfNeeded()
            let expectedWidth = AgentInspectorViewController.drawerWidth(preferred: 360, hostWidth: width)
            #expect(expectedWidth == min(CGFloat(360), width * 0.85))
            #expect(!inspector.view.isHidden)
            #expect(inspector.view.frame.width == expectedWidth)
            #expect(inspector.view.frame.maxX == width)
            #expect(table.frame == host.bounds, "the overlay never reflows the transcript")
            #expect(inspector.scrim.interceptsClicks == (width < 560))
            #expect((inspector.scrim.hitTest(NSPoint(x: 10, y: 10)) != nil) == (width < 560))
            inspector.resize(to: 1_000)
            #expect(inspector.view.frame.width == min(CGFloat(520), width * 0.85))
            inspector.resize(to: 100)
            #expect(inspector.view.frame.width == 240)
            inspector.resize(to: 360)
            let scroll = try #require(inspector.view.subviews.compactMap { $0 as? NSScrollView }.first)
            #expect(scroll.frame.maxY <= inspector.view.bounds.height && scroll.frame.height > 100)
            try capture(host, name: "agent-inspector-\(Int(width))-\(label)")
            if width < 560 {
                inspector.scrim.mouseDown(with: try #require(NSEvent.mouseEvent(
                    with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
                #expect(!inspector.isPresented && closes == 1)
                #expect(inspector.view.isHidden)
            }
        }
    }

    @Test("Esc closes the drawer and Tab stays inside it")
    func escapeAndFocusTrap() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = try #require(window.contentView)
        let composer = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        host.addSubview(composer)
        window.makeFirstResponder(composer)
        try #require(window.firstResponder === composer)
        let (inspector, _) = makeInspector()
        var closes = 0
        inspector.onClose = { closes += 1 }
        inspector.mount(in: host)
        inspector.present(stepContent(output: "ok"), tab: nil)
        #expect(window.firstResponder === inspector.textView)
        for _ in 0..<4 {
            (window.firstResponder as? NSView)?.keyDown(with: try key(48, "\t"))
            #expect((window.firstResponder as? NSView)?.isDescendant(of: inspector.view) == true)
        }
        inspector.textView.keyDown(with: try key(53, "\u{1b}"))
        #expect(!inspector.isPresented && closes == 1)
        #expect(window.firstResponder === composer, "focus returns to where it was")
        inspector.present(stepContent(output: "ok"), tab: nil)
        inspector.view.cancelOperation(nil)
        #expect(!inspector.isPresented && closes == 2)
    }

    @Test("Secret files are masked whole in the Inspector, step export, and run trace")
    func secretFileMasking() async throws {
        let (inspector, recorder) = makeInspector()
        var read = stepContent(output: "PLAIN=visible\nOTHER=1", input: ["file_path": "/repo/.env"])
        if case .tool(var tool)? = read.item?.content {
            tool.locations = [ACPToolLocation(path: "/repo/.env", line: nil)]
            read.item?.content = .tool(tool)
        }
        inspector.present(read, tab: .output)
        #expect(inspector.textView.string == "••••", "the fake policy would leave PLAIN=visible; the whole file is masked")
        #expect(chipIDs(inspector).contains("redacted"))
        inspector.perform(.copyOutput)
        #expect(recorder.copies.last?.text == "••••")
        inspector.select(.input)
        #expect(inspector.textView.string.contains("/repo/.env"), "the path itself stays readable")

        var edit = stepContent(output: "ok", input: ["file_path": "/home/me/.ssh/id_rsa", "new_string": "-----KEY MATERIAL-----"])
        edit.detail?.rawOutput = nil
        inspector.present(edit, tab: .input)
        #expect(!inspector.textView.string.contains("KEY MATERIAL") && inspector.textView.string.contains("id_rsa"))
        #expect(chipIDs(inspector).contains("redacted"))
        recorder.answer = FileManager.default.temporaryDirectory.appendingPathComponent("step.json")
        inspector.perform(.exportStepJSON)
        await waitUntil { !recorder.saved.isEmpty }
        let step = try JSONValue.parse(try #require(recorder.saved.last?.data))
        #expect(step["step"]?["input"]?["new_string"] == "••••" && step["step"]?["input"]?["file_path"] == "/home/me/.ssh/id_rsa")

        // The run trace shares the step encoder, so a tool that touched .npmrc exports no file content.
        let npmrc = AgentChatItem(id: "t1", content: .tool(.init(title: "Read .npmrc", kind: .read, status: .completed, content: "//registry/:_authToken=abc",
                                                                 locations: [ACPToolLocation(path: ".npmrc", line: nil)])))
        let exported = AgentRunTrace.stepJSON(item: npmrc, detail: AgentStepDetail(terminalOutput: "abc"), includeReasoning: false, redactor: Self.fake)
        #expect(exported["step"]?["content"] == "••••" && exported["step"]?["terminalOutput"] == "••••")
        #expect(!AgentInspectorRedactor.isSecretFileName("/repo/README.md") && !AgentInspectorRedactor.isSecretFileName("environment.swift"))
        #expect(["a/.env.local", "server.PEM", "id_ed25519.pub", ".netrc", "credentials.json"].allSatisfy(AgentInspectorRedactor.isSecretFileName))
    }

    @Test("Large pages redact off the main actor, keep their text while refreshing, and drop stale results")
    func largeOutputOffMain() async throws {
        let (inspector, recorder) = makeInspector()
        let filler = String(repeating: "x", count: 100)
        let big = (0..<800).map { $0 == 5 ? "TOKEN=\(Self.secret)" : "\($0) \(filler)" }.joined(separator: "\n")
        try #require(big.utf8.count > AgentInspectorFormatter.largeTextBytes)
        inspector.present(stepContent(output: big), tab: .output)
        #expect(inspector.textView.string == "Redacting…")
        await waitUntil { inspector.page?.truncatedLines == 600 }
        #expect(!inspector.textView.string.contains(Self.secret) && inspector.textView.string.hasPrefix("0 x"))
        #expect(chipIDs(inspector).contains("redacted") && chipIDs(inspector).contains("truncated"))
        // A streaming refresh of the same page keeps the shown text until the new redaction lands.
        inspector.update(stepContent(output: big + "\nmore"))
        #expect(inspector.textView.string.hasPrefix("0 x"))
        await waitUntil { inspector.page?.truncatedLines == 601 }
        // Copy re-redacts the full text off the main actor too.
        inspector.perform(.copyOutput)
        await waitUntil { !recorder.copies.isEmpty }
        #expect(recorder.copies.last?.text.hasSuffix("more") == true && recorder.copies.last?.text.contains(Self.secret) == false)
        // A result for an older subject never replaces the current one.
        inspector.present(stepContent(output: big + "\nstale"), tab: .output)
        inspector.present(thoughtContent("Short reasoning"), tab: nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(inspector.textView.string == "Short reasoning")
    }

    @Test("Streaming output appends in place and keeps the reader's selection")
    func streamingKeepsSelection() {
        let (inspector, _) = makeInspector()
        inspector.present(stepContent(output: "first line"), tab: .output)
        inspector.textView.setSelectedRange(NSRange(location: 0, length: 5))
        inspector.update(stepContent(output: "first line\nsecond line"))
        #expect(inspector.textView.string == "first line\nsecond line")
        #expect(inspector.textView.selectedRange() == NSRange(location: 0, length: 5))
        // Another page replaces the text even when the old text is a prefix of the new one.
        inspector.present(thoughtContent("first line\nsecond line, then reasoning"), tab: nil)
        #expect(inspector.textView.selectedRange().length == 0)
    }

    @Test("Failed agents offer Ask to Continue; tokens never appear per step")
    func failedAgentAndUsageScope() {
        let (inspector, _) = makeInspector()
        var asked: [String] = []
        inspector.actions.askToContinue = { asked.append($0) }
        func agent(error: String?) -> AgentInspectorContent {
            let card = AgentChatItem(id: "subagent-child-2", content: .subagent(.init(childSessionID: "child-2", title: "Lint", detail: nil, state: "idle", error: error)))
            return AgentInspectorContent(subject: .agent(childSessionID: "child-2"), title: "Lint", agentName: "Claude", item: card)
        }
        inspector.present(agent(error: nil), tab: nil)
        #expect(!inspector.availableActions.contains(.askToContinue))
        inspector.present(agent(error: "crashed"), tab: nil)
        #expect(inspector.availableActions.contains(.askToContinue))
        inspector.perform(.askToContinue)
        #expect(asked == ["child-2"])

        var step = stepContent(output: "ok")
        step.turnUsage = NormalizedTurnUsage(uncachedInputTokens: 1, cacheReadTokens: 2, cacheWriteTokens: 3, outputTokens: 4)
        step.context = ACPContextUsage(usedTokens: 58_100, windowTokens: 258_400, costAmount: 0.42, costCurrency: "usd")
        inspector.present(step, tab: .meta)
        #expect(!inspector.textView.string.contains("reported by") && !inspector.textView.string.contains("Context"))
        #expect(AgentInspectorFormatter.contextMeter(step.context!, usage: step.turnUsage) == "58.1k / 258.4k · Cache 33% · \(0.42.formatted(.currency(code: "USD")))")
    }

    @Test("Run-trace export builds from a snapshot off the main actor and never writes an empty trace")
    func runTraceExportSource() async throws {
        let (inspector, recorder) = makeInspector(allowsReasoning: true)
        recorder.answer = FileManager.default.temporaryDirectory.appendingPathComponent("trace.json")
        inspector.present(stepContent(output: "ok"), tab: nil)
        inspector.perform(.exportRunTrace)
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.saved.isEmpty, "an unwired makeRunTrace returns null, which is never written")
        var transcript = AgentTranscript()
        transcript.apply(.init(sessionID: "root", update: .agentThought(text: "why \(Self.secret)", messageID: nil)), rootSessionID: "root")
        inspector.runTraceSource = { (transcript, "Claude") }
        inspector.perform(.exportRunTrace)
        await waitUntil { !recorder.saved.isEmpty }
        let trace = try JSONValue.parse(try #require(recorder.saved.first?.data))
        #expect(trace["schema"] == "cockpit.agent-chat.trace/1" && trace["reasoningIncluded"] == true)
        #expect(trace["items"]?.arrayValue?.first?["text"] == "why ••••")
    }

    @Test("The resize handle widens and narrows within bounds for VoiceOver")
    func resizeHandleAccessibility() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        let (inspector, _) = makeInspector()
        inspector.mount(in: host)
        inspector.present(stepContent(output: "ok"), tab: nil)
        #expect(inspector.view.frame.width == 360)
        #expect(inspector.handle.accessibilityPerformIncrement())
        #expect(inspector.view.frame.width == 384)
        for _ in 0..<20 { _ = inspector.handle.accessibilityPerformDecrement() }
        #expect(inspector.view.frame.width == AgentInspectorViewController.minimumWidth)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func key(_ code: UInt16, _ characters: String) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                      characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    private func capture(_ view: NSView, name: String) throws {
        guard let destination = ProcessInfo.processInfo.environment["MADE_TOOL_REVIEW_OUTPUT"] else { return }
        let output = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
    }
}
