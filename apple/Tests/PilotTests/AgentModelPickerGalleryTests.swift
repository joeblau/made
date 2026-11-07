import AppKit
import Testing
@testable import Pilot

/// Model picker gallery: states mirror the real `session/new` probe results
/// of each agent. Asserts structure always; writes PNGs when
/// MADE_TOOL_REVIEW_OUTPUT is set.
@Suite("Agent model picker gallery")
@MainActor
struct AgentModelPickerGalleryTests {
    // MARK: - Gallery states

    @Test("Codex matches the reference: 6.1 Sol current, Low reasoning, Standard | Fast, Full access")
    func codexMatchesReference() throws {
        for dark in [false, true] {
            let (picker, recorder) = Picker.make(PickerFixtures.codex(), dark: dark)
            #expect(picker.visibleRows.map(\.name) == ["6.1 Sol", "6 Astra", "6.1 Terra", "6 Sol"])
            #expect(picker.keycapCount == 4)
            #expect(picker.rowViews.map(\.keycap.text) == ["⌘1", "⌘2", "⌘3", "⌘4"])
            #expect(picker.rowViews.map { !$0.check.isHidden } == [true, false, false, false])
            #expect(!picker.showMoreButton.isHidden)
            #expect(picker.isReasoningVisible && !picker.reasoningLabel.isHidden)
            #expect(picker.reasoningTitleLabel.stringValue == "6.1 Sol")
            #expect(picker.reasoningButtons.map(\.choice.name) == ["Low", "Medium", "High", "Extra High", "Max", "Ultra"])
            #expect(picker.reasoningButtons.map(\.choice.isCurrent) == [true, false, false, false, false, false])
            #expect(picker.isFooterVisible && !picker.fastToggle.isHidden && !picker.modeButton.isHidden)
            #expect(picker.fastToggle.standard.isOn && !picker.fastToggle.fast.isOn)
            #expect(picker.modeButton.modeName == "Full access")
            #expect(picker.modeButton.shieldSymbol == "shield.slash")
            #expect(picker.railButtons.count == 1 + ChatAgent.allCases.count)
            #expect(picker.railButtons.filter(\.isSelectedTab).map(\.kind) == [.agent(.codex)])
            #expect(picker.preferredContentSize == NSSize(width: 552, height: 396))
            #expect(recorder.actions.isEmpty)
            try Picker.capture(Picker.scene(picker, trigger: ("6.1 Sol", "Low"), agent: .codex, dark: dark),
                               name: "codex-\(dark ? "dark" : "light")")
        }
    }

    @Test("Claude shows its effort levels with a checkmarked shield mode")
    func claude() throws {
        for dark in [false, true] {
            let (picker, _) = Picker.make(PickerFixtures.claude(), dark: dark)
            #expect(picker.visibleRows.map(\.name) == ["Default (recommended)", "Opus 5.5", "Fable 5.1", "Sonnet 5.5"])
            #expect(picker.rowViews.map { !$0.check.isHidden } == [false, true, false, false])
            #expect(picker.reasoningButtons.first { $0.choice.isCurrent }?.choice.name == "High")
            #expect(picker.modeButton.modeName == "Auto" && picker.modeButton.shieldSymbol == "checkmark.shield")
            try Picker.capture(Picker.scene(picker, trigger: ("Opus 5.5", "High"), agent: .claude, dark: dark),
                               name: "claude-\(dark ? "dark" : "light")")
        }
    }

    @Test("Grok has no mode or fast option, so the footer is hidden")
    func grokWithoutFooter() throws {
        for dark in [false, true] {
            let (picker, _) = Picker.make(PickerFixtures.grok(), dark: dark)
            #expect(picker.visibleRows.count == 4 && picker.showMoreButton.isHidden)
            #expect(picker.keycapCount == 4)
            #expect(!picker.isFooterVisible && picker.fastToggle.isHidden && picker.modeButton.isHidden)
            #expect(picker.preferredContentSize.height == 350)
            #expect(picker.isReasoningVisible)
            try Picker.capture(Picker.scene(picker, trigger: ("Grok 4.7 Fast", "Medium"), agent: .grok, dark: dark),
                               name: "grok-\(dark ? "dark" : "light")")
        }
    }

