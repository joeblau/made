import AppKit

@MainActor
final class AgenticUseDailyChartPanel: AgenticUseCardView {
    enum Metric: String, CaseIterable { case cost = "Cost", tokens = "Tokens", savings = "Cache Savings" }
    enum Granularity: String, CaseIterable { case daily = "Daily", weekly = "Weekly" }
    enum Style: String, CaseIterable { case area = "Stacked Area", bars = "Stacked Bars" }
    struct Cell: Identifiable, Equatable {
        let bucket: Date
        let provider: AgenticProvider
        let value: Double
        var id: String { "\(provider.rawValue)|\(bucket.timeIntervalSinceReferenceDate)" }
    }

    private var snapshot: AgenticUseSnapshot
    private var metric = Metric.cost
    private var granularity = Granularity.daily
    private var style = Style.area
    private var isolated: AgenticProvider?
    private let metricPicker = NSSegmentedControl()
    private let granularityPicker = NSPopUpButton()
    private let stylePicker = NSPopUpButton()
    private let plot = AgenticUseStackedPlot()
    private var legendButtons: [AgenticUseActionButton] = []
    private var legendProviders: [AgenticProvider] = []

    init(snapshot: AgenticUseSnapshot) {
        self.snapshot = snapshot
        super.init(title: "Daily Cost")
        metricPicker.segmentCount = Metric.allCases.count
        metricPicker.trackingMode = .selectOne
        metricPicker.segmentStyle = .rounded
        metricPicker.controlSize = .small
        metricPicker.selectedSegment = 0
        for (index, metric) in Metric.allCases.enumerated() { metricPicker.setLabel(metric.rawValue, forSegment: index) }
        metricPicker.target = self
        metricPicker.action = #selector(metricChanged)
        metricPicker.setAccessibilityLabel("Chart metric")
        granularityPicker.addItems(withTitles: Granularity.allCases.map(\.rawValue))
        granularityPicker.target = self
        granularityPicker.action = #selector(granularityChanged)
        granularityPicker.setAccessibilityLabel("Chart granularity")
        stylePicker.addItems(withTitles: Style.allCases.map(\.rawValue))
        stylePicker.target = self
        stylePicker.action = #selector(styleChanged)
        stylePicker.setAccessibilityLabel("Chart style")
        for child in [metricPicker, granularityPicker, stylePicker, plot] { addSubview(child) }
        rebuild()
    }
    required init?(coder: NSCoder) { nil }

    func update(snapshot: AgenticUseSnapshot) {
        let changedRange = self.snapshot.range != snapshot.range
        self.snapshot = snapshot
        if changedRange { plot.clearSelection() }
        if !Self.offersWeekly(snapshot.range) { granularity = .daily }
        if let isolated, !snapshot.providerTotals.contains(where: { $0.provider == isolated }) { self.isolated = nil }
        rebuild()
    }
    private static func offersWeekly(_ range: AgenticUseRange) -> Bool { range == .month || range == .quarter || range == .all }
    private var effectiveGranularity: Granularity { Self.offersWeekly(snapshot.range) ? granularity : .daily }
    private func value(of point: AgenticProviderPoint) -> Double {
        switch metric {
        case .cost: point.cost
        case .tokens: Double(point.tokens)
        case .savings: point.cacheSavings
        }
    }

