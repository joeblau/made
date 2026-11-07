import AppKit
import Testing
@testable import Pilot

/// The integrated pane against scripted agents (spec §3.7–§3.9): Stop,
/// Steer / Queue, the docked approval card, the context meter's new home,
/// the step cursor, and the Inspector overlay.
@Suite("Agent chat pane integration")
@MainActor
struct AgentChatPaneTests {
    @Test("While a turn runs: Stop is visible, the send button steers or queues, and Esc / Cmd-. follow their order",
          arguments: [false, true])
    func runningTurnControls(steering: Bool) async throws {
        let harness = try Harness(steering: steering, #"""
        read -r _
        update '{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Run tests","kind":"execute","status":"in_progress","rawInput":{"command":"bun test"}}'
        while read -r r; do
          case "$r" in
            *_session/steering*) id=$(printf '%s' "$r" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p'); printf '{"jsonrpc":"2.0","id":%s,"result":{"outcome":"injected"}}\n' "$id" ;;
            *session/cancel*) printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"cancelled"}}'; break ;;
          esac
        done
        read -r _
        """#)
        defer { harness.close() }
        try await harness.sendPrompt("Run the tests")
        let controller = harness.controller
        try await harness.waitUntil { harness.session.isTurnRunning && !controller.stopButton.isHidden }
        harness.layout()
        #expect(!controller.stopButton.isHidden && controller.stopButton.isEnabled)
        #expect(controller.stopButton.accessibilityIdentifier() == "agent-chat.stop")
        let send = try #require(harness.view(AgentChatSendButton.self))
        #expect(send.mode == (steering ? .steer : .queue))
        #expect(!send.isEnabled, "An empty draft can't steer or queue")
        #expect(harness.composer.placeholder == (steering ? "Steer the current run…" : "Queue a message for after this turn…"))
        #expect(controller.composerChip.isHidden == !steering)
        if steering { #expect(controller.composerChip.label.stringValue == "Steering current run") }
        let attach = try #require(harness.identified("agent-chat.attach") as? NSButton)
        #expect(attach.isEnabled == !steering, "No attachments while steering")

        harness.type("Also check lint")
        #expect(send.isEnabled)
        harness.composer.keyDown(with: try key(36, "\r"))
        if steering {
            try await harness.waitUntil { harness.session.transcript.items.contains { $0.content == .user("Also check lint") } }
            #expect(harness.session.isTurnRunning, "A steer joins the running turn")
        } else {
            try await harness.waitUntil { harness.session.queuedPrompt == "Also check lint" }
            harness.layout()
            #expect(!controller.composerChip.isHidden)
            #expect(controller.composerChip.label.stringValue == "Queued for next turn")
            #expect(!controller.composerChip.removeButton.isHidden)
            controller.composerChip.removeButton.performClick(nil)
            #expect(harness.session.queuedPrompt == nil)
        }
        try await harness.waitUntil { harness.composer.string.isEmpty }

        // Esc with a draft does nothing; with the Inspector open it only closes the Inspector.
        harness.type("unsent")
        #expect(!controller.handleEscape(fromComposer: true))
        harness.type("")
        controller.openInspector(.run, tab: nil)
        #expect(controller.inspector.isPresented)
        #expect(controller.handleEscape(fromComposer: true))
        #expect(!controller.inspector.isPresented && harness.session.isTurnRunning)

        harness.composer.keyDown(with: try key(47, ".", flags: .command))
        try await harness.waitUntil { harness.session.phase == .ready && controller.stopButton.isHidden }
        harness.layout()
        #expect(send.mode == .send)
    }

    @Test("Approvals dock above the composer, never take focus, and become inline records once decided")
    func approvalsDockAboveTheComposer() async throws {
        let harness = try Harness(steering: false, #"""
        read -r _
        printf '%s\n' '{"jsonrpc":"2.0","id":"p1","method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"t1","title":"Push branch","kind":"execute","rawInput":{"command":"git push origin main"}},"options":[{"optionId":"allow","name":"Allow once","kind":"allow_once"},{"optionId":"always","name":"Always allow","kind":"allow_always"},{"optionId":"reject","name":"Reject","kind":"reject_once"}]}}'
        printf '%s\n' '{"jsonrpc":"2.0","id":"p2","method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"t2","title":"Delete build output","kind":"delete"},"options":[{"optionId":"allow","name":"Allow once","kind":"allow_once"}]}}'
        read -r _
        read -r _
        printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}'
        read -r _
        """#)
        defer { harness.close() }
        try await harness.sendPrompt("Ship it")
        let card = harness.controller.approvalCard
        try await harness.waitUntil { harness.session.permissionQueue.count == 2 && card.headerLabel.stringValue.hasSuffix("1 more") }
        harness.layout()
        #expect(!card.isHidden && card.accessibilityIdentifier() == "agent-chat.approval")
        #expect(card.headerLabel.stringValue.hasSuffix("1 more"))
        #expect(card.titleLabel.stringValue == "Push branch")
        #expect(harness.window.firstResponder !== card, "Approval cards never take focus by themselves")
        let composerCard = try #require(harness.identified("agent-chat.composer-card"))
        let root = harness.controller.view
        #expect(root.convert(card.bounds, from: card).minY >= root.convert(composerCard.bounds, from: composerCard).maxY,
                "The card docks above the composer")
        let options = harness.views(NSButton.self).filter { $0.accessibilityIdentifier() == "agent-chat.approval.option" }
        #expect(options.map(\.title) == ["Allow once", "Always allow", "Reject"], "Agent options verbatim, in order")
        options[0].performClick(nil)
        try await harness.waitUntil { harness.controller.timeline.rows.contains { if case .approvalRecord = $0 { true } else { false } } }
        harness.layout()
        #expect(card.titleLabel.stringValue == "Delete build output")
        #expect(!card.headerLabel.stringValue.contains("more"))
        card.cancelButton.performClick(nil)
        try await harness.waitUntil { harness.session.phase == .ready && card.isHidden }
        let records = harness.controller.timeline.rows.compactMap { row -> AgentChatItem.Approval? in
            if case .approvalRecord(let item) = row, case .approval(let approval) = item.content { approval } else { nil }
        }
        #expect(records.map(\.decision) == [.chose(optionID: "allow", name: "Allow once", allows: true), .cancelledByUser])
        harness.layout()
        let recordRow = try #require(harness.controller.timeline.rows.firstIndex { if case .approvalRecord = $0 { true } else { false } })
        #expect(harness.controller.table.view(atColumn: 0, row: recordRow, makeIfNecessary: true) is ApprovalRecordView)
    }

    @Test("The context meter leaves the composer for a disabled item in the Conversation menu")
    func contextMeterMovesToTheAgentMenu() async throws {
        let harness = try Harness(steering: false, #"""
        read -r _
        update '{"sessionUpdate":"usage_update","used":1200,"size":200000}'
        update '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Done."}}'
        printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn","usage":{"inputTokens":10,"outputTokens":5,"cachedReadTokens":990,"cachedWriteTokens":0}}}'
        read -r _
        """#)
        defer { harness.close() }
        try await harness.sendPrompt("Measure")
        try await harness.waitUntil { harness.session.phase == .ready && harness.session.lastTurnUsage != nil }
        try await Task.sleep(for: .milliseconds(60))
        harness.layout()
        let menu = try #require(harness.identified("agent-chat.agent") as? NSPopUpButton)
        let conversation = try #require(menu.itemArray.first { $0.title == "Conversation" }?.submenu)
        let info = try #require(conversation.items.last)
        #expect(info.title == "Context 1.2k / 200k · Cache 99%")
        #expect(!info.isEnabled)
        let composerCard = try #require(harness.identified("agent-chat.composer-card"))
        let labels = harness.descendants(of: composerCard).compactMap { $0 as? NSTextField }
        #expect(!labels.contains { $0.stringValue.contains("200k") || $0.stringValue.contains("Cache") })
        #expect(!(menu.toolTip ?? "").contains("Context"))
    }

    @Test("j/k move a visible step cursor, Enter opens the Inspector overlay, / and Shift-Tab move focus")
    func keyboardCursorAndInspector() async throws {
        let tools = (1...5).map { index in
            #"update '{"sessionUpdate":"tool_call","toolCallId":"r\#(index)","title":"Read file\#(index).swift","kind":"read","status":"completed","rawInput":{"file_path":"/repo/file\#(index).swift"}}'"#
        }.joined(separator: "\n")
        let harness = try Harness(steering: false, "read -r _\n" + tools + "\n" + #"""
        update '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"All five files read."}}'
        printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}'
        read -r _
        """#)
        defer { harness.close() }
        try await harness.sendPrompt("Read the files")
        try await harness.waitUntil {
            harness.session.phase == .ready && harness.controller.timeline.rows.contains { row in
                if case .activity(let group) = row { group.state == .settled } else { false }
            }
        }
        harness.layout()
        let controller = harness.controller
        guard case .activity(let group)? = controller.timeline.rows.first(where: { if case .activity = $0 { true } else { false } }) else {
            Issue.record("expected an activity row")
            return
        }
        #expect(group.summary.hasPrefix("Explored "))
        #expect(harness.identified("agent-chat.activity") != nil)
        #expect(harness.window.makeFirstResponder(controller.table))
        controller.table.keyDown(with: try key(38, "j"))
        #expect(controller.timeline.cursor.stop == .card(groupID: group.id), "A collapsed card is one stop")
        #expect(!controller.timeline.cursor.ring.isHidden, "The cursor shows a focus ring")
        controller.table.keyDown(with: try key(36, "\r"))
        #expect(controller.inspector.subject == .group(id: group.id))
        #expect(harness.identified("agent-chat.inspector")?.isHidden == false)
        #expect(controller.inspector.view.isDescendant(of: controller.view), "The Inspector overlays the transcript area")
        controller.table.keyDown(with: try key(53, "\u{1b}"))
        #expect(!controller.inspector.isPresented)

        controller.timeline.toggleExpanded(group.id)
        harness.layout()
        #expect(harness.window.makeFirstResponder(controller.table))
        controller.table.keyDown(with: try key(38, "j"))
        controller.table.keyDown(with: try key(38, "j"))
        guard case .step(let key, false)? = controller.timeline.cursor.stop else {
            Issue.record("expected a step stop")
            return
        }
        #expect(harness.identified("agent-chat.step") != nil)
        controller.table.keyDown(with: try self.key(40, "k"))
        controller.table.keyDown(with: try self.key(38, "j"))
        #expect(controller.timeline.cursor.stop == .step(key: key, isThought: false))
        controller.table.keyDown(with: try self.key(36, "\r"))
        #expect(controller.inspector.subject == .step(key: key))
        controller.inspector.dismiss()

        #expect(harness.window.makeFirstResponder(controller.table))
        controller.table.keyDown(with: try self.key(44, "/"))
        #expect(harness.window.firstResponder === harness.composer)
        harness.composer.insertBacktab(nil)
        #expect(harness.window.firstResponder === controller.table, "Shift-Tab from the composer focuses the transcript")
        // Type-select never steals letters from the cursor.
        #expect(!controller.table.allowsTypeSelect)
    }

    private func key(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                      context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: code))
    }
}

/// A pane with a scripted agent in an offscreen window (animations off, so
/// settles are acknowledged at once).
@MainActor
private struct Harness {
    let session: AgentChatSession
    let controller: AgentChatPaneViewController
    let window: NSWindow
    let composer: AgentChatComposerTextView
    private let suite: String

    init(steering: Bool, width: CGFloat = 560, _ body: String) throws {
        suite = "AgentChatPaneTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let preamble = #"""
        update() { printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":%s}}\n' "$1"; }
        read -r _
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":false},"_meta":{"steering":{"supported":STEER}}}}'
        read -r _
        printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s1"}}'

        """#.replacingOccurrences(of: "STEER", with: steering ? "true" : "false")
        let launch = ACPConnection.LaunchConfiguration(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", preamble + body], environment: [:],
            currentDirectory: FileManager.default.temporaryDirectory
        )
        let pane = Pane(kind: .agentChat)
        session = AgentChatSession(paneID: pane.id, agent: .claude, workingDirectory: NSTemporaryDirectory(), defaults: defaults,
                                   resolveLaunch: { _, _ in .success(launch) })
        controller = AgentChatPaneViewController(pane: pane, session: session)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 720), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: width, height: 720))
        controller.updatePresentation(isActive: true, isSelected: true)
        composer = try #require(Self.descendants(of: controller.view).compactMap { $0 as? AgentChatComposerTextView }.first)
    }

    func close() {
        controller.closePane()
        session.shutDown()
        window.close()
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func sendPrompt(_ text: String) async throws {
        try await waitUntil { session.phase == .ready }
        session.draft = text
        session.send()
    }

    func type(_ text: String) {
        composer.string = text
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: composer))
    }

    func layout() {
        controller.view.layoutSubtreeIfNeeded()
        controller.table.layoutSubtreeIfNeeded()
    }

    func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(predicate())
    }

    func descendants(of view: NSView) -> [NSView] { Self.descendants(of: view) }

    static func descendants(of view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants(of: $0) } }

    func identified(_ identifier: String) -> NSView? {
        descendants(of: controller.view).first { $0.accessibilityIdentifier() == identifier }
    }

    func view<T: NSView>(_ type: T.Type) -> T? { descendants(of: controller.view).compactMap { $0 as? T }.first }

    func views<T: NSView>(_ type: T.Type) -> [T] { descendants(of: controller.view).compactMap { $0 as? T } }
}
