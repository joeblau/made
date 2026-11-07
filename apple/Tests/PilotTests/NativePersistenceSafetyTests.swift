import Foundation
import SwiftData
import XCTest
@testable import Pilot

final class NativePersistenceSafetyTests: XCTestCase {
    @MainActor
    func testBackupPreservesBaseAndSidecarsWithoutMovingTheLiveStore() throws {
        let fixture = try StoreFiles()
        defer { fixture.remove() }
        let bytes = ["": Data("base database fixture".utf8),
                     "-wal": Data("uncheckpointed note edits".utf8),
                     "-shm": Data("shared memory fixture".utf8)]
        try fixture.write(bytes)
        CockpitPersistence.backUpStore(at: fixture.store, fileManager: .default)
        let backup = try XCTUnwrap(fixture.backups().first)
        for (suffix, expected) in bytes {
            XCTAssertEqual(try Data(contentsOf: fixture.file(suffix)), expected)
            XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("default.store" + suffix)), expected)
            try FileManager.default.removeItem(at: fixture.file(suffix))
        }
        for (suffix, expected) in bytes {
            XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("default.store" + suffix)), expected,
                           "The backup must remain recoverable after the live files disappear")
        }
    }

    @MainActor
    func testWALOnlyEditsProduceAnotherRecoverableBackup() throws {
        let fixture = try StoreFiles()
        defer { fixture.remove() }
        let originalWAL = Data("old uncheckpointed edits".utf8)
        let updatedWAL = Data("new uncheckpointed edits containing another note".utf8)
        try fixture.write(["": Data("unchanged base".utf8), "-wal": originalWAL, "-shm": Data([1, 2, 3])])
        CockpitPersistence.backUpStore(at: fixture.store, fileManager: .default)
        let originalBackup = try XCTUnwrap(fixture.backups().first)
        try updatedWAL.write(to: fixture.file("-wal"), options: .atomic)
        CockpitPersistence.backUpStore(at: fixture.store, fileManager: .default)
        let backups = try fixture.backups()
        XCTAssertEqual(backups.count, 2, "SQLite may update its WAL without changing the base database")
        XCTAssertEqual(try Data(contentsOf: originalBackup.appendingPathComponent("default.store-wal")), originalWAL)
        XCTAssertTrue(try backups.contains {
            try Data(contentsOf: $0.appendingPathComponent("default.store-wal")) == updatedWAL
        }, "The newest edits must be present in a backup")
    }

    @MainActor
    func testRapidChangedBackupsPreserveEveryVersionWithinRetention() throws {
        let fixture = try StoreFiles()
        defer { fixture.remove() }
        let versions = (1...5).map { Data(String(repeating: "fixture version \($0) ", count: $0).utf8) }
        for version in versions {
            try fixture.write(["": version, "-wal": version + Data(" WAL".utf8), "-shm": Data([1])])
            CockpitPersistence.backUpStore(at: fixture.store, fileManager: .default)
        }
        let stored = try fixture.backups().map { try Data(contentsOf: $0.appendingPathComponent("default.store")) }
        XCTAssertEqual(stored.count, versions.count, "Multiple launches in one second must not reuse a backup directory")
        for version in versions { XCTAssertTrue(stored.contains(version)) }
    }

    @MainActor
    func testFailedSidecarCopyKeepsOldBackupAndCanRetry() throws {
        let fixture = try StoreFiles()
        defer { fixture.remove() }
        let original = Data("previous recoverable database".utf8)
        try fixture.write(["": original, "-wal": Data("original WAL".utf8)])
        CockpitPersistence.backUpStore(at: fixture.store, fileManager: .default)
        let first = try XCTUnwrap(fixture.backups().first)
        let updated = Data("updated database with additional rows".utf8)
        let updatedWAL = Data("updated WAL".utf8)
        try fixture.write(["": updated, "-wal": updatedWAL])
        CockpitPersistence.backUpStore(at: fixture.store, fileManager: RejectWALCopyFileManager())
        XCTAssertEqual(try fixture.backups(), [first])
        XCTAssertEqual(try Data(contentsOf: first.appendingPathComponent("default.store")), original)
        XCTAssertEqual(try Data(contentsOf: fixture.store), updated)

        CockpitPersistence.backUpStore(at: fixture.store, fileManager: .default)
        let retried = try XCTUnwrap(fixture.backups().last)
        XCTAssertEqual(try fixture.backups().count, 2)
        XCTAssertEqual(try Data(contentsOf: retried.appendingPathComponent("default.store")), updated)
        XCTAssertEqual(try Data(contentsOf: retried.appendingPathComponent("default.store-wal")), updatedWAL)
    }

    @MainActor
    func testFailedOpenPreservesTheDatabaseInsteadOfStartingAnEmptyStore() throws {
        let fixture = try StoreFiles()
        defer { fixture.remove() }
        let schema = Schema(versionedSchema: PilotSchemaV4.self)
        let configuration = ModelConfiguration(schema: schema, url: fixture.store)
        let original = Data("unreadable SQLite database: irreplaceable recovery fixture".utf8)
        try original.write(to: fixture.store)
        for _ in 0..<2 {
            XCTAssertThrowsError(try CockpitPersistence.makeModelContainer(
                schema: schema, migrationPlan: PilotMigrationPlan.self, configuration: configuration))
            XCTAssertEqual(try Data(contentsOf: fixture.store), original)
            XCTAssertTrue(try fixture.quarantines().isEmpty)
        }
    }
}

private final class RejectWALCopyFileManager: FileManager, @unchecked Sendable {
    override func copyItem(at source: URL, to destination: URL) throws {
        if source.lastPathComponent.hasSuffix("-wal") { throw CocoaError(.fileReadNoPermission) }
        try super.copyItem(at: source, to: destination)
    }
}

private struct StoreFiles {
    let directory: URL
    var store: URL { file("") }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cockpit-persistence-safety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func file(_ suffix: String) -> URL { directory.appendingPathComponent("default.store" + suffix) }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func write(_ contents: [String: Data]) throws {
        for (suffix, data) in contents { try data.write(to: file(suffix), options: .atomic) }
    }
    func backups() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("Backups", isDirectory: true), includingPropertiesForKeys: nil
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    func quarantines() throws -> [String: Data] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try Dictionary(uniqueKeysWithValues: files.filter { $0.pathExtension == "corrupt" }.map {
            ($0.lastPathComponent, try Data(contentsOf: $0))
        })
    }
}
