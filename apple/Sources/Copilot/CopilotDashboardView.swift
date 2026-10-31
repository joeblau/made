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
                VStack(alignment: .leading, spacing: 18) {
                    Picker("Dashboard", selection: $selectedFamily) {
                        Text("Actions").tag(DashboardFamily.actions)
                        Text("Usage").tag(DashboardFamily.usage)
                        Text("Runners").tag(DashboardFamily.runners)
                    }
                    .pickerStyle(.segmented)

                    if !connected {
                        Label("Cockpit disconnected · showing last-good data", systemImage: "wifi.slash")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }

                    selectedCard
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                    activityControl

                    if let error = activities.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = model.persistenceError {
                        Label(error, systemImage: "externaldrive.badge.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("Aggregate Live Activities update from Cockpit while connected. They do not use APNs or push notifications.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding()
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
        return VStack(alignment: .leading, spacing: 10) {
            Label(
                isActive ? "Live Activity is on" : "Live Activity is off",
                systemImage: isActive ? "livephoto" : "livephoto.slash"
            )
            .font(.subheadline)
            .foregroundStyle(isActive ? .green : .secondary)

            Button(isActive ? "Stop Live Activity" : "Start Live Activity") {
                updateActivity()
            }
            .buttonStyle(.borderedProminent)
            .disabled(isUpdatingActivity || (!isActive && !hasSelectedSnapshot))

            if !isActive && !hasSelectedSnapshot {
                Text("Start becomes available after the first Cockpit update.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
