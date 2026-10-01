import SwiftUI

/// New Terminal / New Browser follow the key scene's focused Workspace, so the
/// shortcut adds a pane to whichever window — main or Extension — is key. They
/// previously targeted `store.selectedWorkspace` (always the main window), so
/// pressing ⌘T/⌘B while the Extension window was key added a hidden pane to the
/// main workspace and looked broken. Main and Extension publish their workspace
/// with `focusedSceneValue`; a nil value (notes/remote-desktop mode, or no
/// selection) disables the commands.
struct PilotPaneCreationCommands: Commands {
    @FocusedValue(Workspace.self) private var workspace
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
