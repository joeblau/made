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
    private static let compactWidths: [CGFloat] = [22, 140, 66, 62, 62, 58, 75]
    private var laidOutZoom: CGFloat?

    private var verticalScrollerAllowance: CGFloat {
        scroll.scrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }
    var minimumCardWidth: CGFloat {
        return Self.compactWidths.reduce(0, +) * AgenticUseLayout.zoom
            + CGFloat(table.numberOfColumns) * table.intercellSpacing.width + 24 + verticalScrollerAllowance
    }

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
        table.style = .plain
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
        var order = visible.map(\.model)
        visible = showsAll ? snapshot.modelTotals : Array(snapshot.modelTotals.prefix(Self.collapsedCount))
        table.tableColumn(withIdentifier: .init("trend"))?.title = snapshot.range == .day ? "24h Trend" : "\(snapshot.range.label) Trend"
        toggle.isHidden = snapshot.modelTotals.count <= Self.collapsedCount
        toggle.title = showsAll ? "Show Top \(Self.collapsedCount)" : "View All \(snapshot.modelTotals.count) Models"
        let next = visible.map(\.model)
        let animation: NSTableView.AnimationOptions = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? [] : .effectFade
        table.beginUpdates()
        let removed = IndexSet(order.indices.filter { !next.contains(order[$0]) })
        table.removeRows(at: removed, withAnimation: animation)
        for index in removed.reversed() { order.remove(at: index) }
        for (index, id) in next.enumerated() {
            if let previous = order.firstIndex(of: id) {
                if previous != index {
                    table.moveRow(at: previous, to: index)
                    order.insert(order.remove(at: previous), at: index)
                }
            } else {
                order.insert(id, at: index)
                table.insertRows(at: IndexSet(integer: index), withAnimation: animation)
            }
        }
        table.endUpdates()
        for row in visible.indices {
            for (column, spec) in table.tableColumns.enumerated() {
                if let cell = table.view(atColumn: column, row: row, makeIfNecessary: false) {
                    configure(cell, row: row, column: spec.identifier.rawValue)
                }
            }
        }
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
        let typographyChanged = laidOutZoom != z
        laidOutZoom = z
        if table.rowHeight != 32 * z { table.rowHeight = 32 * z }
        table.headerView?.frame.size.height = 24 * z
        // Reserve the legacy gutter before AppKit tiles the scroll view. Its
        // scrollers can appear after columns change, otherwise feeding a
        // horizontal/vertical scrollbar feedback loop at narrow widths.
        let availableWidth = min(scroll.contentSize.width, scroll.bounds.width - verticalScrollerAllowance)
        let widths: [CGFloat] = availableWidth < 650 * z
            ? Self.compactWidths : [26, 170, 75, 68, 70, 65, 100]
        let otherWidth = widths.enumerated().filter { $0.offset != 1 }.reduce(CGFloat(0)) { $0 + $1.element }
        for (index, column) in table.tableColumns.enumerated() {
            if typographyChanged {
                column.minWidth = Self.compactWidths[index] * z * 0.8
                column.headerCell.font = AgenticUseLayout.font(.meta, weight: .medium)
            }
            let width = index == 1
                ? max(widths[1] * z, availableWidth - (otherWidth * z + 56)) : widths[index] * z
            if column.width != width { column.width = width }
        }
        // Resizing only changes geometry. Formatting values and rebuilding
        // trend data belongs to snapshot updates and newly visible cells.
        guard typographyChanged else { return }
        table.enumerateAvailableRowViews { _, row in
            for column in 0..<self.table.numberOfColumns {
                if let cell = self.table.view(atColumn: column, row: row, makeIfNecessary: false) as? AgenticUseModelTextCell {
                    cell.label.font = AgenticUseLayout.font(.body, weight: column == 1 ? .medium : .regular)
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
        cell.label.textColor = .labelColor
        cell.marker.isHidden = column != "provider"
        cell.marker.contentTintColor = tint
        cell.label.alignment = ["cost", "tokens", "rate"].contains(column) ? .right : .left
        cell.label.lineBreakMode = column == "model" ? .byTruncatingMiddle : .byTruncatingTail
        switch column {
        case "rank": cell.label.stringValue = "\(row + 1)"
        case "model": cell.label.stringValue = model.displayName + (model.isUnpriced ? " · unpriced" : "")
        case "provider": cell.label.stringValue = model.provider.displayName
        case "cost": cell.setNumber(model.isUnpriced ? nil : model.cost, identity: model.model, format: AgenticUseFormat.cost)
        case "tokens": cell.setNumber(Double(model.tokens), identity: model.model, format: AgenticUseFormat.tokens)
        case "rate": cell.setNumber(model.costPerMillionTokens, identity: model.model, format: AgenticUseFormat.cost)
        default: break
        }
        cell.toolTip = column == "rate" ? "Effective cost per million processed tokens, cache reads included" : model.model
        cell.setAccessibilityLabel(cell.label.stringValue)
    }
}

@MainActor
private final class AgenticUseModelTextCell: NSTableCellView {
    private var number: Double?
    private var numberIdentity: String?
    /// Rolls changed digits (numeric-text style) when the same model's value
    /// updates; a reused cell showing a different model swaps instantly.
    func setNumber(_ value: Double?, identity: String, format: @escaping (Double) -> String) {
        let animate = numberIdentity == identity && number != nil && value != nil && number != value
        numberIdentity = identity
        number = value
        label.roll(to: value.map(format) ?? "—", animated: animate)
    }
    let label = AgenticUseNumericTextField(labelWithString: "")
    let marker = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil) ?? NSImage())
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(label)
        addSubview(marker)
        marker.setAccessibilityElement(false)
        textField = label
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        let z = AgenticUseLayout.zoom
        let inset = marker.isHidden ? 2 : 12 * z
        marker.frame = NSRect(x: 2, y: (bounds.height - 6 * z) / 2, width: 6 * z, height: 6 * z)
        label.frame = NSRect(x: inset, y: (bounds.height - 20 * z) / 2, width: max(0, bounds.width - inset - 2), height: 20 * z)
    }
}