    @Test("Cursor has no reasoning option, so the model column widens")
    func cursorWithoutReasoning() throws {
        for dark in [false, true] {
            let (picker, _) = Picker.make(PickerFixtures.cursor(), dark: dark)
            #expect(!picker.isReasoningVisible && picker.reasoningLabel.isHidden && picker.reasoningButtons.isEmpty)
            #expect(picker.fastToggle.isHidden && !picker.modeButton.isHidden)
            let row = try #require(picker.rowViews.first)
            #expect(row.frame.width > 552 - 46 - 192, "The middle column takes the reasoning column's width")
            try Picker.capture(Picker.scene(picker, trigger: ("grok-4.7", nil), agent: .cursor, dark: dark),
                               name: "cursor-\(dark ? "dark" : "light")")
        }
    }

    @Test("Favorites lists models across providers with each provider's mark")
    func favoritesTab() throws {
        for dark in [false, true] {
            let (picker, _) = Picker.make(PickerFixtures.favorites(), dark: dark)
            #expect(picker.railButtons.filter(\.isSelectedTab).map(\.kind) == [.favorites])
            #expect(picker.visibleRows.map(\.agent) == [.codex, .claude, .grok, .kimi])
            #expect(picker.keycapCount == 4)
            #expect(!picker.isReasoningVisible)
            try Picker.capture(Picker.scene(picker, trigger: ("6.1 Sol", "Low"), agent: .codex, dark: dark),
                               name: "favorites-\(dark ? "dark" : "light")")
            let (empty, _) = Picker.make(PickerFixtures.favorites(rows: []), dark: dark)
            #expect(empty.visibleRows.isEmpty && !empty.emptyLabel.isHidden && empty.keycapCount == 0)
            #expect(empty.emptyLabel.stringValue == "Star a model to keep it here")
        }
    }

    @Test("A provider without a cached catalog shows one placeholder row without keycaps")
    func placeholderTab() throws {
        let (picker, recorder) = Picker.make(PickerFixtures.placeholder(), dark: true)
        #expect(picker.visibleRows.count == 1 && picker.visibleRows[0].isPlaceholder)
        #expect(picker.keycapCount == 0)
        picker.rowViews[0].setHovering(true)
        #expect(picker.rowViews[0].favoriteButton.isHidden)
        #expect(picker.rowViews[0].contextMenu() == nil)
        picker.rowViews[0].press()
        #expect(recorder.actions == [.selectModel(agent: .kimi, modelID: "")])
        try Picker.capture(Picker.scene(picker, trigger: ("6.1 Sol", "Low"), agent: .codex, dark: true), name: "placeholder-dark")
    }

    @Test("Search filters case- and diacritic-insensitively on name and id and shows every match")
    func searchFilter() throws {
        for dark in [false, true] {
            let (picker, recorder) = Picker.make(PickerFixtures.codex(), dark: dark)
            Picker.type("SÓL", into: picker)
            #expect(picker.visibleRows.map(\.name) == ["6.1 Sol", "6 Sol", "5.6 Sol"])
            #expect(picker.keycapCount == 3)
            #expect(picker.showMoreButton.isHidden)
            #expect(picker.highlightedIndex == 0)
            try Picker.capture(Picker.scene(picker, trigger: ("6.1 Sol", "Low"), agent: .codex, dark: dark),
                               name: "search-\(dark ? "dark" : "light")")
            Picker.type("gpt-6-luna", into: picker)
            #expect(picker.visibleRows.map(\.modelID) == ["gpt-6-luna"])
            Picker.type("zzz", into: picker)
            #expect(picker.visibleRows.isEmpty && !picker.emptyLabel.isHidden)
            #expect(recorder.actions.isEmpty)
        }
        let rows = PickerFixtures.codex().rows
        #expect(AgentModelPickerViewController.filter(rows, query: "  terra ").map(\.modelID) == ["gpt-6.1-terra", "gpt-5.6-terra"])
        #expect(AgentModelPickerViewController.filter(rows, query: "").count == rows.count)
    }

