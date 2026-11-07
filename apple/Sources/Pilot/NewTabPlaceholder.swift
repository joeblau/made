import AppKit
import Observation

// MARK: - Navigation model

/// The platform branch below Simulator and Device.
enum NewTabPlatform: String, Hashable, Sendable {
    case apple, google
}

/// One screen of the new-tab placeholder. The placeholder is a push-style
/// stack: every page asks a single question, and Escape returns to the parent.
enum NewTabPage: Hashable, Sendable {
    case root
    case terminal
    case browser
    case browserServers(BrowserEngine)
    case simulator
    case device
    case simulators(NewTabPlatform)
    case devices(NewTabPlatform)

    var title: String {
        switch self {
        case .root: "New Tab"
        case .terminal: "Terminal"
        case .browser: "Browser"
        case .browserServers(let engine): engine == .webKit ? "Safari" : "Chrome"
        case .simulator: "Simulator"
        case .device: "Device"
        case .simulators(.apple): "Apple Simulators"
        case .simulators(.google): "Android Simulators"
        case .devices(.apple): "Apple Devices"
        case .devices(.google): "Android Devices"
        }
    }

    /// Pages whose rows come from a live scan rather than a fixed menu.
    var isLive: Bool {
        switch self {
        case .browserServers, .simulators, .devices: true
        case .root, .terminal, .browser, .simulator, .device: false
        }
    }

    /// The title of the row that opens this page, used in the tab title.
    var crumb: String {
        switch self {
        case .simulators(let platform), .devices(let platform): platform == .apple ? "Apple" : "Google"
        default: title
        }
    }

    /// "New Tab" at the root, then the chosen rows: "Terminal", "Browser / Safari".
    static func breadcrumb(_ path: [NewTabPage]) -> String {
        let crumbs = path.filter { $0 != .root }.map(\.crumb)
        return crumbs.isEmpty ? NewTabPage.root.title : crumbs.joined(separator: " / ")
    }
}

extension Notification.Name {
    /// Posted with the pane's ID (a `UUID`) as `object` when its new-tab path
    /// changes. Observers compare IDs; `object:` filtering would not match.
    static let paneOpeningPathDidChange = Notification.Name("PaneOpeningPathDidChange")
}

/// The working mode a placeholder becomes. Applying one is the only way a
/// placeholder pane starts a terminal, browser, or capture session.
enum NewTabChoice: Equatable {
    case terminal
    case agenticTerminal
    case browser(BrowserEngine, URL?)
    case editor
    case appleSimulator(SimDevice)
    case appleDevice(IOSCaptureDevice)
    case appleWireless
    case android(AndroidPaneTarget, AndroidDevice)
    case androidEmulator(String)
    /// Opens the pane's own setup screen, for example a missing-tooling or
    /// camera-permission message that needs more than a single row.
    case pane(PaneKind, AndroidPaneTarget?)

    var kind: PaneKind {
        switch self {
        case .terminal: .terminal
        case .agenticTerminal: .agentChat
        case .browser: .browser
        case .editor: .editor
        case .appleSimulator: .simulator
        case .appleDevice, .appleWireless: .device
        case .android, .androidEmulator: .android
        case .pane(let kind, _): kind
        }
    }
}

struct NewTabRow: Equatable {
    enum Action: Equatable {
        case push(NewTabPage)
        case open(NewTabChoice)
        case revealInFinder
        case refresh
        /// A non-interactive group heading inside a long list.
        case header
    }

    var id: String
    var title: String
    var detail: String?
    var symbol: String?
    var asset: String?
    /// A single lowercase letter or digit. Rows past the ninth list item have
    /// none and remain reachable with the arrow keys or the pointer.
    var shortcut: String?
    /// Server rows use stacked labels and a live status indicator.
    var serverIsLive: Bool?
    var isEnabled = true
    var action: Action

    var isHeader: Bool { action == .header }
    var isSelectable: Bool { !isHeader && isEnabled }
}

struct NewTabMessage: Equatable {
    var title: String
    var detail: String?
    var isLoading = false
}

struct NewTabContent: Equatable {
    var rows: [NewTabRow]
    var message: NewTabMessage?
}

/// Inputs for the fixed menus. Kept separate from AppKit so the hierarchy and
/// its shortcuts are directly testable.
struct NewTabContext: Equatable {
    var hasRoot: Bool
    var chromiumEnabled: Bool
    var chromiumUnavailableReason: String?

    @MainActor static func current(rootPath: String?) -> NewTabContext {
        NewTabContext(hasRoot: rootPath != nil,
                      chromiumEnabled: ChromiumBrowserCreationPolicy.isCreationEnabled,
                      chromiumUnavailableReason: ChromiumBrowserCreationPolicy.unavailableReason?.message)
    }
}

