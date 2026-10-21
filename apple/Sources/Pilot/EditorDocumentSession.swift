import CodeEditLanguages
import Foundation

// MARK: - File I/O seam

/// Bytes and metadata read for one editor document.
struct EditorFileContents: Sendable {
    let data: Data
    /// Modification date of the resolved file, captured before its bytes were
    /// read so a concurrent writer surfaces as a conflict rather than being
    /// silently absorbed into the baseline.
    let modificationDate: Date?
}

enum EditorFileReadError: Error, Sendable {
    case tooLarge
    case notRegularFile
}

/// Disk access used by `EditorDocumentSession`. Every method is called off the
/// main actor. Implementations resolve symbolic links themselves so the size
/// guard, conflict baseline, and atomic replacement all describe the same file.
protocol EditorFileIO: Sendable {
    /// Read at most `maxBytes`; throw `EditorFileReadError.tooLarge` beyond it.
    func read(_ url: URL, maxBytes: Int) async throws -> EditorFileContents
    func modificationDate(of url: URL) async -> Date?
    /// Atomically replace the file and return its new modification date.
    func write(_ data: Data, to url: URL) async throws -> Date?
}

struct LiveEditorFileIO: EditorFileIO {
    func read(_ url: URL, maxBytes: Int) async throws -> EditorFileContents {
        let target = url.resolvingSymlinksInPath()
        let values = try target.resourceValues(forKeys: [
            .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
        ])
        // FIFOs and devices would block or stream forever.
        guard values.isRegularFile == true else { throw EditorFileReadError.notRegularFile }
        if let size = values.fileSize, size > maxBytes { throw EditorFileReadError.tooLarge }

        // The file can grow between stat and read; bound the allocation anyway.
        let handle = try FileHandle(forReadingFrom: target)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else { throw EditorFileReadError.tooLarge }
        return EditorFileContents(data: data, modificationDate: values.contentModificationDate)
    }

    func modificationDate(of url: URL) async -> Date? {
        try? url.resolvingSymlinksInPath()
            .resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
    }

