import Foundation
import Testing
@testable import Pilot

@Suite("Cursor historical usage")
struct CursorUsageHistoryTests {
    private static let now = Date(timeIntervalSince1970: 1_792_650_000)
    private static let session = UsageSessions.CursorSession(
        accessToken: "test-token", userId: "github|123", expiresAt: nil
    )
    private static let event = """
    {"usageEventId":"event-1","timestamp":"1792609996888","model":"claude-opus-4-8",
     "kind":"USAGE_EVENT_KIND_INCLUDED_IN_PRO","requestsCosts":9,"usageBasedCosts":"-",
     "tokenUsage":{"inputTokens":10,"cacheWriteTokens":20,"cacheReadTokens":1000,
                   "outputTokens":30,"totalCents":1.25}}
    """

    private actor Stub {
        private(set) var requests: [URLRequest] = []
        var bodies: [String]
        var status = 200

        init(_ bodies: [String] = []) { self.bodies = bodies }

        func fail(_ code: Int = 429) { status = code }
        func recover(_ body: String) { status = 200; bodies = [body] }

        func respond(_ request: URLRequest) -> (Data, URLResponse) {
            requests.append(request)
            let body = bodies.isEmpty ? "{}" : bodies.removeFirst()
            return (Data(body.utf8), HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Retry-After": "1200"]
            )!)
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = CursorUsageHistoryTests.now

        func now() -> Date { lock.withLock { date } }
        func advance(_ seconds: TimeInterval = 601) { lock.withLock { date.addTimeInterval(seconds) } }
    }

    private func history(_ stub: Stub, clock: Clock = Clock()) -> CursorUsageHistory {
        CursorUsageHistory(
            transport: { await stub.respond($0) },
            session: { Self.session }, now: { clock.now() }
        )
    }

    private func page(_ events: String = Self.event, total: Int = 1) -> String {
        "{\"totalUsageEventsCount\":\(total),\"usageEventsDisplay\":[\(events)]}"
    }

    @Test("Included calls use native token cents and keep Cursor separate from CLI models")
    func tokenCostAndAttribution() throws {
        let object = try #require(JSONSerialization.jsonObject(with: Data(Self.event.utf8)) as? [String: Any])
        let record = try #require(CursorUsageHistory.parse(object))
        #expect(record.provider == .cursor)
        #expect(record.totalTokens == 1060)
        #expect(record.cacheReadTokens == 1000)
        #expect(record.nativeCostUSD == 0.0125)
        #expect(AgenticUsagePricing.cost(of: record) == 0.0125)
        #expect(AgenticUseModelPalette.provider(for: record.model) == .cursor)
        #expect(AgenticModel.displayName(for: record.model) == "Cursor · Opus 4.8")

        let snapshot = AgenticUsageStore.makeSnapshot(
            records: [record], range: .month, now: Self.now,
            calendar: Calendar(identifier: .gregorian)
        )
        #expect(snapshot.totalCostUSD == 0.0125)
        #expect(snapshot.stats.processedTokens == 1060)
        #expect(snapshot.dailySeries.reduce(0) { $0 + $1.cost } == 0.0125)
        #expect(!snapshot.hasUnpricedModels)
        let cli = AgenticUsageRecord(
            provider: .claude, dedupKey: "cli", model: "claude-opus-4-8", timestamp: record.timestamp,
            inputTokens: 10, cacheWriteTokens: 0, cacheWrite1hTokens: 0, cacheReadTokens: 0,
            outputTokens: 30, thinkingTokens: nil, isFast: false, nativeCostUSD: 0.02
        )
        let combined = AgenticUsageStore.makeSnapshot(
            records: [record, cli], range: .month, now: Self.now, calendar: .current
        )
        #expect(combined.modelTotals.count == 2)
        #expect(combined.totalCostUSD == 0.0325)
    }

