import SwiftUI

/// Scene-local browser selection used by menu commands. Revealing a browser
/// preserves focused-pane mode by moving that focus to the browser instead of
/// leaving `focusedPaneID` attached to a hidden pane.
@MainActor
enum BrowserCommandSelection {
    static func selectedState(
        in workspace: Workspace?,
        supporting capability: BrowserCapability? = nil
    ) -> BrowserState? {
        guard let state = BrowserToolbarSelection.state(for: workspace?.selectedPane) else {
            return nil
        }
        if let capability, !state.supports(capability) {
            return nil
        }
        return state
    }

    static func hasBrowser(
        in workspace: Workspace?,
        supporting capability: BrowserCapability? = nil
    ) -> Bool {
        workspace?.panes.contains { pane in
            guard pane.kind == .browser,
                  let state = pane.browserState else { return false }
            return capability.map(state.supports) ?? true
        } ?? false
    }

    @discardableResult
    static func revealBrowser(
        in workspace: Workspace?,
        supporting capability: BrowserCapability? = nil
    ) -> BrowserState? {
        guard let workspace else { return nil }

        func isEligible(_ pane: Pane) -> Bool {
            guard pane.kind == .browser,
                  let state = pane.browserState else { return false }
            return capability.map(state.supports) ?? true
        }

        let browser: Pane
        if let selectedPane = workspace.selectedPane,
           isEligible(selectedPane) {
            browser = selectedPane
        } else if let firstBrowser = workspace.sortedPanes.first(where: isEligible) {
            browser = firstBrowser
        } else {
            return nil
        }

        if let focusedPaneID = workspace.focusedPaneID,
           focusedPaneID != browser.id {
            workspace.focusPane(browser)
        } else {
            workspace.expandPane(browser)
            workspace.selectedPaneID = browser.id
        }
        return BrowserToolbarSelection.state(for: browser)
    }
}

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
                        _ = await PersistentTerminalSession.runFastCommand(
                            selectedTerminalFastCommand.command,
                            sessionName: selectedTerminalFastCommand.pane.persistentSessionName
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
