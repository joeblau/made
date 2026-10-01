import Darwin
import Foundation

/// Discovers, parses, and deduplicates local agent-CLI usage logs:
///
/// - Claude Code transcripts under `~/.claude/projects` (or
///   `$CLAUDE_CONFIG_DIR/projects`),
/// - Codex rollouts under `~/.codex/sessions` and
///   `~/.codex/archived_sessions` (or `$CODEX_HOME`),
/// - Grok session updates under `~/.grok/sessions` (or `$GROK_HOME`),
/// - Kimi wire logs under `~/.kimi-code` and `~/.kimi`
///   (or `$KIMI_DATA_DIR`).
///
/// The corpus is large (thousands of files, gigabytes of append-only logs),
/// so files parse in parallel off the main actor. Each file keeps a resumable
/// cursor: unchanged files are not read at all, an append reads and parses
/// only the new bytes, and truncation, replacement, or a rewritten prefix
/// falls back to a full rescan of that file. The logs are untrusted input:
/// oversized files and lines are skipped, malformed lines are skipped
/// silently, and no single bad file fails a load.
actor AgenticUsageLoader {
    /// One scan root and the parser its files get.
    struct Source: Sendable {
        let provider: AgenticProvider
        let rootDirectory: URL
        /// Only files with this exact name are parsed; `nil` means every
        /// `.jsonl` file under the root.
        let fileName: String?

        init(provider: AgenticProvider, rootDirectory: URL, fileName: String? = nil) {
            self.provider = provider
            self.rootDirectory = rootDirectory
            self.fileName = fileName
        }
    }

    struct LoadResult: Sendable {
        /// Deduplicated records, sorted by timestamp ascending.
        let records: [AgenticUsageRecord]
        /// Log files discovered across all sources.
        let fileCount: Int
        /// Files that could not be read (or exceeded the size bound).
        let unreadableFileCount: Int
    }

    enum LoadError: Error, LocalizedError {
        case directoryUnreadable(path: String)

        var errorDescription: String? {
            switch self {
            case .directoryUnreadable(let path):
                return "Can't read \(path). Check that Pilot has access to your home folder."
            }
        }
    }

    private struct FileJob: Sendable {
        let path: String
        let url: URL
        let provider: AgenticProvider
        let size: Int
        let modificationDate: Date
    }

    private struct ParseOutcome: Sendable {
        let job: FileJob
        /// `nil` means the file was unreadable.
        let scan: FileScan?
    }

    private struct CacheEntry {
        /// Discovery metadata; an exact match means the file is unchanged.
        let size: Int
        let modificationDate: Date
        let cursor: FileCursor
    }

    /// Bounds on untrusted input. A log file bigger than this, or a single
    /// line bigger than the line bound, is skipped rather than parsed.
    static let maxFileBytes = 512 * 1024 * 1024
    static let maxLineBytes = 16 * 1024 * 1024
    /// Shortest possible line worth decoding.
    static let minLineBytes = 24
    /// Read size for scanning; bounds per-read memory independently of the
    /// file size and spaces cancellation checks.
    static let readChunkBytes = 4 * 1024 * 1024

    private let sources: [Source]
    private var cache: [String: CacheEntry] = [:]
    /// The last merged result and the paths it was built from, reused while
    /// no file's records change.
    private var merged: (paths: [String], records: [AgenticUsageRecord])?
    /// Test seam: runs inside `load()` just before the merge's first
    /// cancellation check, after every file has been scanned.
    private var willMerge: (@Sendable () -> Void)?

    init(sources: [Source] = AgenticUsageLoader.defaultSources()) {
        self.sources = sources
    }

    func setWillMergeHook(_ hook: (@Sendable () -> Void)?) {
        willMerge = hook
    }

    /// The standard scan roots, honoring each CLI's data-dir override.
    nonisolated static func defaultSources(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [Source] {
        func dir(_ variable: String, default defaultPath: String) -> URL {
            if let override = environment[variable], !override.isEmpty {
                return URL(fileURLWithPath: override, isDirectory: true)
            }
            return home.appendingPathComponent(defaultPath, isDirectory: true)
        }
        let codexHome = dir("CODEX_HOME", default: ".codex")
        return [
            Source(
                provider: .claude,
                rootDirectory: dir("CLAUDE_CONFIG_DIR", default: ".claude")
                    .appendingPathComponent("projects", isDirectory: true)
            ),
            Source(
                provider: .codex,
                rootDirectory: codexHome.appendingPathComponent("sessions", isDirectory: true)
            ),
            Source(
                provider: .codex,
                rootDirectory: codexHome.appendingPathComponent("archived_sessions", isDirectory: true)
            ),
            Source(
                provider: .grok,
                rootDirectory: dir("GROK_HOME", default: ".grok")
                    .appendingPathComponent("sessions", isDirectory: true),
                fileName: "updates.jsonl"
            ),
            Source(
                provider: .kimi,
                rootDirectory: dir("KIMI_DATA_DIR", default: ".kimi-code"),
                fileName: "wire.jsonl"
            ),
            Source(
                provider: .kimi,
                rootDirectory: home.appendingPathComponent(".kimi", isDirectory: true),
                fileName: "wire.jsonl"
            ),
        ]
    }

    // MARK: - Loading

    /// Enumerates every source tree and returns the deduplicated record set.
    /// `onProgress` reports (files scanned, total files), throttled, for the
    /// initial determinate progress bar. Cancelling the surrounding task
    /// stops discovery, scanning, decoding, and merging promptly with
    /// `CancellationError` and leaves the cache and the merged result exactly
    /// as the last completed load left them: both are committed together,
    /// after the last cancellation point.
    func load(onProgress: (@Sendable (_ scanned: Int, _ total: Int) -> Void)? = nil) async throws -> LoadResult {
        let files = try discoverFiles()
        guard !files.isEmpty else {
            try Task.checkCancellation()
            cache = [:]
            merged = nil
            return LoadResult(records: [], fileCount: 0, unreadableFileCount: 0)
        }

        // Serve unchanged files from the cache; scan the rest in parallel,
        // resuming each from its cursor. A file moved to a new path (Codex
        // archiving a session) resumes from its old path's cursor when the
        // identity and content fingerprints still match.
        let livePaths = Set(files.map(\.path))
        var orphans: [FileIdentity: FileCursor] = [:]
        for (path, entry) in cache where !livePaths.contains(path) {
            orphans[entry.cursor.identity] = entry.cursor
        }
        var pending: [(job: FileJob, previous: FileCursor?)] = []
        var cachedCount = 0
        for file in files {
            if let entry = cache[file.path] {
                if entry.size == file.size, entry.modificationDate == file.modificationDate {
                    cachedCount += 1
                } else {
                    pending.append((file, entry.cursor))
                }
            } else {
                pending.append((file, nil))
            }
        }
        if !orphans.isEmpty {
            for index in pending.indices where pending[index].previous == nil {
                if let identity = Self.identity(atPath: pending[index].job.path),
                   let cursor = orphans.removeValue(forKey: identity) {
                    pending[index].previous = cursor
                }
            }
        }
        onProgress?(cachedCount, files.count)

        let outcomes = try await Self.parseFiles(
            pending,
            alreadyScanned: cachedCount,
            total: files.count,
            onProgress: onProgress
        )
        try Task.checkCancellation()

        // Build the next cache on a copy. It is committed together with the
        // merge it produced, so a load cancelled anywhere below leaves the
        // cache and `merged` describing the same, last completed load. (A
        // cache committed without its merge would match every file on the
        // next load and serve the stale merge indefinitely.)
        var nextCache = cache
        var unreadableCount = 0
        var recordsChanged = false
        for outcome in outcomes {
            if let scan = outcome.scan {
                recordsChanged = recordsChanged || scan.recordsChanged
                nextCache[outcome.job.path] = CacheEntry(
                    size: outcome.job.size,
                    modificationDate: outcome.job.modificationDate,
                    cursor: scan.cursor
                )
            } else {
                if nextCache.removeValue(forKey: outcome.job.path) != nil { recordsChanged = true }
                unreadableCount += 1
            }
        }

        // Drop cache entries for files deleted since the last load.
        let cachedPaths = nextCache.count
        nextCache = nextCache.filter { livePaths.contains($0.key) }
        if nextCache.count != cachedPaths { recordsChanged = true }

        // Flatten in stable path order so dedup is deterministic, then dedup
        // across ALL files before any date filtering happens. When no file's
        // records changed, the previous merge is still exact.
        let paths = files.map(\.path).filter { nextCache[$0] != nil }
        if !recordsChanged, let merged, merged.paths == paths {
            cache = nextCache
            return LoadResult(
                records: merged.records,
                fileCount: files.count,
                unreadableFileCount: unreadableCount
            )
        }
        var all: [AgenticUsageRecord] = []
        for path in paths {
            if let entry = nextCache[path] {
                all.append(contentsOf: entry.cursor.parser.records)
                all.append(contentsOf: entry.cursor.tailRecords)
            }
        }
        willMerge?()
        try Task.checkCancellation()
        var records = Self.deduplicate(all)
        try Task.checkCancellation()
        records.sort { $0.timestamp < $1.timestamp }
        cache = nextCache
        merged = (paths, records)
        return LoadResult(
            records: records,
            fileCount: files.count,
            unreadableFileCount: unreadableCount
        )
    }

    // MARK: - Discovery

    private func discoverFiles() throws -> [FileJob] {
        var jobs: [FileJob] = []
        for source in sources {
            try discoverFiles(in: source, into: &jobs)
        }
        jobs.sort { $0.path < $1.path }
        return jobs
    }

    private func discoverFiles(in source: Source, into jobs: inout [FileJob]) throws {
        let fileManager = FileManager.default
        let root = source.rootDirectory
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            // A CLI that isn't installed is the empty state, not an error.
            return
        }
        guard fileManager.isReadableFile(atPath: root.path) else {
            throw LoadError.directoryUnreadable(path: root.path)
        }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            throw LoadError.directoryUnreadable(path: root.path)
        }

        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited.isMultiple(of: 256) { try Task.checkCancellation() }
            if let fileName = source.fileName {
                guard url.lastPathComponent == fileName else { continue }
            } else {
                guard url.pathExtension == "jsonl" else { continue }
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            jobs.append(
                FileJob(
                    path: url.path,
                    url: url,
                    provider: source.provider,
                    size: values.fileSize ?? 0,
                    modificationDate: values.contentModificationDate ?? .distantPast
                )
            )
        }
        try Task.checkCancellation()
    }

    // MARK: - Parallel parsing

    private nonisolated static func parseFiles(
        _ jobs: [(job: FileJob, previous: FileCursor?)],
        alreadyScanned: Int,
        total: Int,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> [ParseOutcome] {
        guard !jobs.isEmpty else { return [] }
        let width = min(jobs.count, max(2, ProcessInfo.processInfo.activeProcessorCount))
        return try await withThrowingTaskGroup(of: ParseOutcome.self) { group in
            var outcomes: [ParseOutcome] = []
            outcomes.reserveCapacity(jobs.count)
            var iterator = jobs.makeIterator()
            var scanned = alreadyScanned
            var lastReport = ContinuousClock.now

            for _ in 0..<width {
                guard let next = iterator.next() else { break }
                group.addTask { try Self.parse(next.job, resuming: next.previous) }
            }
            while let outcome = try await group.next() {
                try Task.checkCancellation()
                outcomes.append(outcome)
                scanned += 1
                let now = ContinuousClock.now
                if scanned == total || now - lastReport > .milliseconds(50) {
                    lastReport = now
                    onProgress?(scanned, total)
                }
                if let next = iterator.next() {
                    group.addTask { try Self.parse(next.job, resuming: next.previous) }
                }
            }
            return outcomes
        }
    }

    private nonisolated static func parse(_ job: FileJob, resuming previous: FileCursor?) throws -> ParseOutcome {
        ParseOutcome(job: job, scan: try scanFile(at: job.url, provider: job.provider, resuming: previous))
    }

    // MARK: - Single-file parsing

    /// Device and inode: a renamed file keeps them, a replaced file does not.
    struct FileIdentity: Hashable, Sendable {
        let device: Int64
        let inode: UInt64
    }

    /// Everything needed to resume one file after an append, plus the
    /// fingerprints that prove the already-parsed prefix is still the same.
    struct FileCursor: Sendable {
        let identity: FileIdentity
        let provider: AgenticProvider
        /// The file's modification time when `parser` last caught up.
        var modificationTime: FileTime
        var parser: AgenticUsageLogParser
        /// FNV-1a of the first `headLength` bytes (at most `headBytes`).
        var headLength = 0
        var headHash = Fingerprint.offsetBasis
        /// The last bytes before `parser.consumedBytes` (at most
        /// `boundaryBytes`).
        var boundary = Data()
        /// Provisional records from an unterminated trailing line. They are
        /// re-derived on every scan because the line may still be growing.
        var tailRecords: [AgenticUsageRecord] = []

        static let headBytes = 4096
        static let boundaryBytes = 256

        var records: [AgenticUsageRecord] {
            tailRecords.isEmpty ? parser.records : parser.records + tailRecords
        }

        init(identity: FileIdentity, provider: AgenticProvider, modificationTime: FileTime) {
            self.identity = identity
            self.provider = provider
            self.modificationTime = modificationTime
            self.parser = AgenticUsageLogParser(provider: provider)
        }
    }

    struct FileTime: Equatable, Sendable {
        let seconds: Int
        let nanoseconds: Int

        init(_ time: timespec) {
            seconds = time.tv_sec
            nanoseconds = time.tv_nsec
        }
    }

    struct FileScan: Sendable {
        let cursor: FileCursor
        /// False only when a resumed scan produced exactly the records the
        /// cursor already had.
        let recordsChanged: Bool
        /// True when the scan continued an existing cursor instead of
        /// reparsing the whole file.
        let resumed: Bool
        /// Bytes read from the file by this scan, excluding fingerprint
        /// verification reads.
        let bytesRead: Int
    }

    /// 64-bit FNV-1a, enough to notice a rewritten file prefix.
    enum Fingerprint {
        static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
        static let prime: UInt64 = 0x0000_0100_0000_01b3

        static func hash(_ bytes: UnsafeRawBufferPointer, seed: UInt64) -> UInt64 {
            var hash = seed
            for byte in bytes {
                hash ^= UInt64(byte)
                hash = hash &* prime
            }
            return hash
        }
    }

    private nonisolated static func identity(atPath path: String) -> FileIdentity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileIdentity(device: Int64(info.st_dev), inode: UInt64(info.st_ino))
    }

    /// Scans `url`, continuing `previous` when the file only grew since then
    /// and otherwise parsing from the start. Returns `nil` only when the file
    /// itself can't be read; malformed content inside a readable file yields
    /// whatever records could be salvaged. Throws `CancellationError`.
    nonisolated static func scanFile(
        at url: URL,
        provider: AgenticProvider,
        resuming previous: FileCursor?
    ) throws -> FileScan? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= Int64(maxFileBytes)
        else { return nil }
        let size = Int(info.st_size)
        let identity = FileIdentity(device: Int64(info.st_dev), inode: UInt64(info.st_ino))
        let modificationTime = FileTime(info.st_mtimespec)

        var cursor: FileCursor
        let resumed: Bool
        if let previous, canResume(previous, identity: identity, provider: provider, size: size,
                                   modificationTime: modificationTime, handle: handle) {
            cursor = previous
            resumed = true
        } else {
            cursor = FileCursor(identity: identity, provider: provider, modificationTime: modificationTime)
            resumed = false
        }
        let committedBefore = cursor.parser.records.count
        let tailBefore = cursor.tailRecords

        var offset = cursor.parser.consumedBytes
        var bytesRead = 0
        do {
            try handle.seek(toOffset: UInt64(offset))
            while offset < size {
                try Task.checkCancellation()
                let want = min(readChunkBytes, size - offset)
                guard let chunk = try handle.read(upToCount: want), !chunk.isEmpty else { break }
                bytesRead += chunk.count
                offset += chunk.count
                cursor.absorbFingerprints(chunk)
                try cursor.parser.consume(chunk, checkCancellation: true)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
        cursor.modificationTime = modificationTime
        cursor.tailRecords = cursor.parser.provisionalTailRecords()

        let changed = !resumed
            || cursor.parser.records.count != committedBefore
            || cursor.tailRecords != tailBefore
        return FileScan(cursor: cursor, recordsChanged: changed, resumed: resumed, bytesRead: bytesRead)
    }

    /// A cursor is reusable only for the same file and parser, when nothing
    /// before its offset can have changed: the file did not shrink, an
    /// unchanged length also kept its modification time, and both the head
    /// and the bytes just before the offset still match.
    ///
    /// This is a check for append-only logs, not a proof that the prefix is
    /// unchanged: a same-inode rewrite that keeps the first `headBytes` and
    /// the `boundaryBytes` before the offset (or that rewrites earlier bytes
    /// of an unterminated `pending` line) resumes without being noticed.
    /// Anyone able to write the logs can already forge records, so a full
    /// prefix hash would cost a full read without adding protection.
    private nonisolated static func canResume(
        _ cursor: FileCursor,
        identity: FileIdentity,
        provider: AgenticProvider,
        size: Int,
        modificationTime: FileTime,
        handle: FileHandle
    ) -> Bool {
        let consumed = cursor.parser.consumedBytes
        guard cursor.identity == identity,
              cursor.provider == provider,
              size >= consumed
        else { return false }
        if size == consumed, cursor.modificationTime != modificationTime {
            return false
        }
        do {
            if cursor.headLength > 0 {
                try handle.seek(toOffset: 0)
                guard let head = try handle.read(upToCount: cursor.headLength),
                      head.count == cursor.headLength else { return false }
                let hash = head.withUnsafeBytes { Fingerprint.hash($0, seed: Fingerprint.offsetBasis) }
                guard hash == cursor.headHash else { return false }
            }
            if !cursor.boundary.isEmpty {
                try handle.seek(toOffset: UInt64(consumed - cursor.boundary.count))
                guard let boundary = try handle.read(upToCount: cursor.boundary.count),
                      boundary == cursor.boundary else { return false }
            }
        } catch {
            return false
        }
        return true
    }

    /// Splits on newlines, pre-filters with a cheap byte scan for the
    /// provider's usage-record marker (well under half the lines carry
    /// usage), then decodes each candidate in file order. Lines that fail to
    /// parse skip silently: these are append-in-progress logs and a partial
    /// trailing line is normal.
    nonisolated static func parse(data: Data, provider: AgenticProvider) -> [AgenticUsageRecord] {
        var parser = AgenticUsageLogParser(provider: provider)
        // Without cancellation checks `consume` cannot throw.
        _ = try? parser.consume(data, checkCancellation: false)
        return parser.records + parser.provisionalTailRecords()
    }

    // MARK: - Line prefilter

    private nonisolated static let claudeNeedles: [[UInt8]] = [
        Array("\"type\":\"assistant\"".utf8),
        Array("\"type\": \"assistant\"".utf8),
    ]
    /// Codex needs the model-bearing context lines as well as token counts.
    private nonisolated static let codexNeedles: [[UInt8]] = [
        Array("\"token_count\"".utf8),
        Array("\"turn_context\"".utf8),
        Array("\"collaboration_mode\"".utf8),
    ]
    private nonisolated static let grokNeedles: [[UInt8]] = [
        Array("\"turn_completed\"".utf8),
    ]
    private nonisolated static let kimiNeedles: [[UInt8]] = [
        Array("\"usage.record\"".utf8),
    ]

    fileprivate nonisolated static func lineNeedles(for provider: AgenticProvider) -> [[UInt8]] {
        switch provider {
        case .claude: claudeNeedles
        case .codex: codexNeedles
        case .grok: grokNeedles
        case .kimi: kimiNeedles
        }
    }

    fileprivate nonisolated static func matchesAnyNeedle(
        base: UnsafePointer<UInt8>,
        range: Range<Int>,
        needles: [[UInt8]]
    ) -> Bool {
        for needle in needles where contains(base: base, range: range, needle: needle) {
            return true
        }
        return false
    }

    private nonisolated static func contains(
        base: UnsafePointer<UInt8>,
        range: Range<Int>,
        needle: [UInt8]
    ) -> Bool {
        let length = needle.count
        guard range.count >= length, let first = needle.first else { return false }
        var index = range.lowerBound
        let lastStart = range.upperBound - length
        while index <= lastStart {
            if base[index] == first {
                var offset = 1
                while offset < length, base[index + offset] == needle[offset] {
                    offset += 1
                }
                if offset == length { return true }
            }
            index += 1
        }
        return false
    }

    // MARK: - Line decoding

    /// Decodes one prefiltered candidate line, carrying Codex's model and
    /// cumulative-total context from earlier lines of the same file.
    fileprivate nonisolated static func decode(
        line: Data,
        provider: AgenticProvider,
        decoder: JSONDecoder,
        codexModel: inout String?,
        codexTotals: inout RawCodexTokenUsage?,
        into records: inout [AgenticUsageRecord]
    ) {
        switch provider {
        case .claude:
            if let record = decodeClaudeRecord(from: line, decoder: decoder) {
                records.append(record)
            }
        case .codex:
            decodeCodexLine(
                from: line,
                decoder: decoder,
                currentModel: &codexModel,
                previousTotals: &codexTotals,
                into: &records
            )
        case .grok:
            decodeGrokRecords(from: line, decoder: decoder, into: &records)
        case .kimi:
            if let record = decodeKimiRecord(from: line, decoder: decoder) {
                records.append(record)
            }
        }
    }

    // MARK: - Claude

    private nonisolated static func decodeClaudeRecord(
        from line: Data,
        decoder: JSONDecoder
    ) -> AgenticUsageRecord? {
        guard let raw = try? decoder.decode(RawClaudeLine.self, from: line),
              raw.type == "assistant",
              let message = raw.message,
              let usage = message.usage,
              let rawModel = message.model,
              let model = AgenticModel.canonicalize(rawModel),
              let timestampString = raw.timestamp,
              let timestamp = parseISOTimestamp(timestampString)
        else { return nil }

        let cacheWrite = max(0, usage.cacheCreationInputTokens ?? 0)
        let cache1h = min(cacheWrite, max(0, usage.cacheCreation?.ephemeral1hInputTokens ?? 0))
        var dedupKey: String?
        if let messageId = message.id, let requestId = raw.requestId {
            dedupKey = "c\u{1F}" + messageId + "\u{1F}" + requestId
        }
        return AgenticUsageRecord(
            provider: .claude,
            dedupKey: dedupKey,
            model: model,
            timestamp: timestamp,
            inputTokens: max(0, usage.inputTokens ?? 0),
            cacheWriteTokens: cacheWrite,
            cacheWrite1hTokens: cache1h,
            cacheReadTokens: max(0, usage.cacheReadInputTokens ?? 0),
            outputTokens: max(0, usage.outputTokens ?? 0),
            thinkingTokens: usage.outputTokensDetails?.thinkingTokens,
            isFast: usage.speed == "fast",
            nativeCostUSD: nil
        )
    }

    // MARK: - Codex

    /// Codex logs a `token_count` event after each API call, attributed to
    /// the model named by the most recent `turn_context` (or `world_state`)
    /// line. `last_token_usage.input_tokens` includes the cached portion, so
    /// uncached input is `input - cached`.
    ///
    /// Codex also re-emits `token_count` on events that made no API call
    /// (turn boundaries, settings changes); those carry the previous call's
    /// `last_token_usage` again but leave `total_token_usage` unchanged, so an
    /// event whose cumulative totals did not advance is a repeat, not a new
    /// call (matching ccusage). An event with totals but no last usage bills
    /// the delta of the totals. Resumed sessions replay their history — with
    /// rewritten timestamps — into new rollout files, so the dedup key
    /// fingerprints `(ordinal, last usage, cumulative usage)`, which replays
    /// copy verbatim. Sessions predating per-turn model context fall back to
    /// "gpt-5", matching ccusage.
    private nonisolated static func decodeCodexLine(
        from line: Data,
        decoder: JSONDecoder,
        currentModel: inout String?,
        previousTotals: inout RawCodexTokenUsage?,
        into records: inout [AgenticUsageRecord]
    ) {
        guard let raw = try? decoder.decode(RawCodexLine.self, from: line) else { return }
        if let model = raw.payload?.model ?? raw.payload?.collaborationMode?.model,
           !model.isEmpty {
            currentModel = model
        }
        // world_state nests collaboration_mode one level deeper.
        if let model = raw.payload?.state?.collaborationMode?.model, !model.isEmpty {
            currentModel = model
        }
        guard raw.payload?.type == "token_count",
              let info = raw.payload?.info,
              let timestamp = raw.timestamp.flatMap(parseFlexibleTimestamp)
        else { return }

        let total = info.totalTokenUsage
        let advanced = total == nil || previousTotals != total
        let usage: RawCodexTokenUsage?
        if let last = info.lastTokenUsage, advanced {
            usage = last
        } else if let total {
            usage = total.subtracting(previousTotals)
        } else {
            usage = nil
        }
        if let total { previousTotals = total }
        guard let usage else { return }

        let input = max(0, usage.inputTokens ?? 0)
        let cached = min(input, max(0, usage.cachedInputTokens ?? 0))
        let cacheWrite = max(0, usage.cacheWriteInputTokens ?? 0)
        let output = max(0, usage.outputTokens ?? 0)
        let reasoning = usage.reasoningOutputTokens
        guard input > 0 || cacheWrite > 0 || output > 0 || (reasoning ?? 0) > 0 else { return }

        let dedupKey = "x\u{1F}\(raw.ordinal.map(String.init) ?? "null")"
            + "\u{1F}\(input)\u{1F}\(cached)\u{1F}\(output)\u{1F}\(reasoning ?? -1)"
            + "\u{1F}\(total?.inputTokens ?? -1)\u{1F}\(total?.cachedInputTokens ?? -1)"
            + "\u{1F}\(total?.outputTokens ?? -1)"
        records.append(
            AgenticUsageRecord(
                provider: .codex,
                dedupKey: dedupKey,
                model: currentModel ?? "gpt-5",
                timestamp: timestamp,
                inputTokens: input - cached,
                cacheWriteTokens: cacheWrite,
                cacheWrite1hTokens: 0,
                cacheReadTokens: cached,
                outputTokens: output,
                thinkingTokens: reasoning,
                isFast: false,
                nativeCostUSD: nil
            )
        )
    }

    // MARK: - Grok

    /// Grok logs one `turn_completed` update per prompt, with per-model usage
    /// and an exact cost in `costUsdTicks` (1e-10 USD). `inputTokens`
    /// includes the cached portion.
    private nonisolated static func decodeGrokRecords(
        from line: Data,
        decoder: JSONDecoder,
        into records: inout [AgenticUsageRecord]
    ) {
        guard let raw = try? decoder.decode(RawGrokLine.self, from: line),
              let update = raw.params?.update,
              update.sessionUpdate == "turn_completed",
              let usage = update.usage,
              let epochSeconds = raw.timestamp
        else { return }
        let timestamp = Date(timeIntervalSince1970: TimeInterval(epochSeconds))

        let perModel = usage.modelUsage?.filter { _, use in (use.totalTokens ?? 0) > 0 } ?? [:]
        if perModel.isEmpty {
            append(grokUsage: usage, model: "grok-4.5-build", timestamp: timestamp, into: &records)
        } else {
            for (model, use) in perModel.sorted(by: { $0.key < $1.key }) {
                append(grokUsage: use, model: model, timestamp: timestamp, into: &records)
            }
        }
    }

    private nonisolated static func append(
        grokUsage usage: RawGrokUsage,
        model: String,
        timestamp: Date,
        into records: inout [AgenticUsageRecord]
    ) {
        let input = max(0, usage.inputTokens ?? 0)
        let cached = min(input, max(0, usage.cachedReadTokens ?? 0))
        records.append(
            AgenticUsageRecord(
                provider: .grok,
                dedupKey: nil,
                model: model,
                timestamp: timestamp,
                inputTokens: input - cached,
                cacheWriteTokens: 0,
                cacheWrite1hTokens: 0,
                cacheReadTokens: cached,
                outputTokens: max(0, usage.outputTokens ?? 0),
                thinkingTokens: usage.reasoningTokens,
                isFast: false,
                nativeCostUSD: usage.costUsdTicks.map { Double($0) / 1e10 }
            )
        )
    }

    // MARK: - Kimi

    /// Kimi logs one turn-scoped `usage.record` per API call, plus occasional
    /// session-scoped records that carry the session's cumulative totals;
    /// only the turn records are billable (matching ccusage). `inputOther`
    /// is already the uncached portion. Model ids carry a "kimi-code/"
    /// routing prefix.
    private nonisolated static func decodeKimiRecord(
        from line: Data,
        decoder: JSONDecoder
    ) -> AgenticUsageRecord? {
        guard let raw = try? decoder.decode(RawKimiLine.self, from: line),
              raw.type == "usage.record",
              raw.usageScope == "turn",
              let usage = raw.usage,
              let rawModel = raw.model,
              let epochMilliseconds = raw.time
        else { return nil }
        var model = rawModel
        if model.hasPrefix("kimi-code/") {
            model = String(model.dropFirst("kimi-code/".count))
        }
        return AgenticUsageRecord(
            provider: .kimi,
            dedupKey: nil,
            model: model,
            timestamp: Date(timeIntervalSince1970: TimeInterval(epochMilliseconds) / 1000),
            inputTokens: max(0, usage.inputOther ?? 0),
            cacheWriteTokens: max(0, usage.inputCacheCreation ?? 0),
            cacheWrite1hTokens: 0,
            cacheReadTokens: max(0, usage.inputCacheRead ?? 0),
            outputTokens: max(0, usage.output ?? 0),
            thinkingTokens: nil,
            isFast: false,
            nativeCostUSD: nil
        )
    }

    // MARK: - Timestamps

    private nonisolated static let fractionalISO8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private nonisolated static let plainISO8601 = Date.ISO8601FormatStyle()

    nonisolated static func parseISOTimestamp(_ string: String) -> Date? {
        if let date = try? fractionalISO8601.parse(string) { return date }
        return try? plainISO8601.parse(string)
    }

    /// Codex timestamps are ISO strings in current logs but were epoch
    /// numbers (seconds, or milliseconds when large) in older formats.
    nonisolated static func parseFlexibleTimestamp(_ value: RawFlexibleTimestamp) -> Date? {
        switch value {
        case .iso(let string):
            return parseISOTimestamp(string)
        case .epoch(let number):
            let seconds = number > 1e12 ? number / 1000 : number
            return Date(timeIntervalSince1970: seconds)
        }
    }

    // MARK: - Dedup

    /// Collapses copies of any record with a `dedupKey`, keeping the copy
    /// with the largest `outputTokens`.
    ///
    /// The same call is logged repeatedly: Claude Code replays assistant
    /// messages into multiple transcript files, and the line at stream start
    /// carries a placeholder output count while a later line carries the
    /// final one, so keep-first would undercount output roughly 2x (input
    /// and cache fields are fixed at stream start and identical across
    /// copies). Codex replays whole session histories into new rollout files
    /// on resume; those copies are identical, so keep-max degenerates to
    /// keep-first. Records without a key are always kept.
    nonisolated static func deduplicate(_ records: [AgenticUsageRecord]) -> [AgenticUsageRecord] {
        var indexByKey = [String: Int](minimumCapacity: records.count)
        var kept: [AgenticUsageRecord] = []
        kept.reserveCapacity(records.count)
        for record in records {
            guard let key = record.dedupKey else {
                kept.append(record)
                continue
            }
            if let index = indexByKey[key] {
                if record.outputTokens > kept[index].outputTokens {
                    kept[index] = record
                }
            } else {
                indexByKey[key] = kept.count
                kept.append(record)
            }
        }
        return kept
    }
}

