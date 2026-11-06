import CoreTransferable
import AppKit
import Observation
import UniformTypeIdentifiers

extension UTType {
    static let pilotPane = UTType(exportedAs: "app.blau.pilot.pane")
}

enum WorkspacePaneSurface: String, Codable, Hashable {
    case main
    case `extension`
}

struct WorkspacePaneDragPayload: Codable, Hashable, Transferable {
    let paneID: UUID
    let sourceWorkspaceID: UUID
    let projectID: UUID
    let sourceSurface: WorkspacePaneSurface

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .pilotPane)
    }
}

private enum PaneLayoutMetrics {
    static let dividerLineThickness: CGFloat = 1
    static let dividerHitThickness: CGFloat = 6
    static let collapsedPaneThickness: CGFloat = 28
    /// Pane tab height; tabs are capsules, so this is also their diameter.
    static let tabHeight: CGFloat = 28
}

private struct PaneLayoutPlan {
    let sizes: [UUID: CGFloat]
    let expandedSize: CGFloat
}

/// Pane size floors. The relative 0.1 floor alone let a divider drag (or a
/// narrower window) squeeze a pane to 37–65pt, where pane headers clip and
/// picker titles break a letter per line. An expanded pane therefore keeps
/// at least `minimumPaneLength` points whenever the stack fits every expanded
/// pane at that length; a stack too small for that keeps the relative floor.
enum PaneSizing {
    /// Enough for a pane header: glyph, a short title, and two small buttons.
    static let minimumPaneLength: Double = 160
    static let minimumRelativeFraction = 0.1

    /// The smallest fraction a divider drag may leave an expanded pane.
    static func minimumFraction(expandedSize: Double?, expandedCount: Int) -> Double {
        guard let expandedSize, expandedSize > 0, expandedCount > 0,
              minimumPaneLength * Double(expandedCount) <= expandedSize else {
            return minimumRelativeFraction
        }
        return max(minimumRelativeFraction, minimumPaneLength / expandedSize)
    }

    /// New fractions for the pair either side of a divider. The pair's total is
    /// preserved, and neither side is pushed below `minimumFraction`; a side
    /// already below it (a window that just got narrower) may grow but not
    /// shrink, so the result never jumps, goes negative, or overflows the pair.
    static func resizedPair(
        leading: Double,
        trailing: Double,
        delta: Double,
        minimumFraction: Double
    ) -> (leading: Double, trailing: Double) {
        let leading = max(0, leading)
        let trailing = max(0, trailing)
        let total = leading + trailing
        let lower = min(minimumFraction, leading)
        let upper = total - min(minimumFraction, trailing)
        let newLeading = min(max(leading + delta, lower), upper)
        return (newLeading, total - newLeading)
    }

    /// Lifts every expanded pane below `minimumPaneLength` up to it, taking the
    /// space proportionally from the larger panes. Input fractions sum to 1;
    /// so does the output. When the panes can't all fit at the floor, the
    /// fractions come back unchanged (the previous, purely relative layout).
    static func flooredFractions(_ fractions: [UUID: Double], expandedSize: Double) -> [UUID: Double] {
        guard !fractions.isEmpty, expandedSize > 0,
              minimumPaneLength * Double(fractions.count) <= expandedSize else { return fractions }
        let floor = minimumPaneLength / expandedSize
        var pinned = Set<UUID>()
        while true {
            let free = fractions.filter { !pinned.contains($0.key) }
            let remaining = max(0, 1 - Double(pinned.count) * floor)
            let freeTotal = free.values.reduce(0, +)
            let scaled = free.mapValues { value in
                freeTotal > 0 ? value / freeTotal * remaining : remaining / Double(free.count)
            }
            let undersized = scaled.filter { $0.value < floor }.map(\.key)
            // `count * floor <= 1` means at least one pane always stays free.
            guard !undersized.isEmpty, undersized.count < free.count else {
                return scaled.merging(pinned.map { ($0, floor) }) { scaledValue, _ in scaledValue }
            }
            pinned.formUnion(undersized)
        }
    }
}

/// Owns one presentation controller per live pane. A transfer or workspace
/// switch detaches views; only deletion evicts and explicitly closes a pane.
@MainActor
final class CockpitPaneControllerCache {
    static let shared = CockpitPaneControllerCache()
    private var controllers: [UUID: NSViewController] = [:]
    var onCloseValidationFailure: ((UUID) -> Void)?
    var allControllers: [NSViewController] { Array(controllers.values) }

