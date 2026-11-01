import SwiftUI

struct BuildMonitorView: View {
    @Bindable var monitor: BuildActivityController
    let connected: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let followed = monitor.followedRun {
                    Section {
                        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.small) {
                            runDetails(followed)
                            // Re-checked every 15s, so the warning appears
                            // while the sheet stays open, not only on the
                            // next update (MOT-5).
                            TimelineView(.periodic(from: .now, by: 15)) { context in
                                if !followed.state.isComplete && followed.state.staleDate < context.date {
                                    Label("Updates delayed. Check that Cockpit is awake and online.", systemImage: "wifi.slash")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            // Same glass capsule as Follow Build: stopping is
                            // reversible (follow again any time), so it stays
                            // neutral rather than destructive red (BTN-1, COL-4).
                            Button("Stop Following", systemImage: "stop.circle") {
                                Task { await monitor.stop() }
                            }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                        }
                        .padding(.vertical, LiquidGlassMetrics.Spacing.xxSmall)
                    } header: {
                        Text("Following")
                    } footer: {
                        // Monitor status rides the section it describes
                        // instead of a separate boxed section (LAY-1).
                        if let message = monitor.message { Text(message) }
                    }
                } else if let message = monitor.message {
                    // A glyph anchors the status line instead of a bare
                    // sentence alone in a card (HIER-3).
                    Section {
                        Label(message, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
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
                                let canFollow = connected && !monitor.isStarting
                                Button {
                                    Task { await monitor.follow(run, connected: connected) }
                                } label: {
                                    Label("Follow Build", systemImage: "livephoto")
                                        // Plain `.glass` keeps a full-strength
                                        // label when disabled, so the
                                        // disconnected state looked tappable;
                                        // dim it explicitly (BTN-5).
                                        .foregroundStyle(canFollow ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                                }
                                // Secondary glass control. A non-default style also
                                // keeps the List from routing taps anywhere in the
                                // row (including its GitHub link) to this button.
                                .buttonStyle(.glass)
                                .buttonBorderShape(.capsule)
                                .controlSize(.small)
                                .disabled(!canFollow)
                            }
                        }
                        .padding(.vertical, LiquidGlassMetrics.Spacing.xxSmall)
                        // Separators start at the row's text edge, not at
                        // whichever label (status, Follow Build) the List
                        // picks, so every divider lines up.
                        .alignmentGuide(.listRowSeparatorLeading) { dimensions in dimensions[.leading] }
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
            // Inline like Walkie's other sheets (Dashboard, Settings, Speech
            // Storage) so every sheet shares one header treatment.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func runDetails(_ run: BuildWorkflowRun) -> some View {
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xxSmall) {
            Text(run.workflow).font(.headline)
            Text("\(run.repository) · \(run.branch)").font(.subheadline).foregroundStyle(.secondary)
            HStack {
                // A plain glyph + text pair rather than a Label: inside a List,
                // Label reserves the row-icon column, which parks the status
                // text a wide gap away from its own glyph (LAY-5).
                HStack(spacing: LiquidGlassMetrics.Spacing.xxSmall) {
                    // Same state color as the Live Activity card, so runs
                    // scan by glyph shape and color before text (HIER-3).
                    Image(systemName: run.state.symbol)
                        .foregroundStyle(run.state.buildTint)
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityHidden(true)
                    Text(run.state.label)
                }
                Spacer()
                // A queued run has no clock yet; its status label already
                // says "Queued", so don't repeat it on the trailing edge.
                if run.state.startedAt != nil {
                    BuildElapsedTime(state: run.state)
                }
            }
            .font(.caption)
            // Borderless, so only the link text opens GitHub. With the
            // default style the List made the whole row its tap target, so a
            // tap on the row (or on a disabled Follow Build while
            // disconnected) left Walkie for Safari.
            Link("View on GitHub", destination: run.url)
                .font(.caption)
                .buttonStyle(.borderless)
        }
    }
}
