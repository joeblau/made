import AppKit

@MainActor
final class DroneSettingsViewController: NSViewController {
    private let store: DroneStore
    private let runsDiscovery: Bool
    private let observation = NativeSettingsObservation()
    private let body = NativeSettingsUI.column(spacing: 20)
    private let saved = NativeSettingsGroupView()
    private let discovered = NativeSettingsGroupView()
    private let approvals = NativeSettingsUI.column(spacing: 20)
    private let errors = NativeSettingsUI.label("", color: .systemOrange)
    private let savedHeading = NativeSettingsUI.label("", weight: .semibold)
    private let discoveryStatus = NativeSettingsUI.label("", size: 11, color: .secondaryLabelColor)
    private var discoveryRow: NSView?
    private var savedRowsInstalled = false
    private var discoveredRowsInstalled = false
    private var rows: [UUID: NativeDroneRow] = [:]
    private var recordOrder: [UUID] = []
    private var candidates: [DroneDiscoveryCandidate] = []
    private var requests: [DronePairingRequest] = []
    private var actionError: String?

    init(store: DroneStore, runsDiscovery: Bool = true) {
        self.store = store
        self.runsDiscovery = runsDiscovery
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        body.addArrangedSubview(NativeSettingsUI.pageTitle("Drones"))
        NativeSettingsUI.fillWidth(errors, in: body)
        NativeSettingsUI.fillWidth(approvals, in: body)
        let savedSection = NativeSettingsUI.column(spacing: 6)
        NativeSettingsUI.fillWidth(savedHeading, in: savedSection)
        NativeSettingsUI.fillWidth(saved, in: savedSection)
        savedSection.toolTip = "Offline and unauthorized Drones stay listed. Cockpit never substitutes Local when a Drone is unavailable."
        NativeSettingsUI.fillWidth(savedSection, in: body)
        let retry = NativeSettingsButton("Retry") { [weak self] in self?.store.discovery.retry() }
        retry.toolTip = "Retry Discovery"
        let add = NativeSettingsButton("Add by Address…") { [weak self] in self?.addManual() }
        discoveryRow = NativeSettingsUI.formRow("Local Network", subtitle: discoveryStatus, accessories: [retry, add])
        let discover = NativeSettingsUI.group("Discover", box: discovered)
        discover.toolTip = "Bonjour names, addresses, and protocol advertisements are hints only. A Drone becomes connected only after authenticated identity and capability negotiation."
        NativeSettingsUI.fillWidth(discover, in: body)
        view = NativeSettingsUI.scrolling(body)
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        if runsDiscovery { store.startDiscovery() }
        observation.start { [weak self] in self?.refresh() }
    }
    override func viewWillDisappear() {
        super.viewWillDisappear()
        observation.stop()
        if runsDiscovery { store.stopDiscovery() }
    }

