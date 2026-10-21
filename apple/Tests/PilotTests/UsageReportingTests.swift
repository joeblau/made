import Foundation
import Testing
@testable import Pilot

@Suite("AI usage reporting")
struct UsageReportingTests {
    @Test("Codex accepts current scalar variants, reset fallbacks, and credit balances")
    func codexCurrentResponse() throws {
        let receivedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let root: [String: Any] = [
            "plan_type": "pro",
            "rate_limit": [
                "primary_window": [
                    "used_percent": "25.5",
                    "limit_window_seconds": 18_000,
                    "reset_after_seconds": "60",
                ],
                "secondary_window": [
                    "usedPercent": 80,
                    "windowDurationMins": 10_080,
                    "resetsAt": 1_800_604_800,
                ],
            ],
            "additional_rate_limits": [[
                "limit_name": "fast_model",
                "metered_feature": "fast",
                "rate_limit": [
                    "primary_window": [
                        "used_percent": 10,
                        "limit_window_seconds": 3_600,
                        "reset_at": 1_800_003_600,
                    ],
                ],
            ]],
            "credits": [
                "has_credits": true,
                "unlimited": false,
                "balance": "1129.25",
            ],
        ]

        let usage = CodexUsageAdapter.parse(root, receivedAt: receivedAt)

        #expect(usage.planLabel == "Pro")
        #expect(usage.windows.count == 3)
        #expect(Set(usage.windows.map(\.id)).count == 3)
        let primary = try #require(usage.windows.first { $0.id == "codex-primary" })
        #expect(abs(primary.utilization - 0.255) < 0.000_001)
        #expect(primary.name == "5-hour")
        #expect(primary.resetsAt == receivedAt.addingTimeInterval(60))
        let weekly = try #require(usage.windows.first { $0.id == "codex-secondary" })
        #expect(weekly.name == "Weekly")
        #expect(abs(weekly.utilization - 0.8) < 0.000_001)
        #expect(usage.credits?.balance == 1129.25)
        #expect(usage.credits?.unit == .credits)
    }

    @Test("Codex omits malformed windows instead of reporting false zero usage")
    func codexRejectsMalformedWindow() {
        let usage = CodexUsageAdapter.parse([
            "rate_limit": [
                "primary_window": [
                    "limit_window_seconds": 18_000,
                    "reset_at": 1_800_000_000,
                ],
            ],
        ])

        #expect(usage.windows.isEmpty)
    }

    @Test("Claude exposes extra-usage credits in major currency units")
    func claudeCredits() throws {
        let usage = ClaudeUsageAdapter.parse([
            "five_hour": [
                "utilization": 42,
                "resets_at": "2026-07-12T20:00:00Z",
            ],
            "seven_day": [
                "utilization": 1,
                "resets_at": "2026-07-19T20:00:00Z",
            ],
            "extra_usage": [
                "is_enabled": true,
                "monthly_limit": 5_000,
                "used_credits": 1_234,
                "utilization": 24.68,
                "currency": "usd",
            ],
        ], planLabel: "max")

        #expect(usage.planLabel == "Max")
        let window = try #require(usage.windows.first)
        #expect(abs(window.utilization - 0.42) < 0.000_001)
        let weekly = try #require(usage.windows.first { $0.id == "claude-seven_day" })
        #expect(abs(weekly.utilization - 0.01) < 0.000_001)
        let credits = try #require(usage.credits)
        #expect(credits.unit == .currency("USD"))
        #expect(credits.used == 12.34)
        #expect(credits.limit == 50)
        #expect(abs((credits.utilization ?? 0) - 0.2468) < 0.000_001)
    }

    @Test("Claude shows explicitly unlimited extra usage")
    func claudeUnlimitedCredits() throws {
        let usage = ClaudeUsageAdapter.parse([
            "extra_usage": [
                "is_enabled": true,
                "monthly_limit": NSNull(),
                "used_credits": NSNull(),
                "utilization": NSNull(),
                "currency": "usd",
            ],
        ])

        let credits = try #require(usage.credits)
        #expect(credits.unlimited)
        #expect(!credits.isEmpty)
    }

