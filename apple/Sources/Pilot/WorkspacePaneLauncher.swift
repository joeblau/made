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
    private weak var toolbarItem: NSToolbarItem?

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

    /// The toolbar's single entry point: one button that opens the New Tab
    /// selector, where every pane kind (terminal, browser, simulator,
    /// device, editor, Finder) is chosen. Same as File > New Tab (⌘T).
    static let toolbarSymbol = "plus.square.on.square"

    func makeToolbarItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "New Tab"
        item.paletteLabel = "New Tab"
        item.toolTip = "New Tab (⌘T)"
        item.image = NSImage(systemSymbolName: Self.toolbarSymbol, accessibilityDescription: "New Tab")
        item.target = self
        item.action = #selector(openTabSelector(_:))
        item.isBordered = true
        item.autovalidates = false
        toolbarItem = item
        refreshToolbar()
        return item
    }

    private func refreshToolbar() {
        toolbarItem?.isEnabled = workspace != nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let slot = Slot.allCases.first(where: { $0.title == menu.title }), let workspace else { return }
        for item in entries(for: slot, workspace: workspace, side: .right) { menu.addItem(item) }
    }

    /// Opens a new pane on the New Tab selector's root list.
    @objc func openTabSelector(_ sender: Any?) {
        guard let workspace else { return }
        workspace.addPane(kind: .terminal, side: .right, chooseModeOnOpen: true)
        onCreate?()
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