    func refresh() {
        guard isViewLoaded else { return }
        errors.stringValue = [store.persistenceError, actionError].compactMap { $0 }.joined(separator: "\n")
        errors.isHidden = errors.stringValue.isEmpty
        savedHeading.stringValue = "Saved Drones (\(store.records.count)/\(DroneLimits.maxPairedWorkers))"
        let records = store.records
        let ids = records.map(\.id)
        if ids != recordOrder || !savedRowsInstalled {
            savedRowsInstalled = true
            rows = rows.filter { ids.contains($0.key) }
            var savedRows: [NSView] = []
            if records.isEmpty {
                savedRows.append(NativeSettingsUI.formRow(NativeSettingsUI.label("No saved Drones", color: .secondaryLabelColor)))
            }
            for record in records {
                let row = rows[record.id] ?? NativeDroneRow(
                    retry: { [weak self] in self?.store.retry(id: record.id) },
                    rename: { [weak self] in self?.rename(id: record.id) },
                    diagnostics: { [weak self] in self?.showDiagnostics(id: record.id) },
                    forget: { [weak self] in self?.forget(id: record.id) }
                )
                rows[record.id] = row
                savedRows.append(row)
            }
            saved.setRows(savedRows)
            recordOrder = ids
        }
        for record in records {
            rows[record.id]?.update(
                record: record, state: store.states[record.id] ?? .pairing,
                forgetting: store.forgettingIDs.contains(record.id)
            )
        }
        let pairing = store.pairingRequests.values.sorted { $0.peerID.rawValue.uuidString < $1.peerID.rawValue.uuidString }
        if pairing != requests {
            requests = pairing
            NativeSettingsUI.clear(approvals)
            for request in pairing {
                let message = request.isKeyChange
                    ? "This Drone’s identity changed. Verify before approving."
                    : "Verify this code on both Macs before approving."
                let code = NativeSettingsUI.label(request.verificationCode, size: 18, selectable: true)
                code.usesMonospacedFont = true
                let approve = NativeSettingsButton("Approve") { [weak self] in
                    guard self?.store.pairingRequests[request.id] == request else { return }
                    self?.store.resolvePairing(requestID: request.id, approved: true)
                }
                let reject = NativeSettingsButton("Reject") { [weak self] in
                    self?.store.resolvePairing(requestID: request.id, approved: false)
                }
                NativeSettingsUI.fillWidth(NativeSettingsUI.group("Pairing Approval", [
                    NativeSettingsUI.formRow(message),
                    NativeSettingsUI.formRow(code, accessories: [reject, approve]),
                ]), in: approvals)
            }
        }
        approvals.isHidden = pairing.isEmpty
        switch store.discovery.browseState {
        case .idle: discoveryStatus.stringValue = "Waiting for discovery…"
        case .browsing: discoveryStatus.stringValue = "Browsing the local network"
        case .needsPermission(let message), .failed(let message): discoveryStatus.stringValue = message
        }
        let available = store.availableCandidates
        if available != candidates || !discoveredRowsInstalled {
            discoveredRowsInstalled = true
            candidates = available
            var discoveredRows: [NSView] = discoveryRow.map { [$0] } ?? []
            for candidate in available {
                let version = candidate.advertisedProtocolVersions.isEmpty ? "Unverified"
                    : "Unverified · protocol \(candidate.advertisedProtocolVersions.map(String.init).joined(separator: ", "))"
                discoveredRows.append(NativeSettingsUI.formRow(
                    candidate.displayName,
                    subtitle: NativeSettingsUI.label(version, size: 11, color: .secondaryLabelColor),
                    accessories: [NativeSettingsButton("Pair") { [weak self] in self?.pair(candidate) }]
                ))
            }
            discovered.setRows(discoveredRows)
        }
    }

    private func pair(_ candidate: DroneDiscoveryCandidate) {
        do { _ = try store.pair(candidate); actionError = nil } catch { actionError = Self.describe(error) }
        refresh()
    }

    private func addManual() {
        let form = NativeSettingsFormController(
            title: "Add Drone by Address",
            detail: "The address is only a connection hint. Pairing and pinned identity verification are required before work can be sent.",
            fields: [.init(title: "Display name (optional)"), .init(title: "Hostname or IP address"), .init(title: "Port")],
            confirmTitle: "Add and Pair"
        ) { [weak self] values in
            guard let self else { return "This settings window is no longer available." }
            do {
                _ = try self.store.addManual(name: values[0], host: values[1], port: values[2])
                self.actionError = nil
                return nil
            } catch { return Self.describe(error) }
        }
        presentAsSheet(form)
    }

    private func rename(id: UUID) {
        guard let record = store.records.first(where: { $0.id == id }) else { return }
        let form = NativeSettingsFormController(
            title: "Rename Drone", fields: [.init(title: "Display name", value: record.name)], confirmTitle: "Save"
        ) { [weak self] values in
            guard let self else { return "This settings window is no longer available." }
            do { try self.store.rename(id: id, to: values[0]); self.actionError = nil; return nil } catch { return Self.describe(error) }
        }
        presentAsSheet(form)
    }