enum NewTabMenu {
    static func rows(for page: NewTabPage, context: NewTabContext) -> [NewTabRow] {
        switch page {
        case .root:
            return [
                NewTabRow(id: "terminal", title: "Terminal", symbol: "terminal", shortcut: "t", action: .push(.terminal)),
                NewTabRow(id: "browser", title: "Browser", symbol: "globe", shortcut: "b", action: .push(.browser)),
                NewTabRow(id: "simulator", title: "Simulator", symbol: PaneKind.simulator.systemImageName, shortcut: "s", action: .push(.simulator)),
                NewTabRow(id: "device", title: "Device", symbol: "iphone", shortcut: "d", action: .push(.device)),
                NewTabRow(id: "files", title: "Files", detail: context.hasRoot ? "Open in Finder" : "Choose a workspace folder first",
                          symbol: "folder", shortcut: "f", isEnabled: context.hasRoot, action: .revealInFinder),
                NewTabRow(id: "editor", title: "Editor", detail: context.hasRoot ? nil : "Choose a workspace folder first",
                          symbol: PaneKind.editor.systemImageName, shortcut: "e", isEnabled: context.hasRoot, action: .open(.editor)),
            ]
        case .terminal:
            return [
                NewTabRow(id: "agentic", title: "Agentic", symbol: PaneKind.agentChat.systemImageName, shortcut: "a", action: .open(.agenticTerminal)),
                NewTabRow(id: "raw", title: "Raw", symbol: "terminal", shortcut: "r", action: .open(.terminal)),
            ]
        case .browser:
            return [
                NewTabRow(id: "safari", title: "Safari", symbol: "safari", shortcut: "s", action: .push(.browserServers(.webKit))),
                NewTabRow(id: "chrome", title: "Chrome", detail: context.chromiumEnabled ? nil : context.chromiumUnavailableReason,
                          symbol: "globe", shortcut: "c", isEnabled: context.chromiumEnabled, action: .push(.browserServers(.chromium))),
            ]
        case .simulator:
            return platformRows { .simulators($0) }
        case .device:
            return platformRows { .devices($0) }
        case .browserServers, .simulators, .devices:
            return []
        }
    }

    private static func platformRows(_ page: (NewTabPlatform) -> NewTabPage) -> [NewTabRow] {
        [
            NewTabRow(id: "apple", title: "Apple", symbol: "apple.logo", shortcut: "a", action: .push(page(.apple))),
            NewTabRow(id: "google", title: "Google", asset: "AndroidRobot", shortcut: "g", action: .push(page(.google))),
        ]
    }

    /// Assigns 1–9 to the first nine list items in order. Rows that already
    /// carry a letter (Refresh, Share Wirelessly) and headings are skipped.
    static func numbered(_ rows: [NewTabRow]) -> [NewTabRow] {
        var next = 1
        return rows.map { row in
            guard row.shortcut == nil, !row.isHeader, case .open = row.action else { return row }
            var row = row
            if next <= 9 { row.shortcut = String(next) }
            next += 1
            return row
        }
    }
}

// MARK: - Opening state

extension Pane {
    /// The placeholder's navigation stack. Root is always at the bottom.
    var openingPath: [NewTabPage] {
        get { PaneOpeningChoices.path(for: id) ?? [.root] }
        set {
            PaneOpeningChoices.setPath(newValue, for: id)
            NotificationCenter.default.post(name: .paneOpeningPathDidChange, object: id)
        }
    }

    /// The tab title: the launcher path while choosing ("New Tab", "Terminal",
    /// "Browser / Safari"); an agent chat keeps the path that opens it,
    /// "Terminal / Agent"; every other pane uses its own title.
    var tabTitle: String {
        if isChoosingMode { return NewTabPage.breadcrumb(openingPath) }
        if kind == .agentChat { return NewTabPage.breadcrumb([.root, .terminal]) + " / Agent" }
        return displayTitle
    }

    /// Converts the placeholder into its working mode. Returns false without
    /// mutating the pane when the choice is unavailable or already applied.
    @MainActor @discardableResult
    func applyOpeningChoice(_ choice: NewTabChoice) -> Bool {
        guard isChoosingMode else { return false }
        switch choice {
        case .terminal:
            kind = .terminal
        case .agenticTerminal:
            kind = .agentChat
        case .browser(let engine, let url):
            guard engine == .webKit || ChromiumBrowserCreationPolicy.isCreationEnabled else { return false }
            let state = browserState ?? BrowserState(engine: engine)
            state.engine = engine
            browserState = state
            kind = .browser
            if let url {
                state.urlText = url.absoluteString
                state.navigate()
            }
        case .editor:
            guard workspace?.effectiveRootPath != nil else { return false }
            if editorState == nil { editorState = EditorState() }
            kind = .editor
        case .appleSimulator(let device):
            kind = .simulator
            SimulatorRegistry.shared.session(for: id).boot(device)
        case .appleDevice(let device):
            kind = .device
            DeviceCaptureRegistry.shared.session(for: id).connect(device)
        case .appleWireless:
            kind = .device
            DeviceCaptureRegistry.shared.session(for: id).stop()
            DeviceCaptureRegistry.shared.wirelessSession(for: id).start()
        case .android(let target, let device):
            kind = .android
            androidTarget = target
            AndroidDeviceRegistry.shared.configure(target: target, for: id)
            AndroidDeviceRegistry.shared.session(for: id).connect(device)
        case .androidEmulator(let name):
            kind = .android
            androidTarget = .simulator
            AndroidDeviceRegistry.shared.configure(target: .simulator, for: id)
            AndroidDeviceRegistry.shared.session(for: id).bootAVD(name)
        case .pane(let paneKind, let target):
            kind = paneKind
            if paneKind == .android, let target {
                androidTarget = target
                AndroidDeviceRegistry.shared.configure(target: target, for: id)
            }
        }
        if kind.isTerminalTool, currentDirectory.isEmpty, let workspace {
            // Toolbar placeholders can start as a device kind.
            currentDirectory = workspace.inheritedDirectoryForNewTerminal()
        }
        NewTabProbes.release(paneID: id, keeping: kind)
        isChoosingMode = false
        workspace?.selectedPaneID = id
        if kind == .terminal { workspace?.setFrontmostTerminalPaneID(id) }
        _ = modelContext?.saveReporting(operation: "Choosing pane mode")
        return true
    }
}