    func write(_ data: Data, to url: URL) async throws -> Date? {
        // Replace the link's target, not the link itself.
        let target = url.resolvingSymlinksInPath()
        try data.write(to: target, options: .atomic)
        return try? target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

/// Pure, nonisolated load/save steps. `EditorDocumentSession` runs these on
/// detached tasks so decoding, encoding, and disk I/O of up to
/// `maxEditableBytes` never execute on the main actor.
enum EditorDocumentIO {
    /// CodeEditSourceEditor is not built for multi-megabyte buffers.
    static let maxEditableBytes = 10_000_000

    struct LoadedFile: Sendable {
        let contents: String
        let encoding: String.Encoding
        let modificationDate: Date?
    }

    enum LoadResult: Sendable {
        case loaded(LoadedFile)
        case tooLarge
        case binary
        case failed(String)
    }

    enum WriteResult: Sendable {
        case written(modificationDate: Date?)
        case conflict
        case failed(String)
    }

    static func load(_ url: URL, io: any EditorFileIO, maxBytes: Int = maxEditableBytes) async -> LoadResult {
        let contents: EditorFileContents
        do {
            contents = try await io.read(url, maxBytes: maxBytes)
        } catch EditorFileReadError.tooLarge {
            return .tooLarge
        } catch EditorFileReadError.notRegularFile {
            return .failed("Not a regular file.")
        } catch {
            return .failed(error.localizedDescription)
        }
        if looksBinary(contents.data) { return .binary }
        let (text, encoding) = decode(contents.data)
        return .loaded(LoadedFile(contents: text, encoding: encoding, modificationDate: contents.modificationDate))
    }

    /// Encode and write `text`. Unless `checkConflict` is false (an explicit
    /// overwrite), the write is refused when the file's modification date no
    /// longer matches `baseline` — agents in sibling terminals routinely
    /// rewrite the same files.
    static func write(
        _ text: String,
        encoding: String.Encoding,
        to url: URL,
        baseline: Date?,
        checkConflict: Bool,
        io: any EditorFileIO
    ) async -> WriteResult {
        if checkConflict, baseline != nil, await io.modificationDate(of: url) != baseline {
            return .conflict
        }
        // Preserve the decoded encoding; fall back to UTF-8 when the buffer no
        // longer fits it (e.g. a non-Latin-1 character typed into a Latin-1 file).
        guard let data = text.data(using: encoding) ?? text.data(using: .utf8) else {
            return .failed("The text could not be encoded.")
        }
        do {
            return .written(modificationDate: try await io.write(data, to: url))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Prefer UTF-8 and fall back to Latin-1, which accepts every byte sequence.
    static func decode(_ data: Data) -> (String, String.Encoding) {
        if let utf8 = String(data: data, encoding: .utf8) {
            return (utf8, .utf8)
        }
        return (String(data: data, encoding: .isoLatin1) ?? "", .isoLatin1)
    }

    /// Binary sniff over the first 8 KB: any NUL byte, or more than 30% control
    /// bytes other than tab, LF, and CR.
    static func looksBinary(_ data: Data) -> Bool {
        let sample = data.prefix(8192)
        guard !sample.isEmpty else { return false }
        var controlCount = 0
        for byte in sample {
            if byte == 0x00 { return true }
            if byte < 0x09 || byte == 0x0B || byte == 0x0C || (byte >= 0x0E && byte <= 0x1F) {
                controlCount += 1
            }
        }
        return controlCount * 10 > sample.count * 3
    }
}

// MARK: - Persistence seam

/// Where the open file path is remembered across launches.
@MainActor
protocol EditorFilePathStore: AnyObject {
    var persistedFileURL: URL? { get }
    func persistOpenFile(_ url: URL?)
}

extension EditorState: EditorFilePathStore {
    var persistedFileURL: URL? { fileURL }

    func persistOpenFile(_ url: URL?) {
        filePath = url?.path ?? ""
        // Save immediately so the path survives a relaunch before the
        // container's next autosave tick.
        _ = modelContext?.saveReporting(operation: "Saving editor file state")
    }
}

// MARK: - Session

enum EditorSaveMode: Sendable {
    /// ⌘S: a conflict asks the user (sets `conflictPending`).
    case interactive
    /// File switch / pane close: skipped when clean; a conflict only reports.
    case automatic
    /// The conflict alert's Overwrite action.
    case overwrite
}

enum EditorSaveOutcome: Equatable, Sendable {
    case saved
    /// Nothing to write.
    case clean
    case noDocument
    case conflict
    case failed(String)
}

enum EditorLoadOutcome: Equatable, Sendable {
    case loaded(URL)
    /// The outgoing buffer could not be saved, so the switch did not happen and
    /// the dirty document is still open.
    case blockedBySave(EditorSaveOutcome)
    case tooLarge
    case binary
    case failed(String)
    /// The buffer kept changing while the outgoing save and the read ran, so
    /// the switch gave up rather than replace unsaved edits.
    case blockedByEdits
    /// A newer open request or `close()` replaced this one; nothing was published.
    case superseded

    var isPublishable: Bool { self != .superseded }
}

/// One editor pane's open document: its buffer, revision-tracked dirty state,
/// and the load/save work that feeds it.
///
/// Ownership and ordering:
/// - Every open takes a new generation; a read that finishes after a newer open
///   or `close()` is discarded, so completion order never decides the selection.
/// - Saves are serialized through `saveTask` and hold the session strongly, so
///   a queued flush still runs after the pane releases it. Each snapshots
///   `revision`, and success marks only that revision clean, so edits made
///   while a write is in flight stay dirty.
/// - An open that would replace a dirty buffer saves it first and is blocked
///   (keeping the buffer) when that save does not succeed. The buffer is only
///   replaced after a check, with no suspension before the replacement, that
///   nothing was typed during the save or the read.
@MainActor
@Observable
final class EditorDocumentSession {
    struct Document: Equatable {
        /// Changes on every successful load, including reloads of the same URL.
        let id: UInt64
        let url: URL
        let encoding: String.Encoding
        /// Conflict-guard baseline; nil disables the guard (date unreadable).
        var diskModificationDate: Date?
    }

    private(set) var text = ""
    private(set) var document: Document?
    private(set) var language: CodeLanguage = .default
    /// Bumped on every buffer change; compared with `savedRevision` for dirtiness.
    private(set) var revision: UInt64 = 0
    private(set) var savedRevision: UInt64 = 0
    var errorMessage: String?
    /// Drives the "changed on disk" alert after an interactive save conflict.
    var conflictPending = false

    var isDirty: Bool { document != nil && revision != savedRevision }
    var url: URL? { document?.url }

    @ObservationIgnored private let io: any EditorFileIO
    @ObservationIgnored private weak var store: (any EditorFilePathStore)?
    @ObservationIgnored private var loadGeneration: UInt64 = 0
    @ObservationIgnored private var documentCounter: UInt64 = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<EditorSaveOutcome, Never>?

    init(io: any EditorFileIO = LiveEditorFileIO()) {
        self.io = io
    }

    func attach(store: any EditorFilePathStore) {
        self.store = store
    }

    // MARK: Editing

    /// Apply text coming from the editor. Returns true when it was a real edit.
    @discardableResult
    func updateText(_ newText: String) -> Bool {
        guard document != nil, newText != text else { return false }
        text = newText
        revision &+= 1
        return true
    }

    // MARK: Opening

    /// Start an owned open of `url`. `completion` runs on the main actor unless
    /// the request is superseded by a newer open or by `close()`.
    func requestOpen(
        _ url: URL,
        discardingChanges: Bool = false,
        completion: @escaping @MainActor (EditorLoadOutcome) -> Void = { _ in }
    ) {
        let generation = beginLoad()
        loadTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.performOpen(url, generation: generation, discardingChanges: discardingChanges)
            if outcome.isPublishable { completion(outcome) }
        }
    }

    /// Open `url` and wait for the outcome.
    @discardableResult
    func open(_ url: URL, discardingChanges: Bool = false) async -> EditorLoadOutcome {
        let generation = beginLoad()
        return await performOpen(url, generation: generation, discardingChanges: discardingChanges)
    }

    /// Re-read the current file, discarding the buffer.
    func requestReload(completion: @escaping @MainActor (EditorLoadOutcome) -> Void = { _ in }) {
        guard let url else { return }
        requestOpen(url, discardingChanges: true, completion: completion)
    }

    /// Invalidate pending opens and flush a dirty buffer. The flush keeps the
    /// session alive until it finishes, even if the caller drops it right away;
    /// nothing that was loading is published afterwards.
    func close() {
        _ = beginLoad()
        loadTask = nil
        if isDirty { startSave(.automatic) }
    }

    private func beginLoad() -> UInt64 {
        loadTask?.cancel()
        loadGeneration &+= 1
        return loadGeneration
    }

    /// How many times an open re-saves and re-reads because the buffer changed
    /// underneath it before it gives up with `.blockedByEdits`.
    static let maxOpenAttempts = 3

    private func performOpen(_ url: URL, generation: UInt64, discardingChanges: Bool) async -> EditorLoadOutcome {
        var attempts = 0
        while true {
            attempts += 1
            if !discardingChanges, isDirty {
                let saveOutcome = await save(.automatic)
                guard generation == loadGeneration else { return .superseded }
                switch saveOutcome {
                case .saved, .clean, .noDocument:
                    break
                case .conflict, .failed:
                    return .blockedBySave(saveOutcome)
                }
            }
            guard generation == loadGeneration else { return .superseded }

            let io = io
            let result = await Task.detached(priority: .userInitiated) {
                await EditorDocumentIO.load(url, io: io)
            }.value
            guard generation == loadGeneration, !Task.isCancelled else { return .superseded }

            // Edits typed during the outgoing save or the read must not be
            // replaced. Save them and read again (the read may be of the file
            // just saved); there is no suspension between this check and
            // `apply`, so nothing typed afterwards can be lost.
            if !discardingChanges, isDirty, case .loaded = result {
                if attempts >= Self.maxOpenAttempts {
                    errorMessage = "“\(url.lastPathComponent)” was not opened because this file was still being edited."
                    return .blockedByEdits
                }
                continue
            }
            return publish(result, from: url)
        }
    }

    private func publish(_ result: EditorDocumentIO.LoadResult, from url: URL) -> EditorLoadOutcome {
        let name = url.lastPathComponent
        switch result {
        case .loaded(let file):
            apply(file, from: url)
            return .loaded(url)
        case .tooLarge:
            let limit = EditorDocumentIO.maxEditableBytes / 1_000_000
            errorMessage = "“\(name)” is too large to edit (over \(limit) MB)."
            return .tooLarge
        case .binary:
            errorMessage = "“\(name)” looks like a binary file."
            return .binary
        case .failed(let reason):
            // Stop reopening a moved or deleted file on every launch.
            if let store, url == store.persistedFileURL {
                store.persistOpenFile(nil)
            }
            let message = "Couldn't open “\(name)”: \(reason)"
            errorMessage = message
            return .failed(message)
        }
    }

    private func apply(_ file: EditorDocumentIO.LoadedFile, from url: URL) {
        documentCounter &+= 1
        document = Document(
            id: documentCounter,
            url: url,
            encoding: file.encoding,
            diskModificationDate: file.modificationDate
        )
        text = file.contents
        revision &+= 1
        savedRevision = revision
        language = CodeLanguage.detectLanguageFrom(url: url)
        errorMessage = nil
        conflictPending = false
        store?.persistOpenFile(url)
    }

    // MARK: Saving

    /// Fire-and-forget save; its outcome is reflected in `errorMessage`,
    /// `conflictPending`, and dirty state.
    func requestSave(_ mode: EditorSaveMode) {
        startSave(mode)
    }

    /// Save after any in-flight save finishes, and return this save's outcome.
    @discardableResult
    func save(_ mode: EditorSaveMode) async -> EditorSaveOutcome {
        await startSave(mode).value
    }

    /// Wait for the current load and every queued save.
    func waitForPendingWork() async {
        await loadTask?.value
        while let pending = saveTask {
            _ = await pending.value
            if saveTask == pending { break }
        }
    }

    @discardableResult
    private func startSave(_ mode: EditorSaveMode) -> Task<EditorSaveOutcome, Never> {
        let previous = saveTask
        // Strong capture: a flush from `close()` must still write after the pane
        // drops the session. The task is bounded by one write and releases the
        // session when it ends.
        let task = Task { () -> EditorSaveOutcome in
            _ = await previous?.value
            return await self.performSave(mode)
        }
        saveTask = task
        return task
    }

    private func performSave(_ mode: EditorSaveMode) async -> EditorSaveOutcome {
        guard let document else { return .noDocument }
        if mode == .automatic, !isDirty { return .clean }

        let snapshot = text
        let snapshotRevision = revision
        let io = io
        let result = await Task.detached(priority: .userInitiated) {
            await EditorDocumentIO.write(
                snapshot,
                encoding: document.encoding,
                to: document.url,
                baseline: document.diskModificationDate,
                checkConflict: mode != .overwrite,
                io: io
            )
        }.value

        // A reload may have replaced the document while the write was running.
        let isSameDocument = self.document?.id == document.id
        let name = document.url.lastPathComponent
        switch result {
        case .written(let modificationDate):
            if isSameDocument {
                savedRevision = snapshotRevision
                // Re-baseline so our own write doesn't read back as external.
                self.document?.diskModificationDate = modificationDate
                errorMessage = nil
            }
            return .saved
        case .conflict:
            if isSameDocument {
                if mode == .interactive {
                    conflictPending = true
                } else {
                    errorMessage = "“\(name)” changed on disk — not auto-saved."
                }
            }
            return .conflict
        case .failed(let reason):
            let message = "Couldn't save “\(name)”: \(reason)"
            if isSameDocument { errorMessage = message }
            return .failed(message)
        }
    }
}
