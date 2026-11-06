import AppKit
import Testing
@testable import CodeEditSourceEditor
@testable import Pilot

private actor NativeEditorTestIO: EditorFileIO {
    var data = Data("alpha beta alpha".utf8)
    var date = Date(timeIntervalSince1970: 100)
    var failWrites = false
    var holdWrites = false
    var writeStarted = false
    var writeWaiter: CheckedContinuation<Void, Never>?

    func read(_ url: URL, maxBytes: Int) async throws -> EditorFileContents {
        EditorFileContents(data: data, modificationDate: date)
    }
    func modificationDate(of url: URL) async -> Date? { date }
    func write(_ data: Data, to url: URL) async throws -> Date? {
        writeStarted = true
        if holdWrites { await withCheckedContinuation { writeWaiter = $0 } }
        if failWrites { throw CocoaError(.fileWriteOutOfSpace) }
        self.data = data
        date += 1
        return date
    }
    func setFailWrites() { failWrites = true }
    func simulateExternalEdit() { data = Data("external edit".utf8); date += 1 }
    func suspendWrites() { holdWrites = true }
    func releaseWrite() { holdWrites = false; writeWaiter?.resume(); writeWaiter = nil }
    func hasStartedWrite() -> Bool { writeStarted }
}

@MainActor
@Suite("AppKit editor integration", .serialized)
struct AppKitEditorTests {
    private let url = URL(fileURLWithPath: "/native-editor-test.txt")

    private func makePane(io: NativeEditorTestIO) async -> EditorPaneViewController {
        let session = EditorDocumentSession(io: io)
        let pane = EditorPaneViewController(state: EditorState(), rootPath: nil, session: session)
        pane.updatePresentation(isActive: true, isSelected: true)
        pane.openFile(url)
        await session.waitForPendingWork()
        return pane
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }

    @Test("Quick-open resets selection for a new query and preserves it for the same-query refresh")
    func quickOpenSelectionTracksQueryIntent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["AAAConfig.txt", "BetaConfig.txt", "Config.txt"] {
            try Data("example".utf8).write(to: root.appendingPathComponent(name))
        }
        let finder = FileFinder()
        let pane = EditorPaneViewController(state: EditorState(), rootPath: root.path, finder: finder)
        defer { pane.closePane() }
        pane.updatePresentation(isActive: true, isSelected: true)
        let table = try #require(descendants(pane.view).compactMap { $0 as? NSTableView }.first)
        let search = try #require(descendants(pane.view).compactMap { $0 as? NSSearchField }.first)
        func name(at row: Int) -> String? {
            guard row >= 0, let cell = pane.tableView(table, viewFor: table.tableColumns.first, row: row) else { return nil }
            return descendants(cell).compactMap { ($0 as? NSTextField)?.stringValue }.first
        }
        try await waitUntil { table.numberOfRows == 3 }
        let initialBetaIndex = try #require(finder.results.firstIndex { $0.name == "BetaConfig.txt" })
        table.selectRowIndexes(IndexSet(integer: initialBetaIndex), byExtendingSelection: false)

        search.stringValue = "config"
        pane.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        try await waitUntil { finder.resultsQuery == "config" && name(at: 0) == "Config.txt" }
        #expect(table.selectedRow == 0)

        let rankedBetaIndex = try #require(finder.results.firstIndex { $0.name == "BetaConfig.txt" })
        table.selectRowIndexes(IndexSet(integer: rankedBetaIndex), byExtendingSelection: false)
        try Data("another match".utf8).write(to: root.appendingPathComponent("ConfigExtra.txt"))
        finder.start(root: root.path)
        try await waitUntil { table.numberOfRows == 4 }
        #expect(name(at: table.selectedRow) == "BetaConfig.txt")

