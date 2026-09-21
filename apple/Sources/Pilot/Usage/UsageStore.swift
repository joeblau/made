import Foundation

/// A single usage window (rolling quota) for a provider — e.g. Codex's 5-hour
/// and weekly windows, or Claude's five-hour / seven-day windows.
struct UsageWindow: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    /// Fraction used, 0...1.
    let utilization: Double
    /// When this window's quota resets, if known.
    let resetsAt: Date?
}

/// Credit balance / allowance, when the provider reports one.
enum CreditUnit: Equatable, Sendable {
    case credits
    case currency(String)
}

struct CreditInfo: Equatable, Sendable {
    var balance: Double? = nil
    var unit: CreditUnit = .credits
    var used: Double? = nil
    var limit: Double? = nil
    var unlimited: Bool = false
    /// Monthly-credit utilization (0...1), when reported instead of a balance.
    var utilization: Double? = nil

    var isEmpty: Bool {
        balance == nil && used == nil && limit == nil && !unlimited && utilization == nil
    }
}

/// Plan usage for one provider.
struct ProviderUsage: Equatable, Sendable {
    var planLabel: String?
    var windows: [UsageWindow] = []
    var credits: CreditInfo?

    /// Present short rolling limits first and weekly summaries last. Providers
    /// do not consistently return their windows in duration order (Kimi, for
    /// example, returns the weekly summary before its five-hour limit).
    var windowsInDisplayOrder: [UsageWindow] {
        windows.enumerated()
            .sorted { lhs, rhs in
                let lhsRank = lhs.element.displayOrderRank
                let rhsRank = rhs.element.displayOrderRank
                return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
            }
            .map(\.element)
    }
}

private extension UsageWindow {
    var displayOrderRank: Int {
        let normalizedName = name.lowercased()
        if normalizedName.contains("hour") || normalizedName.contains("h limit") {
            return 0
        }
        if normalizedName.contains("week") {
            return 2
        }
        return 1
    }
}

/// Per-provider fetch state for the inspector.
enum ProviderState: Equatable, Sendable {
    case disabled
    case loading
    case notSignedIn
    case usage(ProviderUsage)
    case error(String)
}

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
/// ⚠️ These are undocumented endpoints the CLIs call internally; they can change.
/// Access is read-only; expired tokens surface a "re-run the CLI" message.
@Observable
@MainActor
final class UsageStore {
    struct Fetchers: Sendable {
        let claude: @Sendable () async -> ProviderFetch
        let codex: @Sendable () async -> ProviderFetch
        let grok: @Sendable () async -> ProviderFetch
        let kimi: @Sendable () async -> ProviderFetch

