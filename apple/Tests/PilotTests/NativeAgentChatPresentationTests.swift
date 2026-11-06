import AppKit
import Testing
@testable import Pilot

@Suite("Native agent chat presentation")
@MainActor
struct NativeAgentChatPresentationTests {
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

    @Test("Long streamed messages follow the end only while both scroll areas follow")
    func longStreamedMessageScrolling() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let cell = AgentChatTranscriptCell()
        cell.frame = NSRect(x: 0, y: 0, width: 752, height: 1_208)
        window.contentView?.addSubview(cell)
        var message = (0..<150).map { "Line \($0)" }.joined(separator: "\n")
        func stream(follow: Bool) {
            let row = AgentChatNativeRow(id: "stream", item: .init(id: "stream", content: .assistant(message)),
                                         depth: 0, expanded: false, childCount: 0)
            cell.apply(AgentChatRenderedRow(row: row), depth: 0, followStreamingOutput: follow)
            cell.layoutSubtreeIfNeeded()
        }
        stream(follow: true)
        let text = try #require(descendants(of: cell).compactMap { $0 as? NSTextView }.first)
        let scroll = try #require(text.enclosingScrollView)
        #expect(text.bounds.height > 1_200)
        try expectMessageEndVisible(text)

        message += "\nNewest streamed line"
        stream(follow: true)
        try expectMessageEndVisible(text)

        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        let selection = NSRange(location: 2, length: 5)
        text.setSelectedRange(selection)
        message += "\nBackground stream while reading earlier text"
        stream(follow: true)
        #expect(scroll.contentView.bounds.origin.y == 0)
        #expect(text.selectedRange() == selection)

        text.scrollToEndOfDocument(nil)
        let originalOrigin = scroll.contentView.bounds.origin
        message += "\nOuter transcript is now scrolled up"
        stream(follow: false)
        #expect(scroll.contentView.bounds.origin == originalOrigin)
        #expect(text.selectedRange() == selection)
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

    private func expectMessageEndVisible(_ text: NSTextView) throws {
        let scroll = try #require(text.enclosingScrollView)
        let layout = try #require(text.layoutManager)
        let container = try #require(text.textContainer)
        let length = text.string.utf16.count
        try #require(length > 0)
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: length - 1, length: 1), actualCharacterRange: nil)
        let lastGlyph = layout.boundingRect(forGlyphRange: glyphs, in: container)
            .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
        let visible = text.convert(scroll.contentView.bounds, from: scroll.contentView)
        let pixel = 1 / (text.window?.backingScaleFactor ?? 1)
        // NSTextView scrolls the final glyph into view; its trailing container
        // padding need not align exactly with the clip edge on every display.
        #expect(lastGlyph.height > 0)
        #expect(lastGlyph.minY >= visible.minY - pixel)
        #expect(lastGlyph.maxY <= visible.maxY + pixel)
        #expect(abs(visible.maxY - text.bounds.maxY) <= text.textContainerInset.height + pixel)
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
