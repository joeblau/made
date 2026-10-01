import Foundation

/// USD rates per million tokens for one model.
///
/// - `cacheRead` defaults to 0.1x input (the Anthropic/Moonshot convention)
///   but can be overridden for models with bespoke cache pricing.
/// - `fastInput`/`fastOutput` are optional fast-tier rates.
struct AgenticModelRate: Sendable, Equatable, Codable {
    struct ContextTier: Sendable, Equatable, Codable {
        let threshold: Int
        var includesThreshold: Bool = false
        let input: Double
        let output: Double
        let cacheRead: Double
        let cacheWrite: Double
    }

    let inputPerMillionUSD: Double
    let outputPerMillionUSD: Double
    let cacheReadPerMillionUSD: Double
    let fastInputPerMillionUSD: Double?
    let fastOutputPerMillionUSD: Double?
    let cacheWritePerMillionUSD: Double
    let contextTiers: [ContextTier]

    init(
        input: Double,
        output: Double,
        cacheRead: Double? = nil,
        fastInput: Double? = nil,
        fastOutput: Double? = nil,
        cacheWrite: Double? = nil,
        contextTiers: [ContextTier] = []
    ) {
        self.inputPerMillionUSD = input
        self.outputPerMillionUSD = output
        self.cacheReadPerMillionUSD = cacheRead ?? input * AgenticUsagePricing.cacheReadMultiplier
        self.fastInputPerMillionUSD = fastInput
        self.fastOutputPerMillionUSD = fastOutput
        self.cacheWritePerMillionUSD = cacheWrite ?? input * AgenticUsagePricing.cacheWrite5mMultiplier
        self.contextTiers = contextTiers.sorted { $0.threshold < $1.threshold }
    }

    /// The input rate for a record, honoring the fast tier when the model
    /// defines one; models without a fast row bill fast calls at standard.
    func inputRate(fast: Bool) -> Double {
        fast ? (fastInputPerMillionUSD ?? inputPerMillionUSD) : inputPerMillionUSD
    }

    func outputRate(fast: Bool) -> Double {
        fast ? (fastOutputPerMillionUSD ?? outputPerMillionUSD) : outputPerMillionUSD
    }
}

/// The authoritative pricing table and cost math for Agentic Use.
///
/// Cost is computed from tokens except when the log itself carries an exact
/// cost (`nativeCostUSD`, Grok), which always wins. A model absent from
/// `rates` yields `nil` (an "unpriced" record) so unknown models surface in
/// the UI instead of silently costing $0.
enum AgenticUsagePricing {
    /// Cache writes bill at 1.25x the model's input rate (5-minute TTL).
    static let cacheWrite5mMultiplier = 1.25
    /// 1h-TTL cache writes bill at 2.0x the model's input rate, matching the
    /// API price sheet and ccusage.
    static let cacheWrite1hMultiplier = 2.0
    /// Default cache-read rate: 0.1x the model's input rate.
    static let cacheReadMultiplier = 0.1

    /// Offline fallback, reviewed 2026-10-01 against provider price sheets:
    /// https://platform.claude.com/docs/en/about-claude/pricing
    /// https://developers.openai.com/api/docs/pricing
    /// https://docs.x.ai/developers/release-notes
    /// https://platform.kimi.ai/docs/pricing/chat
    /// The live catalog adds models and updates rates without an app release.
    static let reviewedDate = "2026-10-01"

    private static func openAIRate(
        input: Double, output: Double, cacheRead: Double,
        cacheWriteMultiplier: Double = 1.25, fastMultiplier: Double = 2
    ) -> AgenticModelRate {
        AgenticModelRate(
            input: input, output: output, cacheRead: cacheRead,
            fastInput: input * fastMultiplier, fastOutput: output * fastMultiplier,
            cacheWrite: input * cacheWriteMultiplier,
            contextTiers: [.init(
                threshold: 272_000, input: input * 2, output: output * 1.5,
                cacheRead: cacheRead * 2, cacheWrite: input * 2 * cacheWriteMultiplier
            )]
        )
    }

    private static func grokRate(cacheRead: Double = 0.5) -> AgenticModelRate {
        AgenticModelRate(
            input: 2, output: 6, cacheRead: cacheRead, fastInput: 4, fastOutput: 12,
            contextTiers: [.init(
                threshold: 200_000, includesThreshold: true,
                input: 4, output: 12, cacheRead: cacheRead * 2, cacheWrite: 4
            )]
        )
    }

