import Foundation
import Testing
@testable import Pilot

// MARK: - Controlled I/O

/// A one-shot latch that records arrivals, so a test can wait until I/O has
/// reached it and then decide when it may proceed.
private actor Gate {
    private var isOpen = false
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        arrivals += 1
        arrivalWaiters.forEach { $0.resume() }
        arrivalWaiters.removeAll()
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func arrived() async {
        guard arrivals == 0 else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }
}

private struct InjectedWriteFailure: LocalizedError {
    var errorDescription: String? { "Disk full" }
}

private actor ControlledEditorFileIO: EditorFileIO {
    private var files: [URL: (data: Data, date: Date)] = [:]
    private var readGates: [URL: Gate] = [:]
    private var writeGate: Gate?
    private var failWrites = false
    private(set) var reads: [URL] = []
    private(set) var writes: [(url: URL, data: Data)] = []
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    func put(_ text: String, at url: URL) {
        clock += 1
        files[url] = (Data(text.utf8), clock)
    }

    func touchExternally(_ url: URL) {
        guard let file = files[url] else { return }
        clock += 1
        files[url] = (file.data, clock)
    }

    func gateRead(_ url: URL) -> Gate {
        let gate = Gate()
        readGates[url] = gate
        return gate
    }

    func gateWrites() -> Gate {
        let gate = Gate()
        writeGate = gate
        return gate
    }

    func setFailWrites(_ fail: Bool) { failWrites = fail }

    func contents(of url: URL) -> String? {
        files[url].map { String(decoding: $0.data, as: UTF8.self) }
    }

    func read(_ url: URL, maxBytes: Int) async throws -> EditorFileContents {
        reads.append(url)
        if let gate = readGates[url] { await gate.pass() }
        guard let file = files[url] else { throw CocoaError(.fileNoSuchFile) }
        guard file.data.count <= maxBytes else { throw EditorFileReadError.tooLarge }
        return EditorFileContents(data: file.data, modificationDate: file.date)
    }

    func modificationDate(of url: URL) async -> Date? {
        files[url]?.date
    }

    func write(_ data: Data, to url: URL) async throws -> Date? {
        if let writeGate { await writeGate.pass() }
        if failWrites { throw InjectedWriteFailure() }
        clock += 1
        files[url] = (data, clock)
        writes.append((url, data))
        return clock
    }
}

@MainActor
private final class PathStore: EditorFilePathStore {
    var persistedFileURL: URL?
    private(set) var persistCount = 0

    init(_ url: URL? = nil) { persistedFileURL = url }

    func persistOpenFile(_ url: URL?) {
        persistedFileURL = url
        persistCount += 1
    }
}

@MainActor
private final class OutcomeLog {
    var outcomes: [String: EditorLoadOutcome] = [:]

    func record(_ key: String) -> @MainActor (EditorLoadOutcome) -> Void {
        { [weak self] outcome in self?.outcomes[key] = outcome }
    }
}

// MARK: - Race and failure tests

@MainActor
@Suite("Editor document session")
struct EditorDocumentSessionTests {
    private let fileA = URL(fileURLWithPath: "/workspace/a.swift")
    private let fileB = URL(fileURLWithPath: "/workspace/b.swift")

