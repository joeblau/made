import AppKit
import Observation

@MainActor
final class AgenticUseViewController: NSViewController, CockpitPanePresenting {
    let store: AgenticUsageStore
    private let isLive: Bool
    private let rangeControl = NSSegmentedControl()
    private let refreshButton = NSButton()
    private let spinner = NSProgressIndicator()
    private let intervalLabel = NSTextField(labelWithString: "")
    private let warningLabel = NSTextField(wrappingLabelWithString: "")
    private let warningDismiss = NSButton()
    private let freshnessLabel = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private var dashboard: AgenticUseDashboard?
    private let stateTitle = NSTextField(labelWithString: "")
    private let stateDetail = NSTextField(wrappingLabelWithString: "")
    private let stateAction = NSButton()
    private let scanProgress = NSProgressIndicator()
    private var visible = false
    private var observationGeneration = 0

    init(store: AgenticUsageStore, isLive: Bool = true) {
        self.store = store
        self.isLive = isLive
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = AgenticUseFlippedView()
        rangeControl.segmentCount = AgenticUseRange.allCases.count
        rangeControl.trackingMode = .selectOne
        rangeControl.segmentStyle = .rounded
        rangeControl.controlSize = .small
        for (index, range) in AgenticUseRange.allCases.enumerated() { rangeControl.setLabel(range.label, forSegment: index) }
        rangeControl.target = self
        rangeControl.action = #selector(rangeChanged)
        rangeControl.setAccessibilityLabel("Usage date range")
        refreshButton.bezelStyle = .rounded
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh usage and pricing")
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        refreshButton.toolTip = "Refresh usage and pricing"
        warningDismiss.bezelStyle = .rounded
        warningDismiss.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss warning")
        warningDismiss.target = self
        warningDismiss.action = #selector(dismissWarning)
        warningLabel.textColor = .systemOrange
        intervalLabel.textColor = .secondaryLabelColor
        freshnessLabel.textColor = .secondaryLabelColor
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        scanProgress.style = .bar
        scanProgress.minValue = 0
        scanProgress.maxValue = 1
        stateTitle.alignment = .center
        stateDetail.alignment = .center
        stateDetail.textColor = .secondaryLabelColor
        stateDetail.isSelectable = true
        stateAction.bezelStyle = .rounded
        stateAction.target = self
        stateAction.action = #selector(performStateAction)
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        for child in [intervalLabel, rangeControl, refreshButton, spinner, warningLabel, warningDismiss,
                      freshnessLabel, scroll, stateTitle, stateDetail, stateAction, scanProgress] { view.addSubview(child) }
        NotificationCenter.default.addObserver(self, selector: #selector(consentChanged), name: UsageConsent.changedNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(zoomChanged), name: .cockpitUIZoomDidChange, object: nil)
        refreshPresentation()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        updatePresentation(isActive: true, isSelected: true)
    }
    override func viewDidDisappear() {
        super.viewDidDisappear()
        updatePresentation(isActive: false, isSelected: false)
    }
    func updatePresentation(isActive: Bool, isSelected: Bool) {
        guard visible != isActive else { return }
        visible = isActive
        observationGeneration &+= 1
        if isActive {
            if isLive { store.start() }
            observe()
        }
        // The application owns historical scanning. Detaching this view stops
        // presentation observation, not the shared store or dashboard publisher.
    }
    private func observe() {
        guard visible else { return }
        let generation = observationGeneration
        withObservationTracking {
            _ = store.phase; _ = store.snapshot; _ = store.isRefreshing; _ = store.scanWarning
            _ = store.cursorLastUpdated; _ = store.range; _ = store.pricingStatus
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.visible, self.observationGeneration == generation else { return }
                self.observe()
            }
        }
        refreshPresentation()
    }

