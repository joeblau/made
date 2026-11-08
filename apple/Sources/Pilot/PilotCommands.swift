import AppKit
import Observation

/// A single native menu routes every command through the window that owns the
/// active pane. The responder chain continues to own text editing and Undo.
@MainActor
final class CockpitMenuController: NSObject, NSMenuDelegate {
    var copyAction: (() -> Void)?
    var pasteAction: (() -> Void)?
    var cutAction: (() -> Void)?
    var canCheckForUpdates: () -> Bool = { true }
    var isMobileDeviceConnected: () -> Bool = { false }
    private let windowProvider: () -> CockpitWindowController?
    private let keyWindowProvider: () -> NSWindow?
    private let showMain: () -> Void
    private let toggleExtendo: () -> Void
    private let showSettings: () -> Void
    private let showSetup: () -> Void
    private let checkForUpdates: () -> Void
    private let sidebarVisibility: SidebarFeatureVisibility?
    private var featureItems: [SidebarFeature: NSMenuItem] = [:]
    private var visibilityGeneration = 0
    private weak var droneMenu: NSMenu?
    private weak var workspaceMenu: NSMenu?
    private weak var addLeftMenu: NSMenu?
    private weak var addRightMenu: NSMenu?

    init(windowProvider: @escaping () -> CockpitWindowController?,
         showMain: @escaping () -> Void, toggleExtendo: @escaping () -> Void,
         showSettings: @escaping () -> Void, showSetup: @escaping () -> Void,
         checkForUpdates: @escaping () -> Void, keyWindowProvider: @escaping () -> NSWindow? = { NSApp.keyWindow },
         sidebarVisibility: SidebarFeatureVisibility? = nil) {
        self.windowProvider = windowProvider
        self.keyWindowProvider = keyWindowProvider
        self.showMain = showMain
        self.toggleExtendo = toggleExtendo
        self.showSettings = showSettings
        self.showSetup = showSetup
        self.checkForUpdates = checkForUpdates
        self.sidebarVisibility = sidebarVisibility
        super.init()
    }

