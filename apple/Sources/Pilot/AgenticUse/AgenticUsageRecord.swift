import Foundation

/// Which local agent CLI a usage record came from. Each provider has its own
/// on-disk log format, parser, and dedup semantics in `AgenticUsageLoader`.
enum AgenticProvider: String, Sendable, CaseIterable {
    case claude
    case codex
    case grok
    case kimi

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .grok: "Grok"
        case .kimi: "Kimi"
        }
    }
}

/// One priced agent-CLI API call, parsed from a local usage log
/// (`~/.claude/projects`, `~/.codex/sessions`, `~/.grok/sessions`, or
/// `~/.kimi-code`).
///
/// The same call can be replayed into several log files (Claude Code replays
/// assistant messages; Codex replays session history on resume), so records
/// only become billable after `AgenticUsageLoader` deduplicates on
/// `dedupKey`. Token counts are kept in the raw categories the APIs report;
/// `AgenticUsagePricing` turns them into dollars.
struct AgenticUsageRecord: Sendable, Equatable {
    let provider: AgenticProvider
    /// Provider-scoped identity for deduplication, or `nil` for records that
    /// never deduplicate (Grok and Kimi logs are append-once).
    let dedupKey: String?
    /// Canonical model identifier: aliases resolved, provider prefixes and
    /// date suffixes stripped by the provider's parser.
    let model: String
    /// The record's timestamp (UTC).
    let timestamp: Date
    /// Uncached input tokens.
    let inputTokens: Int
    /// All cache-write tokens.
    let cacheWriteTokens: Int
    /// Portion of `cacheWriteTokens` written with a 1-hour TTL
    /// (`usage.cache_creation.ephemeral_1h_input_tokens`, Claude only). Kept
    /// separately so pricing can bill 1h writes at their own multiplier.
    let cacheWrite1hTokens: Int
    /// Cache-read tokens.
    let cacheReadTokens: Int
    let outputTokens: Int
    /// Reasoning/thinking output tokens. `nil` means "not reported", not
    /// zero — only some providers and versions log it.
    let thinkingTokens: Int?
    /// Whether the call billed at the priority tier (Claude `speed: "fast"`).
    let isFast: Bool
    /// Exact USD cost carried by the log itself (Grok's `costUsdTicks`).
    /// When present it wins over the pricing table.
    let nativeCostUSD: Double?

    /// Every token the API processed for this call.
    var totalTokens: Int {
        inputTokens + cacheWriteTokens + cacheReadTokens + outputTokens
    }

    /// All input-side tokens, cached or not — the denominator for the
    /// "% of observed input" stat and the >200k pricing-tier trigger.
    var observedInputTokens: Int {
        inputTokens + cacheWriteTokens + cacheReadTokens
    }
}

/// Model-identity policy: canonical ids, display names, and the fixed
/// presentation order shared by the chart legend, color palette, and lists.
enum AgenticModel {
    /// Canonicalizes a raw Claude `message.model` value, or returns `nil`
    /// when the record must be skipped entirely (`<synthetic>` placeholder
    /// responses carry no real cost).
    static func canonicalize(_ raw: String) -> String? {
        guard raw != "<synthetic>" else { return nil }
        let model = aliases[raw] ?? raw
        return strippingDateSuffix(model)
    }

    /// Bare aliases occasionally logged in place of full identifiers.
    private static let aliases: [String: String] = [
        "fable": "claude-fable-5",
        "haiku": "claude-haiku-4-5",
    ]

    /// "claude-haiku-4-5-20251001" -> "claude-haiku-4-5".
    private static func strippingDateSuffix(_ model: String) -> String {
        guard model.count > 9 else { return model }
        let suffix = model.suffix(9)
        guard suffix.first == "-", suffix.dropFirst().allSatisfy(\.isNumber) else { return model }
        return String(model.dropLast(9))
    }

    /// Human name for a canonical id: "claude-opus-4-8" -> "Opus 4.8".
    /// Non-Claude ids are already presentable ("gpt-5.6-sol", "k3") and pass
    /// through unchanged, as do unrecognized shapes, so nothing renders blank.
    static func displayName(for canonical: String) -> String {
        guard canonical.hasPrefix("claude-") else { return canonical }
        let parts = canonical.dropFirst("claude-".count).split(separator: "-")
        guard let family = parts.first, !family.isEmpty else { return canonical }
        let version = parts.dropFirst()
        guard !version.isEmpty, version.allSatisfy({ $0.allSatisfy(\.isNumber) }) else {
            return canonical
        }
        return family.prefix(1).uppercased() + family.dropFirst() + " " + version.joined(separator: ".")
    }

    /// Fixed presentation order, grouped by provider. The chart color scale,
    /// legend, stacking order, and hero list all follow this so a model keeps
    /// its identity as range filters change the set of visible series. Models
    /// not listed here sort after all known ones (they also render unpriced).
    static let presentationOrder: [String] = [
        "claude-opus-5",
        "claude-fable-5-1",
        "claude-fable-5",
        "claude-opus-4-8",
        "claude-opus-4-7",
        "claude-opus-4-6",
        "claude-opus-4-5",
        "claude-sonnet-5",
        "claude-sonnet-4-6",
        "claude-sonnet-4-5",
        "claude-haiku-4-5",
        "claude-mythos-5-1",
        "claude-mythos-5",
        "gpt-5.6-sol",
        "gpt-5.5",
        "gpt-5.4",
        "gpt-5.3-codex",
        "gpt-5.3-codex-spark",
        "gpt-5.2-codex",
        "gpt-5.1-codex-mini",
        "gpt-5-codex",
        "gpt-5",
        "grok-4.6-build",
        "grok-4.6",
        "grok-4.5-build",
        "grok-4.5",
        "k3",
        "k3-256k",
        "k3-max",
        "moonshot-ai/kimi-k3",
        "kimi-for-coding",
    ]

    /// Sort key into `presentationOrder`; unknown models share the tail slot.
    static func orderIndex(for canonical: String) -> Int {
        presentationOrder.firstIndex(of: canonical) ?? presentationOrder.count
    }
}
