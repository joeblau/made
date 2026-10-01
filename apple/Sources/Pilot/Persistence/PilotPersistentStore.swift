import AppKit
import SwiftData

/// Startup ownership of Pilot's on-disk SwiftData store: single-instance
/// enforcement, legacy-location rescue, pre-open backups, and the
/// quarantine-and-recover open path. `PilotApp` asks for one container at
/// launch; everything that can touch the user's store file lives here.
@MainActor
enum PilotPersistentStore {
    /// The newest versioned schema. The store is stamped with this version and
    /// `PilotMigrationPlan` governs upgrades to it.
    static var currentSchema: Schema {
        Schema(versionedSchema: PilotSchemaV3.self)
    }

    /// Opens the container for this launch. Ordering is load-bearing: yield to
    /// an existing instance, rescue a legacy store, and back the store up
    /// before anything opens it.
    static func makeContainer(isRunningTests: Bool) -> ModelContainer {
        let schema = currentSchema
        if isRunningTests {
            // A hosted unit-test launch must never open, back up, migrate, or
            // quarantine the developer's real Pilot store. It can also deadlock
            // behind a normally running Pilot process. Keep the test host fully
            // isolated and ephemeral.
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: configuration)
        }
        // Two live Pilot processes must never share the SwiftData store:
        // a second instance reading while the first checkpoints the WAL
        // fatals deep inside model getters (PersistentModel.getValue).
        // Finder launches are single-instance via LaunchServices, but
        // direct executable launches (Xcode debug runs, CLI) bypass that
        // — enforce it here, before the store is ever opened.
        yieldToExistingInstanceIfNeeded()
        let storeURL = persistentStoreURL()
        // Safety net: copy the on-disk store aside BEFORE opening it, so a failed
        // open or migration can never be the only thing standing between the user
        // and their workspaces/notes. Runs before `makeModelContainer` on purpose.
        backUpStore(at: storeURL, fileManager: .default)
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        return makeModelContainer(
            schema: schema,
            migrationPlan: PilotMigrationPlan.self,
            configuration: configuration,
            storeURL: storeURL
        )
    }

    /// If another Pilot process is already running, bring it forward and exit
    /// quietly instead of racing it for the store. Opt out for deliberate
    /// multi-instance development with the launch args
    /// `-allowMultipleInstances YES` (each instance then needs its own store
    /// via a distinct $HOME or it will still corrupt reads).
    private static func yieldToExistingInstanceIfNeeded() {
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
    private static func persistentStoreURL() -> URL {
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
    ///
    /// `homeDirectory` exists so tests can stage a fake sandbox container; the
    /// app always passes the real home directory.
    static func migrateLegacyStoreIfNeeded(
        to directory: URL,
        storeURL: URL,
        fileManager: FileManager,
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) {
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
        let sandboxStore = homeDirectory
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
    static let maxStoreBackups = 15

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

        // Skip if the newest backup already matches the current store (size +
        // mtime), so repeated launches with no changes don't churn the history.
        let currentSignature = storeSignature(storeURL, fileManager: fileManager)
        if let newest = (try? fileManager.contentsOfDirectory(at: backupsRoot, includingPropertiesForKeys: nil))?
            .filter({ (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
            .max(by: { $0.lastPathComponent < $1.lastPathComponent }),
           storeSignature(newest.appendingPathComponent("default.store"), fileManager: fileManager) == currentSignature {
            return
        }

        let stamp = Int(Date().timeIntervalSince1970)
        let destination = backupsRoot.appendingPathComponent(String(format: "%012d", stamp), isDirectory: true)
        guard (try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)) != nil else { return }
        for suffix in ["", "-wal", "-shm"] {
            let source = directory.appendingPathComponent("default.store\(suffix)")
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try? fileManager.copyItem(at: source, to: destination.appendingPathComponent("default.store\(suffix)"))
        }

        // Prune oldest backups beyond the retention count.
        if let backups = try? fileManager.contentsOfDirectory(at: backupsRoot, includingPropertiesForKeys: nil) {
            let sorted = backups
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if sorted.count > maxStoreBackups {
                for old in sorted.prefix(sorted.count - maxStoreBackups) {
                    try? fileManager.removeItem(at: old)
                }
            }
        }
    }

    /// Cheap content fingerprint (byte size + modification time) for the store
    /// base file, used to avoid making identical back-to-back backups.
    private static func storeSignature(_ url: URL, fileManager: FileManager) -> String? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attributes[.size] as? Int) ?? -1
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return "\(size)-\(modified)"
    }

    /// Open the store, but never let a corrupt/unreadable one crash every launch:
    /// on failure, quarantine the on-disk store aside and start fresh so the app
    /// still opens. The quarantined files are preserved for manual recovery, and
    /// `backUpStore` has already saved a copy aside before this runs.
    ///
    /// Quarantine names are unique per failure (timestamped). A fixed
    /// `default.store.corrupt` name was catastrophic: a *second* failed open
    /// would delete the first quarantine before writing its own, so two bad
    /// launches in a row (e.g. across two schema changes) destroyed the only
    /// surviving copy of the user's data. Never delete an existing quarantine.
    static func makeModelContainer(
        schema: Schema,
        migrationPlan: (any SchemaMigrationPlan.Type)?,
        configuration: ModelConfiguration,
        storeURL: URL
    ) -> ModelContainer {
        do {
            return try ModelContainer(for: schema, migrationPlan: migrationPlan, configurations: configuration)
        } catch {
            let fileManager = FileManager.default
            let directory = storeURL.deletingLastPathComponent()
            let stamp = Int(Date().timeIntervalSince1970)
            for suffix in ["", "-wal", "-shm"] {
                let file = directory.appendingPathComponent("default.store\(suffix)")
                guard fileManager.fileExists(atPath: file.path) else { continue }
                // Find a quarantine name that does not already exist; never
                // overwrite a prior quarantine — it may be the last good copy.
                var quarantined = directory.appendingPathComponent("default.store\(suffix).\(stamp).corrupt")
                var bump = 1
                while fileManager.fileExists(atPath: quarantined.path) {
                    quarantined = directory.appendingPathComponent("default.store\(suffix).\(stamp)-\(bump).corrupt")
                    bump += 1
                }
                try? fileManager.moveItem(at: file, to: quarantined)
            }
            if let fresh = try? ModelContainer(for: schema, migrationPlan: migrationPlan, configurations: configuration) {
                return fresh
            }
            // Last resort when even a fresh on-disk store can't be created (disk
            // full, unwritable directory): an ephemeral in-memory store so the
            // app still opens this session instead of crash-looping every launch.
            return try! ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            )
        }
    }
}
