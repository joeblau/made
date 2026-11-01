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
                Section {
                    if monitor.runs.isEmpty {
                        ContentUnavailableView(
                            connected ? "No Recent Builds" : "Connect to Cockpit",
                            systemImage: "hammer",
                            description: Text(connected
                                ? "Open a GitHub project in Cockpit. Its workflow runs will appear here."
                                : "Open Cockpit on your Mac to choose a workflow run.")
                        )
                        // Float the empty state on the grouped background
                        // instead of boxing it in a row card (LAY-1/MOT-6).
                        .listRowBackground(Color.clear)
                    }
                    ForEach(monitor.runs) { run in
                        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.small) {
                            runDetails(run)
                            if !run.state.isComplete, monitor.followedRun?.id != run.id {
                                Button("Follow Build", systemImage: "livephoto") {
                                    Task { await monitor.follow(run, connected: connected) }
                                }
                                // Secondary glass control. A non-default style also
                                // keeps the List from routing taps anywhere in the
                                // row (including its GitHub link) to this button.
                                .buttonStyle(.glass)
                                .buttonBorderShape(.capsule)
                                .controlSize(.small)
                                .disabled(!connected || monitor.isStarting)
                            }
                        }
                        .padding(.vertical, LiquidGlassMetrics.Spacing.xxSmall)
                    }
                } header: {
                    Text("Workflow runs")
                } footer: {
                    // Explanatory copy rides the section footer instead of its
                    // own boxed section.
                    Text("Follow one run on your Lock Screen and Dynamic Island. Updates continue while Cockpit is running and your Mac is awake. Starting another monitor replaces the current one.")
                }
            }
            // Following/unfollowing and new runs reflow the list with a
            // settle instead of an instant swap (MOT-4).
            .animation(LiquidGlassMetrics.spring, value: monitor.followedRun?.id)
            .animation(LiquidGlassMetrics.spring, value: monitor.runs.map(\.id))
            .navigationTitle("Builds")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func runDetails(_ run: BuildWorkflowRun) -> some View {
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xxSmall) {
            Text(run.workflow).font(.headline)
            Text("\(run.repository) · \(run.branch)").font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Label {
                    Text(run.state.label)
                } icon: {
                    // Same state color as the Live Activity card, so runs
                    // scan by glyph shape and color before text (HIER-3).
                    Image(systemName: run.state.symbol)
                        .foregroundStyle(run.state.buildTint)
                        .contentTransition(.symbolEffect(.replace))
                }
                Spacer()
                BuildElapsedTime(state: run.state)
            }
            .font(.caption)
            Link("View on GitHub", destination: run.url).font(.caption)
        }
    }
}
