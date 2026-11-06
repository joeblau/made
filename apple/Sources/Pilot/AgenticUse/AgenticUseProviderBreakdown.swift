import AppKit

@MainActor
final class AgenticUseProviderBreakdown: AgenticUseCardView {
    struct Entry: Equatable {
        let provider: AgenticProvider
        let share: Double
        let cost: Double
        let tokens: Int
    }
    private var snapshot: AgenticUseSnapshot
    private var entries: [Entry] = []
    private var displayedEntries: [Entry] = []
    private let transition = AgenticUseDataTransition()
    private let layoutTransition = AgenticUseDataTransition()
    private var pendingLayoutTransition = false
    private var previousLayoutWidth: CGFloat = 0
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
        pendingLayoutTransition = window?.isVisible == true
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
        let previousButtons = Dictionary(uniqueKeysWithValues: zip(buttons.map(\.provider), buttons))
        buttons = entries.map { entry in
            let value = usesCost ? AgenticUseFormat.cost(entry.cost) : AgenticUseFormat.tokens(entry.tokens) + " tokens"
            let button = previousButtons[entry.provider] ?? AgenticUseProviderButton(provider: entry.provider)
            button.title = "\(AgenticUseFormat.percent(entry.share)) \(entry.provider.displayName)\n\(value)"
            button.contentTintColor = .labelColor
            button.setAccessibilityLabel("\(entry.provider.displayName), \(AgenticUseFormat.percent(entry.share)), \(value). Show models")
            button.handler = { [weak self, weak button] in
                guard let self, let button else { return }
                self.showModels(for: entry.provider, relativeTo: button)
            }
            if button.superview == nil { addSubview(button) }
            return button
        }
        let providers = Set(entries.map(\.provider))
        for (provider, button) in previousButtons where !providers.contains(provider) { button.removeFromSuperview() }
        let from = Dictionary(uniqueKeysWithValues: displayedEntries.map { ($0.provider, $0) })
        let target = entries
        bar.update(entries: target)
        transition.start(in: self, animated: displayedEntries != target) { [weak self] progress in
            guard let self else { return }
            self.displayedEntries = target.map { entry in
                let old = from[entry.provider]
                return Entry(provider: entry.provider,
                    share: AgenticUseDataTransition.mix(old?.share ?? 0, entry.share, progress),
                    cost: AgenticUseDataTransition.mix(old?.cost ?? 0, entry.cost, progress),
                    tokens: Int(AgenticUseDataTransition.mix(Double(old?.tokens ?? 0), Double(entry.tokens), progress)))
            }
            for (entry, button) in zip(self.displayedEntries, self.buttons) {
                let value = usesCost ? AgenticUseFormat.cost(entry.cost) : AgenticUseFormat.tokens(entry.tokens) + " tokens"
                button.title = "\(AgenticUseFormat.percent(entry.share)) \(entry.provider.displayName)\n\(value)"
            }
        }
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
        if layoutTransition.isRunning && !pendingLayoutTransition && previousLayoutWidth == bounds.width { return }
        let animate = pendingLayoutTransition
        pendingLayoutTransition = false
        previousLayoutWidth = bounds.width
        let from = buttons.map(\.frame)
        let columns = columns(for: bounds.width)
        let width = max(1, (bounds.width - 32) / CGFloat(columns))
        for (index, button) in buttons.enumerated() {
            button.font = AgenticUseLayout.font(.body, weight: .medium)
            button.frame = NSRect(x: 16 + CGFloat(index % columns) * width, y: 88 * z + CGFloat(index / columns) * 54 * z, width: width - 4, height: 48 * z)
        }
        let targets = buttons.map(\.frame)
        layoutTransition.start(in: self, animated: animate) { [weak self] progress in
            guard let self else { return }
            for (index, button) in self.buttons.enumerated() where from.indices.contains(index) {
                let old = from[index].isEmpty ? targets[index] : from[index]
                button.frame = AgenticUseDataTransition.frame(old, targets[index], progress)
            }
        }
    }
    private func showModels(for provider: AgenticProvider, relativeTo button: NSView) {
        guard button.window != nil else { return }
        let models = snapshot.modelTotals.filter { $0.provider == provider }
        guard !models.isEmpty else { return }
        popover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let screen = button.window?.screen?.visibleFrame.size ?? NSSize(width: 1024, height: 768)
        popover.contentViewController = AgenticUseProviderModelsController(
            provider: provider, models: models,
            maximumSize: NSSize(width: max(280, screen.width - 80), height: max(180, screen.height - 120)))
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
    let provider: AgenticProvider
    var handler: (() -> Void)?
    private var tracking: NSTrackingArea?
    init(provider: AgenticProvider) {
        self.provider = provider
        super.init(frame: .zero)
        isBordered = false
        image = AgenticUseModelPalette.providerMarker(for: provider)
        imagePosition = .imageLeading
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
    override func mouseExited(with event: NSEvent) { highlight(false) }
}

@MainActor
private final class AgenticUseProviderBar: NSView {
    private struct Segment: Equatable {
        let provider: AgenticProvider
        let start: Double
        let share: Double
    }
    private var segments: [Segment] = []
    private let transition = AgenticUseDataTransition()
    func update(entries: [AgenticUseProviderBreakdown.Entry]) {
        var position = 0.0
        let target = entries.map { entry in
            defer { position += entry.share }
            return Segment(provider: entry.provider, start: position, share: entry.share)
        }
        let from = Dictionary(uniqueKeysWithValues: segments.map { ($0.provider, $0) })
        let to = Dictionary(uniqueKeysWithValues: target.map { ($0.provider, $0) })
        let order = target.map(\.provider) + segments.map(\.provider).filter { to[$0] == nil }
        transition.start(in: self, animated: segments != target) { [weak self] progress in
            guard let self else { return }
            self.segments = progress == 1 ? target : order.map { provider in
                Segment(provider: provider,
                    start: AgenticUseDataTransition.mix(from[provider]?.start ?? to[provider]?.start ?? 0,
                                                       to[provider]?.start ?? from[provider]?.start ?? 0, progress),
                    share: AgenticUseDataTransition.mix(from[provider]?.share ?? 0, to[provider]?.share ?? 0, progress))
            }
            self.needsDisplay = true
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).addClip()
        NSColor.quaternaryLabelColor.setFill()
        bounds.fill()
        for segment in segments where segment.share > 0 {
            AgenticUseModelPalette.providerColor(for: segment.provider).setFill()
            NSRect(x: bounds.width * segment.start, y: 0, width: max(0, bounds.width * segment.share - 1), height: bounds.height).fill()
        }
    }
}

@MainActor
final class AgenticUseProviderModelsController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let provider: AgenticProvider
    private let models: [AgenticModelTotal]
    private let maximumSize: NSSize
    private let table = NSTableView()
    private let pageLabel = NSTextField(labelWithString: "")
    private let previous = NSButton()
    private let next = NSButton()
    private var page = 0
    private var rowsPerPage = 1
    private var pageCount: Int { max(1, Int(ceil(Double(models.count) / Double(rowsPerPage)))) }

    init(provider: AgenticProvider, models: [AgenticModelTotal], maximumSize: NSSize = NSSize(width: 800, height: 600)) {
        self.provider = provider
        self.models = models
        self.maximumSize = maximumSize
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        let z = AgenticUseLayout.zoom
        rowsPerPage = max(1, min(18, Int((maximumSize.height / z - 94) / 28)))
        let rowCount = min(rowsPerPage, models.count)
        let footerHeight: CGFloat = pageCount > 1 ? 40 : 0
        view = AgenticUseFlippedView(frame: NSRect(
            x: 0, y: 0, width: min(maximumSize.width, 440 * z), height: (54 + CGFloat(rowCount) * 28 + footerHeight) * z))
        let heading = AgenticUseLayout.label(provider.displayName, style: .title)
        heading.frame = NSRect(x: 14, y: 12 * z, width: view.bounds.width - 28, height: 24 * z)
        view.addSubview(heading)
        table.style = .plain
        table.intercellSpacing = .zero
        let column = NSTableColumn(identifier: .init("model"))
        column.width = view.bounds.width - 24
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 28 * z
        table.selectionHighlightStyle = .none
        table.backgroundColor = .clear
        table.setAccessibilityLabel("\(provider.displayName) models, estimated cost, and tokens")
        // A fitted table has no nested scrolling or reserved scroller gutter.
        table.frame = NSRect(x: 12, y: 42 * z, width: view.bounds.width - 24, height: CGFloat(rowCount) * table.rowHeight)
        view.addSubview(table)
        if pageCount > 1 {
            let y = table.frame.maxY + 8 * z
            for (button, symbol, label, action) in [
                (previous, "chevron.left", "Previous models", #selector(previousPage)),
                (next, "chevron.right", "Next models", #selector(nextPage))
            ] {
                button.bezelStyle = .rounded
                button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
                button.setAccessibilityLabel(label)
                button.toolTip = label
                button.target = self
                button.action = action
                view.addSubview(button)
            }
            previous.frame = NSRect(x: 12, y: y, width: 28 * z, height: 28 * z)
            next.frame = NSRect(x: view.bounds.width - 12 - 28 * z, y: y, width: 28 * z, height: 28 * z)
            pageLabel.font = AgenticUseLayout.font(.meta)
            pageLabel.alignment = .center
            pageLabel.frame = NSRect(x: previous.frame.maxX + 8, y: y + 4 * z,
                                     width: max(0, next.frame.minX - previous.frame.maxX - 16), height: 20 * z)
            view.addSubview(pageLabel)
        }
        updatePage()
    }
    private func updatePage() {
        table.reloadData()
        previous.isEnabled = page > 0
        next.isEnabled = page + 1 < pageCount
        pageLabel.stringValue = "\(page + 1) of \(pageCount)"
    }
    @objc private func previousPage() { guard page > 0 else { return }; page -= 1; updatePage() }
    @objc private func nextPage() { guard page + 1 < pageCount else { return }; page += 1; updatePage() }
    func numberOfRows(in tableView: NSTableView) -> Int { min(rowsPerPage, max(0, models.count - page * rowsPerPage)) }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("providerModel")
        let cell = (table.makeView(withIdentifier: id, owner: self) as? AgenticUseProviderModelRow) ?? AgenticUseProviderModelRow()
        cell.identifier = id
        cell.configure(models[page * rowsPerPage + row])
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
        name.textColor = .labelColor
        toolTip = "\(model.displayName): \(model.isUnpriced ? "unpriced" : AgenticUseFormat.cost(model.cost)), \(model.tokens) tokens"
        setAccessibilityLabel(toolTip)
    }
    override func layout() {
        super.layout()
        let valueWidth = min(bounds.width * 0.65, ceil((value.stringValue as NSString).size(
            withAttributes: [.font: value.font ?? AgenticUseLayout.font(.meta)]).width) + 8)
        name.frame = NSRect(x: 2, y: 2, width: max(1, bounds.width - valueWidth - 8), height: bounds.height - 4)
        value.frame = NSRect(x: bounds.width - valueWidth, y: 2, width: valueWidth - 2, height: bounds.height - 4)
    }
}
