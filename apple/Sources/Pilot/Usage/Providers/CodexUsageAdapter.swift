import Foundation

private typealias JSON = UsageJSON

/// Reads Codex (OpenAI) plan usage through the `codex` CLI's own session.
enum CodexUsageAdapter {
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    static func fetch(
        session: UsageSessions.CodexSession?,
        transport: UsageHTTP.Transport = UsageHTTP.live
    ) async -> ProviderFetch {
        guard let session else { return .notSignedIn }

        var headers = [
            "Authorization": "Bearer \(session.accessToken)",
            "Accept": "application/json",
            "OpenAI-Beta": "codex-1",
            "originator": "Codex Desktop",
            "User-Agent": "codex-cli",
        ]
        if let account = session.accountId { headers["ChatGPT-Account-Id"] = account }

        let root: [String: Any]
        do {
            root = try await UsageHTTP.getJSONObject(url: endpoint, headers: headers, transport: transport)
        } catch {
            return UsageHTTP.classify(error, provider: "Codex", cli: "codex")
        }

        return .success(parse(root, receivedAt: Date()))
    }

    static func parse(
        _ root: [String: Any],
        receivedAt: Date = Date()
    ) -> ProviderUsage {
        let rootPlan = JSON.string(root, keys: ["plan_type", "planType"])
        var usage = ProviderUsage(planLabel: rootPlan?.replacingOccurrences(of: "_", with: " ").capitalized)

        func appendRateLimit(
            _ rateLimit: [String: Any],
            idPrefix: String,
            displayName: String? = nil
        ) {
            if usage.planLabel == nil,
               let plan = JSON.string(rateLimit, keys: ["plan_type", "planType"]) {
                usage.planLabel = plan.replacingOccurrences(of: "_", with: " ").capitalized
            }

            let primary = JSON.dictionary(
                rateLimit,
                keys: ["primary_window", "primaryWindow", "primary"]
            )
            let secondary = JSON.dictionary(
                rateLimit,
                keys: ["secondary_window", "secondaryWindow", "secondary"]
            )
            // Keep the pool's label on every window — Codex returns a main
            // rate limit plus scoped "additional" pools that share the same
            // 5-hour/weekly cadence, so the label is what tells them apart.
            if let primary,
               let window = makeWindow(
                primary,
                id: "\(idPrefix)-primary",
                displayName: displayName,
                receivedAt: receivedAt) {
                usage.windows.append(window)
            }
            if let secondary,
               let window = makeWindow(
                secondary,
                id: "\(idPrefix)-secondary",
                displayName: displayName,
                receivedAt: receivedAt) {
                usage.windows.append(window)
            }
            if usage.credits == nil,
               let credits = JSON.dictionary(rateLimit, keys: ["credits"]) {
                usage.credits = makeCredits(credits)
            }
        }

        if let rateLimit = JSON.dictionary(root, keys: ["rate_limit", "rateLimits", "rate_limits"]) {
            appendRateLimit(rateLimit, idPrefix: "codex")
        }

        if let additional = (root["additional_rate_limits"] ?? root["additionalRateLimits"])
            as? [[String: Any]] {
            for (index, entry) in additional.enumerated() {
                let id = JSON.string(entry, keys: ["limit_id", "limitId", "metered_feature", "meteredFeature"])
                    ?? "additional-\(index)"
                let label = JSON.string(entry, keys: ["limit_name", "limitName", "metered_feature", "meteredFeature"])
                    ?? (id.hasPrefix("additional-")
                        ? "Additional \(index + 1)"
                        : id.replacingOccurrences(of: "_", with: " "))
                let rateLimit = JSON.dictionary(entry, keys: ["rate_limit", "rateLimits"]) ?? entry
                appendRateLimit(
                    rateLimit,
                    idPrefix: "codex-\(id)-\(index)",
                    displayName: label
                )
            }
        }

        if let buckets = (root["rateLimitsByLimitId"] ?? root["rate_limits_by_limit_id"])
            as? [String: Any] {
            for key in buckets.keys.sorted() where key != "codex" {
                guard let bucket = buckets[key] as? [String: Any] else { continue }
                let label = JSON.string(bucket, keys: ["limitName", "limit_name"])
                    ?? key.replacingOccurrences(of: "_", with: " ")
                appendRateLimit(bucket, idPrefix: "codex-\(key)", displayName: label)
            }
        }

        if let credits = JSON.dictionary(root, keys: ["credits"]) {
            usage.credits = makeCredits(credits)
        }
        return usage
    }

    private static func makeWindow(
        _ dict: [String: Any],
        id: String,
        displayName: String?,
        receivedAt: Date
    ) -> UsageWindow? {
        guard let usedPercent = JSON.number(dict, keys: ["used_percent", "usedPercent"]),
              usedPercent.isFinite else { return nil }
        let seconds = windowSeconds(dict)
        let absoluteReset = JSON.date(JSON.value(dict, keys: ["reset_at", "resets_at", "resetsAt"]))
        let resetAfter = JSON.number(dict, keys: ["reset_after_seconds", "resetAfterSeconds"])
        let resetsAt = absoluteReset ?? resetAfter.map { receivedAt.addingTimeInterval(max(0, $0)) }
        let generatedName = JSON.windowName(seconds: seconds)
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

    private static func windowSeconds(_ dict: [String: Any]) -> Double? {
        if let seconds = JSON.number(
            dict,
            keys: ["limit_window_seconds", "limitWindowSeconds", "window_seconds", "windowSeconds"]
        ) {
            return seconds
        }
        return JSON.number(dict, keys: ["windowDurationMins", "window_minutes"]).map { $0 * 60 }
    }

    private static func makeCredits(_ dict: [String: Any]) -> CreditInfo? {
        let hasCredits = JSON.bool(dict, keys: ["has_credits", "hasCredits"])
        guard hasCredits != false else { return nil }
        let info = CreditInfo(
            balance: JSON.number(dict, keys: ["balance"]),
            unit: .credits,
            unlimited: JSON.bool(dict, keys: ["unlimited"]) ?? false
        )
        return info.isEmpty ? nil : info
    }
}
