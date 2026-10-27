import SwiftUI

struct BuildMonitorView: View {
    @Bindable var monitor: BuildActivityController
    let connected: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let followed = monitor.followedRun {
                    Section("Following") {
                        runDetails(followed)
                        if !followed.state.isComplete && followed.state.staleDate < Date() {
                            Label("Updates delayed. Check that Cockpit is awake and online.", systemImage: "wifi.slash")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Button("Stop Following", role: .destructive) { Task { await monitor.stop() } }
                    }
                }
                if let message = monitor.message {
                    Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }
                Section("Workflow runs") {
                    if monitor.runs.isEmpty {
                        ContentUnavailableView(
                            connected ? "No Recent Builds" : "Connect to Cockpit",
                            systemImage: "hammer",
                            description: Text(connected
                                ? "Open a GitHub project in Cockpit. Its workflow runs will appear here."
                                : "Open Cockpit on your Mac to choose a workflow run.")
                        )
                    }
                    ForEach(monitor.runs) { run in
                        VStack(alignment: .leading, spacing: 10) {
                            runDetails(run)
                            if !run.state.isComplete, monitor.followedRun?.id != run.id {
                                Button("Follow Build", systemImage: "livephoto") {
                                    Task { await monitor.follow(run, connected: connected) }
                                }
                                .disabled(!connected || monitor.isStarting)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                Section {
                    Text("Follow one run on your Lock Screen and Dynamic Island. Updates continue while Cockpit is running and your Mac is awake. Starting another monitor replaces the current one.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Builds")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func runDetails(_ run: BuildWorkflowRun) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(run.workflow).font(.headline)
            Text("\(run.repository) · \(run.branch)").font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Label(run.state.label, systemImage: run.state.symbol)
                Spacer()
                BuildElapsedTime(state: run.state)
            }
            .font(.caption)
            Link("View on GitHub", destination: run.url).font(.caption)
        }
    }
}