/// Discovery sessions the placeholder starts while the user browses device
/// lists. They are keyed by the pane like the panes' own sessions, so the one
/// matching the final choice carries over and the rest are released.
@MainActor
enum NewTabProbes {
    enum Probe: Hashable { case simulator, device, android }
    private static var touched: [UUID: Set<Probe>] = [:]

    static func mark(_ probe: Probe, paneID: UUID) { touched[paneID, default: []].insert(probe) }

    static func release(paneID: UUID, keeping kind: PaneKind?) {
        guard let probes = touched.removeValue(forKey: paneID) else { return }
        if probes.contains(.simulator), kind != .simulator { SimulatorRegistry.shared.remove(paneID: paneID) }
        if probes.contains(.device), kind != .device { DeviceCaptureRegistry.shared.remove(paneID: paneID) }
        if probes.contains(.android), kind != .android { AndroidDeviceRegistry.shared.remove(paneID: paneID) }
    }
}

// MARK: - Live list content

/// Supplies rows for the scanned pages. Reads go through Observation so the
/// placeholder re-renders as simulators, devices, and servers appear.
@MainActor
protocol NewTabContentSource: AnyObject {
    func activate(_ page: NewTabPage, rootPath: String?)
    func deactivate()
    func content(for page: NewTabPage) -> NewTabContent
}

@MainActor @Observable
final class NewTabLiveSource: NewTabContentSource {
    @ObservationIgnored let paneID: UUID
    private var servers: [LocalServer]?
    private var serverLiveness: [Int: Bool] = [:]
    @ObservationIgnored private var serverRoot: String?
    @ObservationIgnored private var serverGeneration = 0
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private let serverScanner: @Sendable (String) async -> [LocalServer]
    @ObservationIgnored private let serverProbe: @Sendable (Int) async -> Bool

    init(
        paneID: UUID,
        serverScanner: @escaping @Sendable (String) async -> [LocalServer] = { await LocalServerScanner.scan(rootPath: $0) },
        serverProbe: @escaping @Sendable (Int) async -> Bool = { await LocalServerProbe.isLive(port: $0) }
    ) {
        self.paneID = paneID
        self.serverScanner = serverScanner
        self.serverProbe = serverProbe
    }

    isolated deinit {
        scanTask?.cancel()
        polling?.cancel()
    }

    func activate(_ page: NewTabPage, rootPath: String?) {
        polling?.cancel()
        polling = nil
        if case .browserServers = page {} else { stopServerScan() }
        switch page {
        case .browserServers:
            scanServers(rootPath: rootPath)
        case .simulators(.apple):
            NewTabProbes.mark(.simulator, paneID: paneID)
            let session = SimulatorRegistry.shared.session(for: paneID)
            if session.status == .picking, !session.isRefreshing { session.refreshDevices() }
        case .devices(.apple):
            NewTabProbes.mark(.device, paneID: paneID)
            let session = DeviceCaptureRegistry.shared.session(for: paneID)
            session.start()
            poll { if session.status == .picking, !session.isRefreshing { session.refreshDevices() } }
        case .simulators(.google), .devices(.google):
            NewTabProbes.mark(.android, paneID: paneID)
            let target: AndroidPaneTarget = page == .simulators(.google) ? .simulator : .device
            AndroidDeviceRegistry.shared.configure(target: target, for: paneID)
            let session = AndroidDeviceRegistry.shared.session(for: paneID)
            session.invalidateAVDSerialCache()
            if session.status == .picking { session.refreshDevices() }
            poll { if session.status == .picking, !session.isRefreshing { session.refreshDevices() } }
        case .root, .terminal, .browser, .simulator, .device:
            break
        }
    }

    func deactivate() {
        polling?.cancel()
        polling = nil
        stopServerScan()
    }