    func refreshPresentation() {
        guard isViewLoaded else { return }
        rangeControl.selectedSegment = AgenticUseRange.allCases.firstIndex(of: store.range) ?? 0
        refreshButton.isEnabled = isLive && !store.isRefreshing
        stateAction.isEnabled = isLive
        rangeControl.isEnabled = isLive
        if store.isRefreshing { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        intervalLabel.stringValue = store.snapshot.map {
            ($0.interval.start..<$0.interval.end).formatted(.interval.month(.abbreviated).day())
        } ?? "Agent usage"
        warningLabel.stringValue = store.scanWarning ?? ""
        warningLabel.isHidden = store.scanWarning == nil
        warningDismiss.isHidden = warningLabel.isHidden
        freshnessLabel.stringValue = store.cursorLastUpdated.map {
            "Cursor last updated " + $0.formatted(date: .abbreviated, time: .shortened)
        } ?? ""
        stateAction.isHidden = false
        scanProgress.stopAnimation(nil)
        scanProgress.isHidden = true
        var showDashboard = false
        switch store.phase {
        case .idle, .scanning:
            showDashboard = dashboard != nil && store.snapshot?.isEmpty == false
            stateTitle.stringValue = "Loading agent usage…"
            if case .scanning(let scanned, let total) = store.phase, total > 0 {
                stateDetail.stringValue = "\(scanned.formatted()) of \(total.formatted()) files"
            } else { stateDetail.stringValue = "Reading local agent history" }
            stateAction.isHidden = true
            scanProgress.isHidden = false
            scanProgress.isIndeterminate = store.scanProgress == nil
            if let progress = store.scanProgress { scanProgress.doubleValue = progress } else { scanProgress.startAnimation(nil) }
        case .empty:
            stateTitle.stringValue = "No Usage Data"
            stateDetail.stringValue = "No usage was found for Claude Code, Codex, Cursor, Grok, or Kimi.\nRun an agent session, or enable Cursor usage in Settings."
            stateAction.title = "Rescan"
        case .failed(let reason):
            stateTitle.stringValue = "Can't Read Usage Logs"
            stateDetail.stringValue = reason
            stateAction.title = "Retry"
        case .loaded:
            if let snapshot = store.snapshot, dashboard != nil || !snapshot.isEmpty {
                showDashboard = true
                if let dashboard { dashboard.update(snapshot: snapshot, pricingStatus: store.pricingStatus) } else {
                    let dashboard = AgenticUseDashboard(snapshot: snapshot, pricingStatus: store.pricingStatus)
                    self.dashboard = dashboard
                    scroll.documentView = dashboard
                }
                stateAction.isHidden = true
            } else {
                stateTitle.stringValue = "Nothing in This Range"
                stateDetail.stringValue = "No usage recorded in the selected \(store.range.label) range."
                stateAction.title = "Show All History"
                stateAction.isHidden = store.range == .all
            }
        }
        scroll.isHidden = !showDashboard
        if showDashboard { scanProgress.isHidden = true; stateAction.isHidden = true }
        stateTitle.isHidden = !scroll.isHidden
        stateDetail.isHidden = !scroll.isHidden
        view.needsLayout = true
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = view.bounds.width
        let zoom = AgenticUseLayout.zoom
        let compact = width < 650 * zoom
        let headerHeight: CGFloat = (compact ? 76 : 44) * zoom
        let controlsY: CGFloat = (compact ? 40 : 9) * zoom
        intervalLabel.font = AgenticUseLayout.font(.body)
        intervalLabel.frame = NSRect(x: 16, y: 12, width: max(0, compact ? width - 48 : width - 355 * zoom), height: 24 * zoom)
        rangeControl.font = AgenticUseLayout.font(.meta)
        let rangeWidth = min(240 * zoom, max(100, width - 100))
        rangeControl.frame = NSRect(x: max(16, width - rangeWidth - 70 * zoom), y: controlsY, width: rangeWidth, height: 27 * zoom)
        refreshButton.frame = NSRect(x: width - 16 - 30 * zoom, y: controlsY, width: 30 * zoom, height: 27 * zoom)
        spinner.frame = NSRect(x: max(0, rangeControl.frame.minX - 24), y: controlsY + 5, width: 16, height: 16)
        let warningHeight: CGFloat = warningLabel.isHidden ? 0 : 48 * zoom
        warningLabel.font = AgenticUseLayout.font(.body)
        warningLabel.frame = NSRect(x: 16, y: headerHeight + 4, width: max(0, width - 76), height: max(0, warningHeight - 4))
        warningDismiss.frame = NSRect(x: width - 44, y: headerHeight + 8, width: 28, height: 26)
        let footerHeight: CGFloat = freshnessLabel.stringValue.isEmpty ? 0 : 26 * zoom
        freshnessLabel.font = AgenticUseLayout.font(.meta)
        freshnessLabel.frame = NSRect(x: 16, y: view.bounds.height - footerHeight, width: max(0, width - 32), height: footerHeight)
        let top = headerHeight + warningHeight
        scroll.frame = NSRect(x: 0, y: top, width: width, height: max(0, view.bounds.height - top - footerHeight))
        if let dashboard {
            dashboard.setFrameSize(NSSize(width: scroll.contentSize.width, height: dashboard.contentHeight(for: scroll.contentSize.width)))
            dashboard.needsLayout = true
        }
        let center = top + max(0, view.bounds.height - top - 150 * zoom) / 2
        stateTitle.font = AgenticUseLayout.font(.title, weight: .semibold)
        stateTitle.frame = NSRect(x: 24, y: center, width: max(0, width - 48), height: 30 * zoom)
        stateDetail.font = AgenticUseLayout.font(.body)
        stateDetail.frame = NSRect(x: 36, y: center + 38 * zoom, width: max(0, width - 72), height: 70 * zoom)
        stateAction.font = AgenticUseLayout.font(.body)
        stateAction.frame = NSRect(x: max(12, width / 2 - 90 * zoom), y: center + 112 * zoom, width: min(width - 24, 180 * zoom), height: 30 * zoom)
        scanProgress.frame = NSRect(x: max(12, width / 2 - 120), y: center + 112 * zoom, width: 240, height: 16)
    }
    @objc private func rangeChanged() {
        guard isLive, AgenticUseRange.allCases.indices.contains(rangeControl.selectedSegment) else { return }
        store.range = AgenticUseRange.allCases[rangeControl.selectedSegment]
    }
    @objc private func refresh() { if isLive { store.rescan() } }
    @objc private func dismissWarning() { store.dismissScanWarning() }
    @objc private func consentChanged() { if isLive && visible { store.rescan() } }
    @objc private func zoomChanged() { dashboard?.refreshTypography(); view.needsLayout = true }
    @objc private func performStateAction() {
        guard isLive else { return }
        if case .loaded = store.phase { store.range = .all } else { store.rescan() }
    }
}

enum AgenticUseLayout {
    static let cardPadding: CGFloat = 16
    static let cardRadius: CGFloat = 16
    static let gap: CGFloat = 8
    enum TextStyle {
        case display, title, body, meta, caption
        var size: CGFloat {
            switch self {
            case .display: 26
            case .title: 14
            case .body: 12
            case .meta: 11
            case .caption: 10
            }
        }
    }
    @MainActor static var zoom: CGFloat { CockpitUIZoomController.shared.factor }
    @MainActor static func font(_ style: TextStyle, weight: NSFont.Weight = .regular, monospaced: Bool = false) -> NSFont {
        CockpitTypography.font(size: style.size, weight: weight, monospaced: monospaced)
    }
    @MainActor static func label(_ text: String, style: TextStyle = .body, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font(style)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }
}

class AgenticUseFlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
class AgenticUseCardView: AgenticUseFlippedView {
    let titleLabel: NSTextField
    init(title: String) {
        titleLabel = AgenticUseLayout.label(title, style: .title)
        super.init(frame: .zero)
        titleLabel.setAccessibilityRole(.staticText)
        titleLabel.setAccessibilityRoleDescription("Heading")
        addSubview(titleLabel)
    }
    required init?(coder: NSCoder) { nil }
    func preferredHeight(for width: CGFloat) -> CGFloat { 120 * AgenticUseLayout.zoom }
    override func layout() {
        super.layout()
        titleLabel.font = AgenticUseLayout.font(.title, weight: .semibold)
        titleLabel.frame = NSRect(x: 16, y: 14, width: max(0, bounds.width - 32), height: 24 * AgenticUseLayout.zoom)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.withAlphaComponent(0.09).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: AgenticUseLayout.cardRadius, yRadius: AgenticUseLayout.cardRadius).fill()
    }
}