    func controller(for pane: Pane, rootPath: String?, factory: (Pane, String?) -> NSViewController) -> NSViewController {
        if let controller = controllers[pane.id] {
            (controller as? CockpitPaneContextUpdating)?.updateContext(rootPath: rootPath)
            return controller
        }
        let controller = factory(pane, rootPath)
        controllers[pane.id] = controller
        (controller as? CockpitPaneContextUpdating)?.updateContext(rootPath: rootPath)
        return controller
    }

    func existingController(for id: UUID) -> NSViewController? { controllers[id] }

    func retainOnly(_ ids: Set<UUID>) {
        for id in controllers.keys.filter({ !ids.contains($0) }) {
            guard let controller = controllers.removeValue(forKey: id) else { continue }
            (controller as? CockpitPanePresenting)?.updatePresentation(isActive: false, isSelected: false)
            (controller as? CockpitPaneClosing)?.closePane()
            controller.view.removeFromSuperview()
            controller.removeFromParent()
        }
    }

    func prepareToClose(ids: Set<UUID>? = nil, completion: @escaping @MainActor (Bool) -> Void) {
        let values = controllers.filter { ids == nil || ids!.contains($0.key) }.map(\.value)
        Self.validate(values, onFailure: { [weak self] controller in
            self?.revealCloseFailure(controller)
        }, completion: completion)
    }

    /// A user can edit an already-saved pane while another pane or Chromium
    /// shutdown is still awaiting completion. Approval must not outlive edits.
    func validateCloseReadiness(ids: Set<UUID>? = nil) -> Bool {
        let values = controllers.filter { ids == nil || ids!.contains($0.key) }.map(\.value)
        guard let changed = Self.closeReadinessFailure(in: values) else { return true }
        revealCloseFailure(changed)
        return false
    }

    private func revealCloseFailure(_ controller: NSViewController) {
        guard let id = controllers.first(where: { $0.value === controller })?.key else { return }
        onCloseValidationFailure?(id)
    }

    private static func closeReadinessFailure(in controllers: [NSViewController]) -> NSViewController? {
        controllers.first { ($0 as? CockpitPaneCloseValidating)?.isReadyToClose == false }
    }

    static func validate(_ controllers: [NSViewController], onFailure: ((NSViewController) -> Void)? = nil,
                         completion: @escaping @MainActor (Bool) -> Void) {
        validateNext(controllers, onFailure: onFailure) { allowed in
            guard allowed else { completion(false); return }
            if let changed = closeReadinessFailure(in: controllers) {
                onFailure?(changed)
                completion(false)
            } else { completion(true) }
        }
    }

    private static func validateNext(_ controllers: [NSViewController], onFailure: ((NSViewController) -> Void)?,
                                     completion: @escaping @MainActor (Bool) -> Void) {
        guard let controller = controllers.first else { completion(true); return }
        let remaining = Array(controllers.dropFirst())
        guard let validating = controller as? CockpitPaneCloseValidating else {
            validateNext(remaining, onFailure: onFailure, completion: completion); return
        }
        validating.prepareToClose { allowed in
            if allowed { validateNext(remaining, onFailure: onFailure, completion: completion) } else {
                onFailure?(controller)
                completion(false)
            }
        }
    }

    func closeAll() { retainOnly([]) }
}

@MainActor
final class CockpitWorkspaceViewController: NSViewController {
    let workspace: Workspace
    let projectID: UUID
    let surface: WorkspacePaneSurface
    private let cache: CockpitPaneControllerCache
    private let factory: (Pane, String?) -> NSViewController
    private let onDrop: (WorkspacePaneDragPayload, Pane) -> Bool
    var onSelectionChange: (() -> Void)?
    var onClosePane: ((Pane) -> Void)?
    private var panes: [UUID: CockpitPaneSlot] = [:]
    private var active = false
    private let layoutView = CockpitPaneLayoutView()

