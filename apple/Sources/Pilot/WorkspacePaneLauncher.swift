import AppKit

/// Native menu-backed pane creation shared by both workspace windows.
@MainActor
final class WorkspacePaneLauncher: NSView {
    var workspace: Workspace? { didSet { button.isEnabled = workspace != nil } }
    var onCreate: (() -> Void)?
    private let button = NSButton(title: "New Pane", target: nil, action: nil)

    init(workspace: Workspace?) {
        self.workspace = workspace
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: 28))
        button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(showMenu)
        button.isEnabled = workspace != nil
        button.setAccessibilityIdentifier("workspace.pane-launcher")
        shellPin(button, to: self)
    }
    required init?(coder: NSCoder) { nil }

    @objc private func showMenu() { makeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height), in: self) }

    func makeMenu(side: Workspace.Side = .right) -> NSMenu {
        let menu = NSMenu()
        guard let workspace else { return menu }
        let terminal = NSMenuItem(title: "Terminal", action: nil, keyEquivalent: "")
        let destinations = NSMenu()
        destinations.addItem(ShellMenuItem("Local") { [weak self] in workspace.addPane(kind: .terminal, side: side); self?.onCreate?() })
        for record in DroneStore.shared.records {
            destinations.addItem(ShellMenuItem(record.name, enabledWhen: { DroneStore.shared.states[record.id]?.isConnected == true }) { [weak self] in
                workspace.addPane(kind: .terminal, side: side, terminalDestination: .drone(droneID: record.id, name: record.name))
                self?.onCreate?()
            })
        }
        terminal.submenu = destinations; menu.addItem(terminal)
        let browser = NSMenuItem(title: "Browser", action: nil, keyEquivalent: "")
        let engines = NSMenu()
        for engine in BrowserEngine.allCases {
            engines.addItem(ShellMenuItem(engine.displayName, enabledWhen: {
                BrowserPaneCreationPolicy.permitsCreation(for: engine, chromiumCreationEnabled: ChromiumBrowserCreationPolicy.isCreationEnabled)
            }) { [weak self] in workspace.addBrowserPane(engine: engine, side: side); self?.onCreate?() })
        }
        if let reason = ChromiumBrowserCreationPolicy.unavailableReason {
            let item = NSMenuItem(title: reason.message, action: nil, keyEquivalent: "")
            item.isEnabled = false; engines.addItem(item)
        }
        browser.submenu = engines; menu.addItem(browser)
        menu.addItem(ShellMenuItem("Apple Simulator") { [weak self] in workspace.addPane(kind: .simulator, side: side); self?.onCreate?() })
        menu.addItem(ShellMenuItem("Apple Device Stream") { [weak self] in workspace.addPane(kind: .device, side: side); self?.onCreate?() })
        for (title, target) in [("Android Simulator", AndroidPaneTarget.simulator), ("Android Device", AndroidPaneTarget.device)] {
            menu.addItem(ShellMenuItem(title) { [weak self] in
                let pane = workspace.addPane(kind: .android, side: side)
                AndroidDeviceRegistry.shared.configure(target: target, for: pane.id)
                self?.onCreate?()
            })
        }
        let agents = NSMenuItem(title: "Agent Chat", action: nil, keyEquivalent: "")
        let agentMenu = NSMenu()
        for agent in ChatAgent.allCases {
            agentMenu.addItem(ShellMenuItem(agent.displayName, enabledWhen: { workspace.effectiveRootPath != nil }) { [weak self] in
                let pane = workspace.addPane(kind: .agentChat, side: side)
                AgentChatPaneStore.setAgent(agent, for: pane.id)
                self?.onCreate?()
            })
        }
        agents.submenu = agentMenu; menu.addItem(agents)
        menu.addItem(ShellMenuItem("Editor", enabledWhen: { workspace.effectiveRootPath != nil }) { [weak self] in workspace.addPane(kind: .editor, side: side); self?.onCreate?() })
        menu.addItem(.separator())
        menu.addItem(ShellMenuItem("Open in Finder", enabledWhen: { workspace.effectiveRootPath != nil }) {
            if let path = workspace.effectiveRootPath { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        })
        return menu
    }
}
