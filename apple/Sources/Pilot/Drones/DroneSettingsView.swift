import AppKit

@MainActor
final class DroneSettingsViewController: NSViewController {
    private let store: DroneStore
    private let runsDiscovery: Bool
    private let observation = NativeSettingsObservation()
    private let body = NativeSettingsUI.column(spacing: 18)
    private let saved = NativeSettingsUI.column()
    private let discovered = NativeSettingsUI.column()
    private let approvals = NativeSettingsUI.column()
    private let errors = NativeSettingsUI.label("", color: .systemOrange)
    private let savedHeading = NativeSettingsUI.label("", size: 14, weight: .semibold)
    private let discoveryStatus = NativeSettingsUI.label("", color: .secondaryLabelColor)
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
        body.addArrangedSubview(NativeSettingsUI.label("Drones", size: 26, weight: .bold))
        NativeSettingsUI.fillWidth(NativeSettingsUI.label(
            "Pair and supervise secure remote execution workers on your local network.", color: .secondaryLabelColor
        ), in: body)
        NativeSettingsUI.fillWidth(errors, in: body)
        NativeSettingsUI.fillWidth(approvals, in: body)
        body.addArrangedSubview(savedHeading)
        NativeSettingsUI.fillWidth(saved, in: body)
        NativeSettingsUI.fillWidth(NativeSettingsUI.label(
            "Offline and unauthorized Drones stay listed. Cockpit never substitutes Local when a Drone is unavailable.",
            size: 11, color: .secondaryLabelColor
        ), in: body)
        body.addArrangedSubview(NativeSettingsUI.label("Discover", size: 14, weight: .semibold))
        NativeSettingsUI.fillWidth(discoveryStatus, in: body)
        NativeSettingsUI.fillWidth(discovered, in: body)
        body.addArrangedSubview(NativeSettingsUI.row([
            NativeSettingsButton("Retry Discovery") { [weak self] in self?.store.discovery.retry() },
            NativeSettingsButton("Add by Address…") { [weak self] in self?.addManual() }
        ]))
        NativeSettingsUI.fillWidth(NativeSettingsUI.label(
            "Bonjour names, addresses, and protocol advertisements are hints only. A Drone becomes connected only after authenticated identity and capability negotiation.",
            size: 11, color: .secondaryLabelColor
        ), in: body)
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
        if ids != recordOrder || saved.arrangedSubviews.isEmpty {
            NativeSettingsUI.clear(saved)
            rows = rows.filter { ids.contains($0.key) }
            if records.isEmpty {
                NativeSettingsUI.fillWidth(NativeSettingsUI.label(
                    "No saved Drones. Pair a discovered worker or add one by address.", color: .secondaryLabelColor
                ), in: saved)
            }
            for record in records {
                let row = rows[record.id] ?? NativeDroneRow(
                    retry: { [weak self] in self?.store.retry(id: record.id) },
                    rename: { [weak self] in self?.rename(id: record.id) },
                    diagnostics: { [weak self] in self?.showDiagnostics(id: record.id) },
                    forget: { [weak self] in self?.forget(id: record.id) }
                )
                rows[record.id] = row
                NativeSettingsUI.fillWidth(row, in: saved)
            }
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
                NativeSettingsUI.fillWidth(NativeSettingsUI.section("Pairing Approval", [
                    NativeSettingsUI.label(message), code, NativeSettingsUI.row([approve, reject])
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
        if available != candidates || discovered.arrangedSubviews.isEmpty {
            candidates = available
            NativeSettingsUI.clear(discovered)
            if available.isEmpty {
                NativeSettingsUI.fillWidth(NativeSettingsUI.label(
                    "No unpaired Drone advertisements found.", color: .secondaryLabelColor
                ), in: discovered)
            }
            for candidate in available {
                let version = candidate.advertisedProtocolVersions.isEmpty ? "Unverified Bonjour candidate"
                    : "Unverified · advertises protocol \(candidate.advertisedProtocolVersions.map(String.init).joined(separator: ", "))"
                NativeSettingsUI.fillWidth(NativeSettingsUI.section(candidate.displayName, [
                    NativeSettingsUI.label(version, size: 11, color: .secondaryLabelColor),
                    NativeSettingsButton("Pair") { [weak self] in self?.pair(candidate) }
                ]), in: discovered)
            }
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
    private let hardware = NativeSettingsUI.label("", size: 11, color: .secondaryLabelColor)
    private let endpoints = NativeSettingsUI.label("", size: 11, color: .secondaryLabelColor, selectable: true)
    private let status = NativeSettingsUI.label("", weight: .medium)
    private let detail = NativeSettingsUI.label("", color: .secondaryLabelColor)
    private let retryButton: NSButton
    private let renameButton: NSButton
    private let forgetButton: NSButton

    init(retry: @escaping () -> Void, rename: @escaping () -> Void, diagnostics: @escaping () -> Void, forget: @escaping () -> Void) {
        retryButton = NativeSettingsButton("Retry", action: retry)
        renameButton = NativeSettingsButton("Rename…", action: rename)
        forgetButton = NativeSettingsButton("Forget and Revoke…", action: forget)
        super.init(frame: .zero)
        let stack = NativeSettingsUI.column([
            name, hardware, endpoints, status, detail,
            NativeSettingsUI.row([retryButton, NativeSettingsButton("Diagnostics", action: diagnostics), renameButton, forgetButton])
        ], spacing: 7)
        NativeSettingsUI.pin(stack, to: self, inset: 12)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        for label in [name, hardware, endpoints, status, detail] { label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }
    func update(record: DroneRecord, state: DroneConnectionState, forgetting: Bool) {
        name.stringValue = record.name
        hardware.stringValue = record.hardware.displayText
        hardware.isHidden = hardware.stringValue.isEmpty
        endpoints.stringValue = record.endpoints.map(\.displayText).joined(separator: ", ")
        let presentation = Self.presentation(state)
        status.stringValue = presentation.0
        status.textColor = presentation.2
        detail.stringValue = presentation.1
        retryButton.isEnabled = !forgetting
        renameButton.isEnabled = !forgetting
        forgetButton.isEnabled = !forgetting
        viewDidChangeEffectiveAppearance()
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
