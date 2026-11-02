import SwiftUI

@MainActor
struct PlotterDashboardView: View {
    var mirror: MirrorModel
    @Binding var selectedFamily: DashboardFamily
    @ObservedObject private var activities: DashboardActivityController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isChangingActivity = false

    init(mirror: MirrorModel, selectedFamily: Binding<DashboardFamily>) {
        self.mirror = mirror
        _selectedFamily = selectedFamily
        _activities = ObservedObject(wrappedValue: mirror.dashboardActivities)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                // 24pt between groups, 12pt inside the header group (LAY-5).
                VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xLarge) {
                    VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.small) {
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
                        .foregroundStyle(LegibleSecondaryText.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(LiquidGlassMetrics.Spacing.xLarge)
                // Readable column when the sheet is resized wide (LAY-6).
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
                // Switching family swaps the panel content and its height:
                // animate that context change instead of a hard cut (MOT-1,
                // MOT-4).
                .animation(reduceMotion ? nil : LiquidGlassMetrics.spring, value: selectedFamily)
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
        let connected = mirror.isCockpitConnected || mirror.isDemoConnected
        // Green marks only the state glyph; the sentence is the legible
        // secondary gray (the system `.secondary` is 4.0:1 on the light
        // grouped background, TYPE-3).
        return Label {
            Text(
                connected
                    ? "Connected to Cockpit · Local aggregate updates"
                    : "Local aggregate updates · Waiting for Cockpit"
            )
            .foregroundStyle(LegibleSecondaryText.color)
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
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xSmall) {
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
                            .foregroundStyle(LegibleSecondaryText.color)
                            .padding([.horizontal, .bottom], LiquidGlassMetrics.Spacing.medium)
                    }
                } else {
                    ContentUnavailableView {
                        Label("No Actions yet", systemImage: "arrow.triangle.2.circlepath")
                    } description: {
                        Text("Runs from Cockpit will appear here.")
                            .foregroundStyle(LegibleSecondaryText.color)
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
                            .foregroundStyle(LegibleSecondaryText.color)
                            .padding([.horizontal, .bottom], LiquidGlassMetrics.Spacing.medium)
                    }
                } else {
                    ContentUnavailableView {
                        Label("No AI usage yet", systemImage: "sparkles")
                    } description: {
                        Text("Aggregate cost, tokens, and plan utilization will appear here.")
                            .foregroundStyle(LegibleSecondaryText.color)
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
                            .foregroundStyle(LegibleSecondaryText.color)
                            .padding([.horizontal, .bottom], LiquidGlassMetrics.Spacing.medium)
                    }
                } else {
                    ContentUnavailableView {
                        Label("No runner data", systemImage: "server.rack")
                    } description: {
                        Text("Enterprise fleet status from Cockpit will appear here.")
                            .foregroundStyle(LegibleSecondaryText.color)
                    }
                }
            }
        }
        // The shared activity cards carry their own 16pt inset (they also
        // render on the Lock Screen), so the panel adds only 4pt to land the
        // content on the same 20pt edge as the Live Activity panel below.
        .padding(LiquidGlassMetrics.Spacing.xxSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.panelFill, in: Self.panelShape)
    }

    /// Grouped-content surface: white over the gray grouped background in
    /// light mode, an elevated gray over black in dark mode. Plain
    /// `.background` is black-on-black in dark mode and the panels vanish.
    /// Content, not controls, so a semantic fill rather than glass.
    private static let panelFill = Color(.secondarySystemGroupedBackground)

    /// The shared card radius token, so both panels match the rest of the
    /// apps' content cards.
    private static let panelShape = RoundedRectangle(
        cornerRadius: LiquidGlassMetrics.Radius.card,
        style: .continuous
    )

    private var activityControls: some View {
        let isActive = activities.activeFamilies.contains(selectedFamily)
        // Heading + description and button + helper are each tight groups,
        // with a wider gap between them (LAY-5, FORM-5).
        return VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.medium) {
            VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xSmall) {
                HStack {
                    Label("Live Activity", systemImage: "livephoto")
                        .font(.headline)
                    Spacer()
                    // Green caption text on a pale green wash fails contrast
                    // in light mode (TYPE-3); the green fill carries the "on"
                    // signal and the copy stays primary text. The dark-mode
                    // secondary label is translucent and blends with the
                    // chip's own fill (4.4:1), so "Off" is primary too.
                    Text(isActive ? "On" : "Off")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, LiquidGlassMetrics.Spacing.xSmall)
                        .padding(.vertical, LiquidGlassMetrics.Spacing.xxSmall)
                        .background(
                            isActive ? AnyShapeStyle(Color.green.opacity(0.2)) : AnyShapeStyle(.fill.tertiary),
                            in: Capsule()
                        )
                }
                Text("Show \(selectedFamily.title) on the Lock Screen. Updates use local Cockpit data.")
                    .font(.subheadline)
                    .foregroundStyle(LegibleSecondaryText.color)
            }
            VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xSmall) {
                liveActivityButton(isActive: isActive)
                if !isActive && !hasSelectedSnapshot {
                    Text("Start becomes available after the first \(selectedFamily.title) snapshot arrives.")
                        .font(.caption)
                        .foregroundStyle(LegibleSecondaryText.color)
                        .transition(.opacity)
                }
            }
        }
        .padding(LiquidGlassMetrics.Spacing.large)
        .background(Self.panelFill, in: Self.panelShape)
        // On/Off, the button tier, and the helper line change together.
        .animation(reduceMotion ? nil : LiquidGlassMetrics.spring, value: isActive)
        .animation(LiquidGlassMetrics.stateChange, value: isChangingActivity)
    }

    private func liveActivityButton(isActive: Bool) -> some View {
        Button {
            Task { await toggleActivity() }
        } label: {
            HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                if isChangingActivity {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(isActive ? "Stop Live Activity" : "Start Live Activity")
                    .frame(maxWidth: .infinity)
            }
        }
        // Start is the sheet's one primary action; Stop is a reversible,
        // non-destructive toggle, so it drops to neutral glass, not red
        // (BTN-1, COL-4). Full-width capsule tap target (BTN-4).
        .liquidGlassButtonStyle(prominent: !isActive)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(isChangingActivity || (!isActive && !hasSelectedSnapshot))
    }

    @ViewBuilder
    private var errors: some View {
        if let dashboardError = mirror.dashboardError {
            errorLabel(dashboardError)
        }
        if let activityError = activities.lastError {
            errorLabel(activityError)
        }
    }

    /// The red signal lives on the glyph; footnote-size copy stays primary
    /// text, since system red on the light grouped background falls below
    /// small-text contrast (TYPE-3, COL-4).
    private func errorLabel(_ message: String) -> some View {
        Label {
            Text(message)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
        .font(.footnote)
        .fixedSize(horizontal: false, vertical: true)
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