        static let live = Fetchers(
            claude: { await UsageStore.fetchClaude() },
            codex: { await UsageStore.fetchCodex() },
            grok: { await UsageStore.fetchGrok() },
            kimi: { await UsageStore.fetchKimi() }
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

    init(defaults: UserDefaults = .standard, fetchers: Fetchers = .live) {
        self.defaults = defaults
        self.fetchers = fetchers
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
        let now = Date()
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
            blockedUntil[provider] = Date().addingTimeInterval(delay)
            if case .usage = previous { return previous } // keep showing last data
            return .error("Rate limited — backing off ~\(Int((delay / 60).rounded()))m.")

        case .failure(let message):
            if case .usage = previous { return previous }
            return .error(message)

        case .skipped:
            // Spaced-out or backed-off this tick; keep whatever we last showed.
            if case .usage = previous { return previous }
            if let until = blockedUntil[provider], Date() < until {
                let remaining = Int((until.timeIntervalSinceNow / 60).rounded(.up))
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

    // MARK: - Codex (OpenAI)

    nonisolated private static func fetchCodex() async -> ProviderFetch {
        guard let session = UsageSessions.CodexSession.load() else { return .notSignedIn }

        var headers = [
            "Authorization": "Bearer \(session.accessToken)",
            "Accept": "application/json",
            "OpenAI-Beta": "codex-1",
            "originator": "Codex Desktop",
            "User-Agent": "codex-cli",
        ]
        if let account = session.accountId { headers["ChatGPT-Account-Id"] = account }

        let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        let root: [String: Any]
        do {
            root = try await getJSONObject(url: url, headers: headers)
        } catch {
            return classify(error, provider: "Codex", cli: "codex")
        }

        return .success(Self.parseCodexUsage(root, receivedAt: Date()))
    }

    nonisolated static func parseCodexUsage(
        _ root: [String: Any],
        receivedAt: Date = Date()
    ) -> ProviderUsage {
        let rootPlan = string(root, keys: ["plan_type", "planType"])
        var usage = ProviderUsage(planLabel: rootPlan?.replacingOccurrences(of: "_", with: " ").capitalized)

        func appendRateLimit(
            _ rateLimit: [String: Any],
            idPrefix: String,
            displayName: String? = nil
        ) {
            if usage.planLabel == nil,
               let plan = Self.string(rateLimit, keys: ["plan_type", "planType"])
            {
                usage.planLabel = plan.replacingOccurrences(of: "_", with: " ").capitalized
            }

            let primary = Self.dictionary(
                rateLimit,
                keys: ["primary_window", "primaryWindow", "primary"]
            )
            let secondary = Self.dictionary(
                rateLimit,
                keys: ["secondary_window", "secondaryWindow", "secondary"]
            )
            // Keep the pool's label on every window — Codex returns a main
            // rate limit plus scoped "additional" pools that share the same
            // 5-hour/weekly cadence, so the label is what tells them apart.
            if let primary,
               let window = Self.codexWindow(
                primary,
                id: "\(idPrefix)-primary",
                displayName: displayName,
                receivedAt: receivedAt)
            {
                usage.windows.append(window)
            }
            if let secondary,
               let window = Self.codexWindow(
                secondary,
                id: "\(idPrefix)-secondary",
                displayName: displayName,
                receivedAt: receivedAt)
            {
                usage.windows.append(window)
            }
            if usage.credits == nil,
               let credits = Self.dictionary(rateLimit, keys: ["credits"])
            {
                usage.credits = Self.codexCredits(credits)
            }
        }

        if let rateLimit = dictionary(root, keys: ["rate_limit", "rateLimits", "rate_limits"]) {
            appendRateLimit(rateLimit, idPrefix: "codex")
        }

        if let additional = (root["additional_rate_limits"] ?? root["additionalRateLimits"])
            as? [[String: Any]]
        {
            for (index, entry) in additional.enumerated() {
                let id = string(entry, keys: ["limit_id", "limitId", "metered_feature", "meteredFeature"])
                    ?? "additional-\(index)"
                let label = string(entry, keys: ["limit_name", "limitName", "metered_feature", "meteredFeature"])
                    ?? (id.hasPrefix("additional-")
                        ? "Additional \(index + 1)"
                        : id.replacingOccurrences(of: "_", with: " "))
                let rateLimit = dictionary(entry, keys: ["rate_limit", "rateLimits"]) ?? entry
                appendRateLimit(
                    rateLimit,
                    idPrefix: "codex-\(id)-\(index)",
                    displayName: label
                )
            }
        }

        if let buckets = (root["rateLimitsByLimitId"] ?? root["rate_limits_by_limit_id"])
            as? [String: Any]
        {
            for key in buckets.keys.sorted() where key != "codex" {
                guard let bucket = buckets[key] as? [String: Any] else { continue }
                let label = string(bucket, keys: ["limitName", "limit_name"])
                    ?? key.replacingOccurrences(of: "_", with: " ")
                appendRateLimit(bucket, idPrefix: "codex-\(key)", displayName: label)
            }
        }

        if let credits = dictionary(root, keys: ["credits"]) {
            usage.credits = codexCredits(credits)
        }
        return usage
    }

    nonisolated private static func codexWindow(
        _ dict: [String: Any],
        id: String,
        displayName: String?,
        receivedAt: Date
    ) -> UsageWindow? {
        guard let usedPercent = number(dict, keys: ["used_percent", "usedPercent"]),
              usedPercent.isFinite else { return nil }
        let seconds = windowSeconds(dict)
        let absoluteReset = date(value(dict, keys: ["reset_at", "resets_at", "resetsAt"]))
        let resetAfter = number(dict, keys: ["reset_after_seconds", "resetAfterSeconds"])
        let resetsAt = absoluteReset ?? resetAfter.map { receivedAt.addingTimeInterval(max(0, $0)) }
        let generatedName = windowName(seconds: seconds)
        let name = displayName.flatMap { label in
            let cleaned = label.replacingOccurrences(of: "_", with: " ").capitalized
            return generatedName == "Usage" ? cleaned : "\(cleaned) · \(generatedName)"
        } ?? generatedName
        return UsageWindow(
            id: id,
            name: name,
            utilization: min(max(usedPercent / 100.0, 0), 1),
            resetsAt: resetsAt
        )
    }

    nonisolated private static func codexCredits(_ dict: [String: Any]) -> CreditInfo? {
        let hasCredits = bool(dict, keys: ["has_credits", "hasCredits"])
        guard hasCredits != false else { return nil }
        let info = CreditInfo(
            balance: number(dict, keys: ["balance"]),
            unit: .credits,
            unlimited: bool(dict, keys: ["unlimited"]) ?? false
        )
        return info.isEmpty ? nil : info
    }

    // MARK: - Claude (Claude Code)

    nonisolated private static func fetchClaude() async -> ProviderFetch {
        guard let session = UsageSessions.ClaudeSession.load() else { return .notSignedIn }
        guard session.hasProfileScope else {
            return .failure("Claude: this session lacks the user:profile scope — re-run `claude` to sign in.")
        }

        let headers = [
            "Authorization": "Bearer \(session.accessToken)",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-cli/2.1.0 (external, cli)",
        ]
        let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        let root: [String: Any]
        do {
            root = try await getJSONObject(url: url, headers: headers)
        } catch {
            return classify(error, provider: "Claude", cli: "claude")
        }

        return .success(Self.parseClaudeUsage(root, planLabel: session.subscriptionType))
    }

    nonisolated static func parseClaudeUsage(
        _ root: [String: Any],
        planLabel: String? = nil
    ) -> ProviderUsage {
        var usage = ProviderUsage(
            planLabel: planLabel?.replacingOccurrences(of: "_", with: " ").capitalized
        )
        // Account-level windows.
        let account: [(String, String)] = [
            ("five_hour", "5-hour"),
            ("seven_day", "Weekly"),
            ("seven_day_oauth_apps", "Weekly (apps)"),
        ]
        for (key, label) in account {
            if let window = root[key] as? [String: Any],
               let parsed = Self.claudeWindow(id: "claude-\(key)", name: label, window)
            {
                usage.windows.append(parsed)
            }
        }

        // Model-scoped windows (e.g. Fable, Opus, Sonnet). The newer `limits`
        // array names the model via `scope.model.display_name` and supersedes the
        // flat `seven_day_<model>` fields, so track which models it covers.
        var scopedModels = Set<String>()
        if let limits = root["limits"] as? [[String: Any]] {
            for (index, entry) in limits.enumerated() {
                guard bool(entry, keys: ["is_active", "isActive"]) != false,
                      let model = Self.claudeLimitModel(entry),
                      let percent = number(entry, keys: ["percent", "utilization"]), percent.isFinite
                else { continue }
                scopedModels.insert(model.lowercased())
                usage.windows.append(UsageWindow(
                    id: "claude-limit-\(index)",
                    name: "\(Self.claudeLimitPeriod(entry)) (\(model))",
                    utilization: min(max(percent / 100.0, 0), 1),
                    resetsAt: date(value(entry, keys: ["resets_at", "resetsAt"]))
                ))
            }
        }

        // Flat model-scoped fields, only when `limits` didn't already cover them.
        let flatScoped: [(String, String, String)] = [
            ("seven_day_opus", "Weekly (Opus)", "opus"),
            ("seven_day_sonnet", "Weekly (Sonnet)", "sonnet"),
        ]
        for (key, label, model) in flatScoped where !scopedModels.contains(model) {
            if let window = root[key] as? [String: Any],
               let parsed = Self.claudeWindow(id: "claude-\(key)", name: label, window)
            {
                usage.windows.append(parsed)
            }
        }

        if let extra = root["extra_usage"] as? [String: Any],
           bool(extra, keys: ["is_enabled", "isEnabled"]) != false
        {
            let used = number(extra, keys: ["used_credits", "usedCredits"]).map { $0 / 100.0 }
            let limit = number(extra, keys: ["monthly_limit", "monthlyLimit"]).map { $0 / 100.0 }
            let rawUtilization = number(extra, keys: ["utilization"])
            let utilization = rawUtilization.map { min(max($0 / 100.0, 0), 1) }
            let currency = string(extra, keys: ["currency"])?.uppercased() ?? "USD"
            let monthlyLimitValue = value(extra, keys: ["monthly_limit", "monthlyLimit"])
            let unlimited = monthlyLimitValue is NSNull
            let credits = CreditInfo(
                balance: nil,
                unit: .currency(currency),
                used: used,
                limit: limit,
                unlimited: unlimited,
                utilization: utilization
            )
            if !credits.isEmpty { usage.credits = credits }
        }
        return usage
    }

    nonisolated private static func claudeWindow(
        id: String,
        name: String,
        _ dict: [String: Any]
    ) -> UsageWindow? {
        // Claude reports utilization as a percentage in the 0...100 range.
        guard let raw = number(dict, keys: ["utilization"]), raw.isFinite else { return nil }
        return UsageWindow(
            id: id,
            name: name,
            utilization: min(max(raw / 100.0, 0), 1),
            resetsAt: date(value(dict, keys: ["resets_at", "resetsAt"]))
        )
    }

    /// The model a scoped `limits[]` entry applies to (e.g. "Fable"), if any.
    nonisolated private static func claudeLimitModel(_ entry: [String: Any]) -> String? {
        if let scope = entry["scope"] as? [String: Any] {
            if let model = scope["model"] as? [String: Any],
               let name = string(model, keys: ["display_name", "displayName", "name", "id"])
            {
                return name
            }
            if let name = string(scope, keys: ["display_name", "displayName", "name", "model"]) {
                return name
            }
        }
        return string(entry, keys: ["display_name", "displayName", "name"])
    }

    /// The window period for a scoped `limits[]` entry, inferred from its
    /// `group`/`kind` hint (scoped limits are weekly by default).
    nonisolated private static func claudeLimitPeriod(_ entry: [String: Any]) -> String {
        let hint = (string(entry, keys: ["group", "kind", "window", "period"]) ?? "").lowercased()
        if hint.contains("week") || hint.contains("7d") || hint.contains("seven") { return "Weekly" }
        if hint.contains("hour") || hint.contains("5h") || hint.contains("five") { return "5-hour" }
        if hint.contains("month") { return "Monthly" }
        if hint.contains("day") { return "Daily" }
        return "Weekly"
    }

    // MARK: - Kimi (Moonshot AI)

    nonisolated private static func fetchKimi() async -> ProviderFetch {
        guard let session = UsageSessions.KimiSession.load() else { return .notSignedIn }
        guard !session.isExpired else {
            return .failure("Kimi: session expired — re-run `kimi login` to sign in.")
        }
        let headers = [
            "Authorization": "Bearer \(session.accessToken)",
            "Accept": "application/json",
        ]
        let url = URL(string: "https://api.kimi.ai/coding/v1/usages")!
        do {
            let root = try await getJSONObject(url: url, headers: headers)
            return .success(Self.parseKimiUsage(root, receivedAt: Date()))
        } catch {
            return classify(error, provider: "Kimi", cli: "kimi login")
        }
    }

    /// Parse Kimi Code's intentionally loose usage schema: a weekly summary,
    /// rolling limit rows, and an optional Extra Usage booster wallet.
    nonisolated static func parseKimiUsage(
        _ root: [String: Any],
        receivedAt: Date = Date()
    ) -> ProviderUsage {
        var usage = ProviderUsage(planLabel: kimiPlanLabel(root))
        if let summary = dictionary(root, keys: ["usage"]),
           let window = kimiWindow(
               summary,
               id: "kimi-summary",
               defaultName: "Weekly limit",
               receivedAt: receivedAt) {
            usage.windows.append(window)
        }

        if let limits = root["limits"] as? [Any] {
            for (index, rawLimit) in limits.enumerated() {
                guard let item = rawLimit as? [String: Any] else { continue }
                let detail = dictionary(item, keys: ["detail"]) ?? item
                let metadata = dictionary(item, keys: ["window"]) ?? [:]
                let label = kimiLimitLabel(
                    item: item,
                    detail: detail,
                    window: metadata,
                    index: index
                )
                if let window = kimiWindow(
                    detail,
                    id: "kimi-limit-\(index)",
                    defaultName: label,
                    receivedAt: receivedAt) {
                    usage.windows.append(window)
                }
            }
        }

        if let wallet = dictionary(root, keys: ["boosterWallet", "booster_wallet"]) {
            usage.credits = kimiCredits(wallet)
        }
        return usage
    }

    /// Kimi's usage endpoint reports no public plan title, and its
    /// `membership.level` is a coarse legacy field — a Vivace account returns
    /// `LEVEL_STANDARD` (verified against the live endpoint), so the old
    /// level→plan mapping mislabeled paid tiers. The reliable tier signal is
    /// the Kimi Code credit multiplier in `parallel.limit`: the official plan
    /// table's Kimi Code credits row is 1×/5×/15×/30× for
    /// Moderato/Allegretto/Allegro/Vivace. Prefer an explicit title when the
    /// service includes one, then the multiplier, then the free level; hide
    /// the badge rather than show a wrong one.
    nonisolated private static func kimiPlanLabel(_ root: [String: Any]) -> String? {
        let user = dictionary(root, keys: ["user"]) ?? [:]
        let membership = dictionary(user, keys: ["membership"])
            ?? dictionary(root, keys: ["membership"])
            ?? [:]

        if let title = string(
            membership,
            keys: ["title", "name", "displayName", "display_name", "planName", "plan_name"]
        ) {
            return title
        }

        if let parallel = dictionary(root, keys: ["parallel"]),
           let limit = number(parallel, keys: ["limit"]) {
            switch limit {
            case 1: return "Moderato"
            case 5: return "Allegretto"
            case 15: return "Allegro"
            case 30: return "Vivace"
            default: break
            }
        }

        let level = string(membership, keys: ["level", "membershipLevel", "membership_level"])
            ?? string(user, keys: ["membershipLevel", "membership_level"])
        switch level?.uppercased() {
        case "LEVEL_FREE", "FREE":
            return "Adagio"
        default:
            return nil
        }
    }

    nonisolated private static func kimiWindow(
        _ data: [String: Any],
        id: String,
        defaultName: String,
        receivedAt: Date
    ) -> UsageWindow? {
        guard let limit = number(data, keys: ["limit"]), limit.isFinite, limit > 0 else {
            return nil
        }
        let used: Double?
        if let reported = number(data, keys: ["used"]), reported.isFinite {
            used = reported
        } else if let remaining = number(data, keys: ["remaining"]), remaining.isFinite {
            used = limit - remaining
        } else {
            used = nil
        }
        guard let used, used.isFinite else { return nil }

        let absoluteReset = date(value(
            data,
            keys: ["reset_at", "resetAt", "reset_time", "resetTime"]
        ))
        let relativeReset = number(data, keys: ["reset_in", "resetIn", "ttl", "window"])
        let resetsAt = absoluteReset ?? relativeReset.flatMap { seconds in
            guard seconds.isFinite, seconds > 0 else { return nil }
            return receivedAt.addingTimeInterval(seconds)
        }
        return UsageWindow(
            id: id,
            name: string(data, keys: ["name", "title"]) ?? defaultName,
            utilization: min(max(used / limit, 0), 1),
            resetsAt: resetsAt
        )
    }

    nonisolated private static func kimiLimitLabel(
        item: [String: Any],
        detail: [String: Any],
        window: [String: Any],
        index: Int
    ) -> String {
        if let label = string(item, keys: ["name", "title", "scope"])
            ?? string(detail, keys: ["name", "title", "scope"]) {
            return label
        }

        let duration = number(value(window, keys: ["duration"]))
            ?? number(value(item, keys: ["duration"]))
            ?? number(value(detail, keys: ["duration"]))
        guard let duration, duration.isFinite, duration > 0, duration <= Double(Int.max) else {
            return "Limit #\(index + 1)"
        }
        let amount = Int(duration.rounded(.towardZero))
        let unit = (string(window, keys: ["timeUnit"])
            ?? string(item, keys: ["timeUnit"])
            ?? string(detail, keys: ["timeUnit"])
            ?? "").uppercased()
        if unit.contains("MINUTE") {
            if amount >= 60, amount.isMultiple(of: 60) { return "\(amount / 60)h limit" }
            return "\(amount)m limit"
        }
        if unit.contains("HOUR") { return "\(amount)h limit" }
        if unit.contains("DAY") { return "\(amount)d limit" }
        return "\(amount)s limit"
    }

    nonisolated private static func kimiCredits(_ wallet: [String: Any]) -> CreditInfo? {
        guard let balance = dictionary(wallet, keys: ["balance"]),
              string(balance, keys: ["type"])?.uppercased() == "BOOSTER",
              let total = number(balance, keys: ["amount"]), total.isFinite, total > 0
        else { return nil }

        let monthlyLimit = dictionary(wallet, keys: ["monthlyChargeLimit", "monthly_charge_limit"])
        let monthlyUsed = dictionary(wallet, keys: ["monthlyUsed", "monthly_used"])
        let currency = string(monthlyLimit ?? [:], keys: ["currency"])
            ?? string(monthlyUsed ?? [:], keys: ["currency"])
            ?? "USD"
        let limitEnabled = bool(
            wallet,
            keys: ["monthlyChargeLimitEnabled", "monthly_charge_limit_enabled"]
        ) == true
        let rawLimit = number(monthlyLimit ?? [:], keys: ["priceInCents", "price_in_cents"])
        let rawUsed = number(monthlyUsed ?? [:], keys: ["priceInCents", "price_in_cents"])
        let amountLeft = number(balance, keys: ["amountLeft", "amount_left"])
            .flatMap(kimiFixedPointMajorCurrency) ?? 0
        let monthlyLimitMajor: Double? = rawLimit.flatMap { cents -> Double? in
            guard limitEnabled, cents.isFinite, cents > 0 else { return nil }
            return cents / 100.0
        }
        let monthlyUsedMajor: Double = rawUsed.flatMap { cents -> Double? in
            cents.isFinite ? max(0, cents) / 100.0 : nil
        } ?? 0
        let utilization = monthlyLimitMajor.flatMap { limit in
            min(max(monthlyUsedMajor / limit, 0), 1)
        }
        let credits = CreditInfo(
            balance: amountLeft,
            unit: .currency(currency.uppercased()),
            used: monthlyUsedMajor,
            limit: monthlyLimitMajor,
            unlimited: !limitEnabled,
            utilization: utilization
        )
        return credits.isEmpty ? nil : credits
    }

    /// Booster wallet amounts are fixed-point values where 1,000,000 units are
    /// one whole cent; Pilot's currency model stores major units instead.
    nonisolated private static func kimiFixedPointMajorCurrency(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        let rawCents = max(0, value) / 1_000_000.0
        let wholeCents = rawCents > 0 && rawCents < 1 ? 1 : rawCents.rounded()
        return wholeCents / 100.0
    }

    // MARK: - Grok (xAI)

    nonisolated private static func fetchGrok() async -> ProviderFetch {
        guard let session = UsageSessions.GrokSession.load() else { return .notSignedIn }
        let clientVersion = UsageSessions.GrokSession.installedVersion() ?? "0.2.93"
        let headers = [
            "Authorization": "Bearer \(session.accessToken)",
            "Accept": "application/json",
            "User-Agent": "grok/\(clientVersion)",
            "x-grok-client-version": clientVersion,
            "x-grok-client-mode": "tui",
        ]
        let url = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
        do {
            let root = try await getJSONObject(url: url, headers: headers)
            return .success(Self.parseGrokUsage(root, fallbackPlan: session.authMode))
        } catch {
            return classify(error, provider: "Grok", cli: "grok")
        }
    }

    nonisolated static func parseGrokUsage(
        _ root: [String: Any],
        fallbackPlan: String? = nil
    ) -> ProviderUsage {
        // Current Grok releases wrap the billing payload in `config`; older
        // releases returned these fields at the top level.
        let payload = dictionary(root, keys: ["config"]) ?? root
        let rawPlan = string(payload, keys: ["subscriptionTier", "subscription_tier"])
            ?? fallbackPlan
        let planLabel: String?
        switch rawPlan?.lowercased() {
        case "oidc":
            planLabel = "SuperGrok"
        case "session", nil:
            planLabel = nil
        case .some(let plan):
            planLabel = plan.replacingOccurrences(of: "_", with: " ").capitalized
        }
        var usage = ProviderUsage(planLabel: planLabel)
        let currentPeriod = dictionary(payload, keys: ["currentPeriod", "current_period"])
        let billingCycle = dictionary(payload, keys: ["billingCycle", "billing_cycle"])
        let periodStart = date(value(currentPeriod ?? [:], keys: ["start"]))
            ?? date(value(payload, keys: ["billingPeriodStart", "billing_period_start"]))
            ?? date(value(billingCycle ?? [:], keys: ["billingPeriodStart", "billing_period_start"]))
        let periodEnd = date(value(currentPeriod ?? [:], keys: ["end"]))
            ?? date(value(payload, keys: ["billingPeriodEnd", "billing_period_end"]))
            ?? date(value(billingCycle ?? [:], keys: ["billingPeriodEnd", "billing_period_end"]))
        let limit = cents(payload, keys: ["monthlyLimit", "monthly_limit"])
        let includedUsed = cents(payload, keys: ["includedUsed", "included_used"])
            ?? cents(dictionary(payload, keys: ["usage"]) ?? [:], keys: ["totalUsed", "total_used"])
        let percent = number(payload, keys: ["creditUsagePercent", "credit_usage_percent"])
            ?? (limit.flatMap { limit in
                guard limit > 0, let includedUsed else { return nil }
                return includedUsed / limit * 100.0
            })

        if let percent, percent.isFinite {
            let periodType = string(currentPeriod ?? [:], keys: ["type"])
            let name: String
            if let periodType, periodType.localizedCaseInsensitiveContains("week") {
                name = "Weekly"
            } else if let periodType, periodType.localizedCaseInsensitiveContains("month") {
                name = "Monthly"
            } else if let periodStart, let periodEnd {
                name = windowName(seconds: periodEnd.timeIntervalSince(periodStart))
            } else {
                name = "Usage"
            }
            usage.windows.append(UsageWindow(
                id: "grok-current-period",
                name: name,
                utilization: min(max(percent / 100.0, 0), 1),
                resetsAt: periodEnd
            ))
        }

        if let prepaid = cents(payload, keys: ["prepaidBalance", "prepaid_balance"]) {
            usage.credits = CreditInfo(
                balance: prepaid / 100.0,
                unit: .currency("USD")
            )
        } else if let cap = cents(payload, keys: ["onDemandCap", "on_demand_cap"]), cap > 0 {
            let used = cents(payload, keys: ["onDemandUsed", "on_demand_used"])
            usage.credits = CreditInfo(
                balance: nil,
                unit: .currency("USD"),
                used: used.map { $0 / 100.0 },
                limit: cap / 100.0
            )
        }
        return usage
    }

    // MARK: - Shared helpers

    /// Human name for a rolling window given its length in seconds.
    nonisolated static func windowName(seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "Usage" }
        let hours = seconds / 3600
        if hours <= 1.5 { return "Hourly" }
        if hours < 24 { return "\(Int(hours.rounded()))-hour" }
        let days = seconds / 86400
        if days <= 1.5 { return "Daily" }
        if days <= 7.5 { return "Weekly" }
        if days <= 31 { return "Monthly" }
        return "\(Int(days.rounded()))-day"
    }

    /// GET a JSON object, tolerating any field shape — these are undocumented
    /// endpoints whose schemas vary, so we parse defensively rather than with a
    /// strict `Decodable` that would throw on the first type mismatch.
    nonisolated private static func getJSONObject(url: URL, headers: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap { Double($0) }
            throw UsageFetchError.http(status: http.statusCode, retryAfter: retryAfter)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageFetchError.malformed
        }
        return object
    }

    /// Coerce a JSON value to a Double whether it arrived as a number or a string.
    nonisolated static func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    nonisolated private static func number(_ dict: [String: Any], keys: [String]) -> Double? {
        number(value(dict, keys: keys))
    }

    nonisolated private static func bool(_ dict: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = dict[key] as? Bool { return value }
            if let value = dict[key] as? NSNumber { return value.boolValue }
            if let value = dict[key] as? String {
                if value.caseInsensitiveCompare("true") == .orderedSame || value == "1" { return true }
                if value.caseInsensitiveCompare("false") == .orderedSame || value == "0" { return false }
            }
        }
        return nil
    }