// MARK: - Incremental line parser

/// Parses one usage log as a stream of byte chunks, so a file can be resumed
/// after an append. Records come only from newline-terminated lines; the
/// unterminated tail stays in `pending` until a later chunk finishes it.
/// Feeding a file in any chunking produces exactly the records of parsing it
/// in one piece.
struct AgenticUsageLogParser: Sendable {
    let provider: AgenticProvider
    /// Records from newline-terminated lines, in file order.
    private(set) var records: [AgenticUsageRecord] = []
    /// Bytes fed so far, including `pending`.
    private(set) var consumedBytes = 0
    /// The current unterminated line, bounded by `maxLineBytes`.
    private(set) var pending = Data()
    /// The current line already exceeded `maxLineBytes`; skip to its end.
    private var discardingLine = false
    // Codex attributes token counts to the most recent turn's model and
    // reports cumulative totals that tell repeats from new calls.
    private var codexModel: String?
    private var codexTotals: RawCodexTokenUsage?

    private static let cancellationStride = 128

    init(provider: AgenticProvider) {
        self.provider = provider
    }

    /// Feeds the next bytes of the file. With `checkCancellation`, throws
    /// `CancellationError` between candidate decodes; the parser must then be
    /// discarded because the chunk was only partly consumed.
    mutating func consume(_ chunk: Data, checkCancellation: Bool) throws {
        guard !chunk.isEmpty else { return }
        consumedBytes += chunk.count
        let needles = AgenticUsageLoader.lineNeedles(for: provider)
        let decoder = JSONDecoder()
        var decodes = 0
        try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = raw.count
            var lineStart = 0
            while lineStart < count,
                  let hit = memchr(base + lineStart, 0x0A, count - lineStart) {
                let newline = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit))
                if discardingLine {
                    discardingLine = false
                } else if !pending.isEmpty {
                    if pending.count + newline <= AgenticUsageLoader.maxLineBytes {
                        pending.append(base, count: newline)
                        let line = pending
                        try line.withUnsafeBytes { lineRaw in
                            guard let lineBase = lineRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                                return
                            }
                            try process(
                                base: lineBase, range: 0..<lineRaw.count, needles: needles,
                                decoder: decoder, decodes: &decodes, checkCancellation: checkCancellation
                            )
                        }
                    }
                    pending = Data()
                } else {
                    try process(
                        base: base, range: lineStart..<newline, needles: needles,
                        decoder: decoder, decodes: &decodes, checkCancellation: checkCancellation
                    )
                }
                lineStart = newline + 1
            }
            let tail = count - lineStart
            guard tail > 0, !discardingLine else { return }
            if pending.count + tail > AgenticUsageLoader.maxLineBytes {
                pending = Data()
                discardingLine = true
            } else {
                pending.append(base + lineStart, count: tail)
            }
        }
    }

    /// Records the unterminated tail would produce if the file ended here,
    /// decoded on a copy so the committed state can still resume.
    func provisionalTailRecords() -> [AgenticUsageRecord] {
        guard !discardingLine, pending.count >= AgenticUsageLoader.minLineBytes else { return [] }
        var copy = self
        copy.records = []
        var decodes = 0
        pending.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            try? copy.process(
                base: base, range: 0..<raw.count,
                needles: AgenticUsageLoader.lineNeedles(for: provider),
                decoder: JSONDecoder(), decodes: &decodes, checkCancellation: false
            )
        }
        return copy.records
    }

    private mutating func process(
        base: UnsafePointer<UInt8>,
        range: Range<Int>,
        needles: [[UInt8]],
        decoder: JSONDecoder,
        decodes: inout Int,
        checkCancellation: Bool
    ) throws {
        let length = range.count
        guard length >= AgenticUsageLoader.minLineBytes,
              length <= AgenticUsageLoader.maxLineBytes,
              AgenticUsageLoader.matchesAnyNeedle(base: base, range: range, needles: needles)
        else { return }
        decodes += 1
        if checkCancellation, decodes.isMultiple(of: Self.cancellationStride) {
            try Task.checkCancellation()
        }
        let line = Data(bytes: base + range.lowerBound, count: length)
        AgenticUsageLoader.decode(
            line: line,
            provider: provider,
            decoder: decoder,
            codexModel: &codexModel,
            codexTotals: &codexTotals,
            into: &records
        )
    }
}

