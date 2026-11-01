import SwiftUI

struct CopilotDashboardView: View {
    @Bindable var model: CopilotDashboardModel
    @ObservedObject var activities: DashboardActivityController
    let connected: Bool
    @Binding var selectedFamily: DashboardFamily
    @Environment(\.dismiss) private var dismiss
    @State private var isUpdatingActivity = false

    var body: some View {
        NavigationStack {
            ScrollView {
                // Three groups, tight inside and apart between (LAY-5): the
                // family picker, the snapshot with its data status, and the
                // Live Activity control with its status and explanation.
                VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xLarge) {
                    // System segmented picker: a capsule glass control on 26+.
                    // Segment names come from the shared family titles, so they
                    // match the card headers, widgets, and Kneeboard.
                    Picker("Dashboard", selection: $selectedFamily) {
                        ForEach(DashboardFamily.allCases, id: \.self) { family in
                            Text(family.title).tag(family)
                        }
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.small) {
                        if !connected {
                            // Orange glyph carries the caution; footnote copy
                            // stays secondary so it passes contrast (TYPE-3).
                            cautionLabel(Text("Cockpit disconnected · showing last-good data"), systemImage: "wifi.slash")
                                .foregroundStyle(.secondary)
                        }

                        selectedCard
                            .padding(LiquidGlassMetrics.Spacing.medium)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // Content card, not a control: a quiet fill instead of a
                            // material that would stack on the sheet's glass.
                            .background(.fill.quaternary, in: RoundedRectangle(
                                cornerRadius: LiquidGlassMetrics.Radius.card, style: .continuous
                            ))
                            .liquidGlassContainerShape()

                        if let error = model.persistenceError {
                            cautionLabel(Text(error), systemImage: "externaldrive.badge.exclamationmark")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.small) {
                        activityControl

                        if let error = activities.lastError {
                            cautionLabel(Text(error), systemImage: "exclamationmark.triangle.fill", tint: .red)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Text("Aggregate Live Activities update from Cockpit while connected. They do not use APNs or push notifications.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(LiquidGlassMetrics.Spacing.medium)
                // Context transition: the frame stays, the card content
                // cross-fades and the layout settles with a spring (MOT-1/MOT-4).
                .animation(LiquidGlassMetrics.spring, value: selectedFamily)
            }
            .navigationTitle("Dashboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var selectedCard: some View {
        switch selectedFamily {
        case .actions:
            ActionsDashboardWidgetView(snapshot: model.actions)
        case .usage:
            UsageDashboardWidgetView(snapshot: model.usage)
        case .runners:
            RunnersDashboardWidgetView(snapshot: model.runners)
        }
    }

    private var activityControl: some View {
        let isActive = activities.activeFamilies.contains(selectedFamily)
        return VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.small) {
            // The glyph carries the on/off color; the copy stays secondary so
            // green text never has to pass contrast on its own (TYPE-3).
            Label {
                Text(isActive ? "Live Activity is on" : "Live Activity is off")
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: isActive ? "livephoto" : "livephoto.slash")
                    .foregroundStyle(isActive ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .font(.subheadline)

            Button {
                updateActivity()
            } label: {
                Text(isActive ? "Stop Live Activity" : "Start Live Activity")
                    .frame(maxWidth: .infinity)
            }
            // Start is the sheet's one primary action (full-width prominent
            // glass); Stop is a reversible toggle, so it drops to neutral
            // glass, matching Kneeboard's dashboard (BTN-1, COL-4).
            .liquidGlassButtonStyle(prominent: !isActive)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(isUpdatingActivity || (!isActive && !hasSelectedSnapshot))

            if !isActive && !hasSelectedSnapshot {
                Text("Start becomes available after the first Cockpit update.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A footnote status line whose tinted glyph carries the caution or
    /// error signal while the text keeps the caller's contrast-safe
    /// foreground (TYPE-3; color is never the only signal, COL-4).
    private func cautionLabel(_ title: Text, systemImage: String, tint: Color = .orange) -> some View {
        Label {
            title
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
        .font(.footnote)
    }

    private var hasSelectedSnapshot: Bool {
        switch selectedFamily {
        case .actions: model.actions != nil
        case .usage: model.usage != nil
        case .runners: model.runners != nil
        }
    }

    private func updateActivity() {
        guard !isUpdatingActivity else { return }
        let family = selectedFamily
        isUpdatingActivity = true
        Task {
            defer { isUpdatingActivity = false }
            if activities.activeFamilies.contains(family) {
                await activities.stop(family)
                return
            }
            switch family {
            case .actions:
                if let snapshot = model.actions { try? await activities.startActions(snapshot) }
            case .usage:
                if let snapshot = model.usage { try? await activities.startUsage(snapshot) }
            case .runners:
                if let snapshot = model.runners { try? await activities.startRunners(snapshot) }
            }
        }
    }
}