@MainActor
final class AgenticUseActionButton: NSButton {
    var handler: (() -> Void)?
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        controlSize = .small
        target = self
        action = #selector(invoke)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func invoke() { handler?() }
}

/// Panels persist across snapshots, preserving filters and expanded models.
@MainActor
final class AgenticUseDashboard: AgenticUseFlippedView {
    private(set) var snapshot: AgenticUseSnapshot
    private var pricingStatus: String
    private let kpis: AgenticUseKPICards
    private let chart: AgenticUseDailyChartPanel
    private let flow: AgenticUseTokenFlowPanel
    private let breakdown: AgenticUseProviderBreakdown
    private let models: AgenticUseTopModels
    private let insights: AgenticUseInsightsView
    private let footnote = NSTextField(wrappingLabelWithString: "")
    private let layoutTransition = AgenticUseDataTransition()
    private var pendingLayoutTransition = false
    private var layoutWidth: CGFloat = 0
    private var layoutZoom: CGFloat = 0

    init(snapshot: AgenticUseSnapshot, pricingStatus: String) {
        self.snapshot = snapshot
        self.pricingStatus = pricingStatus
        kpis = AgenticUseKPICards(snapshot: snapshot)
        chart = AgenticUseDailyChartPanel(snapshot: snapshot)
        flow = AgenticUseTokenFlowPanel(snapshot: snapshot)
        breakdown = AgenticUseProviderBreakdown(snapshot: snapshot)
        models = AgenticUseTopModels(snapshot: snapshot)
        insights = AgenticUseInsightsView(insights: AgenticUseInsights.make(from: snapshot))
        super.init(frame: .zero)
        for child in [kpis, chart, flow, breakdown, models, insights, footnote] { addSubview(child) }
        models.onHeightChange = { [weak self] in self?.resizeDocument() }
        footnote.textColor = .secondaryLabelColor
        footnote.isSelectable = true
        updateFootnote()
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()
    }
    func update(snapshot: AgenticUseSnapshot, pricingStatus: String) {
        let changed = snapshot != self.snapshot
        guard changed || pricingStatus != self.pricingStatus else { return }
        self.pricingStatus = pricingStatus
        if changed {
            pendingLayoutTransition = window?.isVisible == true
            self.snapshot = snapshot
            kpis.update(snapshot: snapshot); chart.update(snapshot: snapshot); flow.update(snapshot: snapshot)
            breakdown.update(snapshot: snapshot); models.update(snapshot: snapshot)
            insights.update(insights: AgenticUseInsights.make(from: snapshot))
        }
        updateFootnote()
        resizeDocument()
    }
    private func updateFootnote() {
        footnote.stringValue = "Costs are API-equivalent estimates at published per-token rates. \(pricingStatus)."
            + (snapshot.hasUnpricedModels ? "\n* Partial total: \(AgenticUseFormat.tokens(snapshot.unpricedTokens)) tokens have no published rate." : "")
    }
    func refreshTypography() {
        for child in subviews { child.needsLayout = true; child.needsDisplay = true }
        resizeDocument()
    }
    private func resizeDocument() {
        let height = contentHeight(for: bounds.width)
        setFrameSize(NSSize(width: bounds.width, height: pendingLayoutTransition ? max(bounds.height, height) : height))
        needsLayout = true
    }
    func contentHeight(for width: CGFloat) -> CGFloat {
        let inner = max(0, width - 16)
        let top = kpis.preferredHeight(for: inner) + chart.preferredHeight(for: inner) + 24
        let twoColumns = usesTwoColumns(for: width)
        let column = twoColumns ? (inner - 8) / 2 : inner
        let left = flow.preferredHeight(for: column) + insights.preferredHeight(for: column) + 8
        let right = breakdown.preferredHeight(for: column) + models.preferredHeight(for: column) + 8
        return top + (twoColumns ? max(left, right) : left + right + 8) + 74 * AgenticUseLayout.zoom
    }
    override func layout() {
        super.layout()
        if layoutTransition.isRunning && !pendingLayoutTransition && layoutWidth == bounds.width && layoutZoom == AgenticUseLayout.zoom { return }
        let animate = pendingLayoutTransition
        pendingLayoutTransition = false
        if !animate { layoutTransition.finish() }
        let oldFrames = subviews.map(\.frame)
        let oldHeight = bounds.height
        layoutWidth = bounds.width
        layoutZoom = AgenticUseLayout.zoom
        let width = max(0, bounds.width - 16)
        var y: CGFloat = 8
        func place(_ child: NSView, height: CGFloat) {
            child.frame = NSRect(x: 8, y: y, width: width, height: height)
            y += height + 8
        }
        place(kpis, height: kpis.preferredHeight(for: width))
        place(chart, height: chart.preferredHeight(for: width))
        if usesTwoColumns(for: bounds.width) {
            let column = (width - 8) / 2
            flow.frame = NSRect(x: 8, y: y, width: column, height: flow.preferredHeight(for: column))
            insights.frame = NSRect(x: 8, y: flow.frame.maxY + 8, width: column, height: insights.preferredHeight(for: column))
            breakdown.frame = NSRect(x: 16 + column, y: y, width: column, height: breakdown.preferredHeight(for: column))
            models.frame = NSRect(x: 16 + column, y: breakdown.frame.maxY + 8, width: column, height: models.preferredHeight(for: column))
            y = max(insights.frame.maxY, models.frame.maxY) + 8
        } else {
            place(flow, height: flow.preferredHeight(for: width))
            place(breakdown, height: breakdown.preferredHeight(for: width))
            place(models, height: models.preferredHeight(for: width))
            place(insights, height: insights.preferredHeight(for: width))
        }
        footnote.font = AgenticUseLayout.font(.meta)
        footnote.frame = NSRect(x: 12, y: y, width: max(0, width - 8), height: 64 * AgenticUseLayout.zoom)
        if animate {
            let targets = subviews.map(\.frame)
            let targetHeight = contentHeight(for: bounds.width)
            layoutTransition.start(in: self) { [weak self] progress in
                guard let self else { return }
                for (index, child) in self.subviews.enumerated() where oldFrames.indices.contains(index) {
                    child.frame = AgenticUseDataTransition.frame(oldFrames[index], targets[index], progress)
                    child.needsLayout = true
                }
                self.setFrameSize(NSSize(width: self.bounds.width,
                                         height: AgenticUseDataTransition.mix(oldHeight, targetHeight, progress)))
            }
        }
    }

    private func usesTwoColumns(for width: CGFloat) -> Bool {
        (width - 24) / 2 >= models.minimumCardWidth
    }
}