    @Test("Show more expands to every model and keeps keycaps on the first four")
    func showMoreExpanded() throws {
        for dark in [false, true] {
            let (picker, _) = Picker.make(PickerFixtures.codex(), dark: dark)
            picker.showMoreButton.performClick(nil)
            #expect(picker.isExpanded)
            #expect(picker.visibleRows.count == 8)
            #expect(picker.keycapCount == 4)
            #expect(picker.rowViews.prefix(4).allSatisfy { !$0.keycap.isHidden })
            #expect(picker.rowViews.dropFirst(4).allSatisfy { $0.keycap.isHidden })
            #expect(picker.showMoreButton.isHidden)
            try Picker.capture(Picker.scene(picker, trigger: ("6.1 Sol", "Low"), agent: .codex, dark: dark),
                               name: "show-more-\(dark ? "dark" : "light")")
        }
    }

    @Test("Grouped options render section headers between rows")
    func groupedRows() throws {
        var state = PickerFixtures.cursor()
        for index in state.rows.indices { state.rows[index].group = index < 2 ? "Recommended" : "All models" }
        let (picker, _) = Picker.make(state, dark: true)
        #expect(picker.groupLabels.map(\.stringValue) == ["Recommended", "All models"])
        #expect(picker.entries.prefix(3) == [.group("Recommended"), .row(0), .row(1)])
        try Picker.capture(Picker.scene(picker, trigger: ("grok-4.7", nil), agent: .cursor, dark: true), name: "grouped-dark")
    }

    @Test("A non-editable picker disables rows, reasoning and footer but keeps tabs browsable")
    func disabled() throws {
        var state = PickerFixtures.codex()
        state.isEditable = false
        for dark in [false, true] {
            let (picker, recorder) = Picker.make(state, dark: dark)
            picker.rowViews[1].press()
            _ = picker.handleKeyEquivalent(Picker.command("2"))
            picker.reasoningButtons[2].performClick(nil)
            picker.fastToggle.fast.performClick(nil)
            #expect(recorder.actions.isEmpty)
            #expect(picker.reasoningButtons.allSatisfy { !$0.isEnabled })
            #expect(!picker.fastToggle.fast.isEnabled && !picker.modeButton.isEnabled)
            #expect(picker.rowViews.allSatisfy { $0.alphaValue < 1 })
            picker.railButtons[1].performClick(nil)
            #expect(recorder.actions == [.selectTab(.agent(.claude))])
            try Picker.capture(Picker.scene(picker, trigger: ("6.1 Sol", "Low"), agent: .codex, dark: dark),
                               name: "disabled-\(dark ? "dark" : "light")")
        }
    }

    // MARK: - Actions

