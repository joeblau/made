import Foundation
import Testing
@testable import Pilot

@Suite("Usage credential consent")
@MainActor
struct UsageConsentTests {
    private actor FetchSequence {
        private var results: [ProviderFetch]
        private(set) var calls = 0

        init(_ results: [ProviderFetch]) { self.results = results }

        func next() -> ProviderFetch {
            calls += 1
            guard !results.isEmpty else {
                Issue.record("Unexpected extra usage request")
                return .notSignedIn
            }
            return results.removeFirst()
        }
    }

    private actor FetchProbe {
        private var providers: [String] = []

        func record(_ provider: String) -> ProviderFetch {
            providers.append(provider)
            return .notSignedIn
        }

        func recordedProviders() -> [String] {
            providers
        }
    }

    private actor SuspendedFetch {
        private var calls = 0
        private var startedWaiter: CheckedContinuation<Void, Never>?
        private var resultContinuation: CheckedContinuation<ProviderFetch, Never>?

        func run() async -> ProviderFetch {
            calls += 1
            startedWaiter?.resume()
            startedWaiter = nil
            return await withCheckedContinuation { continuation in
                resultContinuation = continuation
            }
        }

        func waitUntilStarted() async {
            guard calls == 0 else { return }
            await withCheckedContinuation { continuation in
                startedWaiter = continuation
            }
        }

        func finish(with result: ProviderFetch) {
            resultContinuation?.resume(returning: result)
            resultContinuation = nil
        }

        func callCount() -> Int {
            calls
        }
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "UsageConsentTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    @Test("Every provider is disabled by default")
    func defaultsArePrivate() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(!UsageConsent.isClaudeEnabled(defaults: defaults))
        #expect(!UsageConsent.isCodexEnabled(defaults: defaults))
        #expect(!UsageConsent.isCursorEnabled(defaults: defaults))
        #expect(!UsageConsent.isGrokEnabled(defaults: defaults))
        #expect(!UsageConsent.isKimiEnabled(defaults: defaults))
    }

    @Test("Reload performs zero provider access before opt-in")
    func noAccessBeforeConsent() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let probe = FetchProbe()
        let store = UsageStore(
            defaults: defaults,
            fetchers: .init(
                claude: { await probe.record("Claude") },
                codex: { await probe.record("Codex") },
                cursor: { await probe.record("Cursor") },
                grok: { await probe.record("Grok") },
                kimi: { await probe.record("Kimi") }
            )
        )

        store.reload()
        await store.waitForCurrentLoad()