    @Test("All pages are loaded, event ids deduplicate, and cached refreshes make no requests")
    func paginationAndCaching() async throws {
        let second = Self.event.replacingOccurrences(of: "event-1", with: "event-2")
        let stub = Stub([page(total: 3), page(Self.event + "," + second, total: 3)])
        let history = history(stub)
        let result = try await history.load(enabled: true, range: .month)
        #expect(result.records.count == 2)
        #expect(result.warning == nil)
        let requests = await stub.requests
        #expect(requests.count == 2)
        let request = try #require(requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Origin") == "https://cursor.com")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "WorkosCursorSessionToken=github%7C123%3A%3Atest-token")
        let requestData = try #require(requests[1].httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        #expect(body["page"] as? Int == 2)
        _ = try await history.load(enabled: true, range: .day)
        #expect(await stub.requests.count == 2)
        #expect(try await history.load(enabled: false, range: .all).records.isEmpty)
    }

    @Test("Disabled history reads neither credentials nor the network")
    func disabledAndMissingSessions() async throws {
        let stub = Stub()
        let disabled = CursorUsageHistory(
            transport: { await stub.respond($0) },
            session: { Issue.record("Credentials read without consent"); return nil }
        )
        #expect(try await disabled.load(enabled: false, range: .month).records.isEmpty)
        let missing = CursorUsageHistory(transport: { await stub.respond($0) }, session: { nil })
        #expect(try await missing.load(enabled: true, range: .month).warning != nil)
        #expect(await stub.requests.isEmpty)
    }

    @Test("A wider range fetches history; failures preserve previous data and honor backoff")
    func expandedRangeAndFailure() async throws {
        let stub = Stub([page(), page()])
        let clock = Clock()
        let history = history(stub, clock: clock)
        _ = try await history.load(enabled: true, range: .month)
        _ = try await history.load(enabled: true, range: .quarter)
        #expect(await stub.requests.count == 2)
        clock.advance()
        await stub.fail()
        let result = try await history.load(enabled: true, range: .quarter)
        #expect(result.records.count == 1)
        #expect(result.warning == nil)
        #expect(result.isStale)
        #expect(result.fetchedAt == Self.now)
        clock.advance()
        _ = try await history.load(enabled: true, range: .quarter)
        #expect(await stub.requests.count == 3)
    }

    @Test("Cursor's empty success response preserves older history without a refresh warning")
    func emptyIncrementalResponse() async throws {
        let stub = Stub([page(), "{}"])
        let clock = Clock()
        let history = history(stub, clock: clock)
        _ = try await history.load(enabled: true, range: .month)
        clock.advance(3 * 86_400)
        // Refresh the gap first; a subsequent empty overlap must retain the
        // older cached event and advance the successful-fetch timestamp.
        await stub.recover(page())
        _ = try await history.load(enabled: true, range: .month)
        clock.advance()
        await stub.recover("{}")
        let result = try await history.load(enabled: true, range: .month)
        #expect(result.records.count == 1)
        #expect(result.warning == nil)
        #expect(!result.isStale)
        #expect(result.fetchedAt == clock.now())
    }

    @Test("Empty first loads accept omitted default fields but reject unrelated payloads")
    func emptyFirstResponse() async throws {
        for body in ["{}", "{\"totalUsageEventsCount\":0}", page("", total: 0)] {
            let result = try await history(Stub([body])).load(enabled: true, range: .month)
            #expect(result.records.isEmpty)
            #expect(result.warning == nil)
            #expect(result.fetchedAt == Self.now)
        }
        let invalid = try await history(Stub(["{\"error\":\"unavailable\"}"])).load(enabled: true, range: .month)
        #expect(invalid.warning != nil)
        #expect(invalid.fetchedAt == nil)
    }

