import SwiftUI

/// Shared key for the Settings window's selected section, so a "Set up" button
/// can deep-link straight to the Usage settings section.
enum SettingsTab {
    static let storageKey = "settings.selectedTab"
    static let general = "general"
    static let usage = "usage"
}

/// Inspector "Usage" tab. Provider cards show plan usage windows (utilization + reset
/// countdown) and credits, read from local `claude`, `codex`, `grok`, and `kimi`
/// CLI sessions.
/// A not-signed-in card links to the Usage settings section for setup help.
struct UsageListView: View {
    let store: UsageStore

    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsTab.storageKey) private var selectedSettingsTab = SettingsTab.general

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 12) {
                    ProviderCard(
                        title: "Claude",
                        systemImage: "sparkle",
                        tint: .orange,
                        cli: "claude",
                        state: store.anthropic,
                        openSetup: openSetup
                    )
                    ProviderCard(
                        title: "Codex",
                        systemImage: "chevron.left.forwardslash.chevron.right",
                        tint: .green,
                        cli: "codex",
                        state: store.openAI,
                        openSetup: openSetup
                    )
                    ProviderCard(
                        title: "Kimi",
                        systemImage: "moon.stars.fill",
                        tint: .blue,
                        cli: "kimi login",
                        state: store.moonshot,
                        openSetup: openSetup
                    )
                    ProviderCard(
                        title: "Grok",
                        systemImage: "bolt.fill",
                        tint: .purple,
                        cli: "grok",
                        state: store.xAI,
                        openSetup: openSetup
                    )
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        InspectorSectionHeader(
            title: "Plan Usage",
            systemImage: "chart.bar.xaxis",
            isLoading: store.isLoading,
            refreshHelp: "Refresh usage",
            refresh: store.reload
        )
    }

    private func openSetup() {
        selectedSettingsTab = SettingsTab.usage
        openSettings()
    }
}

enum UsageResetCountdown {
    /// Live countdown text: "resets in 2d 4h" / "3h 12m" / "12m 05s".
    static func text(until date: Date, now: Date) -> String {
        let remaining = Int(date.timeIntervalSince(now))
        guard remaining > 0 else { return "resetting…" }
        let days = remaining / 86400
        let hours = (remaining % 86400) / 3600
        let minutes = (remaining % 3600) / 60
        let seconds = remaining % 60
        if days > 0 { return "resets in \(days)d \(hours)h" }
        if hours > 0 { return "resets in \(hours)h \(minutes)m" }
        return String(format: "resets in %dm %02ds", minutes, seconds)
    }
}

/// One provider's plan usage card. Renders per `ProviderState`.
private struct ProviderCard: View {
    let title: String
    let systemImage: String
    let tint: Color
    let cli: String
    let state: ProviderState
    let openSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(title)
                .font(.body.weight(.semibold))
            if case .usage(let usage) = state, let plan = usage.planLabel {
                Text(plan)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(tint.opacity(0.15), in: Capsule())
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .disabled:
            setupPrompt(message: "Disabled. Enable this provider in Usage settings before made reads its CLI credentials.")

        case .loading:
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .center)

        case .notSignedIn:
            setupPrompt(message: "Not signed in. Run `\(cli)` in a terminal to log in, then refresh.")

        case .error(let message):
            setupPrompt(message: message)

        case .usage(let usage):
            if usage.windows.isEmpty && usage.credits == nil {
                Text("No usage reported for this window.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(usage.windowsInDisplayOrder) { window in
                        windowRow(window)
                    }
                }
                if let credits = usage.credits, !credits.isEmpty {
                    Divider().padding(.vertical, 2)
                    creditsRow(credits)
                }
            }
        }
    }

    private func windowRow(_ window: UsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.name)
                    .font(.callout.weight(.medium))
                Spacer()
                Text("\(Int((window.utilization * 100).rounded()))%")
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .foregroundStyle(barColor(window.utilization))
            }
            ProgressView(value: min(max(window.utilization, 0), 1))
                .progressViewStyle(.linear)
                .tint(barColor(window.utilization))
            if let resetsAt = window.resetsAt {
                // Live countdown — reticks every second.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let countdown = UsageResetCountdown.text(until: resetsAt, now: context.date)
                    Text(countdown)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.7), value: countdown)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private func creditsRow(_ credits: CreditInfo) -> some View {
        let hasMonthlyAllowance = credits.unlimited || credits.used != nil
            || credits.limit != nil || credits.utilization != nil
        return VStack(spacing: 4) {
            if let balance = credits.balance {
                creditLine(
                    label: hasMonthlyAllowance ? "Balance" : "Credits",
                    value: creditAmount(balance, unit: credits.unit)
                )
            }
            if credits.unlimited {
                if let used = credits.used {
                    creditLine(
                        label: "Used this month",
                        value: creditAmount(used, unit: credits.unit)
                    )
                }
                creditLine(
                    label: credits.balance == nil && credits.used == nil
                        ? "Credits"
                        : "Monthly limit",
                    value: "Unlimited"
                )
            } else if let used = credits.used, let limit = credits.limit {
                let usedText = creditAmount(used, unit: credits.unit)
                let limitText = creditAmount(limit, unit: credits.unit)
                creditLine(
                    label: credits.balance == nil ? "Credits" : "Monthly",
                    value: "\(usedText) / \(limitText) used"
                )
            } else if let utilization = credits.utilization {
                creditLine(
                    label: credits.balance == nil ? "Credits" : "Monthly",
                    value: "\(Int((utilization * 100).rounded()))% used"
                )
            } else if let used = credits.used {
                creditLine(
                    label: credits.balance == nil ? "Credits" : "Monthly",
                    value: "\(creditAmount(used, unit: credits.unit)) used"
                )
            } else if let limit = credits.limit {
                creditLine(
                    label: credits.balance == nil ? "Credits" : "Monthly",
                    value: "\(creditAmount(limit, unit: credits.unit)) limit"
                )
            }
        }
    }

    private func creditLine(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.callout, design: .monospaced))
        }
    }

    private func creditAmount(_ value: Double, unit: CreditUnit) -> String {
        switch unit {
        case .credits:
            let number = value.formatted(
                .number.grouping(.automatic).precision(.fractionLength(0...2))
            )
            return "\(number) credits"
        case .currency(let code):
            return value.formatted(.currency(code: code).precision(.fractionLength(2)))
        }
    }

    private func setupPrompt(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: openSetup) {
                Label("Set up", systemImage: "arrow.up.forward")
                    .font(.callout)
            }
            .buttonStyle(.link)
        }
    }

    private func barColor(_ utilization: Double) -> Color {
        switch utilization {
        case ..<0.75: tint
        case ..<0.9: .yellow
        default: .red
        }
    }
}