    private func poll(_ tick: @escaping @MainActor () -> Void) {
        polling = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                tick()
            }
        }
    }

    private func scanServers(rootPath: String?) {
        guard let rootPath, !rootPath.isEmpty else {
            guard serverRoot != nil || servers == nil else { return }
            stopServerScan()
            servers = []
            serverRoot = nil
            serverLiveness = [:]
            return
        }
        guard serverRoot != rootPath || scanTask == nil else { return }
        stopServerScan()
        serverRoot = rootPath
        servers = nil
        serverLiveness = [:]
        let generation = serverGeneration
        let scan = serverScanner
        let probe = serverProbe
        scanTask = Task { [weak self] in
            let found = await scan(rootPath)
            guard !Task.isCancelled, self?.serverGeneration == generation else { return }
            self?.servers = found
            guard !found.isEmpty else { return }
            await LocalServerLivenessMonitor.monitor(servers: found, probe: probe) { [weak self] latest in
                guard let self, self.serverGeneration == generation, self.serverLiveness != latest else { return }
                self.serverLiveness = latest
            }
        }
    }

    private func stopServerScan() {
        serverGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
    }

    func content(for page: NewTabPage) -> NewTabContent {
        switch page {
        case .browserServers(let engine): browserContent(engine)
        case .simulators(.apple): appleSimulatorContent()
        case .devices(.apple): appleDeviceContent()
        case .simulators(.google): androidContent(.simulator)
        case .devices(.google): androidContent(.device)
        case .root, .terminal, .browser, .simulator, .device: NewTabContent(rows: [])
        }
    }

    private func browserContent(_ engine: BrowserEngine) -> NewTabContent {
        var rows = (servers ?? []).map { server in
            NewTabRow(id: server.id, title: server.name, detail: server.displayURL,
                      serverIsLive: serverLiveness[server.port] == true,
                      action: .open(.browser(engine, server.url)))
        }
        rows.append(NewTabRow(id: "start", title: "Open a URL", detail: "Enter an address", symbol: "globe",
                             shortcut: "0", action: .open(.browser(engine, nil))))
        let message: NewTabMessage
        if serverRoot == nil {
            message = NewTabMessage(title: "Choose a workspace folder to find its sites.")
        } else if servers == nil {
            message = NewTabMessage(title: "Looking for dev servers…", isLoading: true)
        } else if servers?.isEmpty == true {
            message = NewTabMessage(title: "No dev servers found in this workspace.")
        } else {
            message = NewTabMessage(title: "Choose a server, or use its 1–9 shortcut.")
        }
        return NewTabContent(rows: NewTabMenu.numbered(rows), message: message)
    }

    private func appleSimulatorContent() -> NewTabContent {
        guard let session = SimulatorRegistry.shared.existingSession(for: paneID) else {
            return NewTabContent(rows: [], message: NewTabMessage(title: "Looking for simulators…", isLoading: true))
        }
        if session.status == .toolingMissing {
            return NewTabContent(rows: [openPaneRow(.simulator, nil, title: "Open Simulator Setup")],
                                 message: NewTabMessage(title: "Full Xcode Required", detail: "The iOS Simulator needs a full Xcode install."))
        }
        var rows: [NewTabRow] = []
        for group in session.devices {
            rows.append(NewTabRow(id: "group-\(group.id)", title: group.displayName, action: .header))
            for device in group.devices {
                rows.append(NewTabRow(id: device.id, title: device.name, detail: device.isBooted ? "Booted" : nil,
                                      symbol: device.deviceTypeIdentifier?.contains("iPad") == true ? "ipad" : "iphone",
                                      action: .open(.appleSimulator(device))))
            }
        }
        let message: NewTabMessage?
        if !rows.isEmpty {
            message = nil
        } else if session.isRefreshing {
            message = NewTabMessage(title: "Looking for simulators…", isLoading: true)
        } else if let error = session.lastError {
            message = NewTabMessage(title: "Couldn't List Simulators", detail: error)
        } else {
            message = NewTabMessage(title: "No Simulators Found", detail: "Create one in Xcode (Window → Devices and Simulators).")
        }
        return NewTabContent(rows: NewTabMenu.numbered(rows) + [refreshRow(session.isRefreshing)], message: message)
    }

    private func appleDeviceContent() -> NewTabContent {
        let wireless = NewTabRow(id: "wireless", title: "Share Wirelessly…", detail: "Mirror over AirPlay",
                                 symbol: "airplay.video", shortcut: "w", action: .open(.appleWireless))
        guard let session = DeviceCaptureRegistry.shared.existingSession(for: paneID) else {
            return NewTabContent(rows: [wireless], message: NewTabMessage(title: "Looking for devices…", isLoading: true))
        }
        if session.isCameraPermissionDenied {
            return NewTabContent(rows: [openPaneRow(.device, nil, title: "Open Camera Setup"), wireless],
                                 message: NewTabMessage(title: "Camera Access Required",
                                                        detail: "Cockpit needs camera permission to mirror the iPhone screen."))
        }
        let rows = session.devices.map { device in
            NewTabRow(id: device.id, title: device.name, detail: device.detail, symbol: "apps.iphone", action: .open(.appleDevice(device)))
        }
        let message: NewTabMessage?
        if !rows.isEmpty {
            message = nil
        } else if session.isRefreshing {
            message = NewTabMessage(title: "Looking for devices…", isLoading: true)
        } else if let error = session.lastError {
            message = NewTabMessage(title: "Couldn't List Devices", detail: error)
        } else {
            message = NewTabMessage(title: "No USB Devices Found", detail: "Connect an iPhone or iPad over USB, trust this Mac, and keep its screen awake.")
        }
        return NewTabContent(rows: NewTabMenu.numbered(rows) + [wireless, refreshRow(session.isRefreshing)], message: message)
    }

    private func androidContent(_ target: AndroidPaneTarget) -> NewTabContent {
        guard let session = AndroidDeviceRegistry.shared.existingSession(for: paneID), session.target == target else {
            return NewTabContent(rows: [], message: NewTabMessage(title: "Looking for devices…", isLoading: true))
        }
        if session.status == .adbMissing {
            return NewTabContent(rows: [openPaneRow(.android, target, title: "Open Android Setup")],
                                 message: NewTabMessage(title: "adb Required", detail: "Mirroring needs Android platform-tools."))
        }
        let bootable = target == .simulator ? session.bootableAVDs : []
        var rows: [NewTabRow] = []
        if !bootable.isEmpty, !session.devices.isEmpty { rows.append(NewTabRow(id: "running", title: "Running", action: .header)) }
        for device in session.devices {
            let detail: String? = switch device.state {
            case .device: nil
            case .unauthorized: "Unauthorized — accept the USB-debugging prompt"
            case .offline: "Offline — reconnect or re-enable debugging"
            case .other: "Not ready"
            }
            rows.append(NewTabRow(id: device.serial, title: session.displayName(for: device), detail: detail,
                                  symbol: device.isEmulator ? "apps.iphone" : "smartphone", isEnabled: device.isConnectable,
                                  action: .open(.android(target, device))))
        }
        if !bootable.isEmpty {
            rows.append(NewTabRow(id: "available", title: "Available", action: .header))
            for avd in bootable {
                rows.append(NewTabRow(id: "avd-\(avd)", title: EmulatorBridge.displayName(for: avd), detail: "Not running — boots on open",
                                      symbol: "play.circle", action: .open(.androidEmulator(avd))))
            }
        }
        let message: NewTabMessage?
        if !rows.isEmpty {
            message = nil
        } else if session.isRefreshing {
            message = NewTabMessage(title: "Looking for devices…", isLoading: true)
        } else if let error = session.lastError {
            message = NewTabMessage(title: "Couldn't List Devices", detail: error)
        } else if target == .simulator {
            message = NewTabMessage(title: "No Android Simulators Found", detail: "Create an emulator in Android Studio's Device Manager.")
        } else {
            message = NewTabMessage(title: "No Android Devices Found", detail: "Connect a device over USB with USB debugging enabled.")
        }
        return NewTabContent(rows: NewTabMenu.numbered(rows) + [refreshRow(session.isRefreshing)], message: message)
    }

    private func openPaneRow(_ kind: PaneKind, _ target: AndroidPaneTarget?, title: String) -> NewTabRow {
        NewTabRow(id: "open-pane", title: title, symbol: "arrow.right.circle", shortcut: "o", action: .open(.pane(kind, target)))
    }

    private func refreshRow(_ refreshing: Bool) -> NewTabRow {
        NewTabRow(id: "refresh", title: refreshing ? "Refreshing…" : "Refresh", symbol: "arrow.clockwise",
                  shortcut: "r", isEnabled: !refreshing, action: .refresh)
    }

    /// Refresh re-runs the scan for the visible page.
    func refresh(_ page: NewTabPage, rootPath: String?) {
        switch page {
        case .browserServers:
            stopServerScan()
            scanServers(rootPath: rootPath)
        case .simulators(.apple):
            SimulatorRegistry.shared.existingSession(for: paneID)?.refreshDevices()
        case .devices(.apple):
            DeviceCaptureRegistry.shared.existingSession(for: paneID)?.refreshDevices()
        case .simulators(.google), .devices(.google):
            AndroidDeviceRegistry.shared.existingSession(for: paneID)?.refreshDevices()
        case .root, .terminal, .browser, .simulator, .device:
            break
        }
    }
}

