import AppKit

@MainActor
final class AgenticUseProviderBreakdown: AgenticUseCardView {
    struct Entry {
        let provider: AgenticProvider
        let share: Double
        let cost: Double
        let tokens: Int
    }
    private var snapshot: AgenticUseSnapshot
    private var entries: [Entry] = []
    private var buttons: [AgenticUseProviderButton] = []
    private let subtitle = NSTextField(labelWithString: "")
    private let bar = AgenticUseProviderBar()
    private var popover: NSPopover?

    init(snapshot: AgenticUseSnapshot) {
        self.snapshot = snapshot
        super.init(title: "Provider Breakdown")
        subtitle.textColor = .secondaryLabelColor
        addSubview(subtitle)
        addSubview(bar)
        update(snapshot: snapshot)
    }
    required init?(coder: NSCoder) { nil }
    func update(snapshot: AgenticUseSnapshot) {
        self.snapshot = snapshot
        popover?.close()
        let usesCost = snapshot.totalCostUSD > 0
        let totalTokens = snapshot.providerTotals.reduce(0) { $0 + $1.totalTokens }
        entries = snapshot.providerTotals.map { total in
            Entry(provider: total.provider,
                  share: usesCost ? total.estimatedCost / snapshot.totalCostUSD : (totalTokens > 0 ? Double(total.totalTokens) / Double(totalTokens) : 0),
                  cost: total.estimatedCost, tokens: total.totalTokens)
        }.sorted { $0.share == $1.share ? $0.tokens > $1.tokens : $0.share > $1.share }
        subtitle.stringValue = usesCost ? "Share of estimated cost" : "Share of tokens (no priced usage)"
        buttons.forEach { $0.removeFromSuperview() }
        buttons = entries.map { entry in
            let value = usesCost ? AgenticUseFormat.cost(entry.cost) : AgenticUseFormat.tokens(entry.tokens) + " tokens"
            let button = AgenticUseProviderButton()
            button.title = "\(AgenticUseFormat.percent(entry.share)) \(entry.provider.displayName)\n\(value)"
            button.contentTintColor = AgenticUseModelPalette.providerColor(for: entry.provider)
            button.setAccessibilityLabel("\(entry.provider.displayName), \(AgenticUseFormat.percent(entry.share)), \(value). Show models")
            button.handler = { [weak self, weak button] in
                guard let self, let button else { return }
                self.showModels(for: entry.provider, relativeTo: button)
            }
            button.onExit = { [weak self] in self?.popover?.close() }
            addSubview(button)
            return button
        }
        bar.entries = entries
        bar.needsDisplay = true
        needsLayout = true
    }
    private func columns(for width: CGFloat) -> Int { max(1, Int(max(0, width - 32) / (130 * AgenticUseLayout.zoom))) }
    override func preferredHeight(for width: CGFloat) -> CGFloat {
        let rows = ceil(Double(entries.count) / Double(columns(for: width)))
        return (94 + CGFloat(rows) * 54) * AgenticUseLayout.zoom
    }
    override func layout() {
        super.layout()
        let z = AgenticUseLayout.zoom
        subtitle.font = AgenticUseLayout.font(.meta)
        subtitle.frame = NSRect(x: 16, y: 40 * z, width: max(1, bounds.width - 32), height: 18 * z)
        bar.frame = NSRect(x: 16, y: 67 * z, width: max(1, bounds.width - 32), height: 12 * z)
        let columns = columns(for: bounds.width)
        let width = max(1, (bounds.width - 32) / CGFloat(columns))
        for (index, button) in buttons.enumerated() {
            button.font = AgenticUseLayout.font(.body, weight: .medium)
            button.frame = NSRect(x: 16 + CGFloat(index % columns) * width, y: 88 * z + CGFloat(index / columns) * 54 * z, width: width - 4, height: 48 * z)
        }
    }
    private func showModels(for provider: AgenticProvider, relativeTo button: NSView) {
        guard button.window != nil else { return }
        let models = snapshot.modelTotals.filter { $0.provider == provider }
        guard !models.isEmpty else { return }
        popover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = AgenticUseProviderModelsController(provider: provider, models: models)
        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { popover?.close() }
        super.viewWillMove(toWindow: newWindow)
    }
}

