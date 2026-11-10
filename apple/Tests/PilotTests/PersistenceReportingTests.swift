import SwiftData
import Testing
@testable import Pilot

@Suite("Persistence failure recovery")
@MainActor
struct PersistenceReportingTests {
    private enum InjectedFailure: Error {
        case unavailable
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Note.self, configurations: configuration)
        return ModelContext(container)
    }

    @Test("Create failures keep the inserted model available for retry")
    func createFailureKeepsPendingInsert() throws {
        let context = try makeContext()
        let note = Note(body: "pending create")
        context.insert(note)

        let saved = context.saveReporting(operation: "Creating note") { _ in
            throw InjectedFailure.unavailable
        }

        #expect(!saved)
        #expect(try context.fetch(FetchDescriptor<Note>()).contains { $0.id == note.id })
        try context.save()
        #expect(try context.fetch(FetchDescriptor<Note>()).contains { $0.id == note.id })
    }

    @Test("Edit failures keep the unsaved value available for retry")
    func editFailureKeepsPendingValue() throws {
        let context = try makeContext()
        let note = Note(body: "before")
        context.insert(note)
        try context.save()
        note.body = "after"

        let saved = context.saveReporting(operation: "Editing note") { _ in
            throw InjectedFailure.unavailable
        }

        #expect(!saved)
        #expect(note.body == "after")
        try context.save()
        #expect(try context.fetch(FetchDescriptor<Note>()).first?.body == "after")
    }

    @Test("Delete failures roll back instead of pretending deletion was durable")
    func deleteFailureRollsBack() throws {
        let context = try makeContext()
        let note = Note(body: "keep me")
        context.insert(note)
        try context.save()
        context.delete(note)

        let saved = context.saveReporting(
            operation: "Deleting note",
            rollbackOnFailure: true
        ) { _ in
            throw InjectedFailure.unavailable
        }

        #expect(!saved)
        #expect(try context.fetch(FetchDescriptor<Note>()).contains { $0.id == note.id })
    }

    @Test("A failed delete rolls back only its own changes, never an earlier unsaved edit")
    func failedDeleteKeepsEarlierUnsavedEdit() throws {
        let context = try makeContext()
        let edited = Note(body: "before")
        let doomed = Note(body: "delete me")
        context.insert(edited)
        context.insert(doomed)
        try context.save()

        edited.body = "typed while disk full"
        #expect(!context.saveReporting(operation: "Editing note") { _ in
            throw InjectedFailure.unavailable
        })

        // Still failing: the destructive change is refused before it starts.
        #expect(!context.saveEarlierChangesBeforeDestructiveChange(operation: "Deleting note") { _ in
            throw InjectedFailure.unavailable
        })
        #expect(edited.body == "typed while disk full")
        #expect(context.hasChanges)

        // The earlier edit saves, then the delete itself fails and rolls back.
        #expect(context.saveEarlierChangesBeforeDestructiveChange(operation: "Deleting note"))
        #expect(!context.hasChanges)
        context.delete(doomed)
        #expect(!context.saveReporting(operation: "Deleting note", rollbackOnFailure: true) { _ in
            throw InjectedFailure.unavailable
        })

        #expect(edited.body == "typed while disk full")
        let persisted = try ModelContext(context.container).fetch(FetchDescriptor<Note>())
        #expect(persisted.first { $0.id == edited.id }?.body == "typed while disk full")
        #expect(persisted.contains { $0.id == doomed.id })
    }
}
