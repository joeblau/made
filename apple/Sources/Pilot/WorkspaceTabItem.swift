import AppKit
import UniformTypeIdentifiers

@MainActor
final class CockpitPaneTab: NSView, NSDraggingSource {
    let pane: Pane
    var canClose = true { didSet { closeButton.isEnabled = canClose } }
    var isSelected = false { didSet { updateAppearance() } }
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
    private var downPoint: NSPoint?
    private var statusTask: Task<Void, Never>?

    init(pane: Pane, payload: WorkspacePaneDragPayload) {
        self.pane = pane
        self.payload = payload
        closeButton = ShellActionButton("", symbol: "xmark", perform: {})
        hideButton = ShellActionButton("", symbol: "eye.slash", perform: {})
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        title.lineBreakMode = .byTruncatingTail
        title.font = .systemFont(ofSize: 12)
        status.font = .systemFont(ofSize: 10)
        status.textColor = .secondaryLabelColor
        closeButton.perform = { [weak self] in self?.onClose?() }
        closeButton.toolTip = "Close pane"
        closeButton.setAccessibilityLabel("Close pane")
        hideButton.perform = { [weak self] in self?.onHide?() }
        hideButton.toolTip = "Hide or show pane"
        hideButton.setAccessibilityLabel("Hide or show pane")
        for button in [closeButton, hideButton] {
            button.isBordered = false
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        }
        let icon: NSView
        if let state = pane.browserState, pane.kind == .browser { icon = BrowserFaviconView(state: state) } else { icon = NSImageView(image: NSImage(systemSymbolName: pane.kind.systemImageName, accessibilityDescription: nil) ?? NSImage()) }
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let labels = shellStack([title, status], spacing: 0)
        var items: [NSView] = [closeButton, icon, labels]
        if pane.kind == .agentChat { items.append(AgentChatTabBadge(paneID: pane.id)) }
        items.append(hideButton)
        let row = shellStack(items, orientation: .horizontal, spacing: 4)
        row.distribution = .fill
        shellPin(row, to: self, inset: 4)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        registerForDraggedTypes([NSPasteboard.PasteboardType(UTType.pilotPane.identifier)])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        refresh()
    }
    required init?(coder: NSCoder) { nil }
    isolated deinit { statusTask?.cancel() }
    override var isFlipped: Bool { true }

    func refresh() {
        title.font = CockpitTypography.font(size: 12)
        status.font = CockpitTypography.font(size: 10)
        title.stringValue = pane.displayTitle
        if pane.terminalDestination.kind == .drone { title.stringValue += " · " + (pane.terminalDroneNameRaw ?? "Drone") }
        hideButton.image = NSImage(systemSymbolName: pane.isCollapsed ? "eye" : "eye.slash", accessibilityDescription: nil)
        setAccessibilityLabel(pane.displayTitle)
        setAccessibilityValue(pane.isCollapsed ? "Collapsed" : (isSelected ? "Selected" : ""))
        updateAppearance()
    }

    private var isMonitoring = false
    func setActive(_ active: Bool) {
        guard active != isMonitoring else { return }
        isMonitoring = active
        statusTask?.cancel(); statusTask = nil
        guard active, pane.kind == .terminal else { return }
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if NSApp.isActive {
                    let agent = self.pane.liveShellAgent()?.displayName
                    let directory = self.pane.liveShellCurrentDirectory() ?? self.pane.currentDirectory
                    let dirty = directory.isEmpty ? nil : await GitDirtyStateCache.shared.isDirty(directory: directory)
                    guard !Task.isCancelled else { return }
                    self.status.stringValue = [agent, dirty.map { $0 ? "Dirty" : "Clean" }].compactMap { $0 }.joined(separator: " · ")
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateAppearance() }
    private func updateAppearance() {
        layer?.backgroundColor = (isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.17) : NSColor.quaternaryLabelColor.withAlphaComponent(0.08)).cgColor
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
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { decode(sender) == nil ? [] : .move }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let payload = decode(sender) else { return false }
        return onDrop?(payload) ?? false
    }
    private func decode(_ sender: NSDraggingInfo) -> WorkspacePaneDragPayload? {
        guard let data = sender.draggingPasteboard.data(forType: NSPasteboard.PasteboardType(UTType.pilotPane.identifier)), data.count <= 16_384 else { return nil }
        return try? JSONDecoder().decode(WorkspacePaneDragPayload.self, from: data)
    }
    override func accessibilityPerformPress() -> Bool { onSelect?(); return true }
}
