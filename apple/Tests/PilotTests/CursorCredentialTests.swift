import Foundation
import SQLite3
import Testing
@testable import Pilot

@Suite("Cursor desktop credentials")
struct CursorCredentialTests {
    // Synthetic JWT encrypted with Electron's macOS v10 format and a test key.
    private static let stored = "cursor-safe-storage:v1:"
        + "djEwoKC7vNRT4TN9oiQQNHHK42r//XC3X1sJlkm2VU2qQSwOTGJIQ0QN8PzCHdZCMlIa"
        + "Qxywl3clGN53FQWXl13OaePDvmQP2md4dQseNOa7St1hXVya926AuTyDmrw8iTthIyXtnrIPhTGYDmjmXArW0w=="

    @Test("Encrypted desktop credentials retain the original JWT identity and expiration")
    func encryptedSession() throws {
        let session = try UsageSessions.CursorSession.decodeStoredToken(Self.stored, password: { "fixture-password" })
        #expect(session.userId == "test|cursor")
        #expect(session.expiresAt == Date(timeIntervalSince1970: 1_900_000_000))
        #expect(CursorUsageAdapter.cookie(for: session).hasPrefix("WorkosCursorSessionToken=test%7Ccursor%3A%3A"))
        #expect(!session.accessToken.contains(CursorSafeStorage.prefix))
        #expect(session.isExpired(at: Date(timeIntervalSince1970: 1_900_000_001)))
    }

    @Test("Keychain denial and invalid ciphertext produce different actionable errors")
    func unreadableCredentials() {
        #expect(throws: UsageSessions.CursorSession.LoadError.keychainUnavailable) {
            try UsageSessions.CursorSession.decodeStoredToken(Self.stored, password: { nil })
        }
        #expect(throws: UsageSessions.CursorSession.LoadError.unreadableToken) {
            try UsageSessions.CursorSession.decodeStoredToken(Self.stored, password: { "wrong-password" })
        }
        for invalid in ["cursor-safe-storage:v1:not base64", "cursor-safe-storage:v1:djExYWJj", "cursor-safe-storage:v1:djEw"] {
            #expect(CursorSafeStorage.decrypt(invalid, password: "fixture-password") == nil)
        }
    }

    @Test("Legacy plaintext credentials never access Keychain")
    func plaintextSession() throws {
        let plaintext = try #require(CursorSafeStorage.decrypt(Self.stored, password: "fixture-password"))
        let session = try UsageSessions.CursorSession.decodeStoredToken(plaintext) {
            Issue.record("Plaintext sessions must not read Keychain")
            return nil
        }
        #expect(session.userId == "test|cursor")
        #expect(throws: UsageSessions.CursorSession.LoadError.unreadableToken) {
            try UsageSessions.CursorSession.decodeStoredToken("not-a-token") {
                Issue.record("Unknown formats must not read Keychain")
                return nil
            }
        }
    }

    @Test("Loading a session leaves Cursor's state database unchanged")
    func databaseReadOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.vscdb")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT, value TEXT)", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(db, "INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', '\(Self.stored)')", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let before = try Data(contentsOf: url)
        let session = try UsageSessions.CursorSession.loadChecked(databaseURL: url, password: { "fixture-password" })
        #expect(session.userId == "test|cursor")
        #expect(try Data(contentsOf: url) == before)
        #expect(throws: UsageSessions.CursorSession.LoadError.missingDatabase) {
            try UsageSessions.CursorSession.loadChecked(databaseURL: directory.appendingPathComponent("missing")) {
                Issue.record("A missing installation must not read Keychain")
                return nil
            }
        }
    }
}