    @Test("Temporary server failures keep cached usage quiet, then recover automatically")
    func silentRecovery() async throws {
        let stub = Stub([page()])
        let clock = Clock()
        let history = history(stub, clock: clock)
        _ = try await history.load(enabled: true, range: .month)
        clock.advance()
        await stub.fail(503)
        let stale = try await history.load(enabled: true, range: .month)
        #expect(stale.records.count == 1)
        #expect(stale.warning == nil)
        #expect(stale.isStale)
        _ = try await history.load(enabled: true, range: .month)
        #expect(await stub.requests.count == 2)
        clock.advance(121)
        await stub.recover(page())
        let recovered = try await history.load(enabled: true, range: .month)
        #expect(recovered.records.count == 1)
        #expect(!recovered.isStale)
        #expect(recovered.warning == nil)
        #expect(recovered.fetchedAt == clock.now())
        #expect(await stub.requests.count == 3)
    }

    @Test("Malformed responses never become a complete or partial history")
    func malformedResponse() async throws {
        let stub = Stub([page(total: 2), "{}"])
        let result = try await history(stub).load(enabled: true, range: .all)
        #expect(result.records.isEmpty)
        #expect(result.warning != nil)
    }

    @Test("Incremental refresh replaces provisional costs instead of counting a call twice")
    func incrementalRefresh() async throws {
        let corrected = Self.event.replacingOccurrences(of: "1.25", with: "2.50")
        let stub = Stub([page(), page(corrected)])
        let clock = Clock()
        let history = history(stub, clock: clock)
        _ = try await history.load(enabled: true, range: .month)
        clock.advance()
        let result = try await history.load(enabled: true, range: .month)
        #expect(result.records.count == 1)
        #expect(result.records.first?.nativeCostUSD == 0.025)
    }

    @Test("Returning after a long pause fills the entire cached history gap even in a narrow range")
    func refreshAfterLongPause() async throws {
        let stub = Stub([page(), page()])
        let clock = Clock()
        let history = history(stub, clock: clock)
        _ = try await history.load(enabled: true, range: .month)
        clock.advance(7 * 86_400)
        _ = try await history.load(enabled: true, range: .day)
        let requests = await stub.requests
        let data = try #require(requests.last?.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let start = try #require(body["startDate"] as? String)
        #expect(Double(start) == (Self.now.timeIntervalSince1970 - 86_400) * 1000)
    }

    @Test("Cursor-only history populates the dashboard and disappears when consent is disabled")
    @MainActor
    func storeIntegration() async throws {
        let suite = "CursorUsageHistoryTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: UsageConsent.cursorKey)
        defaults.set("all", forKey: "agenticUse.range")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = Stub([page()])
        let store = AgenticUsageStore(
            defaults: defaults, sources: [],
            pricingCatalog: AgenticPricingCatalog(cacheURL: root.appendingPathComponent("pricing.json")) {
                throw URLError(.notConnectedToInternet)
            },
            cursorHistory: history(stub), cacheURL: nil
        )
        store.start()
        defer { store.stop() }
        let deadline = ContinuousClock.now + .seconds(10)
        while store.snapshot == nil {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.phase == .loaded)
        #expect(store.snapshot?.modelTotals.first?.model == "cursor/claude-opus-4-8")
        defaults.set(false, forKey: UsageConsent.cursorKey)
        store.rescan()
        while store.isRefreshing {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.phase == .empty)
        #expect(store.snapshot == nil)
        #expect(await stub.requests.count == 1)
    }

    @Test("Zero-cost calls stay free, missing cost stays unpriced, and invalid counts are skipped")
    func malformedEvents() throws {
        var event = try #require(JSONSerialization.jsonObject(with: Data(Self.event.utf8)) as? [String: Any])
        event["model"] = "auto"
        event["tokenUsage"] = ["inputTokens": 10, "totalCents": 0]
        let free = try #require(CursorUsageHistory.parse(event))
        #expect(AgenticUsagePricing.cost(of: free) == 0)
        event["tokenUsage"] = ["inputTokens": 10]
        #expect(CursorUsageHistory.parse(event).flatMap { AgenticUsagePricing.cost(of: $0) } == nil)
        event["tokenUsage"] = ["inputTokens": -1, "totalCents": 1]
        #expect(CursorUsageHistory.parse(event) == nil)
        event["tokenUsage"] = ["inputTokens": Double.infinity]
        #expect(CursorUsageHistory.parse(event) == nil)
    }
}
