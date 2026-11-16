import AppKit
import UniformTypeIdentifiers

@MainActor
final class CockpitPaneTab: NSView, NSDraggingSource {
    /// Matches the inspector's Actions/Tasks/PRs/Usage picker, so pane
    /// headers and that picker share one row height across the window.
    static let baseHeight: CGFloat = 32
    static var preferredHeight: CGFloat { max(baseHeight, 28 * CGFloat(CockpitUIZoomController.shared.factor) + 4) }

    let pane: Pane
    var canClose = true { didSet { closeButton.isEnabled = canClose } }
    var isSelected = false { didSet { if isSelected != oldValue { updateAppearance() } } }
    /// A hidden pane's tall strip: only the glass bubble shows (the strip lays
    /// its reveal button and Fast Command controls over it), but the bubble
    /// still selects, drags, accepts drops, and offers the context menu.
    var isCompact = false { didSet { if isCompact != oldValue { row.isHidden = isCompact; needsLayout = true } } }
    /// Room kept before the eye button for controls the strip overlays there.
    var trailingAccessoryWidth: CGFloat = 0 {
        didSet {
            guard trailingAccessoryWidth != oldValue else { return }
            accessorySpacerWidth.constant = trailingAccessoryWidth
            accessorySpacer.isHidden = trailingAccessoryWidth == 0
        }
    }
    /// Where the strip may overlay controls, in this view's coordinates.
    var trailingAccessoryFrame: NSRect { layoutSubtreeIfNeeded(); return convert(accessorySpacer.frame, from: row) }
    var payload: WorkspacePaneDragPayload
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onHide: (() -> Void)?
    var onDrop: ((WorkspacePaneDragPayload) -> Bool)?
    var contextMenuProvider: (() -> NSMenu)?
    private let title = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let closeButton: ShellActionButton
    private let hideButton: ShellActionButton
    private var row: NSStackView!
    private let accessorySpacer = NSView()
    private var accessorySpacerWidth: NSLayoutConstraint!
    /// Liquid Glass capsule behind the row; nil with Reduce Transparency.
    private var glass: NSView?
    private var icon: NSView!
    private var agentBadge: AgentChatTabBadge?
    private struct ContentSignature: Equatable {
        let kind: PaneKind
        let isChoosingMode: Bool
        let title: String
        let isCollapsed: Bool
        let zoom: Double
    }
    private var contentSignature: ContentSignature?
    private var downPoint: NSPoint?
    private var statusTask: Task<Void, Never>?
    private var pathObserver: NSObjectProtocol?

