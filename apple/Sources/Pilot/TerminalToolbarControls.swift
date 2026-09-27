import AppKit
import SwiftUI

enum TerminalToolbarSelection {
    static func pane(for pane: Pane?) -> Pane? {
        guard let pane,
              !pane.isCollapsed,
              pane.kind == .terminal else { return nil }
        return pane
    }
}

/// Per-terminal address-style command field. Actions are installed as separate
/// toolbar items so Play and Stop do not sit inside the field's capsule.
struct TerminalFastCommandToolbarField: View {
    let pane: Pane

    @State private var command: String

    init(pane: Pane) {
        self.pane = pane
        // Local state is the editing source of truth. Backing the field with
        // @AppStorage looped every keystroke's UserDefaults write back into a
        // re-render of the toolbar-hosted field — the visible flash while
        // typing. Persist through the store instead; observers of the key
        // (Play button, collapsed-pane slit) still update live.
        _command = State(
            wrappedValue: TerminalFastCommandStore.command(for: pane.id)
        )
    }

    var body: some View {
        TextField("Fast Command", text: $command)
            .textFieldStyle(.plain)
            .scaledFont(size: 13, weight: .medium, design: .monospaced)
            .onSubmit(run)
            .onChange(of: command) { _, newValue in
                TerminalFastCommandStore.setCommand(newValue, for: pane.id)
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 220, idealWidth: 360, maxWidth: 480)
            .layoutPriority(1)
            .accessibilityIdentifier("terminal.fast-command")
    }

    private func run() {
        guard let command = TerminalFastCommandStore.executableCommand(from: command) else {
            return
        }
        Task {
            _ = await PersistentTerminalSession.runFastCommand(
                command,
                sessionName: pane.persistentSessionName
            )
        }
    }
}

struct TerminalFastCommandToolbarActions: View {
    let pane: Pane

    @AppStorage private var command: String
    @State private var activeAction: Action?
    @State private var activity: TerminalProcessActivity = .idle

    private enum Action {
        case play
        case stop
    }

    init(pane: Pane) {
        self.pane = pane
        _command = AppStorage(
            wrappedValue: "",
            TerminalFastCommandStore.preferenceKey(for: pane.id)
        )
    }

    var body: some View {
        ControlGroup {
            Button(action: run) {
                actionLabel(for: .play, systemImage: "play.fill")
            }
            .disabled(activeAction != nil || executableCommand == nil)
            .help("Stop the active process and run this command")
            .accessibilityIdentifier("terminal.fast-command.play")

            Button(action: stop) {
                actionLabel(for: .stop, systemImage: "stop.fill")
            }
            // Nothing to stop when the terminal sits at a shell prompt.
            .disabled(activeAction != nil || activity != .running)
            .help("Stop the active terminal process")
            .accessibilityIdentifier("terminal.fast-command.stop")
        }
        .controlGroupStyle(.navigation)
        .task(id: pane.id) {
            let sessionName = pane.persistentSessionName
            while !Task.isCancelled {
                activity = await PersistentTerminalSession.foregroundActivity(sessionName: sessionName)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @ViewBuilder
    private func actionLabel(for action: Action, systemImage: String) -> some View {
        if activeAction == action {
            ProgressView()
                .controlSize(.small)
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: systemImage)
                .frame(width: 14, height: 14)
        }
    }

    private var executableCommand: String? {
        TerminalFastCommandStore.executableCommand(from: command)
    }

    private func run() {
        guard activeAction == nil, let executableCommand else { return }
        activeAction = .play
        Task {
            _ = await PersistentTerminalSession.runFastCommand(
                executableCommand,
                sessionName: pane.persistentSessionName
            )
            activeAction = nil
        }
    }

    private func stop() {
        guard activeAction == nil else { return }
        activeAction = .stop
        Task {
            _ = await PersistentTerminalSession.stopForegroundCommand(
                sessionName: pane.persistentSessionName
            )
            activeAction = nil
        }
    }
}

/// All destructive terminal UI actions pass through this gate. Check tmux at
/// close time rather than relying on the periodically refreshed tab indicator.
@MainActor
enum TerminalCloseConfirmation {
    private static var pendingPaneIDs: Set<UUID> = []

    static func perform(
        panes: [Pane],
        activity: @MainActor (String) async -> TerminalProcessActivity = {
            // If runtime state cannot be verified, ask before destroying it.
            await PersistentTerminalSession.foregroundActivity(sessionName: $0, unavailableActivity: .running)
        },
        confirm: @MainActor ([Pane]) async -> Bool = { await present(for: $0) },
        action: @MainActor () -> Void
    ) async {
        let terminals = panes.filter { $0.kind == .terminal }
        let ids = Set(terminals.map(\.id))
        guard pendingPaneIDs.isDisjoint(with: ids) else { return }
        pendingPaneIDs.formUnion(ids)
        defer { pendingPaneIDs.subtract(ids) }

        var busy: [Pane] = []
        for pane in terminals {
            if await activity(pane.persistentSessionName) == .running {
                busy.append(pane)
            }
        }
        guard !Task.isCancelled else { return }
        if !busy.isEmpty {
            guard await confirm(busy), !Task.isCancelled else { return }
        }
        action()
    }

    private static func present(for panes: [Pane]) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = panes.count == 1 ? "Close busy terminal?" : "Close busy terminals?"
        alert.informativeText = "Closing will terminate running commands or AI sessions in "
            + (panes.count == 1 ? "this terminal." : "\(panes.count) terminals.")
            + " Any work in progress may be lost."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Close Anyway")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].hasDestructiveAction = true
        if let window = NSApp.keyWindow {
            return await alert.beginSheetModal(for: window) == .alertSecondButtonReturn
        }
        return alert.runModal() == .alertSecondButtonReturn
    }
}

extension Workspace {
    @MainActor
    func requestRemovePane(_ pane: Pane) {
        guard panes.count > 1, panes.contains(where: { $0 === pane }) else { return }
        Task {
            await TerminalCloseConfirmation.perform(panes: [pane]) {
                // The user can change workspaces or move panes while the
                // activity check or confirmation sheet is pending.
                guard self.panes.contains(where: { $0 === pane }) else { return }
                self.removePane(pane)
            }
        }
    }
}
