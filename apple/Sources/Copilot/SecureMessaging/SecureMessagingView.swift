#if os(iOS)
import SwiftUI
import CryptoKit

/// Copilot's peer-to-peer secure messaging screen (issue #51, Phase 3).
///
/// Lets the user paste the peer's pinned static public key + a shared pairing
/// token, then Connect: the ``SecureChannelTransport`` walks signaling ->
/// hole-punch -> Noise IK handshake -> connected and exposes a live status, the
/// decrypted message log, and send paths for reliable text and a best-effort
/// test blob. Reached from the shared Identity & Keys section in `SettingsView`.
struct SecureMessagingView: View {
    @AppStorage("p2p.rendezvousURL") private var rendezvousURL = "https://rendezvous.blau.app"
    @AppStorage("p2p.allowInsecureLocalhost") private var allowInsecureLocalhost = false

    @State private var peerKeyInput = ""
    @State private var tokenInput = ""
    @State private var transport: SecureChannelTransport?
    @State private var outgoing = ""
    @State private var errorMessage: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var myPublicKey: String { DeviceIdentity.publicKeyBase64() ?? "—" }
    private let pairingStore = SecurePairingStore()

    var body: some View {
        Form {
            statusSection
            identitySection
            pairingSection
            if let transport, transport.state.isConnected {
                messagingSection(transport)
            }
            if let transport {
                logSection(transport)
            }
        }
        // The multi-line peer-key field turns Return into a newline, so a
        // drag down is the way to put the keyboard away and reveal the
        // field's inline error and Connect (FORM-4).
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Secure Messaging")
        .navigationBarTitleDisplayMode(.inline)
        .task { loadPairingSecrets() }
        .onDisappear { savePairingSecrets() }
        .alert("Connection error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section {
            LabeledContent("Connection") {
                HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                    // In-flight stages show activity rather than a static dot
                    // (MOT-5); settled states keep the colored indicator.
                    if isConnecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                    }
                    Text(statusText)
                        .legibleSecondaryRowText()
                        .contentTransition(.opacity)
                }
                .animation(LiquidGlassMetrics.stateChange, value: statusText)
            }
        } header: {
            Text("Status").legibleSectionText()
        }
    }

    private var identitySection: some View {
        Section {
            LabeledContent("This device") {
                Text(myPublicKey)
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            ShareLink(item: myPublicKey) {
                Label("Share my key", systemImage: "key")
            }
        } header: {
            Text("My public key").legibleSectionText()
        } footer: {
            Text("Send this to your peer; they paste it as the peer key on their device.")
                .legibleSectionText()
        }
    }

    private var pairingSection: some View {
        Section {
            // Persistent labels above each field; placeholders are only an
            // instruction or a bare example (FORM-1/FORM-2). Each field is a
            // Liquid Glass field with a focus ring (FORM-4), matching the
            // bezeled fields of Cockpit's Secure Messaging form instead of
            // bare text in the row.
            labeledField("Peer public key", error: peerKeyError) {
                TextField(
                    "Peer public key",
                    text: $peerKeyInput,
                    prompt: Text("Paste your peer's base64 key"),
                    axis: .vertical
                )
                .font(.system(.footnote, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(1...3)
                .liquidGlassField(multiline: true)
                // Error state on the field itself, not only in the helper
                // line below it (FORM-4). Same shape as the glass and its
                // focus ring.
                .overlay {
                    ConcentricRectangle(
                        corners: .concentric(minimum: .fixed(LiquidGlassMetrics.Radius.field)),
                        isUniform: true
                    )
                    .stroke(.red, lineWidth: 1.5)
                    .opacity(peerKeyError == nil ? 0 : 1)
                    .allowsHitTesting(false)
                }
            }
            labeledField("Pairing token") {
                TextField("Pairing token", text: $tokenInput, prompt: Text("Generate or paste a token"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .liquidGlassField()
            }
            // Secondary glass beside the token it fills (BTN-1); a
            // non-default style also keeps the row from routing every tap
            // in it to this button.
            // "Generate Token" under the Pairing token label: the shorter
            // verb label no longer hyphenates mid-word at accessibility
            // sizes (BTN-2, TYPE-4); the full name stays for VoiceOver.
            Button {
                generateToken()
            } label: {
                // At accessibility sizes the glyph would force "Generate" to
                // break mid-word; the title alone wraps by words.
                if dynamicTypeSize.isAccessibilitySize {
                    Text("Generate Token")
                } else {
                    Label("Generate Token", systemImage: "key.viewfinder")
                }
            }
            .accessibilityLabel("Generate secure pairing token")
            .liquidGlassButtonStyle()
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            labeledField("Rendezvous URL") {
                TextField("Rendezvous URL", text: $rendezvousURL, prompt: Text(verbatim: "https://rendezvous.blau.app"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .liquidGlassField()
            }
            Toggle("Allow HTTP for localhost development", isOn: $allowInsecureLocalhost)

            // Connect is the screen's one prominent action (BTN-1, BTN-4);
            // Disconnect and Cancel are reversible, so neutral glass with
            // the destructive role's red label.
            Group {
                if let transport, !transport.state.isFailed {
                    Button(role: .destructive) {
                        transport.disconnect()
                        self.transport = nil
                    } label: {
                        Text(transport.state == .signaling ? "Cancel connection" : "Disconnect")
                            .frame(maxWidth: .infinity)
                    }
                    .liquidGlassButtonStyle()
                } else {
                    Button {
                        connect()
                    } label: {
                        Text("Connect")
                            .frame(maxWidth: .infinity)
                    }
                    .liquidGlassButtonStyle(prominent: true)
                    .disabled(!canConnect)
                }
            }
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        } header: {
            Text("Peer").legibleSectionText()
        } footer: {
            Text("The pairing token must match on both devices. Peer key is pinned and authenticated by the handshake.")
                .legibleSectionText()
        }
    }

    private func messagingSection(_ transport: SecureChannelTransport) -> some View {
        // The section header is the composer's persistent label (FORM-1).
        Section {
            HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                TextField("Message", text: $outgoing)
                    .onSubmit(send)
                    .liquidGlassField()
                // Connect is hidden while connected, so Send is the view's one
                // prominent action (BTN-1): a circular glass icon button in the
                // Messages idiom. A non-default style also keeps the Form from
                // routing taps anywhere in the row to it.
                Button("Send", systemImage: "arrow.up", action: send)
                    .liquidGlassIconButton(prominent: true)
                    .disabled(outgoing.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Button {
                transport.sendTestBlob()
            } label: {
                Label("Send test blob (best-effort)", systemImage: "shippingbox")
            }
            .liquidGlassButtonStyle()
            .buttonBorderShape(.capsule)
            .controlSize(.small)
        } header: {
            Text("Send").legibleSectionText()
        }
    }

    private func logSection(_ transport: SecureChannelTransport) -> some View {
        Section {
            if transport.log.isEmpty {
                Label("No activity yet.", systemImage: "text.alignleft")
                    .legibleSecondaryRowText()
            } else {
                ForEach(transport.log.reversed()) { entry in
                    Text(entry.text)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } header: {
            Text("Session log").legibleSectionText()
        }
    }

    /// A Form row with a persistent visible label above its field (FORM-1),
    /// label → input at 8pt (FORM-5). The field's own title stays its
    /// VoiceOver label, so the visible label is hidden from accessibility.
    /// `error`, when set, is shown under the field as its inline error state.
    private func labeledField<Field: View>(
        _ title: LocalizedStringKey,
        error: String? = nil,
        @ViewBuilder field: () -> Field
    ) -> some View {
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xSmall) {
            Text(title)
                .font(.subheadline)
                .legibleSecondaryRowText()
                .accessibilityHidden(true)
            // Input → helper/error text at 4pt (FORM-5); the error is the
            // field's designed error state (FORM-4).
            VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xxSmall) {
                field()
                if let error {
                    // The red glyph and field stroke carry the error; the
                    // footnote copy stays primary, since system red text on
                    // the light grouped row measures about 3.6:1 (TYPE-3).
                    Label {
                        Text(error)
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .font(.footnote)
                    .transition(.opacity)
                }
            }
            .animation(LiquidGlassMetrics.stateChange, value: error)
        }
        .padding(.vertical, LiquidGlassMetrics.Spacing.xxSmall)
    }

    // MARK: - Actions

    /// Inline validation for the peer key. The slot is the shared device pin
    /// (also used by PeerSync), so malformed text is never persisted; tell
    /// the user before they leave the screen. An empty field is not an
    /// error: it unpairs.
    private var peerKeyError: String? {
        SecurePairingStore.peerKeyUpdate(for: peerKeyInput) == .rejectInvalid
            ? "Not a valid base64 X25519 key. It won't be saved."
            : nil
    }

    /// The field's key when it is one the store would pin, else `nil`.
    private var validPeerKey: String? {
        guard case .save(let key) = SecurePairingStore.peerKeyUpdate(for: peerKeyInput) else { return nil }
        return key
    }

    private var canConnect: Bool {
        validPeerKey != nil
            && SecurePairingStore.isValidIdentifier(
                tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
            )
    }

    private func connect() {
        guard let pin = validPeerKey, let peerKey = DeviceIdentity.parsePeerPublicKey(pin) else {
            errorMessage = "Peer public key is not a valid base64 X25519 key."
            return
        }
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SecurePairingStore.isValidIdentifier(token) else {
            errorMessage = "Use a randomly generated pairing token."
            return
        }
        do {
            try pairingStore.setPeerPublicKey(pin)
            try pairingStore.setToken(token)
            let identity = try DeviceIdentity.loadOrCreate()
            let client = try SignalingClient(
                baseURLString: rendezvousURL,
                allowInsecureLocalhost: allowInsecureLocalhost
            )
            let t = SecureChannelTransport(
                role: .initiator,
                signaling: client,
                token: token,
                staticKey: identity,
                peerStatic: peerKey
            )
            replaceActiveConnection(&transport, with: t) { $0.disconnect() }
            t.connect()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadPairingSecrets() {
        do {
            let secrets = try pairingStore.loadMigratingLegacy()
            peerKeyInput = secrets.peerPublicKey
            tokenInput = secrets.token
        } catch {
            errorMessage = "Could not load secure pairing settings."
        }
    }

    private func savePairingSecrets() {
        do {
            // Writes only a valid key or clears an emptied field; malformed
            // text leaves the existing pin untouched (shown inline above).
            try pairingStore.applyPeerKeyInput(peerKeyInput)
            try pairingStore.setToken(tokenInput)
        } catch {
            errorMessage = "Could not save secure pairing settings."
        }
    }

    private func generateToken() {
        do {
            tokenInput = try SecurePairingStore.generateToken()
            try pairingStore.setToken(tokenInput)
        } catch {
            errorMessage = "Could not generate a secure pairing token."
        }
    }

    private func send() {
        let text = outgoing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        transport?.sendText(text)
        outgoing = ""
    }

    // MARK: - Status presentation

    private var statusText: String {
        switch transport?.state {
        case .none: return "Idle"
        case .signaling: return "Signaling…"
        case .holePunching: return "Hole punching…"
        case .handshake: return "Handshaking…"
        case .connected: return "Connected"
        case .failed(let reason): return "Failed: \(reason)"
        }
    }

    private var isConnecting: Bool {
        switch transport?.state {
        case .signaling, .holePunching, .handshake: return true
        case .none, .connected, .failed: return false
        }
    }

    private var statusColor: Color {
        switch transport?.state {
        case .connected: return .green
        case .failed: return .red
        // Idle reads as the semantic secondary tint in both appearances (COL-2).
        case .none: return .secondary
        default: return .orange
        }
    }
}
#endif
