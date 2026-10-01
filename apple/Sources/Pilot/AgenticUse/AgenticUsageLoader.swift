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
/// so files parse in parallel off the main actor and an in-memory
/// `(path, size, mtime)` cache makes every load after the first near-instant
/// — unchanged files never re-parse. The logs are untrusted input: files
/// stream with bounded lines, malformed lines are skipped, and no
/// single bad file fails a load.
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
        /// Files that could not be read.
        let unreadableFileCount: Int
        var skippedLineCount: Int = 0
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
        let records: [AgenticUsageRecord]?
        var skippedLineCount: Int = 0
    }

    private struct CacheEntry {
        let size: Int
        let modificationDate: Date
        let records: [AgenticUsageRecord]
        let skippedLineCount: Int
    }

    /// Bound individual lines while streaming files of any size.
    private static let maxLineBytes = 16 * 1024 * 1024
    /// Shortest possible line worth decoding.
    private static let minLineBytes = 24

    private let sources: [Source]
    private var cache: [String: CacheEntry] = [:]

    init(sources: [Source] = AgenticUsageLoader.defaultSources()) {
        self.sources = sources
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
    /// aborts between files with `CancellationError`.
    func load(onProgress: (@Sendable (_ scanned: Int, _ total: Int) -> Void)? = nil) async throws -> LoadResult {
        let files = try discoverFiles()
        guard !files.isEmpty else {
            cache = [:]
            return LoadResult(records: [], fileCount: 0, unreadableFileCount: 0)
        }

        // Serve unchanged files from the cache; parse the rest in parallel.
        var pending: [FileJob] = []
        var cachedCount = 0
        for file in files {
            if let entry = cache[file.path], entry.size == file.size,
               entry.modificationDate == file.modificationDate {
                cachedCount += 1
            } else {
                pending.append(file)
            }
        }
        onProgress?(cachedCount, files.count)

        let outcomes = try await Self.parseFiles(
            pending,
            alreadyScanned: cachedCount,
            total: files.count,
            onProgress: onProgress
        )

        var unreadableCount = 0
        for outcome in outcomes {
            if let records = outcome.records {
                cache[outcome.job.path] = CacheEntry(
                    size: outcome.job.size,
                    modificationDate: outcome.job.modificationDate,
                    records: records,
                    skippedLineCount: outcome.skippedLineCount
                )
            } else {
                cache[outcome.job.path] = nil
                unreadableCount += 1
            }
        }

        // Drop cache entries for files deleted since the last load.
        let livePaths = Set(files.map(\.path))
        cache = cache.filter { livePaths.contains($0.key) }

        // Flatten in stable path order so dedup is deterministic, then dedup
        // across ALL files before any date filtering happens.
        var all: [AgenticUsageRecord] = []
        for file in files {
            if let entry = cache[file.path] {
                all.append(contentsOf: entry.records)
            }
        }
        var records = Self.deduplicate(all)
        records.sort { $0.timestamp < $1.timestamp }
        return LoadResult(
            records: records,
            fileCount: files.count,
            unreadableFileCount: unreadableCount,
            skippedLineCount: cache.values.reduce(0) { $0 + $1.skippedLineCount }
        )
    }

    // MARK: - Discovery

    private func discoverFiles() throws -> [FileJob] {
        var jobs: [FileJob] = []
        for source in sources {
            try discoverFiles(in: source, into: &jobs)
        }
        // Overrides and default roots can overlap; never scan a file twice.
        var seen: Set<String> = []
        jobs = jobs.filter { seen.insert($0.url.resolvingSymlinksInPath().path).inserted }
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

        for case let url as URL in enumerator {
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
    }

    // MARK: - Parallel parsing

    private nonisolated static func parseFiles(
        _ jobs: [FileJob],
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
                guard let job = iterator.next() else { break }
                group.addTask {
                    Self.parseJob(job)
                }
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
                if let job = iterator.next() {
                    group.addTask {
                        Self.parseJob(job)
                    }
                }
            }
            return outcomes
        }
    }

    // MARK: - Single-file parsing

    private struct ParseState {
        var records: [AgenticUsageRecord] = []
        var codex = CodexState()
        var line = Data()
        var oversizedLine = false
        var oversizedLineNeedsWarning = true
        var skippedLineCount = 0
        let decoder = JSONDecoder()
    }

    private struct CodexState {
        var model: String?
        var totals: RawCodexTokenUsage?
        var sessionID: String?
        var serviceTier: String?
        var lastResponseUsage: RawCodexTokenUsage?
    }

    private nonisolated static func parseJob(_ job: FileJob) -> ParseOutcome {
        guard let state = parseFileState(at: job.url, provider: job.provider) else {
            return ParseOutcome(job: job, records: nil)
        }
        return ParseOutcome(job: job, records: state.records, skippedLineCount: state.skippedLineCount)
    }

    /// Streams large rollouts instead of dropping them at an arbitrary file
    /// size. Only one chunk and a bounded pending line reside in memory.
    nonisolated static func parseFile(at url: URL, provider: AgenticProvider) -> [AgenticUsageRecord]? {
        parseFileState(at: url, provider: provider)?.records
    }

    private nonisolated static func parseFileState(at url: URL, provider: AgenticProvider) -> ParseState? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var state = ParseState()
        do {
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                consume(chunk, provider: provider, state: &state)
            }
            finishLine(provider: provider, state: &state)
            return state
        } catch {
            return nil
        }
    }

    nonisolated static func parse(data: Data, provider: AgenticProvider) -> [AgenticUsageRecord] {
        var state = ParseState()
        consume(data, provider: provider, state: &state)
        finishLine(provider: provider, state: &state)
        return state.records
    }

    private nonisolated static func consume(_ data: Data, provider: AgenticProvider, state: inout ParseState) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var start = 0
            var index = 0
            while index < raw.count {
                if base[index] == 0x0A {
                    appendLineBytes(data[(data.startIndex + start)..<(data.startIndex + index)], provider: provider, state: &state)
                    finishLine(provider: provider, state: &state)
                    start = index + 1
                }
                index += 1
            }
            appendLineBytes(data[(data.startIndex + start)..<data.endIndex], provider: provider, state: &state)
        }
    }

    private nonisolated static func appendLineBytes(
        _ bytes: Data.SubSequence, provider: AgenticProvider, state: inout ParseState
    ) {
        guard !state.oversizedLine else { return }
        guard state.line.count + bytes.count <= maxLineBytes else {
            let prefix = state.line.isEmpty ? Data(bytes.prefix(4096)) : Data(state.line.prefix(4096))
            state.oversizedLineNeedsWarning = !isNonUsageCodexLine(prefix, provider: provider)
            state.line.removeAll(keepingCapacity: true)
            state.oversizedLine = true
            return
        }
        state.line.append(contentsOf: bytes)
    }

    /// Large compaction histories and transcript messages carry no billable
    /// usage. Decode only the complete envelope preceding their payload to
    /// distinguish them from oversized usage or model-context records.
    private nonisolated static func isNonUsageCodexLine(_ prefix: Data, provider: AgenticProvider) -> Bool {
        guard provider == .codex,
              let payload = prefix.range(of: Data("\"payload\"".utf8)) else { return false }
        var header = Data(prefix[..<payload.lowerBound])
        header.append(contentsOf: "\"payload\":null}".utf8)
        guard let raw = try? JSONDecoder().decode(RawCodexLine.self, from: header) else { return false }
        return raw.type == "compacted" || raw.type == "response_item"
    }

    private nonisolated static func finishLine(provider: AgenticProvider, state: inout ParseState) {
        defer {
            state.line.removeAll(keepingCapacity: true)
            state.oversizedLine = false
            state.oversizedLineNeedsWarning = true
        }
        if state.oversizedLine {
            if state.oversizedLineNeedsWarning { state.skippedLineCount += 1 }
            return
        }
        let line = state.line
        guard line.count >= minLineBytes else { return }
        let candidate = line.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            return matchesAnyNeedle(base: base, range: 0..<raw.count, needles: lineNeedles(for: provider))
        }
        guard candidate else { return }
        switch provider {
        case .claude:
            if let record = decodeClaudeRecord(from: line, decoder: state.decoder) { state.records.append(record) }
        case .codex:
            decodeCodexLine(from: line, decoder: state.decoder, state: &state.codex, into: &state.records)
        case .grok:
            decodeGrokRecords(from: line, decoder: state.decoder, into: &state.records)
        case .kimi:
            if let record = decodeKimiRecord(from: line, decoder: state.decoder) { state.records.append(record) }
        }
    }

    // MARK: - Line prefilter

    private nonisolated static let claudeNeedles: [[UInt8]] = [Array("\"usage\"".utf8)]
    /// Codex needs the model-bearing context lines as well as token counts.
    private nonisolated static let codexNeedles: [[UInt8]] = [
        Array("\"token_count\"".utf8),
        Array("\"token_usage_record\"".utf8),
        Array("\"session_meta\"".utf8),
        Array("\"world_state\"".utf8),
        Array("\"turn_context\"".utf8),
        Array("\"collaboration_mode\"".utf8),
    ]
    private nonisolated static let grokNeedles: [[UInt8]] = [
        Array("\"turn_completed\"".utf8),
    ]
    private nonisolated static let kimiNeedles: [[UInt8]] = [
        Array("\"usage.record\"".utf8),
    ]

    private nonisolated static func lineNeedles(for provider: AgenticProvider) -> [[UInt8]] {
        switch provider {
        case .claude: claudeNeedles
        case .codex: codexNeedles
        case .grok: grokNeedles
        case .kimi: kimiNeedles
        }
    }

    private nonisolated static func matchesAnyNeedle(
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

        let cacheWrite = max(0, usage.cacheCreationInputTokens
            ?? ((usage.cacheCreation?.ephemeral5mInputTokens ?? 0) + (usage.cacheCreation?.ephemeral1hInputTokens ?? 0)))
        let cache1h = min(cacheWrite, max(0, usage.cacheCreation?.ephemeral1hInputTokens ?? 0))
        var dedupKey: String?
        if let messageId = message.id, let requestId = raw.requestId {
            dedupKey = "c\u{1F}" + messageId + "\u{1F}" + requestId
        }
        var record = AgenticUsageRecord(
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
        record.serviceTier = usage.serviceTier
        record.inferenceGeo = usage.inferenceGeo
        return record
    }

    // MARK: - Codex

    /// Current Codex emits per-response `token_usage_record` and a legacy
    /// `token_count` notification for the same call. Consume response usage
    /// first, advancing the cumulative cursor so notifications cannot bill
    /// it again. Older logs still use last usage or cumulative deltas.
    private nonisolated static func decodeCodexLine(
        from line: Data,
        decoder: JSONDecoder,
        state: inout CodexState,
        into records: inout [AgenticUsageRecord]
    ) {
        guard let raw = try? decoder.decode(RawCodexLine.self, from: line), let payload = raw.payload else { return }
        if raw.type == "session_meta" { state.sessionID = payload.id ?? payload.sessionID }
        if let id = payload.threadID ?? payload.sessionID { state.sessionID = id }
        if let model = payload.model ?? payload.collaborationMode?.resolvedModel
            ?? payload.state?.collaborationMode?.resolvedModel, !model.isEmpty {
            state.model = AgenticModel.canonicalize(model) ?? model
        }
        if raw.type == "turn_context" { state.serviceTier = payload.serviceTier }
        if let tier = payload.serviceTier { state.serviceTier = tier }
        let isResponse = raw.type == "token_usage_record"
        guard isResponse || payload.type == "token_count",
              let timestamp = raw.timestamp.flatMap(parseFlexibleTimestamp) else { return }

        let total = isResponse ? payload.threadTokenUsage : payload.info?.totalTokenUsage
        let previous = state.totals
        if let total { state.totals = total }
        let usage: RawCodexTokenUsage
        if isResponse {
            guard let responseUsage = payload.usage else { return }
            usage = responseUsage
            state.lastResponseUsage = usage
        } else {
            // Metadata-only repeats carry the previous call's last usage.
            if let total, total == previous { return }
            if let last = payload.info?.lastTokenUsage {
                if last == state.lastResponseUsage {
                    state.lastResponseUsage = nil
                    return
                }
                usage = last
            } else if let total {
                usage = total.subtracting(previous)
            } else { return }
            state.lastResponseUsage = nil
        }

        let input = max(0, usage.inputTokens ?? 0)
        let cached = min(input, max(0, usage.cachedInputTokens ?? 0))
        // Codex input includes both cache reads and writes; keep categories
        // disjoint so writes aren't also billed as plain input.
        let cacheWrite = min(input - cached, max(0, usage.cacheWriteInputTokens ?? 0))
        let output = max(0, usage.outputTokens ?? 0)
        let reasoning = usage.reasoningOutputTokens.map { max(0, $0) }
        guard input > 0 || output > 0 else { return }

        let identity = payload.responseID ?? (total == nil
            ? (raw.ordinal.map(String.init) ?? timestamp.description)
            : "cumulative")
        let dedupKey = "x\u{1F}\(state.sessionID ?? "legacy")\u{1F}\(identity)"
            + "\u{1F}\(input)\u{1F}\(cached)\u{1F}\(cacheWrite)\u{1F}\(output)\u{1F}\(reasoning ?? -1)"
            + "\u{1F}\(total?.inputTokens ?? -1)\u{1F}\(total?.cachedInputTokens ?? -1)"
            + "\u{1F}\(total?.cacheWriteInputTokens ?? -1)\u{1F}\(total?.outputTokens ?? -1)"
        var record = AgenticUsageRecord(
            provider: .codex,
            dedupKey: dedupKey,
            model: state.model ?? "gpt-unknown",
            timestamp: timestamp,
            inputTokens: input - cached - cacheWrite,
            cacheWriteTokens: cacheWrite,
            cacheWrite1hTokens: 0,
            cacheReadTokens: cached,
            outputTokens: output,
            thinkingTokens: reasoning,
            isFast: ["fast", "priority"].contains(state.serviceTier ?? ""),
            nativeCostUSD: nil
        )
        record.serviceTier = state.serviceTier
        records.append(record)
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

        let perModel = usage.modelUsage?.filter { _, use in
            (use.inputTokens ?? 0) > 0 || (use.outputTokens ?? 0) > 0 || (use.totalTokens ?? 0) > 0
        } ?? [:]
        if perModel.isEmpty {
            append(grokUsage: usage, model: "grok-unknown", timestamp: timestamp, into: &records)
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
                nativeCostUSD: usage.costUsdTicks.flatMap { $0 >= 0 ? Double($0) / 1e10 : nil }
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
    let serviceTier: String?
    let inferenceGeo: String?
    let cacheCreation: RawClaudeCacheCreation?
    let outputTokensDetails: RawClaudeOutputTokensDetails?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case outputTokens = "output_tokens"
        case speed
        case serviceTier = "service_tier"
        case inferenceGeo = "inference_geo"
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
    let type: String?
    let timestamp: RawFlexibleTimestamp?
    let ordinal: Int?
    let payload: RawCodexPayload?
}

private struct RawCodexPayload: Decodable {
    let id: String?
    let threadID: String?
    let sessionID: String?
    let responseID: String?
    let serviceTier: String?
    let usage: RawCodexTokenUsage?
    let threadTokenUsage: RawCodexTokenUsage?
    let type: String?
    let model: String?
    let collaborationMode: RawCodexCollaborationMode?
    let state: RawCodexWorldState?
    let info: RawCodexTokenInfo?

    enum CodingKeys: String, CodingKey {
        case id
        case threadID = "thread_id"
        case sessionID = "session_id"
        case responseID = "response_id"
        case serviceTier = "service_tier"
        case usage
        case threadTokenUsage = "thread_token_usage"
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
    let settings: RawCodexCollaborationSettings?

    var resolvedModel: String? { model ?? settings?.model }
}

private struct RawCodexCollaborationSettings: Decodable {
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

private struct RawCodexTokenUsage: Decodable, Equatable {
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