        #expect(await probe.recordedProviders().isEmpty)
        #expect(store.anthropic == .disabled)
        #expect(store.openAI == .disabled)
        #expect(store.anysphere == .disabled)
        #expect(store.xAI == .disabled)
        #expect(store.moonshot == .disabled)
    }

    @Test("A repeated reload keeps the active request and reports loading")
    func repeatedReloadKeepsActiveRequest() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: UsageConsent.codexKey)
        let suspendedFetch = SuspendedFetch()
        let store = UsageStore(
            defaults: defaults,
            fetchers: .init(
                claude: { .notSignedIn },
                codex: { await suspendedFetch.run() },
                cursor: { .notSignedIn },
                grok: { .notSignedIn },
                kimi: { .notSignedIn }
            )
        )

        store.reload()
        #expect(store.openAI == .loading)
        await suspendedFetch.waitUntilStarted()

        store.reload()
        #expect(store.openAI == .loading)
        #expect(await suspendedFetch.callCount() == 1)

        await suspendedFetch.finish(with: .notSignedIn)
        await store.waitForCurrentLoad()
        #expect(store.openAI == .notSignedIn)
    }

    @Test("Only an opted-in provider may reach its credential and network boundary")
    func consentIsPerProviderAndRevocable() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: UsageConsent.codexKey)
        let probe = FetchProbe()
        let store = UsageStore(
            defaults: defaults,
            fetchers: .init(
                claude: { await probe.record("Claude") },
                codex: { await probe.record("Codex") },
                cursor: { await probe.record("Cursor") },
                grok: { await probe.record("Grok") },
                kimi: { await probe.record("Kimi") }
            )
        )

        store.reload()
        await store.waitForCurrentLoad()

        #expect(await probe.recordedProviders() == ["Codex"])
        defaults.set(false, forKey: UsageConsent.codexKey)
        store.reload()
        await store.waitForCurrentLoad()
        #expect(store.openAI == .disabled)
    }

    @Test("A 429 honors a longer Retry-After and blocks requests past the normal spacing")
    func rateLimitBacksOffProvider() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: UsageConsent.codexKey)
        let probe = FetchProbe()
        var clock = Date(timeIntervalSince1970: 1_790_000_000)
        let store = UsageStore(
            defaults: defaults,
            fetchers: .init(
                claude: { .notSignedIn },
                codex: {
                    _ = await probe.record("Codex")
                    return .rateLimited(retryAfter: 900)
                },
                cursor: { .notSignedIn },
                grok: { .notSignedIn },
                kimi: { .notSignedIn }
            ),
            now: { clock }
        )

        store.reload()
        await store.waitForCurrentLoad()
        let deadline = clock.addingTimeInterval(900)
        #expect(store.openAI == .rateLimited(until: deadline, usage: nil))

        // Five minutes on, the two-minute spacing has expired and the
        // exponential backoff alone (5 minutes for one strike) would allow a
        // retry, so only the 15-minute Retry-After can still block it.
        clock += 5 * 60 + 1
        store.reload()
        await store.waitForCurrentLoad()
        #expect(await probe.recordedProviders() == ["Codex"])
        #expect(store.openAI == .rateLimited(until: deadline, usage: nil))

        // Once the Retry-After window passes, the provider is fetched again.
        clock += 10 * 60
        store.reload()
        await store.waitForCurrentLoad()
        #expect(await probe.recordedProviders() == ["Codex", "Codex"])
    }

    @Test("Claude uses server retry hints without inflating or truncating them")
    func claudeRetryHintsOverrideFallback() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: UsageConsent.claudeKey)
        let sequence = FetchSequence([
            .rateLimited(retryAfter: nil), .rateLimited(retryAfter: nil),
            .rateLimited(retryAfter: 60), .rateLimited(retryAfter: 7200), .success(ProviderUsage()),
        ])
        var clock = Date(timeIntervalSince1970: 1_790_000_000)
        let store = UsageStore(defaults: defaults, fetchers: .init(
            claude: { await sequence.next() }, codex: { .notSignedIn },
            cursor: { .notSignedIn }, grok: { .notSignedIn }, kimi: { .notSignedIn }
        ), now: { clock })

        for (index, delay) in [300.0, 600.0, 120.0, 7200.0].enumerated() {
            store.reload()
            await store.waitForCurrentLoad()
            let deadline = clock.addingTimeInterval(delay)
            #expect(store.anthropic == .rateLimited(until: deadline, usage: nil))
            clock = deadline.addingTimeInterval(-1)
            store.reload()
            await store.waitForCurrentLoad()
            #expect(await sequence.calls == index + 1)
            clock = deadline
        }
        store.reload()
        await store.waitForCurrentLoad()
        #expect(store.anthropic == .usage(ProviderUsage()))
        #expect(await sequence.calls == 5)
    }

    @Test("Polling retries automatically at the countdown deadline", .timeLimit(.minutes(1)))
    func automaticallyRetriesAtDeadline() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: UsageConsent.claudeKey)
        let sequence = FetchSequence([.rateLimited(retryAfter: 300), .success(ProviderUsage())])
        let requests = AsyncStream.makeStream(of: Void.self)
        defer { requests.continuation.finish() }
        var clock = Date(timeIntervalSince1970: 1_790_000_000)
        let store = UsageStore(defaults: defaults, fetchers: .init(
            claude: {
                let result = await sequence.next()
                requests.continuation.yield(())
                return result
            },
            codex: { .notSignedIn }, cursor: { .notSignedIn }, grok: { .notSignedIn }, kimi: { .notSignedIn }
        ), now: { clock })
        defer { store.stop() }
        store.start()
        await store.waitForCurrentLoad()
        var events = requests.stream.makeAsyncIterator()
        _ = await events.next()

        // Re-arm just before the deadline, then let the timer itself fetch.
        // Advancing the injected clock avoids waiting five real minutes.
        clock += 299.99
        store.reload()
        clock += 0.01
        try #require(await events.next() != nil)
        await store.waitForCurrentLoad()
        #expect(await sequence.calls == 2)
        #expect(store.anthropic == .usage(ProviderUsage()))
    }

    @Test("Fallback backoff caps at an hour and resets after recovery")
    func fallbackBackoffResetsAfterSuccess() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: UsageConsent.claudeKey)
        let sequence = FetchSequence(
            Array(repeating: .rateLimited(retryAfter: nil), count: 6)
                + [.success(ProviderUsage()), .rateLimited(retryAfter: .infinity)]
        )
        var clock = Date(timeIntervalSince1970: 1_790_000_000)
        let store = UsageStore(defaults: defaults, fetchers: .init(
            claude: { await sequence.next() }, codex: { .notSignedIn },
            cursor: { .notSignedIn }, grok: { .notSignedIn }, kimi: { .notSignedIn }
        ), now: { clock })

        for delay in [300.0, 600.0, 1200.0, 2400.0, 3600.0, 3600.0] {
            store.reload()
            await store.waitForCurrentLoad()
            clock += delay
            #expect(store.anthropic == .rateLimited(until: clock, usage: nil))
        }
        store.reload()
        await store.waitForCurrentLoad()
        clock += 600
        store.reload()
        await store.waitForCurrentLoad()
        #expect(store.anthropic == .rateLimited(until: clock.addingTimeInterval(300), usage: ProviderUsage()))
    }

    @Test("Rate limits preserve usage across repeated failures, manual refresh, and stop/start")
    func rateLimitPreservesUsageAndDeadline() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: UsageConsent.claudeKey)
        defaults.set(true, forKey: UsageConsent.codexKey)
        let usage = ProviderUsage(planLabel: "Max", windows: [
            UsageWindow(id: "five_hour", name: "5-hour", utilization: 0.25, resetsAt: nil),
        ])
        let sequence = FetchSequence([
            .success(usage), .rateLimited(retryAfter: 900), .rateLimited(retryAfter: 300), .success(usage),
        ])
        let codex = FetchProbe()
        var clock = Date(timeIntervalSince1970: 1_790_000_000)
        let store = UsageStore(defaults: defaults, fetchers: .init(
            claude: { await sequence.next() }, codex: { await codex.record("Codex") },
            cursor: { .notSignedIn }, grok: { .notSignedIn }, kimi: { .notSignedIn }
        ), now: { clock })
        defer { store.stop() }

        store.start()
        await store.waitForCurrentLoad()
        clock += 600
        store.reload()
        await store.waitForCurrentLoad()
        let deadline = clock.addingTimeInterval(900)
        #expect(store.anthropic == .rateLimited(until: deadline, usage: usage))
        #expect(store.anthropic.displayedUsage == usage)

        store.stop()
        clock += 600
        store.start()
        await store.waitForCurrentLoad()
        #expect(await sequence.calls == 2)
        #expect(await codex.recordedProviders().count == 3)
        #expect(store.anthropic == .rateLimited(until: deadline, usage: usage))

        clock = deadline
        store.reload()
        await store.waitForCurrentLoad()
        #expect(store.anthropic == .rateLimited(until: clock.addingTimeInterval(300), usage: usage))
        clock += 300
        store.reload()
        await store.waitForCurrentLoad()
        #expect(store.anthropic == .usage(usage))
        #expect(await sequence.calls == 4)
    }

    @Test("Kimi credential access is independently opted in and revocable")
    func kimiConsentIsIndependentAndRevocable() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: UsageConsent.kimiKey)
        let probe = FetchProbe()
        let store = UsageStore(
            defaults: defaults,
            fetchers: .init(
                claude: { await probe.record("Claude") },
                codex: { await probe.record("Codex") },
                cursor: { await probe.record("Cursor") },
                grok: { await probe.record("Grok") },
                kimi: { await probe.record("Kimi") }
            )
        )

        store.reload()
        await store.waitForCurrentLoad()

        #expect(await probe.recordedProviders() == ["Kimi"])
        defaults.set(false, forKey: UsageConsent.kimiKey)
        store.reload()
        await store.waitForCurrentLoad()
        #expect(store.moonshot == .disabled)
    }

    @Test("Cursor credential access is independently opted in and revocable")
    func cursorConsentIsIndependentAndRevocable() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: UsageConsent.cursorKey)
        let probe = FetchProbe()
        let store = UsageStore(
            defaults: defaults,
            fetchers: .init(
                claude: { await probe.record("Claude") },
                codex: { await probe.record("Codex") },
                cursor: { await probe.record("Cursor") },
                grok: { await probe.record("Grok") },
                kimi: { await probe.record("Kimi") }
            )
        )

        store.reload()
        await store.waitForCurrentLoad()

        #expect(await probe.recordedProviders() == ["Cursor"])
        defaults.set(false, forKey: UsageConsent.cursorKey)
        store.reload()
        await store.waitForCurrentLoad()
        #expect(store.anysphere == .disabled)
    }
}
