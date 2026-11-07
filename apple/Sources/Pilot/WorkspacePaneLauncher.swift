import AppKit
import Synchronization

/// Opening UI state follows pane identity, since SwiftData can recreate model
/// instances. Only the chosen kind/engine/target belongs in the saved model.
/// Each pending pane keeps its placeholder navigation stack.
enum PaneOpeningChoices {
    private static let pending = Mutex<[UUID: [NewTabPage]]>([:])

    static func contains(_ id: UUID) -> Bool { pending.withLock { $0[id] != nil } }
    static func set(_ choosing: Bool, for id: UUID) {
        pending.withLock {
            if choosing { $0[id] = $0[id] ?? [.root] } else { $0.removeValue(forKey: id) }
        }
    }
    static func path(for id: UUID) -> [NewTabPage]? { pending.withLock { $0[id] } }
    /// Only a pending pane has a path; the root page is always kept.
    static func setPath(_ path: [NewTabPage], for id: UUID) {
        pending.withLock {
            guard $0[id] != nil else { return }
            $0[id] = path.first == .root ? path : [.root] + path
        }
    }
    static func retainOnly(_ ids: Set<UUID>) { pending.withLock { $0 = $0.filter { ids.contains($0.key) } } }
}

extension Workspace {
    @discardableResult
    func addBrowserPane(engine: BrowserEngine = .webKit, side: Side) -> Pane {
        addPane(kind: .browser, side: side, browserEngine: engine)
    }
}

extension PaneKind {
    var isTerminalTool: Bool { self == .terminal || self == .agentChat }
    var isAppleTool: Bool { self == .device || self == .simulator }
}

extension Pane {
    var isChoosingMode: Bool {
        get { PaneOpeningChoices.contains(id) }
        set { PaneOpeningChoices.set(newValue, for: id) }
    }

    var androidTarget: AndroidPaneTarget {
        get { androidTargetRaw.flatMap(AndroidPaneTarget.init(rawValue:)) ?? .simulator }
        set { androidTargetRaw = newValue.rawValue }
    }
}

/// Native pane launchers. Each category chooses its mode once when opened.
@MainActor
final class WorkspacePaneLauncher: NSObject, NSMenuDelegate {
    var workspace: Workspace? { didSet { refreshToolbar() } }
    var onCreate: (() -> Void)?
    private weak var toolbarGroup: NSToolbarItemGroup?

    private enum Slot: String, CaseIterable {
        case terminal, browser, simulator, device, editor, finder

        var title: String {
            switch self {
            case .terminal: "Terminal"
            case .browser: "Browser"
            case .simulator: "Simulator"
            case .device: "Device"
            case .editor: "Editor"
            case .finder: "Open in Finder"
            }
        }
        var symbol: String {
            switch self {
            case .terminal: PaneKind.terminal.systemImageName
            case .browser: PaneKind.browser.systemImageName
            case .simulator: PaneKind.simulator.systemImageName
            case .device: "iphone"
            case .editor: PaneKind.editor.systemImageName
            case .finder: "folder"
            }
        }
        var requiresRoot: Bool { self == .editor || self == .finder }
    }

    init(workspace: Workspace?) {
        self.workspace = workspace
        super.init()
    }

    /// AppKit owns the shared glass capsule, symbol sizing and overflow menu.
    func makeToolbarItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItemGroup {
        let group = NSToolbarItemGroup(itemIdentifier: identifier)
        group.label = "New Pane"
        group.controlRepresentation = .expanded
        group.selectionMode = .momentary
        group.isBordered = true
        group.autovalidates = false
        group.subitems = Slot.allCases.map { slot in
            let itemID = NSToolbarItem.Identifier("workspace.launcher.\(slot.rawValue)")
            let item = NSToolbarItem(itemIdentifier: itemID)
            item.target = self
            item.action = switch slot {
            case .terminal: #selector(openTerminal(_:))
            case .browser: #selector(openBrowser(_:))
            case .simulator: #selector(openSimulator(_:))
            case .device: #selector(openDevice(_:))
            case .editor: #selector(openEditor(_:))
            case .finder: #selector(openFinder(_:))
            }
            item.label = slot.title
            item.toolTip = slot.title
            item.image = NSImage(systemSymbolName: slot.symbol, accessibilityDescription: slot.title)
            item.isBordered = true
            item.autovalidates = false
            return item
        }
        toolbarGroup = group
        refreshToolbar()
        return group
    }