    @Test("Clicks send model, tab, favorite, reasoning, speed and mode actions")
    func clickActions() throws {
        let (picker, recorder) = Picker.make(PickerFixtures.codex(), dark: true, inWindow: true)
        let window = try #require(picker.view.window)
        let row = picker.rowViews[2]
        let center = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        row.mouseUp(with: try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: center, modifierFlags: [], timestamp: 0,
                                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                          clickCount: 1, pressure: 0)))
        picker.railButtons[0].performClick(nil)
        #expect((window.firstResponder as? NSTextView)?.delegate === picker.searchField, "A clicked tab returns focus to search")
        row.setHovering(true)
        #expect(!row.favoriteButton.isHidden)
        row.favoriteButton.performClick(nil)
        let menu = try #require(row.contextMenu())
        #expect(menu.items.map(\.title) == ["Add to Favorites"])
        menu.performActionForItem(at: 0)
        picker.reasoningButtons[3].performClick(nil)
        picker.fastToggle.fast.performClick(nil)
        let modes = picker.modeMenu()
        #expect(modes.items.map(\.title) == ["Read-only", "Workspace access", "Auto review", "Full access"])
        #expect(modes.items.map(\.state) == [.off, .off, .off, .on])
        picker.modeItemChosen(modes.items[0])
        #expect(recorder.actions == [
            .selectModel(agent: .codex, modelID: "gpt-6.1-terra"),
            .selectTab(.favorites),
            .toggleFavorite(agent: .codex, modelID: "gpt-6.1-terra"),
            .toggleFavorite(agent: .codex, modelID: "gpt-6.1-terra"),
            .selectReasoning("xhigh"),
            .setFast(true),
            .selectMode("read-only"),
        ])
        let favorite = try #require(Picker.make(PickerFixtures.favorites(), dark: true).0.rowViews.first?.contextMenu())
        #expect(favorite.items.map(\.title) == ["Remove from Favorites"])
    }

    // MARK: - Keyboard

    @Test("Search takes focus; arrows move the highlight, Return selects, Esc dismisses")
    func keyboardNavigation() throws {
        let (picker, recorder) = Picker.make(PickerFixtures.codex(), dark: true, inWindow: true)
        let window = try #require(picker.view.window)
        picker.viewDidAppear()
        let editor = try #require(window.firstResponder as? NSTextView)
        #expect(editor.delegate === picker.searchField)
        #expect(picker.highlightedIndex == nil)
        editor.keyDown(with: Picker.key(125))
        editor.keyDown(with: Picker.key(125))
        #expect(picker.highlightedIndex == 1)
        #expect(picker.rowViews[1].isHighlighted && !picker.rowViews[0].isHighlighted)
        editor.keyDown(with: Picker.key(126))
        editor.keyDown(with: Picker.key(126))
        #expect(picker.highlightedIndex == 0)
        editor.keyDown(with: Picker.key(125))
        editor.keyDown(with: Picker.key(36, characters: "\r"))
        editor.keyDown(with: Picker.key(53, characters: "\u{1B}"))
        #expect(recorder.actions == [.selectModel(agent: .codex, modelID: "gpt-6-astra"), .dismiss])
    }

    @Test("Command-1 through Command-4 pick the first four visible rows")
    func commandShortcuts() throws {
        let (picker, recorder) = Picker.make(PickerFixtures.codex(), dark: true, inWindow: true)
        for number in 1...4 { #expect(picker.view.performKeyEquivalent(with: Picker.command("\(number)"))) }
        #expect(!picker.view.performKeyEquivalent(with: Picker.command("5")))
        #expect(recorder.actions == ["gpt-6.1-sol", "gpt-6-astra", "gpt-6.1-terra", "gpt-6-sol"].map {
            .selectModel(agent: .codex, modelID: $0)
        })
        recorder.actions = []
        Picker.type("luna", into: picker)
        #expect(picker.view.performKeyEquivalent(with: Picker.command("2")))
        #expect(recorder.actions == [.selectModel(agent: .codex, modelID: "gpt-5.6-luna")])
    }

    @Test("Tab moves search → reasoning → footer → rail; arrows walk reasoning levels")
    func tabOrder() throws {
        let (picker, recorder) = Picker.make(PickerFixtures.codex(), dark: true, inWindow: true)
        let window = try #require(picker.view.window)
        picker.viewDidAppear()
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.keyDown(with: Picker.key(48, characters: "\t"))
        #expect(window.firstResponder === picker.reasoningButtons[0])
        picker.reasoningButtons[0].keyDown(with: Picker.key(125))
        #expect(window.firstResponder === picker.reasoningButtons[1])
        picker.reasoningButtons[1].keyDown(with: Picker.key(36, characters: "\r"))
        #expect(recorder.actions == [.selectReasoning("medium")])
        #expect(picker.reasoningButtons[1].nextKeyView === picker.fastToggle.standard)
        #expect(picker.fastToggle.standard.nextKeyView === picker.modeButton)
        #expect(picker.modeButton.nextKeyView === picker.railButtons[0])
        #expect(picker.railButtons.last?.nextKeyView === picker.searchField)
        picker.fastToggle.standard.keyDown(with: Picker.key(124))
        #expect(recorder.actions.last == .setFast(true))
    }

    // MARK: - Updates

    @Test("update keeps search, highlight and Show more while rows are unchanged and resets them otherwise")
    func updatePreservesTransientState() throws {
        let (picker, _) = Picker.make(PickerFixtures.codex(), dark: true)
        picker.showMoreButton.performClick(nil)
        picker.moveHighlight(by: 1)
        picker.moveHighlight(by: 1)
        var state = PickerFixtures.codex()
        for index in state.rows.indices { state.rows[index].isCurrent = state.rows[index].modelID == "gpt-6-sol" }
        state.reasoning[0].isCurrent = false
        state.reasoning[2].isCurrent = true
        picker.update(state)
        #expect(picker.isExpanded && picker.highlightedIndex == 1 && picker.visibleRows.count == 8)
        #expect(picker.rowViews[3].check.isHidden == false)
        #expect(picker.reasoningButtons[2].choice.isCurrent)
        Picker.type("sol", into: picker)
        picker.update(PickerFixtures.claude())
        #expect(picker.searchField.stringValue == "sol")
        #expect(!picker.isExpanded && picker.highlightedIndex == nil)
        #expect(picker.visibleRows.isEmpty, "Claude has no model matching “sol”")
        #expect(picker.railButtons.filter(\.isSelectedTab).map(\.kind) == [.agent(.claude)])
    }

    // MARK: - Trigger and palette

    @Test("The composer trigger reads brand + model + reasoning and collapses to the mark")
    func trigger() throws {
        let trigger = AgentModelTriggerButton()
        trigger.configure(agent: .codex, modelName: "6.1 Sol", reasoning: "Low", compact: false)
        #expect(trigger.label.stringValue == "6.1 Sol Low" && !trigger.label.isHidden)
        #expect(trigger.accessibilityIdentifier() == "agent-chat.agent")
        #expect(trigger.accessibilityLabel() == "Model and provider")
        #expect(trigger.glyph.image != nil)
        let wide = trigger.intrinsicContentSize
        trigger.configure(agent: .cursor, modelName: "grok-4.7", reasoning: nil, compact: false)
        #expect(trigger.label.stringValue == "grok-4.7")
        trigger.configure(agent: .kimi, modelName: nil, reasoning: nil, compact: false)
        #expect(trigger.label.stringValue == "Kimi")
        trigger.configure(agent: .codex, modelName: "6.1 Sol", reasoning: "Low", compact: true)
        #expect(trigger.label.isHidden)
        #expect(trigger.intrinsicContentSize.width == trigger.intrinsicContentSize.height)
        #expect(trigger.intrinsicContentSize.width < wide.width)
        for agent in ChatAgent.allCases { #expect(AgentModelPickerBrand.image(for: agent) != nil, "\(agent) has a brand mark") }
    }

    @Test("Picker text meets 4.5:1 on every picker surface in light and dark")
    func paletteContrast() {
        for pair in AgentChatPalette.pickerTextPairs {
            for dark in [false, true] {
                let ratio = AgentChatPalette.contrastRatio(pair.text, on: pair.surface, dark: dark)
                #expect(ratio >= 4.5, "\(pair.name) (\(dark ? "dark" : "light")) is \(ratio):1")
            }
        }
        for dark in [false, true] {
            #expect(AgentChatPalette.contrastRatio(.pickerClaude, on: .pickerSurface, dark: dark) >= 3)
        }
    }
}

