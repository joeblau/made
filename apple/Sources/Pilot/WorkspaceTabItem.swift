import AppKit
import UniformTypeIdentifiers

/// A one-time choice in a newly opened pane. The working view takes its entire
/// place after selection; restored panes go straight to their persisted mode.
@MainActor
final class CockpitPaneModePicker: NSView {
    let pane: Pane
    var onChange: (() -> Void)?
    private let heading = CockpitUI.label("", role: .sectionTitle)
    private var shortcutHint: NSTextField?
    private var buttons: [NSButton] = []
    private var options: [String] = []
    private var shortcuts: [String] = []
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { pane.isChoosingMode && !shortcuts.isEmpty }

    init(pane: Pane) {
        self.pane = pane
        super.init(frame: .zero)
        setAccessibilityIdentifier("pane.opening-choice")
        heading.alignment = .center
        heading.lineBreakMode = .byTruncatingTail
        addSubview(heading)
        switch pane.kind {
        case .terminal, .agentChat:
            heading.stringValue = "Open Terminal"
            options = ["Raw Terminal", "Agentic Terminal"]
            shortcuts = ["r", "a"]
        case .browser:
            heading.stringValue = "Open Browser"
            options = ["Safari", "Chrome"]
            shortcuts = ["s", "c"]
            setShortcutHint("S Safari · C Chrome")
        case .device, .simulator:
            heading.stringValue = "Open Apple"
            options = ["Simulator", "Device"]
            shortcuts = ["s", "d"]
            setShortcutHint("S Simulator · D Device")
        case .android:
            heading.stringValue = "Open Android"
            options = ["Simulator", "Device"]
            shortcuts = ["s", "d"]
            setShortcutHint("S Simulator · D Device")
        case .editor: break
        }
        for (index, title) in options.enumerated() {
            let button = CockpitActionButton(title: title) { [weak self] in self?.selectMode(at: index) }
            button.controlSize = .large
            button.setAccessibilityIdentifier("pane.opening-choice.\(index)")
            button.setAccessibilityLabel(title)
            button.toolTip = title
            if shortcuts.indices.contains(index) {
                button.setAccessibilityHelp("Press \(shortcuts[index].uppercased()) to open \(title).")
                if pane.kind == .terminal || pane.kind == .agentChat {
                    button.image = NSImage(systemSymbolName: shortcuts[index] + ".square", accessibilityDescription: nil)
                    button.imagePosition = .imageTrailing
                    button.symbolConfiguration = .init(pointSize: 12, weight: .regular)
                }
            }
            button.lineBreakMode = .byTruncatingTail
            if pane.kind == .browser && index == 1 {
                button.isEnabled = ChromiumBrowserCreationPolicy.isCreationEnabled
                button.toolTip = ChromiumBrowserCreationPolicy.unavailableReason?.message ?? title
            }
            buttons.append(button)
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { nil }

    private func setShortcutHint(_ text: String) {
        let hint = CockpitUI.label(text, size: 11, color: .secondaryLabelColor)
        hint.alignment = .center
        hint.lineBreakMode = .byTruncatingTail
        shortcutHint = hint
        addSubview(hint)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        // Handle letters only in this focused opening chooser, never as
        // window-wide key equivalents that could consume input in another pane.
        guard pane.isChoosingMode,
              pane.workspace?.selectedPaneID == pane.id, !isHiddenOrHasHiddenAncestor,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              !event.isARepeat,
              let key = event.charactersIgnoringModifiers?.lowercased(),
              let index = shortcuts.firstIndex(of: key) else { super.keyDown(with: event); return }
        selectMode(at: index)
    }

    override func layout() {
        super.layout()
        let width = min(240, max(0, bounds.width - 24))
        let headingHeight = heading.intrinsicContentSize.height
        let buttonHeight: CGFloat = 32
        let hintHeight = shortcutHint?.intrinsicContentSize.height ?? 0
        let height = headingHeight + 16 + CGFloat(buttons.count) * (buttonHeight + 8) - 8
            + (shortcutHint == nil ? 0 : hintHeight + 12)
        let left = (bounds.width - width) / 2
        var top = max(12, (bounds.height - height) / 2)
        heading.frame = NSRect(x: left, y: top, width: width, height: headingHeight)
        top += headingHeight + 16
        for button in buttons {
            button.frame = NSRect(x: left, y: top, width: width, height: buttonHeight)
            top += buttonHeight + 8
        }
        shortcutHint?.frame = NSRect(x: left, y: top + 4, width: width, height: hintHeight)
    }

    func selectMode(at index: Int) {
        guard pane.isChoosingMode, options.indices.contains(index) else { return }
        switch pane.kind {
        case .terminal, .agentChat:
            pane.kind = index == 0 ? .terminal : .agentChat
        case .browser:
            guard index == 0 || ChromiumBrowserCreationPolicy.isCreationEnabled else { return }
            pane.browserState?.engine = index == 0 ? .webKit : .chromium
        case .device, .simulator:
            pane.kind = index == 0 ? .simulator : .device
        case .android:
            pane.androidTarget = index == 0 ? .simulator : .device
            AndroidDeviceRegistry.shared.configure(target: pane.androidTarget, for: pane.id)
        case .editor: return
        }
        pane.isChoosingMode = false
        pane.workspace?.selectedPaneID = pane.id
        if pane.kind == .terminal { pane.workspace?.setFrontmostTerminalPaneID(pane.id) }
        _ = pane.modelContext?.saveReporting(operation: "Choosing pane mode")
        onChange?()
    }
}

@MainActor
final class CockpitPaneTab: NSView, NSDraggingSource {
    /// Keep room for the native buttons even at the smallest text size.
    static var preferredHeight: CGFloat { max(28, 28 * CGFloat(CockpitUIZoomController.shared.factor)) }

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
    private var row: NSStackView!
    private var icon: NSView!
    private var agentBadge: AgentChatTabBadge?
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
        status.lineBreakMode = .byTruncatingTail
        status.setAccessibilityIdentifier("pane.status")
        title.setAccessibilityIdentifier("pane.title")
        closeButton.perform = { [weak self] in self?.onClose?() }
        closeButton.toolTip = "Close pane"
        closeButton.setAccessibilityLabel("Close pane")
        hideButton.perform = { [weak self] in self?.onHide?() }
        hideButton.toolTip = "Hide or show pane"
        hideButton.setAccessibilityLabel("Hide or show pane")
        for button in [closeButton, hideButton] {
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true
            button.heightAnchor.constraint(equalToConstant: 20).isActive = true
        }
        if let state = pane.browserState, pane.kind == .browser { icon = BrowserFaviconView(state: state) } else { icon = NSImageView(image: NSImage(systemSymbolName: pane.kind.systemImageName, accessibilityDescription: nil) ?? NSImage()) }
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        row = shellStack([closeButton, icon, title, status, hideButton], orientation: .horizontal, spacing: 4)
        row.distribution = .fill
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
    isolated deinit { statusTask?.cancel() }
    override var isFlipped: Bool { true }

    func refresh() {
        if let image = icon as? NSImageView, pane.kind != .browser {
            image.image = NSImage(systemSymbolName: pane.kind.systemImageName, accessibilityDescription: nil)
        }
        if pane.kind == .agentChat, agentBadge == nil {
            let badge = AgentChatTabBadge(paneID: pane.id)
            row.insertArrangedSubview(badge, at: row.arrangedSubviews.count - 1)
            agentBadge = badge
        }
        agentBadge?.isHidden = pane.kind != .agentChat
        title.font = CockpitTypography.font(size: 12)
        status.font = CockpitTypography.font(size: 10)
        title.stringValue = pane.displayTitle
        if pane.terminalDestination.kind == .drone { title.stringValue += " · " + (pane.terminalDroneNameRaw ?? "Drone") }
        title.toolTip = title.stringValue
        hideButton.image = NSImage(systemSymbolName: pane.isCollapsed ? "eye" : "eye.slash", accessibilityDescription: nil)
        setAccessibilityLabel(pane.displayTitle)
        setAccessibilityValue(pane.isCollapsed ? "Collapsed" : (isSelected ? "Selected" : ""))
        updateAppearance()
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
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateAppearance() }
    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.17) : NSColor.quaternaryLabelColor.withAlphaComponent(0.08)).cgColor
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
