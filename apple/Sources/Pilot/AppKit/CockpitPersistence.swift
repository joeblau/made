import AppKit
import SwiftData

@MainActor
enum CockpitPersistence {
    /// If another Pilot process is already running, bring it forward and exit
    /// quietly instead of racing it for the store. Opt out for deliberate
    /// multi-instance development with the launch args
    /// `-allowMultipleInstances YES` (each instance then needs its own store
    /// via a distinct $HOME or it will still corrupt reads).
    static func yieldToExistingInstanceIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "allowMultipleInstances") else { return }
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != currentPID && !$0.isTerminated }
        guard let existing else { return }
        existing.activate()
        exit(0)
    }

    /// Pilot runs unsandboxed (so Ghostty can launch real shell processes), so
    /// it owns `~/Library/Application Support` directly. Earlier builds wrote the
    /// SwiftData store into the *sandbox container* at
    /// `~/Library/Containers/app.blau.pilot/Data/…`; once unsandboxed, every
    /// access to that path makes macOS treat us as reaching into another app's
    /// data and throws a "would like to access data from other apps" prompt — on
    /// every launch, since the store reopens each time. Keep the store in
    /// Application Support instead, and migrate the old one over once so existing
    /// notes/workspaces carry across.
    static func persistentStoreURL() -> URL {
        let fileManager = FileManager.default
        let appSupport = (try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let directory = appSupport.appendingPathComponent("Pilot", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent("default.store")

        migrateLegacyStoreIfNeeded(to: directory, storeURL: storeURL, fileManager: fileManager)
        return storeURL
    }

    /// One-time copy of the SwiftData store out of an older location, run only
    /// when the new store is absent.
    ///
    /// There are two legacy locations to rescue, because the store has moved
    /// twice:
    ///   1. `~/Library/Application Support/default.store` — the unsandboxed-era
    ///      store, written there by `ModelConfiguration` before the move into
    ///      the `Pilot/` subdirectory. This is where most existing users' data
    ///      actually lives, and missing it orphaned real workspaces/notes.
    ///   2. `~/Library/Containers/app.blau.pilot/.../default.store` — the
    ///      original sandbox-container store (pre-unsandboxing).
    /// Whichever exists and was modified most recently wins, so the freshest
    /// data is the one carried across.
    ///
    /// It *copies* (never moves) so a denied or failed migration leaves the
    /// legacy data intact and retryable rather than destroyed, and it commits the
    /// base `.store` LAST via an atomic same-volume rename: SQLite only ever sees
    /// the new store appear with its WAL/SHM sidecars already in place, never an
    /// orphan `-wal` next to an empty store (which it would read as a malformed
    /// image and crash on). Any failure rolls the partial copy back so the next
    /// launch retries from a clean slate.
    private static func migrateLegacyStoreIfNeeded(to directory: URL, storeURL: URL, fileManager: FileManager) {
        guard !fileManager.fileExists(atPath: storeURL.path) else { return }

        let stagedStore = directory.appendingPathComponent("default.store.import")
        let sidecars = ["-wal", "-shm"].map { directory.appendingPathComponent("default.store\($0)") }
        func rollback() {
            try? fileManager.removeItem(at: stagedStore)
            for sidecar in sidecars { try? fileManager.removeItem(at: sidecar) }
        }
        // The base store is absent, so any sidecars/staging present here are
        // orphans from a prior aborted run. Clear them up front — before the
        // legacy-present check below can early-return — so SQLite is never handed
        // a `-wal` next to a missing base (a "malformed image"), whatever happens
        // to the legacy source.
        rollback()

        // Candidate legacy stores. `directory` is `…/Application Support/Pilot`,
        // so its parent is the unsandboxed-era root location.
        let rootAppSupportStore = directory.deletingLastPathComponent()
            .appendingPathComponent("default.store")
        let sandboxStore = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Containers/app.blau.pilot/Data/Library/Application Support/default.store", isDirectory: true)

        func modificationDate(_ url: URL) -> Date {
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            return (attributes?[.modificationDate] as? Date) ?? .distantPast
        }
        let candidates = [rootAppSupportStore, sandboxStore]
            .filter { fileManager.fileExists(atPath: $0.path) }
        guard let legacyStore = candidates.max(by: { modificationDate($0) < modificationDate($1) }) else { return }
        let legacyDirectory = legacyStore.deletingLastPathComponent()

        do {
            // Copy the base to a staging name and the sidecars to their final
            // names; the base is committed last so it never appears half-built.
            try fileManager.copyItem(at: legacyStore, to: stagedStore)
            for suffix in ["-wal", "-shm"] {
                let source = legacyDirectory.appendingPathComponent("default.store\(suffix)")
                guard fileManager.fileExists(atPath: source.path) else { continue }
                try fileManager.copyItem(at: source, to: directory.appendingPathComponent("default.store\(suffix)"))
            }
            // Commit: the base store appears only now, with sidecars in place.
            try fileManager.moveItem(at: stagedStore, to: storeURL)
        } catch {
            rollback()
        }
    }

    /// Number of timestamped store backups to retain. Enough that a handful of
    /// rapid relaunches can't prune away the last known-good copy.
    private static let maxStoreBackups = 15

    /// Copy the on-disk store (base + WAL + SHM) into a timestamped folder under
    /// `Pilot/Backups/` before it is opened, then prune to `maxStoreBackups`.
    ///
    /// This is the data-loss backstop: notes and workspaces can only be lost if
    /// *every* copy is gone, and this guarantees a recent copy always survives an
    /// open or migration that goes wrong — independent of the corruption handler.
    /// It copies (never moves) and tolerates every failure silently: a backup is
    /// best-effort insurance and must never block the app from launching.
    static func backUpStore(at storeURL: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: storeURL.path) else { return }
        let directory = storeURL.deletingLastPathComponent()
        let backupsRoot = directory.appendingPathComponent("Backups", isDirectory: true)
        let storeName = storeURL.lastPathComponent

        // SQLite can commit edits solely to the WAL. Compare every member of
        // the store family before treating a launch as unchanged.
        guard let currentSignature = storeSignature(storeURL, fileManager: fileManager) else { return }
        if let newest = backupDirectories(in: backupsRoot, fileManager: fileManager).last,
           storeSignature(newest.appendingPathComponent(storeName), fileManager: fileManager) == currentSignature {
            return
        }

        // Publish only a complete copy. A failed sidecar copy must not prune a
        // good backup or leave a partial directory that suppresses the retry.
        let staging = backupsRoot.appendingPathComponent(".pending-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] {
                let source = directory.appendingPathComponent(storeName + suffix)
                guard suffix.isEmpty || fileManager.fileExists(atPath: source.path) else { continue }
                try fileManager.copyItem(at: source, to: staging.appendingPathComponent(storeName + suffix))
            }
            let stamp = String(format: "%012lld", Int64(Date().timeIntervalSince1970))
            var bump = 0
            while true {
                let name = stamp + (bump == 0 ? "" : String(format: "-%06d", bump))
                let destination = backupsRoot.appendingPathComponent(name, isDirectory: true)
                do {
                    try fileManager.moveItem(at: staging, to: destination)
                    break
                } catch {
                    guard fileManager.fileExists(atPath: destination.path) else { throw error }
                    bump += 1
                }
            }
        } catch {
            return
        }

        // Prune only completed, timestamped backups after a successful copy.
        let backups = backupDirectories(in: backupsRoot, fileManager: fileManager)
        if backups.count > maxStoreBackups {
            for old in backups.prefix(backups.count - maxStoreBackups) {
                try? fileManager.removeItem(at: old)
            }
        }
    }

    private static func backupDirectories(in directory: URL, fileManager: FileManager) -> [URL] {
        ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter {
                $0.lastPathComponent.range(of: #"^\d{12}(?:-\d{6,})?$"#, options: .regularExpression) != nil
                    && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Cheap content fingerprint (byte size + modification time) for the store
    /// family, including absent sidecars, used to avoid unchanged backups.
    private static func storeSignature(_ url: URL, fileManager: FileManager) -> String? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return ["", "-wal", "-shm"].map { suffix in
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path + suffix) else { return "missing" }
            let size = (attributes[.size] as? Int) ?? -1
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            return "\(size)-\(modified)"
        }.joined(separator: ";")
    }

    /// The schema version the running app reads and writes. Adding a version
    /// means a new frozen `PilotSchemaV<n>`, a stage in `PilotMigrationPlan`,
    /// and a change here — nowhere else.
    static var currentSchema: Schema { Schema(versionedSchema: PilotSchemaV4.self) }

    /// Open the on-disk store exactly as launch does: back up the store family,
    /// then open it with the current schema and the full migration plan so a
    /// store written by any shipped version migrates forward. Throws rather than
    /// substituting an empty store; the backup taken here survives a failed or
    /// lossy migration.
    static func openStore(at storeURL: URL, fileManager: FileManager = .default) throws -> ModelContainer {
        backUpStore(at: storeURL, fileManager: fileManager)
        let schema = currentSchema
        // Released pre-Drone V3 stores need their own plan; others use the default.
        return try makeModelContainer(
            schema: schema, migrationPlan: PilotMigrationPlan.forStore(at: storeURL),
            configuration: ModelConfiguration(schema: schema, url: storeURL))
    }

    /// An isolated, memory-only store with the current schema (fixtures and
    /// screenshot runs never touch the user's database).
    static func openInMemoryStore() throws -> ModelContainer {
        let schema = currentSchema
        return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    /// A migration, permissions, or disk error does not mean the data is corrupt.
    /// Propagate the failure so startup can explain it and stop. Never move the
    /// user's database aside or silently substitute an empty/ephemeral store.
    static func makeModelContainer(
        schema: Schema,
        migrationPlan: (any SchemaMigrationPlan.Type)?,
        configuration: ModelConfiguration
    ) throws -> ModelContainer {
        try ModelContainer(for: schema, migrationPlan: migrationPlan, configurations: configuration)
    }

}
