import SwiftUI

struct TabItemContent: View {
    let pane: Pane
    let isSelected: Bool
    let isHovering: Bool
    let isWorkspaceActive: Bool
    let canClose: Bool
    let onClose: () -> Void
    let onHide: () -> Void
    let onUnhide: () -> Void

    var body: some View {
        if pane.isCollapsed {
            collapsedContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            expandedContent
        }
    }

    @ViewBuilder
    private var collapsedContent: some View {
        if pane.kind == .terminal {
            headerButton(systemName: "eye", help: "Show Terminal. Hidden terminals keep running.", action: onUnhide)
        } else if pane.kind == .browser, let state = pane.browserState {
            Button(action: onUnhide) {
                BrowserFaviconView(state: state)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help("Unhide \(pane.displayTitle)")
            .accessibilityLabel("Unhide \(pane.displayTitle)")
        } else {
            headerButton(systemName: "eye", help: "Unhide \(paneTitle)", action: onUnhide)
        }
    }

    private var expandedContent: some View {
        HStack(spacing: 6) {
            if isHovering && canClose {
                headerButton(systemName: "xmark", help: "Close \(paneTitle)", action: onClose)
                    .background(.white.opacity(0.1), in: Circle())
                    .transition(.opacity)
            }

            Image(systemName: pane.kind.systemImageName)
                .scaledFont(size: 11)
                .foregroundStyle(isSelected ? .primary : .secondary)

            Text(pane.displayTitle)
                .scaledFont(size: 12)
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)

            if pane.kind == .terminal {
                TerminalAgentBadge(pane: pane, isWorkspaceActive: isWorkspaceActive)
                TerminalDirtyBadge(pane: pane, isWorkspaceActive: isWorkspaceActive)
            }

            Spacer(minLength: 0)

            if isHovering {
                headerButton(systemName: "eye.slash", help: "Hide \(paneTitle)", action: onHide)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
    }

    private var paneTitle: String {
        pane.kind.displayName
    }

    private func headerButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .scaledFont(size: 9, weight: .bold)
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Accent capsule naming the coding agent (Claude, Codex, …) currently open in
/// a terminal pane, shown right after "Terminal". Polls the shell's process tree
/// every couple of seconds while its workspace is active and the app is
/// frontmost; renders nothing when no supported agent is open.
private struct TerminalAgentBadge: View {
    let pane: Pane
    let isWorkspaceActive: Bool
    @State private var isApplicationActive = true
    @State private var agent: TerminalAgent?

    var body: some View {
        Group {
            if let agent {
                Text(agent.displayName)
                    .scaledFont(size: 10, weight: .semibold)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .help("\(agent.displayName) is open in this terminal")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: agent)
        .observingApplicationActivity($isApplicationActive)
        // Restart polling when activation flips; only the visible workspace of
        // the frontmost app polls.
        .task(id: isWorkspaceActive && isApplicationActive) {
            guard isWorkspaceActive, isApplicationActive else { return }
            while !Task.isCancelled {
                agent = pane.liveShellAgent()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

/// "Clean" / "Dirty" word shown after "Terminal" in a terminal tab header,
/// reflecting whether the shell's current directory sits in a git work tree with
/// uncommitted changes. Polls `git status` every few seconds while its workspace
/// is active and the app is frontmost (it reads the shell's live cwd, so it
/// tracks `cd` and file edits); panes sharing a cwd share one subprocess via
/// GitDirtyStateCache. Renders nothing when the directory isn't a git repo.
private struct TerminalDirtyBadge: View {
    let pane: Pane
    let isWorkspaceActive: Bool
    @State private var isApplicationActive = true
    @State private var isDirty: Bool?

    var body: some View {
        Group {
            if let isDirty {
                Text(isDirty ? "Dirty" : "Clean")
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundStyle(isDirty ? Color.orange : Color.green)
            }
        }
        .observingApplicationActivity($isApplicationActive)
        // Restart polling when activation flips; only the visible workspace of
        // the frontmost app polls.
        .task(id: isWorkspaceActive && isApplicationActive) {
            guard isWorkspaceActive, isApplicationActive else { return }
            while !Task.isCancelled {
                let directory = pane.liveShellCurrentDirectory() ?? pane.currentDirectory
                let status: Bool? = directory.isEmpty
                    ? nil
                    : await GitDirtyStateCache.shared.isDirty(directory: directory)
                if Task.isCancelled { break }
                isDirty = status
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

/// Mirrors NSApplication's active state into `isActive` so polling badges stop
/// forking subprocesses while the app is backgrounded — the same activation
/// signal RepositoryPollingEnvironmentMonitor feeds the gh polling scheduler.
private extension View {
    @MainActor
    func observingApplicationActivity(_ isActive: Binding<Bool>) -> some View {
        self
            .onAppear { isActive.wrappedValue = NSApplication.shared.isActive }
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )) { _ in isActive.wrappedValue = true }
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didResignActiveNotification
            )) { _ in isActive.wrappedValue = false }
    }
}