        // This query has the same results; an equality-coalesced publication
        // must still reset selection and Return must open the top-ranked file.
        search.stringValue = "CONFIG"
        pane.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        #expect(table.selectedRow == 0)
        try await waitUntil { finder.resultsQuery == "CONFIG" && name(at: 0) == "Config.txt" }
        #expect(pane.control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        await pane.session.waitForPendingWork()
        #expect(pane.session.url?.resolvingSymlinksInPath()
            == root.appendingPathComponent("Config.txt").resolvingSymlinksInPath())
    }

    @Test("Native find and replacement controls edit the real document with undo")
    func nativeFindAndReplace() async throws {
        let pane = await makePane(io: NativeEditorTestIO())
        defer { pane.closePane() }
        let editor = try #require(pane.children.compactMap { $0 as? TextViewController }.first)
        let baseInset = editor.scrollView.contentInsets.top
        #expect(baseInset == (editor.configuration.layout.contentInsets?.top ?? 0)
            + (editor.configuration.layout.additionalTextInsets?.top ?? 0))
        editor.showNativeFindPanel(replacing: true)
        let find = try #require(editor.findViewController)
        #expect(editor.scrollView.contentInsets.top == baseInset + 54)
        let fields = descendants(find.findPanel).compactMap { $0 as? NSTextField }
        let search = try #require(fields.first { $0 is NSSearchField })
        let replacement = try #require(fields.first { $0.placeholderString == "Replace with" })

        search.stringValue = "alpha"
        find.findPanel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        #expect(find.viewModel.findMatches == [NSRange(location: 0, length: 5), NSRange(location: 11, length: 5)])
        replacement.stringValue = "omega"
        find.findPanel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: replacement))
        let replaceAll = try #require(descendants(find.findPanel).compactMap { $0 as? NSButton }.first { $0.title == "All" })
        let action = try #require(replaceAll.action)
        #expect(NSApp.sendAction(action, to: replaceAll.target, from: replaceAll))
        #expect(editor.text == "omega beta omega")
        #expect(pane.session.text == editor.text)
        #expect(pane.session.isDirty)
        editor.textView.undoManager?.undo()
        #expect(editor.text == "alpha beta alpha")
        #expect(pane.session.text == editor.text)

        #expect(!descendants(pane.view).contains {
            let name = NSStringFromClass(type(of: $0))
            return name.contains("NSHostingView") || name.contains("NSHostingController")
        })
        #expect(find.view.subviews.last === find.findPanel)
        find.hideFindPanel(animated: false)
        #expect(editor.scrollView.contentInsets.top == baseInset)
        find.hideFindPanel(animated: false)
        #expect(editor.scrollView.contentInsets.top == baseInset)
        find.showFindPanel(animated: false)
        #expect(editor.scrollView.contentInsets.top == baseInset + 28)
    }

    @Test("Workspace detachment preserves the editor, selection and unsaved buffer")
    func detachmentPreservesNativeEditor() async throws {
        let pane = await makePane(io: NativeEditorTestIO())
        defer { pane.closePane() }
        let editor = try #require(pane.children.compactMap { $0 as? TextViewController }.first)
        editor.textView.replaceCharacters(in: NSRange(location: 0, length: 5), with: "edited")
        let documentID = pane.session.document?.id
        let selection = editor.cursorPositions
        pane.updatePresentation(isActive: false, isSelected: false)
        pane.updatePresentation(isActive: true, isSelected: true)
        #expect(pane.children.contains { $0 === editor })
        #expect(pane.session.document?.id == documentID)
        #expect(pane.session.text == "edited beta alpha")
        #expect(pane.session.isDirty)
        #expect(editor.cursorPositions == selection)
    }

    @Test("Workspace detachment preserves an in-progress input-method composition")
    func detachmentPreservesMarkedText() async throws {
        let pane = await makePane(io: NativeEditorTestIO())
        defer { pane.closePane() }
        let editor = try #require(pane.children.compactMap { $0 as? TextViewController }.first)
        #expect(editor.textView.selectedRange() == NSRange(location: 0, length: 0))
        editor.textView.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0),
                                     replacementRange: NSRange(location: 0, length: 5))
        #expect(editor.textView.hasMarkedText())
        let markedRange = editor.textView.markedRange()
        pane.updatePresentation(isActive: false, isSelected: false)
        pane.updatePresentation(isActive: true, isSelected: true)
        #expect(editor.textView.hasMarkedText())
        #expect(editor.textView.markedRange() == markedRange)
        editor.textView.insertText("仮名", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!editor.textView.hasMarkedText())
        #expect(pane.session.text == "仮名 beta alpha")
    }

    @Test("Closing an untouched document neither writes nor conflicts with external changes", arguments: [false, true])
    func cleanDocumentClosesWithoutWriting(externallyChanged: Bool) async {
        let io = NativeEditorTestIO()
        let pane = await makePane(io: io)
        defer { pane.closePane() }
        await io.setFailWrites()
        if externallyChanged { await io.simulateExternalEdit() }
        #expect(!pane.session.isDirty)
        let mayClose = await withCheckedContinuation { continuation in
            pane.prepareToClose { continuation.resume(returning: $0) }
        }
        #expect(mayClose)
        #expect(await io.hasStartedWrite() == false)
        #expect(pane.session.errorMessage == nil)
        #expect(!pane.session.conflictPending)
    }

    @Test("Close preflight saves an in-progress input-method edit")
    func closeSavesMarkedText() async throws {
        let io = NativeEditorTestIO()
        let pane = await makePane(io: io)
        defer { pane.closePane() }
        let editor = try #require(pane.children.compactMap { $0 as? TextViewController }.first)
        editor.textView.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0),
                                     replacementRange: NSRange(location: 0, length: 5))
        #expect(editor.textView.hasMarkedText())
        #expect(pane.session.isDirty)
        let mayClose = await withCheckedContinuation { continuation in
            pane.prepareToClose { continuation.resume(returning: $0) }
        }
        #expect(mayClose)
        #expect(await io.hasStartedWrite())
        #expect(pane.session.text == "かな beta alpha")
        #expect(!pane.session.isDirty)
    }

    @Test("A failed save vetoes pane close and retains the dirty buffer")
    func failedSaveVetoesClose() async {
        let io = NativeEditorTestIO()
        let pane = await makePane(io: io)
        await io.setFailWrites()
        pane.session.updateText("unsaved")
        let mayClose = await withCheckedContinuation { continuation in
            pane.prepareToClose { continuation.resume(returning: $0) }
        }
        #expect(!mayClose)
        #expect(pane.session.isDirty)
        #expect(pane.session.text == "unsaved")
        #expect(pane.session.errorMessage != nil)
    }

    @Test("Typing while close saves is retained and vetoes close")
    func typingDuringCloseSaveVetoesClose() async {
        let io = NativeEditorTestIO()
        let pane = await makePane(io: io)
        pane.session.updateText("first revision")
        await io.suspendWrites()
        let closing = Task { @MainActor in
            await withCheckedContinuation { continuation in
                pane.prepareToClose { continuation.resume(returning: $0) }
            }
        }
        while !(await io.hasStartedWrite()) { await Task.yield() }
        pane.session.updateText("newer revision")
        await io.releaseWrite()
        #expect(await closing.value == false)
        #expect(pane.session.isDirty)
        #expect(pane.session.text == "newer revision")
        pane.closePane()
        await pane.session.waitForPendingWork()
    }
}
