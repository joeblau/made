import Foundation
import SwiftData

enum PaneKind: String, Codable, CaseIterable {
    case terminal
    case browser
    case device
    case simulator
    case android
    case editor

    var displayName: String {
        switch self {
        case .terminal: "Terminal"
        case .browser: "Browser"
        case .device: "Device"
        case .simulator: "Simulator"
        case .android: "Android"
        case .editor: "Editor"
        }
    }

    var systemImageName: String {
        switch self {
        case .terminal: "terminal"
        case .browser: "safari"
        case .device: "apps.iphone"
        case .simulator: "ipad.landscape.and.ipod"
        case .android: "smartphone"
        case .editor: "curlybraces"
        }
    }
}

enum BrowserEngine: String, Codable, CaseIterable, Sendable {
    case webKit = "webkit"
    case chromium

    var displayName: String {
        switch self {
        case .webKit: "WebKit"
        case .chromium: "Chromium"
        }
    }

    var systemImageName: String {
        switch self {
        case .webKit: "safari"
        case .chromium: "globe"
        }
    }

    func supports(_ capability: BrowserCapability) -> Bool {
        switch self {
        case .webKit:
            true
        case .chromium:
            switch capability {
            case .navigation, .addressFocus, .developerTools:
                true
            case .appearanceOverride, .annotation, .websiteDataReset:
                false
            }
        }
    }
}

enum BrowserCapability: Hashable, Sendable {
    case navigation
    case addressFocus
    case appearanceOverride
    case developerTools
    case annotation
    case websiteDataReset
}

enum BrowserPaneCommand: Sendable {
    case back
    case forward
    case reload
    case stop
    case focusAddress
    case toggleDeveloperTools
    case toggleAnnotation

    var requiredCapability: BrowserCapability {
        switch self {
        case .back, .forward, .reload, .stop:
            .navigation
        case .focusAddress:
            .addressFocus
        case .toggleDeveloperTools:
            .developerTools
        case .toggleAnnotation:
            .annotation
        }
    }
}

enum AppearanceMode: String, Codable, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
}

enum InspectorTab: String, Codable, CaseIterable {
    case actions = "Actions"
    case tasks = "Tasks"
    case pullRequests = "PRs"
    case filesystem = "Files"
    case usage = "Usage"

    var systemImageName: String {
        switch self {
        case .actions: "gearshape.2"
        case .tasks: "checklist"
        case .pullRequests: "arrow.triangle.pull"
        case .filesystem: "folder"
        case .usage: "chart.bar.xaxis"
        }
    }
}

enum RootPathSource: String, Codable {
    case automatic
    case manual
}

/// A terminal pane's persisted one-click command. This intentionally lives in
/// UUID-keyed preferences rather than the versioned SwiftData graph: it is
/// terminal UI state, and adding it must not force a migration of user notes
/// and workspaces.
enum TerminalFastCommandStore {
    private static let keyPrefix = "terminal.fastCommand."

    static func command(for paneID: UUID, defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: preferenceKey(for: paneID)) ?? ""
    }

    static func setCommand(
        _ command: String,
        for paneID: UUID,
        defaults: UserDefaults = .standard
    ) {
        if command.isEmpty {
            defaults.removeObject(forKey: preferenceKey(for: paneID))
        } else {
            defaults.set(command, forKey: preferenceKey(for: paneID))
        }
    }

    static func removeCommand(for paneID: UUID, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: preferenceKey(for: paneID))
    }

    static func executableCommand(from command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func preferenceKey(for paneID: UUID) -> String {
        keyPrefix + paneID.uuidString.lowercased()
    }
}

