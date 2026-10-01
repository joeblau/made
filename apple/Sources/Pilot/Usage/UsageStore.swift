import Foundation

enum UsageConsent {
    static let claudeKey = "usage.consent.claude"
    static let codexKey = "usage.consent.codex"
    static let grokKey = "usage.consent.grok"
    static let kimiKey = "usage.consent.kimi"
    static let changedNotification = Notification.Name("app.blau.pilot.usage-consent-changed")

    static func isClaudeEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: claudeKey)
    }

    static func isCodexEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: codexKey)
    }

    static func isGrokEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: grokKey)
    }

    static func isKimiEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: kimiKey)
    }
}

/// Pulls **plan usage, reset windows, and credits** for Claude, Codex, Grok, and
/// Kimi by reusing the local CLI OAuth sessions (see `UsageSessions`)
/// and calling each CLI's own usage endpoint — no admin keys, no separate login.
///
/// The store owns consent, polling, spacing, and rate-limit backoff. The
/// provider adapters in `Usage/Providers` own each request and its tolerant
/// parsing of these undocumented endpoints.
@Observable
@MainActor
final class UsageStore {
    struct Fetchers: Sendable {
        let claude: @Sendable () async -> ProviderFetch
        let codex: @Sendable () async -> ProviderFetch
        let grok: @Sendable () async -> ProviderFetch
        let kimi: @Sendable () async -> ProviderFetch

        /// Each closure reads its CLI credential only when invoked, and the
        /// store invokes it only for an opted-in provider.
        static let live = Fetchers(
            claude: { await ClaudeUsageAdapter.fetch(session: UsageSessions.ClaudeSession.load()) },
            codex: { await CodexUsageAdapter.fetch(session: UsageSessions.CodexSession.load()) },
            grok: {
                // Read the installed version only once a session exists.
                guard let session = UsageSessions.GrokSession.load() else { return .notSignedIn }
                return await GrokUsageAdapter.fetch(
                    session: session,
                    clientVersion: UsageSessions.GrokSession.installedVersion()
                )
            },
            kimi: { await KimiUsageAdapter.fetch(session: UsageSessions.KimiSession.load()) }
        )
    }

    private(set) var anthropic: ProviderState = .disabled
    private(set) var openAI: ProviderState = .disabled
    private(set) var xAI: ProviderState = .disabled
    private(set) var moonshot: ProviderState = .disabled
    private(set) var isLoading = false

    private var loadTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var activeProviders: Set<Provider> = []
    private let defaults: UserDefaults
    private let fetchers: Fetchers
    /// Wall clock for spacing and backoff; injectable for tests.
    private let now: () -> Date

    /// These are undocumented, aggressively rate-limited endpoints. Poll rarely —
    /// reset countdowns tick client-side, so the network data only needs to be
    /// roughly current. On top of this we enforce per-provider spacing + backoff
    /// so we never hammer an endpoint (and risk a ban).
    private static let pollInterval: TimeInterval = 600            // 10 min
    /// Never hit the same provider more often than this, even on manual refresh
    /// or tab switches.
    private static let minSpacing: TimeInterval = 120             // 2 min
    /// Backoff schedule after a 429, doubling per consecutive strike.
    private static let backoffBase: TimeInterval = 300           // 5 min
    private static let backoffCap: TimeInterval = 3600           // 1 hour

    private enum Provider: CaseIterable { case anthropic, openAI, xAI, moonshot }
    /// When a provider was last actually hit (for min-spacing).
    private var lastAttempt: [Provider: Date] = [:]
    /// When a rate-limited provider may be hit again.
    private var blockedUntil: [Provider: Date] = [:]
    /// Consecutive 429 count per provider (drives the exponential backoff).
    private var rateLimitStrikes: [Provider: Int] = [:]

    init(defaults: UserDefaults = .standard, fetchers: Fetchers = .live, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.fetchers = fetchers
        self.now = now
    }

