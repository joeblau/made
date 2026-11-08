import AppKit
import Testing
@testable import Pilot

@Suite("Native agent chat presentation")
@MainActor
struct NativeAgentChatPresentationTests {
    @Test("Streaming can restyle earlier Markdown and preserve the reader's selection")
    func streamingMarkdownRestylesPrefix() throws {
        let cell = ProseCellView()
        cell.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        var revision = 0
        func stream(_ message: String) {
            revision += 1
            cell.configure(item: AgentChatItem(id: "stream", content: .assistant(message), revision: revision),
                           isStreaming: true, actions: AgentChatRowActions())
            cell.layoutSubtreeIfNeeded()
        }
        stream("A **bold")
        let text = try #require(descendants(of: cell).compactMap { $0 as? NSTextView }.first)
        text.setSelectedRange(NSRange(location: 0, length: 1))
        stream("A **bold** answer")
        #expect(text.string == "A bold answer")
        #expect(text.selectedRange() == NSRange(location: 0, length: 1))
        let bold = (text.string as NSString).range(of: "bold")
        let font = try #require(text.textStorage?.attribute(.font, at: bold.location, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        stream("A **bold** answer with more text.")
        #expect(text.string == "A bold answer with more text.")
        #expect(text.selectedRange() == NSRange(location: 0, length: 1))
    }

