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

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        pageHeader
                        switch progress.step {
                        case .welcome: welcome
                        case .permissions: permissionRows
                        case .tools: toolRows
                        case .ready: summary
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 48, height: 48)
                Text("Cockpit").font(.title2.bold())
                Text("Your development environment,\nready for takeoff.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(SetupStep.allCases) { step in
                    Button {
                        progress.step = step
                    } label: {
                        HStack(spacing: 12) {
                            Text("\(step.rawValue + 1)")
                                .font(.caption.monospacedDigit().bold())
                                .frame(width: 26, height: 26)
                                .background(progress.step == step ? Color.accentColor : Color.secondary.opacity(0.12), in: Circle())
                                .foregroundStyle(progress.step == step ? Color.white : Color.secondary)
                            Text(step.title).fontWeight(progress.step == step ? .semibold : .regular)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(requesting != nil)
                    .accessibilityAddTraits(progress.step == step ? .isSelected : [])
                }
            }
            Spacer()
            Text("You can return to setup from the Cockpit menu at any time.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(.quaternary.opacity(0.3))
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SET UP YOUR MAC")
                .font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(.secondary)
            Text(pageTitle).font(.system(size: 26, weight: .bold))
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
        VStack(alignment: .leading, spacing: 20) {
            feature("terminal", "Start building", "Terminals, editing, browser previews, and notes in one workspace.")
            feature("lock.shield", "Approve access up front", "Choose permissions for device sharing and browser previews before you need them.")
            feature("wrench.and.screwdriver", "Connect your tools", "Check Git, GitHub, persistent terminals, simulators, and containers.")
            if !Bundle.main.bundleURL.path.hasPrefix("/Applications/") &&
                !Bundle.main.bundleURL.path.hasPrefix(NSHomeDirectory() + "/Applications/") {
                Label("For reliable updates, drag Cockpit into Applications and open it there before setting up permissions.", systemImage: "folder.badge.gearshape")
                    .font(.callout).padding(16)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
            Text("macOS may ask you to quit and reopen after a permission change. Your setup progress is saved automatically.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor).frame(width: 32)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var permissionRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(SetupPermission.allCases) { permission in
                permissionRow(permission)
            }
            Toggle("Connect companion apps automatically", isOn: $companionsEnabled)
                .disabled(permissions.status(.localNetwork) != .allowed && !companionsEnabled)
            Text("Enable Local Network first. Turning this off keeps Walkie and Kneeboard discovery off at launch.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Refresh permission status") { permissions.refresh() }
                Button("Check Local Network") { permissions.verifyLocalNetwork() }
                    .disabled(permissions.status(.localNetwork) == .checking)
            }
            .disabled(requesting != nil)
            Text("If access is already denied, enable Cockpit in System Settings → Privacy & Security. Screen recording may require reopening the app. Website access and new device pairing still ask for your approval.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func permissionRow(_ permission: SetupPermission) -> some View {
        let status = permissions.status(permission)
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: permission.symbol).font(.title3).frame(width: 26).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(permission.title).font(.headline)
                Text(permission.detail).font(.callout).foregroundStyle(.secondary)
                Label(status.label, systemImage: status == .allowed ? "checkmark.circle.fill" : "circle")
                    .font(.caption).foregroundStyle(status == .allowed ? Color.green : Color.secondary)
            }
            Spacer(minLength: 0)
            if status == .allowed {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Allowed")
            } else {
                Button(status == .needsSettings ? "Open Settings" : "Enable") {
                    if permission == .localNetwork { enableCompanionsAfterProbe = true }
                    requesting = permission
                    Task {
                        await permissions.request(permission)
                        requesting = nil
                    }
                }
                .disabled(requesting != nil || status == .checking || status == .restricted)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private var toolRows: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Your first project").font(.headline)
                Text("Choose a folder now to grant access and open a terminal there when setup finishes.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Text(projectDirectory?.path ?? "No folder selected · optional")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button("Choose Folder…") { chooseProjectDirectory() }
                }
            }
            .padding(16)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            ForEach(SetupTool.all) { tool in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(tool.title).font(.headline)
                        Spacer()
                        Text(toolStatus(tool.id)).font(.caption)
                            .foregroundStyle(tools.results[tool.id] == true ? Color.green : Color.secondary)
                    }
                    Text(tool.detail).font(.callout).foregroundStyle(.secondary)
                    if tools.results[tool.id] != true {
                        HStack {
                            Text(tool.command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Spacer()
                            Button(copiedCommand == tool.id ? "Copied" : "Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(tool.command, forType: .string)
                                copiedCommand = tool.id
                            }
                            Link("Instructions", destination: tool.helpURL)
                        }
                    }
                }
                .padding(16)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            }
            HStack {
                Button("Check again") { Task { await tools.refresh() } }.disabled(tools.isChecking)
                if tools.isChecking { ProgressView().controlSize(.small) }
                Spacer()
                Link("Get Homebrew", destination: URL(string: "https://brew.sh/")!)
            }
            Text("Run copied commands in Terminal. Install and sign in to your preferred coding agents there as well. Cockpit uses your existing accounts; it does not install tools or change credentials automatically.")
                .font(.caption).foregroundStyle(.secondary)
        }
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
        VStack(alignment: .leading, spacing: 20) {
            feature("checkmark.circle.fill", "Terminal, editor & browser included", "Create a workspace, choose a project folder, and start building.")
            if let projectDirectory {
                Label(projectDirectory.path, systemImage: "folder")
                    .font(.callout).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(SetupPermission.allCases) { permission in
                    HStack {
                        Text(permission.title)
                        Spacer()
                        Text(permissions.status(permission) == .allowed ? "Allowed" : "Not verified · optional")
                            .foregroundStyle(.secondary)
                    }
                }
                Divider()
                Text("\(tools.results.values.filter { $0 }.count) of \(SetupTool.all.count) optional tools ready")
                    .foregroundStyle(.secondary)
            }
            Toggle("Check for updates automatically", isOn: $automaticUpdates)
                .onChange(of: automaticUpdates) { _, enabled in updater.automaticallyChecksForUpdates = enabled }
            Text("Updates are verified before installation. You can also use Cockpit → Check for Updates.")
                .font(.caption).foregroundStyle(.secondary)
            Text("When connecting a companion, compare the fingerprint on both devices and approve the pairing. Approve USB trust or debugging on each phone you connect.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var navigation: some View {
        HStack {
            if progress.step != .welcome {
                Button("Back") { progress.step = SetupStep(rawValue: progress.step.rawValue - 1) ?? .welcome }
            }
            Spacer()
            if progress.step != .ready {
                Button("Set Up Later") { progress.step = .ready }
                Button("Continue") { progress.step = SetupStep(rawValue: progress.step.rawValue + 1) ?? .ready }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            } else {
                Button("Open Cockpit") {
                    permissions.stopProbe()
                    progress.finish()
                    onFinish(projectDirectory)
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .disabled(requesting != nil)
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
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