    /// Begin (or restart) periodic refresh. Safe to call repeatedly.
    func start() {
        reload()
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { _ in
            Task { @MainActor in self.reload() }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        // A cancelled request did not produce a reusable result. Let the next
        // presentation retry immediately instead of leaving a loading card
        // stranded behind the normal two-minute request spacing.
        for provider in activeProviders {
            lastAttempt[provider] = nil
        }
        activeProviders.removeAll()
    }

    /// May we hit `provider` right now? Respects both the rate-limit backoff and
    /// the minimum spacing between attempts.
    private func mayFetch(_ provider: Provider, now: Date) -> Bool {
        if let until = blockedUntil[provider], now < until { return false }
        if let last = lastAttempt[provider], now.timeIntervalSince(last) < Self.minSpacing { return false }
        return true
    }

    /// Detect sessions and fetch providers that aren't spaced-out or backed-off.
    func reload() {
        let now = self.now()
        let claudeEnabled = UsageConsent.isClaudeEnabled(defaults: defaults)
        let codexEnabled = UsageConsent.isCodexEnabled(defaults: defaults)
        let grokEnabled = UsageConsent.isGrokEnabled(defaults: defaults)
        let kimiEnabled = UsageConsent.isKimiEnabled(defaults: defaults)
        if !claudeEnabled { anthropic = .disabled }
        if !codexEnabled { openAI = .disabled }
        if !grokEnabled { xAI = .disabled }
        if !kimiEnabled { moonshot = .disabled }

        // Multiple view lifecycle events can request a refresh together when
        // the inspector is presented. Keep the in-flight load: cancelling it
        // here records an attempt, then the spacing guard prevents its
        // replacement from running and leaves the cards without a result.
        guard loadTask == nil else { return }

        let doAnthropic = claudeEnabled && mayFetch(.anthropic, now: now)
        let doOpenAI = codexEnabled && mayFetch(.openAI, now: now)
        let doGrok = grokEnabled && mayFetch(.xAI, now: now)
        let doKimi = kimiEnabled && mayFetch(.moonshot, now: now)
        if doAnthropic {
            lastAttempt[.anthropic] = now
            if case .usage = anthropic {} else { anthropic = .loading }
        }
        if doOpenAI {
            lastAttempt[.openAI] = now
            if case .usage = openAI {} else { openAI = .loading }
        }
        if doGrok {
            lastAttempt[.xAI] = now
            if case .usage = xAI {} else { xAI = .loading }
        }
        if doKimi {
            lastAttempt[.moonshot] = now
            if case .usage = moonshot {} else { moonshot = .loading }
        }

        // Nothing to do this tick — everything is spaced-out or backed-off.
        guard doAnthropic || doOpenAI || doGrok || doKimi else {
            isLoading = false
            return
        }

        isLoading = true
        activeProviders = Set([
            doAnthropic ? Provider.anthropic : nil,
            doOpenAI ? Provider.openAI : nil,
            doGrok ? Provider.xAI : nil,
            doKimi ? Provider.moonshot : nil,
        ].compactMap { $0 })
        let fetchers = fetchers
        loadTask = Task {
            async let anthropicResult = Self.fetch(when: doAnthropic, using: fetchers.claude)
            async let openAIResult = Self.fetch(when: doOpenAI, using: fetchers.codex)
            async let xAIResult = Self.fetch(when: doGrok, using: fetchers.grok)
            async let moonshotResult = Self.fetch(when: doKimi, using: fetchers.kimi)
            let (aRes, oRes, xRes, kRes) = await (
                anthropicResult,
                openAIResult,
                xAIResult,
                moonshotResult
            )
            if Task.isCancelled { return }
            anthropic = UsageConsent.isClaudeEnabled(defaults: defaults)
                ? resolve(.anthropic, previous: anthropic, result: aRes)
                : .disabled
            openAI = UsageConsent.isCodexEnabled(defaults: defaults)
                ? resolve(.openAI, previous: openAI, result: oRes)
                : .disabled
            xAI = UsageConsent.isGrokEnabled(defaults: defaults)
                ? resolve(.xAI, previous: xAI, result: xRes)
                : .disabled
            moonshot = UsageConsent.isKimiEnabled(defaults: defaults)
                ? resolve(.moonshot, previous: moonshot, result: kRes)
                : .disabled
            isLoading = false
            activeProviders.removeAll()
            loadTask = nil
            // Pick up a provider enabled while this batch was in flight. The
            // spacing guard skips every provider that just completed.
            reload()
        }
    }

    func waitForCurrentLoad() async {
        await loadTask?.value
    }

    nonisolated private static func fetch(
        when allowed: Bool,
        using operation: @Sendable () async -> ProviderFetch
    ) async -> ProviderFetch {
        guard allowed else { return .skipped }
        return await operation()
    }

    /// Fold a fetch result into the provider's state and update its backoff.
    private func resolve(_ provider: Provider, previous: ProviderState, result: ProviderFetch) -> ProviderState {
        switch result {
        case .success(let usage):
            rateLimitStrikes[provider] = 0
            blockedUntil[provider] = nil
            return .usage(usage)

        case .notSignedIn:
            rateLimitStrikes[provider] = 0
            blockedUntil[provider] = nil
            return .notSignedIn

        case .rateLimited(let retryAfter):
            let strikes = (rateLimitStrikes[provider] ?? 0) + 1
            rateLimitStrikes[provider] = strikes
            let delay = Self.backoffDelay(strikes: strikes, retryAfter: retryAfter)
            blockedUntil[provider] = now().addingTimeInterval(delay)
            if case .usage = previous { return previous } // keep showing last data
            return .error("Rate limited — backing off ~\(Int((delay / 60).rounded()))m.")

        case .failure(let message):
            if case .usage = previous { return previous }
            return .error(message)

        case .skipped:
            // Spaced-out or backed-off this tick; keep whatever we last showed.
            if case .usage = previous { return previous }
            let current = now()
            if let until = blockedUntil[provider], current < until {
                let remaining = Int((until.timeIntervalSince(current) / 60).rounded(.up))
                return .error("Rate limited — retrying in ~\(max(1, remaining))m.")
            }
            return previous
        }
    }

    /// Exponential backoff, honoring a server `Retry-After` when longer.
    private static func backoffDelay(strikes: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let exponential = min(backoffBase * pow(2, Double(max(0, strikes - 1))), backoffCap)
        if let retryAfter, retryAfter > 0 {
            return min(max(retryAfter, exponential), backoffCap)
        }
        return exponential
    }
}