    private func forget(id: UUID) {
        guard let record = store.records.first(where: { $0.id == id }), let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Forget and Revoke Drone?"
        alert.informativeText = "This closes \(record.name), removes its saved metadata, and deletes its local pairing pin. Remote sessions are not terminated."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Forget and Revoke")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task { await self.store.forget(id: id) }
        }
    }

    private func showDiagnostics(id: UUID) {
        presentAsSheet(DroneDiagnosticsViewController(store: store, id: id))
    }

    private static func describe(_ error: any Error) -> String {
        switch error as? DroneRegistryError {
        case .invalidName: "Enter a name between 1 and 80 UTF-8 bytes."
        case .invalidEndpoint: "Enter a valid hostname or IP address and a port from 1 to 65535."
        case .registryFull: "Cockpit supports at most \(DroneLimits.maxPairedWorkers) saved Drones."
        case .duplicateDrone: "This discovered Drone is already saved."
        case .persistenceUnavailable: "The saved registry is read-only because it could not be loaded."
        default: "Cockpit could not save the Drone registry. Check disk permissions and available space."
        }
    }
}

@MainActor
private final class NativeDroneRow: NSView {
    private let name = NativeSettingsUI.label("", weight: .semibold)
    private let summary = NativeSettingsUI.label("", size: 11, color: .secondaryLabelColor, selectable: true)
    private let status = NativeSettingsUI.label("", weight: .medium)
    private let detail = NativeSettingsUI.label("", size: 11, color: .secondaryLabelColor)
    private let actionsButton = NSButton()
    private let actions: [() -> Void]
    private let menuItems: [NSMenuItem]

    init(retry: @escaping () -> Void, rename: @escaping () -> Void, diagnostics: @escaping () -> Void, forget: @escaping () -> Void) {
        actions = [retry, diagnostics, rename, forget]
        menuItems = ["Retry", "Diagnostics", "Rename…", "Forget and Revoke…"].map {
            NSMenuItem(title: $0, action: #selector(NativeDroneRow.performMenuAction(_:)), keyEquivalent: "")
        }
        super.init(frame: .zero)
        for (index, item) in menuItems.enumerated() {
            item.tag = index
            item.target = self
        }
        actionsButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Drone Actions")
        actionsButton.isBordered = false
        actionsButton.imagePosition = .imageOnly
        actionsButton.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        actionsButton.contentTintColor = .secondaryLabelColor
        actionsButton.toolTip = "Drone Actions"
        actionsButton.setAccessibilityLabel("Drone Actions")
        actionsButton.target = self
        actionsButton.action = #selector(showActions)
        status.alignment = .right
        status.maximumNumberOfLines = 1
        summary.maximumNumberOfLines = 1
        summary.lineBreakMode = .byTruncatingMiddle
        let subtitle = NativeSettingsUI.column([summary, detail], spacing: 2)
        for label in [summary, detail] { label.widthAnchor.constraint(equalTo: subtitle.widthAnchor).isActive = true }
        NativeSettingsUI.pin(NativeSettingsUI.formRow(name, subtitle: subtitle, accessories: [status, actionsButton]), to: self)
    }
    required init?(coder: NSCoder) { nil }

    @objc private func showActions() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menuItems.forEach { $0.menu?.removeItem($0); menu.addItem($0) }
        menu.insertItem(.separator(), at: 3)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: actionsButton.bounds.maxY + 4), in: actionsButton)
    }

    @objc private func performMenuAction(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }

    func update(record: DroneRecord, state: DroneConnectionState, forgetting: Bool) {
        name.stringValue = record.name
        summary.stringValue = ([record.hardware.displayText] + record.endpoints.map(\.displayText))
            .filter { !$0.isEmpty }.joined(separator: " · ")
        summary.isHidden = summary.stringValue.isEmpty
        let presentation = Self.presentation(state)
        status.stringValue = presentation.0
        status.textColor = presentation.2
        // Healthy Drones need no explanation; problems keep their recovery hint.
        if case .connected = state {
            detail.stringValue = ""
            status.toolTip = presentation.1
        } else {
            detail.stringValue = presentation.1
            status.toolTip = nil
        }
        detail.isHidden = detail.stringValue.isEmpty
        for index in [0, 2, 3] { menuItems[index].isEnabled = !forgetting }
    }
    private static func presentation(_ state: DroneConnectionState) -> (String, String, NSColor) {
        switch state {
        case .pairing: ("Pairing required", DroneConnectionIssue.pairingRequired.recoveryInstruction, .systemOrange)
        case .connecting(let attempt): ("Connecting", "Identity and protocol probe, attempt \(attempt). Nothing is sent before authentication.", .systemBlue)
        case .connected(let peer):
            ("Connected", "Protocol \(peer.hello.selectedVersion.map(String.init) ?? "unknown") · \(peer.hello.capabilities.joined(separator: ", "))", .systemGreen)
        case .offline(let issue, let attempt):
            (issue.title, issue.recoveryInstruction + (attempt.map { " Automatic retry \($0) is scheduled." } ?? ""), .systemOrange)
        case .unauthorized(let issue): (issue.title, issue.recoveryInstruction, .systemRed)
        case .incompatible: ("Incompatible", DroneConnectionIssue.incompatible.recoveryInstruction, .systemRed)
        case .busy(let attempt): ("Busy", "\(DroneConnectionIssue.busy.recoveryInstruction) Retry \(attempt) is scheduled.", .systemOrange)
        case .forgetting: ("Forgetting", "Closing the connection and revoking the local pin.", .secondaryLabelColor)
        }
    }
}

