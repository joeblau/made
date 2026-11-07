import AppKit
import Observation
import SwiftData

/// Four stable screen slots per saved group. The controller owns presentation;
/// RemoteDesktopSessionManager continues to own connections across navigation.
@MainActor
final class RemoteDesktopViewController: NSViewController, CockpitPanePresenting {
    let store: WorkspaceStore
    let sessions: RemoteDesktopSessionManager
    let groups: RemoteDesktopGroups
    private let isLive: Bool
    private let isolatedDefaultsName: String?
    private let header = NSStackView()
    private lazy var tabStrip = CockpitTabStrip(stack: header)
    private let grid = RemoteDesktopGridView()
    private let observation = RRObservation()
    private var panes: [UUID: RemoteConnectionViewController] = [:]
    private var knownIDs: [UUID] = []
    private var active = false
    private var picker: RemoteComputerPickerController?
    private var removalID: UUID?
    private var zoomObservation: RRZoomObservation?

    init(store: WorkspaceStore, sessions: RemoteDesktopSessionManager? = nil,
         groups: RemoteDesktopGroups? = nil, isLive: Bool = true) {
        self.store = store
        self.isLive = isLive
        self.sessions = isLive ? (sessions ?? .shared) : RemoteDesktopSessionManager()
        if let groups {
            self.groups = groups
            isolatedDefaultsName = nil
        } else if isLive {
            self.groups = RemoteDesktopGroups()
            isolatedDefaultsName = nil
        } else {
            let name = "app.blau.cockpit.remote-fixture.\(UUID().uuidString)"
            isolatedDefaultsName = name
            self.groups = RemoteDesktopGroups(defaults: UserDefaults(suiteName: name)!)
        }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        if let isolatedDefaultsName { UserDefaults.standard.removePersistentDomain(forName: isolatedDefaultsName) }
    }

    override func loadView() {
        view = RRBackgroundView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        tabStrip.setAccessibilityIdentifier("remote.groups")
        let stack = RRUI.stack([tabStrip, grid], spacing: 4)
        RRUI.fillWidth(stack)
        RRUI.pin(stack, to: view)
        zoomObservation = RRZoomObservation { [weak self] in
            if let self {
                RRUI.zoomControls(in: self.view)
                self.tabStrip.needsLayout = true
            }
        }
        render()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        updatePresentation(isActive: true, isSelected: true)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        updatePresentation(isActive: false, isSelected: false)
    }

    func updatePresentation(isActive: Bool, isSelected: Bool) {
        if isActive { _ = view }
        guard active != isActive else { return }
        active = isActive
        guard isViewLoaded else { return }
        if active {
            render()
            observation.start(tracking: { [weak self] in
                guard let self else { return }
                _ = self.store.remoteConnections.map { ($0.id, $0.displayTitle, $0.username) }
                _ = self.store.selectedRemoteConnectionID
                _ = self.store.remoteConnectionPendingClose
                _ = self.groups.groups
                _ = self.groups.selectedGroupID
            }, changed: { [weak self] in self?.render() })
        } else {
            observation.stop()
            picker?.cancel()
            for pane in panes.values { pane.setVisible(false) }
            if isLive { sessions.setActiveConnections([]) }
        }
    }