// MARK: - Harness

@MainActor
private final class PickerRecorder {
    var actions: [AgentModelPickerAction] = []
}

@MainActor
private enum Picker {
    static func make(_ state: AgentModelPickerState, dark: Bool,
                     inWindow: Bool = false) -> (AgentModelPickerViewController, PickerRecorder) {
        let recorder = PickerRecorder()
        let picker = AgentModelPickerViewController(state: state) { recorder.actions.append($0) }
        picker.view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if inWindow {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: picker.preferredContentSize), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = picker
        }
        picker.view.layoutSubtreeIfNeeded()
        picker.layoutContent()
        return (picker, recorder)
    }

    static func type(_ text: String, into picker: AgentModelPickerViewController) {
        picker.searchField.stringValue = text
        picker.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: picker.searchField))
        picker.layoutContent()
    }

    static func key(_ code: UInt16, characters: String = "") -> NSEvent {
        let scalar: String = switch code {
        case 125: String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case 126: String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case 123: String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case 124: String(UnicodeScalar(NSRightArrowFunctionKey)!)
        default: characters
        }
        let flags: NSEvent.ModifierFlags = (123...126).contains(code) ? [.numericPad, .function] : []
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                characters: scalar, charactersIgnoringModifiers: scalar, isARepeat: false, keyCode: code)!
    }

    static func command(_ character: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                         characters: character, charactersIgnoringModifiers: character, isARepeat: false,
                         keyCode: UInt16(17 + (Int(character) ?? 0)))!
    }

    /// The picker above the composer trigger, as in the reference.
    static func scene(_ picker: AgentModelPickerViewController, trigger title: (String, String?), agent: ChatAgent,
                      dark: Bool) -> NSView {
        let size = picker.preferredContentSize
        let host = AgentChatSurfaceView(fill: .thread, cornerRadius: 0)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: size.width + 24, height: size.height + 64)
        let card = AgentChatSurfaceView(fill: nil, border: .cardBorder, cornerRadius: 12)
        picker.view.removeFromSuperview()
        picker.view.frame = NSRect(x: 12, y: 12, width: size.width, height: size.height)
        picker.view.wantsLayer = true
        picker.view.layer?.cornerRadius = 12
        picker.view.layer?.masksToBounds = true
        host.addSubview(picker.view)
        card.frame = picker.view.frame
        host.addSubview(card)
        let trigger = AgentModelTriggerButton()
        trigger.configure(agent: agent, modelName: title.0, reasoning: title.1, compact: false)
        let triggerSize = trigger.intrinsicContentSize
        trigger.frame = NSRect(x: host.frame.width - 12 - triggerSize.width, y: size.height + 12 + 14,
                               width: triggerSize.width, height: triggerSize.height)
        host.addSubview(trigger)
        host.layoutSubtreeIfNeeded()
        picker.layoutContent()
        return host
    }

    static func capture(_ view: NSView, name: String) throws {
        guard let destination = ProcessInfo.processInfo.environment["MADE_TOOL_REVIEW_OUTPUT"] else { return }
        let output = URL(fileURLWithPath: destination).appendingPathComponent("agent-model-picker")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
    }
}