    nonisolated private static func string(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = dict[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    nonisolated private static func dictionary(
        _ dict: [String: Any],
        keys: [String]
    ) -> [String: Any]? {
        for key in keys {
            if let value = dict[key] as? [String: Any] { return value }
        }
        return nil
    }

    nonisolated private static func value(_ dict: [String: Any], keys: [String]) -> Any? {
        for key in keys where dict[key] != nil { return dict[key] }
        return nil
    }

    nonisolated private static func windowSeconds(_ dict: [String: Any]) -> Double? {
        if let seconds = number(
            dict,
            keys: ["limit_window_seconds", "limitWindowSeconds", "window_seconds", "windowSeconds"]
        ) {
            return seconds
        }
        return number(dict, keys: ["windowDurationMins", "window_minutes"]).map { $0 * 60 }
    }

    /// Billing JSON wraps cent values as `{ "val": number }`.
    nonisolated private static func cents(_ dict: [String: Any], keys: [String]) -> Double? {
        guard let raw = value(dict, keys: keys) else { return nil }
        if let wrapped = raw as? [String: Any] { return number(wrapped, keys: ["val", "value"]) }
        return number(raw)
    }

    /// Parse a reset timestamp from either unix seconds (Codex) or a string in a
    /// range of ISO-8601 / RFC formats (Claude).
    nonisolated static func date(_ any: Any?) -> Date? {
        if let numeric = number(any) { return unixDate(numeric) }
        guard let string = any as? String, !string.isEmpty else { return nil }

        for options in [ISO8601DateFormatter.Options([.withInternetDateTime, .withFractionalSeconds]),
                        ISO8601DateFormatter.Options([.withInternetDateTime])] {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = options
            if let parsed = iso.date(from: string) { return parsed }
        }
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZZZ",
                        "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
                        "yyyy-MM-dd HH:mm:ssZZZZZ",
                        "EEE',' dd MMM yyyy HH':'mm':'ss zzz"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = pattern
            if let parsed = formatter.date(from: string) { return parsed }
        }
        return nil
    }

    nonisolated private static func unixDate(_ value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        let seconds = value > 10_000_000_000 ? value / 1_000.0 : value
        return Date(timeIntervalSince1970: seconds)
    }

    /// Turn a thrown fetch error into a `ProviderFetch`, routing 429s to the
    /// backoff path and everything else to a displayable failure.
    nonisolated private static func classify(_ error: Error, provider: String, cli: String) -> ProviderFetch {
        if case let UsageFetchError.http(status, retryAfter) = error, status == 429 {
            return .rateLimited(retryAfter: retryAfter)
        }
        return .failure(describe(error, provider: provider, reauth: cli))
    }

    nonisolated private static func describe(_ error: Error, provider: String, reauth cli: String) -> String {
        switch error {
        case UsageFetchError.http(let status, _) where status == 401 || status == 403:
            return "\(provider): session expired — re-run `\(cli)` to sign in."
        case UsageFetchError.http(let status, _):
            return "\(provider): request failed (HTTP \(status))."
        default:
            return "\(provider): couldn’t read the usage response."
        }
    }
}

private enum UsageFetchError: Error {
    case http(status: Int, retryAfter: TimeInterval?)
    case malformed
}

/// Outcome of one provider fetch.
enum ProviderFetch: Sendable {
    case success(ProviderUsage)
    case notSignedIn
    /// The endpoint returned 429; `retryAfter` is the server's hint, if any.
    case rateLimited(retryAfter: TimeInterval?)
    /// Not attempted this tick (min-spacing / backoff).
    case skipped
    case failure(String)
}
