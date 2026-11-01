import Foundation

// Pure derivations over an `AgenticUseSnapshot` that several dashboard panels
// share. Kept out of the views so each rule is unit-testable and every panel
// reads the same numbers.

// MARK: - Bucket totals

/// One chart bucket summed across providers — the KPI sparklines and the
/// spike insight read these.
struct AgenticBucketTotal: Sendable, Equatable {
    let day: Date
    let cost: Double
    let tokens: Int
    let cacheSavings: Double
    let cacheReadTokens: Int
    let observedInputTokens: Int

    /// Cache-read share of observed input, or `nil` when the bucket saw no
    /// input (so a silent hour doesn't read as a 0% hit rate).
    var cachedInputShare: Double? {
        observedInputTokens > 0 ? Double(cacheReadTokens) / Double(observedInputTokens) : nil
    }
}

extension AgenticUseSnapshot {
    /// `providerSeries` collapsed to one total per bucket, oldest first.
    var bucketTotals: [AgenticBucketTotal] {
        var order: [Date] = []
        var sums: [Date: (Double, Int, Double, Int, Int)] = [:]
        for point in providerSeries {
            if sums[point.day] == nil { order.append(point.day) }
            var cell = sums[point.day, default: (0, 0, 0, 0, 0)]
            cell.0 += point.cost
            cell.1 += point.tokens
            cell.2 += point.cacheSavings
            cell.3 += point.cacheReadTokens
            cell.4 += point.observedInputTokens
            sums[point.day] = cell
        }
        return order.sorted().map { day in
            let cell = sums[day]!
            return AgenticBucketTotal(
                day: day, cost: cell.0, tokens: cell.1, cacheSavings: cell.2,
                cacheReadTokens: cell.3, observedInputTokens: cell.4
            )
        }
    }

    /// One model's token usage per bucket, oldest first — the Top Models
    /// trend column.
    func tokenTrend(for model: String) -> [Double] {
        dailySeries.filter { $0.model == model }.map { Double($0.tokens) }
    }
}

// MARK: - Token flow (Sankey) graph

/// Provider → model → token-type flow, weighted by processed tokens.
///
/// The middle column keeps the top `maxModels` models by tokens and folds the
/// rest into one "Other models" node, so the diagram stays legible however
/// many models a range contains. Every link value is a real token count:
/// provider outflow equals model inflow, and model outflow equals the model's
/// input + cache write + cache read + output split.
struct AgenticTokenFlowGraph: Equatable {
    enum TokenType: String, CaseIterable, Identifiable {
        case input
        case cacheWrite
        case cacheRead
        case output

        var id: String { rawValue }

        var title: String {
            switch self {
            case .input: "Input"
            case .cacheWrite: "Cache Write"
            case .cacheRead: "Cached Input"
            case .output: "Output"
            }
        }

        var symbol: String {
            switch self {
            case .input: "arrow.down.doc"
            case .cacheWrite: "square.and.arrow.down.on.square"
            case .cacheRead: "shippingbox"
            case .output: "text.bubble"
            }
        }
    }

    enum NodeID: Hashable {
        case provider(AgenticProvider)
        /// Canonical model id.
        case model(String)
        case otherModels
        case tokenType(TokenType)
    }

    struct Node: Identifiable, Equatable {
        let id: NodeID
        let tokens: Int
        /// Priced cost flowing through the node (providers and models only).
        let cost: Double
    }

    struct Link: Identifiable, Equatable {
        let source: NodeID
        let target: NodeID
        let tokens: Int

        var id: String { "\(source)→\(target)" }
    }

    let providers: [Node]
    let models: [Node]
    let tokenTypes: [Node]
    let links: [Link]

    var totalTokens: Int { providers.reduce(0) { $0 + $1.tokens } }

    /// The model nodes folded into `otherModels`, for its tooltip.
    let otherModelNames: [String]

