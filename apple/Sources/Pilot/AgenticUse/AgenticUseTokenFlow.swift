import AppKit

@MainActor
final class AgenticUseTokenFlowPanel: AgenticUseCardView {
    private let subtitle = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let diagram: AgenticUseTokenFlowDiagram
    private var graph: AgenticTokenFlowGraph
    init(snapshot: AgenticUseSnapshot) {
        graph = AgenticTokenFlowGraph.make(modelTotals: snapshot.modelTotals)
        diagram = AgenticUseTokenFlowDiagram(graph: graph, modelTotals: snapshot.modelTotals)
        super.init(title: "Token Flow")
        subtitle.textColor = .secondaryLabelColor
        addSubview(subtitle)
        scroll.documentView = diagram
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        addSubview(scroll)
        update(snapshot: snapshot)
    }
    required init?(coder: NSCoder) { nil }
    func update(snapshot: AgenticUseSnapshot) {
        graph = AgenticTokenFlowGraph.make(modelTotals: snapshot.modelTotals)
        subtitle.stringValue = "\(AgenticUseFormat.tokens(graph.totalTokens)) tokens by provider, model, and type"
        diagram.update(graph: graph, modelTotals: snapshot.modelTotals)
        needsLayout = true
    }
    static func height(for graph: AgenticTokenFlowGraph) -> CGFloat {
        max(300, CGFloat(graph.models.count) * 44, CGFloat(graph.providers.count) * 78, CGFloat(graph.tokenTypes.count) * 74)
    }
    override func preferredHeight(for width: CGFloat) -> CGFloat { (Self.height(for: graph) + 98) * AgenticUseLayout.zoom }
    override func layout() {
        super.layout()
        let z = AgenticUseLayout.zoom
        subtitle.font = AgenticUseLayout.font(.meta)
        subtitle.frame = NSRect(x: 16, y: 41 * z, width: max(1, bounds.width - 32), height: 19 * z)
        scroll.frame = NSRect(x: 16, y: 72 * z, width: max(1, bounds.width - 32), height: max(1, bounds.height - 82 * z))
        diagram.frame = NSRect(x: 0, y: 0, width: max(520 * z, scroll.contentSize.width), height: Self.height(for: graph) * z)
        diagram.needsLayout = true
    }
}

@MainActor
private final class AgenticUseTokenFlowDiagram: AgenticUseFlippedView {
    nonisolated static let providerHeight: CGFloat = 60
    nonisolated static let modelHeight: CGFloat = 30
    nonisolated static let typeHeight: CGFloat = 52
    typealias NodeID = AgenticTokenFlowGraph.NodeID
    private var graph: AgenticTokenFlowGraph
    private var modelTotals: [AgenticModelTotal]
    private var hovered: NodeID?
    private var selected: NodeID?
    private var nodes: [NodeID: AgenticUseFlowNode] = [:]
    private var geometry: Layout?
    private var geometrySize = NSSize.zero
    private var geometryZoom: CGFloat = 0
    private var highlighted: Set<String>?