    private func render() {
        let connections = store.remoteConnections
        let ids = connections.map(\.id)
        if ids != knownIDs || groups.groups.isEmpty {
            groups.reconcile(connectionIDs: ids)
            knownIDs = ids
        }
        let selected = groups.selectConnection(store.selectedRemoteConnectionID)
        if selected != store.selectedRemoteConnectionID { store.selectedRemoteConnectionID = selected }
        for id in Array(panes.keys) where !ids.contains(id) {
            let pane = panes.removeValue(forKey: id)
            pane?.setVisible(false)
            pane?.view.removeFromSuperview()
            pane?.removeFromParent()
        }
        renderHeader()
        let group = groups.selectedGroup
        let visible = Set(group?.connectionIDs ?? [])
        for (id, pane) in panes { pane.setVisible(active && visible.contains(id)) }
        var cells: [NSView] = []
        for slot in 0..<RemoteDesktopGroup.capacity {
            if let id = group?.slots[slot], let connection = connections.first(where: { $0.id == id }) {
                let pane: RemoteConnectionViewController
                if let existing = panes[id] {
                    pane = existing
                } else {
                    pane = RemoteConnectionViewController(connection: connection, session: sessions.session(for: id), isLive: isLive)
                    pane.onActivate = { [weak self] in self?.store.selectedRemoteConnectionID = id }
                    pane.makeMenu = { [weak self] in self?.connectionMenu(connection) ?? NSMenu() }
                    panes[id] = pane
                    addChild(pane)
                }
                pane.setSelected(store.selectedRemoteConnectionID == id)
                pane.setVisible(active)
                cells.append(pane.view)
            } else {
                let drop = RemoteDesktopDropView(frame: grid.frameForCell(at: slot))
                let button = RRButton("Add Computer", symbol: "display") { [weak self] in
                    guard let self, let group else { return }
                    self.showPicker(groupID: group.id, slot: slot)
                }
                button.setAccessibilityLabel("Add a computer to slot \(slot + 1)")
                button.isEnabled = isLive
                drop.showsEmptySurface = true
                let empty = RRUI.stack([
                    RRUI.label("Empty Screen", size: 16, weight: .semibold),
                    RRUI.label("Add a computer or drag one here.", size: 12, color: .secondaryLabelColor), button,
                ], spacing: 12)
                empty.alignment = .centerX
                empty.translatesAutoresizingMaskIntoConstraints = false
                drop.addSubview(empty)
                NSLayoutConstraint.activate([
                    empty.centerXAnchor.constraint(equalTo: drop.centerXAnchor),
                    empty.centerYAnchor.constraint(equalTo: drop.centerYAnchor),
                    empty.leadingAnchor.constraint(greaterThanOrEqualTo: drop.leadingAnchor, constant: 12),
                    empty.trailingAnchor.constraint(lessThanOrEqualTo: drop.trailingAnchor, constant: -12),
                ])
                drop.accept = { [weak self] raw in
                    guard let self, let group else { return false }
                    return self.move(raw, group: group.id, slot: slot)
                }
                cells.append(drop)
            }
        }
        grid.setCells(cells)
        if active && isLive { sessions.setActiveConnections(visible) }
        if let connection = store.remoteConnectionPendingClose { confirmRemoval(connection) }
    }

    private func renderHeader() {
        defer { tabStrip.needsLayout = true }
        RRUI.clear(header)
        for group in groups.groups {
            let button = RRButton(group.name) { [weak self] in
                guard let self else { return }
                self.store.selectedRemoteConnectionID = self.groups.selectGroup(group.id, preserving: self.store.selectedRemoteConnectionID)
                self.render()
            }
            button.setButtonType(.pushOnPushOff)
            button.state = group.id == groups.selectedGroupID ? .on : .off
            button.setAccessibilityLabel("Remote Desktop group \(group.name)")
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(RRMenuItem("Rename Group…", enabled: isLive) { [weak self] in self?.rename(group) })
            menu.addItem(RRMenuItem("Delete Empty Group", enabled: isLive && group.connectionIDs.isEmpty && groups.groups.count > 1) { [weak self] in
                guard self?.isLive == true else { return }
                self?.groups.deleteEmptyGroup(group.id)
                self?.render()
            })
            button.menu = menu
            let drop = RemoteDesktopDropView()
            RRUI.pin(button, to: drop)
            drop.accept = { [weak self] raw in self?.move(raw, group: group.id) ?? false }
            header.addArrangedSubview(drop)
        }
        let newGroup = RRButton("New Group", symbol: "plus") { [weak self] in
            guard let self, self.isLive else { return }
            let id = self.groups.addGroup()
            self.store.selectedRemoteConnectionID = nil
            self.render()
            if let group = self.groups.groups.first(where: { $0.id == id }) { self.rename(group) }
        }
        newGroup.isEnabled = isLive
        header.addArrangedSubview(newGroup)
        if let group = groups.selectedGroup {
            header.addArrangedSubview(RRUI.label("\(group.connectionIDs.count)/4", color: .secondaryLabelColor))
            let rename = RRButton("Rename", symbol: "pencil") { [weak self] in self?.rename(group) }
            rename.isEnabled = isLive
            header.addArrangedSubview(rename)
            let add = RRButton("Add Computer", symbol: "plus") { [weak self] in self?.showPicker(groupID: group.id, slot: nil) }
            add.isEnabled = isLive && !group.isFull
            header.addArrangedSubview(add)
        }
    }