    @Test("Chat setup builds native controls without launching an agent")
    func setupControlsAreNative() throws {
        let defaults = try #require(UserDefaults(suiteName: "NativeAgentChatPresentationTests.\(UUID().uuidString)"))
        let pane = Pane(kind: .agentChat)
        let session = AgentChatSession(paneID: pane.id, agent: .claude, workingDirectory: nil, defaults: defaults)
        let controller = AgentChatPaneViewController(pane: pane, session: session)
        controller.updatePresentation(isActive: true, isSelected: false)
        defer { controller.closePane() }

        #expect(session.phase == .needsSetup(.noWorkingDirectory))
        let views = descendants(of: controller.view)
        #expect(views.contains { $0 is NSTableView })
        #expect(views.contains { $0 is AgentChatComposerTextView })
        // AppKit uses _NSCoreHostingView internally for native controls.
        // The migration boundary excludes SwiftUI hosts owned by the app.
        #expect(!views.contains { NSStringFromClass(type(of: $0)).contains("NSHostingView") })
        #expect(!descendants(of: controller).contains {
            NSStringFromClass(type(of: $0)).contains("NSHostingController")
        })
        #expect(views.compactMap { $0 as? NSTextField }.contains {
            $0.stringValue == ChatAgentSetupIssue.noWorkingDirectory.message
        })
    }

    @Test("An open chat switches providers in place and keeps the unsent draft")
    func providerSelectionInsideChat() throws {
        let name = "NativeAgentChatPresentationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let pane = Pane(kind: .agentChat)
        let session = AgentChatSession(paneID: pane.id, agent: .claude, workingDirectory: nil, defaults: defaults)
        session.draft = "Review this change"
        let controller = AgentChatPaneViewController(pane: pane, session: session)
        controller.updatePresentation(isActive: true, isSelected: false)
        defer { controller.closePane() }
        let trigger = try #require(descendants(of: controller.view).compactMap { $0 as? AgentModelTriggerButton }
            .first { $0.accessibilityIdentifier() == "agent-chat.agent" })
        #expect(trigger.accessibilityLabel() == "Model and provider")
        let composer = try #require(descendants(of: controller.view).compactMap { $0 as? AgentChatComposerTextView }.first)
        for agent: ChatAgent in [.cursor, .codex, .kimi, .claude] {
            // A provider without a cached catalog offers one row that starts it.
            let state = AgentModelPickerController.state(session: session, catalog: controller.modelPicker.catalog,
                                                         selectedTab: .agent(agent))
            let row = try #require(state.rows.first)
            #expect(row.isPlaceholder && state.isEditable)
            controller.modelPicker.handle(.selectModel(agent: row.agent, modelID: row.modelID))
            #expect(session.agent == agent)
            #expect(trigger.agent == agent)
            #expect(AgentChatPaneStore.agent(for: pane.id, defaults: defaults) == agent)
            #expect(session.draft == "Review this change")
            #expect(composer.superview != nil)
        }
    }

    @Test("The bottom composer grows, stays usable in split panes, and sends into the conversation", arguments: [160, 280, 560, 1_000])
    func composerLayoutAndConversation(width: Int) async throws {
        let name = "NativeAgentChatPresentationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let launch = ACPConnection.LaunchConfiguration(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", #"""
            read -r _
            printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":false}}}'
            read -r _
            printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"composer","models":{"currentModelId":"m","availableModels":[{"modelId":"m","name":"Opus 5.5"}]}}}'
            read -r _
            printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"composer","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"The composer keeps your conversation above the draft.\n\n- Choose an agent from the lower right.\n- Press **Return** to send, or **Option-Return** for a new line."}}}}'
            printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}'
            read -r _
            """#], environment: [:], currentDirectory: FileManager.default.temporaryDirectory
        )
        let pane = Pane(kind: .agentChat)
        let session = AgentChatSession(paneID: pane.id, agent: .claude, workingDirectory: NSTemporaryDirectory(),
                                       defaults: defaults, resolveLaunch: { _, _ in .success(launch) })
        let controller = AgentChatPaneViewController(pane: pane, session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 720),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: width, height: 720))
        defer { controller.closePane(); session.shutDown(); window.close() }
        controller.updatePresentation(isActive: true, isSelected: true)
        let views = descendants(of: controller.view)
        let composer = try #require(views.compactMap { $0 as? AgentChatComposerTextView }.first)
        let scroll = try #require(composer.enclosingScrollView)
        let card = try #require(views.first { $0.accessibilityIdentifier() == "agent-chat.composer-card" })
        let send = try #require(views.compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "agent-chat.send" })
        let table = try #require(views.compactMap { $0 as? NSTableView }.first)
        try await waitUntil { composer.isEditable }
        controller.view.layoutSubtreeIfNeeded()
        #expect(table.numberOfRows == 0, "Empty-state guidance must not become a copyable conversation row")
        #expect(!send.isEnabled)
        let originalHeight = card.bounds.height
        func draft(_ text: String) {
            composer.string = text
            controller.textDidChange(Notification(name: NSText.didChangeNotification, object: composer))
            controller.view.layoutSubtreeIfNeeded()
        }
        draft((0..<80).map { "Draft line \($0)" }.joined(separator: "\n"))
        #expect(card.bounds.height > originalHeight)
        #expect(card.bounds.height < 340, "Long drafts must leave room for the conversation")
        #expect(composer.bounds.height > scroll.contentSize.height)
        draft("Hello")
        #expect(abs(card.bounds.height - originalHeight) < 1)
        draft("Help me understand this workspace.")
        #expect(send.isEnabled)
        #expect(abs(send.bounds.width - send.bounds.height) < 1, "The send action must remain circular")
        #expect(views.contains { $0.accessibilityIdentifier() == "agent-chat.stop" && $0.isHidden },
                "Stop exists but stays hidden while nothing runs")
        let trigger = try #require(views.compactMap { $0 as? AgentModelTriggerButton }.first)
        if width <= 160 { #expect(trigger.compact && trigger.label.isHidden, "Narrow composers show the provider mark alone") }
        if width >= 560 { #expect(!trigger.compact && trigger.label.stringValue == "Opus 5.5") }
        for identifier in ["agent-chat.agent", "agent-chat.conversation-menu", "agent-chat.attach", "agent-chat.send",
                           "agent-chat.stop"] {
            let control = try #require(views.first { $0.accessibilityIdentifier() == identifier })
            if control.isHidden { continue }
            let frame = card.convert(control.bounds, from: control)
            #expect(card.bounds.contains(frame), "\(identifier) must fit inside the composer at \(width) pt")
            #expect(frame.maxY <= card.convert(scroll.bounds, from: scroll).minY)
        }
        let cardFrame = controller.view.convert(card.bounds, from: card)
        #expect(abs(controller.view.bounds.width - CGFloat(width)) < 1)
        let transcript = try #require(table.enclosingScrollView)
        #expect(controller.view.convert(transcript.bounds, from: transcript).minY >= cardFrame.maxY)
        #expect(cardFrame.minX >= 12 && cardFrame.minY >= 12)
        try capture(controller.view, name: "agent-composer-\(width)-draft")
        send.performClick(nil)
        try await waitUntil { session.phase == .ready && table.numberOfRows == 2 && composer.string.isEmpty }
        #expect(!send.isEnabled)
        #expect(session.transcript.items.count == 2)
        controller.view.layoutSubtreeIfNeeded()
        let answer = try #require(table.view(atColumn: 0, row: 1, makeIfNecessary: true))
        answer.layoutSubtreeIfNeeded()
        let answerText = try #require(descendants(of: answer).compactMap { $0 as? NSTextView }.first)
        if answer.bounds.height < 1_200 {
            #expect(answerText.enclosingScrollView?.contentView.bounds.minY == 0,
                    "A short wrapped response must show its first line without inner scrolling")
        }
        try capture(controller.view, name: "agent-composer-\(width)-conversation")
    }

    @Test("Return submits and Option-Return keeps a multiline draft")
    func composerReturnRouting() throws {
        let composer = AgentChatComposerTextView()
        composer.string = "First"
        composer.setSelectedRange(NSRange(location: 5, length: 0))
        var submissions = 0
        composer.onSubmit = { submissions += 1 }
        composer.keyDown(with: try key(code: 36, characters: "\r"))
        #expect(submissions == 1)
        #expect(composer.string == "First")
        composer.keyDown(with: try key(code: 36, characters: "\r", flags: .option))
        #expect(submissions == 1)
        #expect(composer.string.contains("\n"))
    }

    @Test("Input method owns Return until marked text is committed")
    func markedTextIsNotSubmitted() throws {
        let composer = AgentChatComposerTextView()
        var submissions = 0
        composer.onSubmit = { submissions += 1 }
        composer.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(composer.hasMarkedText())
        composer.keyDown(with: try key(code: 36, characters: "\r"))
        #expect(submissions == 0)
    }

    @Test("Escape cancels only when the active turn accepts cancellation")
    func escapeCancellation() throws {
        let composer = AgentChatComposerTextView()
        var cancellations = 0
        composer.onCancel = { cancellations += 1; return true }
        composer.keyDown(with: try key(code: 53, characters: "\u{1b}"))
        #expect(cancellations == 1)
    }

    @Test("Agent readiness honors requested input focus without stealing another field", arguments: [false, true])
    func readinessFocus(preserveOtherField: Bool) async throws {
        let defaults = try #require(UserDefaults(suiteName: "NativeAgentChatPresentationTests.\(UUID().uuidString)"))
        let launch = ACPConnection.LaunchConfiguration(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", #"""
            read -r _
            printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":false}}}'
            read -r _
            printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"native-focus"}}'
            read -r _
            """#],
            environment: [:], currentDirectory: FileManager.default.temporaryDirectory
        )
        let pane = Pane(kind: .agentChat)
        let session = AgentChatSession(paneID: pane.id, agent: .claude,
                                       workingDirectory: NSTemporaryDirectory(), defaults: defaults,
                                       resolveLaunch: { _, _ in .success(launch) })
        let controller = AgentChatPaneViewController(pane: pane, session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { controller.closePane(); session.shutDown(); window.close() }
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 800, height: 600))
        controller.updatePresentation(isActive: true, isSelected: true)
        controller.focusPaneInput()
        let composer = try #require(descendants(of: controller.view).compactMap { $0 as? AgentChatComposerTextView }.first)
        let otherField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        if preserveOtherField {
            controller.view.addSubview(otherField)
            #expect(window.makeFirstResponder(otherField))
        }
        let previousResponder = window.firstResponder
        let deadline = ContinuousClock.now + .seconds(10)
        while !composer.isEditable, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(session.phase == .ready)
        #expect(composer.isEditable)
        if preserveOtherField {
            #expect(window.firstResponder === previousResponder)
        } else {
            #expect(window.firstResponder === composer)
        }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(predicate())
    }

    private func capture(_ view: NSView, name: String) throws {
        guard let destination = ProcessInfo.processInfo.environment["MADE_TOOL_REVIEW_OUTPUT"] else { return }
        let output = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
    }

    private func key(code: UInt16, characters: String, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code
        ))
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func descendants(of controller: NSViewController) -> [NSViewController] {
        [controller] + controller.children.flatMap { descendants(of: $0) }
    }
}
