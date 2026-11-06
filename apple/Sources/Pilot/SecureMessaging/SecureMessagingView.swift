import AppKit
import CryptoKit

@MainActor
final class PilotSecureMessagingViewController: NSViewController, NSTextFieldDelegate {
    private let defaults: UserDefaults
    private let loadsPairingSecrets: Bool
    private let suppliedPublicKey: String?
    private let pairingStore = SecurePairingStore()
    private let observation = NativeSettingsObservation()
    private var transport: SecureChannelResponder?
    private var secretsLoaded = false
    private var visible = false
    private let status = NativeSettingsUI.label("Idle")
    private let publicKey = NativeSettingsUI.label("", size: 11, selectable: true)
    private let peerKey = NativeSettingsTextField(size: 11, monospaced: true)
    private let token = NativeSettingsTextField()
    private let rendezvous = NativeSettingsTextField()
    private let outgoing = NativeSettingsTextField()
    private let keyError = NativeSettingsUI.label("", size: 11, color: .systemRed)
    private let errorLabel = NativeSettingsUI.label("", color: .systemRed)
    private let log = NativeSettingsTextView()
    private let sendSection = NSView()
    private var connectionButton: NSButton!
    private var sendButton: NSButton!
    private var allowLocalhost: NSButton!
    private var myPublicKey: String { publicKey.stringValue }