    private func connectionMenu(_ connection: RemoteDesktopConnection) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for group in groups.groups where !group.connectionIDs.contains(connection.id) {
            menu.addItem(RRMenuItem("Move to \(group.name)", enabled: isLive && !group.isFull) { [weak self] in
                guard self?.isLive == true else { return }
                _ = self?.groups.place(connection.id, in: group.id)
                self?.render()
            })
        }
        menu.addItem(RRMenuItem("Disconnect", enabled: isLive) { [weak self] in
            guard self?.isLive == true else { return }
            self?.sessions.session(for: connection.id).disconnect()
        })
        menu.addItem(RRMenuItem("Remove Connection…", enabled: isLive) { [weak self] in
            guard self?.isLive == true else { return }
            self?.store.requestCloseRemoteConnection(connection)
            self?.confirmRemoval(connection)
        })
        return menu
    }

    private func move(_ raw: String, group: UUID, slot: Int? = nil) -> Bool {
        guard isLive, let id = UUID(uuidString: raw), store.remoteConnections.contains(where: { $0.id == id }) else { return false }
        let moved = groups.place(id, in: group, slot: slot)
        if moved { render() }
        return moved
    }

    private func rename(_ group: RemoteDesktopGroup) {
        guard isLive, let parent = view.window, parent.attachedSheet == nil else { return }
        let field = NSTextField(string: group.name)
        field.setAccessibilityLabel("Group name")
        let alert = NSAlert()
        alert.messageText = "Rename Group"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.beginSheetModal(for: parent) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.groups.renameGroup(group.id, to: field.stringValue)
            self?.render()
        }
        alert.window.makeFirstResponder(field)
    }

    private func confirmRemoval(_ connection: RemoteDesktopConnection) {
        guard isLive, removalID == nil, let parent = view.window, parent.attachedSheet == nil else { return }
        removalID = connection.id
        let alert = NSAlert()
        alert.messageText = "Remove Connection?"
        alert.informativeText = "“\(connection.displayTitle)” will be removed from your saved connections."
        alert.addButton(withTitle: "Remove Connection")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: parent) { [weak self] response in
            guard let self else { return }
            self.removalID = nil
            if response == .alertFirstButtonReturn {
                self.sessions.endSession(for: connection.id)
                self.store.deleteRemoteConnection(connection)
            }
            self.store.remoteConnectionPendingClose = nil
            self.render()
        }
    }

    private func showPicker(groupID: UUID, slot: Int?) {
        guard isLive, let parent = view.window, parent.attachedSheet == nil else { return }
        let picker = RemoteComputerPickerController()
        self.picker = picker
        picker.onPick = { [weak self] host, port, nickname in
            guard let self, let group = self.groups.groups.first(where: { $0.id == groupID }), !group.isFull else { return }
            let connection = self.store.addRemoteConnection(host: host, port: port, nickname: nickname)
            self.groups.place(connection.id, in: groupID, slot: slot)
            self.render()
        }
        picker.onClose = { [weak self] in self?.picker = nil }
        picker.present(on: parent)
    }
}

@MainActor
private final class RemoteDesktopGridView: NSView {
    override var isFlipped: Bool { true }
    func setCells(_ cells: [NSView]) {
        for child in subviews where !cells.contains(where: { $0 === child }) { child.removeFromSuperview() }
        for (index, child) in cells.enumerated() { child.frame = frameForCell(at: index) }
        for child in cells where child.superview !== self { addSubview(child) }
        cellsInOrder = cells
        needsLayout = true
    }
    private var cellsInOrder: [NSView] = []
    override func layout() {
        super.layout()
        guard bounds.width > 28, bounds.height > 28 else { return }
        for (index, cell) in cellsInOrder.enumerated() { cell.frame = frameForCell(at: index) }
    }