    init(workspace: Workspace, projectID: UUID, surface: WorkspacePaneSurface,
         cache: CockpitPaneControllerCache, factory: @escaping (Pane, String?) -> NSViewController,
         onDrop: @escaping (WorkspacePaneDragPayload, Pane) -> Bool) {
        self.workspace = workspace
        self.projectID = projectID
        self.surface = surface
        self.cache = cache
        self.factory = factory
        self.onDrop = onDrop
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() { view = layoutView; layoutView.workspace = workspace }

    func refresh(isActive: Bool) {
        loadViewIfNeeded()
        active = isActive
        let sorted = workspace.sortedPanes
        let ids = Set(sorted.map(\.id))
        for id in panes.keys.filter({ !ids.contains($0) }) {
            panes.removeValue(forKey: id)?.detach()
        }
        var slots: [CockpitPaneSlot] = []
        for pane in sorted {
            let slot: CockpitPaneSlot
            if let existing = panes[pane.id] { slot = existing } else {
                let payload = WorkspacePaneDragPayload(paneID: pane.id, sourceWorkspaceID: workspace.id,
                                                       projectID: projectID, sourceSurface: surface)
                slot = CockpitPaneSlot(pane: pane, payload: payload)
                slot.onSelect = { [weak self, weak pane] in
                    guard let self, let pane else { return }
                    if pane.isCollapsed { self.workspace.expandPane(pane) }
                    self.workspace.selectedPaneID = pane.id
                    if pane.kind == .terminal { self.workspace.setFrontmostTerminalPaneID(pane.id) }
                    self.workspace.syncDefaultRootPathIfNeeded()
                    self.onSelectionChange?()
                    self.refresh(isActive: self.active)
                }
                slot.onFocus = { [weak self] in self?.focusSelectedPane() }
                slot.tab.onClose = { [weak self, weak pane] in if let pane { self?.onClosePane?(pane) } }
                slot.tab.onHide = { [weak self, weak pane] in
                    guard let self, let pane else { return }
                    if pane.isCollapsed { self.workspace.expandPane(pane) } else { self.workspace.collapsePane(pane) }
                    self.refresh(isActive: self.active)
                }
                slot.tab.onDrop = { [weak self, weak pane] payload in
                    guard let self, let pane else { return false }
                    let result = self.onDrop(payload, pane)
                    self.refresh(isActive: self.active)
                    return result
                }
                slot.tab.contextMenuProvider = { [weak self, weak pane] in
                    guard let self, let pane else { return NSMenu() }
                    return self.contextMenu(for: pane)
                }
                panes[pane.id] = slot
            }
            slot.tab.canClose = sorted.count > 1 || surface == .extension
            slot.tab.isSelected = workspace.selectedPaneID == pane.id && !pane.isCollapsed
            slot.tab.refresh()
            slot.tab.setActive(isActive && !pane.isCollapsed)
            if pane.isCollapsed {
                slot.detach()
                slot.showCollapsed()
            } else {
                let controller = cache.controller(for: pane, rootPath: workspace.effectiveRootPath, factory: factory)
                if controller.parent !== self {
                    controller.view.removeFromSuperview()
                    controller.removeFromParent()
                    addChild(controller)
                }
                slot.attach(controller)
                (controller as? CockpitPanePresenting)?.updatePresentation(isActive: isActive, isSelected: isActive && workspace.selectedPaneID == pane.id)
            }
            slots.append(slot)
        }
        layoutView.setSlots(slots)
    }

    func deactivate() {
        active = false
        for slot in panes.values { slot.tab.setActive(false); slot.detach() }
    }

    func focusSelectedPane() {
        guard let pane = workspace.selectedPane, !pane.isCollapsed else { return }
        guard let controller = cache.existingController(for: pane.id) else { return }
        if let focusing = controller as? CockpitPaneInputFocusing { focusing.focusPaneInput(); return }
        func responder(in view: NSView) -> NSView? {
            guard !view.isHiddenOrHasHiddenAncestor else { return nil }
            if let control = view as? NSControl, !control.isEnabled { return nil }
            for child in view.subviews { if let found = responder(in: child) { return found } }
            return view.acceptsFirstResponder ? view : nil
        }
        if let target = responder(in: controller.view) { view.window?.makeFirstResponder(target) }
    }

    private func contextMenu(for pane: Pane) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ShellMenuItem(pane.isCollapsed ? "Show Pane" : "Hide Pane") { [weak self] in
            if pane.isCollapsed { self?.workspace.expandPane(pane) } else { self?.workspace.collapsePane(pane) }
        })
        menu.addItem(ShellMenuItem(workspace.focusedPaneID == pane.id ? "Restore Pane Layout" : "Focus Pane") { [weak self] in self?.workspace.focusPane(pane) })
        menu.addItem(ShellMenuItem("Close Pane", enabledWhen: { [weak self] in (self?.workspace.panes.count ?? 0) > 1 || self?.surface == .extension }) { [weak self] in self?.onClosePane?(pane) })
        menu.addItem(.separator())
        let launcher = WorkspacePaneLauncher(workspace: workspace)
        for (title, side) in [("Add Pane on Left", Workspace.Side.left), ("Add Pane on Right", Workspace.Side.right)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = launcher.makeMenu(side: side)
            menu.addItem(item)
        }
        menu.addItem(ShellMenuItem(workspace.axis == .vertical ? "Stack Panes Vertically" : "Arrange Panes Horizontally") { [weak self] in
            guard let self else { return }
            self.workspace.axis = self.workspace.axis == .vertical ? .horizontal : .vertical
            _ = self.workspace.modelContext?.saveReporting()
        })
        menu.addItem(ShellMenuItem("Reset Pane Sizes") { [weak self] in self?.workspace.resetPaneSizes() })
        return menu
    }
}