    init(defaults: UserDefaults = .standard, loadsPairingSecrets: Bool = true, localPublicKey: String? = nil) {
        self.defaults = defaults
        self.loadsPairingSecrets = loadsPairingSecrets
        suppliedPublicKey = localPublicKey
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 620, height: 760)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let body = NativeSettingsUI.column(spacing: 18)
        body.addArrangedSubview(NativeSettingsUI.label("Secure Messaging", size: 26, weight: .bold))
        NativeSettingsUI.fillWidth(errorLabel, in: body)
        errorLabel.isHidden = true
        NativeSettingsUI.fillWidth(NativeSettingsUI.section("Status", [status]), in: body)
        publicKey.usesMonospacedFont = true
        publicKey.stringValue = suppliedPublicKey ?? (loadsPairingSecrets ? DeviceIdentity.publicKeyBase64() : nil) ?? "—"
        NativeSettingsUI.fillWidth(NativeSettingsUI.section("My Public Key", [
            publicKey,
            NativeSettingsButton("Copy My Key") { [weak self] in
                guard let self else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(self.myPublicKey, forType: .string)
            },
            NativeSettingsUI.label("Send this to your peer; they paste it as the peer key on their device.", size: 11, color: .secondaryLabelColor)
        ]), in: body)
        for (field, title, placeholder) in [
            (peerKey, "Peer public key", "Paste your peer's base64 key"),
            (token, "Pairing token", "Generate or paste a token"),
            (rendezvous, "Rendezvous URL", "https://rendezvous.blau.app"),
            (outgoing, "Message", "")
        ] {
            field.placeholderString = placeholder
            field.setAccessibilityLabel(title)
            field.delegate = self
            field.isAutomaticTextCompletionEnabled = false
        }
        rendezvous.stringValue = defaults.string(forKey: "p2p.rendezvousURL") ?? "https://rendezvous.blau.app"
        allowLocalhost = NativeSettingsButton(
            checkbox: "Allow HTTP for localhost development", checked: defaults.bool(forKey: "p2p.allowInsecureLocalhost")
        ) { [weak self] enabled in self?.defaults.set(enabled, forKey: "p2p.allowInsecureLocalhost") }
        connectionButton = NativeSettingsButton("Connect") { [weak self] in self?.toggleConnection() }
        let generate = NativeSettingsButton("Generate Pairing Token") { [weak self] in self?.generateToken() }
        generate.isEnabled = loadsPairingSecrets
        NativeSettingsUI.fillWidth(NativeSettingsUI.section("Peer", [
            NativeSettingsUI.label("Peer public key", weight: .medium), peerKey, keyError,
            NativeSettingsUI.label("Pairing token", weight: .medium), token,
            generate,
            NativeSettingsUI.label("Rendezvous URL", weight: .medium), rendezvous,
            allowLocalhost, connectionButton,
            NativeSettingsUI.label(
                "The pairing token must match on both devices. The peer key is pinned and authenticated by the handshake.",
                size: 11, color: .secondaryLabelColor
            )
        ]), in: body)
        sendButton = NativeSettingsButton("Send") { [weak self] in self?.send() }
        outgoing.target = self
        outgoing.action = #selector(send)
        let message = NativeSettingsUI.section("Send", [
            NativeSettingsUI.label("Message", weight: .medium), outgoing, sendButton,
            NativeSettingsButton("Send Test Blob (Best-Effort)") { [weak self] in self?.transport?.sendTestBlob() }
        ])
        NativeSettingsUI.pin(message, to: sendSection)
        NativeSettingsUI.fillWidth(sendSection, in: body)
        log.isEditable = false
        log.isSelectable = true
        log.isRichText = false
        log.autoresizingMask = [.width]
        log.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = log
        scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
        NativeSettingsUI.fillWidth(NativeSettingsUI.section("Session Log", [scroll]), in: body)
        view = NativeSettingsUI.scrolling(body)
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        visible = true
        if loadsPairingSecrets, !secretsLoaded {
            secretsLoaded = true
            loadSecrets()
        }
        observeTransport()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        visible = false
        observation.stop()
        if loadsPairingSecrets { saveSecrets() }
    }

    func shutdown() {
        observation.stop()
        if isViewLoaded, loadsPairingSecrets { saveSecrets() }
        transport?.disconnect()
        transport = nil
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === rendezvous {
            defaults.set(rendezvous.stringValue, forKey: "p2p.rendezvousURL")
        }
        refresh()
    }

    private var validPeerKey: String? {
        guard case .save(let value) = SecurePairingStore.peerKeyUpdate(for: peerKey.stringValue) else { return nil }
        return value
    }

    private func refresh() {
        guard isViewLoaded else { return }
        let connected = transport?.state.isConnected == true
        sendSection.isHidden = !connected
        keyError.stringValue = SecurePairingStore.peerKeyUpdate(for: peerKey.stringValue) == .rejectInvalid
            ? "Not a valid base64 X25519 key. It won't be saved." : ""
        keyError.isHidden = keyError.stringValue.isEmpty
        switch transport?.state {
        case .none: status.stringValue = "Idle"; status.textColor = .secondaryLabelColor
        case .signaling: status.stringValue = "Signaling…"; status.textColor = .systemOrange
        case .holePunching: status.stringValue = "Hole punching…"; status.textColor = .systemOrange
        case .handshake: status.stringValue = "Handshaking…"; status.textColor = .systemOrange
        case .connected: status.stringValue = "Connected"; status.textColor = .systemGreen
        case .failed(let reason): status.stringValue = "Failed: \(reason)"; status.textColor = .systemRed
        }
        if let transport, !transport.state.isFailed {
            connectionButton.title = transport.state == .signaling ? "Cancel Connection" : "Disconnect"
            connectionButton.isEnabled = true
        } else {
            connectionButton.title = "Connect"
            connectionButton.isEnabled = loadsPairingSecrets && validPeerKey != nil && SecurePairingStore.isValidIdentifier(
                token.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        sendButton.isEnabled = connected && !outgoing.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let next = transport?.log.reversed().map(\.text).joined(separator: "\n") ?? "No activity yet."
        if log.string != next { log.string = next.isEmpty ? "No activity yet." : next }
    }

    private func observeTransport() {
        if visible { observation.start { [weak self] in self?.refresh() } } else { refresh() }
    }

    private func toggleConnection() {
        guard loadsPairingSecrets else { return }
        if let transport, !transport.state.isFailed {
            transport.disconnect()
            self.transport = nil
            observeTransport()
            return
        }
        guard let pin = validPeerKey, let peerStatic = DeviceIdentity.parsePeerPublicKey(pin) else {
            showError("Peer public key is not a valid base64 X25519 key.")
            return
        }
        let pairingToken = token.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SecurePairingStore.isValidIdentifier(pairingToken) else {
            showError("Use a randomly generated pairing token.")
            return
        }
        do {
            try pairingStore.setPeerPublicKey(pin)
            try pairingStore.setToken(pairingToken)
            let identity = try DeviceIdentity.loadOrCreate()
            let signaling = try SignalingClient(
                baseURLString: rendezvous.stringValue, allowInsecureLocalhost: allowLocalhost.state == .on
            )
            let connection = SecureChannelResponder(
                role: .responder, signaling: signaling, token: pairingToken, staticKey: identity, peerStatic: peerStatic
            )
            replaceActiveConnection(&transport, with: connection) { $0.disconnect() }
            connection.connect()
            errorLabel.isHidden = true
            observeTransport()
        } catch { showError(error.localizedDescription) }
    }

    private func loadSecrets() {
        do {
            let secrets = try pairingStore.loadMigratingLegacy()
            peerKey.stringValue = secrets.peerPublicKey
            token.stringValue = secrets.token
        } catch { showError("Could not load secure pairing settings.") }
    }

    private func saveSecrets() {
        do {
            try pairingStore.applyPeerKeyInput(peerKey.stringValue)
            try pairingStore.setToken(token.stringValue)
        } catch { showError("Could not save secure pairing settings.") }
    }

    private func generateToken() {
        guard loadsPairingSecrets else { return }
        do {
            token.stringValue = try SecurePairingStore.generateToken()
            try pairingStore.setToken(token.stringValue)
            refresh()
        } catch { showError("Could not generate a secure pairing token.") }
    }

    @objc private func send() {
        guard transport?.state.isConnected == true else { return }
        let message = outgoing.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        transport?.sendText(message)
        outgoing.stringValue = ""
        refresh()
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        if visible, let window = view.window { NativeSettingsUI.error(message, in: window) }
    }
}