    /// Frame-managed cards need usable dimensions before their child constraints
    /// are installed, including while the controller is loaded offscreen.
    func frameForCell(at index: Int) -> NSRect {
        let gap: CGFloat = 12
        let width = ((bounds.width > 28 ? bounds.width : 1000) - 28) / 2
        let height = ((bounds.height > 28 ? bounds.height : 748) - 28) / 2
        return NSRect(x: 8 + CGFloat(index % 2) * (width + gap),
                      y: 8 + CGFloat(index / 2) * (height + gap), width: width, height: height)
    }
}

@MainActor
private final class RemoteDesktopDropView: NSView {
    var accept: (String) -> Bool = { _ in false }
    var showsEmptySurface = false { didSet { refreshSurface() } }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.string])
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshSurface()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshSurface()
    }
    private func refreshSurface() {
        guard showsEmptySurface else { return }
        wantsLayer = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = 12
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.borderWidth = 1
        }
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.string(forType: .string).flatMap(UUID.init(uuidString:)) == nil ? [] : .move
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let text = sender.draggingPasteboard.string(forType: .string) else { return false }
        return accept(text)
    }
}

@MainActor
private final class RemoteConnectionViewController: NSViewController, NSTextFieldDelegate {
    let connection: RemoteDesktopConnection
    let session: RemoteDesktopSession
    private let isLive: Bool
    var onActivate: () -> Void = {}
    var makeMenu: () -> NSMenu = { NSMenu() }
    private let observation = RRObservation()
    private let content = NSView()
    private let status = RRUI.label("Not connected", size: 11, color: .secondaryLabelColor)
    private let username = NSTextField(string: "")
    private let password = NSSecureTextField(string: "")
    private let save = NSButton(checkboxWithTitle: "Save password", target: nil, action: nil)
    private let automatic = NSButton(checkboxWithTitle: "Connect automatically", target: nil, action: nil)
    private let clipboard = NSButton(checkboxWithTitle: "Share clipboard", target: nil, action: nil)
    private let reconnect = RRButton("Reconnect", action: {})
    private var viewer: RemoteDesktopViewer?
    private var visible = false
    private var restored = false
    private var selected = false
    private var previousStatus: RemoteConnectionStatus?
    private var displayedStatus: RemoteConnectionStatus?
    private var primary: NSButton?
    private var cancel: NSButton?
    private var rejectedCredential = false
    private var zoomObservation: RRZoomObservation?

    init(connection: RemoteDesktopConnection, session: RemoteDesktopSession, isLive: Bool) {
        self.connection = connection
        self.session = session
        self.isLive = isLive
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let surface = RemoteConnectionSurface(frame: NSRect(x: 0, y: 0, width: 486, height: 360))
        surface.onActivate = { [weak self] in self?.onActivate() }
        view = surface
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.masksToBounds = true
        let header = RemoteConnectionHeader(id: connection.id, title: connection.displayTitle)
        header.onActivate = { [weak self] in self?.onActivate() }
        header.menuProvider = { [weak self] in self?.makeMenu() ?? NSMenu() }
        let headerHeight = header.heightAnchor.constraint(equalToConstant: 30)
        headerHeight.isActive = true
        username.stringValue = connection.username
        username.setAccessibilityLabel("Username")
        username.delegate = self
        password.setAccessibilityLabel("Password")
        password.delegate = self
        username.isEnabled = isLive
        password.isEnabled = isLive
        save.isEnabled = isLive
        automatic.isEnabled = isLive
        clipboard.isEnabled = isLive
        reconnect.isEnabled = isLive
        password.target = self
        password.action = #selector(connect)
        save.target = self
        save.action = #selector(saveChanged)
        automatic.target = self
        automatic.action = #selector(autoChanged)
        clipboard.target = self
        clipboard.action = #selector(clipboardChanged)
        clipboard.toolTip = "Allows this remote VNC server to read and replace your Mac clipboard."
        clipboard.state = isLive && VNCPreferences.isClipboardRedirectionEnabled(id: connection.id) ? .on : .off
        reconnect.perform = { [weak self] in self?.reconnectSession() }
        let footer = RRUI.stack([clipboard, RRUI.spacer(), status, reconnect], axis: .horizontal)
        footer.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        let stack = RRUI.stack([header, content, footer], spacing: 0)
        RRUI.fillWidth(stack)
        RRUI.pin(stack, to: view)
        zoomObservation = RRZoomObservation { [weak self] in
            headerHeight.constant = 30 * RRUI.zoom
            if let self { RRUI.zoomControls(in: self.view) }
        }
        render()
    }