@MainActor
private final class CockpitPaneSlot: NSView {
    let pane: Pane
    let tab: CockpitPaneTab
    var onSelect: (() -> Void)?
    var onFocus: (() -> Void)?
    private let content = NSView()
    private weak var controller: NSViewController?
    private let reveal = ShellActionButton("Show Pane", symbol: "eye", perform: {})
    override var isFlipped: Bool { true }

    init(pane: Pane, payload: WorkspacePaneDragPayload) {
        self.pane = pane
        tab = CockpitPaneTab(pane: pane, payload: payload)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(tab); addSubview(content)
        tab.onSelect = { [weak self] in self?.onSelect?(); self?.onFocus?() }
        reveal.perform = { [weak self] in self?.onSelect?(); self?.onFocus?() }
        reveal.setAccessibilityLabel("Show \(pane.displayTitle)")
    }
    required init?(coder: NSCoder) { nil }

    func attach(_ controller: NSViewController) {
        self.controller = controller
        reveal.removeFromSuperview()
        if controller.view.superview !== content {
            controller.view.removeFromSuperview()
            content.addSubview(controller.view)
        }
        controller.view.frame = content.bounds
        controller.view.autoresizingMask = [.width, .height]
    }
    func detach() {
        tab.setActive(false)
        guard let controller else { return }
        // The destination window may already have reparented this retained
        // controller. A late source refresh must not deactivate its new host.
        if controller.view.superview === content {
            (controller as? CockpitPanePresenting)?.updatePresentation(isActive: false, isSelected: false)
            controller.view.removeFromSuperview()
            controller.removeFromParent()
        }
        self.controller = nil
    }
    func showCollapsed() {
        if reveal.superview !== content { content.addSubview(reveal) }
        reveal.frame = content.bounds
        reveal.autoresizingMask = [.width, .height]
    }
    override func layout() {
        super.layout()
        let height: CGFloat = pane.isCollapsed && bounds.width <= 32 ? 0 : min(36 * CGFloat(CockpitUIZoomController.shared.factor), bounds.height)
        tab.frame = NSRect(x: 0, y: 0, width: bounds.width, height: height)
        tab.isHidden = height == 0
        content.frame = NSRect(x: 0, y: height, width: bounds.width, height: max(0, bounds.height - height))
        controller?.view.frame = content.bounds
        reveal.frame = content.bounds
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        if result != nil, NSApp.currentEvent?.type == .leftMouseDown, pane.workspace?.selectedPaneID != pane.id { onSelect?() }
        return result
    }
}

@MainActor
private final class CockpitPaneLayoutView: NSView {
    weak var workspace: Workspace?
    private var slots: [CockpitPaneSlot] = []
    private var dividers: [CockpitPaneDivider] = []
    private let empty = NSTextField(labelWithString: "Add a pane using the toolbar.")
    override var isFlipped: Bool { true }