    static func make(modelTotals: [AgenticModelTotal], maxModels: Int = 7) -> AgenticTokenFlowGraph {
        let active = modelTotals.filter { $0.tokens > 0 }
        let ranked = active.sorted { $0.tokens == $1.tokens ? $0.model < $1.model : $0.tokens > $1.tokens }
        // Folding a single model into "Other" hides a name for no space saved.
        let keepCount = ranked.count > maxModels + 1 ? maxModels : ranked.count
        let kept = Array(ranked.prefix(keepCount))
        let folded = Array(ranked.dropFirst(keepCount))

        func modelNode(for total: AgenticModelTotal) -> NodeID {
            keepCount < ranked.count && !kept.contains(where: { $0.model == total.model })
                ? .otherModels : .model(total.model)
        }

        var providerTokens: [AgenticProvider: (tokens: Int, cost: Double)] = [:]
        var providerToModel: [NodeID: [NodeID: Int]] = [:]
        var modelToType: [NodeID: [TokenType: Int]] = [:]
        var modelSums: [NodeID: (tokens: Int, cost: Double)] = [:]
        var typeSums: [TokenType: Int] = [:]

        for total in active {
            let node = modelNode(for: total)
            var provider = providerTokens[total.provider, default: (0, 0)]
            provider.tokens += total.tokens
            provider.cost += total.cost
            providerTokens[total.provider] = provider
            providerToModel[.provider(total.provider), default: [:]][node, default: 0] += total.tokens
            var sum = modelSums[node, default: (0, 0)]
            sum.tokens += total.tokens
            sum.cost += total.cost
            modelSums[node] = sum
            let split: [(TokenType, Int)] = [
                (.input, total.inputTokens), (.cacheWrite, total.cacheWriteTokens),
                (.cacheRead, total.cacheReadTokens), (.output, total.outputTokens),
            ]
            for (type, tokens) in split where tokens > 0 {
                modelToType[node, default: [:]][type, default: 0] += tokens
                typeSums[type, default: 0] += tokens
            }
        }

        let providers = providerTokens
            .map { Node(id: .provider($0.key), tokens: $0.value.tokens, cost: $0.value.cost) }
            .sorted { $0.tokens > $1.tokens }
        // Models sit in provider order, largest first within a provider, so
        // provider-to-model ribbons never cross. Ranked globally, a Codex model
        // between two Claude models pulled ribbons across each other.
        var providerRank: [AgenticProvider: Int] = [:]
        for (index, node) in providers.enumerated() {
            if case .provider(let provider) = node.id { providerRank[provider] = index }
        }
        var models = kept.enumerated()
            .sorted { lhs, rhs in
                let lhsRank = providerRank[lhs.element.provider] ?? .max
                let rhsRank = providerRank[rhs.element.provider] ?? .max
                return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
            }
            .map { Node(id: .model($0.element.model), tokens: $0.element.tokens, cost: $0.element.cost) }
        if let other = modelSums[.otherModels] {
            models.append(Node(id: .otherModels, tokens: other.tokens, cost: other.cost))
        }
        let tokenTypes = TokenType.allCases.compactMap { type in
            typeSums[type].map { Node(id: .tokenType(type), tokens: $0, cost: 0) }
        }

        var links: [Link] = []
        for provider in providers {
            for model in models {
                if let tokens = providerToModel[provider.id]?[model.id], tokens > 0 {
                    links.append(Link(source: provider.id, target: model.id, tokens: tokens))
                }
            }
        }
        for model in models {
            for type in TokenType.allCases {
                if let tokens = modelToType[model.id]?[type], tokens > 0 {
                    links.append(Link(source: model.id, target: .tokenType(type), tokens: tokens))
                }
            }
        }

        return AgenticTokenFlowGraph(
            providers: providers,
            models: models,
            tokenTypes: tokenTypes,
            links: links,
            otherModelNames: folded.map(\.displayName)
        )
    }
}

// MARK: - Insights

/// One plain-language observation for the Insights row. Every figure comes
/// straight from the snapshot; nothing is extrapolated.
struct AgenticUseInsight: Identifiable, Equatable {
    enum Kind: String {
        case cacheHitRate
        case spike
        case costChange
        case topModel
    }

    enum Tone: Equatable {
        case positive
        case negative
        case neutral
    }

    let kind: Kind
    let title: String
    let detail: String
    let tone: Tone

    var id: String { kind.rawValue }
}

enum AgenticUseInsights {
    /// A bucket counts as a spike when it reaches this multiple of the
    /// window's average bucket cost.
    static let spikeThreshold = 1.5

    static func make(from snapshot: AgenticUseSnapshot, calendar: Calendar = .current) -> [AgenticUseInsight] {
        [cacheInsight(snapshot), spikeInsight(snapshot, calendar: calendar), costInsight(snapshot)]
            .compactMap { $0 }
    }

