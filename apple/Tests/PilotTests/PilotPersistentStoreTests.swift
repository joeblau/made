import Foundation
import SwiftData
import Testing
@testable import Pilot

/// Exercises the launch-time store path that `PilotApp` delegates to
/// `PilotPersistentStore`: legacy rescue, pre-open backup, open/migrate, and
/// quarantine-and-recover. Every test runs in its own temporary directory and
/// never touches the developer's real store.
@Suite("Pilot persistent store startup", .serialized)
@MainActor
struct PilotPersistentStoreTests {
    @Test("An existing current-schema store is backed up and reopens without data loss")
    func existingStoreRestoresThroughStartupPath() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("default.store")

        let ids = try autoreleasepool { () throws -> (workspace: UUID, note: UUID) in
            let container = try openCurrentContainer(at: storeURL)
            let workspace = Workspace(name: "Restored Workspace")
            workspace.rootPath = "/tmp/restored-repository"
            let note = Note(body: "Restored note\nsecond line", sortOrder: 2)
            container.mainContext.insert(workspace)
            container.mainContext.insert(note)
            try container.mainContext.save()
            return (workspace.id, note.id)
        }

        PilotPersistentStore.backUpStore(at: storeURL, fileManager: .default)
        let backups = try backupDirectories(in: directory)
        #expect(backups.count == 1)
        let backup = try #require(backups.first)
        #expect(FileManager.default.fileExists(atPath: backup.appendingPathComponent("default.store").path))