@MainActor
private final class DroneDiagnosticsViewController: NSViewController {
    private let store: DroneStore
    private let id: UUID
    private let text = NativeSettingsTextView()
    private let heading = NativeSettingsUI.label("", size: 20, weight: .semibold)
    private let observation = NativeSettingsObservation()
    init(store: DroneStore, id: UUID) {
        self.store = store
        self.id = id
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        text.isEditable = false
        text.isSelectable = true
        text.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        text.autoresizingMask = [.width]
        let copy = NativeSettingsButton("Copy Diagnostics") { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.text.string, forType: .string)
        }
        let done = NativeSettingsButton("Done") { [weak self] in guard let self else { return }; self.dismiss(self) }
        done.keyEquivalent = "\r"
        let stack = NativeSettingsUI.column([heading, scroll, NativeSettingsUI.row([copy, NativeSettingsUI.spacer(), done])])
        NativeSettingsUI.fillWidth(NSView(), in: stack)
        view = NSView()
        NativeSettingsUI.pin(stack, to: view, inset: 24)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 360).isActive = true
        view.widthAnchor.constraint(equalToConstant: 620).isActive = true
        refresh()
    }
    override func viewWillAppear() { super.viewWillAppear(); observation.start { [weak self] in self?.refresh() } }
    override func viewWillDisappear() { super.viewWillDisappear(); observation.stop() }
    private func refresh() {
        guard let record = store.records.first(where: { $0.id == id }) else {
            heading.stringValue = "Drone removed"
            text.string = "This Drone is no longer saved."
            return
        }
        let state = store.states[id] ?? .pairing
        let diagnostics = store.diagnostics[id] ?? DroneDiagnostics()
        heading.stringValue = "\(record.name) Diagnostics"
        let header = [
            "Drone: \(record.name)", "Drone ID: \(record.id.uuidString)", "State: \(state)",
            "Generation: \(diagnostics.generation)", "Connect attempts: \(diagnostics.connectAttempts)",
            "Successful connections: \(diagnostics.successfulConnections)",
            "Verified identity: \(record.verifiedIdentityFingerprint ?? "Not paired")",
            "Endpoint: \(diagnostics.lastEndpoint?.displayText ?? "None")",
            "Last issue: \(diagnostics.lastIssue?.title ?? "None")", "", "Recent non-secret events"
        ]
        let events = diagnostics.entries.map { "\($0.timestamp.formatted(date: .omitted, time: .standard)) · \($0.event)" }
        let next = (header + events).joined(separator: "\n")
        if text.string != next { text.string = next }
    }
}
