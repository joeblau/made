import SwiftUI

/// Sankey-style token flow: provider → model → token type.
///
/// Swift Charts has no flow mark, so ribbons are drawn in a `Canvas` and the
/// nodes are ordinary SwiftUI cards laid over it. Each ribbon's thickness at
/// either end is its share of that node's tokens, so every node's ribbons
/// exactly fill its edge; hovering a node highlights the flow through it.
struct AgenticUseTokenFlowPanel: View {
    let snapshot: AgenticUseSnapshot

    @State private var hovered: AgenticTokenFlowGraph.NodeID?

    private var graph: AgenticTokenFlowGraph {
        AgenticTokenFlowGraph.make(modelTotals: snapshot.modelTotals)
    }

    var body: some View {
        let graph = graph
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.medium) {
            HStack(alignment: .firstTextBaseline, spacing: LiquidGlassMetrics.Spacing.xSmall) {
                Text("Token Flow").agenticUseCardTitle()
                Text("\(AgenticUseFormat.tokens(graph.totalTokens)) tokens by provider, model, and type")
                    .agenticUseFont(.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            if graph.links.isEmpty {
                ContentUnavailableView("No token flow", systemImage: "point.3.connected.trianglepath.dotted")
                    .frame(minHeight: 200)
            } else {
                AgenticUseTokenFlowDiagram(
                    graph: graph,
                    modelTotals: snapshot.modelTotals,
                    hovered: $hovered
                )
                .frame(height: Self.height(for: graph))
            }
        }
        .agenticUseCard()
    }

    /// Tall enough that the busiest column's nodes keep a comfortable gap.
    static func height(for graph: AgenticTokenFlowGraph) -> CGFloat {
        let models = CGFloat(graph.models.count) * (AgenticUseTokenFlowDiagram.modelHeight + 14)
        let providers = CGFloat(graph.providers.count) * (AgenticUseTokenFlowDiagram.providerHeight + 18)
        let types = CGFloat(graph.tokenTypes.count) * (AgenticUseTokenFlowDiagram.typeHeight + 22)
        return max(300, models, providers, types)
    }
}

private struct AgenticUseTokenFlowDiagram: View {
    let graph: AgenticTokenFlowGraph
    let modelTotals: [AgenticModelTotal]
    @Binding var hovered: AgenticTokenFlowGraph.NodeID?

    nonisolated static let providerHeight: CGFloat = 60
    nonisolated static let modelHeight: CGFloat = 30
    nonisolated static let typeHeight: CGFloat = 52

    typealias NodeID = AgenticTokenFlowGraph.NodeID

