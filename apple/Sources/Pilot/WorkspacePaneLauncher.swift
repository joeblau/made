import AppKit
import Synchronization

/// Opening UI state follows pane identity, since SwiftData can recreate model
/// instances. Only the chosen kind/engine/target belongs in the saved model.
enum PaneOpeningChoices {
    private static let pending = Mutex<Set<UUID>>([])

    static func contains(_ id: UUID) -> Bool { pending.withLock { $0.contains(id) } }
    static func set(_ choosing: Bool, for id: UUID) {
        pending.withLock { if choosing { $0.insert(id) } else { $0.remove(id) } }
    }
    static func retainOnly(_ ids: Set<UUID>) { pending.withLock { $0.formIntersection(ids) } }
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
        case terminal, browser, apple, android, editor, finder

        var title: String {
            switch self {
            case .terminal: "Terminal"
            case .browser: "Browser"
            case .apple: "Apple"
            case .android: "Android"
            case .editor: "Editor"
            case .finder: "Open in Finder"
            }
        }
        var symbol: String {
            switch self {
            case .terminal: PaneKind.terminal.systemImageName
            case .browser: PaneKind.browser.systemImageName
            case .apple: "apple.logo"
            case .android: PaneKind.android.systemImageName
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
            case .apple: #selector(openApple(_:))
            case .android: #selector(openAndroid(_:))
            case .editor: #selector(openEditor(_:))
            case .finder: #selector(openFinder(_:))
            }
            item.label = slot.title
            item.toolTip = slot.title
            item.image = slot == .android ? NSImage(named: "AndroidRobot") : nil
            if item.image == nil { item.image = NSImage(systemSymbolName: slot.symbol, accessibilityDescription: slot.title) }
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

    private func open(_ kind: PaneKind) {
        guard let workspace else { return }
        workspace.addPane(kind: kind, side: .right, chooseModeOnOpen: kind != .browser)
        onCreate?()
    }

    @objc private func openTerminal(_ sender: Any?) { open(.terminal) }
    @objc private func openBrowser(_ sender: Any?) { open(.browser) }
    @objc private func openApple(_ sender: Any?) { open(.simulator) }
    @objc private func openAndroid(_ sender: Any?) { open(.android) }

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
        case .apple:
            return [
                ShellMenuItem("Apple Simulator") { [weak self] in workspace.addPane(kind: .simulator, side: side); self?.onCreate?() },
                ShellMenuItem("Apple Device Stream") { [weak self] in workspace.addPane(kind: .device, side: side); self?.onCreate?() }
            ]
        case .android:
            return [("Android Simulator", AndroidPaneTarget.simulator), ("Android Device", AndroidPaneTarget.device)].map { title, target in
                ShellMenuItem(title) { [weak self] in
                    let pane = workspace.addPane(kind: .android, side: side)
                    pane.androidTarget = target
                    _ = workspace.modelContext?.saveReporting()
                    AndroidDeviceRegistry.shared.configure(target: target, for: pane.id)
                    self?.onCreate?()
                }
            }
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
}