enum PersistentTerminalSession {
    private static let runtimeCache = TerminalRuntimeCache<PaneRuntime> { sessionName in
        guard let tmuxPath = tmuxExecutablePath() else { return nil }
        return await loadPaneRuntime(sessionName: sessionName, executable: URL(fileURLWithPath: tmuxPath))
    }
    private static let tmuxCandidates = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/usr/bin/tmux",
    ]

    static func bootstrapCommand(for pane: Pane, workingDirectory: String?) -> String? {
        guard let tmuxPath = tmuxExecutablePath() else { return nil }

        let sessionName = shellEscape(pane.persistentSessionName)
        let tmux = shellEscape(tmuxPath)
        let createCommand: String
        // Panes render in Ghostty, a truecolor terminal, so a NO_COLOR leaked
        // from whatever launched Pilot (agent shells, scripts) must not reach
        // pane shells: the tmux server snapshots its environment at birth and
        // seeds every session from it. Strip it from the server, the session,
        // and the server-creating new-session itself.
        let configureSessionCommand = """
        \(tmux) set-option -t \(sessionName) status off >/dev/null 2>&1
        \(tmux) set-option -t \(sessionName) mouse on >/dev/null 2>&1
        \(tmux) set-environment -gu NO_COLOR >/dev/null 2>&1
        \(tmux) set-environment -t \(sessionName) -u NO_COLOR >/dev/null 2>&1
        \(tmux) set-environment -t \(sessionName) COLORTERM truecolor >/dev/null 2>&1
        """

        if let workingDirectory = validWorkingDirectory(workingDirectory) {
            createCommand = "env -u NO_COLOR \(tmux) new-session -d -s \(sessionName) -c \(shellEscape(workingDirectory))"
        } else {
            createCommand = "env -u NO_COLOR \(tmux) new-session -d -s \(sessionName)"
        }

        return """
        if \(tmux) has-session -t \(sessionName) 2>/dev/null; then
          \(configureSessionCommand)
          exec \(tmux) attach-session -t \(sessionName)
        else
          \(createCommand)
          \(configureSessionCommand)
          exec \(tmux) attach-session -t \(sessionName)
        fi
        """ + "\n"
    }

    static func killSession(for pane: Pane) {
        guard pane.kind == .terminal,
              let tmuxPath = tmuxExecutablePath() else { return }

        let sessionName = pane.persistentSessionName
        runtimeCache.invalidate(sessionName)
        Task {
            _ = try? await ProcessRunner.run(ProcessInvocation(
                executableURL: URL(fileURLWithPath: tmuxPath),
                arguments: ["kill-session", "-t", sessionName],
                timeout: .seconds(1), standardOutputLimit: 1024, standardErrorLimit: 4096
            ))
        }
    }

    struct PaneRuntime: Sendable {
        let shellPID: pid_t
        let cursorVisible: Bool
    }

    /// Runtime state reported by tmux for the pane. `#{pane_pid}` stays the
    /// shell while a foreground job owns the pty, so its descendants include
    /// the agent. Cursor visibility distinguishes an agent working from one
    /// parked at its input composer for agents that use the native cursor.
    static func paneRuntime(sessionName: String) -> PaneRuntime? {
        runtimeCache.snapshot(for: sessionName)
    }

    static func loadPaneRuntime(sessionName: String, executable: URL) async -> PaneRuntime? {
        guard let result = try? await ProcessRunner.run(ProcessInvocation(
            executableURL: executable,
            arguments: ["display-message", "-p", "-t", sessionName, "#{pane_pid}\t#{cursor_flag}"],
            timeout: .seconds(1), standardOutputLimit: 4096, standardErrorLimit: 4096
        )) else { return nil }
        let text = result.standardOutputString
        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 2,
              let pid = pid_t(fields[0]),
              pid > 0 else { return nil }
        return PaneRuntime(shellPID: pid, cursorVisible: fields[1] == "1")
    }

    static func paneShellPID(sessionName: String) -> pid_t? {
        paneRuntime(sessionName: sessionName)?.shellPID
    }

    /// The visible viewport only, bounded so arbitrary terminal output cannot
    /// grow an allocation without limit. Used for agents whose TUI does not
    /// expose native-cursor state while waiting for input.
    static func visibleContents(sessionName: String) async -> String? {
        guard let tmuxPath = tmuxExecutablePath() else { return nil }
        let invocation = ProcessInvocation(
            executableURL: URL(fileURLWithPath: tmuxPath),
            arguments: ["capture-pane", "-p", "-t", sessionName],
            timeout: .seconds(1),
            standardOutputLimit: 128 * 1_024,
            standardErrorLimit: 4 * 1_024
        )
        return try? await ProcessRunner.run(invocation).standardOutputString
    }

    static func foregroundActivity(sessionName: String) async -> TerminalProcessActivity {
        guard let tmuxPath = tmuxExecutablePath() else { return .idle }
        guard let result = try? await ProcessRunner.run(ProcessInvocation(
            executableURL: URL(fileURLWithPath: tmuxPath),
            arguments: ["display-message", "-p", "-t", sessionName, "#{pane_current_command}"],
            timeout: .seconds(1), standardOutputLimit: 4096, standardErrorLimit: 4096
        )) else { return .running }
        return TerminalProcessActivity.classify(currentCommand: result.standardOutputString)
    }

    /// Interrupts the foreground process group and waits until tmux reports
    /// that the pane's interactive shell owns the terminal again.
    static func stopForegroundCommand(sessionName: String) async -> Bool {
        guard let tmuxPath = tmuxExecutablePath() else { return false }

        if await foregroundActivity(sessionName: sessionName) == .idle {
            return true
        }

        // Interactive agents can consume one interrupt without exiting. Retry
        // a bounded number of times and wait for the shell after each attempt.
        for _ in 0..<3 {
            guard await sendKeys(["C-c"], to: sessionName, using: tmuxPath) else {
                return false
            }
            for _ in 0..<5 {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return false
                }
                if await foregroundActivity(sessionName: sessionName) == .idle {
                    return true
                }
            }
        }
        return false
    }

    /// Stops the active job, inserts the exact command text at the returned
    /// shell prompt, and executes it. `send-keys -l` prevents tmux from treating
    /// command fragments as named keys.
    static func runFastCommand(_ command: String, sessionName: String) async -> Bool {
        guard let command = TerminalFastCommandStore.executableCommand(from: command),
              await stopForegroundCommand(sessionName: sessionName),
              let tmuxPath = tmuxExecutablePath(),
              await sendLiteral(command, to: sessionName, using: tmuxPath) else {
            return false
        }
        return await sendKeys(["Enter"], to: sessionName, using: tmuxPath)
    }

    private static func sendKeys(
        _ keys: [String],
        to sessionName: String,
        using tmuxPath: String
    ) async -> Bool {
        do {
            _ = try await ProcessRunner.run(
                ProcessInvocation(
                    executableURL: URL(fileURLWithPath: tmuxPath),
                    arguments: ["send-keys", "-t", sessionName] + keys,
                    timeout: .seconds(2),
                    standardOutputLimit: 1_024,
                    standardErrorLimit: 4_096
                )
            )
            return true
        } catch {
            return false
        }
    }

    private static func sendLiteral(
        _ text: String,
        to sessionName: String,
        using tmuxPath: String
    ) async -> Bool {
        do {
            _ = try await ProcessRunner.run(
                ProcessInvocation(
                    executableURL: URL(fileURLWithPath: tmuxPath),
                    arguments: ["send-keys", "-l", "-t", sessionName, "--", text],
                    timeout: .seconds(2),
                    standardOutputLimit: 1_024,
                    standardErrorLimit: 4_096
                )
            )
            return true
        } catch {
            return false
        }
    }

    private static func tmuxExecutablePath() -> String? {
        tmuxCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func validWorkingDirectory(_ directory: String?) -> String? {
        guard let directory else { return nil }
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func shellEscape(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

enum TerminalProcessActivity: Equatable, Sendable {
    case idle
    case running

    private static let interactiveShellNames: Set<String> = [
        "bash",
        "csh",
        "dash",
        "fish",
        "ksh",
        "nu",
        "pwsh",
        "sh",
        "tcsh",
        "xonsh",
        "zsh",
    ]

    static func classify(currentCommand: String?) -> Self {
        guard let currentCommand else { return .idle }
        let command = currentCommand
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/")
            .last
            .map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .lowercased() ?? ""
        guard !command.isEmpty else { return .idle }
        return interactiveShellNames.contains(command) ? .idle : .running
    }
}

@Model
final class BrowserState {
    var urlText: String = ""
    var engineRaw: String = BrowserEngine.webKit.rawValue
    var appearanceModeRaw: String = AppearanceMode.system.rawValue
    var navigationRequestID: Int = 0
    var inspectorToggleRequestID: Int = 0

    @Transient var pendingURL: URL? = nil
    @Transient var canGoBack: Bool = false
    @Transient var canGoForward: Bool = false
    @Transient var isLoading: Bool = false
    @Transient var title: String = ""
    /// Favicon metadata follows the loaded page, independently of address edits.
    @Transient private var faviconMetadata = BrowserFaviconMetadata()
    @Transient var estimatedProgress: Double = 0
    @Transient var showDevTools: Bool = false
    @Transient var needsInspectorToggle: Bool = false
    /// Browser Annotate mode — runtime only, off after relaunch.
    @Transient var annotateMode: Bool = false
    @Transient var annotateToggleRequestID: Int = 0
    /// Set by ⌘L and consumed when this browser's address field is mounted.
    @Transient var needsAddressFocus: Bool = false
    /// Native navigation callbacks must not replace a newer address-field draft.
    @Transient var isAddressEditing: Bool = false
    @Transient var pendingAddressSubmission: String? = nil
    /// Recreates the WKWebView after its persistent website data is cleared.
    @Transient var websiteDataResetRequestID: Int = 0
    /// Recreates an unavailable Chromium surface without changing its engine.
    @Transient var runtimeRetryRequestID: Int = 0
    /// Chromium-only page command state. Counters make every action edge-triggered.
    @Transient var findQuery: String = ""
    @Transient var findForward: Bool = true
    @Transient var findMatchCase: Bool = false
    @Transient var findNext: Bool = false
    @Transient var findRequestID: Int = 0
    @Transient var stopFindingRequestID: Int = 0
    @Transient var findMatchCount: Int = 0
    @Transient var activeFindMatchOrdinal: Int = 0
    @Transient var printRequestID: Int = 0
    @Transient var savePageRequestID: Int = 0
    @Transient var downloadStatusText: String = ""
    @Transient var downloadProgress: Double? = nil

    var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: appearanceModeRaw) ?? .system }
        set { appearanceModeRaw = newValue.rawValue }
    }

    var engine: BrowserEngine {
        get { BrowserEngine(rawValue: engineRaw) ?? .webKit }
        set { engineRaw = newValue.rawValue }
    }

    init(engine: BrowserEngine = .webKit) {
        self.engineRaw = engine.rawValue
        // Empty by default — the pane shows the local-server start page
        // until the user navigates somewhere or picks a card.
    }

    func supports(_ capability: BrowserCapability) -> Bool {
        engine.supports(capability)
    }

    @discardableResult
    func perform(_ command: BrowserPaneCommand) -> Bool {
        guard supports(command.requiredCapability) else { return false }

        switch command {
        case .back:
            requestNavigationCommand("blau://back")
        case .forward:
            requestNavigationCommand("blau://forward")
        case .reload:
            requestNavigationCommand("blau://reload")
        case .stop:
            requestNavigationCommand("blau://stop")
        case .focusAddress:
            requestAddressFocus()
        case .toggleDeveloperTools:
            toggleDeveloperTools()
        case .toggleAnnotation:
            toggleAnnotateMode()
        }
        return true
    }

    func navigate() {
        var text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") {
            text = "https://\(text)"
            urlText = text
        }
        pendingAddressSubmission = text
        issueNavigationRequest(URL(string: text))
    }

    /// Accept a committed native navigation only while it cannot destroy a
    /// newer user draft. Redirects remain free to update the field until the
    /// user changes the submitted text.
    func acceptCommittedURL(_ url: URL) {
        let currentText = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isAddressEditing || currentText == pendingAddressSubmission else {
            return
        }
        urlText = url.absoluteString
        pendingAddressSubmission = url.absoluteString
    }

    var faviconPageURL: String? { faviconMetadata.pageURL }
    var faviconURLs: [String] { faviconMetadata.urls }

    func commitFaviconPage(_ url: URL) {
        guard faviconPageURL != url.absoluteString else { return }
        faviconMetadata.pageURL = url.absoluteString
        faviconMetadata.urls = []
    }

    func updateFaviconURLs(_ urls: [URL], for pageURL: URL?) {
        guard let pageURL, pageURL.absoluteString == faviconPageURL else { return }
        let next = urls.prefix(16).map(\.absoluteString)
        guard faviconURLs != next else { return }
        faviconMetadata.urls = next
    }

    func requestNavigationCommand(_ command: String) {
        issueNavigationRequest(URL(string: command))
    }

    func toggleDeveloperTools() {
        guard supports(.developerTools) else { return }
        showDevTools.toggle()
        needsInspectorToggle = true
        inspectorToggleRequestID += 1
    }

    func toggleAnnotateMode() {
        setAnnotateMode(!annotateMode)
    }

    func requestAddressFocus() {
        guard supports(.addressFocus) else { return }
        needsAddressFocus = true
    }

    func requestWebsiteDataReset() {
        guard supports(.websiteDataReset) else { return }
        pendingURL = nil
        canGoBack = false
        canGoForward = false
        isLoading = !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        websiteDataResetRequestID += 1
    }

    func requestRuntimeRetry() {
        pendingURL = nil
        canGoBack = false
        canGoForward = false
        isLoading = !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        estimatedProgress = 0
        runtimeRetryRequestID += 1
    }

    func requestFind(
        _ query: String,
        forward: Bool = true,
        matchCase: Bool = false,
        findNext: Bool = false
    ) {
        guard engine == .chromium, !query.isEmpty else { return }
        findQuery = query
        findForward = forward
        findMatchCase = matchCase
        self.findNext = findNext
        findRequestID += 1
    }

    func stopFinding() {
        guard engine == .chromium else { return }
        findQuery = ""
        findMatchCount = 0
        activeFindMatchOrdinal = 0
        stopFindingRequestID += 1
    }

    func requestPrint() {
        guard engine == .chromium else { return }
        printRequestID += 1
    }

    func requestSavePage() {
        guard engine == .chromium else { return }
        savePageRequestID += 1
    }

    /// Set lasso mode explicitly. The request ID is the WebView update trigger,
    /// so repeated writes of the current value must not generate phantom toggles.
    func setAnnotateMode(_ enabled: Bool) {
        guard supports(.annotation) else { return }
        guard annotateMode != enabled else { return }
        annotateMode = enabled
        annotateToggleRequestID += 1
    }

    private func issueNavigationRequest(_ request: URL?) {
        if let request {
            if request.absoluteString == "blau://stop" {
                isLoading = false
            } else {
                isLoading = true
            }
        }
        pendingURL = request
        navigationRequestID += 1
    }
}