    var body: some View {
        GeometryReader { geometry in
            let layout = Layout(graph: graph, size: geometry.size)
            let highlighted = highlightedLinks
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for ribbon in layout.ribbons {
                        let emphasis: Double = if let highlighted {
                            highlighted.contains(ribbon.link.id) ? 0.78 : 0.07
                        } else {
                            0.4
                        }
                        let from = color(for: ribbon.link.source)
                        let to = color(for: ribbon.link.target)
                        context.fill(
                            ribbon.path,
                            with: .linearGradient(
                                Gradient(colors: [from.opacity(emphasis), to.opacity(emphasis)]),
                                startPoint: CGPoint(x: ribbon.startX, y: 0),
                                endPoint: CGPoint(x: ribbon.endX, y: 0)
                            )
                        )
                    }
                }
                .allowsHitTesting(false)
                .animation(LiquidGlassMetrics.stateChange, value: hovered)

                ForEach(layout.frames, id: \.id) { frame in
                    node(frame.id)
                        .frame(width: frame.rect.width, height: frame.rect.height)
                        .position(x: frame.rect.midX, y: frame.rect.midY)
                        .onHover { inside in
                            if inside {
                                hovered = frame.id
                            } else if hovered == frame.id {
                                hovered = nil
                            }
                        }
                }
            }
        }
    }

    // MARK: - Highlighting

    /// Links to emphasize for the hovered node: its own links plus the flow
    /// one hop beyond, so hovering a provider lights its models' outputs.
    private var highlightedLinks: Set<String>? {
        guard let hovered else { return nil }
        let direct = graph.links.filter { $0.source == hovered || $0.target == hovered }
        var ids = Set(direct.map(\.id))
        let neighbors = Set(direct.flatMap { [$0.source, $0.target] }).subtracting([hovered])
        switch hovered {
        case .provider:
            for link in graph.links where neighbors.contains(link.source) { ids.insert(link.id) }
        case .tokenType:
            for link in graph.links where neighbors.contains(link.target) { ids.insert(link.id) }
        case .model, .otherModels:
            break
        }
        return ids
    }

    // MARK: - Colors

    private func color(for id: NodeID) -> Color {
        switch id {
        case .provider(let provider):
            AgenticUseModelPalette.providerColor(for: provider)
        case .model(let model):
            modelTotals.first { $0.model == model }
                .map { AgenticUseModelPalette.providerColor(for: $0.provider) } ?? .gray
        case .otherModels:
            .gray
        case .tokenType(let type):
            Self.tint(for: type)
        }
    }

    static func tint(for type: AgenticTokenFlowGraph.TokenType) -> Color {
        switch type {
        case .input: .cyan
        case .cacheWrite: .indigo
        case .cacheRead: .purple
        case .output: .mint
        }
    }

    // MARK: - Nodes

    @ViewBuilder
    private func node(_ id: NodeID) -> some View {
        switch id {
        case .provider(let provider):
            if let node = graph.providers.first(where: { $0.id == id }) {
                providerNode(provider, node: node)
            }
        case .model(let model):
            if let total = modelTotals.first(where: { $0.model == model }) {
                modelNode(
                    title: total.displayName,
                    provider: total.provider,
                    help: "\(total.displayName): \(AgenticUseFormat.tokens(total.tokens)) tokens"
                        + (total.isUnpriced ? " (unpriced)" : " · \(AgenticUseFormat.cost(total.cost))")
                )
            }
        case .otherModels:
            modelNode(
                title: "Other Models",
                provider: nil,
                help: graph.otherModelNames.joined(separator: ", ")
            )
        case .tokenType(let type):
            if let node = graph.tokenTypes.first(where: { $0.id == id }) {
                typeNode(type, node: node)
            }
        }
    }

    private func isDimmed(_ id: NodeID) -> Bool {
        guard let hovered, hovered != id, let links = highlightedLinks else { return false }
        return !graph.links.contains { links.contains($0.id) && ($0.source == id || $0.target == id) }
    }

    private func providerNode(_ provider: AgenticProvider, node: AgenticTokenFlowGraph.Node) -> some View {
        let tint = AgenticUseModelPalette.providerColor(for: provider)
        // Soft tint like the token-type tiles: a solid gradient tile read as
        // a button and out-shouted the flow itself.
        return HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
            RoundedRectangle(cornerRadius: NodeMetrics.tileRadius, style: .continuous)
                .fill(tint.opacity(0.2))
                .frame(width: 36, height: 36)
                .overlay {
                    // Icon glyphs fill about 55% of their tile; they don't follow the text scale.
                    Image(provider.brandSymbol)
                        .scaledFont(size: 20, weight: .semibold)
                        .foregroundStyle(tint)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .agenticUseFont(.body, weight: .semibold)
                Text("\(AgenticUseFormat.tokens(node.tokens)) tokens")
                    .agenticUseFont(.caption)
                    .foregroundStyle(.secondary)
                Text(node.cost > 0 ? AgenticUseFormat.cost(node.cost) : "—")
                    .agenticUseFont(.caption, weight: .medium)
                    .monospacedDigit()
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NodeMetrics.padding)
        .nodeChrome(tint: tint, dimmed: isDimmed(.provider(provider)))
    }

    private func modelNode(title: String, provider: AgenticProvider?, help: String) -> some View {
        HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
            Group {
                if let provider {
                    Image(provider.brandSymbol)
                        .foregroundStyle(AgenticUseModelPalette.providerColor(for: provider))
                } else {
                    Image(systemName: "square.grid.2x2")
                        .foregroundStyle(.secondary)
                }
            }
            .agenticUseFont(.meta, weight: .semibold)
            .frame(width: 16)
            .accessibilityHidden(true)
            Text(title)
                .agenticUseFont(.meta, weight: .medium)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        // Model nodes are short, so the concentric node radius renders them
        // as capsules; pad a little more so the text clears the round ends.
        .padding(.horizontal, NodeMetrics.padding + LiquidGlassMetrics.Spacing.xxSmall)
        .nodeChrome(tint: nil, dimmed: false)
        .help(help)
    }

    private func typeNode(_ type: AgenticTokenFlowGraph.TokenType, node: AgenticTokenFlowGraph.Node) -> some View {
        let tint = Self.tint(for: type)
        let share = graph.totalTokens > 0 ? Double(node.tokens) / Double(graph.totalTokens) : 0
        return HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
            RoundedRectangle(cornerRadius: NodeMetrics.tileRadius, style: .continuous)
                .fill(tint.opacity(0.2))
                .frame(width: 32, height: 32)
                .overlay {
                    // Glyph sized to its tile, not to the text scale.
                    Image(systemName: type.symbol)
                        .scaledFont(size: 17, weight: .semibold)
                        .foregroundStyle(tint)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(type.title)
                    .agenticUseFont(.body, weight: .semibold)
                Text("\(AgenticUseFormat.tokens(node.tokens)) (\(AgenticUseFormat.percent(share)))")
                    .agenticUseFont(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NodeMetrics.padding)
        .nodeChrome(tint: tint, dimmed: isDimmed(.tokenType(type)))
    }

    // MARK: - Layout

    struct NodeFrame {
        let id: NodeID
        let rect: CGRect
    }

    struct Ribbon {
        let link: AgenticTokenFlowGraph.Link
        let path: Path
        let startX: CGFloat
        let endX: CGFloat
    }

    /// Column geometry plus ribbon paths for one size. Ribbons attach to the
    /// node edges in the vertical order of their far ends, which keeps
    /// crossings to the ones the data actually forces.
    struct Layout {
        let frames: [NodeFrame]
        let ribbons: [Ribbon]

        /// Thinnest ribbon end drawn, so a tiny output share stays visible.
        static let minimumSpan: CGFloat = 1.5

        init(graph: AgenticTokenFlowGraph, size: CGSize) {
            let width = max(size.width, 300)
            let nodeWidth = min(180, max(118, (width - 2 * 56) / 3))
            let columns: [(nodes: [AgenticTokenFlowGraph.Node], x: CGFloat, height: CGFloat)] = [
                (graph.providers, 0, AgenticUseTokenFlowDiagram.providerHeight),
                (graph.models, (width - nodeWidth) / 2, AgenticUseTokenFlowDiagram.modelHeight),
                (graph.tokenTypes, width - nodeWidth, AgenticUseTokenFlowDiagram.typeHeight),
            ]
            var frames: [NodeFrame] = []
            var rects: [NodeID: CGRect] = [:]
            for column in columns {
                for (index, y) in Self.stack(count: column.nodes.count, nodeHeight: column.height, in: size.height).enumerated() {
                    let rect = CGRect(x: column.x, y: y, width: nodeWidth, height: column.height)
                    frames.append(NodeFrame(id: column.nodes[index].id, rect: rect))
                    rects[column.nodes[index].id] = rect
                }
            }

            let tokensByNode = Dictionary(
                (graph.providers + graph.models + graph.tokenTypes).map { ($0.id, $0.tokens) },
                uniquingKeysWith: { first, _ in first }
            )

            // Per-node attachment offsets for outgoing (right edge) and
            // incoming (left edge) ribbons.
            var outgoing: [String: (CGFloat, CGFloat)] = [:]
            var incoming: [String: (CGFloat, CGFloat)] = [:]
            for (id, rect) in rects {
                let inset: CGFloat = 5
                let band = rect.height - inset * 2
                let total = CGFloat(tokensByNode[id] ?? 0)
                guard total > 0 else { continue }
                let outs = graph.links.filter { $0.source == id }
                    .sorted { (rects[$0.target]?.midY ?? 0) < (rects[$1.target]?.midY ?? 0) }
                var cursor = rect.minY + inset
                for link in outs {
                    let span = max(Self.minimumSpan, band * CGFloat(link.tokens) / total)
                    outgoing[link.id] = (cursor, cursor + span)
                    cursor += span
                }
                let ins = graph.links.filter { $0.target == id }
                    .sorted { (rects[$0.source]?.midY ?? 0) < (rects[$1.source]?.midY ?? 0) }
                cursor = rect.minY + inset
                for link in ins {
                    let span = max(Self.minimumSpan, band * CGFloat(link.tokens) / total)
                    incoming[link.id] = (cursor, cursor + span)
                    cursor += span
                }
            }

            ribbons = graph.links.compactMap { link in
                guard let source = rects[link.source], let target = rects[link.target],
                      let start = outgoing[link.id], let end = incoming[link.id] else { return nil }
                let x0 = source.maxX - 1
                let x1 = target.minX + 1
                let mid = (x0 + x1) / 2
                var path = Path()
                path.move(to: CGPoint(x: x0, y: start.0))
                path.addCurve(
                    to: CGPoint(x: x1, y: end.0),
                    control1: CGPoint(x: mid, y: start.0),
                    control2: CGPoint(x: mid, y: end.0)
                )
                path.addLine(to: CGPoint(x: x1, y: end.1))
                path.addCurve(
                    to: CGPoint(x: x0, y: start.1),
                    control1: CGPoint(x: mid, y: end.1),
                    control2: CGPoint(x: mid, y: start.1)
                )
                path.closeSubpath()
                return Ribbon(link: link, path: path, startX: x0, endX: x1)
            }
            self.frames = frames
        }

        /// Top edges for `count` nodes centered in `height`, with gaps capped
        /// so a short column doesn't scatter to the corners.
        static func stack(count: Int, nodeHeight: CGFloat, in height: CGFloat) -> [CGFloat] {
            guard count > 0 else { return [] }
            guard count > 1 else { return [(height - nodeHeight) / 2] }
            let free = max(0, height - CGFloat(count) * nodeHeight)
            let gap = min(free / CGFloat(count - 1), nodeHeight * 0.9 + 18)
            let block = CGFloat(count) * nodeHeight + CGFloat(count - 1) * gap
            let top = (height - block) / 2
            return (0..<count).map { top + CGFloat($0) * (nodeHeight + gap) }
        }
    }
}

/// Node geometry. Icon tiles sit `padding` in from the node edge, so the node
/// radius is the tile radius plus that padding — concentric corners (LAY-4).
private enum NodeMetrics {
    static let padding: CGFloat = LiquidGlassMetrics.Spacing.xSmall
    static let tileRadius: CGFloat = LiquidGlassMetrics.Radius.control
    static let radius: CGFloat = tileRadius + padding
}

private extension View {
    /// Shared node card: an opaque fill so ribbons pass cleanly underneath,
    /// with a tinted wash for provider and token-type nodes. No outline —
    /// the wash already separates each node from the ribbons. Nodes are
    /// content (data), not controls, so they stay solid rather than glass.
    func nodeChrome(tint: Color?, dimmed: Bool) -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: NodeMetrics.radius, style: .continuous)
                    .fill(.background)
                RoundedRectangle(cornerRadius: NodeMetrics.radius, style: .continuous)
                    .fill((tint ?? .secondary).opacity(tint == nil ? 0.1 : 0.16))
            }
            .opacity(dimmed ? 0.45 : 1)
            .animation(LiquidGlassMetrics.stateChange, value: dimmed)
    }
}