    private func refreshToolbar() {
        guard let toolbarGroup else { return }
        toolbarGroup.isEnabled = workspace != nil
        for (slot, item) in zip(Slot.allCases, toolbarGroup.subitems) {
            item.isEnabled = workspace != nil && (!slot.requiresRoot || workspace?.effectiveRootPath != nil)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let slot = Slot.allCases.first(where: { $0.title == menu.title }), let workspace else { return }
        for item in entries(for: slot, workspace: workspace, side: .right) { menu.addItem(item) }
    }

    /// Opens a new-tab placeholder already pushed to the toolbar category.
    /// Escape returns to the full New Tab list.
    private func openPlaceholder(_ kind: PaneKind, page: NewTabPage) {
        guard let workspace else { return }
        let pane = workspace.addPane(kind: kind, side: .right, chooseModeOnOpen: true)
        pane.openingPath = [.root, page]
        onCreate?()
    }

    @objc private func openTerminal(_ sender: Any?) { openPlaceholder(.terminal, page: .terminal) }
    @objc private func openBrowser(_ sender: Any?) {
        guard let workspace else { return }
        workspace.addBrowserPane(side: .right)
        onCreate?()
    }
    @objc private func openSimulator(_ sender: Any?) { openPlaceholder(.simulator, page: .simulator) }
    @objc private func openDevice(_ sender: Any?) { openPlaceholder(.device, page: .device) }

    @objc private func openEditor(_ sender: Any?) {
        guard let workspace, workspace.effectiveRootPath != nil else { return }
        workspace.addPane(kind: .editor, side: .right)
        onCreate?()
    }

    @objc private func openFinder(_ sender: Any?) {
        guard let path = workspace?.effectiveRootPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func makeMenu(side: Workspace.Side = .right) -> NSMenu {
        let menu = NSMenu()
        guard let workspace else { return menu }
        for slot in Slot.allCases {
            let items = entries(for: slot, workspace: workspace, side: side)
            if slot == .finder { menu.addItem(.separator()) }
            if slot == .terminal || slot == .browser {
                let item = NSMenuItem(title: slot.title, action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: slot.title)
                items.forEach(submenu.addItem)
                item.submenu = submenu
                menu.addItem(item)
            } else { items.forEach(menu.addItem) }
        }
        return menu
    }

    private func entries(for slot: Slot, workspace: Workspace, side: Workspace.Side) -> [NSMenuItem] {
        switch slot {
        case .terminal:
            return [ShellMenuItem("Raw Terminal") { [weak self] in
                workspace.addPane(kind: .terminal, side: side); self?.onCreate?()
            }, ShellMenuItem("Agentic Terminal") { [weak self] in
                workspace.addPane(kind: .agentChat, side: side); self?.onCreate?()
            }] + DroneStore.shared.records.map { record in
                ShellMenuItem(record.name, enabledWhen: { DroneStore.shared.states[record.id]?.isConnected == true }) { [weak self] in
                    workspace.addPane(kind: .terminal, side: side, terminalDestination: .drone(droneID: record.id, name: record.name))
                    self?.onCreate?()
                }
            }
        case .browser:
            var items: [NSMenuItem] = BrowserEngine.allCases.map { engine in
                ShellMenuItem(engine.displayName, enabledWhen: {
                    BrowserPaneCreationPolicy.permitsCreation(for: engine, chromiumCreationEnabled: ChromiumBrowserCreationPolicy.isCreationEnabled)
                }) { [weak self] in workspace.addBrowserPane(engine: engine, side: side); self?.onCreate?() }
            }
            if let reason = ChromiumBrowserCreationPolicy.unavailableReason {
                let item = NSMenuItem(title: reason.message, action: nil, keyEquivalent: "")
                item.isEnabled = false; items.append(item)
            }
            return items
        case .simulator:
            return [
                ShellMenuItem("Apple Simulator") { [weak self] in workspace.addPane(kind: .simulator, side: side); self?.onCreate?() },
                androidEntry("Android Simulator", target: .simulator, workspace: workspace, side: side)
            ]
        case .device:
            return [
                ShellMenuItem("Apple Device Stream") { [weak self] in workspace.addPane(kind: .device, side: side); self?.onCreate?() },
                androidEntry("Android Device", target: .device, workspace: workspace, side: side)
            ]
        case .editor:
            return [ShellMenuItem("Editor", enabledWhen: { workspace.effectiveRootPath != nil }) { [weak self] in
                workspace.addPane(kind: .editor, side: side); self?.onCreate?()
            }]
        case .finder:
            return [ShellMenuItem("Open in Finder", enabledWhen: { workspace.effectiveRootPath != nil }) {
                if let path = workspace.effectiveRootPath { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            }]
        }
    }

    private func androidEntry(_ title: String, target: AndroidPaneTarget, workspace: Workspace, side: Workspace.Side) -> NSMenuItem {
        ShellMenuItem(title) { [weak self] in
            let pane = workspace.addPane(kind: .android, side: side)
            pane.androidTarget = target
            _ = workspace.modelContext?.saveReporting()
            AndroidDeviceRegistry.shared.configure(target: target, for: pane.id)
            self?.onCreate?()
        }
    }
}