    private static func comparisonSuffix(_ snapshot: AgenticUseSnapshot) -> String {
        snapshot.range.comparisonLabel ?? ""
    }

    private static func cacheInsight(_ snapshot: AgenticUseSnapshot) -> AgenticUseInsight? {
        let stats = snapshot.stats
        guard stats.cachedInputTokens > 0 else { return nil }
        let rate = AgenticUseFormat.percent(stats.cachedInputShare)
        let savings = "Saved an estimated \(AgenticUseFormat.cost(stats.cacheSavingsUSD))."
        guard let previous = snapshot.previous, !previous.isEmpty, let label = snapshot.range.comparisonLabel else {
            return AgenticUseInsight(
                kind: .cacheHitRate,
                title: "Cache hit rate \(rate)",
                detail: "\(rate) of input tokens were cache reads. \(savings)",
                tone: .positive
            )
        }
        let change = stats.cachedInputShare - previous.cachedInputShare
        guard abs(change) >= 0.0005 else {
            return AgenticUseInsight(
                kind: .cacheHitRate,
                title: "Cache hit rate held",
                detail: "\(rate), unchanged \(label). \(savings)",
                tone: .positive
            )
        }
        let sign = change > 0 ? "+" : "−"
        return AgenticUseInsight(
            kind: .cacheHitRate,
            title: "Cache hit rate \(change > 0 ? "increased" : "decreased")",
            detail: "\(rate) (\(sign)\(AgenticUseFormat.deltaPoints(change))) \(label). \(savings)",
            tone: change > 0 ? .positive : .negative
        )
    }

    private static func spikeInsight(_ snapshot: AgenticUseSnapshot, calendar: Calendar) -> AgenticUseInsight? {
        let buckets = snapshot.bucketTotals
        let active = buckets.filter { $0.cost > 0 }
        guard buckets.count >= 3, active.count >= 3,
              let peak = buckets.max(by: { $0.cost < $1.cost }) else { return nil }
        let average = buckets.reduce(0) { $0 + $1.cost } / Double(buckets.count)
        guard average > 0, peak.cost >= average * spikeThreshold else { return nil }

        let leaders = snapshot.dailySeries
            .filter { $0.day == peak.day && $0.cost > 0 }
            .sorted { $0.cost > $1.cost }
        let providerLeader = snapshot.providerSeries
            .filter { $0.day == peak.day }
            .max { $0.cost < $1.cost }
        let providerName = providerLeader?.provider.displayName ?? "Usage"
        let when = snapshot.range.bucketUnit == .hour
            ? peak.day.formatted(.dateTime.hour().minute())
            : peak.day.formatted(.dateTime.month(.abbreviated).day())
        let unit = snapshot.range.bucketUnit == .hour ? "hourly" : "daily"
        var detail = "+\(AgenticUseFormat.deltaPercent(peak.cost / average - 1)) above the \(unit) average on \(when)"
        if let top = leaders.first {
            detail += ", mostly \(top.displayName)."
        } else {
            detail += "."
        }
        return AgenticUseInsight(kind: .spike, title: "\(providerName) usage spike", detail: detail, tone: .negative)
    }

    private static func costInsight(_ snapshot: AgenticUseSnapshot) -> AgenticUseInsight? {
        if let previous = snapshot.previous, previous.totalCostUSD > 0,
           let change = AgenticUseFormat.relativeChange(current: snapshot.totalCostUSD, previous: previous.totalCostUSD),
           let label = snapshot.range.comparisonLabel {
            let direction = change < 0 ? "down" : "up"
            let period = label.replacingOccurrences(of: "vs ", with: "")
            return AgenticUseInsight(
                kind: .costChange,
                title: "Total cost \(direction) \(AgenticUseFormat.deltaPercent(change))",
                detail: "\(AgenticUseFormat.compactCost(snapshot.totalCostUSD)) vs \(AgenticUseFormat.compactCost(previous.totalCostUSD)) in the \(period).",
                tone: change <= 0 ? .positive : .negative
            )
        }
        guard let top = snapshot.modelTotals.first(where: { !$0.isUnpriced && $0.cost > 0 }) else { return nil }
        let count = snapshot.modelTotals.count
        return AgenticUseInsight(
            kind: .topModel,
            title: "\(top.displayName) leads cost",
            detail: "\(AgenticUseFormat.percent(top.costShare)) of estimated cost across \(count) model\(count == 1 ? "" : "s").",
            tone: .neutral
        )
    }
}