@Model
final class Pane {
    #Unique([\Pane.id])

    var id: UUID = UUID()
    var kindRaw: String = PaneKind.terminal.rawValue
    var sortOrder: Int = 0
    var currentDirectory: String = ""
    var bellCount: Int = 0
    var sizeFraction: Double = 0
    var isCollapsed: Bool = false
    var restoredSizeFraction: Double = 0
    var wasCollapsedBeforeFocus: Bool = false

    @Relationship(deleteRule: .cascade)
    var browserState: BrowserState?

    @Relationship(deleteRule: .cascade)
    var editorState: EditorState?

    var workspace: Workspace?

    var kind: PaneKind {
        get { PaneKind(rawValue: kindRaw) ?? .terminal }
        set { kindRaw = newValue.rawValue }
    }

    init(
        kind: PaneKind = .terminal,
        sortOrder: Int = 0,
        currentDirectory: String = "",
        browserEngine: BrowserEngine = .webKit
    ) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.sortOrder = sortOrder
        self.currentDirectory = currentDirectory
        switch kind {
        case .terminal:
            break
        case .browser:
            self.browserState = BrowserState(engine: browserEngine)
        case .device:
            break
        case .simulator:
            break
        case .android:
            break
        case .editor:
            self.editorState = EditorState()
        }
    }

    var displayTitle: String {
        if kind == .editor, let path = editorState?.filePath, !path.isEmpty {
            return (path as NSString).lastPathComponent
        }
        if kind == .browser,
           let title = browserState?.title
                .trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        return kind.displayName
    }

    func incrementBellCount() {
        bellCount += 1
    }

    func resetBellCount() {
        guard bellCount != 0 else { return }
        bellCount = 0
    }

    func setCurrentDirectory(_ directory: String) {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Don't persist uninteresting directories
        guard trimmed != "/" && trimmed != NSHomeDirectory() else { return }
        guard currentDirectory != trimmed else { return }
        currentDirectory = trimmed
        workspace?.syncDefaultRootPathIfNeeded(using: self)
        _ = modelContext?.saveReporting()
    }

    var persistentSessionName: String {
        "pilot-\(id.uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
    }

    /// The pid of the pane's in-session shell, straight from tmux: the root
    /// process of the pane's session, which stays the shell even while a
    /// foreground job (the agent) owns the pty. Asking the server beats
    /// recording pids from the pane's spawn environment — tmux sessions
    /// outlive the app, so anything keyed to the app instance or the spawning
    /// shell goes stale across a relaunch and every pane reads as shell-less.
    func liveShellPID() -> pid_t? {
        guard kind == .terminal else { return nil }
        return PersistentTerminalSession.paneShellPID(sessionName: persistentSessionName)
    }

    /// The coding agent started under the pane's shell, or `nil` when no
    /// supported agent process is open in the terminal.
    func liveShellAgent() -> TerminalAgent? {
        guard let pid = liveShellPID() else { return nil }
        return TerminalAgent.started(under: pid)
    }

    /// A started coding agent plus whether its current turn is active. Keeping
    /// these separate is important: an idle TUI remains a live child of the
    /// shell, but it should contribute only to the sidebar denominator.
    @MainActor
    func liveShellAgentStatus() async -> LiveTerminalAgent? {
        guard kind == .terminal,
              let runtime = PersistentTerminalSession.paneRuntime(sessionName: persistentSessionName),
              let agent = TerminalAgent.started(under: runtime.shellPID) else { return nil }
        let contents: String? = if agent.needsVisibleTerminalContentsForActivity {
            await PersistentTerminalSession.visibleContents(sessionName: persistentSessionName)
        } else {
            nil
        }
        return LiveTerminalAgent(
            agent: agent,
            activity: agent.activity(
                cursorVisible: runtime.cursorVisible,
                visibleTerminalContents: contents
            )
        )
    }

    /// Reads the live cwd of the pane's shell process from the kernel.
    /// Unlike `currentDirectory` (updated only when the shell emits OSC 7 on
    /// each prompt), this works even while a foreground process like Claude
    /// Code owns the pty — the shell is paused but its cwd is still current.
    func liveShellCurrentDirectory() -> String? {
        guard let pid = liveShellPID() else { return nil }

        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard result == size else { return nil }

        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }

    /// Stops every runtime-only resource owned by this pane. During a
    /// transactional deletion, iOS capture is deliberately left alive until
    /// the save succeeds: a rollback can keep presenting the same SwiftUI view,
    /// so stopping it early would leave the restored pane dormant. The caller
    /// clears its preference and evicts/stops the session immediately after a
    /// successful save.
    func tearDownRuntimeResources(preservingDevicePreference: Bool = false) {
        PersistentTerminalSession.killSession(for: self)
        if preservingDevicePreference, kind == .device { return }
        stopRuntimeResources(isDestructive: true)
    }

    /// Stops window-bound capture sessions without killing a terminal's tmux
    /// identity. Persisted Extension panes use this when their window closes so
    /// reopening can restore the same terminal session and pane configuration.
    func suspendRuntimeResources() {
        stopRuntimeResources(isDestructive: false)
    }

    private func stopRuntimeResources(isDestructive: Bool) {
        let paneID = id
        let paneKind = kind
        MainActor.assumeIsolated {
            switch paneKind {
            case .device:
                if isDestructive {
                    DeviceCaptureRegistry.shared.remove(paneID: paneID)
                } else {
                    DeviceCaptureRegistry.shared.suspend(paneID: paneID)
                }
            case .simulator:
                SimulatorRegistry.shared.remove(paneID: paneID)
            case .android:
                AndroidDeviceRegistry.shared.remove(paneID: paneID)
            case .terminal:
                if isDestructive {
                    TerminalFastCommandStore.removeCommand(for: paneID)
                }
            case .browser, .editor:
                break
            }
        }
    }
}

