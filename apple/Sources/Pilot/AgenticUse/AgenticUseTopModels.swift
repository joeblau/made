import AppKit

/// Native, reusable model rows. Expanding preserves every model while bounding
/// the number of rendered cells; the native table supplies keyboard navigation.
@MainActor
final class AgenticUseTopModels: AgenticUseCardView, NSTableViewDataSource, NSTableViewDelegate {
    var onHeightChange: (() -> Void)?
    private var snapshot: AgenticUseSnapshot
    private var showsAll = false
    private var visible: [AgenticModelTotal] = []
    private var trends: [String: [Double]] = [:]
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private let toggle = NSButton()
    private static let collapsedCount = 10

    init(snapshot: AgenticUseSnapshot) {
        self.snapshot = snapshot
        super.init(title: "Top Models")
        toggle.bezelStyle = .rounded
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(toggleModels)
        addSubview(toggle)
        let specs: [(String, String, CGFloat)] = [("rank", "#", 26), ("model", "Model", 170), ("provider", "Provider", 75), ("cost", "Cost", 68), ("tokens", "Tokens", 70), ("rate", "$/1M", 65), ("trend", "Trend", 100)]
        for (id, title, width) in specs {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            column.minWidth = id == "model" ? 100 : width * 0.8
            column.resizingMask = .userResizingMask
            table.addTableColumn(column)
        }
        table.delegate = self
        table.dataSource = self
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = false
        table.setAccessibilityLabel("Models ranked by estimated cost")
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        addSubview(scroll)
        update(snapshot: snapshot)
    }
    required init?(coder: NSCoder) { nil }
    func update(snapshot: AgenticUseSnapshot) {
        self.snapshot = snapshot
        trends = snapshot.tokenTrends
        reloadRows()
    }
    private func reloadRows() {
        let selectedID = visible.indices.contains(table.selectedRow) ? visible[table.selectedRow].model : nil
        visible = showsAll ? snapshot.modelTotals : Array(snapshot.modelTotals.prefix(Self.collapsedCount))
        table.tableColumn(withIdentifier: .init("trend"))?.title = snapshot.range == .day ? "24h Trend" : "\(snapshot.range.label) Trend"
        toggle.isHidden = snapshot.modelTotals.count <= Self.collapsedCount
        toggle.title = showsAll ? "Show Top \(Self.collapsedCount)" : "View All \(snapshot.modelTotals.count) Models"
        table.reloadData()
        if let selectedID, let row = visible.firstIndex(where: { $0.model == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        needsLayout = true
    }
    @objc private func toggleModels() {
        showsAll.toggle()
        reloadRows()
        onHeightChange?()
    }
    override func preferredHeight(for width: CGFloat) -> CGFloat {
        let header: CGFloat = width < 440 * AgenticUseLayout.zoom ? 86 : 54
        return (header + 26 + CGFloat(min(visible.count, 18)) * 32 + 20) * AgenticUseLayout.zoom
    }
    override func layout() {
        super.layout()
        let z = AgenticUseLayout.zoom
        let compact = bounds.width < 440 * z
        toggle.font = AgenticUseLayout.font(.meta)
        toggle.sizeToFit()
        toggle.frame.origin = NSPoint(x: max(16, bounds.width - toggle.frame.width - 16), y: compact ? 43 * z : 12 * z)
        titleLabel.frame.size.width = compact ? max(0, bounds.width - 32) : max(0, toggle.frame.minX - 24)
        let top: CGFloat = (compact ? 80 : 48) * z
        scroll.frame = NSRect(x: 12, y: top, width: max(1, bounds.width - 24), height: max(1, bounds.height - top - 12))
        table.rowHeight = 32 * z
        table.headerView?.frame.size.height = 24 * z
        let widths: [CGFloat] = scroll.contentSize.width < 650 * z
            ? [22, 140, 66, 62, 62, 58, 75] : [26, 170, 75, 68, 70, 65, 100]
        for (column, width) in zip(table.tableColumns, widths) {
            column.width = width * z
            column.headerCell.font = AgenticUseLayout.font(.meta, weight: .medium)
        }
        if let model = table.tableColumn(withIdentifier: .init("model")) {
            let otherWidth = widths.enumerated().filter { $0.offset != 1 }.reduce(CGFloat(0)) { $0 + $1.element }
            model.width = max(widths[1] * z, scroll.contentSize.width - (otherWidth * z + 56))
        }
        table.enumerateAvailableRowViews { _, row in
            for column in 0..<self.table.numberOfColumns {
                if let view = self.table.view(atColumn: column, row: row, makeIfNecessary: false) {
                    self.configure(view, row: row, column: self.table.tableColumns[column].identifier.rawValue)
                }
            }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        let id = tableColumn.identifier
        let cell: NSView
        if let reused = table.makeView(withIdentifier: id, owner: self) {
            cell = reused
        } else if id.rawValue == "trend" {
            cell = AgenticUseSparkline(values: [], tint: .controlAccentColor, lineWidth: 1.25)
        } else {
            cell = AgenticUseModelTextCell()
        }
        cell.identifier = id
        configure(cell, row: row, column: id.rawValue)
        return cell
    }
    private func configure(_ view: NSView, row: Int, column: String) {
        guard visible.indices.contains(row) else { return }
        let model = visible[row]
        let tint = AgenticUseModelPalette.providerColor(for: model.provider)
        if let sparkline = view as? AgenticUseSparkline {
            sparkline.update(values: trends[model.model] ?? [], tint: tint)
            sparkline.toolTip = "Tokens per \(snapshot.range.bucketUnit == .hour ? "hour" : "day"): " + (trends[model.model] ?? []).map { String(Int($0)) }.joined(separator: ", ")
            return
        }
        guard let cell = view as? AgenticUseModelTextCell else { return }
        cell.label.font = AgenticUseLayout.font(.body, weight: column == "model" ? .medium : .regular)
        cell.label.textColor = column == "provider" ? tint : .labelColor
        cell.label.alignment = ["cost", "tokens", "rate"].contains(column) ? .right : .left
        cell.label.lineBreakMode = column == "model" ? .byTruncatingMiddle : .byTruncatingTail
        switch column {
        case "rank": cell.label.stringValue = "\(row + 1)"
        case "model": cell.label.stringValue = model.displayName + (model.isUnpriced ? " · unpriced" : "")
        case "provider": cell.label.stringValue = model.provider.displayName
        case "cost": cell.label.stringValue = model.isUnpriced ? "—" : AgenticUseFormat.cost(model.cost)
        case "tokens": cell.label.stringValue = AgenticUseFormat.tokens(model.tokens)
        case "rate": cell.label.stringValue = model.costPerMillionTokens.map(AgenticUseFormat.cost) ?? "—"
        default: break
        }
        cell.toolTip = column == "rate" ? "Effective cost per million processed tokens, cache reads included" : model.model
        cell.setAccessibilityLabel(cell.label.stringValue)
    }
}

@MainActor
private final class AgenticUseModelTextCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(label)
        textField = label
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        label.frame = NSRect(x: 2, y: (bounds.height - 20 * AgenticUseLayout.zoom) / 2, width: max(0, bounds.width - 4), height: 20 * AgenticUseLayout.zoom)
    }
}
