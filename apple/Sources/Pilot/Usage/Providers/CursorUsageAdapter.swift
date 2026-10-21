import Foundation

private typealias JSON = UsageJSON

/// Reads Cursor plan usage and spend through the Cursor editor's own web
/// session (see `UsageSessions.CursorSession`).
///
/// Two dashboard endpoints feed one card. `usage-summary` works for every
/// membership and carries the billing cycle, included-plan percentage, and
/// legacy on-demand spend. The v2 `usage-status` endpoint adds what unified
/// (post-2025) memberships actually budget on: the weekly included-usage
/// window and the monthly metered spend, both in cents.
enum CursorUsageAdapter {
    static let summaryEndpoint = URL(string: "https://cursor.com/api/usage-summary")!
    static let statusEndpoint = URL(
        string: "https://cursor.com/api/dashboard/v2/usage-status?scope=user"
    )!

    static func fetch(
        session: UsageSessions.CursorSession?,
        transport: UsageHTTP.Transport = UsageHTTP.live
    ) async -> ProviderFetch {
        guard let session else { return .notSignedIn }
        guard !session.isExpired else {
            return .failure("Cursor: session expired — sign in to the Cursor app, then refresh.")
        }
        let headers = [
            "Cookie": cookie(for: session),
            "Accept": "application/json",
        ]
        let summary: [String: Any]
        do {
            summary = try await UsageHTTP.getJSONObject(
                url: summaryEndpoint, headers: headers, transport: transport
            )
        } catch {
            return UsageHTTP.classify(error, provider: "Cursor", cli: "cursor")
        }
        // The v2 status is unified-membership only; a failure there must not
        // take down the card the summary can already draw.
        let status = try? await UsageHTTP.getJSONObject(
            url: statusEndpoint, headers: headers, transport: transport
        )
        return .success(parse(summary: summary, status: status))
    }

    /// The dashboard cookie is `sub::token` with both separators URL-encoded;
    /// the raw JWT alone is rejected.
    static func cookie(for session: UsageSessions.CursorSession) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let user = session.userId.addingPercentEncoding(withAllowedCharacters: allowed)
            ?? session.userId
        return "WorkosCursorSessionToken=\(user)%3A%3A\(session.accessToken)"
    }

    static func parse(
        summary: [String: Any],
        status: [String: Any]?
    ) -> ProviderUsage {
        var usage = ProviderUsage(
            planLabel: planLabel(JSON.string(summary, keys: ["membershipType", "membership_type"]))
        )

        // Weekly included budget (unified memberships), in cents.
        var weeklyBudgetCents: Double?
        if let status,
           let weekly = JSON.dictionary(status, keys: ["weeklyIncludedUsage", "weekly_included_usage"]),
           let budget = JSON.number(weekly, keys: ["budgetCents", "budget_cents"]),
           budget > 0,
           let used = JSON.number(weekly, keys: ["usedCents", "used_cents"]) {
            weeklyBudgetCents = budget
            usage.windows.append(UsageWindow(
                id: "cursor-weekly-included",
                name: "Weekly",
                utilization: min(max(used / budget, 0), 1),
                resetsAt: JSON.date(JSON.value(weekly, keys: ["resetsAt", "resets_at"]))
            ))
        }

        // Included-plan usage over the billing cycle. For unified memberships
        // the summary mirrors the weekly included budget — recognizable by the
        // matching limit — so only distinct quotas earn a second bar.
        let individual = JSON.dictionary(summary, keys: ["individualUsage", "individual_usage"]) ?? [:]
        if let plan = JSON.dictionary(individual, keys: ["plan"]),
           JSON.bool(plan, keys: ["enabled"]) != false,
           let percent = JSON.number(plan, keys: ["totalPercentUsed", "total_percent_used"]),
           percent.isFinite,
           JSON.number(plan, keys: ["limit"]) != weeklyBudgetCents {
            let cycleStart = JSON.date(JSON.value(summary, keys: ["billingCycleStart", "billing_cycle_start"]))
            let cycleEnd = JSON.date(JSON.value(summary, keys: ["billingCycleEnd", "billing_cycle_end"]))
            let name: String
            if let cycleStart, let cycleEnd {
                name = JSON.windowName(seconds: cycleEnd.timeIntervalSince(cycleStart))
            } else {
                name = "Plan"
            }
            usage.windows.append(UsageWindow(
                id: "cursor-plan",
                name: name,
                utilization: min(max(percent / 100.0, 0), 1),
                resetsAt: cycleEnd
            ))
        }

        // Metered spend: the v2 monthly figure for unified memberships, else
        // the summary's on-demand block. Zero still renders — a budget being
        // tracked at $0.00 is information, an empty card is not.
        if let status,
           let monthly = JSON.dictionary(status, keys: ["monthlyUsage", "monthly_usage"]),
           let usedCents = JSON.number(monthly, keys: ["usedCents", "used_cents"]) {
            usage.credits = CreditInfo(
                unit: .currency("USD"),
                used: usedCents / 100.0,
                limit: JSON.number(monthly, keys: ["limitCents", "limit_cents"]).map { $0 / 100.0 }
            )
        } else if let onDemand = JSON.dictionary(individual, keys: ["onDemand", "on_demand"]),
                  JSON.bool(onDemand, keys: ["enabled"]) == true,
                  let used = JSON.number(onDemand, keys: ["used"]) {
            usage.credits = CreditInfo(
                unit: .currency("USD"),
                used: used / 100.0,
                limit: JSON.number(onDemand, keys: ["limit"]).map { $0 / 100.0 }
            )
        }
        return usage
    }

    /// `unified_ultra` → "Ultra", `free_trial` → "Free Trial", `pro` → "Pro".
    private static func planLabel(_ membership: String?) -> String? {
        guard var membership else { return nil }
        if let stripped = membership.range(of: "unified_") {
            membership.removeSubrange(stripped)
        }
        let label = membership
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
        return label.isEmpty ? nil : label
    }
}
