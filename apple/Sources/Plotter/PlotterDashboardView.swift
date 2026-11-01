import SwiftUI

@MainActor
struct PlotterDashboardView: View {
    var mirror: MirrorModel
    @Binding var selectedFamily: DashboardFamily
    @ObservedObject private var activities: DashboardActivityController
    @Environment(\.dismiss) private var dismiss
    @State private var isChangingActivity = false

    init(mirror: MirrorModel, selectedFamily: Binding<DashboardFamily>) {
        self.mirror = mirror
        _selectedFamily = selectedFamily
        _activities = ObservedObject(wrappedValue: mirror.dashboardActivities)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        connectionStatus
                        familyPicker
                    }
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        dashboardPanel(at: context.date)
                    }
                    activityControls
                    errors
                    Text("Live Activities show the latest aggregate received locally from Cockpit. Keep Kneeboard connected for updates.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(24)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Dashboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // Neutral glass close control; the sheet's one prominent
                    // action is Start Live Activity (BTN-1).
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    private var connectionStatus: some View {
        let connected = mirror.isCockpitConnected || mirror.isDemoMode
        // Green marks only the state glyph; the sentence stays secondary text
        // so it keeps body contrast on the grouped background.
        return Label {
            Text(
                connected
                    ? "Connected to Cockpit · Local aggregate updates"
                    : "Local aggregate updates · Waiting for Cockpit"
            )
            .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: connected ? "laptopcomputer.and.arrow.down" : "laptopcomputer.slash")
                .foregroundStyle(connected ? Color.green : Color.secondary)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(
            connected
                ? "Connected to Cockpit. Local aggregate updates."
                : "Waiting for Cockpit. Local aggregate updates."
        )
    }

    private var familyPicker: some View {
        Picker("Dashboard", selection: $selectedFamily) {
            ForEach(DashboardFamily.allCases, id: \.self) { family in
                Text(family.title).tag(family)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    @ViewBuilder
    private func dashboardPanel(at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch selectedFamily {
            case .actions:
                if let snapshot = mirror.dashboardSnapshots.actions {
                    ActionsDashboardActivityCard(
                        projection: snapshot.activityProjection,
                        isStale: snapshot.isStale(at: now.timeIntervalSince1970)
                    )
                    if snapshot.runs.isEmpty {
                        Label("No runs reported", systemImage: "tray")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding([.horizontal, .bottom], 16)
                    }
                } else {
                    ContentUnavailableView {
                        Label("No Actions yet", systemImage: "arrow.triangle.2.circlepath")
                    } description: {
                        Text("Runs from Cockpit will appear here.")
                    }
                }
            case .usage:
                if let snapshot = mirror.dashboardSnapshots.usage {
                    UsageDashboardActivityCard(
                        projection: snapshot.activityProjection,
                        isStale: snapshot.isStale(at: now.timeIntervalSince1970)
                    )
                    if snapshot.providers.isEmpty {
                        Label("No provider summaries", systemImage: "tray")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding([.horizontal, .bottom], 16)
                    }
                } else {
                    ContentUnavailableView {
                        Label("No AI usage yet", systemImage: "sparkles")
                    } description: {
                        Text("Aggregate cost, tokens, and plan utilization will appear here.")
                    }
                }
            case .runners:
                if let snapshot = mirror.dashboardSnapshots.runners {
                    RunnersDashboardActivityCard(
                        projection: snapshot.activityProjection,
                        isStale: snapshot.isStale(at: now.timeIntervalSince1970)
                    )
                    if snapshot.runners.isEmpty {
                        Label("No runners in the sample", systemImage: "tray")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding([.horizontal, .bottom], 16)
                    }
                } else {
                    ContentUnavailableView {
                        Label("No runner data", systemImage: "server.rack")
                    } description: {
                        Text("Enterprise fleet status from Cockpit will appear here.")
                    }
                }
            }
        }
        // The shared activity cards carry their own 16pt inset (they also
        // render on the Lock Screen), so the panel adds only 4pt to land the
        // content on the same 20pt edge as the Live Activity panel below.
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.panelFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// Grouped-content surface: white over the gray grouped background in
    /// light mode, an elevated gray over black in dark mode. Plain
    /// `.background` is black-on-black in dark mode and the panels vanish.
    private static let panelFill = Color(.secondarySystemGroupedBackground)

    private var activityControls: some View {
        let isActive = activities.activeFamilies.contains(selectedFamily)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Live Activity", systemImage: "livephoto")
                    .font(.headline)
                Spacer()
                Text(isActive ? "On" : "Off")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(isActive ? .green : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isActive ? Color.green.opacity(0.12) : Color.secondary.opacity(0.12), in: Capsule())
            }
            Text("Show \(selectedFamily.title) on the Lock Screen. Updates use local Cockpit data.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                Task { await toggleActivity() }
            } label: {
                HStack(spacing: 8) {
                    if isChangingActivity {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(isActive ? "Stop Live Activity" : "Start Live Activity")
                        .frame(maxWidth: .infinity)
                }
            }
            // Start is the sheet's one primary action; Stop is a reversible,
            // non-destructive toggle, so it drops to neutral glass, not red.
            .modifier(LiveActivityButtonStyle(isPrimary: !isActive))
            .controlSize(.large)
            .disabled(isChangingActivity || (!isActive && !hasSelectedSnapshot))
            if !isActive && !hasSelectedSnapshot {
                Text("Start becomes available after the first \(selectedFamily.title) snapshot arrives.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(Self.panelFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private var errors: some View {
        if let dashboardError = mirror.dashboardError {
            Label(dashboardError, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let activityError = activities.lastError {
            Label(activityError, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hasSelectedSnapshot: Bool {
        switch selectedFamily {
        case .actions: mirror.dashboardSnapshots.actions != nil
        case .usage: mirror.dashboardSnapshots.usage != nil
        case .runners: mirror.dashboardSnapshots.runners != nil
        }
    }

    private func toggleActivity() async {
        let family = selectedFamily
        isChangingActivity = true
        defer { isChangingActivity = false }
        do {
            switch family {
            case .actions:
                guard let snapshot = mirror.dashboardSnapshots.actions else { return }
                try await activities.toggleActions(snapshot)
            case .usage:
                guard let snapshot = mirror.dashboardSnapshots.usage else { return }
                try await activities.toggleUsage(snapshot)
            case .runners:
                guard let snapshot = mirror.dashboardSnapshots.runners else { return }
                try await activities.toggleRunners(snapshot)
            }
        } catch {
            // DashboardActivityController publishes the actionable error.
        }
    }
}

/// Liquid Glass button tiers for the Live Activity toggle (BTN-1).
private struct LiveActivityButtonStyle: ViewModifier {
    let isPrimary: Bool

    func body(content: Content) -> some View {
        if isPrimary {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.glass)
        }
    }
}