@MainActor
private final class AgenticUseProviderButton: NSButton {
    var handler: (() -> Void)?
    var onExit: (() -> Void)?
    private var tracking: NSTrackingArea?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        alignment = .left
        cell?.wraps = true
        target = self
        action = #selector(invoke)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func invoke() { handler?() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking)
        self.tracking = tracking
    }
    override func mouseEntered(with event: NSEvent) { highlight(true); handler?() }
    override func mouseExited(with event: NSEvent) { highlight(false); onExit?() }
}

@MainActor
private final class AgenticUseProviderBar: NSView {
    var entries: [AgenticUseProviderBreakdown.Entry] = []
    override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).addClip()
        NSColor.quaternaryLabelColor.setFill()
        bounds.fill()
        let visible = entries.filter { $0.share > 0 }
        let width = max(0, bounds.width - CGFloat(max(0, visible.count - 1)) * 2)
        var x: CGFloat = 0
        for entry in visible {
            let segment = max(0, width * entry.share)
            AgenticUseModelPalette.providerColor(for: entry.provider).setFill()
            NSRect(x: x, y: 0, width: segment, height: bounds.height).fill()
            x += segment + 2
        }
    }
}

@MainActor
private final class AgenticUseProviderModelsController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let provider: AgenticProvider
    private let models: [AgenticModelTotal]
    private let table = NSTableView()
    init(provider: AgenticProvider, models: [AgenticModelTotal]) {
        self.provider = provider
        self.models = models
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        let z = AgenticUseLayout.zoom
        view = AgenticUseFlippedView(frame: NSRect(x: 0, y: 0, width: 440 * z, height: (58 + CGFloat(min(18, models.count)) * 28) * z))
        let heading = AgenticUseLayout.label(provider.displayName, style: .title)
        heading.frame = NSRect(x: 14, y: 12, width: view.bounds.width - 28, height: 24 * z)
        view.addSubview(heading)
        let column = NSTableColumn(identifier: .init("model"))
        column.width = view.bounds.width - 30
        table.addTableColumn(column)
        table.headerView = nil
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 28 * z
        table.backgroundColor = .clear
        table.setAccessibilityLabel("\(provider.displayName) models, estimated cost, and tokens")
        let scroll = NSScrollView(frame: NSRect(x: 12, y: 42 * z, width: view.bounds.width - 24, height: view.bounds.height - 50 * z))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        view.addSubview(scroll)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { models.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("providerModel")
        let cell = (table.makeView(withIdentifier: id, owner: self) as? AgenticUseProviderModelRow) ?? AgenticUseProviderModelRow()
        cell.identifier = id
        cell.configure(models[row])
        return cell
    }
}

@MainActor
private final class AgenticUseProviderModelRow: NSTableCellView {
    private let name = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(name); addSubview(value)
        textField = name
        value.alignment = .right
    }
    required init?(coder: NSCoder) { nil }
    func configure(_ model: AgenticModelTotal) {
        name.stringValue = model.displayName + (model.isUnpriced ? " · unpriced" : "")
        value.stringValue = "\(model.isUnpriced ? "—" : AgenticUseFormat.cost(model.cost))    \(AgenticUseFormat.tokens(model.tokens))"
        name.font = AgenticUseLayout.font(.meta, weight: .medium)
        value.font = AgenticUseLayout.font(.meta)
        name.lineBreakMode = .byTruncatingMiddle
        name.textColor = AgenticUseModelPalette.color(for: model.model)
        toolTip = "\(model.displayName): \(model.isUnpriced ? "unpriced" : AgenticUseFormat.cost(model.cost)), \(model.tokens) tokens"
        setAccessibilityLabel(toolTip)
    }
    override func layout() {
        super.layout()
        let valueWidth = 135 * AgenticUseLayout.zoom
        name.frame = NSRect(x: 2, y: 2, width: max(1, bounds.width - valueWidth - 8), height: bounds.height - 4)
        value.frame = NSRect(x: bounds.width - valueWidth, y: 2, width: valueWidth - 2, height: bounds.height - 4)
    }
}