extension AgenticUsageLoader.FileCursor {
    /// Extends the head hash and boundary bytes with the chunk about to be
    /// consumed at `parser.consumedBytes`.
    mutating func absorbFingerprints(_ chunk: Data) {
        if headLength < Self.headBytes {
            let take = min(Self.headBytes - headLength, chunk.count)
            let seed = headHash
            headHash = chunk.prefix(take).withUnsafeBytes {
                AgenticUsageLoader.Fingerprint.hash($0, seed: seed)
            }
            headLength += take
        }
        if chunk.count >= Self.boundaryBytes {
            boundary = Data(chunk.suffix(Self.boundaryBytes))
        } else {
            var combined = boundary
            combined.append(chunk)
            boundary = Data(combined.suffix(Self.boundaryBytes))
        }
    }
}

// MARK: - Raw JSONL shapes

/// A JSON value that is either an ISO8601 string or an epoch number.
enum RawFlexibleTimestamp: Decodable, Sendable {
    case iso(String)
    case epoch(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .iso(string)
        } else {
            self = .epoch(try container.decode(Double.self))
        }
    }
}

// Claude Code transcript lines.

private struct RawClaudeLine: Decodable {
    let type: String?
    let requestId: String?
    let timestamp: String?
    let message: RawClaudeMessage?
}

