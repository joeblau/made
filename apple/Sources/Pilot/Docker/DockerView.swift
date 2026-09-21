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
        .confirmationDialog(
            "Remove this container?",
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
        .onAppear { store.start() }
        .onDisappear { store.stop() }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 10) {
            engineStatus

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .scaledFont(size: 12)
                    .frame(width: 160)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            Toggle("Show stopped", isOn: $store.showsStopped)
                .toggleStyle(.checkbox)
                .controlSize(.small)

            Button {
                store.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .scaledFont(size: 12, weight: .medium)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!store.engine.isConnected)
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var engineStatus: some View {
        switch store.engine {
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for a container engine…")
                    .scaledFont(size: 12)
                    .foregroundStyle(.secondary)
            }
        case .unavailable:
            HStack(spacing: 8) {
                Circle().fill(.secondary).frame(width: 7, height: 7)
                Text("Engine not running")
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(.secondary)
            }
        case .connected(let version, _):
            HStack(spacing: 8) {
                Circle().fill(.green).frame(width: 7, height: 7)
                Text(version.version.isEmpty ? "Docker" : "Docker \(version.version)")
                    .scaledFont(size: 12, weight: .medium)
                Text("\(store.runningCount) of \(store.containers.count) running")
                    .scaledFont(size: 12)
                    .foregroundStyle(.secondary)
                if store.isRefreshing {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                }
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .scaledFont(size: 12)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button {
                store.dismissActionError()
            } label: {
                Image(systemName: "xmark")
                    .scaledFont(size: 10, weight: .semibold)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch store.engine {
        case .checking:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable(let reason):
            unavailableState(reason: reason)
        case .connected:
            if store.containers.isEmpty {
                ContentUnavailableView {
                    Label("No Containers", systemImage: "shippingbox")
                } description: {
                    Text("Nothing has been created on this engine yet. Start one from a terminal with `docker run`.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.visibleContainers.isEmpty {
                ContentUnavailableView {
                    Label("Nothing Matches", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text(store.showsStopped
                         ? "No container matches the filter."
                         : "No running container matches the filter. Turn on “Show stopped” to see the rest.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                containerList
            }
        }
    }

    private var containerList: some View {
        List(selection: $store.selectedContainerID) {
            ForEach(store.groupedContainers) { group in
                Section {
                    ForEach(group.containers) { container in
                        DockerContainerRow(
                            container: container,
                            isBusy: store.busyContainerIDs.contains(container.id),
                            perform: { action in
                                if action == .remove {
                                    store.requestRemoval(of: container)
                                } else {
                                    store.perform(action, on: container)
                                }
                            }
                        )
                        .tag(container.id)
                    }
                } header: {
                    HStack(spacing: 6) {
                        if group.isCompose {
                            Image(systemName: "square.stack.3d.up")
                                .scaledFont(size: 10)
                        }
                        Text(group.title)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func unavailableState(reason: String) -> some View {
        ContentUnavailableView {
            Label("No Container Engine", systemImage: "shippingbox")
        } description: {
            VStack(spacing: 6) {
                Text(reason)
                Text("""
                     Pilot talks to whichever engine you already run — Docker Desktop, \
                     Colima, Rancher Desktop, or Podman's Docker-compatible service. \
                     Start one and this list fills in.
                     """)
                .foregroundStyle(.tertiary)
            }
        } actions: {
            HStack(spacing: 10) {
                Button("Retry") { store.reconnect() }
                    .buttonStyle(.borderedProminent)
                if let dockerApp = Self.installedDockerAppURL {
                    Button("Open Docker Desktop") {
                        NSWorkspace.shared.openApplication(
                            at: dockerApp,
                            configuration: NSWorkspace.OpenConfiguration()
                        )
                    }
                }
            }
        }
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
    let perform: (DockerContainerAction) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(container.state.indicatorColor)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(container.name)
                    .scaledFont(size: 13, weight: .medium)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(container.image)
                        .lineLimit(1)
                    Text(verbatim: "·")
                    Text(container.status.isEmpty ? container.state.rawValue.capitalized : container.status)
                        .lineLimit(1)
                }
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if !container.portsSummary.isEmpty {
                Text(container.portsSummary)
                    .scaledFont(size: 11)
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 60, alignment: .trailing)
            } else {
                actions
                    .opacity(isHovering ? 1 : 0.001)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            ForEach(availableActions, id: \.self) { action in
                Button(action.label, systemImage: action.systemImage) { perform(action) }
            }
            Divider()
            Button("Copy Container ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(container.id, forType: .string)
            }
        }
        .help(container.command.isEmpty ? container.shortID : "\(container.shortID) — \(container.command)")
    }

    private var actions: some View {
        HStack(spacing: 2) {
            ForEach(availableActions, id: \.self) { action in
                Button {
                    perform(action)
                } label: {
                    Image(systemName: action.systemImage)
                        .scaledFont(size: 11, weight: .medium)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(action == .remove ? Color.red.opacity(0.8) : Color.secondary)
                .help(action.label)
            }
        }
    }

    /// Starting a running container or stopping a stopped one are both no-ops;
    /// only offer what will actually do something.
    private var availableActions: [DockerContainerAction] {
        container.state.isRunning ? [.stop, .restart, .remove] : [.start, .remove]
    }
}
