import SwiftUI

/// View-menu mode toggles (Inspector, Notes, Remote Desktop, Docker) and pane
/// focus. These intentionally follow the main window's selected workspace.
struct PilotViewCommands: Commands {
    let store: WorkspaceStore

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(store.selectedWorkspace?.isInspectorPresented == true ? "Hide Inspector" : "Show Inspector") {
                guard let workspace = store.selectedWorkspace else { return }
                workspace.setInspectorPresented(!workspace.isInspectorPresented)
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(store.selectedWorkspace == nil)

            Button(store.isNotesMode ? "Hide Notes" : "Show Notes") {
                store.toggleNotesMode()
            }
            .keyboardShortcut("0", modifiers: .command)

            Button(store.isRemoteDesktopMode ? "Hide Remote Desktop" : "Show Remote Desktop") {
                store.toggleRemoteDesktopMode()
            }
            .keyboardShortcut("0", modifiers: [.command, .shift])

            Button(store.isDockerMode ? "Hide Docker" : "Show Docker") {
                store.toggleDockerMode()
            }
            .keyboardShortcut("0", modifiers: [.command, .control])

            Button("Focus Selected Pane") {
                guard let workspace = store.selectedWorkspace,
                      let pane = workspace.selectedPane else { return }
                workspace.focusPane(pane)
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(store.selectedWorkspace?.selectedPane == nil)
        }
    }
}

/// Text-size commands. The zoom value is owned by `PilotApp`'s `ui.zoom`
/// storage, which also feeds the `uiZoom` environment and Ghostty.
struct PilotTextSizeCommands: Commands {
    @Binding var uiZoom: Double

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Increase Text Size") {
                uiZoom = UIZoomLadder.next(after: uiZoom)
            }
            .keyboardShortcut("=", modifiers: .command)

            Button("Decrease Text Size") {
                uiZoom = UIZoomLadder.previous(before: uiZoom)
            }
            .keyboardShortcut("-", modifiers: .command)

            Button("Actual Size") {
                uiZoom = UIZoomLadder.default
            }
            .keyboardShortcut("0", modifiers: [.command, .option])
        }
    }
}
