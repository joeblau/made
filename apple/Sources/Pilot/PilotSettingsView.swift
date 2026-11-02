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
            // The system sidebar search field (HIER-6) replaces a hand-drawn
            // capsule; it adopts Liquid Glass on macOS 26 automatically.
            let showsGeneral = matchesSearch("General identity keys about version updates setup permissions tools Chromium")
            let showsUsage = matchesSearch("Usage Claude Codex Kimi Grok")
            List(selection: sidebarSelection) {
                if showsGeneral {
                    Label("General", systemImage: "gearshape")
                        .tag(SettingsTab.general)
                }
                if showsUsage {
                    Label("Usage", systemImage: "chart.bar.xaxis")
                        .tag(SettingsTab.usage)
                }
            }
            .listStyle(.sidebar)
            // A designed no-results state instead of a blank sidebar (MOT-6).
            .overlay {
                if !showsGeneral && !showsUsage {
                    ContentUnavailableView.search(text: searchText)
                    .legibleSecondaryHierarchy()
                }
            }
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search")
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
                // Secondary glass actions (BTN-1: the page has no single
                // primary action, so none is prominent).
                Section("Updates") {
                    Button("Check for Updates…") {
                        updater.checkForUpdates()
                    }
                    .compatGlassButtonStyle()
                }
                Section("Setup") {
                    // The description sits beside its action (LAY-5) in the
                    // standard settings-row layout.
                    LabeledContent {
                        OpenSetupButton()
                            .compatGlassButtonStyle()
                    } label: {
                        Text("Review permissions, companion connections, and developer tools.")
                            .foregroundStyle(.secondary)
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
        VStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
            // A text style scaled up instead of a fixed point size (TYPE-4).
            // The tile is content, not a control, so it stays a tinted fill
            // rather than glass; continuous corners on the card token.
            Image(systemName: systemImage)
                .font(.largeTitle.weight(.medium))
                .imageScale(.large)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 64, height: 64)
                .background(
                    tint.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: LiquidGlassMetrics.Radius.card, style: .continuous)
                )
                .accessibilityHidden(true)

            // `.largeTitle` is 26pt on macOS: same size, but a named style.
            Text(title)
                .font(.largeTitle.bold())

            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, LiquidGlassMetrics.Spacing.xLarge)
    }
}
