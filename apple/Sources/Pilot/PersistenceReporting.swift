import Foundation
import OSLog
import SwiftData

struct PersistenceFailure: Identifiable {
    let id = UUID()
    let operation: String
    let message: String
}

extension Notification.Name {
    static let pilotPersistenceSaveFailed = Notification.Name("app.blau.pilot.persistence-save-failed")
}

private final class PersistenceFailureDeduplicator: @unchecked Sendable {
    private let lock = NSLock()
    private var lastFingerprint: String?
    private var lastNotificationDate: Date?

    func shouldNotify(operation: String, error: Error, now: Date = Date()) -> Bool {
        let fingerprint = "\(operation)|\(String(reflecting: type(of: error)))|\(error.localizedDescription)"
        lock.lock()
        defer { lock.unlock() }
        if fingerprint == lastFingerprint,
           let lastNotificationDate,
           now.timeIntervalSince(lastNotificationDate) < 5 {
            return false
        }
        lastFingerprint = fingerprint
        lastNotificationDate = now
        return true
    }
}

private let persistenceFailureDeduplicator = PersistenceFailureDeduplicator()

extension ModelContext {
    /// Saves earlier pending work before a destructive change begins (#437).
    ///
    /// `rollback()` discards every pending change in the context, not just the
    /// destructive caller's. Failed non-destructive edits (for example note text
    /// from the debounced Notes save) stay pending for retry, so a later failed
    /// delete would silently revert them. Every `rollbackOnFailure: true` caller
    /// must call this first and refuse the destructive change when it returns
    /// `false`; the earlier edits then stay pending and nothing is deleted.
    /// When it returns `true` the context has no pending changes, so a rollback
    /// of the destructive save discards only that operation's own changes.
    func saveEarlierChangesBeforeDestructiveChange(
        operation: String,
        performSave: (ModelContext) throws -> Void = { try $0.save() }
    ) -> Bool {
        guard hasChanges else { return true }
        return saveReporting(operation: operation, performSave: performSave)
    }

    /// Saves without pretending failure is success. Non-destructive edits stay
    /// in memory so the user can retry; destructive callers request rollback to
    /// restore the deleted models when durability cannot be guaranteed. A
    /// rollback discards everything pending, so destructive callers must first
    /// clear earlier work with `saveEarlierChangesBeforeDestructiveChange`.
    @discardableResult
    func saveReporting(
        operation: String = "Saving Cockpit data",
        rollbackOnFailure: Bool = false,
        performSave: (ModelContext) throws -> Void = { try $0.save() }
    ) -> Bool {
        do {
            try performSave(self)
            return true
        } catch {
            if rollbackOnFailure { rollback() }
            let message = error.localizedDescription
            Logger(subsystem: "app.blau.pilot", category: "Persistence")
                .error(
                    "Operation failed: \(operation, privacy: .public); error type: \(String(reflecting: type(of: error)), privacy: .public)"
                )
            if persistenceFailureDeduplicator.shouldNotify(operation: operation, error: error) {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .pilotPersistenceSaveFailed,
                        object: nil,
                        userInfo: ["operation": operation, "message": message]
                    )
                }
            }
            return false
        }
    }
}