    func install() {
        let main = NSMenu()
        let app = submenu("Cockpit", in: main)
        app.addItem(ShellMenuItem("About Cockpit") { NSApp.orderFrontStandardAboutPanel(nil) })
        app.addItem(ShellMenuItem("Check for Updates…", enabledWhen: { [weak self] in self?.canCheckForUpdates() ?? false }, perform: checkForUpdates))
        app.addItem(ShellMenuItem("Setup…", perform: showSetup))
        app.addItem(.separator())
        app.addItem(ShellMenuItem("Settings…", key: ",", perform: showSettings))
        let services = submenu("Services", in: app)
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(responder("Hide Cockpit", #selector(NSApplication.hide(_:)), key: "h"))
        app.addItem(responder("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option]))
        app.addItem(responder("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(.separator())
        app.addItem(responder("Quit Cockpit", #selector(NSApplication.terminate(_:)), key: "q"))

        let file = submenu("File", in: main)
        file.addItem(ShellMenuItem("Show Main Window", key: "n", perform: showMain))
        file.addItem(command("New Workspace…", key: "n", modifiers: [.command, .shift]) { $0.presentNewWorkspace() })
        file.addItem(command("New Workspace Group…") { $0.presentNewGroup() })
        file.addItem(.separator())
        file.addItem(command("New Tab", key: "t", requiresWorkspace: true) {
            $0.selectedWorkspace?.addPane(kind: .terminal, side: .right, chooseModeOnOpen: true)
            $0.refresh(); $0.focusSelectedPane()
        })
        let drones = submenu("New Terminal on Drone", in: file)
        droneMenu = drones; drones.delegate = self
        file.addItem(responder("Open…", Selector(("openDocument:")), key: "o"))
        file.addItem(responder("Save", Selector(("saveDocument:")), key: "s"))
        file.addItem(.separator())
        file.addItem(ShellMenuItem("Close Tab", key: "w", enabledWhen: { [weak self] in
            if let window = self?.windowProvider() { return window.canCloseSelectedPane }
            return self?.keyWindowProvider()?.styleMask.contains(.closable) == true
        }) { [weak self] in
            if let window = self?.windowProvider() { window.closeSelectedPane() } else { self?.keyWindowProvider()?.performClose(nil) }
        })
        file.addItem(ShellMenuItem("Close Window", key: "w", modifiers: [.command, .shift], enabledWhen: { [weak self] in self?.keyWindowProvider() != nil }) { [weak self] in self?.keyWindowProvider()?.performClose(nil) })
        file.addItem(ShellMenuItem("Close All Windows", key: "w", modifiers: [.command, .option, .shift]) {
            for window in NSApp.windows where window.isVisible && window.styleMask.contains(.closable) { window.performClose(nil) }
        })

        let edit = submenu("Edit", in: main)
        edit.addItem(responder("Undo", Selector(("undo:")), key: "z"))
        edit.addItem(responder("Redo", Selector(("redo:")), key: "z", modifiers: [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(ShellMenuItem("Cut", key: "x") { [weak self] in
            if let action = self?.cutAction { action() } else { NSApp.sendAction(Selector(("cut:")), to: nil, from: nil) }
        })
        edit.addItem(ShellMenuItem("Copy", key: "c") { [weak self] in
            if let action = self?.copyAction { action() } else { NSApp.sendAction(Selector(("copy:")), to: nil, from: nil) }
        })
        edit.addItem(ShellMenuItem("Paste", key: "v") { [weak self] in
            if let action = self?.pasteAction { action() } else { NSApp.sendAction(Selector(("paste:")), to: nil, from: nil) }
        })
        edit.addItem(responder("Select All", Selector(("selectAll:")), key: "a"))
        edit.addItem(.separator())
        edit.addItem(ShellMenuItem("Find… / Focus Selected Pane", key: "f", enabledWhen: { [weak self] in
            self?.windowProvider()?.selectedPane != nil || NSApp.target(forAction: Selector(("showFindPanel:"))) != nil
        }) { [weak self] in self?.find() })
        edit.addItem(ShellMenuItem("Find Next", key: "g") { [weak self] in self?.findAgain(forward: true) })
        edit.addItem(ShellMenuItem("Find Previous", key: "g", modifiers: [.command, .shift]) { [weak self] in self?.findAgain(forward: false) })
        edit.addItem(responder("Use Selection for Find", Selector(("useSelectionForFind:")), key: "e"))

        let view = submenu("View", in: main)
        view.addItem(command("Toggle Sidebar", key: "s", modifiers: [.command, .control]) { $0.toggleSidebar() })
        view.addItem(command("Toggle Inspector", key: "i", requiresWorkspace: true) { $0.toggleInspector() })
        for feature in SidebarFeature.allCases {
            let (key, modifiers) = Self.shortcut(for: feature)
            let item = command("Toggle " + feature.title, key: key, modifiers: modifiers) { $0.store.toggleMode(feature); $0.refresh() }
            featureItems[feature] = item
            view.addItem(item)
        }
        observeSidebarVisibility()
        view.addItem(.separator())
        let layout = submenu("Layout", in: view)
        layout.addItem(command("Focus or Restore Selected Pane", requiresPane: true) { window in
            if let pane = window.selectedPane { window.selectedWorkspace?.focusPane(pane); window.refresh(); window.focusSelectedPane() }
        })
        layout.addItem(command("Hide Selected Pane", requiresPane: true) { window in
            if let pane = window.selectedPane { window.selectedWorkspace?.collapsePane(pane); window.refresh(); window.focusSelectedPane() }
        })
        let left = submenu("Add Pane on Left", in: layout)
        left.delegate = self; addLeftMenu = left
        let right = submenu("Add Pane on Right", in: layout)
        right.delegate = self; addRightMenu = right
        layout.addItem(.separator())
        layout.addItem(command("Arrange Panes Horizontally", requiresWorkspace: true) { window in
            window.selectedWorkspace?.axis = .vertical
            _ = window.selectedWorkspace?.modelContext?.saveReporting()
            window.refresh()
        })
        layout.addItem(command("Stack Panes Vertically", requiresWorkspace: true) { window in
            window.selectedWorkspace?.axis = .horizontal
            _ = window.selectedWorkspace?.modelContext?.saveReporting()
            window.refresh()
        })
        layout.addItem(command("Reset Pane Sizes", requiresWorkspace: true) { $0.selectedWorkspace?.resetPaneSizes(); $0.refresh() })
        view.addItem(command("Toggle Drawing", key: "d", modifiers: [.command, .shift], requiresWorkspace: true) { $0.toggleDrawing() })
        view.addItem(.separator())
        view.addItem(ShellMenuItem("Increase Text Size", key: "=") { CockpitUIZoomController.shared.increase() })
        view.addItem(ShellMenuItem("Decrease Text Size", key: "-") { CockpitUIZoomController.shared.decrease() })
        view.addItem(ShellMenuItem("Actual Size", key: "0", modifiers: [.command, .option]) { CockpitUIZoomController.shared.reset() })
        view.addItem(responder("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), key: "f", modifiers: [.command, .control]))

        let browser = submenu("Browser", in: main)
        browser.addItem(ShellMenuItem("Reload / Run Fast Command", key: "r", enabledWhen: { [weak self] in
            guard let self else { return false }
            return BrowserCommandSelection.selectedState(in: self.windowProvider()?.selectedWorkspace, supporting: .navigation) != nil || self.fastCommand != nil
        }) { [weak self] in self?.reloadOrRun() })
        browser.addItem(ShellMenuItem("Focus Address Bar", key: "l", enabledWhen: { [weak self] in
            BrowserCommandSelection.hasBrowser(in: self?.windowProvider()?.selectedWorkspace, supporting: .addressFocus)
        }) { [weak self] in
            guard let window = self?.windowProvider() else { return }
            let browser = BrowserCommandSelection.revealBrowser(in: window.selectedWorkspace, supporting: .addressFocus)
            window.refresh(); browser?.perform(.focusAddress)
        })
        browser.addItem(ShellMenuItem("Toggle Lasso", key: "a", modifiers: [.command, .shift], enabledWhen: { [weak self] in
            BrowserCommandSelection.selectedState(in: self?.windowProvider()?.selectedWorkspace, supporting: .annotation) != nil
        }) { [weak self] in BrowserCommandSelection.selectedState(in: self?.windowProvider()?.selectedWorkspace, supporting: .annotation)?.perform(.toggleAnnotation) })
        browser.addItem(.separator())
        browser.addItem(ShellMenuItem("Debug Mobile App in Browser", key: "d", modifiers: [.command, .option], enabledWhen: { [weak self] in self?.isMobileDeviceConnected() ?? false }) { SafariWebInspector.open() })

        let windows = submenu("Window", in: main)
        NSApp.windowsMenu = windows
        windows.addItem(ShellMenuItem("Show Main Window", perform: showMain))
        windows.addItem(ShellMenuItem("Toggle Extendo", key: "e", modifiers: [.command, .option], perform: toggleExtendo))
        windows.addItem(.separator())
        windows.addItem(responder("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        windows.addItem(responder("Zoom", #selector(NSWindow.performZoom(_:))))
        windows.addItem(.separator())
        windows.addItem(command("Previous Panel", key: "[", modifiers: [.command, .shift], requiresWorkspace: true) { $0.cyclePane(by: -1) })
        windows.addItem(command("Next Panel", key: "]", modifiers: [.command, .shift], requiresWorkspace: true) { $0.cyclePane(by: 1) })
        let workspaces = submenu("Workspaces", in: windows)
        workspaceMenu = workspaces; workspaces.delegate = self
        populateWorkspaceMenu(workspaces)
        NSApp.mainMenu = main
    }

    private static func shortcut(for feature: SidebarFeature) -> (String, NSEvent.ModifierFlags) {
        switch feature {
        case .notes: ("0", .command)
        case .remoteDesktop: ("0", [.command, .shift])
        case .docker: ("0", [.command, .control])
        case .agenticUse, .runners, .mockups: ("", .command)
        }
    }

    /// A hidden sidebar mode also loses its View menu toggle, and with it the
    /// keyboard shortcut; the store refuses to enter it from anywhere else.
    private func observeSidebarVisibility() {
        guard let sidebarVisibility else { return }
        visibilityGeneration += 1
        let generation = visibilityGeneration
        withObservationTracking {
            for (feature, item) in featureItems { item.isHidden = !sidebarVisibility.isVisible(feature) }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == self.visibilityGeneration else { return }
                self.observeSidebarVisibility()
            }
        }
    }

    private func submenu(_ title: String, in parent: NSMenu) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu; parent.addItem(item)
        return menu
    }
    private func responder(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
    private func command(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command,
                         requiresWorkspace: Bool = false, requiresPane: Bool = false, action: @escaping (CockpitWindowController) -> Void) -> NSMenuItem {
        ShellMenuItem(title, key: key, modifiers: modifiers, enabledWhen: { [weak self] in
            guard let window = self?.windowProvider() else { return false }
            return (!requiresWorkspace || window.selectedWorkspace != nil) && (!requiresPane || window.selectedPane != nil)
        }) { [weak self] in if let window = self?.windowProvider() { action(window) } }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === addLeftMenu || menu === addRightMenu {
            menu.removeAllItems()
            let launcher = WorkspacePaneLauncher(workspace: windowProvider()?.selectedWorkspace)
            let entries = launcher.makeMenu(side: menu === addLeftMenu ? .left : .right)
            let items = entries.items
            entries.removeAllItems()
            items.forEach(menu.addItem)
        }
        if menu === workspaceMenu { populateWorkspaceMenu(menu) }
        if menu === droneMenu {
            menu.removeAllItems()
            for record in DroneStore.shared.records {
                menu.addItem(ShellMenuItem(record.name, enabledWhen: { [weak self] in
                    self?.windowProvider()?.selectedWorkspace != nil && DroneStore.shared.states[record.id]?.isConnected == true
                }) { [weak self] in
                    guard let window = self?.windowProvider(), DroneStore.shared.states[record.id]?.isConnected == true else { return }
                    window.selectedWorkspace?.addPane(kind: .terminal, side: .right, terminalDestination: .drone(droneID: record.id, name: record.name))
                    window.refresh()
                })
            }
        }
    }
    private func populateWorkspaceMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        // Keep all nine shortcuts installed even before the first workspace is
        // created; actions always resolve against the current stable ordering.
        for index in 0..<9 {
            let workspaces = windowProvider()?.store.workspaces ?? []
            let title = index < workspaces.count ? workspaces[index].name : "Workspace \(index + 1)"
            menu.addItem(ShellMenuItem(title, key: String(index + 1), enabledWhen: { [weak self] in
                (self?.windowProvider()?.store.workspaces.count ?? 0) > index
            }) { [weak self] in
                guard let window = self?.windowProvider(), window.store.workspaces.indices.contains(index) else { return }
                window.select(.workspace(window.store.workspaces[index].id))
            })
        }
    }
    private var fastCommand: (Pane, String)? {
        guard let pane = TerminalToolbarSelection.pane(for: windowProvider()?.selectedPane),
              let command = TerminalFastCommandStore.executableCommand(from: TerminalFastCommandStore.command(for: pane.id)) else { return nil }
        return (pane, command)
    }
    private func reloadOrRun() {
        if let state = BrowserCommandSelection.selectedState(in: windowProvider()?.selectedWorkspace, supporting: .navigation) { state.perform(.reload) } else if let (pane, command) = fastCommand { Task { _ = await pane.terminalSession.runFastCommand(command) } }
    }
    private func find() {
        guard let window = windowProvider() else { _ = NSApp.sendAction(Selector(("showFindPanel:")), to: nil, from: nil); return }
        if let state = BrowserFindCommandTarget.state(for: window.selectedPane) { state.showFindBar(); return }
        if window.selectedPane?.kind == .editor {
            if let pane = window.selectedPane { NSApp.sendAction(Selector(("showFindPanel:")), to: window.paneController(for: pane), from: nil) }
        } else if window.selectedPane == nil {
            NSApp.sendAction(Selector(("showFindPanel:")), to: nil, from: nil)
        } else if let pane = window.selectedPane {
            window.selectedWorkspace?.focusPane(pane); window.refresh(); window.focusSelectedPane()
        }
    }
    private func findAgain(forward: Bool) {
        if let state = BrowserFindCommandTarget.state(for: windowProvider()?.selectedPane) { state.findAgain(forward: forward) } else { NSApp.sendAction(Selector(forward ? "findNext:" : "findPrevious:"), to: nil, from: nil) }
    }
}