    func setSelected(_ selected: Bool) {
        self.selected = selected
        if isViewLoaded {
            view.layer?.borderColor = NSColor.controlAccentColor.cgColor
            view.layer?.borderWidth = selected ? 2 : 0
            primary?.keyEquivalent = selected ? "\r" : ""
            cancel?.keyEquivalent = selected ? "\u{1b}" : ""
        }
    }

    func controlTextDidBeginEditing(_ obj: Notification) { onActivate() }

    func setVisible(_ visible: Bool) {
        guard self.visible != visible else { return }
        self.visible = visible
        if visible {
            _ = view
            restoreCredentials()
            render()
            observation.start(tracking: { [weak self] in
                guard let self else { return }
                _ = self.session.status
                _ = self.session.framebufferGeneration
                _ = self.session.credentialRejected
            }, changed: { [weak self] in self?.render() })
        } else {
            observation.stop()
            if let responder = view.window?.firstResponder as? NSView,
               responder === view || responder.isDescendant(of: view) {
                view.window?.makeFirstResponder(nil)
            }
            viewer?.detach()
            viewer?.removeFromSuperview()
            viewer = nil
            displayedStatus = nil
        }
    }

    private func restoreCredentials() {
        guard isLive, !restored else { return }
        restored = true
        let saved = VNCKeychain.load(id: connection.id)
        let hasSaved = !(saved ?? "").isEmpty
        save.state = hasSaved ? .on : .off
        automatic.isEnabled = hasSaved
        automatic.state = VNCPreferences.isAutoConnectEnabled(id: connection.id, hasSavedPassword: hasSaved) ? .on : .off
        password.stringValue = saved ?? ""
        guard hasSaved, automatic.state == .on else { return }
        switch session.status {
        case .idle, .disconnected: connect()
        case .connecting, .connected, .failed: break
        }
    }

    private func render() {
        guard isViewLoaded else { return }
        if session.credentialRejected && !rejectedCredential {
            password.stringValue = ""
        }
        rejectedCredential = session.credentialRejected
        if isLive, session.status == .connected, previousStatus != .connected {
            connection.lastConnectedAt = Date()
            _ = connection.modelContext?.saveReporting(operation: "Recording remote desktop connection")
        }
        previousStatus = session.status
        let changed = displayedStatus != session.status || (session.isLive && viewer == nil)
        if changed {
            displayedStatus = session.status
            for child in content.subviews { child.removeFromSuperview() }
            primary = nil
            cancel = nil
            switch session.status {
            case .connecting, .connected:
                if viewer == nil { viewer = RemoteDesktopViewer(session: session, framebufferGeneration: session.framebufferGeneration, onActivate: onActivate) }
                if let viewer { RRUI.pin(viewer, to: content) }
                if session.status == .connecting {
                    let cancelButton = RRButton("Cancel") { [weak self] in self?.session.disconnect() }
                    cancel = cancelButton
                    let indicator = NSProgressIndicator()
                    indicator.style = .spinning
                    indicator.startAnimation(nil)
                    let overlay = RRUI.stack([indicator, RRUI.label("Connecting to \(connection.displayTitle)…"), cancelButton])
                    overlay.alignment = .centerX
                    let background = NSVisualEffectView()
                    background.material = .hudWindow
                    background.blendingMode = .withinWindow
                    RRUI.pin(background, to: content)
                    RRUI.pin(overlay, to: background, inset: 20)
                }
            case .idle, .disconnected:
                showForm(error: nil)
            case .failed(let message):
                showForm(error: message)
            }
        }
        viewer?.update(generation: session.framebufferGeneration, onActivate: onActivate)
        switch session.status {
        case .connected: status.stringValue = "Connected"; status.textColor = .systemGreen
        case .connecting: status.stringValue = "Connecting…"; status.textColor = .systemOrange
        case .failed: status.stringValue = "Not connected"; status.textColor = .systemRed
        case .idle, .disconnected: status.stringValue = "Not connected"; status.textColor = .secondaryLabelColor
        }
        reconnect.isHidden = !session.isLive || session.activeConnection?.settings.isClipboardRedirectionEnabled == (clipboard.state == .on)
        setSelected(selected)
    }

