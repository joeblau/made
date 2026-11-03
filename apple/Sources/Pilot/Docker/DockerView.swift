import AppKit
import SwiftUI

/// Detail-area view for the global Docker mode. A status bar over a grouped list
/// of every container the local engine knows about, with the four lifecycle
/// actions inline on each row.
///
/// The engine is whatever the user already runs — Pilot only speaks the Engine
/// API over its Unix socket, so this section is a control surface, not a runtime.
struct DockerView: View {
    @Bindable var store: DockerStore

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            if let message = store.actionError {
                errorBanner(message)
            }
            content
        }
        .animation(LiquidGlassMetrics.spring, value: store.actionError)
        .confirmationDialog(
            "Remove Container?",
            isPresented: Binding(
                get: { store.containerPendingRemoval != nil },
                set: { if !$0 { store.containerPendingRemoval = nil } }
            ),
            presenting: store.containerPendingRemoval
        ) { container in
            Button("Remove Container", role: .destructive) {
                store.perform(.remove, on: container)
                store.containerPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { store.containerPendingRemoval = nil }
        } message: { container in
            Text("“\(container.name)” will be stopped and deleted. Its named volumes are kept.")
        }
        // Semantic text styles below follow Cockpit's ⌘+/⌘- ladder through
        // Dynamic Type, replacing one-off `scaledFont` point sizes (TYPE-4).
        .uiZoomedDynamicType()
        .onAppear { store.start() }
        .onDisappear { store.stop() }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: LiquidGlassMetrics.Spacing.small) {
            engineStatus

            Spacer(minLength: LiquidGlassMetrics.Spacing.small)

            // Header controls float as glass above the container list.
            TextField("Filter containers", text: $store.searchText)
                .frame(width: 160)
                .liquidGlassField(systemImage: "magnifyingglass")
                .font(.callout)

            Toggle("Show stopped", isOn: $store.showsStopped)
                .toggleStyle(.switch)
                .controlSize(.small)
                .scaledFont(size: 13)

            // The spinner for a manual or background refresh runs inside the
            // control itself rather than beside the engine status (MOT-5).
            Button {
                store.refreshNow()
            } label: {
                Label {
                    Text("Refresh containers")
                } icon: {
                    InspectorRefreshGlyph(isRefreshing: store.isRefreshing)
                }
            }
            .compatGlassIconButton(controlSize: .small)
            .disabled(!store.engine.isConnected)
            .help("Refresh")
        }
        .padding(.horizontal, LiquidGlassMetrics.Spacing.small)
        .padding(.vertical, LiquidGlassMetrics.Spacing.xSmall)
    }

    @ViewBuilder
    private var engineStatus: some View {
        switch store.engine {
        case .checking:
            HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                ProgressView().controlSize(.small)
                Text("Looking for a container engine…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .unavailable:
            HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                Circle().fill(.secondary).frame(width: 8, height: 8)
                Text("Engine not running")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        case .connected(let version, _):
            HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text(version.version.isEmpty ? "Docker" : "Docker \(version.version)")
                    .font(.callout.weight(.medium))
                Text("\(store.runningCount) of \(store.containers.count) running")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(LiquidGlassMetrics.stateChange, value: store.runningCount)
            }
        }
    }

    /// An inset warning wash (content, not glass) with rounded corners. Its
    /// radius is the dismiss circle's (~12pt) plus the 8pt vertical inset, so
    /// the corners nest concentrically (LAY-4).
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: LiquidGlassMetrics.Spacing.xSmall)
            Button {
                store.dismissActionError()
            } label: {
                Label("Dismiss error", systemImage: "xmark")
            }
            .compatGlassIconButton(controlSize: .small)
            .help("Dismiss")
        }
        .padding(.leading, LiquidGlassMetrics.Spacing.small)
        .padding(.trailing, LiquidGlassMetrics.Spacing.xSmall)
        .padding(.vertical, LiquidGlassMetrics.Spacing.xSmall)
        .background(
            Color.orange.opacity(0.1),
            in: RoundedRectangle(
                cornerRadius: LiquidGlassMetrics.Radius.field + LiquidGlassMetrics.Spacing.xSmall,
                style: .continuous
            )
        )
        .padding(.horizontal, LiquidGlassMetrics.Spacing.small)
        .padding(.bottom, LiquidGlassMetrics.Spacing.xSmall)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch store.engine {
        case .checking:
            ProgressView("Looking for a container engine…")
                .controlSize(.small)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable(let reason):
            unavailableState(reason: reason)
        case .connected:
            let visibleContainers = store.visibleContainers
            if store.containers.isEmpty {
                ContentUnavailableView {
                    Label("No Containers", systemImage: "shippingbox")
                } description: {
                    Text("Nothing has been created on this engine yet. Start one from a terminal with `docker run`.")
                }
                .legibleSecondaryHierarchy()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleContainers.isEmpty {
                ContentUnavailableView {
                    Label("Nothing Matches", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text(store.showsStopped
                         ? "No container matches the filter."
                         : "No running container matches the filter. Turn on “Show stopped” to see the rest.")
                }
                .legibleSecondaryHierarchy()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                containerList(visibleContainers)
            }
        }
    }

    /// Each container is its own card; sections are separated by whitespace
    /// and a plain title, not a rule (LAY-2).
    private func containerList(_ visibleContainers: [DockerContainerSummary]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(store.groupedContainers(from: visibleContainers)) { group in
                    VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.small) {
                        HStack(spacing: 6) {
                            if group.isCompose {
                                Image(systemName: "square.stack.3d.up")
                                    .scaledFont(size: 10)
                            }
                            Text(group.title)
                        }
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)

                        ForEach(group.containers) { container in
                            DockerContainerRow(
                                container: container,
                                isBusy: store.busyContainerIDs.contains(container.id),
                                isSelected: store.selectedContainerID == container.id,
                                perform: { action in
                                    if action == .remove {
                                        store.requestRemoval(of: container)
                                    } else {
                                        store.perform(action, on: container)
                                    }
                                }
                            )
                            .onTapGesture { store.selectedContainerID = container.id }
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                }
            }
            .animation(LiquidGlassMetrics.spring, value: store.showsStopped)
            .padding(.horizontal, LiquidGlassMetrics.Spacing.xSmall)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
    }

    private func unavailableState(reason: String) -> some View {
        ContentUnavailableView {
            Label("No Container Engine", systemImage: "shippingbox")
        } description: {
            VStack(spacing: 8) {
                Text(reason)
                Text("""
                     Cockpit talks to whichever engine you already run — Docker Desktop, \
                     Colima, Rancher Desktop, or Podman's Docker-compatible service. \
                     Start one and this list fills in.
                     """)
                .foregroundStyle(.secondary)
            }
        } actions: {
            // One primary action (BTN-1); neighbors share a glass container.
            CompatGlassContainer(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                    Button("Retry") { store.reconnect() }
                        .compatGlassProminentButtonStyle()
                    if let dockerApp = Self.installedDockerAppURL {
                        Button("Open Docker Desktop") {
                            NSWorkspace.shared.openApplication(
                                at: dockerApp,
                                configuration: NSWorkspace.OpenConfiguration()
                            )
                        }
                        .compatGlassButtonStyle()
                    }
                }
            }
        }
        .legibleSecondaryHierarchy()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Only offer the launch button when Docker Desktop is actually installed —
    /// a button that silently does nothing is worse than no button.
    private static var installedDockerAppURL: URL? {
        let url = URL(fileURLWithPath: "/Applications/Docker.app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// One container: state dot, name, image + status, ports, and the actions that
/// make sense for its current state.
private struct DockerContainerRow: View {
    let container: DockerContainerSummary
    let isBusy: Bool
    let isSelected: Bool
    let perform: (DockerContainerAction) -> Void

    @State private var isHovering = false
    /// The action button holding keyboard focus (Full Keyboard Access / Tab).
    @FocusState private var focusedAction: DockerContainerAction?
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    /// Pointer users get the hover reveal. Keyboard focus on an action and a
    /// running VoiceOver also reveal the actions, so a focused control is
    /// never invisible (A11Y keyboard/VoiceOver reachability).
    private var revealsActions: Bool {
        isHovering || focusedAction != nil || voiceOverEnabled
    }

    private static let cardShape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        HStack(spacing: LiquidGlassMetrics.Spacing.small) {
            Circle()
                .fill(container.state.indicatorColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(container.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: LiquidGlassMetrics.Spacing.xxSmall) {
                    Text(container.image)
                        .lineLimit(1)
                    Text(verbatim: "·")
                        .accessibilityHidden(true)
                    Text(container.status.isEmpty ? container.state.rawValue.capitalized : container.status)
                        .lineLimit(1)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: LiquidGlassMetrics.Spacing.xSmall)

            if !container.portsSummary.isEmpty {
                Text(container.portsSummary)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // The actions keep their layout slot while busy, and the spinner
            // sits over it, so the ports column never jumps mid-action. The
            // slot is always as wide as the longest action set, so a stopped
            // row (two actions) ends its ports where a running row (three)
            // does instead of one button further right.
            ZStack(alignment: .trailing) {
                actionButtons(Self.widestActions, placeholder: true)
                    .hidden()
                    .disabled(true)
                    .accessibilityHidden(true)
                actionButtons(availableActions)
                    .opacity(isBusy ? 0 : (revealsActions ? 1 : 0.001))
                    .disabled(isBusy)
                    .accessibilityHidden(isBusy)
            }
            .overlay(alignment: .trailing) {
                if isBusy {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Working")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // Matches the Usage cards: a tinted fill, no resting stroke.
        .background(.quaternary.opacity(isHovering ? 0.6 : 0.4), in: Self.cardShape)
        .overlay {
            // Selection is a state signal: an accent ring, not a fill (COL-4).
            if isSelected {
                Self.cardShape.strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 2)
            }
        }
        .contentShape(Self.cardShape)
        .onHover { isHovering = $0 }
        .animation(LiquidGlassMetrics.stateChange, value: isHovering)
        .animation(LiquidGlassMetrics.stateChange, value: focusedAction)
        .animation(LiquidGlassMetrics.stateChange, value: isBusy)
        // The same actions from the row itself in the VoiceOver actions
        // menu, so they do not depend on finding the trailing buttons.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityActions {
            if !isBusy {
                ForEach(availableActions, id: \.self) { action in
                    Button(action.label) { perform(action) }
                }
            }
        }
        .contextMenu {
            ForEach(availableActions, id: \.self) { action in
                // Remove asks for confirmation first, so its menu item takes
                // an ellipsis.
                Button(
                    action == .remove ? "\(action.label)…" : action.label,
                    systemImage: action.systemImage
                ) { perform(action) }
            }
            Divider()
            Button("Copy Container ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(container.id, forType: .string)
            }
        }
        .help(container.command.isEmpty ? container.shortID : "\(container.shortID) — \(container.command)")
    }

    /// Icon-only glass circles, one control size across the Docker surface.
    /// Remove carries no destructive role or red tint here: it only asks, and
    /// the danger color waits for the confirmation dialog (COL-4, MODAL-1).
    private func actionButtons(_ actions: [DockerContainerAction], placeholder: Bool = false) -> some View {
        CompatGlassContainer(spacing: LiquidGlassMetrics.Spacing.xxSmall) {
            HStack(spacing: LiquidGlassMetrics.Spacing.xxSmall) {
                ForEach(actions, id: \.self) { action in
                    Button {
                        perform(action)
                    } label: {
                        Label(action.label, systemImage: action.systemImage)
                    }
                    .compatGlassIconButton(controlSize: .small)
                    .focused($focusedAction, equals: placeholder ? nil : action)
                    .help(action.label)
                }
            }
        }
    }

    /// Starting a running container or stopping a stopped one are both no-ops;
    /// only offer what will actually do something.
    private var availableActions: [DockerContainerAction] {
        container.state.isRunning ? Self.widestActions : [.start, .remove]
    }

    /// The longest action set; it sizes every row's action slot.
    private static let widestActions: [DockerContainerAction] = [.stop, .restart, .remove]
}