/// Hand-written states mirroring the agents' `session/new` probe results
/// (names and descriptions verbatim; "Xhigh" shown as "Extra High").
@MainActor
enum PickerFixtures {
    typealias State = AgentModelPickerState

    static let tabs: [State.Tab] = [State.Tab(kind: .favorites, title: "Favorites")]
        + ChatAgent.allCases.map { State.Tab(kind: .agent($0), title: $0.displayName) }

    static func rows(_ agent: ChatAgent, _ models: [(String, String, String?)], current: String,
                     favorites: Set<String> = []) -> [State.Row] {
        models.map { id, name, detail in
            State.Row(agent: agent, modelID: id, name: name, detail: detail, group: nil, isCurrent: id == current,
                      isFavorite: favorites.contains(id), isPlaceholder: false)
        }
    }

    static func choices(_ values: [(String, String, String?)], current: String,
                        unrestricted: Set<String> = []) -> [State.Choice] {
        values.map { id, name, detail in
            State.Choice(id: id, name: name, detail: detail, isCurrent: id == current, isUnrestricted: unrestricted.contains(id))
        }
    }

    static let codexModels: [(String, String, String?)] = [
        ("gpt-6.1-sol", "6.1 Sol", "Latest workhorse model for coding and everyday work."),
        ("gpt-6-astra", "6 Astra", "Frontier intelligence for the most demanding work."),
        ("gpt-6.1-terra", "6.1 Terra", "GPT-6.1 Terra Codex model."),
        ("gpt-6-sol", "6 Sol", "Previous generation workhorse model."),
        ("gpt-6-luna", "6 Luna", "Fast and affordable model for easier tasks."),
        ("gpt-5.6-sol", "5.6 Sol", "Older generation workhorse model."),
        ("gpt-5.6-terra", "5.6 Terra", "Older balanced model for straightforward work."),
        ("gpt-5.6-luna", "5.6 Luna", "Older fast and efficient model."),
    ]

