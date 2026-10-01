import Sparkle
import SwiftUI

/// Pilot's Settings window contents (⌘,). A source-list shell — sections on the
/// left, detail on the right — matching the modern macOS/Xcode settings layout.
/// "General" reuses the shared `SettingsSections` (Identity & Keys + About);
/// "Usage" connects the AI usage APIs. The selected section is backed by
/// `AppStorage` so the inspector's Usage empty-state can deep-link straight here.
struct PilotSettingsView: View {
    @AppStorage(SettingsTab.storageKey) private var selectedTab = SettingsTab.general
    @State private var searchText = ""

    let updater: SPUUpdater

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                List(selection: sidebarSelection) {
                    if matchesSearch("General identity keys about version updates") {
                        Label("General", systemImage: "gearshape")
                            .tag(SettingsTab.general)
                    }
                    if matchesSearch("Usage Claude Codex Kimi Grok") {
                        Label("Usage", systemImage: "chart.bar.xaxis")
                            .tag(SettingsTab.usage)
                    }
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, idealWidth: 920, minHeight: 520, idealHeight: 680)
    }

    /// Bridges the non-optional `AppStorage` string to `List`'s optional selection.
    private var sidebarSelection: Binding<String?> {
        Binding(get: { selectedTab }, set: { selectedTab = $0 ?? SettingsTab.general })
    }

    private func matchesSearch(_ terms: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || terms.localizedCaseInsensitiveContains(query)
    }

    @ViewBuilder
    private var detail: some View {
        switch selectedTab {
        case SettingsTab.usage:
            UsageSettingsView(showsPageHeader: true)
                .formStyle(.grouped)
        default:
            Form {
                PilotSettingsPageHeader(
                    title: "General",
                    subtitle: "Manage Cockpit identity, pairing, and app information.",
                    systemImage: "gearshape.fill",
                    tint: .blue
                )
                Section("Updates") {
                    Button("Check for Updates…") {
                        updater.checkForUpdates()
                    }
                }
                SettingsSections()
                ChromiumDiagnosticsSettingsSection()
            }
            .formStyle(.grouped)
        }
    }
}

struct PilotSettingsPageHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 68, height: 68)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))

            Text(title)
                .font(.system(size: 26, weight: .bold))

            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }
}
