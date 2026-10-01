import Foundation

private typealias JSON = UsageJSON

/// Reads Claude plan usage through Claude Code's own OAuth session.
enum ClaudeUsageAdapter {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func fetch(
        session: UsageSessions.ClaudeSession?,
        transport: UsageHTTP.Transport = UsageHTTP.live
    ) async -> ProviderFetch {
        guard let session else { return .notSignedIn }
        guard session.hasProfileScope else {
            return .failure("Claude: this session lacks the user:profile scope — re-run `claude` to sign in.")
        }

        let headers = [
            "Authorization": "Bearer \(session.accessToken)",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-cli/2.1.0 (external, cli)",
        ]
        let root: [String: Any]
        do {
            root = try await UsageHTTP.getJSONObject(url: endpoint, headers: headers, transport: transport)
        } catch {
            return UsageHTTP.classify(error, provider: "Claude", cli: "claude")
        }

        return .success(parse(root, planLabel: session.subscriptionType))
    }

    static func parse(
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
               let parsed = makeWindow(id: "claude-\(key)", name: label, window) {
                usage.windows.append(parsed)
            }
        }

        // Model-scoped windows (e.g. Fable, Opus, Sonnet). The newer `limits`
        // array names the model via `scope.model.display_name` and supersedes the
        // flat `seven_day_<model>` fields, so track which models it covers.
        var scopedModels = Set<String>()
        if let limits = root["limits"] as? [[String: Any]] {
            for (index, entry) in limits.enumerated() {
                guard JSON.bool(entry, keys: ["is_active", "isActive"]) != false,
                      let model = limitModel(entry),
                      let percent = JSON.number(entry, keys: ["percent", "utilization"]), percent.isFinite
                else { continue }
                scopedModels.insert(model.lowercased())
                usage.windows.append(UsageWindow(
                    id: "claude-limit-\(index)",
                    name: "\(limitPeriod(entry)) (\(model))",
                    utilization: min(max(percent / 100.0, 0), 1),
                    resetsAt: JSON.date(JSON.value(entry, keys: ["resets_at", "resetsAt"]))
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
               let parsed = makeWindow(id: "claude-\(key)", name: label, window) {
                usage.windows.append(parsed)
            }
        }

        if let extra = root["extra_usage"] as? [String: Any],
           JSON.bool(extra, keys: ["is_enabled", "isEnabled"]) != false {
            let used = JSON.number(extra, keys: ["used_credits", "usedCredits"]).map { $0 / 100.0 }
            let limit = JSON.number(extra, keys: ["monthly_limit", "monthlyLimit"]).map { $0 / 100.0 }
            let rawUtilization = JSON.number(extra, keys: ["utilization"])
            let utilization = rawUtilization.map { min(max($0 / 100.0, 0), 1) }
            let currency = JSON.string(extra, keys: ["currency"])?.uppercased() ?? "USD"
            let monthlyLimitValue = JSON.value(extra, keys: ["monthly_limit", "monthlyLimit"])
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

    private static func makeWindow(
        id: String,
        name: String,
        _ dict: [String: Any]
    ) -> UsageWindow? {
        // Claude reports utilization as a percentage in the 0...100 range.
        guard let raw = JSON.number(dict, keys: ["utilization"]), raw.isFinite else { return nil }
        return UsageWindow(
            id: id,
            name: name,
            utilization: min(max(raw / 100.0, 0), 1),
            resetsAt: JSON.date(JSON.value(dict, keys: ["resets_at", "resetsAt"]))
        )
    }

    /// The model a scoped `limits[]` entry applies to (e.g. "Fable"), if any.
    private static func limitModel(_ entry: [String: Any]) -> String? {
        if let scope = entry["scope"] as? [String: Any] {
            if let model = scope["model"] as? [String: Any],
               let name = JSON.string(model, keys: ["display_name", "displayName", "name", "id"]) {
                return name
            }
            if let name = JSON.string(scope, keys: ["display_name", "displayName", "name", "model"]) {
                return name
            }
        }
        return JSON.string(entry, keys: ["display_name", "displayName", "name"])
    }

    /// The window period for a scoped `limits[]` entry, inferred from its
    /// `group`/`kind` hint (scoped limits are weekly by default).
    private static func limitPeriod(_ entry: [String: Any]) -> String {
        let hint = (JSON.string(entry, keys: ["group", "kind", "window", "period"]) ?? "").lowercased()
        if hint.contains("week") || hint.contains("7d") || hint.contains("seven") { return "Weekly" }
        if hint.contains("hour") || hint.contains("5h") || hint.contains("five") { return "5-hour" }
        if hint.contains("month") { return "Monthly" }
        if hint.contains("day") { return "Daily" }
        return "Weekly"
    }
}