    static func codex() -> State {
        State(
            tabs: tabs, selectedTab: .agent(.codex), rows: rows(.codex, codexModels, current: "gpt-6.1-sol"),
            reasoningTitle: "6.1 Sol",
            reasoning: choices([
                ("low", "Low", "Fast responses with lighter reasoning"),
                ("medium", "Medium", "Balances speed and reasoning depth for everyday tasks"),
                ("high", "High", "Greater reasoning depth for complex problems"),
                ("xhigh", "Extra High", "Extra high reasoning depth for complex problems"),
                ("max", "Max", "Maximum reasoning depth for the hardest problems"),
                ("ultra", "Ultra", "Maximum reasoning with automatic task delegation"),
            ], current: "low"),
            fast: false, modeName: "Full access",
            modeChoices: choices([
                ("read-only", "Read-only", "Requires approval to edit files and access the internet."),
                ("workspace-write", "Workspace access", "Edit workspace files; ask before writing outside the workspace."),
                ("agent", "Auto review", "Only ask for actions detected as potentially unsafe"),
                ("agent-full-access", "Full access", "Unrestricted access to the internet and any file on your computer."),
            ], current: "agent-full-access", unrestricted: ["agent-full-access"]),
            modeIsUnrestricted: true, isEditable: true
        )
    }

    static func claude() -> State {
        let models: [(String, String, String?)] = [
            ("default", "Default (recommended)", "Opus 5.5"), ("opus", "Opus 5.5", "For complex work and everyday tasks"),
            ("fable", "Fable 5.1", "For your toughest challenges"), ("sonnet", "Sonnet 5.5", "Most efficient for simpler tasks"),
            ("haiku", "Haiku 5.5", "Fastest for quick answers"), ("claude-haiku-4-5-20251001", "Haiku 4.5", "Fastest for quick answers"),
            ("claude-sonnet-5", "Sonnet 5", "Efficient for routine tasks"), ("claude-opus-5", "Opus 5", "Best for everyday, complex tasks"),
            ("claude-fable-5", "Fable 5", "Most capable for your hardest and longest-running tasks"),
            ("claude-opus-4-8", "Opus 4.8", "Best for everyday, complex tasks"),
            ("claude-opus-4-7", "Opus 4.7", "Best for everyday, complex tasks"),
            ("claude-opus-4-6", "Opus 4.6", "Best for everyday, complex tasks"),
            ("claude-sonnet-4-6", "Sonnet 4.6", "Efficient for routine tasks"),
        ]
        return State(
            tabs: tabs, selectedTab: .agent(.claude), rows: rows(.claude, models, current: "opus"),
            reasoningTitle: "Opus 5.5",
            reasoning: choices([("default", "Default", nil), ("low", "Low", nil), ("medium", "Medium", nil), ("high", "High", nil),
                                ("xhigh", "Extra High", nil), ("max", "Max", nil)], current: "high"),
            fast: false, modeName: "Auto",
            modeChoices: choices([
                ("default", "Manual", "Always ask before making changes"),
                ("acceptEdits", "Accept edits", "Automatically accept all file edits"),
                ("plan", "Plan", "Create a plan before making changes"),
                ("auto", "Auto", "Claude handles permission decisions"),
                ("bypassPermissions", "Bypass permissions", "Accepts all permissions"),
            ], current: "auto", unrestricted: ["bypassPermissions"]),
            modeIsUnrestricted: false, isEditable: true
        )
    }