// MARK: - View

/// The placeholder shown by ⌘T. Each row has a one-key shortcut, so a user can
/// type a path such as T A (agentic terminal) or S A 1 (first Apple simulator)
/// without waiting for the slide transition to finish.
@MainActor
final class CockpitNewTabView: NSView {
    let pane: Pane
    var onChange: (() -> Void)?
    private let source: NewTabContentSource
    private let backButton = NSButton()
    private let heading = CockpitUI.label("", role: .sectionTitle)
    private let hint = CockpitUI.label("", size: 11, color: .tertiaryLabelColor)
    private let pageHost = NSView()
    private var pageView: NewTabPageView?
    private var content = NewTabContent(rows: [])
    private var highlightedID: String?
    private lazy var observation = CockpitObservation(owner: self) { $0.renderContent() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { pane.isChoosingMode }

    var currentPage: NewTabPage { pane.openingPath.last ?? .root }
    var rows: [NewTabRow] { content.rows }

    init(pane: Pane, source: NewTabContentSource? = nil) {
        self.pane = pane
        self.source = source ?? NewTabLiveSource(paneID: pane.id)
        super.init(frame: .zero)
        setAccessibilityIdentifier("pane.opening-choice")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        heading.alignment = .center
        heading.maximumNumberOfLines = 1
        heading.lineBreakMode = .byTruncatingTail
        heading.setAccessibilityRole(.staticText)
        hint.alignment = .center
        hint.maximumNumberOfLines = 1
        hint.lineBreakMode = .byTruncatingTail
        backButton.bezelStyle = .accessoryBarAction
        backButton.isBordered = false
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        backButton.imagePosition = .imageOnly
        backButton.contentTintColor = .secondaryLabelColor
        backButton.target = self
        backButton.action = #selector(backPressed)
        backButton.toolTip = "Back (Esc)"
        backButton.setAccessibilityLabel("Back")
        backButton.setAccessibilityIdentifier("pane.opening-choice.back")
        pageHost.wantsLayer = true
        pageHost.layer?.masksToBounds = true
        [heading, backButton, hint, pageHost].forEach(addSubview)
        self.source.activate(currentPage, rootPath: rootPath)
        showPage(transition: nil)
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit { source.deactivate() }

    private var rootPath: String? { pane.workspace?.effectiveRootPath }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            observation.stop()
            source.deactivate()
        } else {
            source.activate(currentPage, rootPath: rootPath)
            observation.start()
        }
    }

    // MARK: Navigation

    func push(_ page: NewTabPage) {
        guard pane.isChoosingMode else { return }
        pane.openingPath.append(page)
        source.activate(page, rootPath: rootPath)
        showPage(transition: .fromRight)
    }

    @discardableResult
    func pop() -> Bool {
        guard pane.isChoosingMode, pane.openingPath.count > 1 else { return false }
        pane.openingPath.removeLast()
        source.activate(currentPage, rootPath: rootPath)
        showPage(transition: .fromLeft)
        return true
    }

    @objc private func backPressed() {
        pop()
        reclaimFocus()
    }

    /// A pointer press keeps typing in the placeholder until it is replaced.
    private func reclaimFocus() {
        guard pane.isChoosingMode, window != nil else { return }
        window?.makeFirstResponder(self)
    }

    /// Activates the row with the given shortcut on the current page.
    @discardableResult
    func press(_ key: String) -> Bool {
        guard pane.isChoosingMode,
              let row = content.rows.first(where: { $0.shortcut == key.lowercased() && $0.isSelectable }) else { return false }
        activate(row)
        return true
    }

    func activate(_ row: NewTabRow) {
        guard pane.isChoosingMode, row.isSelectable else { return }
        switch row.action {
        case .push(let page):
            push(page)
        case .open(let choice):
            guard pane.applyOpeningChoice(choice) else { return }
            source.deactivate()
            onChange?()
        case .revealInFinder:
            if let rootPath { NSWorkspace.shared.open(URL(fileURLWithPath: rootPath)) }
        case .refresh:
            (source as? NewTabLiveSource)?.refresh(currentPage, rootPath: rootPath)
        case .header:
            break
        }
    }