    func setSlots(_ next: [CockpitPaneSlot]) {
        let changed = slots.map(ObjectIdentifier.init) != next.map(ObjectIdentifier.init)
        if changed {
            for slot in slots { slot.removeFromSuperview() }
            for divider in dividers { divider.removeFromSuperview() }
            slots = next
            dividers = []
            for slot in slots { addSubview(slot) }
            if slots.count > 1 {
                for index in 0..<(slots.count - 1) {
                    let divider = CockpitPaneDivider(frame: .zero)
                    divider.onResize = { [weak self] delta in
                        guard let self, let workspace = self.workspace else { return }
                        let expanded = self.expandedLength
                        guard expanded > 0 else { return }
                        workspace.resizePanes(leadingID: self.slots[index].pane.id, trailingID: self.slots[index + 1].pane.id,
                                              delta: Double(delta / expanded), expandedSize: Double(expanded))
                        self.needsLayout = true
                        self.layoutSubtreeIfNeeded()
                    }
                    divider.onEnd = { [weak workspace] in workspace?.persistPaneSizes() }
                    dividers.append(divider); addSubview(divider)
                }
            }
        }
        if slots.isEmpty { if empty.superview == nil { addSubview(empty) } } else { empty.removeFromSuperview() }
        needsLayout = true
    }

    private var expandedLength: CGFloat {
        let isVertical = workspace?.axis == .vertical
        let total = isVertical ? bounds.width : bounds.height
        let collapsed = slots.filter { $0.pane.isCollapsed }.count
        return max(0, total - CGFloat(max(0, slots.count - 1)) * 6 - CGFloat(collapsed) * 28)
    }

    override func layout() {
        super.layout()
        guard let workspace else { return }
        let isVertical = workspace.axis == .vertical
        let total = isVertical ? bounds.width : bounds.height
        let fractions = PaneSizing.flooredFractions(workspace.normalizedExpandedSizeFractions, expandedSize: Double(expandedLength))
        let collapsedCount = slots.filter { $0.pane.isCollapsed }.count
        let available = max(0, total - CGFloat(max(0, slots.count - 1)) * 6)
        let collapsedSize = collapsedCount > 0 ? min(28, available / CGFloat(max(1, slots.count))) : 0
        let expanded = max(0, available - CGFloat(collapsedCount) * collapsedSize)
        var position: CGFloat = 0
        for (index, slot) in slots.enumerated() {
            let length = slot.pane.isCollapsed ? collapsedSize : expanded * CGFloat(fractions[slot.pane.id] ?? 0)
            slot.frame = isVertical ? NSRect(x: position, y: 0, width: length, height: bounds.height)
                                   : NSRect(x: 0, y: position, width: bounds.width, height: length)
            position += length
            if dividers.indices.contains(index) {
                let divider = dividers[index]
                divider.isVertical = isVertical
                divider.isEnabled = workspace.canResizePanes(leadingID: slots[index].pane.id, trailingID: slots[index + 1].pane.id)
                divider.frame = isVertical ? NSRect(x: position, y: 0, width: 6, height: bounds.height)
                                          : NSRect(x: 0, y: position, width: bounds.width, height: 6)
                position += 6
            }
        }
        empty.sizeToFit()
        empty.frame.origin = NSPoint(x: max(12, (bounds.width - empty.frame.width) / 2), y: max(12, bounds.height / 2))
    }
}

@MainActor
private final class CockpitPaneDivider: NSView {
    var isVertical = true { didSet { setAccessibilityLabel(isVertical ? "Resize panels horizontally" : "Resize panels vertically") } }
    var isEnabled = true { didSet { setAccessibilityEnabled(isEnabled) } }
    var onResize: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    private var previous: NSPoint?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Resize panels")
    }
    required init?(coder: NSCoder) { nil }
    override func accessibilityPerformIncrement() -> Bool { resizeByKeyboard(12) }
    override func accessibilityPerformDecrement() -> Bool { resizeByKeyboard(-12) }
    private func resizeByKeyboard(_ delta: CGFloat) -> Bool {
        guard isEnabled else { return false }
        onResize?(delta); onEnd?(); return true
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 126: _ = resizeByKeyboard(-12)
        case 124, 125: _ = resizeByKeyboard(12)
        default: super.keyDown(with: event)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        let line = isVertical ? NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height)
                              : NSRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1)
        line.fill()
    }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: isVertical ? .resizeLeftRight : .resizeUpDown) } }
    override func mouseDown(with event: NSEvent) { if isEnabled { previous = event.locationInWindow } }
    override func mouseDragged(with event: NSEvent) {
        guard let previous else { return }
        let current = event.locationInWindow
        self.previous = current
        onResize?(isVertical ? current.x - previous.x : previous.y - current.y)
    }
    override func mouseUp(with event: NSEvent) { previous = nil; onEnd?() }
}