    private func showForm(error: String?) {
        viewer?.detach()
        viewer = nil
        // A compact sign-in column: identity first, then credentials, then
        // options, then one primary action. It stays narrow and centered
        // however wide the card is.
        let symbol = NSImageView(image: NSImage(systemSymbolName: "display", accessibilityDescription: nil) ?? NSImage())
        symbol.symbolConfiguration = .init(pointSize: 26 * RRUI.zoom, weight: .regular)
        symbol.contentTintColor = .secondaryLabelColor
        let heading = RRUI.label("Sign in to screen sharing", size: 15, weight: .semibold)
        let address = RRUI.label("\(connection.host):\(connection.port)", size: 12, color: .secondaryLabelColor)
        for label in [heading, address] { label.alignment = .center; label.lineBreakMode = .byTruncatingMiddle }
        let identity = RRUI.stack([symbol, heading, address], spacing: 4)
        identity.alignment = .centerX
        identity.setCustomSpacing(10, after: symbol)
        for field in [username, password] as [NSTextField] {
            field.controlSize = .large
            field.bezelStyle = .roundedBezel
        }
        let usernameGroup = RRUI.stack([
            RRUI.label("Username (optional)", size: 11, weight: .medium, color: .secondaryLabelColor), username,
        ], spacing: LiquidGlassMetrics.Spacing.xxSmall)
        let passwordGroup = RRUI.stack([
            RRUI.label("Password", size: 11, weight: .medium, color: .secondaryLabelColor), password,
        ], spacing: LiquidGlassMetrics.Spacing.xxSmall)
        RRUI.fillWidth(usernameGroup)
        RRUI.fillWidth(passwordGroup)
        let options = RRUI.stack([save, automatic], spacing: 6)
        let form = RRUI.stack([identity, usernameGroup, passwordGroup, options], spacing: 12)
        form.setCustomSpacing(20, after: identity)
        form.setCustomSpacing(16, after: passwordGroup)
        form.setCustomSpacing(20, after: options)
        if let error {
            let message = RRUI.label(error, size: 12, color: .systemRed)
            message.maximumNumberOfLines = 3
            form.addArrangedSubview(message)
        }
        let button = RRButton(error == nil ? "Connect" : "Try Again") { [weak self] in self?.connect() }
        button.controlSize = .large
        button.isEnabled = isLive && !connection.host.trimmingCharacters(in: .whitespaces).isEmpty
        primary = button
        form.addArrangedSubview(button)
        RRUI.fillWidth(form)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.setAccessibilityIdentifier("remote.credentials")
        let document = RemoteCredentialsDocument()
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        form.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(form)
        let preferredWidth = form.widthAnchor.constraint(equalToConstant: 300 * RRUI.zoom)
        preferredWidth.priority = .defaultHigh
        let snugHeight = document.heightAnchor.constraint(equalToConstant: 0)
        snugHeight.priority = .defaultLow
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            snugHeight,
            preferredWidth,
            form.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: 20),
            form.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -20),
            form.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            form.topAnchor.constraint(greaterThanOrEqualTo: document.topAnchor, constant: 20),
            form.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -20),
            form.centerYAnchor.constraint(equalTo: document.centerYAnchor),
        ])
        RRUI.pin(scroll, to: content)
        RRUI.zoomControls(in: form)
    }

    @objc private func connect() {
        guard isLive else { return }
        onActivate()
        connection.username = username.stringValue
        _ = connection.modelContext?.saveReporting(operation: "Saving remote desktop username")
        VNCPreferences.setClipboardRedirectionEnabled(clipboard.state == .on, id: connection.id)
        VNCPreferences.setAutoConnectEnabled(automatic.state == .on, id: connection.id)
        session.connect(host: connection.host, port: connection.port, username: connection.username,
                        password: password.stringValue, savePasswordOnSuccess: save.state == .on,
                        isClipboardRedirectionEnabled: clipboard.state == .on)
        render()
    }
    @objc private func saveChanged() {
        guard isLive else { return }
        automatic.isEnabled = save.state == .on
        if save.state != .on { automatic.state = .off; autoChanged() }
    }
    @objc private func autoChanged() {
        guard isLive else { return }
        VNCPreferences.setAutoConnectEnabled(automatic.state == .on, id: connection.id)
    }
    @objc private func clipboardChanged() {
        guard isLive else { return }
        VNCPreferences.setClipboardRedirectionEnabled(clipboard.state == .on, id: connection.id)
        render()
    }
    private func reconnectSession() {
        guard isLive else { return }
        session.disconnect()
        guard let saved = VNCKeychain.load(id: connection.id), !saved.isEmpty else { render(); return }
        password.stringValue = saved
        save.state = .on
        connect()
    }
}