    static func grok() -> State {
        State(
            tabs: tabs, selectedTab: .agent(.grok),
            rows: rows(.grok, [("grok-4.7", "Grok 4.7", nil), ("grok-4.7-build-fast", "Grok 4.7 Fast", nil),
                               ("grok-4.6", "Grok 4.6", nil), ("grok-4.5", "Grok 4.5", nil)], current: "grok-4.7-build-fast"),
            reasoningTitle: "Grok 4.7 Fast",
            reasoning: choices([
                ("xhigh", "Extra High", "Maximum reasoning for the hardest tasks."),
                ("high", "High", "Thorough reasoning and quality. Recommended."),
                ("medium", "Medium", "Strong quality with a faster turnaround."),
                ("low", "Low", "Fastest responses. Best for simple tasks."),
            ], current: "medium"),
            fast: nil, modeName: nil, modeChoices: [], modeIsUnrestricted: false, isEditable: true
        )
    }

    static func cursor() -> State {
        let ids = ["default[]", "grok-4.7[context=256k,reasoning_effort=high,fast=true]", "grok-4.6[effort=high,fast=true]",
                   "composer-2.5[fast=true]", "claude-opus-5-5[context=300k,effort=medium,fast=false]",
                   "claude-opus-5[thinking=true,context=300k,effort=high,fast=false]",
                   "gemini-4-argon[reasoning_effort=medium]", "gpt-5.6-sol[context=272k,reasoning=medium,fast=false]"]
        let names = ["Auto", "grok-4.7", "grok-4.6", "composer-2.5", "claude-opus-5-5", "claude-opus-5", "gemini-4-argon", "gpt-5.6-sol"]
        return State(
            tabs: tabs, selectedTab: .agent(.cursor),
            rows: rows(.cursor, zip(ids, names).map { ($0, $1, nil) }, current: ids[1]),
            reasoningTitle: nil, reasoning: [], fast: nil, modeName: "Agent",
            modeChoices: choices([
                ("agent", "Agent", "Full agent capabilities with tool access"),
                ("plan", "Plan", "Read-only mode for planning and designing before implementation"),
                ("ask", "Ask", "Q&A mode - no edits or command execution"),
            ], current: "agent"),
            modeIsUnrestricted: false, isEditable: true
        )
    }

    static func favorites(rows: [State.Row]? = nil) -> State {
        var state = codex()
        state.selectedTab = .favorites
        state.rows = rows ?? [
            State.Row(agent: .codex, modelID: "gpt-6.1-sol", name: "6.1 Sol", detail: nil, group: nil, isCurrent: true,
                      isFavorite: true, isPlaceholder: false),
            State.Row(agent: .claude, modelID: "opus", name: "Opus 5.5", detail: nil, group: nil, isCurrent: false,
                      isFavorite: true, isPlaceholder: false),
            State.Row(agent: .grok, modelID: "grok-4.7", name: "Grok 4.7", detail: nil, group: nil, isCurrent: false,
                      isFavorite: true, isPlaceholder: false),
            State.Row(agent: .kimi, modelID: "kimi-code/k3", name: "K3", detail: nil, group: nil, isCurrent: false,
                      isFavorite: true, isPlaceholder: false),
        ]
        state.reasoningTitle = nil
        state.reasoning = []
        return state
    }

    static func placeholder() -> State {
        var state = codex()
        state.selectedTab = .agent(.kimi)
        state.rows = [State.Row(agent: .kimi, modelID: "", name: "Start Kimi to see its models", detail: nil, group: nil,
                                isCurrent: false, isFavorite: false, isPlaceholder: true)]
        state.reasoningTitle = nil
        state.reasoning = []
        return state
    }
}
