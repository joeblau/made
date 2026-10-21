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