    private func showPage(transition: CATransitionSubtype?) {
        let page = currentPage
        heading.stringValue = page.title
        heading.setAccessibilityLabel(page.title)
        backButton.isHidden = pane.openingPath.count <= 1
        hint.stringValue = pane.openingPath.count > 1 ? "Esc to go back" : "Press a letter to choose"
        highlightedID = nil
        let next = NewTabPageView()
        next.onActivate = { [weak self] row in self?.activate(row); self?.reclaimFocus() }
        next.onHover = { [weak self] id in self?.setHighlight(id) }
        pageView?.removeFromSuperview()
        pageView = next
        pageHost.addSubview(next)
        renderContent(force: true)
        needsLayout = true
        layoutSubtreeIfNeeded()
        if let transition, window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let animation = CATransition()
            animation.type = .push
            animation.subtype = transition
            animation.duration = 0.2
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pageHost.layer?.add(animation, forKey: "cockpit.new-tab.push")
        }
        setAccessibilityLabel(page.title)
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    private func renderContent(force: Bool = false) {
        let page = currentPage
        // Reading the workspace root here also observes folder changes while
        // a site picker is visible. Activation is idempotent for the same root.
        let currentRoot = rootPath
        if case .browserServers = page { source.activate(page, rootPath: currentRoot) }
        let next = page.isLive ? source.content(for: page)
            : NewTabContent(rows: NewTabMenu.rows(for: page, context: .current(rootPath: currentRoot)))
        if let highlightedID, !next.rows.contains(where: { $0.id == highlightedID && $0.isSelectable }) { self.highlightedID = nil }
        guard force || next != content else { return }
        content = next
        pageView?.update(rows: next.rows, message: next.message, highlightedID: highlightedID)
        needsLayout = true
    }

    private func setHighlight(_ id: String?) {
        highlightedID = id
        pageView?.setHighlight(id)
    }

    private func moveHighlight(by delta: Int) {
        let selectable = content.rows.filter(\.isSelectable)
        guard !selectable.isEmpty else { return }
        let index = selectable.firstIndex { $0.id == highlightedID }
        let next = index.map { min(max($0 + delta, 0), selectable.count - 1) } ?? (delta > 0 ? 0 : selectable.count - 1)
        setHighlight(selectable[next].id)
        pageView?.scrollToHighlight()
    }

    // MARK: Keyboard

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        // Handle keys only in this focused placeholder, never as window-wide
        // key equivalents that could consume input in another pane.
        guard pane.isChoosingMode,
              pane.workspace?.selectedPaneID == pane.id, !isHiddenOrHasHiddenAncestor,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event); return
        }
        switch event.keyCode {
        case 53, 123: // Escape, Left Arrow
            if !event.isARepeat, pop() { return }
        case 125: moveHighlight(by: 1); return // Down Arrow
        case 126: moveHighlight(by: -1); return // Up Arrow
        case 36, 76, 124: // Return, Enter, Right Arrow
            if !event.isARepeat, let row = content.rows.first(where: { $0.id == highlightedID }) { activate(row); return }
        default:
            if !event.isARepeat, let key = event.charactersIgnoringModifiers, key.count == 1, press(key) { return }
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if !pop() { super.cancelOperation(sender) }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let zoom = CGFloat(CockpitUIZoomController.shared.factor)
        let width = min(440 * zoom, max(0, bounds.width - 32))
        let left = (bounds.width - width) / 2
        let headingHeight = heading.intrinsicContentSize.height
        let hintHeight = hint.intrinsicContentSize.height
        let pageHeight = pageView?.preferredHeight(width: width) ?? 0
        let chrome = headingHeight + 20 + 16 + hintHeight
        let available = max(0, bounds.height - 24 - chrome)
        let listHeight = min(pageHeight, available)
        var top = max(12, (bounds.height - chrome - listHeight) / 2)
        let backSize: CGFloat = 24
        backButton.frame = NSRect(x: left - 4, y: top + (headingHeight - backSize) / 2, width: backSize, height: backSize)
        heading.frame = NSRect(x: left + backSize, y: top, width: max(0, width - backSize * 2), height: headingHeight)
        top += headingHeight + 20
        pageHost.frame = NSRect(x: left, y: top, width: width, height: listHeight)
        pageView?.frame = pageHost.bounds
        top += listHeight + 16
        hint.frame = NSRect(x: left, y: top, width: width, height: hintHeight)
    }
}

/// A scrollable column of rows for one page.
@MainActor
private final class NewTabPageView: NSScrollView {
    var onActivate: ((NewTabRow) -> Void)?
    var onHover: ((String?) -> Void)?
    private(set) var rows: [NewTabRow] = []
    private(set) var message: NewTabMessage?
    private let document = FlippedView()
    private var rowViews: [NewTabRowView] = []
    private var messageView: NewTabMessageView?

    private final class FlippedView: NSView { override var isFlipped: Bool { true } }

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
        documentView = document
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { nil }

    private var rowHeight: CGFloat { 36 * CGFloat(CockpitUIZoomController.shared.factor) }
    private var headerHeight: CGFloat { 26 * CGFloat(CockpitUIZoomController.shared.factor) }

    private func height(for row: NewTabRow) -> CGFloat {
        if row.isHeader { return headerHeight }
        return row.serverIsLive == nil ? rowHeight : 52 * CGFloat(CockpitUIZoomController.shared.factor)
    }