@MainActor
private final class RemoteCredentialsDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class RemoteConnectionSurface: RRBackgroundView {
    var onActivate: () -> Void = {}
    override func hitTest(_ point: NSPoint) -> NSView? {
        let target = super.hitTest(point)
        guard target != nil, let event = NSApp.currentEvent, event.window === window,
              event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown else { return target }
        onActivate()
        return target
    }
}

@MainActor
private final class RemoteConnectionHeader: NSView, NSDraggingSource {
    let id: UUID
    var onActivate: () -> Void = {}
    var menuProvider: () -> NSMenu = { NSMenu() }
    private var down: NSEvent?
    init(id: UUID, title: String) {
        self.id = id
        super.init(frame: .zero)
        let titleField = RRUI.label(title, size: 12, weight: .medium)
        titleField.maximumNumberOfLines = 1
        let options = RRButton("", symbol: "ellipsis") { }
        options.setAccessibilityLabel("Options for \(title)")
        options.perform = { [weak self, weak options] in
            guard let self, let options else { return }
            self.menuProvider().popUp(positioning: nil, at: NSPoint(x: 0, y: options.bounds.maxY), in: options)
        }
        let stack = RRUI.stack([titleField, RRUI.spacer(), options], axis: .horizontal)
        RRUI.pin(stack, to: self, inset: 4)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { nil }
    override func accessibilityPerformPress() -> Bool { onActivate(); return true }
    override func mouseDown(with event: NSEvent) { down = event; onActivate() }
    override func mouseDragged(with event: NSEvent) {
        guard let down else { return }
        self.down = nil
        let item = NSDraggingItem(pasteboardWriter: id.uuidString as NSString)
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        image.unlockFocus()
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: down, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
}

@MainActor
private final class RemoteComputerPickerController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var onPick: (String, Int, String) -> Void = { _, _, _ in }
    var onClose: () -> Void = {}
    private let discovery = RemoteScreenDiscovery()
    private let observation = RRObservation()
    private let table = NSTableView()
    private let host = NSTextField(string: "")
    private let stateLabel = RRUI.label("Looking for computers with Screen Sharing enabled…", color: .secondaryLabelColor)
    private let connectButton = RRButton("Connect", action: {})
    private var sheet: NSWindow?
    private var resolveTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var closed = false
    private var zoomObservation: RRZoomObservation?

    override func loadView() {
        let title = RRUI.label("Computers on This Network", size: 17, weight: .semibold)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 30
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(pickSelected)
        table.setAccessibilityLabel("Discovered computers")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        scroll.heightAnchor.constraint(equalToConstant: 190).isActive = true
        host.placeholderString = "Host, IP address, or MagicDNS name"
        host.setAccessibilityLabel("Host Address")
        host.delegate = self
        host.target = self
        host.action = #selector(connectManual)
        connectButton.perform = { [weak self] in self?.connectManual() }
        connectButton.keyEquivalent = "\r"
        connectButton.isEnabled = false
        let pick = RRButton("Use Selected Computer") { [weak self] in self?.pickSelected() }
        let cancel = RRButton("Cancel") { [weak self] in self?.cancel() }
        cancel.keyEquivalent = "\u{1b}"
        let settings = RRButton("Open Local Network Settings") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") { NSWorkspace.shared.open(url) }
        }
        let content = RRUI.stack([
            title, stateLabel, scroll, pick,
            RRUI.label("Enable Screen Sharing on the target Mac and allow Cockpit Local Network access. You can also enter a host address below.", size: 11, color: .secondaryLabelColor),
            settings, RRUI.label("Host Address", weight: .medium), host,
            RRUI.stack([RRUI.spacer(), cancel, connectButton], axis: .horizontal),
        ], spacing: 10)
        RRUI.fillWidth(content)
        view = content
        zoomObservation = RRZoomObservation { [weak self] in
            guard let self else { return }
            RRUI.zoomControls(in: self.view)
            self.sheet?.setContentSize(NSSize(width: 540 * RRUI.zoom, height: 540 * RRUI.zoom))
        }
    }

