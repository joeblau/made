import SwiftUI

/// Settings section for AI usage. There are **no keys to enter** — usage is read
/// from the `claude`, `codex`, `grok`, and `kimi` CLI sessions already on this
/// Mac. This page shows whether each is signed in and how to sign in if not.
struct UsageSettingsView: View {
    var showsPageHeader = false

    @AppStorage(UsageConsent.claudeKey) private var claudeEnabled = false
    @AppStorage(UsageConsent.codexKey) private var codexEnabled = false
    @AppStorage(UsageConsent.grokKey) private var grokEnabled = false
    @AppStorage(UsageConsent.kimiKey) private var kimiEnabled = false
    @State private var claudeSignedIn: Bool?
    @State private var codexSignedIn: Bool?
    @State private var grokSignedIn: Bool?
    @State private var kimiSignedIn: Bool?

    private static let claudeDocsURL = URL(string: "https://code.claude.com/docs/en/overview")!
    private static let codexDocsURL = URL(string: "https://developers.openai.com/codex/cli")!
    private static let grokDocsURL = URL(string: "https://docs.x.ai/build/overview")!
    private static let kimiDocsURL = URL(
        string: "https://www.kimi.ai/help/kimi-code/cli-getting-started"
    )!

    var body: some View {
        Form {
            if showsPageHeader {
                PilotSettingsPageHeader(
                    title: "Usage",
                    subtitle: "Connect local coding-agent sessions and review their usage in Cockpit.",
                    systemImage: "chart.bar.xaxis",
                    tint: .blue
                )
            }

            Section {
                Toggle("Allow Cockpit to read Claude Code credentials and usage", isOn: $claudeEnabled)
                statusRow(enabled: claudeEnabled, signedIn: claudeSignedIn)
                Link(destination: Self.claudeDocsURL) {
                    Label("Install & sign in to Claude Code", systemImage: "arrow.up.forward.app")
                }
            } header: {
                Text("Claude")
            } footer: {
                Text("When enabled, Cockpit reads Claude Code's credential file or Keychain item and sends its bearer token only to Anthropic's usage endpoint. Keychain access may prompt once.")
            }

            Section {
                Toggle("Allow Cockpit to read Codex credentials and usage", isOn: $codexEnabled)
                statusRow(enabled: codexEnabled, signedIn: codexSignedIn)
                Link(destination: Self.codexDocsURL) {
                    Label("Install & sign in to Codex", systemImage: "arrow.up.forward.app")
                }
            } header: {
                Text("Codex")
            } footer: {
                Text("When enabled, Cockpit reads ~/.codex/auth.json and sends its bearer token only to ChatGPT's Codex usage endpoint.")
            }

            Section {
                Toggle("Allow Cockpit to read Kimi Code credentials and usage", isOn: $kimiEnabled)
                statusRow(enabled: kimiEnabled, signedIn: kimiSignedIn)
                Link(destination: Self.kimiDocsURL) {
                    Label("Install & sign in to Kimi Code", systemImage: "arrow.up.forward.app")
                }
            } header: {
                Text("Kimi")
            } footer: {
                Text(
                    "When enabled, Cockpit reads Kimi Code's credential file under "
                        + "$KIMI_CODE_HOME (or ~/.kimi-code), with legacy ~/.kimi fallback, "
                        + "and sends its bearer token only to api.kimi.ai/coding/v1/usages."
                )
            }

            Section {
                Toggle("Allow Cockpit to read Grok credentials and usage", isOn: $grokEnabled)
                statusRow(enabled: grokEnabled, signedIn: grokSignedIn)
                Link(destination: Self.grokDocsURL) {
                    Label("Install & sign in to Grok", systemImage: "arrow.up.forward.app")
                }
            } header: {
                Text("Grok")
            } footer: {
                Text(
                    "When enabled, Cockpit reads $GROK_HOME/auth.json (or ~/.grok/auth.json) "
                        + "and sends its bearer token only to xAI's usage endpoint."
                )
            }

            Section {
                EmptyView()
            } footer: {
                Text("All providers are disabled by default. Cockpit does not read auth files, query Keychain, or make usage requests until you enable that provider. Tokens are never stored by Cockpit.")
            }
        }
        .task { await detect() }
        .onChange(of: claudeEnabled) { consentChanged() }
        .onChange(of: codexEnabled) { consentChanged() }
        .onChange(of: grokEnabled) { consentChanged() }
        .onChange(of: kimiEnabled) { consentChanged() }
    }

    @ViewBuilder
    private func statusRow(enabled: Bool, signedIn: Bool?) -> some View {
        LabeledContent("Status") {
            if !enabled {
                Label("Disabled", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            } else {
                switch signedIn {
                case .some(true):
                    Label("Signed in", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                case .some(false):
                    Label("Not signed in", systemImage: "xmark.circle")
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                case .none:
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    private func detect() async {
        claudeSignedIn = nil
        codexSignedIn = nil
        grokSignedIn = nil
        kimiSignedIn = nil
        async let claude = Self.detectClaude(enabled: claudeEnabled)
        async let codex = Self.detectCodex(enabled: codexEnabled)
        async let grok = Self.detectGrok(enabled: grokEnabled)
        async let kimi = Self.detectKimi(enabled: kimiEnabled)
        let values = await (claude, codex, grok, kimi)
        claudeSignedIn = claudeEnabled ? values.0 : nil
        codexSignedIn = codexEnabled ? values.1 : nil
        grokSignedIn = grokEnabled ? values.2 : nil
        kimiSignedIn = kimiEnabled ? values.3 : nil
    }

    private func consentChanged() {
        NotificationCenter.default.post(name: UsageConsent.changedNotification, object: nil)
        Task { await detect() }
    }

    private static func detectClaude(enabled: Bool) async -> Bool {
        guard enabled else { return false }
        return await Task.detached { UsageSessions.ClaudeSession.load() != nil }.value
    }

    private static func detectCodex(enabled: Bool) async -> Bool {
        guard enabled else { return false }
        return await Task.detached { UsageSessions.CodexSession.load() != nil }.value
    }

    private static func detectGrok(enabled: Bool) async -> Bool {
        guard enabled else { return false }
        return await Task.detached { UsageSessions.GrokSession.load() != nil }.value
    }

    private static func detectKimi(enabled: Bool) async -> Bool {
        guard enabled else { return false }
        return await Task.detached {
            guard let session = UsageSessions.KimiSession.load() else { return false }
            return !session.isExpired
        }.value
    }
}
