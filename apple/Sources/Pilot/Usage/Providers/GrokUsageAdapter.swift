import Foundation

private typealias JSON = UsageJSON

/// Reads Grok (xAI) billing usage through the `grok` CLI's own session.
enum GrokUsageAdapter {
    static let endpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    static let fallbackClientVersion = "0.2.93"

    static func fetch(
        session: UsageSessions.GrokSession?,
        clientVersion: String?,
        transport: UsageHTTP.Transport = UsageHTTP.live
    ) async -> ProviderFetch {
        guard let session else { return .notSignedIn }
        let clientVersion = clientVersion ?? fallbackClientVersion
        let headers = [
            "Authorization": "Bearer \(session.accessToken)",
            "Accept": "application/json",
            "User-Agent": "grok/\(clientVersion)",
            "x-grok-client-version": clientVersion,
            "x-grok-client-mode": "tui",
        ]
        do {
            let root = try await UsageHTTP.getJSONObject(url: endpoint, headers: headers, transport: transport)
            return .success(parse(root, fallbackPlan: session.authMode))
        } catch {
            return UsageHTTP.classify(error, provider: "Grok", cli: "grok")
        }
    }

    static func parse(
        _ root: [String: Any],
        fallbackPlan: String? = nil
    ) -> ProviderUsage {
        // Current Grok releases wrap the billing payload in `config`; older
        // releases returned these fields at the top level.
        let payload = JSON.dictionary(root, keys: ["config"]) ?? root
        let rawPlan = JSON.string(payload, keys: ["subscriptionTier", "subscription_tier"])
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
        let currentPeriod = JSON.dictionary(payload, keys: ["currentPeriod", "current_period"])
        let billingCycle = JSON.dictionary(payload, keys: ["billingCycle", "billing_cycle"])
        let periodStart = JSON.date(JSON.value(currentPeriod ?? [:], keys: ["start"]))
            ?? JSON.date(JSON.value(payload, keys: ["billingPeriodStart", "billing_period_start"]))
            ?? JSON.date(JSON.value(billingCycle ?? [:], keys: ["billingPeriodStart", "billing_period_start"]))
        let periodEnd = JSON.date(JSON.value(currentPeriod ?? [:], keys: ["end"]))
            ?? JSON.date(JSON.value(payload, keys: ["billingPeriodEnd", "billing_period_end"]))
            ?? JSON.date(JSON.value(billingCycle ?? [:], keys: ["billingPeriodEnd", "billing_period_end"]))
        let limit = cents(payload, keys: ["monthlyLimit", "monthly_limit"])
        let includedUsed = cents(payload, keys: ["includedUsed", "included_used"])
            ?? cents(JSON.dictionary(payload, keys: ["usage"]) ?? [:], keys: ["totalUsed", "total_used"])
        let percent = JSON.number(payload, keys: ["creditUsagePercent", "credit_usage_percent"])
            ?? (limit.flatMap { limit in
                guard limit > 0, let includedUsed else { return nil }
                return includedUsed / limit * 100.0
            })

        if let percent, percent.isFinite {
            let periodType = JSON.string(currentPeriod ?? [:], keys: ["type"])
            let name: String
            if let periodType, periodType.localizedCaseInsensitiveContains("week") {
                name = "Weekly"
            } else if let periodType, periodType.localizedCaseInsensitiveContains("month") {
                name = "Monthly"
            } else if let periodStart, let periodEnd {
                name = JSON.windowName(seconds: periodEnd.timeIntervalSince(periodStart))
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

    /// Billing JSON wraps cent values as `{ "val": number }`.
    private static func cents(_ dict: [String: Any], keys: [String]) -> Double? {
        guard let raw = JSON.value(dict, keys: keys) else { return nil }
        if let wrapped = raw as? [String: Any] { return JSON.number(wrapped, keys: ["val", "value"]) }
        return JSON.number(raw)
    }
}