    init(pane: Pane, payload: WorkspacePaneDragPayload) {
        self.pane = pane
        self.payload = payload
        closeButton = ShellActionButton("", symbol: "xmark", perform: {})
        hideButton = ShellActionButton("", symbol: "eye.slash", perform: {})
        super.init(frame: .zero)
        // The new-tab path isn't observable, so the launcher posts each step.
        // `object` matching is by identity and a bridged UUID is a new object
        // each time, so filter on the ID instead.
        let paneID = pane.id
        pathObserver = NotificationCenter.default.addObserver(
            forName: .paneOpeningPathDidChange, object: nil, queue: .main
        ) { [weak self] note in
            guard (note.object as? UUID) == paneID else { return }
            MainActor.assumeIsolated { self?.refresh() }
        }
        wantsLayer = true
        layer?.cornerRadius = Self.preferredHeight / 2
        title.lineBreakMode = .byTruncatingTail
        title.font = .systemFont(ofSize: 12)
        status.font = .systemFont(ofSize: 10)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setAccessibilityIdentifier("pane.status")
        title.setAccessibilityIdentifier("pane.title")
        closeButton.perform = { [weak self] in self?.onClose?() }
        closeButton.toolTip = "Close pane"
        closeButton.setAccessibilityLabel("Close pane")
        hideButton.perform = { [weak self] in self?.onHide?() }
        hideButton.toolTip = "Hide or show pane"
        hideButton.setAccessibilityLabel("Hide or show pane")
        // Liquid Glass capsules, wider than tall, sized to the header row.
        for button in [closeButton, hideButton] {
            button.title = ""
            button.imagePosition = .imageOnly
            button.bezelStyle = .glass
            button.borderShape = .capsule
            button.controlSize = .small
            button.symbolConfiguration = .init(pointSize: 11, weight: .medium)
            button.widthAnchor.constraint(equalToConstant: 32).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        if let state = pane.browserState, pane.kind == .browser { icon = BrowserFaviconView(state: state) } else { icon = NSImageView(image: NSImage(systemSymbolName: pane.kind.systemImageName, accessibilityDescription: nil) ?? NSImage()) }
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        accessorySpacerWidth = accessorySpacer.widthAnchor.constraint(equalToConstant: 0)
        accessorySpacerWidth.isActive = true
        accessorySpacer.isHidden = true
        row = shellStack([closeButton, icon, title, status, accessorySpacer, hideButton], orientation: .horizontal, spacing: 4)
        row.distribution = .fill
        row.detachesHiddenViews = true
        shellPin(row, to: self, inset: 4)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        registerForDraggedTypes([NSPasteboard.PasteboardType(UTType.pilotPane.identifier)])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        refresh()
    }
    required init?(coder: NSCoder) { nil }
    isolated deinit {
        statusTask?.cancel()
        if let pathObserver { NotificationCenter.default.removeObserver(pathObserver) }
    }
    override var isFlipped: Bool { true }

    func refresh() {
        var displayTitle = pane.tabTitle
        if pane.terminalDestination.kind == .drone { displayTitle += " · " + (pane.terminalDroneNameRaw ?? "Drone") }
        let signature = ContentSignature(kind: pane.kind, isChoosingMode: pane.isChoosingMode, title: displayTitle,
                                         isCollapsed: pane.isCollapsed, zoom: CockpitUIZoomController.shared.factor)
        setAccessibilityValue(pane.isCollapsed ? "Collapsed" : (isSelected ? "Selected" : ""))
        guard contentSignature != signature else { return }
        contentSignature = signature
        if pane.kind == .browser, !pane.isChoosingMode, let state = pane.browserState, !(icon is BrowserFaviconView) {
            // A new-tab placeholder can become a browser after its tab exists.
            replaceIcon(with: BrowserFaviconView(state: state))
        }
        if let image = icon as? NSImageView {
            let symbol = pane.isChoosingMode ? "plus.square.on.square" : pane.kind.systemImageName
            image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        if pane.kind == .agentChat, agentBadge == nil {
            let badge = AgentChatTabBadge(paneID: pane.id)
            row.insertArrangedSubview(badge, at: row.arrangedSubviews.count - 1)
            agentBadge = badge
        }
        agentBadge?.isHidden = pane.kind != .agentChat
        title.font = CockpitTypography.font(size: 12)
        status.font = CockpitTypography.font(size: 10)
        title.stringValue = displayTitle
        title.toolTip = displayTitle
        hideButton.image = NSImage(systemSymbolName: pane.isCollapsed ? "eye" : "eye.slash", accessibilityDescription: nil)
        hideButton.toolTip = pane.isCollapsed ? "Show \(displayTitle)" : "Hide \(displayTitle)"
        setAccessibilityLabel(displayTitle)
        updateAppearance()
    }

    private func replaceIcon(with view: NSView) {
        view.widthAnchor.constraint(equalToConstant: 16).isActive = true
        view.heightAnchor.constraint(equalToConstant: 16).isActive = true
        if let index = row.arrangedSubviews.firstIndex(of: icon) {
            row.removeArrangedSubview(icon)
            icon.removeFromSuperview()
            row.insertArrangedSubview(view, at: index)
        }
        icon = view
    }

    private var isMonitoring = false
    func setActive(_ active: Bool) {
        let monitoring = active && pane.kind == .terminal
        guard monitoring != isMonitoring else { return }
        isMonitoring = monitoring
        statusTask?.cancel(); statusTask = nil
        guard monitoring else {
            if pane.kind != .terminal { updateStatus(agentName: nil, isDirty: nil) }
            return
        }
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if NSApp.isActive {
                    let agent = self.pane.liveShellAgent()?.displayName
                    let directory = self.pane.liveShellCurrentDirectory() ?? self.pane.currentDirectory
                    let dirty = directory.isEmpty ? nil : await GitDirtyStateCache.shared.isDirty(directory: directory)
                    guard !Task.isCancelled else { return }
                    self.updateStatus(agentName: agent, isDirty: dirty)
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func updateStatus(agentName: String?, isDirty: Bool?) {
        status.stringValue = [agentName, isDirty.map { $0 ? "Dirty" : "Clean" }].compactMap { $0 }.joined(separator: " · ")
        status.toolTip = status.stringValue
        toolTip = [title.stringValue, status.stringValue].filter { !$0.isEmpty }.joined(separator: " — ")
        setAccessibilityHelp(status.stringValue)
        needsLayout = true
    }

    override func layout() {
        // Keep the title and actions readable in a narrow split. Metadata stays
        // available through the pane tooltip and accessibility help.
        let hideStatus = status.stringValue.isEmpty || bounds.width < 240 * CGFloat(CockpitUIZoomController.shared.factor)
        if status.isHidden != hideStatus { status.isHidden = hideStatus }
        super.layout()
        let radius = min(bounds.width, bounds.height) / 2
        layer?.cornerRadius = radius
        if #available(macOS 26.0, *), let glass = glass as? NSGlassEffectView, glass.cornerRadius != radius {
            glass.cornerRadius = radius
        }
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateAppearance() }
    private func updateAppearance() {
        let selectedTint = NSColor.controlAccentColor.withAlphaComponent(0.17)
        if #available(macOS 26.0, *), !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let surface: NSGlassEffectView
            if let current = glass as? NSGlassEffectView { surface = current } else {
                // Behind the row: clicks and drags on the bare glass travel up
                // the responder chain to this tab, and drops find its
                // registered types through the superview chain.
                surface = NSGlassEffectView()
                surface.frame = bounds
                surface.autoresizingMask = [.width, .height]
                surface.cornerRadius = min(bounds.width, bounds.height) / 2
                addSubview(surface, positioned: .below, relativeTo: nil)
                glass = surface
            }
            surface.tintColor = isSelected ? selectedTint : nil
            layer?.backgroundColor = nil
        } else {
            glass?.removeFromSuperview()
            glass = nil
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = (isSelected ? selectedTint : NSColor.quaternaryLabelColor.withAlphaComponent(0.08)).cgColor
            }
        }
    }
    override func mouseDown(with event: NSEvent) { downPoint = convert(event.locationInWindow, from: nil); onSelect?() }
    override func mouseUp(with event: NSEvent) { downPoint = nil }
    override func mouseDragged(with event: NSEvent) {
        guard let downPoint else { return }
        let location = convert(event.locationInWindow, from: nil)
        guard hypot(location.x - downPoint.x, location.y - downPoint.y) >= 4,
              let data = try? JSONEncoder().encode(payload) else { return }
        self.downPoint = nil
        let item = NSPasteboardItem()
        item.setData(data, forType: NSPasteboard.PasteboardType(UTType.pilotPane.identifier))
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) { cacheDisplay(in: bounds, to: rep); image.addRepresentation(rep) }
        dragging.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [dragging], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { context == .withinApplication ? .move : [] }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenuProvider?() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let payload = decode(sender) else { return [] }
        // A tab dragged over itself is not a destination worth announcing.
        if payload.paneID != pane.id { CockpitMotion.setDropHighlight(true, on: self) }
        return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { CockpitMotion.setDropHighlight(false, on: self) }
    override func draggingEnded(_ sender: NSDraggingInfo) { CockpitMotion.setDropHighlight(false, on: self) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        CockpitMotion.setDropHighlight(false, on: self)
        guard let payload = decode(sender) else { return false }
        return onDrop?(payload) ?? false
    }
    private func decode(_ sender: NSDraggingInfo) -> WorkspacePaneDragPayload? {
        guard let data = sender.draggingPasteboard.data(forType: NSPasteboard.PasteboardType(UTType.pilotPane.identifier)), data.count <= 16_384 else { return nil }
        return try? JSONDecoder().decode(WorkspacePaneDragPayload.self, from: data)
    }
    override func accessibilityPerformPress() -> Bool { onSelect?(); return true }
}