    static let rates: [String: AgenticModelRate] = [
        // Claude (Anthropic price sheet). Fable 5.1 and Mythos 5.1 bill cache
        // reads at 0.025x input ($0.25/M), not the usual 0.1x.
        "claude-opus-5-5": AgenticModelRate(input: 4, output: 20, cacheRead: 0.20, fastInput: 8, fastOutput: 40),
        "claude-sonnet-5-5": AgenticModelRate(input: 2, output: 10),
        "claude-opus-5": AgenticModelRate(input: 5.00, output: 25.00, fastInput: 10.00, fastOutput: 50.00),
        "claude-fable-5-1": AgenticModelRate(input: 10.00, output: 50.00, cacheRead: 0.25),
        "claude-mythos-5-1": AgenticModelRate(input: 10.00, output: 50.00, cacheRead: 0.25),
        "claude-fable-5": AgenticModelRate(input: 10.00, output: 50.00),
        "claude-mythos-5": AgenticModelRate(input: 10.00, output: 50.00),
        "claude-opus-4-8": AgenticModelRate(input: 5.00, output: 25.00, fastInput: 10, fastOutput: 50),
        "claude-opus-4-7": AgenticModelRate(input: 5.00, output: 25.00),
        "claude-opus-4-6": AgenticModelRate(input: 5.00, output: 25.00),
        "claude-opus-4-5": AgenticModelRate(input: 5.00, output: 25.00),
        // Sonnet 5's $2/$10 launch pricing became the standard price; the
        // announced $3/$15 increase for 2026-09-01 was cancelled.
        "claude-sonnet-5": AgenticModelRate(input: 2.00, output: 10.00),
        "claude-sonnet-4-6": AgenticModelRate(input: 3.00, output: 15.00),
        "claude-sonnet-4-5": AgenticModelRate(input: 3.00, output: 15.00),
        "claude-haiku-4-5": AgenticModelRate(input: 1.00, output: 5.00),
        // Codex uses published API-equivalent pricing, including the
        // >272K prompt tier. CLI/subscription usage is not an API invoice.
        "gpt-6-astra": openAIRate(input: 10, output: 50, cacheRead: 1),
        "gpt-6.1-sol": openAIRate(input: 2, output: 10, cacheRead: 0.1),
        "gpt-6-sol": openAIRate(input: 2, output: 10, cacheRead: 0.2),
        "gpt-6-luna": openAIRate(input: 0.1, output: 0.5, cacheRead: 0.01),
        "gpt-5.6-sol": openAIRate(input: 4, output: 20, cacheRead: 0.4),
        "gpt-5.5": openAIRate(input: 5, output: 30, cacheRead: 0.5, cacheWriteMultiplier: 1, fastMultiplier: 2.5),
        "gpt-5.4": openAIRate(input: 2.5, output: 15, cacheRead: 0.25, cacheWriteMultiplier: 1),
        "gpt-5.3-codex": AgenticModelRate(input: 1.75, output: 14.00),
        "gpt-5.3-codex-spark": AgenticModelRate(input: 1.75, output: 14.00),
        "gpt-5.2-codex": AgenticModelRate(input: 1.75, output: 14.00),
        "gpt-5.1-codex-mini": AgenticModelRate(input: 0.25, output: 2.00),
        "gpt-5-codex": AgenticModelRate(input: 1.25, output: 10.00),
        "gpt-5": AgenticModelRate(input: 1.25, output: 10.00),
        // Grok (xAI). Normally billed from the log's own costUsdTicks; these
        // rates are the fallback for turns that lack a native cost and the
        // full-rate baseline behind the cache-savings stat.
        "grok-4.7": grokRate(),
        "grok-4.7-build": grokRate(),
        "grok-4.6": grokRate(),
        "grok-4.6-build": grokRate(),
        "grok-4.5": grokRate(cacheRead: 0.3),
        "grok-4.5-build": grokRate(cacheRead: 0.3),
        // Kimi Code routing ids are API-equivalent estimates at the
        // underlying public model's rates, not subscription quota prices.
        "k3": AgenticModelRate(input: 3, output: 15, cacheWrite: 3),
        "k3-256k": AgenticModelRate(input: 3, output: 15, cacheWrite: 3),
        "kimi-k3": AgenticModelRate(input: 3, output: 15, cacheWrite: 3),
        "moonshot-ai/kimi-k3": AgenticModelRate(input: 3, output: 15, cacheWrite: 3),
        "kimi-for-coding": AgenticModelRate(input: 0.95, output: 4, cacheRead: 0.16),
        "kimi-k2.6": AgenticModelRate(input: 0.95, output: 4, cacheRead: 0.16),
        "kimi-k2.7-code": AgenticModelRate(input: 0.95, output: 4, cacheRead: 0.19),
        "kimi-for-coding-highspeed": AgenticModelRate(input: 1.9, output: 8, cacheRead: 0.38),
    ]

    static func rate(for model: String) -> AgenticModelRate? {
        rates[model]
    }

    static func isPriced(_ model: String) -> Bool {
        rates[model] != nil
    }

