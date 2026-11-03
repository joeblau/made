import SwiftUI

/// Browser menu commands follow the key scene's focused Workspace. Main and
/// Extension publish their own workspace with `focusedSceneValue`, preventing
/// shortcuts in one window from reloading, annotating, or selecting a browser
/// in the other.
struct PilotBrowserCommands: Commands {
    @FocusedValue(Workspace.self) private var workspace
    let isMobileDeviceConnected: Bool

    var body: some Commands {
        CommandMenu("Browser") {
            Button(primaryCommandTitle) {
                if let selectedReloadableBrowserState {
                    selectedReloadableBrowserState.perform(.reload)
                } else if let selectedTerminalFastCommand {
                    Task {
                        _ = await selectedTerminalFastCommand.pane.terminalSession.runFastCommand(
                            selectedTerminalFastCommand.command
                        )
                    }
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(selectedReloadableBrowserState == nil && selectedTerminalFastCommand == nil)

            Button("Focus Address Bar") {
                BrowserCommandSelection.revealBrowser(
                    in: workspace,
                    supporting: .addressFocus
                )?.perform(.focusAddress)
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(!hasBrowserPane)

            Button(selectedAnnotatableBrowserState?.annotateMode == true ? "Turn Off Lasso" : "Turn On Lasso") {
                selectedAnnotatableBrowserState?.perform(.toggleAnnotation)
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(selectedAnnotatableBrowserState == nil)

            Divider()

            Button("Debug Mobile App in Browser") {
                SafariWebInspector.open()
            }
            .keyboardShortcut("d", modifiers: [.command, .option])
            .disabled(!isMobileDeviceConnected)
        }
    }

    private var selectedReloadableBrowserState: BrowserState? {
        BrowserCommandSelection.selectedState(in: workspace, supporting: .navigation)
    }

    private var selectedAnnotatableBrowserState: BrowserState? {
        BrowserCommandSelection.selectedState(in: workspace, supporting: .annotation)
    }

    private var selectedTerminalFastCommand: (pane: Pane, command: String)? {
        guard let pane = TerminalToolbarSelection.pane(for: workspace?.selectedPane),
              let command = TerminalFastCommandStore.executableCommand(
                  from: TerminalFastCommandStore.command(for: pane.id)
              ) else {
            return nil
        }
        return (pane, command)
    }

    private var primaryCommandTitle: String {
        selectedTerminalFastCommand == nil ? "Reload" : "Run Fast Command"
    }

    private var hasBrowserPane: Bool {
        BrowserCommandSelection.hasBrowser(in: workspace, supporting: .addressFocus)
    }
}

/// New Terminal / New Browser follow the key scene's focused Workspace, so the
/// shortcut adds a pane to whichever window — main or Extension — is key. They
/// previously targeted `store.selectedWorkspace` (always the main window), so
/// pressing ⌘T/⌘B while the Extension window was key added a hidden pane to the
/// main workspace and looked broken. Main and Extension publish their workspace
/// with `focusedSceneValue`; a nil value (notes/remote-desktop mode, or no
/// selection) disables the commands.
struct PilotPaneCreationCommands: Commands {
    @FocusedValue(Workspace.self) private var workspace
    private let droneStore = DroneStore.shared
    @ObservedObject private var chromiumDiagnostics = ChromiumDiagnosticsCenter.shared
    @ObservedObject private var chromiumProfileAccess =
        ChromiumProfileAccessCoordinator.shared

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Terminal") {
                workspace?.addPane(kind: .terminal, side: .right)
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(workspace == nil)

            Menu("New Terminal on Drone") {
                ForEach(droneStore.records) { record in
                    Button(record.name) {
                        workspace?.addPane(
                            kind: .terminal,
                            side: .right,
                            terminalDestination: .drone(droneID: record.id, name: record.name)
                        )
                    }
                    .disabled(droneStore.states[record.id]?.isConnected != true)
                }
            }
            .disabled(workspace == nil || droneStore.records.isEmpty)

            Button("New Browser") {
                workspace?.addBrowserPane(engine: .webKit, side: .right)
            }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(workspace == nil)

            Button("New Chromium Browser") {
                workspace?.addBrowserPane(engine: .chromium, side: .right)
            }
            .disabled(
                workspace == nil
                    || !chromiumCreationEnabled
            )
        }
    }

    private var chromiumCreationEnabled: Bool {
        _ = chromiumDiagnostics.runtimeStatus
        _ = chromiumProfileAccess.isClearing
        return BrowserPaneCreationPolicy.permitsCreation(
            for: .chromium,
            chromiumCreationEnabled:
                ChromiumBrowserCreationPolicy.isCreationEnabled
        )
    }
}

/// Pane navigation follows the key window's workspace, including Extendo.
/// Menu commands also remain reachable when a terminal or browser has focus.
struct PilotPaneNavigationCommands: Commands {
    @FocusedValue(Workspace.self) private var workspace

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Previous Panel") {
                workspace?.selectPreviousPane()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled((workspace?.panes.count ?? 0) < 2)

            Button("Next Panel") {
                workspace?.selectNextPane()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled((workspace?.panes.count ?? 0) < 2)
        }
    }
}
