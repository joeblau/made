import AppKit
import SwiftUI

/// The connected pane launcher shared by Pilot's main and extension windows.
/// Supplying the owning workspace lets Extension reuse the exact controls while
/// keeping independent runtime IDs for every terminal, browser, and device.
struct WorkspacePaneLauncher: View {
    let workspace: Workspace?

    @ObservedObject private var chromiumDiagnostics = ChromiumDiagnosticsCenter.shared
    @ObservedObject private var chromiumProfileAccess =
        ChromiumProfileAccessCoordinator.shared

    /// Launcher slot size; the capsule is one slot tall.
    fileprivate static let slotSize: CGFloat = 36
    /// Inset of the hover circle inside a slot. The capsule's end radius is
    /// half a slot, so a circle inset by this on every side, with the same
    /// horizontal padding, nests concentrically (LAY-4).
    fileprivate static let highlightInset: CGFloat = 2

    var body: some View {
        HStack(spacing: 0) {
            paneButtons
        }
        // Slots stay unglazed inside the one glass capsule (no glass on
        // glass); each gets a circular hover wash and press feedback (BTN-5).
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        .padding(.horizontal, Self.highlightInset)
        // Not `.interactive()`: the capsule is a container for the slots, not
        // a control, so a click on one slot should not flex the whole cluster.
        .compatGlassEffect(in: Capsule())
        .disabled(workspace == nil)
        .accessibilityIdentifier("workspace.pane-launcher")
    }

    @ViewBuilder
    private var paneButtons: some View {
        Button {
            workspace?.addPane(kind: .terminal, side: .right)
        } label: {
            launcherLabel("New Terminal", systemImage: PaneKind.terminal.systemImageName)
        }
        .launcherSlot()

        // No `primaryAction`: clicking opens the engine chooser rather than
        // silently picking WebKit, matching the Apple and Android buttons beside
        // it. ⌘B still opens a WebKit browser directly from the main menu.
        Menu {
            ForEach(BrowserEngine.allCases, id: \.self) { engine in
                Button {
                    addBrowserPane(engine: engine)
                } label: {
                    Label("\(engine.displayName) Browser", systemImage: engine.systemImageName)
                }
                .disabled(!browserCreationEnabled(for: engine))
            }

            // A greyed-out Chromium row is otherwise unexplained, and the three
            // causes need different answers — most often nothing is wrong at all,
            // just a build that deliberately ships without the CEF runtime.
            if let reason = chromiumUnavailableReason {
                Section {
                    Text(reason.message)
                }
            }
        } label: {
            launcherLabel("New Browser", systemImage: BrowserEngine.webKit.systemImageName)
        }
        .menuIndicator(.hidden)
        .launcherSlot()
        .help("Open a browser pane — choose WebKit or Chromium")
        .accessibilityIdentifier("workspace.browser-pane-launcher")

        Menu {
            Button {
                workspace?.addPane(kind: .simulator, side: .right)
            } label: {
                Label("Simulator", systemImage: PaneKind.simulator.systemImageName)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Button {
                workspace?.addPane(kind: .device, side: .right)
            } label: {
                Label("Device Stream", systemImage: PaneKind.device.systemImageName)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
        } label: {
            launcherLabel("Apple", systemImage: "apple.logo")
        }
        .menuIndicator(.hidden)
        .launcherSlot()
        .help("Open an Apple Simulator or QuickTime device stream")
        .accessibilityIdentifier("workspace.apple-pane-launcher")

        Menu {
            Button {
                addAndroidPane(target: .simulator)
            } label: {
                Label("Android Simulator", systemImage: "apps.iphone")
            }

            Button {
                addAndroidPane(target: .device)
            } label: {
                Label("Android Device", systemImage: "smartphone")
            }
        } label: {
            launcherLabel("Android") {
                Image("AndroidRobot")
            }
        }
        .menuIndicator(.hidden)
        .launcherSlot()
        .help("Open an Android Simulator or device stream")
        .accessibilityIdentifier("workspace.android-pane-launcher")

        Button {
            workspace?.addPane(kind: .editor, side: .right)
        } label: {
            launcherLabel("Open Editor", systemImage: PaneKind.editor.systemImageName)
        }
        .launcherSlot()
        .keyboardShortcut("e", modifiers: .command)
        .disabled(workspace?.effectiveRootPath == nil)
        .help(
            workspace?.effectiveRootPath == nil
                ? "Set a workspace root path to open the editor"
                : "Open a file editor with fuzzy file search"
        )

        Button {
            if let rootPath = workspace?.effectiveRootPath {
                NSWorkspace.shared.open(URL(fileURLWithPath: rootPath))
            }
        } label: {
            launcherLabel("Open in Finder", systemImage: "folder")
        }
        .launcherSlot()
        .disabled(workspace?.effectiveRootPath == nil)
        .help(
            workspace?.effectiveRootPath == nil
                ? "Set a workspace root path to open it in Finder"
                : "Open the workspace folder in Finder"
        )
    }

    private func addAndroidPane(target: AndroidPaneTarget) {
        guard let pane = workspace?.addPane(kind: .android, side: .right) else { return }
        AndroidDeviceRegistry.shared.configure(target: target, for: pane.id)
    }

    private func addBrowserPane(engine: BrowserEngine) {
        workspace?.addBrowserPane(engine: engine, side: .right)
    }

    private var chromiumUnavailableReason: ChromiumUnavailableReason? {
        _ = chromiumDiagnostics.runtimeStatus
        _ = chromiumProfileAccess.isClearing
        return ChromiumBrowserCreationPolicy.unavailableReason
    }

    private func browserCreationEnabled(for engine: BrowserEngine) -> Bool {
        _ = chromiumDiagnostics.runtimeStatus
        _ = chromiumProfileAccess.isClearing
        return BrowserPaneCreationPolicy.permitsCreation(
            for: engine,
            chromiumCreationEnabled:
                ChromiumBrowserCreationPolicy.isCreationEnabled
        )
    }

    private func launcherLabel(_ title: String, systemImage: String) -> some View {
        launcherLabel(title) {
            Image(systemName: systemImage)
        }
    }

    private func launcherLabel<Icon: View>(
        _ title: String,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        Label {
            Text(title)
        } icon: {
            icon()
        }
        .labelStyle(.iconOnly)
        .frame(width: Self.slotSize, height: Self.slotSize)
        .contentShape(Rectangle())
    }
}

private extension View {
    /// Sizes one launcher slot and adds its hover wash. Applied to the
    /// Button or Menu itself, not its label: macOS flattens menu labels to a
    /// title and image, so a label background would never draw for menus.
    func launcherSlot() -> some View {
        frame(width: WorkspacePaneLauncher.slotSize, height: WorkspacePaneLauncher.slotSize)
            .modifier(LauncherSlotHover())
    }
}

/// Circular hover wash for one launcher slot. Works for both the plain
/// buttons and the borderless menus, so every slot responds the same way.
private struct LauncherSlotHover: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background {
                Circle()
                    .fill(.fill.tertiary)
                    .padding(WorkspacePaneLauncher.highlightInset)
                    .opacity(isHovered && isEnabled ? 1 : 0)
            }
            .onHover { isHovered = $0 }
            .animation(LiquidGlassMetrics.stateChange, value: isHovered)
    }
}