    private func spacing(after row: NewTabRow) -> CGFloat {
        row.isHeader ? 0 : (row.serverIsLive == nil ? 2 : 5)
    }

    func update(rows: [NewTabRow], message: NewTabMessage?, highlightedID: String?) {
        self.rows = rows
        self.message = message
        // Reuse row views by position so live refreshes don't flash.
        while rowViews.count > rows.count { rowViews.removeLast().removeFromSuperview() }
        while rowViews.count < rows.count {
            let view = NewTabRowView()
            view.onActivate = { [weak self] row in self?.onActivate?(row) }
            view.onHover = { [weak self] id in self?.onHover?(id) }
            document.addSubview(view)
            rowViews.append(view)
        }
        for (view, row) in zip(rowViews, rows) { view.configure(row, highlighted: row.id == highlightedID) }
        if let message {
            let view = messageView ?? NewTabMessageView()
            if view.superview == nil { document.addSubview(view) }
            view.configure(message)
            messageView = view
        } else {
            messageView?.removeFromSuperview()
            messageView = nil
        }
        needsLayout = true
    }

    func setHighlight(_ id: String?) {
        for view in rowViews { view.isHighlighted = view.row?.id == id && view.row?.isSelectable == true }
    }

    func scrollToHighlight() {
        guard let view = rowViews.first(where: \.isHighlighted) else { return }
        document.scrollToVisible(view.frame.insetBy(dx: 0, dy: -4))
    }

    private var messageHeight: CGFloat { message == nil ? 0 : (messageView?.preferredHeight ?? 0) + 8 }

    func preferredHeight(width: CGFloat) -> CGFloat {
        messageHeight + rows.reduce(0) { $0 + height(for: $1) + spacing(after: $1) }
    }

    override func layout() {
        super.layout()
        let width = contentSize.width
        var top: CGFloat = 0
        if let messageView {
            messageView.frame = NSRect(x: 0, y: 0, width: width, height: messageView.preferredHeight)
            top = messageHeight
        }
        for view in rowViews {
            guard let row = view.row else { continue }
            let height = height(for: row)
            view.frame = NSRect(x: 0, y: top, width: width, height: height)
            top += height + spacing(after: row)
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(top, contentSize.height))
    }
}

@MainActor
private final class NewTabMessageView: NSView {
    private let spinner = NSProgressIndicator()
    private let title = CockpitUI.label("", size: 12, weight: .medium, color: .secondaryLabelColor)
    private let detail = CockpitUI.label("", size: 11, color: .tertiaryLabelColor)
    private var isLoading = false
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        title.alignment = .center
        title.maximumNumberOfLines = 1
        title.lineBreakMode = .byTruncatingTail
        detail.alignment = .center
        detail.lineBreakMode = .byWordWrapping
        detail.maximumNumberOfLines = 3
        [spinner, title, detail].forEach(addSubview)
    }

    required init?(coder: NSCoder) { nil }

    var preferredHeight: CGFloat {
        let titleHeight = title.intrinsicContentSize.height
        // Wrapping labels report no useful intrinsic height before layout;
        // reserve two lines of detail text.
        let lineHeight = detail.font.map { ceil($0.ascender - $0.descender + $0.leading) } ?? 14
        let detailHeight = detail.stringValue.isEmpty ? 0 : lineHeight * 2 + 4
        return 8 + titleHeight + detailHeight + 8
    }

    func configure(_ message: NewTabMessage) {
        title.stringValue = message.title
        detail.stringValue = message.detail ?? ""
        detail.isHidden = message.detail == nil
        isLoading = message.isLoading
        if isLoading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel([message.title, message.detail].compactMap { $0 }.joined(separator: ". "))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let titleHeight = title.intrinsicContentSize.height
        let titleWidth = min(bounds.width - 24, ceil(title.attributedStringValue.size().width) + 4)
        let spinnerSize: CGFloat = isLoading ? 16 : 0
        let total = titleWidth + (spinnerSize > 0 ? spinnerSize + 6 : 0)
        let x = (bounds.width - total) / 2
        spinner.frame = NSRect(x: x, y: 8 + (titleHeight - 16) / 2, width: 16, height: 16)
        title.frame = NSRect(x: x + (spinnerSize > 0 ? spinnerSize + 6 : 0), y: 8, width: titleWidth, height: titleHeight)
        detail.frame = NSRect(x: 12, y: 12 + titleHeight, width: bounds.width - 24, height: max(0, bounds.height - titleHeight - 20))
    }
}

