#if os(macOS)
import SwiftUI
import AppKit
import CryptoKit

/// Pilot's peer-to-peer secure messaging screen (issue #51, Phase 4).
///
/// The macOS counterpart of Copilot's `SecureMessagingView`: Pilot is the
/// **responder**. The user pastes the peer's pinned static public key (the
/// initiator's) plus the shared pairing token, then Connect: the
/// ``SecureChannelResponder`` walks signaling -> hole-punch -> Noise IK
/// handshake (authenticating the initiator against the pinned key) -> connected,
/// and exposes a live status, the decrypted message log, and send paths for
/// reliable text and a best-effort test blob.
///
/// Reached from the shared Identity & Keys section in `SettingsView`
/// (Pilot's Settings window, ⌘,).
struct PilotSecureMessagingView: View {
    @AppStorage("p2p.rendezvousURL") private var rendezvousURL = "https://rendezvous.blau.app"
    @AppStorage("p2p.allowInsecureLocalhost") private var allowInsecureLocalhost = false

    @State private var peerKeyInput = ""
    @State private var tokenInput = ""
    @State private var transport: SecureChannelResponder?
    @State private var outgoing = ""
    @State private var errorMessage: String?

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
        .formStyle(.grouped)
        .navigationTitle("Secure Messaging")
        .frame(minWidth: 480, minHeight: 560)
        .task { loadPairingSecrets() }
        .onDisappear { savePairingSecrets() }
        .alert("Secure Messaging Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("Dismiss", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section("Status") {
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
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
                .animation(LiquidGlassMetrics.stateChange, value: statusText)
            }
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
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(myPublicKey, forType: .string)
            } label: {
                Label("Copy My Key", systemImage: "key")
            }
            .compatGlassButtonStyle()
        } header: {
            Text("My Public Key")
        } footer: {
            Text("Send this to your peer; they paste it as the peer key on their device.")
        }
    }

    private var pairingSection: some View {
        Section {
            TextField("Peer public key (base64)", text: $peerKeyInput, axis: .vertical)
                .font(.system(.footnote, design: .monospaced))
                .autocorrectionDisabled()
                .lineLimit(1...3)
            TextField("Pairing token", text: $tokenInput)
                .autocorrectionDisabled()
            Button("Generate Pairing Token") { generateToken() }
                .compatGlassButtonStyle()
            TextField("Rendezvous URL", text: $rendezvousURL)
                .autocorrectionDisabled()
            Toggle("Allow HTTP for localhost development", isOn: $allowInsecureLocalhost)

            if let transport, !transport.state.isFailed {
                Button(transport.state == .signaling ? "Cancel Connection" : "Disconnect", role: .destructive) {
                    transport.disconnect()
                    self.transport = nil
                }
                .compatGlassButtonStyle()
            } else {
                Button("Connect") { connect() }
                    .compatGlassProminentButtonStyle()
                    .disabled(!canConnect)
            }
        } header: {
            Text("Peer")
        } footer: {
            Text("The pairing token must match on both devices. The peer key is pinned and authenticated by the handshake.")
        }
    }

    private func messagingSection(_ transport: SecureChannelResponder) -> some View {
        Section("Send") {
            // A persistent row label (FORM-1) with the field and its action
            // side by side. Connect is hidden while connected, so Send is the
            // view's single prominent action (BTN-1).
            LabeledContent("Message") {
                HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                    TextField("Message", text: $outgoing)
                        .labelsHidden()
                        .onSubmit(send)
                    Button("Send", action: send)
                        .compatGlassProminentButtonStyle()
                        .disabled(outgoing.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Button {
                transport.sendTestBlob()
            } label: {
                Label("Send Test Blob (Best-Effort)", systemImage: "shippingbox")
            }
            .compatGlassButtonStyle()
        }
    }

    private func logSection(_ transport: SecureChannelResponder) -> some View {
        Section("Session Log") {
            if transport.log.isEmpty {
                Label("No activity yet.", systemImage: "text.alignleft")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(transport.log.reversed()) { entry in
                    Text(entry.text)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Actions

    private var canConnect: Bool {
        DeviceIdentity.parsePeerPublicKey(peerKeyInput) != nil
            && SecurePairingStore.isValidIdentifier(
                tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
            )
    }

    private func connect() {
        guard let peerKey = DeviceIdentity.parsePeerPublicKey(peerKeyInput) else {
            errorMessage = "Peer public key is not a valid base64 X25519 key."
            return
        }
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SecurePairingStore.isValidIdentifier(token) else {
            errorMessage = "Use a randomly generated pairing token."
            return
        }
        do {
            try pairingStore.setPeerPublicKey(peerKeyInput)
            try pairingStore.setToken(token)
            let identity = try DeviceIdentity.loadOrCreate()
            let client = try SignalingClient(
                baseURLString: rendezvousURL,
                allowInsecureLocalhost: allowInsecureLocalhost
            )
            let t = SecureChannelResponder(
                role: .responder,
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
            try pairingStore.setPeerPublicKey(peerKeyInput)
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