    @Test("Grok maps weekly billing usage, reset time, plan, and prepaid balance")
    func grokBilling() throws {
        let usage = GrokUsageAdapter.parse([
            "subscriptionTier": "super_grok",
            "creditUsagePercent": "37.5",
            "currentPeriod": [
                "type": "weekly",
                "start": "2026-07-06T12:00:00Z",
                "end": "2026-07-13T12:00:00Z",
            ],
            "prepaidBalance": ["val": 2_500],
        ])

        #expect(usage.planLabel == "Super Grok")
        let window = try #require(usage.windows.first)
        #expect(window.name == "Weekly")
        #expect(abs(window.utilization - 0.375) < 0.000_001)
        #expect(window.resetsAt == UsageJSON.date("2026-07-13T12:00:00Z"))
        #expect(usage.credits?.balance == 25)
        #expect(usage.credits?.unit == .currency("USD"))
    }

    @Test("Grok unwraps the current billing config response")
    func grokWrappedBillingConfig() throws {
        let usage = GrokUsageAdapter.parse([
            "config": [
                "creditUsagePercent": 2.0,
                "currentPeriod": [
                    "type": "USAGE_PERIOD_TYPE_WEEKLY",
                    "start": "2026-07-25T21:30:04.363559+00:00",
                    "end": "2026-08-01T21:30:04.363559+00:00",
                ],
                "prepaidBalance": ["val": 0],
            ],
        ], fallbackPlan: "oidc")

        #expect(usage.planLabel == "SuperGrok")
        let window = try #require(usage.windows.first)
        #expect(window.name == "Weekly")
        #expect(abs(window.utilization - 0.02) < 0.000_001)
        #expect(window.resetsAt == UsageJSON.date("2026-08-01T21:30:04.363559+00:00"))
        #expect(usage.credits?.balance == 0)
    }

