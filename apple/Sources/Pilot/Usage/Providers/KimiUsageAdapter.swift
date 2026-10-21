import Foundation

private typealias JSON = UsageJSON

/// Reads Kimi Code (Moonshot AI) plan usage through Kimi Code's own session.
enum KimiUsageAdapter {
    static let endpoint = URL(string: "https://api.kimi.ai/coding/v1/usages")!
    /// The account endpoint carries the membership tier name; the usages
    /// endpoint does not.
    static let accountEndpoint = URL(string: "https://api.kimi.ai/coding/v1/me")!
    static let expiredMessage = "Kimi: session expired — re-run `kimi login` to sign in."

    /// Refreshes the Kimi session; injectable so tests never touch the real
    /// token endpoint or credential file.
    typealias Refresh = @Sendable (UsageSessions.KimiSession) async -> UsageSessions.KimiSession?

    static let liveRefresh: Refresh = { session in
        await UsageSessions.KimiSession.refresh(session: session)
    }

    static func fetch(
        session: UsageSessions.KimiSession?,
        transport: UsageHTTP.Transport = UsageHTTP.live,
        refresh: Refresh? = nil
    ) async -> ProviderFetch {
        guard var session else { return .notSignedIn }

        // Kimi access tokens last fifteen minutes, so an expired session is
        // the steady state between CLI runs — revive it instead of surfacing
        // it. Without a refresh path the expiry is reported as before.
        var didRefresh = false
        if session.isExpired {
            guard session.canRefresh, let refresh, let refreshed = await refresh(session) else {
                return .failure(expiredMessage)
            }
            session = refreshed
            didRefresh = true
        }

        var result = await request(session: session, transport: transport)
        // A 401/403 ahead of the recorded expiry means the token was revoked
        // early; one refresh-and-retry covers it without risking a loop.
        if case .failure = result, isAuthFailure(result), !didRefresh,
           session.canRefresh, let refresh,
           let refreshed = await refresh(session) {
            result = await request(session: refreshed, transport: transport)
        }
        return result
    }

    private static func request(
        session: UsageSessions.KimiSession,
        transport: UsageHTTP.Transport
    ) async -> ProviderFetch {
        let headers = [
            "Authorization": "Bearer \(session.accessToken)",
            "Accept": "application/json",
        ]
        do {
            let root = try await UsageHTTP.getJSONObject(url: endpoint, headers: headers, transport: transport)
            var usage = parse(root, receivedAt: Date())
            // The usages payload has no plan title; the account endpoint reports
            // the tier directly (e.g. "Vivace"). Best-effort: a failed or absent
            // lookup just leaves whatever `parse` could infer, so the card never
            // fails over a missing badge.
            if let level = try? await accountLevel(headers: headers, transport: transport) {
                usage.planLabel = level
            }
            return .success(usage)
        } catch {
            return UsageHTTP.classify(error, provider: "Kimi", cli: "kimi login")
        }
    }

    /// The authoritative membership tier from Kimi's account endpoint.
    private static func accountLevel(
        headers: [String: String],
        transport: UsageHTTP.Transport
    ) async throws -> String? {
        let account = try await UsageHTTP.getJSONObject(
            url: accountEndpoint, headers: headers, transport: transport
        )
        return JSON.string(account, keys: ["user_level_name", "userLevelName"])
    }

    private static func isAuthFailure(_ fetch: ProviderFetch) -> Bool {
        guard case .failure(let message) = fetch else { return false }
        return message.contains("session expired")
    }

    /// Parse Kimi Code's intentionally loose usage schema: a weekly summary,
    /// rolling limit rows, and an optional Extra Usage booster wallet.
    static func parse(
        _ root: [String: Any],
        receivedAt: Date = Date()
    ) -> ProviderUsage {
        var usage = ProviderUsage(planLabel: planLabel(root))
        if let summary = JSON.dictionary(root, keys: ["usage"]),
           let window = makeWindow(
               summary,
               id: "kimi-summary",
               defaultName: "Weekly limit",
               receivedAt: receivedAt) {
            usage.windows.append(window)
        }

        if let limits = root["limits"] as? [Any] {
            for (index, rawLimit) in limits.enumerated() {
                guard let item = rawLimit as? [String: Any] else { continue }
                let detail = JSON.dictionary(item, keys: ["detail"]) ?? item
                let metadata = JSON.dictionary(item, keys: ["window"]) ?? [:]
                let label = limitLabel(
                    item: item,
                    detail: detail,
                    window: metadata,
                    index: index
                )
                if let window = makeWindow(
                    detail,
                    id: "kimi-limit-\(index)",
                    defaultName: label,
                    receivedAt: receivedAt) {
                    usage.windows.append(window)
                }
            }
        }

        if let wallet = JSON.dictionary(root, keys: ["boosterWallet", "booster_wallet"]) {
            usage.credits = makeCredits(wallet)
        }
        return usage
    }