    func present(on parent: NSWindow) {
        let sheet = RRUI.sheet(view, width: 540 * RRUI.zoom, height: 540 * RRUI.zoom)
        self.sheet = sheet
        parent.beginSheet(sheet) { [weak self] _ in self?.finish() }
        sheet.makeFirstResponder(host)
        discovery.start()
        observation.start(tracking: { [weak self] in
            _ = self?.discovery.services
            _ = self?.discovery.browseState
        }, changed: { [weak self] in self?.refresh() })
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.discovery.retryIfNeedsPermission() }
        }
        refresh()
    }

    func cancel() {
        if let sheet { RRUI.dismiss(sheet) }
        finish()
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        resolveTask?.cancel()
        resolveTask = nil
        observation.stop()
        discovery.stop()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        sheet = nil
        onClose()
    }

    private func refresh() {
        table.reloadData()
        switch discovery.browseState {
        case .needsPermission(let detail), .failed(let detail):
            stateLabel.stringValue = "Cockpit can't browse the local network. \(detail)"
        default:
            stateLabel.stringValue = discovery.services.isEmpty ? "Looking for computers with Screen Sharing enabled…" : "Select a computer or enter a host address."
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { discovery.services.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard discovery.services.indices.contains(row) else { return nil }
        return RRUI.label(discovery.services[row].name)
    }
    func controlTextDidChange(_ obj: Notification) { connectButton.isEnabled = !host.stringValue.trimmingCharacters(in: .whitespaces).isEmpty }
    @objc private func connectManual() {
        let text = host.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let (hostname, port) = RemoteDesktopAddress.parse(text)
        guard !hostname.isEmpty, (1...65535).contains(port) else { stateLabel.stringValue = "Enter a host and a port from 1 to 65535."; return }
        onPick(hostname, port, "")
        cancel()
    }
    @objc private func pickSelected() {
        guard resolveTask == nil, discovery.services.indices.contains(table.selectedRow) else { return }
        let service = discovery.services[table.selectedRow]
        table.isEnabled = false
        stateLabel.stringValue = "Resolving \(service.name)…"
        resolveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let address = await self.discovery.resolve(service)
            guard !Task.isCancelled, !self.closed else { return }
            self.onPick(address?.host ?? service.name, address?.port ?? 5900, service.name)
            self.cancel()
        }
    }
}

enum RemoteDesktopAddress {
    static func parse(_ input: String) -> (host: String, port: Int) {
        if input.hasPrefix("["), let close = input.firstIndex(of: "]") {
            let host = String(input[input.index(after: input.startIndex)..<close])
            let rest = input[input.index(after: close)...]
            return (host, rest.hasPrefix(":") ? Int(rest.dropFirst()) ?? 5900 : 5900)
        }
        if input.filter({ $0 == ":" }).count >= 2 { return (input, 5900) }
        if let colon = input.lastIndex(of: ":"), let port = Int(input[input.index(after: colon)...]) {
            return (String(input[..<colon]), port)
        }
        return (input, 5900)
    }
}