    @Test("Grok auth prefers the current OIDC scope")
    func grokAuthScopePreference() throws {
        let data = try #require("""
        {
          "https://accounts.x.ai/sign-in": {
            "key": "legacy-token",
            "auth_mode": "session"
          },
          "https://auth.x.ai::expired-client": {
            "key": "expired-token",
            "auth_mode": "oidc",
            "expires_at": "2026-01-01T12:00:00Z"
          },
          "https://auth.x.ai::client-id": {
            "key": "oidc-token",
            "auth_mode": "oidc",
            "email": "dev@example.com",
            "team_id": "team-1",
            "expires_at": "2026-08-01T12:00:00Z"
          }
        }
        """.data(using: .utf8))

        let now = try #require(UsageJSON.date("2026-07-12T12:00:00Z"))
        let session = try #require(UsageSessions.GrokSession.parse(data: data, now: now))
        #expect(session.accessToken == "oidc-token")
        #expect(session.authMode == "oidc")
        #expect(session.email == "dev@example.com")
        #expect(session.teamId == "team-1")
    }

    @Test("Kimi accepts its current OAuth credential and identifies expired tokens")
    func kimiOAuthCredential() throws {
        let currentData = try #require("""
        {
          "access_token": "kimi-access-token",
          "refresh_token": "kimi-refresh-token",
          "expires_at": 1800000060,
          "scope": "openid profile",
          "token_type": "Bearer"
        }
        """.data(using: .utf8))
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let session = try #require(UsageSessions.KimiSession.parse(data: currentData))

        #expect(session.accessToken == "kimi-access-token")
        #expect(session.expiresAt == Date(timeIntervalSince1970: 1_800_000_060))
        #expect(!session.isExpired(at: now))

        let expiredData = try #require("""
        {
          "access_token": "expired-kimi-token",
          "refresh_token": "expired-refresh-token",
          "expires_at": 1799999999,
          "token_type": "Bearer"
        }
        """.data(using: .utf8))
        let expired = try #require(UsageSessions.KimiSession.parse(data: expiredData))
        #expect(expired.isExpired(at: now))
    }

    // MARK: - Kimi credential discovery

    /// Writes `credentials/<name>` under a throwaway root, oldest first so the
    /// modification order the discovery sort relies on is unambiguous.
    private func makeKimiRoot(
        _ files: [(name: String, token: String?)]
    ) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kimi-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("credentials", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        for (offset, file) in files.enumerated() {
            let url = directory.appendingPathComponent(file.name)
            let body = """
            {
              "access_token": "\(file.token ?? "")",
              "refresh_token": "kimi-refresh-token",
              "expires_at": \(file.token == nil ? 0 : 1_800_000_060),
              "token_type": "Bearer"
            }
            """
            try #require(body.data(using: .utf8)).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000
                    + Double(offset) * 60)],
                ofItemAtPath: url.path
            )
        }
        return root
    }

    @Test("An emptied pre-migration file does not hide the environment credential")
    func kimiEnvironmentCredentialWinsOverBlankedFile() throws {
        // The exact layout Kimi Code leaves behind after migrating: the fixed
        // name is kept but blanked, and the live token moves to a per-
        // environment file.
        let root = try makeKimiRoot([
            (name: "kimi-code.json", token: nil),
            (name: "kimi-code-env-0e4f99c69cc27850.json", token: "env-token"),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let session = try #require(UsageSessions.KimiSession.load(roots: [root]))
        #expect(session.accessToken == "env-token")
    }

    @Test("The newest environment credential wins, and the fixed name is tried last")
    func kimiPrefersNewestEnvironmentCredential() throws {
        let root = try makeKimiRoot([
            (name: "kimi-code.json", token: "fixed-token"),
            (name: "kimi-code-env-aaaa.json", token: "older-env-token"),
            (name: "kimi-code-env-bbbb.json", token: "newer-env-token"),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let ordered = UsageSessions.KimiSession.credentialFiles(in: root)
            .map(\.lastPathComponent)
        #expect(ordered == [
            "kimi-code-env-bbbb.json",
            "kimi-code-env-aaaa.json",
            "kimi-code.json",
        ])

        let session = try #require(UsageSessions.KimiSession.load(roots: [root]))
        #expect(session.accessToken == "newer-env-token")
    }

    @Test("A root holding only a blanked file falls through to the legacy root")
    func kimiFallsThroughToLegacyRoot() throws {
        let current = try makeKimiRoot([(name: "kimi-code.json", token: nil)])
        let legacy = try makeKimiRoot([(name: "kimi-code.json", token: "legacy-token")])
        defer {
            try? FileManager.default.removeItem(at: current)
            try? FileManager.default.removeItem(at: legacy)
        }

        let session = try #require(
            UsageSessions.KimiSession.load(roots: [current, legacy])
        )
        #expect(session.accessToken == "legacy-token")
    }

    @Test("A pre-migration install with only the fixed credential still loads")
    func kimiFixedCredentialStillLoads() throws {
        let root = try makeKimiRoot([(name: "kimi-code.json", token: "fixed-token")])
        defer { try? FileManager.default.removeItem(at: root) }

        let session = try #require(UsageSessions.KimiSession.load(roots: [root]))
        #expect(session.accessToken == "fixed-token")
        #expect(UsageSessions.KimiSession.load(roots: []) == nil)
    }

    @Test("Kimi maps weekly and detailed limits with absolute and relative resets")
    func kimiUsageWindows() throws {
        let receivedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = KimiUsageAdapter.parse([
            "user": [
                "membership": ["level": "LEVEL_STANDARD"],
            ],
            "parallel": ["limit": "30"],
            "usage": [
                "used": "25",
                "limit": 100,
                "resetAt": 1_800_604_800,
            ],
            "limits": [
                [
                    "name": "Fast models",
                    "detail": [
                        "remaining": "60",
                        "limit": "100",
                        "resetIn": "3600",
                    ],
                ],
                [
                    "window": ["duration": 300, "timeUnit": "MINUTE"],
                    "detail": [
                        "used": 80,
                        "limit": 200,
                        "reset_time": "2027-01-16T08:00:00Z",
                    ],
                ],
            ],
        ], receivedAt: receivedAt)

        #expect(usage.planLabel == "Vivace")
        #expect(usage.windows.count == 3)
        let weekly = try #require(usage.windows.first { $0.name == "Weekly limit" })
        #expect(abs(weekly.utilization - 0.25) < 0.000_001)
        #expect(weekly.resetsAt == Date(timeIntervalSince1970: 1_800_604_800))

        let fast = try #require(usage.windows.first { $0.name == "Fast models" })
        #expect(abs(fast.utilization - 0.4) < 0.000_001)
        #expect(fast.resetsAt == receivedAt.addingTimeInterval(3_600))

        let fiveHour = try #require(usage.windows.first { $0.name == "5h limit" })
        #expect(abs(fiveHour.utilization - 0.4) < 0.000_001)
        #expect(fiveHour.resetsAt == UsageJSON.date("2027-01-16T08:00:00Z"))
    }

    @Test("Usage windows display hourly limits first and weekly limits last")
    func usageWindowDisplayOrder() {
        let usage = ProviderUsage(planLabel: nil, windows: [
            UsageWindow(id: "weekly", name: "Weekly limit", utilization: 0.7, resetsAt: nil),
            UsageWindow(id: "other", name: "Fast models", utilization: 0.4, resetsAt: nil),
            UsageWindow(id: "five-hour", name: "5h limit", utilization: 0.2, resetsAt: nil),
        ])

        #expect(usage.windowsInDisplayOrder.map(\.id) == ["five-hour", "other", "weekly"])
    }

    @Test(
        "Kimi maps the Code credit multiplier to public plan names",
        arguments: [
            (1.0, "Moderato"),
            (5.0, "Allegretto"),
            (15.0, "Allegro"),
            (30.0, "Vivace"),
        ]
    )
    func kimiParallelLimitPlan(limit: Double, expected: String) {
        // Matches the live response shape: `level` stays LEVEL_STANDARD for
        // every paid tier, so `parallel.limit` carries the tier.
        let usage = KimiUsageAdapter.parse([
            "user": [
                "membership": ["level": "LEVEL_STANDARD"],
            ],
            "parallel": ["limit": String(Int(limit))],
        ])

        #expect(usage.planLabel == expected)
    }

    @Test("Kimi free membership still maps to Adagio")
    func kimiFreePlan() {
        let usage = KimiUsageAdapter.parse([
            "user": [
                "membership": ["level": "LEVEL_FREE"],
            ],
        ])

        #expect(usage.planLabel == "Adagio")
    }

    @Test("Kimi paid membership without a multiplier shows no badge")
    func kimiPaidPlanWithoutMultiplier() {
        // LEVEL_STANDARD alone must NOT guess a tier — a Vivace account
        // returns exactly this, and a wrong badge is worse than none.
        let usage = KimiUsageAdapter.parse([
            "user": [
                "membership": ["level": "LEVEL_STANDARD"],
            ],
        ])

        #expect(usage.planLabel == nil)
    }

    @Test("Kimi prefers an explicit plan title and hides unknown internal levels")
    func kimiMembershipPlanFallbacks() {
        let titled = KimiUsageAdapter.parse([
            "user": [
                "membership": [
                    "level": "LEVEL_FUTURE",
                    "displayName": "Prestissimo",
                ],
            ],
        ])
        let unknown = KimiUsageAdapter.parse([
            "user": [
                "membership": ["level": "LEVEL_FUTURE"],
            ],
        ])

        #expect(titled.planLabel == "Prestissimo")
        #expect(unknown.planLabel == nil)
    }

    @Test("Kimi maps its booster wallet and monthly USD allowance")
    func kimiBoosterWallet() throws {
        let usage = KimiUsageAdapter.parse([
            "boosterWallet": [
                "balance": [
                    "type": "BOOSTER",
                    "amount": 250_000_000,
                    "amountLeft": 125_000_000,
                ],
                "monthlyChargeLimitEnabled": true,
                "monthlyChargeLimit": [
                    "priceInCents": 5_000,
                    "currency": "USD",
                ],
                "monthlyUsed": [
                    "priceInCents": 1_234,
                    "currency": "USD",
                ],
            ],
        ])

        let credits = try #require(usage.credits)
        #expect(credits.balance == 1.25)
        #expect(credits.used == 12.34)
        #expect(credits.limit == 50)
        #expect(credits.unit == .currency("USD"))
        #expect(abs((credits.utilization ?? 0) - 0.2468) < 0.000_001)
    }

    @Test("Kimi.ai dashboard figures map to plan usage and extra usage")
    func kimiAIDashboardFigures() throws {
        let usage = KimiUsageAdapter.parse([
            "user": [
                "membership": ["level": "LEVEL_STANDARD"],
            ],
            "parallel": ["limit": 30],
            "usage": [
                "used": 33.06,
                "limit": 100,
            ],
            "limits": [
                [
                    "window": ["duration": 300, "timeUnit": "MINUTE"],
                    "detail": ["used": 61.45, "limit": 100],
                ],
                [
                    "window": ["duration": 7, "timeUnit": "DAY"],
                    "detail": ["used": 100, "limit": 100],
                ],
            ],
            "boosterWallet": [
                "balance": [
                    "type": "BOOSTER",
                    "amount": 5_000_000_000,
                    "amountLeft": 4_321_000_000,
                ],
                "monthlyChargeLimitEnabled": true,
                "monthlyChargeLimit": [
                    "priceInCents": 5_000,
                    "currency": "USD",
                ],
                "monthlyUsed": [
                    "priceInCents": 679,
                    "currency": "USD",
                ],
            ],
        ])

        #expect(usage.planLabel == "Vivace")
        let total = try #require(usage.windows.first { $0.id == "kimi-summary" })
        #expect(abs(total.utilization - 0.3306) < 0.000_001)
        let fiveHour = try #require(usage.windows.first { $0.name == "5h limit" })
        #expect(abs(fiveHour.utilization - 0.6145) < 0.000_001)
        let sevenDay = try #require(usage.windows.first { $0.name == "7d limit" })
        #expect(sevenDay.utilization == 1)

        let credits = try #require(usage.credits)
        #expect(credits.balance == 43.21)
        #expect(credits.used == 6.79)
        #expect(credits.limit == 50)
        #expect(abs((credits.utilization ?? 0) - 0.1358) < 0.000_001)
    }

    @Test("Kimi treats a disabled monthly cap as unlimited and defaults spend to zero")
    func kimiUnlimitedBoosterWallet() throws {
        let usage = KimiUsageAdapter.parse([
            "boosterWallet": [
                "balance": [
                    "type": "BOOSTER",
                    "amount": 20_000_000_000,
                    "amountLeft": 10_000_000_000,
                ],
            ],
        ])

        let credits = try #require(usage.credits)
        #expect(credits.balance == 100)
        #expect(credits.used == 0)
        #expect(credits.limit == nil)
        #expect(credits.unlimited)
        #expect(credits.unit == .currency("USD"))
    }

    @Test("Kimi omits unusable rows and clamps out-of-range utilization")
    func kimiMalformedLimits() throws {
        let usage = KimiUsageAdapter.parse([
            "usage": ["used": 1, "limit": 0],
            "limits": [
                ["name": "Missing limit", "detail": ["used": 10]],
                ["name": "Invalid limit", "detail": ["used": 10, "limit": "none"]],
                ["name": "Zero limit", "detail": ["used": 10, "limit": 0]],
                ["name": "Over quota", "detail": ["used": 150, "limit": 100]],
                ["name": "Negative usage", "detail": ["used": -10, "limit": 100]],
            ],
        ])

        #expect(usage.windows.count == 2)
        let over = try #require(usage.windows.first { $0.name == "Over quota" })
        #expect(over.utilization == 1)
        let negative = try #require(usage.windows.first { $0.name == "Negative usage" })
        #expect(negative.utilization == 0)
    }

    @Test("Codex labels additional multi-window pools so they are distinguishable")
    func codexLabelsAdditionalPools() throws {
        let usage = CodexUsageAdapter.parse([
            "plan_type": "pro",
            "rate_limit": [
                "primary_window": ["used_percent": 1, "limit_window_seconds": 18_000],
                "secondary_window": ["used_percent": 0, "limit_window_seconds": 604_800],
            ],
            "additional_rate_limits": [[
                "limit_name": "gpt_5_codex",
                "rate_limit": [
                    "primary_window": ["used_percent": 0, "limit_window_seconds": 18_000],
                    "secondary_window": ["used_percent": 0, "limit_window_seconds": 604_800],
                ],
            ]],
        ])

        // Main pool stays plain; the additional pool is labeled on both windows.
        #expect(usage.windows.contains { $0.name == "5-hour" })
        #expect(usage.windows.contains { $0.name == "Weekly" })
        #expect(usage.windows.contains { $0.name == "Gpt 5 Codex · 5-hour" })
        #expect(usage.windows.contains { $0.name == "Gpt 5 Codex · Weekly" })
    }

    @Test("Claude surfaces model-scoped limits like Fable and dedupes flat fields")
    func claudeScopedLimits() throws {
        let usage = ClaudeUsageAdapter.parse([
            "five_hour": ["utilization": 3, "resets_at": "2026-07-12T20:00:00Z"],
            "seven_day": ["utilization": 66, "resets_at": "2026-07-19T20:00:00Z"],
            "seven_day_opus": ["utilization": 12, "resets_at": "2026-07-19T20:00:00Z"],
            "limits": [
                [
                    "group": "weekly",
                    "percent": 5,
                    "resets_at": "2026-07-19T20:00:00Z",
                    "scope": ["model": ["display_name": "Fable"]],
                    "is_active": true,
                ],
                [
                    "group": "weekly",
                    "percent": 20,
                    "resets_at": "2026-07-19T20:00:00Z",
                    "scope": ["model": ["display_name": "Opus"]],
                    "is_active": true,
                ],
                [
                    "group": "weekly",
                    "percent": 99,
                    "scope": ["model": ["display_name": "Haiku"]],
                    "is_active": false,
                ],
            ],
        ], planLabel: "max")

        let fable = try #require(usage.windows.first { $0.name == "Weekly (Fable)" })
        #expect(abs(fable.utilization - 0.05) < 0.000_001)
        // Opus comes from `limits` (20%), superseding the flat seven_day_opus (12%).
        let opus = try #require(usage.windows.first { $0.name == "Weekly (Opus)" })
        #expect(abs(opus.utilization - 0.20) < 0.000_001)
        #expect(usage.windows.filter { $0.name == "Weekly (Opus)" }.count == 1)
        // Inactive scoped limits are excluded.
        #expect(!usage.windows.contains { $0.name == "Weekly (Haiku)" })
    }

    @Test(
        "Reset countdown formats fixed boundaries",
        arguments: [
            (TimeInterval(-1), "resetting…"),
            (TimeInterval(59 * 60 + 5), "resets in 59m 05s"),
            (TimeInterval(3 * 3_600 + 12 * 60), "resets in 3h 12m"),
            (TimeInterval(2 * 86_400 + 4 * 3_600), "resets in 2d 4h"),
        ]
    )
    func countdown(remaining: TimeInterval, expected: String) {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(UsageResetCountdown.text(
            until: now.addingTimeInterval(remaining),
            now: now
        ) == expected)
    }
}
