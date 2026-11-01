import AppKit
import Sparkle
import SwiftUI

struct SetupView: View {
    static let windowSize = CGSize(width: 900, height: 620)

    @Bindable var progress: SetupProgress
    let updater: SPUUpdater
    let onFinish: (URL?) -> Void
    var runsChecks = true

    @State private var permissions = SetupPermissions()
    @State private var tools = SetupTools()
    @State private var requesting: SetupPermission?
    @State private var enableCompanionsAfterProbe = false
    @State private var automaticUpdates = true
    @State private var copiedCommand: String?
    @State private var projectDirectory: URL?
    @AppStorage(SetupProgress.companionsKey) private var companionsEnabled = false
    @Namespace private var stepNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Step badge diameter; the sidebar row pill is concentric around it (LAY-4).
    private static let stepBadgeSide: CGFloat = 28

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.large) {
                        pageHeader
                        switch progress.step {
                        case .welcome: welcome
                        case .permissions: permissionRows
                        case .tools: toolRows
                        case .ready: summary
                        }
                    }
                    .padding(LiquidGlassMetrics.Spacing.xLarge)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Context transition: the frame stays, the page content
                    // cross-fades with an ease-out (MOT-1, MOT-4).
                    .animation(reduceMotion ? nil : LiquidGlassMetrics.stateChange, value: progress.step)
                }
                Divider()
                navigation
            }
        }
        .frame(
            minWidth: 820, idealWidth: Self.windowSize.width, maxWidth: Self.windowSize.width,
            minHeight: 560, idealHeight: Self.windowSize.height, maxHeight: Self.windowSize.height
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            guard runsChecks else { return }
            permissions.refresh()
            automaticUpdates = updater.automaticallyChecksForUpdates
        }
        .task(id: progress.step) {
            guard runsChecks else { return }
            if progress.step == .tools || progress.step == .ready { await tools.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard runsChecks else { return }
            permissions.refresh()
        }
        .onDisappear { permissions.stopProbe() }
        .onChange(of: permissions.access[.localNetwork]) { _, access in
            if access == .allowed && enableCompanionsAfterProbe {
                companionsEnabled = true
                enableCompanionsAfterProbe = false
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xLarge) {
            VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.small) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                Text("Cockpit").font(.title2.bold())
                Text("Your development environment,\nready for takeoff.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xxSmall) {
                ForEach(SetupStep.allCases) { step in
                    stepButton(step)
                }
            }
            // Rows carry a horizontal inset for their selection pill; pull the
            // stack back out so the step badges align with the header above.
            .padding(.horizontal, -LiquidGlassMetrics.Spacing.xSmall)
            .animation(reduceMotion ? nil : LiquidGlassMetrics.spring, value: progress.step)
            Spacer()
            Text("You can return to setup from the Cockpit menu at any time.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(LiquidGlassMetrics.Spacing.xLarge)
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(.quaternary.opacity(0.3))
    }

    /// A sidebar step row: a whole-row tap target, so it keeps a plain look
    /// with hover/press feedback (BTN-5) and a capsule selection pill that
    /// slides between steps (MOT-4). The pill is concentric with the step
    /// badge: radius = badge radius + inset (LAY-4).
    private func stepButton(_ step: SetupStep) -> some View {
        let isSelected = progress.step == step
        let inset = LiquidGlassMetrics.Spacing.xSmall
        let rowRadius = Self.stepBadgeSide / 2 + inset
        return Button {
            progress.step = step
        } label: {
            HStack(spacing: LiquidGlassMetrics.Spacing.small) {
                Text("\(step.rawValue + 1)")
                    .font(.caption.monospacedDigit().bold())
                    .frame(width: Self.stepBadgeSide, height: Self.stepBadgeSide)
                    .background(
                        isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.fill.tertiary),
                        in: Circle()
                    )
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
                Text(step.title).fontWeight(isSelected ? .semibold : .regular)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(inset)
            .background {
                if isSelected {
                    Capsule()
                        .fill(.fill.secondary)
                        .matchedGeometryEffect(id: "selectedStep", in: stepNamespace)
                }
            }
        }
        .buttonStyle(.liquidGlassPressable(cornerRadius: rowRadius))
        .disabled(requesting != nil)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xSmall) {
            Text("SET UP YOUR MAC")
                .font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(.secondary)
            // `.largeTitle` is 26pt on macOS: same size, but a named style.
            Text(pageTitle).font(.largeTitle.bold())
            Text(pageSubtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pageTitle: String {
        switch progress.step {
        case .welcome: "Welcome to Cockpit"
        case .permissions: "A few permissions. Fewer interruptions."
        case .tools: "Bring your tools along."
        case .ready: "Your workspace is ready."
        }
    }

    private var pageSubtitle: String {
        switch progress.step {
        case .welcome: "Set up the features you use before you start building. Everything here is optional; the terminal and editor are built in."
        case .permissions: "Approve each feature you want to use. macOS asks for each permission separately, and you stay in control."
        case .tools: "We check what is already installed. Use the instructions below to add missing tools, then check again."
        case .ready: "Review your choices, then open Cockpit. Skipped features can be configured later from Set Up Cockpit."
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.large) {
            feature("terminal", "Start building", "Terminals, editing, browser previews, and notes in one workspace.")
            feature("lock.shield", "Approve access up front", "Choose permissions for device sharing and browser previews before you need them.")
            feature("wrench.and.screwdriver", "Connect your tools", "Check Git, GitHub, persistent terminals, simulators, and containers.")
            if !Bundle.main.bundleURL.path.hasPrefix("/Applications/") &&
                !Bundle.main.bundleURL.path.hasPrefix(NSHomeDirectory() + "/Applications/") {
                Label {
                    Text("For reliable updates, drag Cockpit into Applications and open it there before setting up permissions.")
                } icon: {
                    Image(systemName: "folder.badge.gearshape")
                        .foregroundStyle(.orange)
                }
                .font(.callout)
                .setupCard(tint: .orange)
            }
            Text("macOS may ask you to quit and reopen after a permission change. Your setup progress is saved automatically.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: LiquidGlassMetrics.Spacing.medium) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tint).frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xxSmall) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var permissionRows: some View {
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.small) {
            ForEach(SetupPermission.allCases) { permission in
                permissionRow(permission)
            }
            // Helper text sits tight under its control (FORM-5, LAY-5).
            VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xxSmall) {
                Toggle("Connect companion apps automatically", isOn: $companionsEnabled)
                    .disabled(permissions.status(.localNetwork) != .allowed && !companionsEnabled)
                Text("Enable Local Network first. Turning this off keeps Walkie and Kneeboard discovery off at launch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, LiquidGlassMetrics.Spacing.xSmall)
            // Secondary glass actions; Continue stays the one prominent action.
            CompatGlassContainer(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                    Button("Refresh Status") { permissions.refresh() }
                    Button("Check Local Network") { permissions.verifyLocalNetwork() }
                        .disabled(permissions.status(.localNetwork) == .checking)
                }
                .compatGlassButtonStyle()
            }
            .disabled(requesting != nil)
            Text("If access is already denied, enable Cockpit in System Settings → Privacy & Security. Screen recording may require reopening the app. Website access and new device pairing still ask for your approval.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func permissionRow(_ permission: SetupPermission) -> some View {
        let status = permissions.status(permission)
        return HStack(alignment: .top, spacing: LiquidGlassMetrics.Spacing.medium) {
            Image(systemName: permission.symbol).font(.title3).frame(width: 32).padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xxSmall) {
                Text(permission.title).font(.headline)
                Text(permission.detail).font(.callout).foregroundStyle(.secondary)
                Label(status.label, systemImage: status == .allowed ? "checkmark.circle.fill" : "circle")
                    .font(.caption).foregroundStyle(status == .allowed ? Color.green : Color.secondary)
            }
            Spacer(minLength: 0)
            if status == .allowed {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Allowed")
            } else {
                HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                    // Show the in-flight request instead of a silently
                    // disabled button (MOT-5).
                    if requesting == permission {
                        ProgressView().controlSize(.small)
                    }
                    Button(status == .needsSettings ? "Open Settings" : "Enable") {
                        if permission == .localNetwork { enableCompanionsAfterProbe = true }
                        requesting = permission
                        Task {
                            await permissions.request(permission)
                            requesting = nil
                        }
                    }
                    .compatGlassButtonStyle()
                    .disabled(requesting != nil || status == .checking || status == .restricted)
                }
            }
        }
        .setupCard()
    }

    private var toolRows: some View {
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.small) {
            VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xSmall) {
                Text("Your first project").font(.headline)
                Text("Choose a folder now to grant access and open a terminal there when setup finishes.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: LiquidGlassMetrics.Spacing.small) {
                    Text(projectDirectory?.path ?? "No folder selected · optional")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button("Choose Folder…") { chooseProjectDirectory() }
                        .compatGlassButtonStyle()
                }
            }
            .setupCard()
            ForEach(SetupTool.all) { tool in
                toolCard(tool)
            }
            HStack(spacing: LiquidGlassMetrics.Spacing.small) {
                Button("Check Again") { Task { await tools.refresh() } }
                    .compatGlassButtonStyle()
                    .disabled(tools.isChecking)
                if tools.isChecking { ProgressView().controlSize(.small) }
                Spacer()
                Link("Get Homebrew", destination: URL(string: "https://brew.sh/")!)
            }
            Text("Run copied commands in Terminal. Install and sign in to your preferred coding agents there as well. Cockpit uses your existing accounts; it does not install tools or change credentials automatically.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func toolCard(_ tool: SetupTool) -> some View {
        let isReady = tools.results[tool.id] == true
        let isCopied = copiedCommand == tool.id
        return VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xSmall) {
            HStack(spacing: LiquidGlassMetrics.Spacing.small) {
                Text(tool.title).font(.headline)
                Spacer()
                // Same status glyphs as the permission rows, so state never
                // relies on color alone (IMG-1).
                Label(toolStatus(tool.id), systemImage: isReady ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(isReady ? Color.green : Color.secondary)
            }
            Text(tool.detail).font(.callout).foregroundStyle(.secondary)
            if !isReady {
                HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                    // The command reads as code: a quiet inset fill, not glass.
                    Text(tool.command)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, LiquidGlassMetrics.Spacing.xSmall)
                        .padding(.vertical, LiquidGlassMetrics.Spacing.xxSmall)
                        .background(
                            .fill.quaternary,
                            in: RoundedRectangle(cornerRadius: LiquidGlassMetrics.Radius.control, style: .continuous)
                        )
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(tool.command, forType: .string)
                        copiedCommand = tool.id
                    } label: {
                        Label(isCopied ? "Copied" : "Copy", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                            .labelStyle(.titleAndIcon)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .compatGlassButtonStyle()
                    .animation(LiquidGlassMetrics.stateChange, value: isCopied)
                    // Glass like its Copy neighbor, so the row's two actions
                    // read as one control set rather than a button and a URL.
                    Link("Instructions", destination: tool.helpURL)
                        .compatGlassButtonStyle()
                }
            }
        }
        .setupCard()
    }

    private func toolStatus(_ id: String) -> String {
        guard let ready = tools.results[id] else { return tools.isChecking ? "Checking…" : "Not checked" }
        return ready ? "Ready" : "Setup needed · optional"
    }

    private func chooseProjectDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose a project folder"
        panel.prompt = "Use Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK { projectDirectory = panel.url }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.large) {
            feature("checkmark.circle.fill", "Terminal, editor & browser included", "Create a workspace, choose a project folder, and start building.")
            if let projectDirectory {
                Label(projectDirectory.path, systemImage: "folder")
                    .font(.callout).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xSmall) {
                ForEach(SetupPermission.allCases) { permission in
                    let isAllowed = permissions.status(permission) == .allowed
                    HStack {
                        Text(permission.title)
                        Spacer()
                        Label(isAllowed ? "Allowed" : "Not verified · optional",
                              systemImage: isAllowed ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isAllowed ? Color.green : Color.secondary)
                    }
                }
                Divider()
                Text("\(tools.results.values.filter { $0 }.count) of \(SetupTool.all.count) optional developer tools ready")
                    .foregroundStyle(.secondary)
            }
            .setupCard()
            // Helper text sits tight under its control (FORM-5, LAY-5).
            VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xxSmall) {
                Toggle("Check for updates automatically", isOn: $automaticUpdates)
                    .onChange(of: automaticUpdates) { _, enabled in updater.automaticallyChecksForUpdates = enabled }
                Text("Updates are verified before installation. You can also use Cockpit → Check for Updates.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("When connecting a companion, compare the fingerprint on both devices and approve the pairing. Approve USB trust or debugging on each phone you connect.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var navigation: some View {
        CompatGlassContainer(spacing: LiquidGlassMetrics.Spacing.xSmall) {
            HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                if progress.step != .welcome {
                    Button("Back") { progress.step = SetupStep(rawValue: progress.step.rawValue - 1) ?? .welcome }
                        .compatGlassButtonStyle()
                }
                Spacer()
                // One prominent action per step (BTN-1); the rest stay secondary glass.
                if progress.step != .ready {
                    Button("Set Up Later") { progress.step = .ready }
                        .compatGlassButtonStyle()
                    Button("Continue") { progress.step = SetupStep(rawValue: progress.step.rawValue + 1) ?? .ready }
                        .compatGlassProminentButtonStyle().keyboardShortcut(.defaultAction)
                } else {
                    Button("Open Cockpit") {
                        permissions.stopProbe()
                        progress.finish()
                        onFinish(projectDirectory)
                    }
                    .compatGlassProminentButtonStyle().keyboardShortcut(.defaultAction)
                }
            }
        }
        .controlSize(.large)
        .disabled(requesting != nil)
        .padding(.horizontal, LiquidGlassMetrics.Spacing.xLarge)
        .padding(.vertical, LiquidGlassMetrics.Spacing.medium)
    }
}

private extension View {
    /// The one setup card treatment (systemic, LAY-4): 4pt-grid padding, the
    /// shared continuous card radius, and a declared container shape so any
    /// concentric children nest inside it. Cards are content, so they get a
    /// quiet fill — never glass (glass is the control layer).
    func setupCard(tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: LiquidGlassMetrics.Radius.card, style: .continuous)
        let fill: AnyShapeStyle = if let tint {
            AnyShapeStyle(tint.opacity(0.1))
        } else {
            AnyShapeStyle(.quaternary.opacity(0.35))
        }
        return padding(LiquidGlassMetrics.Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: shape)
            .liquidGlassContainerShape()
    }
}

struct SetupWindowView: View {
    let progress: SetupProgress
    let updater: SPUUpdater
    let onFinish: (URL?) -> Void
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        SetupView(progress: progress, updater: updater) { directory in
            onFinish(directory)
            dismissWindow(id: "setup")
        }
    }
}

struct OpenSetupButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Set Up Cockpit…") { openWindow(id: "setup") }
    }
}