private struct RawClaudeMessage: Decodable {
    let id: String?
    let model: String?
    let usage: RawClaudeUsage?
}

private struct RawClaudeUsage: Decodable {
    let inputTokens: Int?
    let cacheCreationInputTokens: Int?
    let cacheReadInputTokens: Int?
    let outputTokens: Int?
    let speed: String?
    let cacheCreation: RawClaudeCacheCreation?
    let outputTokensDetails: RawClaudeOutputTokensDetails?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case outputTokens = "output_tokens"
        case speed
        case cacheCreation = "cache_creation"
        case outputTokensDetails = "output_tokens_details"
    }
}

private struct RawClaudeCacheCreation: Decodable {
    let ephemeral5mInputTokens: Int?
    let ephemeral1hInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case ephemeral5mInputTokens = "ephemeral_5m_input_tokens"
        case ephemeral1hInputTokens = "ephemeral_1h_input_tokens"
    }
}

private struct RawClaudeOutputTokensDetails: Decodable {
    let thinkingTokens: Int?

    enum CodingKeys: String, CodingKey {
        case thinkingTokens = "thinking_tokens"
    }
}

// Codex rollout lines.

private struct RawCodexLine: Decodable {
    let timestamp: RawFlexibleTimestamp?
    let ordinal: Int?
    let payload: RawCodexPayload?
}

