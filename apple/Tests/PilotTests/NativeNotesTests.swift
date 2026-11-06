import AppKit
import SwiftData
import Testing
@testable import Pilot

@MainActor
@Suite("Native Notes", .serialized)
struct NativeNotesTests {
    @Test("The native editor publishes the final automatic reflow and undoes it as one edit")
    func editorReflowAndUndo() {
        var changes: [String] = []
        let editor = NoteTextView(
            text: "- [ ] alpha\n- [ ] beta", fontSize: 13, wordWrapColumns: 80,
            onChange: { changes.append($0) }
        )
        let window = window(containing: editor)
        defer { window.close() }
        editor.editingUndoManager.groupsByEvent = false
        editor.editingUndoManager.beginUndoGrouping()
        editor.textView.setSelectedRange(NSRange(location: 3, length: 1))
        editor.textView.insertText("x", replacementRange: NSRange(location: 3, length: 1))
        editor.editingUndoManager.endUndoGrouping()

        #expect(editor.textView.string == "- [ ] beta\n- [x] alpha")
        #expect(changes.last == editor.textView.string)
        editor.editingUndoManager.undo()
        #expect(editor.textView.string == "- [ ] alpha\n- [ ] beta")
        #expect(changes.last == editor.textView.string)
    }

    @Test("Identical model updates and wrapping changes preserve the caret and plaintext masking")
    func presentationDoesNotReplaceText() {
        let source = "API_TOKEN=secret-value\nOrdinary prose"
        let editor = NoteTextView(text: source, fontSize: 13, wordWrapColumns: 80)
        let window = window(containing: editor)
        defer { window.close() }
        editor.textView.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        let selection = editor.textView.selectedRanges

        editor.update(text: source, fontSize: 15, wordWrapColumns: 120)

        #expect(editor.textView.string == source)
        #expect(editor.textView.selectedRanges == selection)
        #expect(editor.textView.accessibilityValue()?.contains("secret-value") == false)
        #expect(!editor.scrollView.hasHorizontalScroller)
        editor.update(fontSize: 15, wordWrapColumns: nil)
        #expect(editor.scrollView.hasHorizontalScroller)
        #expect(editor.textView.selectedRanges == selection)
    }

    @Test("Separate native editors have independent undo histories")
    func independentUndo() {
        let first = NoteTextView(text: "First", fontSize: 13, wordWrapColumns: 80)
        let second = NoteTextView(text: "Second", fontSize: 13, wordWrapColumns: 80)
        let window = window(containing: first)
        defer { window.close() }
        first.editingUndoManager.groupsByEvent = false
        first.editingUndoManager.beginUndoGrouping()
        first.textView.insertText("!", replacementRange: NSRange(location: 5, length: 0))
        first.editingUndoManager.endUndoGrouping()
        window.contentView = second

        #expect(first.editingUndoManager.canUndo)
        #expect(!second.editingUndoManager.canUndo)
        first.editingUndoManager.undo()
        #expect(first.textView.string == "First")
        #expect(second.textView.string == "Second")
    }

    @Test("Switching notes retains the recent editor and hiding Notes flushes its pending save")
    func controllerSwitchAndSave() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let first = fixture.store.addNote()
        first.body = "First"
        let second = fixture.store.addNote()
        second.body = "Second"
        _ = fixture.container.mainContext.saveReporting()
        fixture.store.selectedNoteID = first.id
        let controller = NotesViewController(store: fixture.store, defaults: fixture.defaults)
        let window = window(containing: controller.view)
        defer { window.close() }
        controller.refresh()
        let firstEditor = try #require(descendants(controller.view).compactMap { $0 as? NoteTextView }.first)
        firstEditor.textView.setSelectedRange(NSRange(location: 5, length: 0))
        firstEditor.textView.insertText("!", replacementRange: NSRange(location: 5, length: 0))
        #expect(first.body == "First!")

        fixture.store.selectedNoteID = second.id
        controller.refresh()
        #expect(!fixture.container.mainContext.hasChanges)
        fixture.store.selectedNoteID = first.id
        controller.refresh()
        let restored = try #require(descendants(controller.view).compactMap { $0 as? NoteTextView }.first)
        #expect(restored === firstEditor)
        #expect(restored.textView.selectedRange().location == 6)
        restored.textView.insertText("?", replacementRange: NSRange(location: 6, length: 0))
        controller.updatePresentation(isActive: false, isSelected: false)
        #expect(first.body == "First!?")
        #expect(!fixture.container.mainContext.hasChanges)
        #expect(descendants(controller.view).allSatisfy {
            !NSStringFromClass(type(of: $0)).contains("NSHosting")
        })
    }

    @Test("Controller teardown flushes a pending note save and releases observation ownership")
    func controllerTeardownSaves() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let note = fixture.store.addNote()
        var controller: NotesViewController? = NotesViewController(store: fixture.store, defaults: fixture.defaults)
        let editor = try #require(controller.flatMap {
            descendants($0.view).compactMap { $0 as? NoteTextView }.first
        })
        editor.textView.insertText("Saved at teardown", replacementRange: NSRange(location: 0, length: 0))
        weak var weakController = controller

        controller = nil

        #expect(weakController == nil)
        #expect(note.body == "Saved at teardown")
        #expect(!fixture.container.mainContext.hasChanges)
    }

    @Test("Quit preflight commits marked text while the debounce save preserves active composition")
    func markedTextCommit() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let note = fixture.store.addNote()
        let controller = NotesViewController(store: fixture.store, defaults: fixture.defaults)
        let window = window(containing: controller.view)
        defer { window.close() }
        let editor = try #require(descendants(controller.view).compactMap { $0 as? NoteTextView }.first)
        window.makeFirstResponder(editor.textView)
        editor.textView.setMarkedText(
            "日本語", selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        controller.flushPendingSave()
        #expect(editor.textView.hasMarkedText())
        #expect(note.body.isEmpty)

        controller.commitPendingEdits()
        #expect(!editor.textView.hasMarkedText())
        #expect(note.body == "日本語")
        #expect(fixture.container.mainContext.saveReporting(operation: "Saving Cockpit before quit"))
        #expect(!fixture.container.mainContext.hasChanges)
    }

    @Test("Deleting an empty note through the native controller does not ask for confirmation")
    func emptyNoteClose() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let note = fixture.store.addNote()
        let controller = NotesViewController(store: fixture.store, defaults: fixture.defaults)
        _ = controller.view

        controller.closeSelectedNote()

        #expect(fixture.store.notes.allSatisfy { $0.id != note.id })
        #expect(fixture.store.notePendingClose == nil)
    }

    private func window(containing view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        if let editor = view as? NoteTextView { window.makeFirstResponder(editor.textView) }
        return window
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor
    private struct Fixture {
        let container: ModelContainer
        let store: WorkspaceStore
        let defaults: UserDefaults
        let defaultsName: String

        init() throws {
            defaultsName = "app.blau.pilot.native-notes-tests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: defaultsName)!
            let schema = Schema(versionedSchema: PilotSchemaV3.self)
            container = try ModelContainer(
                for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            )
            store = WorkspaceStore(
                modelContext: container.mainContext,
                workspaceGroups: WorkspaceGroups(defaults: defaults), defaults: defaults
            )
        }

        func cleanUp() { defaults.removePersistentDomain(forName: defaultsName) }
    }
}
