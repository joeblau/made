import Foundation

/// Historical token usage from the same dashboard session as Plan Usage.
/// Kept in memory, with overlapping incremental refreshes for late billing
/// updates. Credentials are read only after the caller enables Cursor usage.
actor CursorUsageHistory {
    struct Result: Sendable {
        var records: [AgenticUsageRecord] = []
        var warning: String?
    }

    static let endpoint = URL(string: "https://cursor.com/api/dashboard/get-filtered-usage-events")!
    private let transport: UsageHTTP.Transport
    private let session: @Sendable () -> UsageSessions.CursorSession?
    private let now: @Sendable () -> Date
    private var cached = Result()
    private var coveredStart: Date?
    private var fetchedAt: Date?
    private var retryAt: Date?

    init(
        transport: @escaping UsageHTTP.Transport = UsageHTTP.live,
        session: @escaping @Sendable () -> UsageSessions.CursorSession? = { UsageSessions.CursorSession.load() },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.session = session
        self.now = now
    }

    func load(enabled: Bool, range: AgenticUseRange) async throws -> Result {
        guard enabled else {
            cached = Result()
            coveredStart = nil
            fetchedAt = nil
            retryAt = nil
            return cached
        }
        let end = now()
        // Cursor did not exist before 2020; avoid distantPast's overflowing
        // millisecond timestamp for the All range.
        let start = max(
            range.interval(endingAt: end, calendar: .current).start,
            Date(timeIntervalSince1970: 1_577_836_800)
        )
        if let retryAt, end < retryAt { return cached }
        let covered = coveredStart.map { $0 <= start } ?? false
        if covered, let fetchedAt, end.timeIntervalSince(fetchedAt) < 600 { return cached }
        guard let session = session(), !session.isExpired(at: end) else {
            cached = Result(warning: "Cursor history unavailable. Sign in to Cursor, then refresh.")
            coveredStart = nil
            fetchedAt = nil
            retryAt = end.addingTimeInterval(120)
            return cached
        }

        // Re-fetch the most recent day so settled token counts/costs replace
        // provisional values. A wider range loads the missing history too.
        let queryStart: Date
        if covered, let fetchedAt {
            queryStart = max(start, fetchedAt.addingTimeInterval(-86_400))
        } else {
            queryStart = start
        }
        do {
            let fresh = try await fetch(session: session, start: queryStart, end: end)
            try Task.checkCancellation()
            let retained = cached.records.filter { $0.timestamp < queryStart }
            cached = Result(records: AgenticUsageLoader.deduplicate(retained + fresh)
                .sorted { $0.timestamp < $1.timestamp })
            coveredStart = min(coveredStart ?? start, start)
            fetchedAt = end
            retryAt = nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            var delay: TimeInterval = 120
            if case let UsageFetchError.http(status, retryAfter) = error, status == 429 {
                delay = max(600, retryAfter ?? 0)
            }
            retryAt = end.addingTimeInterval(delay)
            cached.warning = cached.records.isEmpty
                ? "Cursor history could not load. Sign in to Cursor, then try refreshing."
                : "Cursor history could not refresh; showing previously loaded usage."
        }
        return cached
    }

    private func fetch(
        session: UsageSessions.CursorSession,
        start: Date,
        end: Date
    ) async throws -> [AgenticUsageRecord] {
        let pageSize = 1000
        var records: [AgenticUsageRecord] = []
        var received = 0
        for page in 1...200 {
            try Task.checkCancellation()
            var request = URLRequest(url: Self.endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue(CursorUsageAdapter.cookie(for: session), forHTTPHeaderField: "Cookie")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            // The dashboard enforces same-origin POSTs.
            request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
            request.setValue("https://cursor.com/dashboard?tab=usage", forHTTPHeaderField: "Referer")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "startDate": String(Int64(start.timeIntervalSince1970 * 1000)),
                "endDate": String(Int64(end.timeIntervalSince1970 * 1000)),
                "page": page,
                "pageSize": pageSize,
            ])
            let (data, response) = try await transport(request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw UsageFetchError.http(
                    status: http.statusCode,
                    retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                )
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let events = object["usageEventsDisplay"] as? [[String: Any]],
                  let total = UsageJSON.number(object["totalUsageEventsCount"]),
                  total.isFinite, total >= 0 else { throw UsageFetchError.malformed }
            received += events.count
            records += events.compactMap(Self.parse)
            if Double(received) >= total { return records }
            // Never silently treat an incomplete response as complete history.
            guard !events.isEmpty else { throw UsageFetchError.malformed }
        }
        throw UsageFetchError.malformed
    }

    /// Native totalCents is the token cost, even for included-plan calls.
    /// requestsCosts is a request-credit quantity, not a USD token cost.
    static func parse(_ event: [String: Any]) -> AgenticUsageRecord? {
        guard let usage = event["tokenUsage"] as? [String: Any],
              let rawModel = UsageJSON.string(event, keys: ["model"]),
              let model = AgenticModel.canonicalize(rawModel),
              let timestamp = UsageJSON.date(event["timestamp"]) else { return nil }
        let fields = ["inputTokens", "cacheWriteTokens", "cacheReadTokens", "outputTokens"]
        var tokens: [Int] = []
        for field in fields {
            let value = UsageJSON.number(usage[field]) ?? 0
            guard value.isFinite, value >= 0, value <= 1_000_000_000_000 else { return nil }
            tokens.append(Int(value))
        }
        let cents = UsageJSON.number(usage["totalCents"])
        if let cents, !cents.isFinite || cents < 0 { return nil }
        guard tokens.contains(where: { $0 > 0 }) || (cents ?? 0) > 0 else { return nil }
        let eventID = UsageJSON.string(event, keys: ["usageEventId"])
        // Older events have no id. Keep identical calls distinct rather than
        // collapsing real requests sharing the same timestamp and token counts.
        return AgenticUsageRecord(
            provider: .cursor,
            dedupKey: eventID.map { "cursor:\($0)" },
            model: "cursor/" + model,
            timestamp: timestamp,
            inputTokens: tokens[0], cacheWriteTokens: tokens[1], cacheWrite1hTokens: 0,
            cacheReadTokens: tokens[2], outputTokens: tokens[3], thinkingTokens: nil,
            isFast: false, nativeCostUSD: cents.map { $0 / 100 }
        )
    }
}