    /// Actual USD cost of one record, or `nil` when the model is unpriced.
    ///
    /// cost = input x inputRate + cacheWrite5m x writeRate + cacheWrite1h x in x 2.0
    ///        + cacheRead x readRate + output x outputRate, per million tokens —
    /// unless the record carries a native cost, which is exact and wins.
    static func cost(of record: AgenticUsageRecord, rates: [String: AgenticModelRate] = rates) -> Double? {
        if let native = record.nativeCostUSD { return native }
        guard let rate = rates[record.model] else { return nil }
        let effective = effectiveRates(for: rate, record: record)
        let write1h = min(record.cacheWrite1hTokens, record.cacheWriteTokens)
        let write5m = record.cacheWriteTokens - write1h
        let total = Double(record.inputTokens) * effective.input
            + Double(write5m) * effective.cacheWrite
            + Double(write1h) * effective.input * cacheWrite1hMultiplier
            + Double(record.cacheReadTokens) * effective.cacheRead
            + Double(record.outputTokens) * effective.output
        return total / 1_000_000
    }

    /// Hypothetical cost if every input token had billed at the full input
    /// rate — the baseline that makes "cache savings" (`fullRateCost - cost`)
    /// meaningful. `nil` when the model is unpriced (native-cost records
    /// still need a table entry to have a baseline).
    static func fullRateCost(of record: AgenticUsageRecord, rates: [String: AgenticModelRate] = rates) -> Double? {
        guard let rate = rates[record.model] else { return nil }
        let effective = effectiveRates(for: rate, record: record)
        let total = Double(record.observedInputTokens) * effective.input
            + Double(record.outputTokens) * effective.output
        return total / 1_000_000
    }

    /// Select context rates using all prompt tokens, then apply processing
    /// tier and geography to every category, preserving bespoke cache ratios.
    private static func effectiveRates(
        for rate: AgenticModelRate,
        record: AgenticUsageRecord
    ) -> (input: Double, output: Double, cacheRead: Double, cacheWrite: Double) {
        let tier = rate.contextTiers.last {
            $0.includesThreshold
                ? record.observedInputTokens >= $0.threshold
                : record.observedInputTokens > $0.threshold
        }
        let fast = record.isFast || ["fast", "priority"].contains(record.serviceTier ?? "")
        let inputScale = fast ? rate.inputRate(fast: true) / rate.inputPerMillionUSD : 1
        let outputScale = fast ? rate.outputRate(fast: true) / rate.outputPerMillionUSD : 1
        var multiplier = record.inferenceGeo == "us" ? 1.1 : 1.0
        if record.provider == .codex {
            if ["batch", "flex"].contains(record.serviceTier ?? "") { multiplier *= 0.5 }
            if record.serviceTier == "ultrafast", record.model == "gpt-6-astra" { multiplier *= 6 }
        }
        return (
            (tier?.input ?? rate.inputPerMillionUSD) * inputScale * multiplier,
            (tier?.output ?? rate.outputPerMillionUSD) * outputScale * multiplier,
            (tier?.cacheRead ?? rate.cacheReadPerMillionUSD) * inputScale * multiplier,
            (tier?.cacheWrite ?? rate.cacheWritePerMillionUSD) * inputScale * multiplier
        )
    }
}