    @Test("A slow open of A followed by a fast open of B leaves B selected")
    func delayedOpenCannotReplaceNewerSelection() async {
        let io = ControlledEditorFileIO()
        await io.put("alpha", at: fileA)
        await io.put("bravo", at: fileB)
        let gateA = await io.gateRead(fileA)
        let session = EditorDocumentSession(io: io)
        let log = OutcomeLog()

        session.requestOpen(fileA, completion: log.record("a"))
        await gateA.arrived()
        session.requestOpen(fileB, completion: log.record("b"))
        await session.waitForPendingWork()
        #expect(session.url == fileB)

        await gateA.open()
        // Let the stale read finish and attempt to publish.
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))

        #expect(session.url == fileB)
        #expect(session.text == "bravo")
        #expect(log.outcomes["a"] == nil)
        #expect(log.outcomes["b"] == .loaded(fileB))
    }

    @Test("Closing the pane prevents a late load from publishing")
    func closePreventsLatePublication() async {
        let io = ControlledEditorFileIO()
        await io.put("alpha", at: fileA)
        let gateA = await io.gateRead(fileA)
        let store = PathStore()
        let session = EditorDocumentSession(io: io)
        session.attach(store: store)
        let log = OutcomeLog()

        session.requestOpen(fileA, completion: log.record("a"))
        await gateA.arrived()
        session.close()
        await gateA.open()
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))

        #expect(session.document == nil)
        #expect(session.text.isEmpty)
        #expect(log.outcomes.isEmpty)
        #expect(store.persistCount == 0)
    }

    @Test("A failed outgoing save keeps the dirty buffer and blocks the switch")
    func failedOutgoingSaveBlocksSwitch() async {
        let io = ControlledEditorFileIO()
        await io.put("alpha", at: fileA)
        await io.put("bravo", at: fileB)
        let session = EditorDocumentSession(io: io)
        #expect(await session.open(fileA) == .loaded(fileA))

        session.updateText("alpha edited")
        await io.setFailWrites(true)
        let outcome = await session.open(fileB)

        guard case .blockedBySave(.failed) = outcome else {
            Issue.record("Expected a blocked switch, got \(outcome)")
            return
        }
        #expect(session.url == fileA)
        #expect(session.text == "alpha edited")
        #expect(session.isDirty)
        #expect(session.errorMessage?.contains("Disk full") == true)
        #expect(await io.reads == [fileA])
        #expect(await io.contents(of: fileA) == "alpha")

        // Recoverable: once the disk accepts writes, the same buffer saves.
        await io.setFailWrites(false)
        #expect(await session.save(.interactive) == .saved)
        #expect(await io.contents(of: fileA) == "alpha edited")
        #expect(!session.isDirty)
    }

    @Test("A conflicted outgoing save keeps the dirty buffer and blocks the switch")
    func conflictedOutgoingSaveBlocksSwitch() async {
        let io = ControlledEditorFileIO()
        await io.put("alpha", at: fileA)
        await io.put("bravo", at: fileB)
        let session = EditorDocumentSession(io: io)
        await session.open(fileA)

        session.updateText("alpha edited")
        await io.touchExternally(fileA)
        let outcome = await session.open(fileB)

        #expect(outcome == .blockedBySave(.conflict))
        #expect(session.url == fileA)
        #expect(session.text == "alpha edited")
        #expect(session.isDirty)
        #expect(session.errorMessage == "“a.swift” changed on disk — not auto-saved.")
        #expect(!session.conflictPending)
        #expect(await io.writes.isEmpty)

        // ⌘S raises the conflict prompt; Overwrite then succeeds.
        #expect(await session.save(.interactive) == .conflict)
        #expect(session.conflictPending)
        #expect(await session.save(.overwrite) == .saved)
        #expect(await io.contents(of: fileA) == "alpha edited")
        #expect(!session.isDirty)
    }

    @Test("A successful outgoing save lets the switch proceed")
    func successfulOutgoingSaveSwitches() async {
        let io = ControlledEditorFileIO()
        await io.put("alpha", at: fileA)
        await io.put("bravo", at: fileB)
        let session = EditorDocumentSession(io: io)
        await session.open(fileA)
        session.updateText("alpha edited")

        #expect(await session.open(fileB) == .loaded(fileB))
        #expect(await io.contents(of: fileA) == "alpha edited")
        #expect(session.text == "bravo")
        #expect(!session.isDirty)
    }

    @Test("Edits made while a save is in flight stay dirty")
    func editsDuringSaveRemainDirty() async {
        let io = ControlledEditorFileIO()
        await io.put("alpha", at: fileA)
        let session = EditorDocumentSession(io: io)
        await session.open(fileA)

        session.updateText("first")
        let gate = await io.gateWrites()
        session.requestSave(.interactive)
        await gate.arrived()
        session.updateText("second")
        await gate.open()
        await session.waitForPendingWork()

        #expect(await io.contents(of: fileA) == "first")
        #expect(session.text == "second")
        #expect(session.isDirty)

        #expect(await session.save(.automatic) == .saved)
        #expect(await io.contents(of: fileA) == "second")
        #expect(!session.isDirty)
        #expect(await session.save(.automatic) == .clean)
    }

    @Test("Echoed identical text from the editor does not mark the buffer dirty")
    func identicalTextIsNotAnEdit() async {
        let io = ControlledEditorFileIO()
        await io.put("alpha", at: fileA)
        let session = EditorDocumentSession(io: io)
        #expect(!session.updateText("typed before any document"))
        await session.open(fileA)

        #expect(!session.updateText("alpha"))
        #expect(!session.isDirty)
        #expect(session.updateText("alpha!"))
        #expect(session.isDirty)
    }

    @Test("Successful loads persist the path; a failed restore clears it")
    func persistedPathRestoration() async {
        let io = ControlledEditorFileIO()
        await io.put("alpha", at: fileA)
        let missing = URL(fileURLWithPath: "/workspace/deleted.swift")

        let store = PathStore(missing)
        let session = EditorDocumentSession(io: io)
        session.attach(store: store)
        let outcome = await session.open(missing)
        guard case .failed = outcome else {
            Issue.record("Expected failure, got \(outcome)")
            return
        }
        #expect(store.persistedFileURL == nil)

        await session.open(fileA)
        #expect(store.persistedFileURL == fileA)

        // Failing to open some other file leaves the persisted path alone.
        _ = await session.open(missing)
        #expect(store.persistedFileURL == fileA)
        #expect(session.url == fileA)
    }

    @Test("Closing a dirty pane flushes the buffer")
    func closeFlushesDirtyBuffer() async {
        let io = ControlledEditorFileIO()
        await io.put("alpha", at: fileA)
        let session = EditorDocumentSession(io: io)
        await session.open(fileA)
        session.updateText("flushed")

        session.close()
        await session.waitForPendingWork()

        #expect(await io.contents(of: fileA) == "flushed")
        #expect(!session.isDirty)
    }

    @Test("Binary sniffing and encoding fallback")
    func binaryAndEncodingHeuristics() {
        #expect(EditorDocumentIO.looksBinary(Data([0x41, 0x00, 0x42])))
        #expect(!EditorDocumentIO.looksBinary(Data("hello\tworld\r\n".utf8)))
        #expect(!EditorDocumentIO.looksBinary(Data()))
        #expect(EditorDocumentIO.decode(Data("é".utf8)).1 == .utf8)
        let (latin1, encoding) = EditorDocumentIO.decode(Data([0x63, 0x61, 0x66, 0xE9]))
        #expect(encoding == .isoLatin1)
        #expect(latin1 == "café")
    }
}