private struct RawCodexPayload: Decodable {
    let type: String?
    let model: String?
    let collaborationMode: RawCodexCollaborationMode?
    let state: RawCodexWorldState?
    let info: RawCodexTokenInfo?

    enum CodingKeys: String, CodingKey {
        case type
        case model
        case collaborationMode = "collaboration_mode"
        case state
        case info
    }
}

private struct RawCodexWorldState: Decodable {
    let collaborationMode: RawCodexCollaborationMode?

    enum CodingKeys: String, CodingKey {
        case collaborationMode = "collaboration_mode"
    }
}

private struct RawCodexCollaborationMode: Decodable {
    let model: String?
}

private struct RawCodexTokenInfo: Decodable {
    let totalTokenUsage: RawCodexTokenUsage?
    let lastTokenUsage: RawCodexTokenUsage?

    enum CodingKeys: String, CodingKey {
        case totalTokenUsage = "total_token_usage"
        case lastTokenUsage = "last_token_usage"
    }
}

private struct RawCodexTokenUsage: Decodable, Equatable, Sendable {
    let inputTokens: Int?
    let cachedInputTokens: Int?
    let cacheWriteInputTokens: Int?
    let outputTokens: Int?
    let reasoningOutputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case cacheWriteInputTokens = "cache_write_input_tokens"
        case outputTokens = "output_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
    }

    init(
        inputTokens: Int?,
        cachedInputTokens: Int?,
        cacheWriteInputTokens: Int?,
        outputTokens: Int?,
        reasoningOutputTokens: Int?
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
    }

    /// Per-call usage as the difference between two cumulative totals.
    /// Clamped at zero: totals never go backwards in a well-formed log.
    func subtracting(_ previous: RawCodexTokenUsage?) -> RawCodexTokenUsage {
        func delta(_ current: Int?, _ earlier: Int?) -> Int? {
            guard let current else { return nil }
            return max(0, current - (earlier ?? 0))
        }
        return RawCodexTokenUsage(
            inputTokens: delta(inputTokens, previous?.inputTokens),
            cachedInputTokens: delta(cachedInputTokens, previous?.cachedInputTokens),
            cacheWriteInputTokens: delta(cacheWriteInputTokens, previous?.cacheWriteInputTokens),
            outputTokens: delta(outputTokens, previous?.outputTokens),
            reasoningOutputTokens: delta(reasoningOutputTokens, previous?.reasoningOutputTokens)
        )
    }
}

// Grok session-update lines.

private struct RawGrokLine: Decodable {
    let timestamp: Double?
    let params: RawGrokParams?
}

private struct RawGrokParams: Decodable {
    let update: RawGrokUpdate?
}

private struct RawGrokUpdate: Decodable {
    let sessionUpdate: String?
    let usage: RawGrokUsage?
}

private struct RawGrokUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?
    let cachedReadTokens: Int?
    let reasoningTokens: Int?
    let costUsdTicks: Int?
    let modelUsage: [String: RawGrokUsage]?
}

// Kimi wire lines.

private struct RawKimiLine: Decodable {
    let type: String?
    let model: String?
    let usage: RawKimiUsage?
    let usageScope: String?
    let time: Double?
}

private struct RawKimiUsage: Decodable {
    let inputOther: Int?
    let output: Int?
    let inputCacheRead: Int?
    let inputCacheCreation: Int?
}