@MainActor
private final class NewTabRowView: NSView {
    var onActivate: ((NewTabRow) -> Void)?
    var onHover: ((String?) -> Void)?
    private(set) var row: NewTabRow?
    var isHighlighted = false { didSet { if isHighlighted != oldValue { updateAppearance() } } }
    private let icon = NSImageView()
    private let title = CockpitUI.label("", size: 13)
    private let detail = CockpitUI.label("", size: 11, color: .secondaryLabelColor)
    private let chevron = NSImageView()
    private let badge = NewTabKeyBadge()
    private let serverIndicator = NSView()
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = .labelColor
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        chevron.contentTintColor = .tertiaryLabelColor
        for label in [title, detail] {
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
        }
        serverIndicator.wantsLayer = true
        serverIndicator.setAccessibilityElement(false)
        [icon, title, detail, chevron, badge, serverIndicator].forEach(addSubview)
        setAccessibilityElement(true)
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ row: NewTabRow, highlighted: Bool) {
        self.row = row
        let zoom = CGFloat(CockpitUIZoomController.shared.factor)
        title.baseFontSize = row.isHeader ? 11 : 13
        title.fontWeight = row.isHeader ? .semibold : (row.serverIsLive == nil ? .regular : .medium)
        title.textColor = row.isHeader ? .secondaryLabelColor : .labelColor
        title.stringValue = row.title
        detail.stringValue = row.detail ?? ""
        detail.isHidden = row.detail == nil || row.isHeader
        if let asset = row.asset {
            icon.image = NSImage(named: asset)
        } else if let symbol = row.symbol {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15 * zoom, weight: .regular))
        } else {
            icon.image = nil
        }
        icon.isHidden = row.isHeader || row.serverIsLive != nil
        serverIndicator.isHidden = row.serverIsLive == nil
        if case .push = row.action { chevron.isHidden = false } else { chevron.isHidden = true }
        badge.key = row.shortcut
        badge.isHidden = row.shortcut == nil || row.isHeader
        alphaValue = row.isEnabled ? 1 : 0.4
        isHighlighted = highlighted && row.isSelectable
        if row.isHeader {
            setAccessibilityRole(.staticText)
            setAccessibilityLabel(row.title)
            setAccessibilityHelp(nil)
            setAccessibilityIdentifier(nil)
        } else {
            setAccessibilityRole(.button)
            let serverDescription = row.serverIsLive.map { "\(row.title), \(row.detail ?? ""), \($0 ? "listening" : "not listening")" }
            setAccessibilityLabel(serverDescription ?? row.title)
            setAccessibilityIdentifier("pane.opening-choice.\(row.id)")
            setAccessibilityEnabled(row.isEnabled)
            let help = [row.detail, row.shortcut.map { "Press \($0.uppercased())." }].compactMap { $0 }.joined(separator: " ")
            setAccessibilityHelp(help.isEmpty ? nil : help)
            toolTip = row.detail
        }
        updateAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let zoom = CGFloat(CockpitUIZoomController.shared.factor)
        let height = bounds.height
        if row?.isHeader == true {
            let titleHeight = title.intrinsicContentSize.height
            title.frame = NSRect(x: 10, y: height - titleHeight - 4, width: bounds.width - 20, height: titleHeight)
            return
        }
        if row?.serverIsLive != nil {
            let dotSize = 8 * zoom
            serverIndicator.frame = NSRect(x: bounds.width - 14 - dotSize, y: (height - dotSize) / 2,
                                           width: dotSize, height: dotSize)
            serverIndicator.layer?.cornerRadius = dotSize / 2
            badge.frame = NSRect(x: serverIndicator.frame.minX - 12 - 24 * zoom, y: (height - 22 * zoom) / 2,
                                 width: 24 * zoom, height: 22 * zoom)
            let textRight = (badge.isHidden ? serverIndicator.frame.minX : badge.frame.minX) - 12
            let titleHeight = title.intrinsicContentSize.height
            let detailHeight = detail.intrinsicContentSize.height
            let top = (height - titleHeight - detailHeight - 2) / 2
            title.frame = NSRect(x: 14, y: top, width: max(0, textRight - 14), height: titleHeight)
            detail.frame = NSRect(x: 14, y: top + titleHeight + 2, width: title.frame.width, height: detailHeight)
            return
        }
        let iconSize = 20 * zoom
        icon.frame = NSRect(x: 10, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
        let badgeSize = NSSize(width: 24 * zoom, height: 22 * zoom)
        badge.frame = NSRect(x: bounds.width - 8 - badgeSize.width, y: (height - badgeSize.height) / 2,
                             width: badgeSize.width, height: badgeSize.height)
        let chevronWidth: CGFloat = chevron.isHidden ? 0 : 12
        chevron.frame = NSRect(x: badge.frame.minX - 8 - chevronWidth, y: (height - 14) / 2, width: chevronWidth, height: 14)
        let textLeft = icon.frame.maxX + 10
        let textRight = (chevron.isHidden ? badge.frame.minX : chevron.frame.minX) - 8
        let titleWidth = min(ceil(title.attributedStringValue.size().width) + 4, max(0, textRight - textLeft))
        let titleHeight = title.intrinsicContentSize.height
        title.frame = NSRect(x: textLeft, y: (height - titleHeight) / 2, width: titleWidth, height: titleHeight)
        let detailLeft = title.frame.maxX + 8
        let detailHeight = detail.intrinsicContentSize.height
        detail.frame = NSRect(x: detailLeft, y: (height - detailHeight) / 2 + 1,
                              width: max(0, textRight - detailLeft), height: detailHeight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard let row, row.isSelectable else { return }
        onHover?(row.id)
    }

    override func mouseExited(with event: NSEvent) {
        if isHighlighted { onHover?(nil) }
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard let row, row.isSelectable, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onActivate?(row)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let row, row.isSelectable else { return false }
        onActivate?(row)
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let fill: NSColor = if isHighlighted {
                NSColor.quaternaryLabelColor.withAlphaComponent(0.35)
            } else if row?.serverIsLive != nil {
                NSColor.quaternaryLabelColor.withAlphaComponent(0.10)
            } else {
                .clear
            }
            layer?.backgroundColor = fill.cgColor
            serverIndicator.layer?.backgroundColor = (row?.serverIsLive == true ? NSColor.systemGreen : .tertiaryLabelColor).cgColor
        }
    }
}

/// The rounded key cap shown at the trailing edge of each row.
@MainActor
private final class NewTabKeyBadge: NSView {
    private let label = CockpitUI.label("", size: 12, weight: .semibold, color: .labelColor)
    var key: String? { didSet { label.stringValue = key?.uppercased() ?? ""; needsLayout = true } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        label.alignment = .center
        addSubview(label)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayer()
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}