/// A daily public catalog refresh, with a persistent last-known-good cache.
/// Only public pricing is downloaded; usage logs never leave the device.
actor AgenticPricingCatalog {
    struct Snapshot: Sendable, Codable {
        let fetchedAt: Date
        let reviewedDate: String
        let rates: [String: AgenticModelRate]
    }

    struct Result: Sendable {
        let rates: [String: AgenticModelRate]
        let fetchedAt: Date?
        let warning: String?
    }

    typealias Fetch = @Sendable () async throws -> Data
    private let cacheURL: URL
    private let fetch: Fetch
    private var cached: Snapshot?
    private var lastAttempt: Date?
    private static let maxBytes = 16 * 1024 * 1024

    init(cacheURL: URL? = nil, fetch: @escaping Fetch = AgenticPricingCatalog.download) {
        self.cacheURL = cacheURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.blau.pilot/agentic-pricing-v1.json")
        self.fetch = fetch
    }

    func load(force: Bool = false, now: Date = Date()) async -> Result {
        if cached == nil,
           let attributes = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
           let size = attributes[.size] as? Int, size <= Self.maxBytes,
           let data = try? Data(contentsOf: cacheURL),
           let saved = try? JSONDecoder().decode(Snapshot.self, from: data),
           saved.reviewedDate == AgenticUsagePricing.reviewedDate {
            cached = saved
        }
        if !force, let cached, now.timeIntervalSince(cached.fetchedAt) < 24 * 60 * 60 {
            return result(warning: nil)
        }
        // A failed fetch retries after five minutes, not every usage scan.
        if !force, let lastAttempt, now.timeIntervalSince(lastAttempt) < 5 * 60 {
            return result(warning: "Pricing refresh unavailable; using saved rates.")
        }
        lastAttempt = now
        do {
            let data = try await fetch()
            try Task.checkCancellation()
            let rates = try Self.decode(data)
            guard !rates.isEmpty else { throw URLError(.cannotParseResponse) }
            let snapshot = Snapshot(fetchedAt: now, reviewedDate: AgenticUsagePricing.reviewedDate, rates: rates)
            cached = snapshot
            try? FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if let encoded = try? JSONEncoder().encode(snapshot) {
                try? encoded.write(to: cacheURL, options: .atomic)
            }
            return result(warning: nil)
        } catch is CancellationError {
            return result(warning: nil)
        } catch {
            return result(warning: "Pricing refresh unavailable; using saved rates.")
        }
    }

    private func result(warning: String?) -> Result {
        var rates = AgenticUsagePricing.rates
        if let cached { rates.merge(cached.rates) { _, refreshed in refreshed } }
        return Result(rates: rates, fetchedAt: cached?.fetchedAt, warning: warning)
    }

    private nonisolated static func download() async throws -> Data {
        let url = URL(string: "https://models.dev/api.json")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.expectedContentLength <= maxBytes else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maxBytes else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }

    /// Import only USD API providers, never subscription-plan rows (whose
    /// zero prices describe quota access rather than API-equivalent cost).
    /// Prefer the catalog's explicit context threshold over its legacy 200K
    /// field: OpenAI's threshold is 272K, not 200K.
    nonisolated static func decode(_ data: Data) throws -> [String: AgenticModelRate] {
        guard data.count <= maxBytes,
              let providers = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw URLError(.cannotParseResponse) }
        var rates: [String: AgenticModelRate] = [:]
        for provider in ["anthropic", "openai", "xai", "moonshotai"] {
            guard let entry = providers[provider] as? [String: Any],
                  let models = entry["models"] as? [String: [String: Any]] else { continue }
            for id in models.keys.sorted() {
                guard let model = models[id], let canonical = AgenticModel.canonicalize(id),
                      let cost = model["cost"] as? [String: Any],
                      let input = number(cost["input"]), let output = number(cost["output"]),
                      input > 0, output > 0 else { continue }
                let fallback = AgenticUsagePricing.rate(for: canonical)
                // The reviewed price sheet wins over older community rows.
                // A later catalog revision can update existing models.
                if fallback != nil,
                   (model["last_updated"] as? String ?? "") <= AgenticUsagePricing.reviewedDate { continue }
                let cacheRead = number(cost["cache_read"]) ?? fallback?.cacheReadPerMillionUSD
                let cacheWrite = number(cost["cache_write"]) ?? fallback?.cacheWritePerMillionUSD
                var tiers: [AgenticModelRate.ContextTier] = []
                for tier in cost["tiers"] as? [[String: Any]] ?? [] {
                    guard let condition = tier["tier"] as? [String: Any],
                          condition["type"] as? String == "context",
                          let threshold = condition["size"] as? Int, threshold > 0,
                          let tierInput = number(tier["input"]),
                          let tierOutput = number(tier["output"]),
                          let tierCacheRead = number(tier["cache_read"]) else { continue }
                    tiers.append(.init(
                        threshold: threshold, includesThreshold: provider == "xai",
                        input: tierInput, output: tierOutput,
                        cacheRead: tierCacheRead,
                        cacheWrite: number(tier["cache_write"]) ?? tierInput * 1.25
                    ))
                }
                let fastMultiplier = fallback.map { $0.inputRate(fast: true) / $0.inputPerMillionUSD }
                rates[canonical] = AgenticModelRate(
                    input: input, output: output, cacheRead: cacheRead,
                    fastInput: fastMultiplier.map { input * $0 },
                    fastOutput: fastMultiplier.map { output * $0 },
                    cacheWrite: cacheWrite,
                    contextTiers: tiers.isEmpty ? (fallback?.contextTiers ?? []) : tiers
                )
            }
        }
        // Documented CLI routing names share the public model's rates.
        for (alias, publicID) in [
            "grok-4.7-build": "grok-4.7", "grok-4.6-build": "grok-4.6",
            "k3": "kimi-k3", "k3-256k": "kimi-k3", "moonshot-ai/kimi-k3": "kimi-k3",
            "kimi-for-coding-highspeed": "kimi-k2.7-code-highspeed",
        ] {
            if let rate = rates[publicID] { rates[alias] = rate }
        }
        return rates
    }

    private nonisolated static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite && value >= 0 && value <= 100_000 ? value : nil
    }
}