    /// Data and rollups are cached by the native plot, independent of pointer
    /// movement. This is the same provider ordering and calendar bucketing as
    /// the original chart, including local weeks and the trailing 24h range.
    private func rebuild() {
        let allProviders = snapshot.providerTotals.map(\.provider)
        let providers = isolated.map { [$0] } ?? allProviders
        let visible = Set(providers)
        var totals: [Date: [AgenticProvider: Double]] = [:]
        var shares: [AgenticProvider: Double] = [:]
        for point in snapshot.providerSeries {
            shares[point.provider, default: 0] += value(of: point)
            guard visible.contains(point.provider) else { continue }
            let date = effectiveGranularity == .weekly
                ? Calendar.current.dateInterval(of: .weekOfYear, for: point.day)?.start ?? point.day : point.day
            totals[date, default: [:]][point.provider, default: 0] += value(of: point)
        }
        let cells = totals.keys.sorted().flatMap { date in
            providers.map { Cell(bucket: date, provider: $0, value: totals[date]?[$0] ?? 0) }
        }
        let unit = snapshot.range == .day ? "Hourly" : effectiveGranularity == .weekly ? "Weekly" : "Daily"
        titleLabel.stringValue = unit + " " + metric.rawValue
        granularityPicker.isHidden = !Self.offersWeekly(snapshot.range)
        granularityPicker.selectItem(withTitle: effectiveGranularity.rawValue)
        plot.update(cells: cells, providers: providers, metric: metric, style: style,
                    hourly: snapshot.range == .day, weekly: effectiveGranularity == .weekly)
        if legendProviders != allProviders {
            legendButtons.forEach { $0.removeFromSuperview() }
            legendProviders = allProviders
            legendButtons = allProviders.map { provider in
                let button = AgenticUseActionButton("") { [weak self] in
                    guard let self else { return }
                    self.isolated = self.isolated == provider ? nil : provider
                    self.plot.clearSelection()
                    self.rebuild()
                }
                button.setButtonType(.pushOnPushOff)
                addSubview(button)
                return button
            }
        }
        let sum = shares.values.reduce(0, +)
        for (provider, button) in zip(allProviders, legendButtons) {
            let share = sum > 0 ? (shares[provider] ?? 0) / sum : 0
            button.title = provider.displayName + " " + AgenticUseFormat.percent(share)
            button.contentTintColor = AgenticUseModelPalette.providerColor(for: provider)
            button.state = isolated == provider ? .on : .off
            button.toolTip = isolated == provider ? "Show all providers" : "Show only " + provider.displayName
            button.setAccessibilityValue(isolated == provider ? "Selected" : "Not selected")
        }
        needsLayout = true
    }
    override func preferredHeight(for width: CGFloat) -> CGFloat {
        let columns = max(1, Int(max(1, width - 32) / (155 * AgenticUseLayout.zoom)))
        let legendRows = ceil(CGFloat(snapshot.providerTotals.count) / CGFloat(columns))
        return ((width < 780 * AgenticUseLayout.zoom ? 388 : 320) + legendRows * 32) * AgenticUseLayout.zoom + 16
    }
    override func layout() {
        super.layout()
        let zoom = AgenticUseLayout.zoom
        let compact = bounds.width < 780 * zoom
        titleLabel.frame.size.width = compact ? max(0, bounds.width - 32) : 180 * zoom
        metricPicker.font = AgenticUseLayout.font(.meta)
        metricPicker.frame = NSRect(x: compact ? 16 : 196 * zoom, y: compact ? 44 * zoom : 12,
                                   width: min(max(1, bounds.width - 32), 246 * zoom), height: 28 * zoom)
        stylePicker.font = AgenticUseLayout.font(.meta)
        granularityPicker.font = AgenticUseLayout.font(.meta)
        stylePicker.frame = NSRect(x: max(16, bounds.width - 16 - 148 * zoom), y: compact ? 80 * zoom : 12, width: 148 * zoom, height: 28 * zoom)
        granularityPicker.frame = NSRect(x: max(16, bounds.width - 16 - 258 * zoom), y: compact ? 80 * zoom : 12, width: 104 * zoom, height: 28 * zoom)
        let top: CGFloat = compact ? 118 * zoom : 50 * zoom
        plot.frame = NSRect(x: 8, y: top, width: max(0, bounds.width - 16), height: 270 * zoom)
        let columns = max(1, Int(max(1, bounds.width - 32) / (155 * zoom)))
        let columnWidth = max(1, (bounds.width - 32) / CGFloat(columns))
        for (index, button) in legendButtons.enumerated() {
            button.font = AgenticUseLayout.font(.meta)
            button.frame = NSRect(x: 16 + CGFloat(index % columns) * columnWidth,
                                  y: plot.frame.maxY + 8 + CGFloat(index / columns) * 32 * zoom,
                                  width: max(1, columnWidth - 6), height: 27 * zoom)
        }
    }
    @objc private func metricChanged() {
        guard Metric.allCases.indices.contains(metricPicker.selectedSegment) else { return }
        metric = Metric.allCases[metricPicker.selectedSegment]; plot.clearSelection(); rebuild()
    }
    @objc private func granularityChanged() {
        granularity = Granularity.allCases[granularityPicker.indexOfSelectedItem]; plot.clearSelection(); rebuild()
    }
    @objc private func styleChanged() {
        style = Style.allCases[stylePicker.indexOfSelectedItem]; plot.clearSelection(); rebuild()
    }
    nonisolated static func snappedBucket(for date: Date, range: AgenticUseRange, calendar: Calendar) -> Date? {
        range.bucketUnit == .day ? calendar.startOfDay(for: date) : calendar.dateInterval(of: .hour, for: date)?.start
    }
}