    /// Fallback plan inference from the usages payload, used only when the
    /// account endpoint's `user_level_name` is unavailable (see `request`).
    /// The usages payload reports no public plan title, and its
    /// `membership.level` is a coarse legacy field — a Vivace account returns
    /// `LEVEL_STANDARD`, so a level→plan mapping mislabels paid tiers. The
    /// reliable in-payload signal is the Kimi Code credit multiplier in
    /// `parallel.limit`: the official plan table's Kimi Code credits row is
    /// 1×/5×/15×/30× for Moderato/Allegretto/Allegro/Vivace. Prefer an explicit
    /// title when the service includes one, then the multiplier, then the free
    /// level; hide the badge rather than show a wrong one.
    private static func planLabel(_ root: [String: Any]) -> String? {
        let user = JSON.dictionary(root, keys: ["user"]) ?? [:]
        let membership = JSON.dictionary(user, keys: ["membership"])
            ?? JSON.dictionary(root, keys: ["membership"])
            ?? [:]

        if let title = JSON.string(
            membership,
            keys: ["title", "name", "displayName", "display_name", "planName", "plan_name"]
        ) {
            return title
        }

        if let parallel = JSON.dictionary(root, keys: ["parallel"]),
           let limit = JSON.number(parallel, keys: ["limit"]) {
            switch limit {
            case 1: return "Moderato"
            case 5: return "Allegretto"
            case 15: return "Allegro"
            case 30: return "Vivace"
            default: break
            }
        }

        let level = JSON.string(membership, keys: ["level", "membershipLevel", "membership_level"])
            ?? JSON.string(user, keys: ["membershipLevel", "membership_level"])
        switch level?.uppercased() {
        case "LEVEL_FREE", "FREE":
            return "Adagio"
        default:
            return nil
        }
    }

    private static func makeWindow(
        _ data: [String: Any],
        id: String,
        defaultName: String,
        receivedAt: Date
    ) -> UsageWindow? {
        guard let limit = JSON.number(data, keys: ["limit"]), limit.isFinite, limit > 0 else {
            return nil
        }
        let used: Double?
        if let reported = JSON.number(data, keys: ["used"]), reported.isFinite {
            used = reported
        } else if let remaining = JSON.number(data, keys: ["remaining"]), remaining.isFinite {
            used = limit - remaining
        } else {
            used = nil
        }
        guard let used, used.isFinite else { return nil }

        let absoluteReset = JSON.date(JSON.value(
            data,
            keys: ["reset_at", "resetAt", "reset_time", "resetTime"]
        ))
        let relativeReset = JSON.number(data, keys: ["reset_in", "resetIn", "ttl", "window"])
        let resetsAt = absoluteReset ?? relativeReset.flatMap { seconds in
            guard seconds.isFinite, seconds > 0 else { return nil }
            return receivedAt.addingTimeInterval(seconds)
        }
        return UsageWindow(
            id: id,
            name: JSON.string(data, keys: ["name", "title"]) ?? defaultName,
            utilization: min(max(used / limit, 0), 1),
            resetsAt: resetsAt
        )
    }

    private static func limitLabel(
        item: [String: Any],
        detail: [String: Any],
        window: [String: Any],
        index: Int
    ) -> String {
        if let label = JSON.string(item, keys: ["name", "title", "scope"])
            ?? JSON.string(detail, keys: ["name", "title", "scope"]) {
            return label
        }

        let duration = JSON.number(JSON.value(window, keys: ["duration"]))
            ?? JSON.number(JSON.value(item, keys: ["duration"]))
            ?? JSON.number(JSON.value(detail, keys: ["duration"]))
        guard let duration, duration.isFinite, duration > 0, duration <= Double(Int.max) else {
            return "Limit #\(index + 1)"
        }
        let amount = Int(duration.rounded(.towardZero))
        let unit = (JSON.string(window, keys: ["timeUnit"])
            ?? JSON.string(item, keys: ["timeUnit"])
            ?? JSON.string(detail, keys: ["timeUnit"])
            ?? "").uppercased()
        if unit.contains("MINUTE") {
            if amount >= 60, amount.isMultiple(of: 60) { return "\(amount / 60)h limit" }
            return "\(amount)m limit"
        }
        if unit.contains("HOUR") { return "\(amount)h limit" }
        if unit.contains("DAY") { return "\(amount)d limit" }
        return "\(amount)s limit"
    }

    private static func makeCredits(_ wallet: [String: Any]) -> CreditInfo? {
        guard let balance = JSON.dictionary(wallet, keys: ["balance"]),
              JSON.string(balance, keys: ["type"])?.uppercased() == "BOOSTER",
              let total = JSON.number(balance, keys: ["amount"]), total.isFinite, total > 0
        else { return nil }

        let monthlyLimit = JSON.dictionary(wallet, keys: ["monthlyChargeLimit", "monthly_charge_limit"])
        let monthlyUsed = JSON.dictionary(wallet, keys: ["monthlyUsed", "monthly_used"])
        let currency = JSON.string(monthlyLimit ?? [:], keys: ["currency"])
            ?? JSON.string(monthlyUsed ?? [:], keys: ["currency"])
            ?? "USD"
        let limitEnabled = JSON.bool(
            wallet,
            keys: ["monthlyChargeLimitEnabled", "monthly_charge_limit_enabled"]
        ) == true
        let rawLimit = JSON.number(monthlyLimit ?? [:], keys: ["priceInCents", "price_in_cents"])
        let rawUsed = JSON.number(monthlyUsed ?? [:], keys: ["priceInCents", "price_in_cents"])
        let amountLeft = JSON.number(balance, keys: ["amountLeft", "amount_left"])
            .flatMap(fixedPointMajorCurrency) ?? 0
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
    private static func fixedPointMajorCurrency(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        let rawCents = max(0, value) / 1_000_000.0
        let wholeCents = rawCents > 0 && rawCents < 1 ? 1 : rawCents.rounded()
        return wholeCents / 100.0
    }
}