// MARK: - Live file-system behavior

@MainActor
@Suite("Editor document session on disk")
struct EditorDocumentSessionDiskTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorDocumentSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("Saving through a symlink replaces the target and keeps the link")
    func symlinkResolution() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let link = directory.appendingPathComponent("link.txt")
        try Data("one".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let session = EditorDocumentSession()
        #expect(await session.open(link) == .loaded(link))
        session.updateText("two")
        #expect(await session.save(.interactive) == .saved)
        // The re-baseline must describe the same file the guard checks, or the
        // second save would read our own write as an external change.
        session.updateText("three")
        #expect(await session.save(.interactive) == .saved)

        let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(try String(contentsOf: target, encoding: .utf8) == "three")
    }

    @Test("Latin-1 files are written back in Latin-1")
    func originalEncodingPreserved() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("legacy.txt")
        try Data([0x63, 0x61, 0x66, 0xE9]).write(to: file)

        let session = EditorDocumentSession()
        await session.open(file)
        #expect(session.text == "café")
        session.updateText("café!")
        #expect(await session.save(.interactive) == .saved)
        #expect(try Data(contentsOf: file) == Data([0x63, 0x61, 0x66, 0xE9, 0x21]))
    }

    @Test("An external change is not overwritten by a save")
    func externalChangeDetected() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("shared.txt")
        try Data("ours".utf8).write(to: file)

        let session = EditorDocumentSession()
        await session.open(file)
        session.updateText("ours, edited")
        try Data("theirs".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: file.path
        )

        #expect(await session.save(.automatic) == .conflict)
        #expect(try String(contentsOf: file, encoding: .utf8) == "theirs")
        #expect(session.isDirty)

        let reloaded = await session.open(file, discardingChanges: true)
        #expect(reloaded == .loaded(file))
        #expect(session.text == "theirs")
        #expect(!session.isDirty)
    }

    @Test("Size, binary, and non-regular-file guards")
    func loadGuards() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oversized = directory.appendingPathComponent("big.txt")
        try Data(repeating: 0x61, count: EditorDocumentIO.maxEditableBytes + 1).write(to: oversized)
        let binary = directory.appendingPathComponent("blob.bin")
        try Data([0x00, 0x01, 0x02]).write(to: binary)

        let session = EditorDocumentSession()
        #expect(await session.open(oversized) == .tooLarge)
        #expect(await session.open(binary) == .binary)
        let directoryOutcome = await session.open(directory)
        guard case .failed = directoryOutcome else {
            Issue.record("Expected a directory to be refused, got \(directoryOutcome)")
            return
        }
        #expect(session.document == nil)
    }

    /// Near-limit file: opens and saves with the decode/encode/write work off
    /// the main actor. Records the longest main-actor stall observed while each
    /// operation runs next to the time the pre-session code spent blocking the
    /// main actor for the same work (decode + binary sniff on load; encode +
    /// atomic write on save).
    @Test("Near-limit file loads and saves without blocking the main actor")
    func nearLimitResponsiveness() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("large.swift")
        let line = "let value = \"near-limit editor buffer ✓\" // padding padding\n"
        let lineBytes = line.utf8.count
        let lineCount = (EditorDocumentIO.maxEditableBytes - 1_000) / lineBytes
        let original = String(repeating: line, count: lineCount)
        try Data(original.utf8).write(to: file)
        let byteCount = original.utf8.count
        #expect(byteCount <= EditorDocumentIO.maxEditableBytes)

        // Before: the old view decoded and sniffed on the main actor after an
        // off-main read, and encoded + wrote synchronously from the view.
        let rawData = try Data(contentsOf: file)
        let clock = ContinuousClock()
        let legacyLoad = clock.measure {
            _ = EditorDocumentIO.looksBinary(rawData)
            _ = EditorDocumentIO.decode(rawData)
        }
        let legacyCopy = directory.appendingPathComponent("legacy-copy.swift")
        let legacySave = try clock.measure {
            let data = (original + "x").data(using: .utf8)
            try data?.write(to: legacyCopy, options: .atomic)
        }

        // After: the session, with a main-actor ticker measuring stalls.
        let session = EditorDocumentSession()
        let loadStall = await maxMainActorStall {
            #expect(await session.open(file) == .loaded(file))
        }
        #expect(session.text.utf8.count == byteCount)

        session.updateText(session.text + "x")
        let saveStall = await maxMainActorStall {
            #expect(await session.save(.interactive) == .saved)
        }
        #expect(!session.isDirty)
        #expect(try Data(contentsOf: file).count == byteCount + 1)

        let report = """
        editor-responsiveness bytes=\(byteCount) \
        legacyMainActorLoad=\(legacyLoad) sessionMaxStallLoad=\(loadStall) \
        legacyMainActorSave=\(legacySave) sessionMaxStallSave=\(saveStall)
        """
        print(report)
        let reportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("made-editor-responsiveness.txt")
        try? Data((report + "\n").utf8).write(to: reportURL)
    }

    /// Longest gap between 1 ms main-actor ticks (minus the tick) while `work`
    /// runs; approximates how long the UI could not process events.
    private func maxMainActorStall(_ work: @MainActor () async -> Void) async -> Duration {
        let clock = ContinuousClock()
        var running = true
        let ticker = Task { @MainActor () -> Duration in
            var worst = Duration.zero
            var last = clock.now
            while running {
                try? await Task.sleep(for: .milliseconds(1))
                let now = clock.now
                worst = max(worst, now - last - .milliseconds(1))
                last = now
            }
            return worst
        }
        await Task.yield()
        await work()
        running = false
        return await ticker.value
    }
}