@MainActor
private final class AgenticUseStackedPlot: AgenticUseFlippedView {
    typealias Cell = AgenticUseDailyChartPanel.Cell
    private var providers: [AgenticProvider] = []
    private var buckets: [Date] = []
    private var values: [[Double]] = []
    private var maximum = 1.0
    private var metric = AgenticUseDailyChartPanel.Metric.cost
    private var style = AgenticUseDailyChartPanel.Style.area
    private var hourly = false
    private var weekly = false
    private var selected: Int?
    private var tracking: NSTrackingArea?
    private let tooltip = NSTextField(wrappingLabelWithString: "")
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        tooltip.isHidden = true
        tooltip.drawsBackground = true
        tooltip.backgroundColor = .windowBackgroundColor
        tooltip.wantsLayer = true
        tooltip.layer?.cornerRadius = 8
        tooltip.layer?.borderWidth = 1
        tooltip.layer?.borderColor = NSColor.separatorColor.cgColor
        tooltip.setAccessibilityElement(false)
        addSubview(tooltip)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Usage chart")
        setAccessibilityHelp("Use Left and Right Arrow to inspect each time bucket. Copy chart data from the context menu.")
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Previous time bucket") { [weak self] in self?.moveSelection(by: -1) ?? false },
            NSAccessibilityCustomAction(name: "Next time bucket") { [weak self] in self?.moveSelection(by: 1) ?? false }
        ])
        let menu = NSMenu()
        let copy = NSMenuItem(title: "Copy Chart Data", action: #selector(copyData), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        self.menu = menu
    }
    required init?(coder: NSCoder) { nil }
    func update(cells: [Cell], providers: [AgenticProvider], metric: AgenticUseDailyChartPanel.Metric,
                style: AgenticUseDailyChartPanel.Style, hourly: Bool, weekly: Bool) {
        self.providers = providers; self.metric = metric; self.style = style; self.hourly = hourly; self.weekly = weekly
        buckets = Array(Set(cells.map(\.bucket))).sorted()
        let groups = Dictionary(grouping: cells, by: \.bucket)
        values = buckets.map { bucket in
            let row = Dictionary(uniqueKeysWithValues: (groups[bucket] ?? []).map { ($0.provider, $0.value) })
            return providers.map { row[$0] ?? 0 }
        }
        maximum = max(0.000001, (values.map { $0.reduce(0, +) }.max() ?? 0) * 1.08)
        if let selected, !buckets.indices.contains(selected) { self.selected = nil }
        setAccessibilityLabel(metric.rawValue + " by " + (hourly ? "hour" : weekly ? "week" : "day"))
        updateTooltip()
        needsDisplay = true
    }
    func clearSelection() { selected = nil; updateTooltip(); needsDisplay = true }
    private var plotRect: NSRect {
        let z = AgenticUseLayout.zoom
        return NSRect(x: 54 * z, y: 10 * z, width: max(1, bounds.width - 70 * z), height: max(1, bounds.height - 45 * z))
    }
    private func x(_ index: Int) -> CGFloat { plotRect.minX + (CGFloat(index) + 0.5) / CGFloat(max(1, buckets.count)) * plotRect.width }
    private func y(_ value: Double) -> CGFloat { plotRect.maxY - CGFloat(value / maximum) * plotRect.height }
    private func formatted(_ value: Double) -> String { metric == .tokens ? AgenticUseFormat.tokens(value) : AgenticUseFormat.cost(value) }
    private func dateLabel(_ date: Date) -> String {
        hourly ? date.formatted(.dateTime.month(.abbreviated).day().hour())
            : (weekly ? "Week of " : "") + date.formatted(.dateTime.month(.abbreviated).day().year())
    }
    override func draw(_ dirtyRect: NSRect) {
        let rect = plotRect
        let attributes: [NSAttributedString.Key: Any] = [.font: AgenticUseLayout.font(.caption), .foregroundColor: NSColor.secondaryLabelColor]
        for tick in 0...4 {
            let value = maximum * Double(tick) / 4
            let yy = y(value)
            let grid = NSBezierPath(); grid.move(to: NSPoint(x: rect.minX, y: yy)); grid.line(to: NSPoint(x: rect.maxX, y: yy))
            NSColor.separatorColor.withAlphaComponent(0.5).setStroke(); grid.stroke()
            let text = metric == .tokens ? AgenticUseFormat.tokens(value) : AgenticUseFormat.axisCost(value)
            (text as NSString).draw(in: NSRect(x: 0, y: yy - 7, width: 50, height: 18), withAttributes: attributes)
        }
        guard !buckets.isEmpty, values.contains(where: { $0.contains(where: { $0 > 0 }) }) else {
            let text = metric == .savings ? "No priced cache reads in this range" : metric == .cost ? "No published pricing · select Tokens to view usage" : "No tokens in this range"
            (text as NSString).draw(in: rect.insetBy(dx: 20, dy: rect.height / 2 - 10), withAttributes: attributes)
            return
        }
        var bottom = Array(repeating: 0.0, count: buckets.count)
        for (providerIndex, provider) in providers.enumerated() {
            let top = values.enumerated().map { bottom[$0.offset] + $0.element[providerIndex] }
            AgenticUseModelPalette.providerColor(for: provider).withAlphaComponent(0.82).setFill()
            if style == .bars || buckets.count == 1 {
                let width = rect.width / CGFloat(buckets.count) * 0.8
                for index in buckets.indices {
                    NSBezierPath(rect: NSRect(x: x(index) - width / 2, y: y(top[index]), width: width,
                                             height: max(0, y(bottom[index]) - y(top[index])))).fill()
                }
            } else {
                let area = NSBezierPath()
                for index in buckets.indices {
                    let point = NSPoint(x: x(index), y: y(top[index]))
                    if index == 0 { area.move(to: point) } else { area.line(to: point) }
                }
                for index in buckets.indices.reversed() { area.line(to: NSPoint(x: x(index), y: y(bottom[index]))) }
                area.close(); area.fill()
            }
            bottom = top
        }
        let strideValue = max(1, Int(ceil(CGFloat(buckets.count) / max(1, rect.width / 95))))
        for index in stride(from: 0, to: buckets.count, by: strideValue) {
            let text = hourly ? buckets[index].formatted(.dateTime.hour()) : buckets[index].formatted(.dateTime.month(.abbreviated).day())
            (text as NSString).draw(in: NSRect(x: x(index) - 30, y: rect.maxY + 8, width: 80, height: 20), withAttributes: attributes)
        }
        if let selected {
            let line = NSBezierPath(); line.move(to: NSPoint(x: x(selected), y: rect.minY)); line.line(to: NSPoint(x: x(selected), y: rect.maxY))
            line.setLineDash([3, 3], count: 2, phase: 0)
            NSColor.labelColor.withAlphaComponent(0.6).setStroke(); line.stroke()
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseMoved(with event: NSEvent) { select(at: convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) { select(at: convert(event.locationInWindow, from: nil)) }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); select(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { if window?.firstResponder !== self { clearSelection() } }
    override func keyDown(with event: NSEvent) {
        guard !buckets.isEmpty else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 123: _ = moveSelection(by: -1)
        case 124: _ = moveSelection(by: 1)
        case 53: clearSelection(); return
        default: super.keyDown(with: event); return
        }
    }
    private func moveSelection(by offset: Int) -> Bool {
        guard !buckets.isEmpty else { return false }
        selected = min(buckets.count - 1, max(0, (selected ?? (offset < 0 ? buckets.count : -1)) + offset))
        updateTooltip(); needsDisplay = true
        NSAccessibility.post(element: self, notification: .valueChanged)
        return true
    }
    private func select(at point: NSPoint) {
        guard plotRect.contains(point), !buckets.isEmpty else { clearSelection(); return }
        let index = min(buckets.count - 1, max(0, Int((point.x - plotRect.minX) / plotRect.width * CGFloat(buckets.count))))
        guard selected != index else { return }
        selected = index; updateTooltip(); needsDisplay = true
    }
    private func updateTooltip() {
        guard let selected, buckets.indices.contains(selected) else { tooltip.isHidden = true; setAccessibilityValue("Use arrow keys to inspect usage buckets"); return }
        let entries = zip(providers, values[selected]).sorted { $0.1 > $1.1 }
        let lines = [dateLabel(buckets[selected]), "Total: " + formatted(values[selected].reduce(0, +))]
            + entries.map { $0.0.displayName + ": " + formatted($0.1) }
        tooltip.stringValue = lines.joined(separator: "\n")
        tooltip.font = AgenticUseLayout.font(.meta)
        tooltip.isHidden = false
        let width: CGFloat = min(240, max(140, bounds.width - 70))
        let xx = x(selected) < plotRect.midX ? x(selected) + 10 : x(selected) - width - 10
        tooltip.frame = NSRect(x: min(max(0, xx), max(0, bounds.width - width)), y: 8, width: width, height: CGFloat(lines.count) * 18 * AgenticUseLayout.zoom + 10)
        setAccessibilityValue(lines.joined(separator: ", "))
    }
    override func layout() { super.layout(); updateTooltip() }
    @objc private func copyData() {
        var lines = ["Date\tProvider\t" + metric.rawValue]
        for index in buckets.indices {
            for (column, provider) in providers.enumerated() {
                lines.append(buckets[index].ISO8601Format() + "\t" + provider.displayName + "\t" + String(values[index][column]))
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