    init(graph: AgenticTokenFlowGraph, modelTotals: [AgenticModelTotal]) {
        self.graph = graph
        self.modelTotals = modelTotals
        super.init(frame: .zero)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Token flow from provider through model to token type")
        update(graph: graph, modelTotals: modelTotals)
    }
    required init?(coder: NSCoder) { nil }
    func update(graph: AgenticTokenFlowGraph, modelTotals: [AgenticModelTotal]) {
        self.graph = graph
        self.modelTotals = modelTotals
        let all = graph.providers + graph.models + graph.tokenTypes
        let identifiers = Set(all.map(\.id))
        for id in Array(nodes.keys) where !identifiers.contains(id) { nodes.removeValue(forKey: id)?.removeFromSuperview() }
        if let selected, !identifiers.contains(selected) { self.selected = nil }
        if let hovered, !identifiers.contains(hovered) { self.hovered = nil }
        for node in all {
            let view = nodes[node.id] ?? AgenticUseFlowNode()
            view.configure(title: title(for: node.id), detail: detail(for: node), tint: color(for: node.id), compact: Self.isModel(node.id))
            view.toolTip = help(for: node)
            view.setAccessibilityLabel(help(for: node))
            view.onHover = { [weak self] inside in
                guard let self else { return }
                if inside { self.hovered = node.id } else if self.hovered == node.id { self.hovered = nil }
                self.updateHighlight()
            }
            view.onSelect = { [weak self] in
                guard let self else { return }
                self.selected = self.selected == node.id ? nil : node.id
                self.updateHighlight()
            }
            view.onClear = { [weak self] in self?.selected = nil; self?.hovered = nil; self?.updateHighlight() }
            if nodes[node.id] == nil { addSubview(view); nodes[node.id] = view }
        }
        geometry = nil
        updateHighlight()
        needsLayout = true
    }
    private static func isModel(_ id: NodeID) -> Bool {
        switch id { case .model, .otherModels: true; default: false }
    }
    private func title(for id: NodeID) -> String {
        switch id {
        case .provider(let provider): provider.displayName
        case .model(let name): modelTotals.first { $0.model == name }?.displayName ?? name
        case .otherModels: "Other Models"
        case .tokenType(let type): type.title
        }
    }
    private func detail(for node: AgenticTokenFlowGraph.Node) -> String {
        let count = AgenticUseFormat.tokens(node.tokens)
        switch node.id {
        case .provider: return "\(count) tokens · \(node.cost > 0 ? AgenticUseFormat.cost(node.cost) : "—")"
        case .model, .otherModels: return count
        case .tokenType:
            let share = graph.totalTokens > 0 ? Double(node.tokens) / Double(graph.totalTokens) : 0
            return "\(count) (\(AgenticUseFormat.percent(share)))"
        }
    }
    private func help(for node: AgenticTokenFlowGraph.Node) -> String {
        var help = "\(title(for: node.id)): \(node.tokens) tokens"
        if case .model(let name) = node.id, let total = modelTotals.first(where: { $0.model == name }) {
            help += total.isUnpriced ? " (unpriced)" : " · \(AgenticUseFormat.cost(total.cost))"
        }
        if node.id == .otherModels { help += ": " + graph.otherModelNames.joined(separator: ", ") }
        return help + ". Activate to highlight connected flows. Escape clears selection."
    }
    private func color(for id: NodeID) -> NSColor {
        switch id {
        case .provider(let provider): AgenticUseModelPalette.providerColor(for: provider)
        case .model(let name): modelTotals.first { $0.model == name }.map { AgenticUseModelPalette.providerColor(for: $0.provider) } ?? .systemGray
        case .otherModels: .systemGray
        case .tokenType(let type): Self.tint(for: type)
        }
    }
    static func tint(for type: AgenticTokenFlowGraph.TokenType) -> NSColor {
        switch type {
        case .input: .systemCyan
        case .cacheWrite: .systemIndigo
        case .cacheRead: .systemPurple
        case .output: .systemMint
        }
    }
    private func updateHighlight() {
        if let id = hovered ?? selected {
            let direct = graph.links.filter { $0.source == id || $0.target == id }
            var ids = Set(direct.map(\.id))
            let neighbors = Set(direct.flatMap { [$0.source, $0.target] }).subtracting([id])
            switch id {
            case .provider:
                for link in graph.links where neighbors.contains(link.source) { ids.insert(link.id) }
            case .tokenType:
                for link in graph.links where neighbors.contains(link.target) { ids.insert(link.id) }
            case .model, .otherModels: break
            }
            highlighted = ids
        } else { highlighted = nil }
        let connected = Set(graph.links.filter { highlighted?.contains($0.id) ?? true }.flatMap { [$0.source, $0.target] })
        for (id, node) in nodes {
            node.alphaValue = highlighted == nil || connected.contains(id) || id == hovered || id == selected ? 1 : 0.45
            node.state = id == selected ? .on : .off
        }
        needsDisplay = true
    }
    override func layout() {
        super.layout()
        if geometry == nil || geometrySize != bounds.size || geometryZoom != AgenticUseLayout.zoom {
            geometry = Layout(graph: graph, size: bounds.size)
            geometrySize = bounds.size
            geometryZoom = AgenticUseLayout.zoom
        }
        for frame in geometry?.frames ?? [] { nodes[frame.id]?.frame = frame.rect; nodes[frame.id]?.needsDisplay = true }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        if graph.links.isEmpty {
            let text = "No token flow" as NSString
            text.draw(at: NSPoint(x: 20, y: 40), withAttributes: [.font: AgenticUseLayout.font(.body), .foregroundColor: NSColor.secondaryLabelColor])
            return
        }
        for ribbon in geometry?.ribbons ?? [] {
            let alpha: CGFloat = highlighted.map { $0.contains(ribbon.link.id) ? 0.78 : 0.07 } ?? 0.4
            let from = color(for: ribbon.link.source).withAlphaComponent(alpha)
            let to = color(for: ribbon.link.target).withAlphaComponent(alpha)
            NSGraphicsContext.saveGraphicsState()
            ribbon.path.addClip()
            let gradient = NSGradient(colorsAndLocations: (from, 0), (from, 0.45), (to, 1))
            gradient?.draw(from: NSPoint(x: ribbon.startX, y: 0), to: NSPoint(x: ribbon.endX, y: 0), options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    struct NodeFrame {
        let id: NodeID
        let rect: CGRect
    }

    struct Ribbon {
        let link: AgenticTokenFlowGraph.Link
        let path: NSBezierPath
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

        @MainActor init(graph: AgenticTokenFlowGraph, size: CGSize) {
            let zoom = AgenticUseLayout.zoom
            let width = max(size.width, 520 * zoom)
            let nodeWidth = min(180 * zoom, max(118 * zoom, (width - 112 * zoom) / 3))
            let columns: [(nodes: [AgenticTokenFlowGraph.Node], x: CGFloat, height: CGFloat)] = [
                (graph.providers, 0, AgenticUseTokenFlowDiagram.providerHeight * zoom),
                (graph.models, (width - nodeWidth) / 2, AgenticUseTokenFlowDiagram.modelHeight * zoom),
                (graph.tokenTypes, width - nodeWidth, AgenticUseTokenFlowDiagram.typeHeight * zoom),
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
                let inset: CGFloat = 5 * zoom
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
                let path = NSBezierPath()
                path.move(to: CGPoint(x: x0, y: start.0))
                path.curve(
                    to: CGPoint(x: x1, y: end.0),
                    controlPoint1: CGPoint(x: mid, y: start.0),
                    controlPoint2: CGPoint(x: mid, y: end.0)
                )
                path.line(to: CGPoint(x: x1, y: end.1))
                path.curve(
                    to: CGPoint(x: x0, y: start.1),
                    controlPoint1: CGPoint(x: mid, y: end.1),
                    controlPoint2: CGPoint(x: mid, y: start.1)
                )
                path.close()
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

@MainActor
private final class AgenticUseFlowNode: NSButton {
    var onHover: ((Bool) -> Void)?
    var onSelect: (() -> Void)?
    var onClear: (() -> Void)?
    private var detail = ""
    private var tint = NSColor.systemGray
    private var compact = false
    private var tracking: NSTrackingArea?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setButtonType(.pushOnPushOff)
        isBordered = false
        target = self
        action = #selector(selectNode)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    func configure(title: String, detail: String, tint: NSColor, compact: Bool) {
        self.title = title
        self.detail = detail
        self.tint = tint
        self.compact = compact
        needsDisplay = true
    }
    @objc private func selectNode() { onSelect?() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking)
        self.tracking = tracking
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClear?() } else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        let z = AgenticUseLayout.zoom
        let path = NSBezierPath(roundedRect: bounds, xRadius: 12 * z, yRadius: 12 * z)
        NSColor.windowBackgroundColor.setFill(); path.fill()
        tint.withAlphaComponent(state == .on ? 0.28 : 0.16).setFill(); path.fill()
        if window?.firstResponder === self { NSColor.keyboardFocusIndicatorColor.setStroke(); path.lineWidth = 2; path.stroke() }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        let titleFont = AgenticUseLayout.font(compact ? .meta : .body, weight: .semibold)
        let textHeight = titleFont.ascender - titleFont.descender + 3
        let titleRect = NSRect(x: 10 * z, y: compact ? (bounds.height - textHeight) / 2 : 8 * z, width: max(1, bounds.width - (compact ? 62 : 20) * z), height: textHeight)
        (title as NSString).draw(in: titleRect, withAttributes: [.font: titleFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
        style.alignment = compact ? .right : .left
        let detailRect = compact ? NSRect(x: bounds.width - 54 * z, y: (bounds.height - textHeight) / 2, width: 44 * z, height: textHeight) : NSRect(x: 10 * z, y: 29 * z, width: max(1, bounds.width - 20 * z), height: 24 * z)
        (detail as NSString).draw(in: detailRect, withAttributes: [.font: AgenticUseLayout.font(.caption), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style])
    }
}
