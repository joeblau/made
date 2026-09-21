import SwiftUI

// A shared, extensible Settings surface for Copilot, Pilot, and Plotter.
//
// `SettingsSections` is the cross-platform body (a set of `Section`s meant to
// live inside a `Form`); it's the container we add to over time. It currently
// carries Identity & Keys (this device's auto-generated public key, the paired
// peer's auto-synced key, and a single Regenerate & re-sync action — issue #51)
// and an About section.
//
// Identity & Keys only appears when a `SecureIdentity` is in the environment
// (Copilot, Pilot); Plotter, which doesn't pair keys, shows just About.
//
// The iOS apps present it as a sheet via `SettingsButton`/`SettingsScreen`;
// Pilot drops `SettingsSections` into a macOS `Settings { }` scene.

/// App name / version / build read from the bundle's Info.plist. The project
/// maps these to `PRODUCT_NAME` / `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`.
enum AppInfo {
    static var name: String {
        bundleString("CFBundleDisplayName") ?? bundleString("CFBundleName") ?? "made"
    }
    static var version: String { bundleString("CFBundleShortVersionString") ?? "—" }
    static var build: String { bundleString("CFBundleVersion") ?? "—" }

    private static func bundleString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else { return nil }
        return value
    }
}

/// The settings sections shared across all three apps. Place inside a `Form`.
struct SettingsSections: View {
    /// Provided by Copilot/Pilot; absent on Plotter (which doesn't pair keys).
    @Environment(SecureIdentity.self) private var identity: SecureIdentity?

    var body: some View {
        if let identity {
            Section {
                LabeledContent("This device") {
                    keyValue(identity.localPublicKey, placeholder: "Generating…")
                }
                LabeledContent("Paired device") {
                    if let peer = identity.peerPublicKey {
                        keyValue(peer, tint: .green)
                    } else {
                        Text("Waiting to sync…")
                            .foregroundStyle(.secondary)
                    }
                }
                // The only control: roll a new identity key and push it to the
                // paired device over the encrypted channel. Everything else is
                // automatic.
                Button {
                    identity.regenerate()
                } label: {
                    Label("Regenerate & re-sync", systemImage: "arrow.triangle.2.circlepath")
                }
            } header: {
                HStack(spacing: 6) {
                    if identity.isSynced {
                        Text("Synced")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.15), in: Capsule())
                            .textCase(nil)
                    }
                    Text("Identity & Keys")
                }
            } footer: {
                Text("Your device key is generated automatically and exchanged with your paired device over the encrypted connection — no setup required.")
            }
        }

        Section("About") {
            LabeledContent("App", value: AppInfo.name)
            LabeledContent("Version", value: AppInfo.version)
            LabeledContent("Build", value: AppInfo.build)
        }
    }

    @ViewBuilder
    private func keyValue(_ value: String?, placeholder: String = "—", tint: Color? = nil) -> some View {
        if let value {
            Text(value)
                .font(.system(.footnote, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(tint ?? .primary)
                .textSelection(.enabled)
        } else {
            Text(placeholder).foregroundStyle(.secondary)
        }
    }
}

#if os(iOS)
/// Self-contained "•••" button for the iOS apps (Copilot, Plotter): tapping it
/// presents the shared settings in a sheet. Owns its own presentation state, so
/// a host only needs to drop it into a toolbar or overlay.
struct SettingsButton: View {
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("Settings")
        .sheet(isPresented: $isPresented) {
            SettingsScreen()
        }
    }
}

/// The iOS settings screen: the shared sections in a `Form`, wrapped in a
/// `NavigationStack` with a Done button for sheet presentation.
struct SettingsScreen: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                SettingsSections()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
#endif