        try autoreleasepool {
            let container = startupContainer(at: storeURL)
            let workspaces = try container.mainContext.fetch(FetchDescriptor<Workspace>())
            let notes = try container.mainContext.fetch(FetchDescriptor<Note>())
            #expect(workspaces.map(\.id) == [ids.workspace])
            #expect(workspaces.first?.name == "Restored Workspace")
            #expect(workspaces.first?.rootPath == "/tmp/restored-repository")
            #expect(notes.map(\.id) == [ids.note])
            #expect(notes.first?.body == "Restored note\nsecond line")
            #expect(notes.first?.sortOrder == 2)
        }
        #expect(try quarantinedFiles(in: directory).isEmpty)
    }

    @Test("A shipped V1 store migrates through the startup path instead of being quarantined")
    func v1StoreMigratesThroughStartupPath() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("default.store")

        let noteID = try autoreleasepool { () throws -> UUID in
            let schema = Schema(versionedSchema: PilotSchemaV1.self)
            let container = try ModelContainer(
                for: schema,
                migrationPlan: V1OnlyPlan.self,
                configurations: ModelConfiguration(schema: schema, url: storeURL)
            )
            let note = PilotSchemaV1.Note()
            note.body = "Shipped V1 note"
            container.mainContext.insert(note)
            try container.mainContext.save()
            return note.id
        }

        try autoreleasepool {
            let container = startupContainer(at: storeURL)
            let notes = try container.mainContext.fetch(FetchDescriptor<Note>())
            #expect(notes.map(\.id) == [noteID])
            #expect(notes.first?.body == "Shipped V1 note")
        }
        #expect(try quarantinedFiles(in: directory).isEmpty)
    }

    @Test("Unchanged stores are not re-backed up and history is pruned to the retention limit")
    func backupDeduplicatesAndPrunes() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileManager = FileManager.default
        let storeURL = directory.appendingPathComponent("default.store")
        try Data("store-v1".utf8).write(to: storeURL)
        try Data("wal".utf8).write(to: directory.appendingPathComponent("default.store-wal"))

        PilotPersistentStore.backUpStore(at: storeURL, fileManager: fileManager)
        PilotPersistentStore.backUpStore(at: storeURL, fileManager: fileManager)
        let firstPass = try backupDirectories(in: directory)
        #expect(firstPass.count == 1)
        let first = try #require(firstPass.first)
        #expect(try Data(contentsOf: first.appendingPathComponent("default.store-wal")) == Data("wal".utf8))

        // Older history beyond the retention window, then a changed store.
        let backupsRoot = directory.appendingPathComponent("Backups", isDirectory: true)
        for index in 1...PilotPersistentStore.maxStoreBackups {
            let old = backupsRoot.appendingPathComponent(String(format: "%012d", index), isDirectory: true)
            try fileManager.createDirectory(at: old, withIntermediateDirectories: true)
        }
        try fileManager.removeItem(at: first)
        try Data("store-v2-changed".utf8).write(to: storeURL)
        PilotPersistentStore.backUpStore(at: storeURL, fileManager: fileManager)

        let pruned = try backupDirectories(in: directory)
        #expect(pruned.count == PilotPersistentStore.maxStoreBackups)
        #expect(!pruned.contains { $0.lastPathComponent == String(format: "%012d", 1) })
        let newest = try #require(pruned.last)
        #expect(try Data(contentsOf: newest.appendingPathComponent("default.store")) == Data("store-v2-changed".utf8))
    }

    @Test("Unreadable stores are quarantined under unique names and a fresh store opens")
    func unreadableStoreIsQuarantinedWithoutOverwritingEarlierCopies() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("default.store")
        let payloads = [Data("not a sqlite store #1".utf8), Data("not a sqlite store #2".utf8)]

        for payload in payloads {
            try payload.write(to: storeURL)
            try autoreleasepool {
                let container = startupContainer(at: storeURL)
                container.mainContext.insert(Note(body: "fresh"))
                try container.mainContext.save()
            }
            // Leave the next iteration a corrupt base again.
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(
                    at: directory.appendingPathComponent("default.store\(suffix)")
                )
            }
        }

        let quarantined = try quarantinedFiles(in: directory)
            .filter { $0.lastPathComponent.hasPrefix("default.store.") }
        #expect(quarantined.count == 2)
        let contents = try Set(quarantined.map { try Data(contentsOf: $0) })
        #expect(contents == Set(payloads))
    }

    @Test("Legacy rescue copies the newest legacy store with sidecars and leaves sources intact")
    func legacyStoreRescueCopiesNewestCandidate() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileManager = FileManager.default
        let appSupport = root.appendingPathComponent("AppSupport", isDirectory: true)
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let directory = appSupport.appendingPathComponent("Pilot", isDirectory: true)
        let sandboxDirectory = home.appendingPathComponent(
            "Library/Containers/app.blau.pilot/Data/Library/Application Support",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sandboxDirectory, withIntermediateDirectories: true)

        let rootStore = appSupport.appendingPathComponent("default.store")
        try Data("root-era".utf8).write(to: rootStore)
        try Data("root-wal".utf8).write(to: appSupport.appendingPathComponent("default.store-wal"))
        let sandboxStore = sandboxDirectory.appendingPathComponent("default.store")
        try Data("sandbox-era".utf8).write(to: sandboxStore)
        try fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -86_400)],
            ofItemAtPath: sandboxStore.path
        )
        // An orphan sidecar from an aborted earlier run must not survive.
        try Data("orphan".utf8).write(to: directory.appendingPathComponent("default.store-shm"))

        let storeURL = directory.appendingPathComponent("default.store")
        PilotPersistentStore.migrateLegacyStoreIfNeeded(
            to: directory,
            storeURL: storeURL,
            fileManager: fileManager,
            homeDirectory: home
        )

        #expect(try Data(contentsOf: storeURL) == Data("root-era".utf8))
        #expect(try Data(contentsOf: directory.appendingPathComponent("default.store-wal")) == Data("root-wal".utf8))
        #expect(!fileManager.fileExists(atPath: directory.appendingPathComponent("default.store-shm").path))
        #expect(!fileManager.fileExists(atPath: directory.appendingPathComponent("default.store.import").path))
        #expect(try Data(contentsOf: rootStore) == Data("root-era".utf8))
        #expect(try Data(contentsOf: sandboxStore) == Data("sandbox-era".utf8))

        // An existing store is never replaced by a later rescue attempt.
        try Data("current".utf8).write(to: storeURL)
        PilotPersistentStore.migrateLegacyStoreIfNeeded(
            to: directory,
            storeURL: storeURL,
            fileManager: fileManager,
            homeDirectory: home
        )
        #expect(try Data(contentsOf: storeURL) == Data("current".utf8))
    }

    // MARK: - Helpers

    private enum V1OnlyPlan: SchemaMigrationPlan {
        static var schemas: [any VersionedSchema.Type] { [PilotSchemaV1.self] }
        static var stages: [MigrationStage] { [] }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pilot-persistent-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func openCurrentContainer(at storeURL: URL) throws -> ModelContainer {
        let schema = PilotPersistentStore.currentSchema
        return try ModelContainer(
            for: schema,
            migrationPlan: PilotMigrationPlan.self,
            configurations: ModelConfiguration(schema: schema, url: storeURL)
        )
    }

    /// The same open call `PilotPersistentStore.makeContainer` performs after
    /// its single-instance check and store-location resolution.
    private func startupContainer(at storeURL: URL) -> ModelContainer {
        let schema = PilotPersistentStore.currentSchema
        return PilotPersistentStore.makeModelContainer(
            schema: schema,
            migrationPlan: PilotMigrationPlan.self,
            configuration: ModelConfiguration(schema: schema, url: storeURL),
            storeURL: storeURL
        )
    }

    private func backupDirectories(in directory: URL) throws -> [URL] {
        let root = directory.appendingPathComponent("Backups", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func quarantinedFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "corrupt" }
    }
}