enum PaneAxis: String, Codable {
    case vertical
    case horizontal
}

@Model
final class Workspace {
    #Unique([\Workspace.id])

    var id: UUID = UUID()
    var name: String = ""
    var selectedPaneID: UUID?
    var frontmostTerminalPaneID: UUID?
    var axisRaw: String = PaneAxis.vertical.rawValue
    var isInspectorPresented: Bool = false
    var inspectorTabRaw: String = InspectorTab.actions.rawValue
    var focusedPaneID: UUID?
    var isPinned: Bool = false
    var workspaceSortOrder: Int = 0
    var rootPath: String = ""
    var rootPathSourceRaw: String? = RootPathSource.automatic.rawValue
    /// Count of GitHub Action runs that completed for this workspace's repo
    /// while it was in the background. Cleared when the workspace is selected.
    /// Added to the terminal bell count to form `badgeCount`.
    var actionBadgeCount: Int = 0

    @Relationship(deleteRule: .cascade, inverse: \Pane.workspace)
    var panes: [Pane] = []

    var selectedPane: Pane? {
        sortedPanes.first { $0.id == selectedPaneID }
    }

    var frontmostTerminalPane: Pane? {
        if let frontmostTerminalPaneID,
           let pane = sortedPanes.first(where: {
               $0.id == frontmostTerminalPaneID && $0.kind == .terminal && !$0.isCollapsed
           }) {
            return pane
        }

        if let selectedPane, selectedPane.kind == .terminal, !selectedPane.isCollapsed {
            return selectedPane
        }

        return sortedPanes.first { $0.kind == .terminal && !$0.isCollapsed }
            ?? sortedPanes.first { $0.kind == .terminal }
    }

    var leftmostTerminalPane: Pane? {
        sortedPanes.first { $0.kind == .terminal && !$0.isCollapsed }
            ?? sortedPanes.first { $0.kind == .terminal }
    }

    var rootTrackingTerminalPane: Pane? {
        if let selectedPane, selectedPane.kind == .terminal, !selectedPane.isCollapsed {
            return selectedPane
        }

        return frontmostTerminalPane ?? leftmostTerminalPane
    }

    var effectiveRootPath: String? {
        let trimmed = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var sortedPanes: [Pane] {
        panes.sorted { $0.sortOrder < $1.sortOrder }
    }

    var badgeCount: Int {
        let bells = panes.filter { $0.kind == .terminal }.reduce(0) { $0 + $1.bellCount }
        return bells + actionBadgeCount
    }

    func incrementActionBadge() {
        actionBadgeCount += 1
    }

    func resetActionBadge() {
        guard actionBadgeCount != 0 else { return }
        actionBadgeCount = 0
    }

    var axis: PaneAxis {
        get { PaneAxis(rawValue: axisRaw) ?? .vertical }
        set { axisRaw = newValue.rawValue }
    }

    var inspectorTab: InspectorTab {
        get { InspectorTab(rawValue: inspectorTabRaw) ?? .actions }
        set { inspectorTabRaw = newValue.rawValue }
    }

    var rootPathSource: RootPathSource {
        get { RootPathSource(rawValue: rootPathSourceRaw ?? "") ?? .automatic }
        set { rootPathSourceRaw = newValue.rawValue }
    }

    init(name: String) {
        self.id = UUID()
        self.name = name
        let initialPane = Pane(kind: .terminal)
        self.panes = [initialPane]
        self.selectedPaneID = initialPane.id
        self.frontmostTerminalPaneID = initialPane.id
    }

    @discardableResult
    func addPane(
        kind: PaneKind,
        side: Side,
        browserEngine: BrowserEngine = .webKit
    ) -> Pane {
        let maxOrder = panes.map(\.sortOrder).max() ?? -1
        let pane = Pane(
            kind: kind,
            sortOrder: maxOrder + 1,
            currentDirectory: kind == .terminal ? inheritedDirectoryForNewTerminal() : "",
            browserEngine: browserEngine
        )

        if let selectedID = selectedPaneID,
           let selectedPane = sortedPanes.first(where: { $0.id == selectedID }),
           let index = sortedPanes.firstIndex(where: { $0.id == selectedID }) {
            let insertOrder: Int
            if side == .left {
                insertOrder = selectedPane.sortOrder
                for p in panes where p.sortOrder >= insertOrder {
                    p.sortOrder += 1
                }
            } else {
                let nextIndex = index + 1
                if nextIndex < sortedPanes.count {
                    insertOrder = sortedPanes[nextIndex].sortOrder
                    for p in panes where p.sortOrder >= insertOrder {
                        p.sortOrder += 1
                    }
                } else {
                    insertOrder = selectedPane.sortOrder + 1
                }
            }
            pane.sortOrder = insertOrder
        }

        panes.append(pane)
        selectedPaneID = pane.id
        if kind == .terminal {
            frontmostTerminalPaneID = pane.id
        }
        syncDefaultRootPathIfNeeded()
        _ = modelContext?.saveReporting(operation: "Adding pane")
        return pane
    }

    @discardableResult
    func addBrowserPane(engine: BrowserEngine = .webKit, side: Side) -> Pane {
        addPane(kind: .browser, side: side, browserEngine: engine)
    }

    @discardableResult
    func removePane(
        _ pane: Pane,
        performSave: (ModelContext) throws -> Void = { try $0.save() }
    ) -> Bool {
        guard panes.count > 1 else { return false }
        let context = modelContext
        let deletedDevicePaneID = pane.kind == .device ? pane.id : nil
        pane.tearDownRuntimeResources(preservingDevicePreference: true)
        panes.removeAll { $0.id == pane.id }
        if selectedPaneID == pane.id {
            selectedPaneID = sortedPanes.first(where: { !$0.isCollapsed })?.id ?? sortedPanes.first?.id
        }
        if frontmostTerminalPaneID == pane.id {
            frontmostTerminalPaneID = sortedPanes.first(where: { $0.kind == .terminal && !$0.isCollapsed })?.id
                ?? sortedPanes.first(where: { $0.kind == .terminal })?.id
        }
        syncDefaultRootPathForPaneTransfer()
        guard let context else {
            clearDeletedDevicePreference(paneID: deletedDevicePaneID)
            return true
        }
        guard context.saveReporting(
            operation: "Removing pane",
            rollbackOnFailure: true,
            performSave: performSave
        ) else { return false }
        clearDeletedDevicePreference(paneID: deletedDevicePaneID)
        return true
    }

    private func clearDeletedDevicePreference(paneID: UUID?) {
        guard let paneID else { return }
        MainActor.assumeIsolated {
            DeviceCaptureRegistry.shared.clearPreference(paneID: paneID)
        }
    }

    func setFrontmostTerminalPaneID(_ paneID: UUID?) {
        guard frontmostTerminalPaneID != paneID else { return }
        frontmostTerminalPaneID = paneID
        _ = modelContext?.saveReporting()
    }

    /// Move the selection to the next pane, wrapping around. In focus mode
    /// (one pane full-screen, others collapsed) this re-focuses the next
    /// pane instead — i.e. ⌘→ acts like ⌘} between browser tabs.
    func selectNextPane() { cyclePane(by: 1) }

    /// Move the selection to the previous pane, wrapping around. Same focus
    /// behavior as `selectNextPane`.
    func selectPreviousPane() { cyclePane(by: -1) }

    private func cyclePane(by delta: Int) {
        let allPanes = sortedPanes
        guard allPanes.count > 1 else { return }

        // Focus mode: cycle through every pane and switch the full-screened
        // one. The user explicitly opted into single-pane viewing, so the
        // arrow keys should rotate that pane like tabs.
        if focusedPaneID != nil {
            let currentIndex = allPanes.firstIndex(where: { $0.id == focusedPaneID }) ?? 0
            let count = allPanes.count
            let nextIndex = ((currentIndex + delta) % count + count) % count
            focusPane(allPanes[nextIndex])
            return
        }

        // Normal split mode: skip collapsed panes since selecting an invisible
        // slit isn't useful.
        let visible = allPanes.filter { !$0.isCollapsed }
        guard visible.count > 1 else { return }

        let currentIndex = visible.firstIndex(where: { $0.id == selectedPaneID }) ?? 0
        let count = visible.count
        let nextIndex = ((currentIndex + delta) % count + count) % count
        let next = visible[nextIndex]

        selectedPaneID = next.id
        if next.kind == .terminal {
            frontmostTerminalPaneID = next.id
        }
        _ = modelContext?.saveReporting()
    }

    func setInspectorPresented(_ isPresented: Bool) {
        guard isInspectorPresented != isPresented else { return }
        isInspectorPresented = isPresented
        _ = modelContext?.saveReporting()
    }

    func setInspectorTab(_ tab: InspectorTab) {
        guard inspectorTab != tab else { return }
        inspectorTab = tab
        _ = modelContext?.saveReporting()
    }

    /// Returns normalized size fractions for sorted panes, ensuring they sum to 1.0.
    /// Unset panes borrow the average assigned weight so new panes stay visible.
    var normalizedSizeFractions: [UUID: Double] {
        let sorted = sortedPanes
        guard !sorted.isEmpty else { return [:] }

        let assigned = sorted.filter { $0.sizeFraction > 0 }
        if assigned.isEmpty {
            let equal = 1.0 / Double(sorted.count)
            return Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, equal) })
        }

        let assignedTotal = assigned.reduce(0.0) { $0 + $1.sizeFraction }
        let defaultWeight = assignedTotal / Double(assigned.count)
        let weights = sorted.map { pane in
            (pane.id, pane.sizeFraction > 0 ? pane.sizeFraction : defaultWeight)
        }
        let totalWeight = weights.reduce(0.0) { $0 + $1.1 }

        guard totalWeight > 0 else {
            let equal = 1.0 / Double(sorted.count)
            return Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, equal) })
        }

        return Dictionary(uniqueKeysWithValues: weights.map { ($0.0, $0.1 / totalWeight) })
    }

    var normalizedExpandedSizeFractions: [UUID: Double] {
        normalizedSizeFractions(for: sortedPanes.filter { !$0.isCollapsed })
    }

    func canResizePanes(leadingID: UUID, trailingID: UUID) -> Bool {
        resizePanePair(leadingID: leadingID, trailingID: trailingID) != nil
    }

    /// Resize the nearest expanded panes on either side of the divider by a delta
    /// (in fraction of total expanded size). Collapsed panes keep their slit width.
    func resizePanes(leadingID: UUID, trailingID: UUID, delta: Double) {
        guard let (leadingPane, trailingPane) = resizePanePair(
            leadingID: leadingID,
            trailingID: trailingID
        ) else { return }

        let fractions = normalizedExpandedSizeFractions
        guard let leadFrac = fractions[leadingPane.id],
              let trailFrac = fractions[trailingPane.id] else { return }

        let minFraction = 0.1
        let newLead = max(minFraction, min(leadFrac + delta, leadFrac + trailFrac - minFraction))
        let newTrail = leadFrac + trailFrac - newLead

        // Apply to all panes (initialize any that were 0)
        for pane in sortedPanes where !pane.isCollapsed {
            if pane.id == leadingPane.id {
                pane.sizeFraction = newLead
            } else if pane.id == trailingPane.id {
                pane.sizeFraction = newTrail
            } else if pane.sizeFraction <= 0 {
                pane.sizeFraction = fractions[pane.id] ?? (1.0 / Double(panes.count))
            }
        }
    }

    func persistPaneSizes() {
        let fractions = normalizedExpandedSizeFractions
        for pane in sortedPanes where !pane.isCollapsed {
            pane.sizeFraction = fractions[pane.id] ?? (1.0 / Double(max(panes.count, 1)))
        }
        _ = modelContext?.saveReporting()
    }

    /// Reset all panes to equal size.
    func resetPaneSizes() {
        let equal = 1.0 / Double(max(panes.count, 1))
        for pane in panes {
            if pane.isCollapsed {
                pane.restoredSizeFraction = equal
            } else {
                pane.sizeFraction = equal
            }
        }
        _ = modelContext?.saveReporting()
    }

    func collapsePane(_ pane: Pane) {
        guard !pane.isCollapsed else { return }

        let currentFraction = normalizedExpandedSizeFractions[pane.id] ?? pane.sizeFraction
        pane.restoredSizeFraction = currentFraction > 0 ? currentFraction : 1.0 / Double(max(panes.count, 1))
        pane.isCollapsed = true

        if selectedPaneID == pane.id {
            selectedPaneID = sortedPanes.first(where: { !$0.isCollapsed && $0.id != pane.id })?.id ?? pane.id
        }
        if frontmostTerminalPaneID == pane.id {
            frontmostTerminalPaneID = sortedPanes.first(where: { $0.kind == .terminal && !$0.isCollapsed })?.id
                ?? (pane.kind == .terminal ? pane.id : nil)
        }

        _ = modelContext?.saveReporting()
    }

    func expandPane(_ pane: Pane) {
        guard pane.isCollapsed else { return }

        let expandedPanes = sortedPanes.filter { !$0.isCollapsed && $0.id != pane.id }
        let currentFractions = normalizedSizeFractions(for: expandedPanes)
        let restoredFraction = clampedRestoredFraction(for: pane, expandedSiblingCount: expandedPanes.count)
        let remainingFraction = max(0, 1.0 - restoredFraction)

        pane.isCollapsed = false
        pane.sizeFraction = restoredFraction
        for sibling in expandedPanes {
            sibling.sizeFraction = (currentFractions[sibling.id] ?? 0) * remainingFraction
        }

        selectedPaneID = pane.id
        if pane.kind == .terminal {
            frontmostTerminalPaneID = pane.id
        }

        _ = modelContext?.saveReporting()
    }

    func focusPane(_ pane: Pane) {
        if focusedPaneID == pane.id {
            restoreFocusedPane()
            return
        }

        if focusedPaneID != nil {
            restoreFocusedPane()
        }

        let expandedFractions = normalizedExpandedSizeFractions
        for existingPane in sortedPanes {
            existingPane.wasCollapsedBeforeFocus = existingPane.isCollapsed
            if !existingPane.isCollapsed {
                let currentFraction = expandedFractions[existingPane.id] ?? existingPane.sizeFraction
                existingPane.restoredSizeFraction = currentFraction > 0
                    ? currentFraction
                    : 1.0 / Double(max(panes.count, 1))
            }
        }

        if pane.isCollapsed {
            expandPane(pane)
        }

        for otherPane in sortedPanes where otherPane.id != pane.id && !otherPane.isCollapsed {
            otherPane.isCollapsed = true
        }

        pane.isCollapsed = false
        pane.sizeFraction = 1.0
        selectedPaneID = pane.id
        focusedPaneID = pane.id
        if pane.kind == .terminal {
            frontmostTerminalPaneID = pane.id
        }

        _ = modelContext?.saveReporting()
    }

    func syncDefaultRootPathIfNeeded(using pane: Pane? = nil) {
        syncDefaultRootPathIfNeeded(using: pane, save: true)
    }

    /// Re-evaluates an automatic root as part of a larger pane-transfer
    /// transaction. The caller owns the single save/rollback for the move.
    func syncDefaultRootPathForPaneTransfer() {
        syncDefaultRootPathIfNeeded(using: nil, save: false)
    }

    private func syncDefaultRootPathIfNeeded(using pane: Pane?, save: Bool) {
        guard rootPathSource == .automatic else { return }

        guard let rootTrackingTerminalPane else {
            if !rootPath.isEmpty {
                rootPath = ""
                if save {
                    _ = modelContext?.saveReporting()
                }
            }
            return
        }

        if let pane, pane.id != rootTrackingTerminalPane.id {
            return
        }

        let liveDirectory = rootTrackingTerminalPane.liveShellCurrentDirectory()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cachedDirectory = rootTrackingTerminalPane.currentDirectory
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = (liveDirectory?.isEmpty == false ? liveDirectory! : cachedDirectory)
        let repoRoot = directory.isEmpty ? nil : RepositoryStore.findGitRoot(from: directory)
        let nextRootPath = repoRoot ?? ""

        guard rootPath != nextRootPath else { return }
        rootPath = nextRootPath
        if save {
            _ = modelContext?.saveReporting()
        }
    }

    func setRootPath(_ path: String) {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextRootPath = trimmedPath.isEmpty
            ? ""
            : (trimmedPath as NSString).expandingTildeInPath

        let nextSource: RootPathSource = nextRootPath.isEmpty ? .automatic : .manual
        guard rootPath != nextRootPath || rootPathSource != nextSource else { return }
        rootPath = nextRootPath
        rootPathSource = nextSource
        _ = modelContext?.saveReporting()
    }

    enum Side {
        case left, right
    }

    private func inheritedDirectoryForNewTerminal() -> String {
        if let effectiveRootPath {
            return effectiveRootPath
        }

        if let selectedPaneID,
           let selectedPane = sortedPanes.first(where: { $0.id == selectedPaneID }),
           selectedPane.kind == .terminal,
           !selectedPane.isCollapsed {
            let directory = selectedPane.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            if !directory.isEmpty {
                return directory
            }
        }

        if let existingTerminal = sortedPanes.first(where: {
            $0.kind == .terminal && !$0.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return existingTerminal.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return ""
    }

    private func normalizedSizeFractions(for panes: [Pane]) -> [UUID: Double] {
        guard !panes.isEmpty else { return [:] }

        let assigned = panes.filter { $0.sizeFraction > 0 }
        if assigned.isEmpty {
            let equal = 1.0 / Double(panes.count)
            return Dictionary(uniqueKeysWithValues: panes.map { ($0.id, equal) })
        }

        let assignedTotal = assigned.reduce(0.0) { $0 + $1.sizeFraction }
        let defaultWeight = assignedTotal / Double(assigned.count)
        let weights = panes.map { pane in
            (pane.id, pane.sizeFraction > 0 ? pane.sizeFraction : defaultWeight)
        }
        let totalWeight = weights.reduce(0.0) { $0 + $1.1 }

        guard totalWeight > 0 else {
            let equal = 1.0 / Double(panes.count)
            return Dictionary(uniqueKeysWithValues: panes.map { ($0.id, equal) })
        }

        return Dictionary(uniqueKeysWithValues: weights.map { ($0.0, $0.1 / totalWeight) })
    }

    func prepareForPaneTransfer() {
        restoreFocusedPane(save: false)
    }

    private func restoreFocusedPane(save: Bool = true) {
        guard focusedPaneID != nil else { return }

        let fallbackFraction = 1.0 / Double(max(panes.count, 1))
        for pane in sortedPanes {
            pane.isCollapsed = pane.wasCollapsedBeforeFocus
            pane.wasCollapsedBeforeFocus = false

            if !pane.isCollapsed {
                pane.sizeFraction = pane.restoredSizeFraction > 0
                    ? pane.restoredSizeFraction
                    : fallbackFraction
            }
        }

        focusedPaneID = nil
        selectedPaneID = sortedPanes.first(where: { $0.id == selectedPaneID && !$0.isCollapsed })?.id
            ?? sortedPanes.first(where: { !$0.isCollapsed })?.id
            ?? sortedPanes.first?.id

        if let frontmostTerminalPaneID,
           sortedPanes.contains(where: {
               $0.id == frontmostTerminalPaneID && $0.kind == .terminal && !$0.isCollapsed
           }) {
            self.frontmostTerminalPaneID = frontmostTerminalPaneID
        } else {
            self.frontmostTerminalPaneID = sortedPanes.first(where: { $0.kind == .terminal && !$0.isCollapsed })?.id
                ?? sortedPanes.first(where: { $0.kind == .terminal })?.id
        }

        if save {
            _ = modelContext?.saveReporting()
        }
    }

    private func resizePanePair(leadingID: UUID, trailingID: UUID) -> (Pane, Pane)? {
        let sorted = sortedPanes
        guard let leadingIndex = sorted.firstIndex(where: { $0.id == leadingID }),
              let trailingIndex = sorted.firstIndex(where: { $0.id == trailingID }),
              trailingIndex == leadingIndex + 1 else { return nil }

        let leadingPane = sorted[...leadingIndex].last(where: { !$0.isCollapsed })
        let trailingPane = sorted[trailingIndex...].first(where: { !$0.isCollapsed })

        guard let leadingPane,
              let trailingPane,
              leadingPane.id != trailingPane.id else { return nil }

        return (leadingPane, trailingPane)
    }

    private func clampedRestoredFraction(for pane: Pane, expandedSiblingCount: Int) -> Double {
        let fallback = 1.0 / Double(max(panes.count, 1))
        let restored = pane.restoredSizeFraction > 0 ? pane.restoredSizeFraction : fallback
        guard expandedSiblingCount > 0 else { return 1.0 }
        return min(max(0.1, restored), 0.85)
    }
}
