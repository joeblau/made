import AppKit
import SwiftUI

/// Renamable groups of four remote screens, with stable blank grid positions.
struct RemoteDesktopView: View {
    @Bindable var store: WorkspaceStore
    var sessions: RemoteDesktopSessionManager = .shared
    @State private var groups: RemoteDesktopGroups
    @State private var pickerGroupID: UUID?
    @State private var discovery = RemoteScreenDiscovery()
    @State private var renamingGroupID: UUID?
    @State private var groupName = ""

    init(store: WorkspaceStore, sessions: RemoteDesktopSessionManager = .shared,
         groups: RemoteDesktopGroups = RemoteDesktopGroups()) {
        self.store = store
        self.sessions = sessions
        _groups = State(initialValue: groups)
    }

    private var visibleIDs: [UUID] { groups.selectedGroup?.connectionIDs ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            groupBar
            Divider()
            grid
        }
        .background(.black)
        .overlay {
            if let groupID = pickerGroupID {
                RemoteComputerPicker(
                    discovery: discovery,
                    onPick: { host, port, nickname in
                        guard let group = groups.groups.first(where: { $0.id == groupID }),
                              !group.isFull else { pickerGroupID = nil; return }
                        let connection = store.addRemoteConnection(host: host, port: port, nickname: nickname)
                        groups.place(connection.id, in: groupID)
                        pickerGroupID = nil
                    },
                    onCancel: { pickerGroupID = nil }
                )
                .transition(.opacity)
            }
        }
        .alert("Rename Group", isPresented: Binding(
            get: { renamingGroupID != nil },
            set: { if !$0 { renamingGroupID = nil } }
        )) {
            TextField("Group name", text: $groupName)
            Button("Save") {
                if let id = renamingGroupID { groups.renameGroup(id, to: groupName) }
                renamingGroupID = nil
            }
            .disabled(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { renamingGroupID = nil }
        }
        .confirmationDialog(
            "Remove this connection?",
            isPresented: Binding(
                get: { store.remoteConnectionPendingClose != nil },
                set: { if !$0 { store.remoteConnectionPendingClose = nil } }
            ),
            presenting: store.remoteConnectionPendingClose
        ) { connection in
            Button("Remove Connection", role: .destructive) {
                sessions.endSession(for: connection.id)
                store.deleteRemoteConnection(connection)
                store.remoteConnectionPendingClose = nil
            }
            Button("Cancel", role: .cancel) { store.remoteConnectionPendingClose = nil }
        } message: { connection in
            Text("“\(connection.displayTitle)” will be removed from your saved connections.")
        }
        .onChange(of: pickerGroupID) {
            if pickerGroupID != nil { discovery.start() } else { discovery.stop() }
        }
        .onChange(of: store.remoteConnections.map(\.id), initial: true) {
            groups.reconcile(connectionIDs: store.remoteConnections.map(\.id))
            synchronizeSelection()
        }
        .onChange(of: store.selectedRemoteConnectionID, initial: true) {
            synchronizeSelection()
        }
        .onChange(of: visibleIDs, initial: true) {
            synchronizeSelection()
            // Create sessions before marking the whole grid visible.
            for id in visibleIDs { _ = sessions.session(for: id) }
            sessions.setActiveConnections(Set(visibleIDs))
        }
        .onDisappear {
            discovery.stop()
            sessions.setActiveConnections([])
        }
    }

    private var groupBar: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(groups.groups) { group in
                        Button {
                            store.selectedRemoteConnectionID = groups.selectGroup(
                                group.id, preserving: store.selectedRemoteConnectionID
                            )
                        } label: {
                            Label(group.name, systemImage: "square.grid.2x2")
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    group.id == groups.selectedGroupID
                                        ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 7)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 7)
                                        .strokeBorder(group.id == groups.selectedGroupID
                                            ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Rename Group…") { rename(group) }
                            Button("Delete Empty Group", role: .destructive) { groups.deleteEmptyGroup(group.id) }
                                .disabled(!group.connectionIDs.isEmpty || groups.groups.count == 1)
                        }
                        .dropDestination(for: String.self) { items, _ in
                            return moveDroppedMachine(items, to: group.id)
                        }
                    }
                    Button {
                        let id = groups.addGroup()
                        store.selectedRemoteConnectionID = nil
                        if let group = groups.groups.first(where: { $0.id == id }) { rename(group) }
                    } label: {
                        Image(systemName: "plus").frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .help("New Group")
                    .accessibilityLabel("New Group")
                }
            }
            if let group = groups.selectedGroup {
                Button { rename(group) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.plain)
                    .help("Rename Group")
                    .accessibilityLabel("Rename Group")
                Text("\(group.connectionIDs.count)/4")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button { pickerGroupID = group.id } label: {
                    Label("Add Computer", systemImage: "plus")
                }
                .disabled(group.isFull)
                .help(group.isFull ? "This group already has four computers" : "Add a computer to this group")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var grid: some View {
        GeometryReader { geometry in
            if let group = groups.selectedGroup {
                let width = max(0, (geometry.size.width - 1) / 2)
                let height = max(0, (geometry.size.height - 1) / 2)
                VStack(spacing: 1) {
                    ForEach(0..<2) { row in
                        HStack(spacing: 1) {
                            ForEach(0..<2) { column in
                                let slot = row * 2 + column
                                cell(group: group, slot: slot)
                                    .frame(width: width, height: height)
                                    .clipped()
                            }
                        }
                    }
                }
                .background(Color(nsColor: .separatorColor))
            }
        }
    }

    @ViewBuilder
    private func cell(group: RemoteDesktopGroup, slot: Int) -> some View {
        if let id = group.slots[slot], let connection = store.remoteConnections.first(where: { $0.id == id }) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "display")
                    Text(connection.displayTitle).lineLimit(1)
                    Spacer()
                    Menu {
                        ForEach(groups.groups.filter { $0.id != group.id }) { destination in
                            Button("Move to \(destination.name)") { groups.place(id, in: destination.id) }
                                .disabled(destination.isFull)
                        }
                        Button("Disconnect") { sessions.session(for: id).disconnect() }
                        Button("Remove Connection…", role: .destructive) { store.requestCloseRemoteConnection(connection) }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Options for \(connection.displayTitle)")
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(store.selectedRemoteConnectionID == id
                    ? Color.accentColor.opacity(0.15) : Color(nsColor: .windowBackgroundColor))
                .contentShape(Rectangle())
                .onTapGesture { store.selectedRemoteConnectionID = id }
                .draggable(id.uuidString)
                Divider()
                RemoteConnectionPane(
                    connection: connection,
                    session: sessions.session(for: id),
                    isSelected: store.selectedRemoteConnectionID == id,
                    onActivate: {
                        if store.selectedRemoteConnectionID != id {
                            store.selectedRemoteConnectionID = id
                        }
                    }
                )
                .id(id)
            }
        } else {
            Color.black
                .dropDestination(for: String.self) { items, _ in
                    return moveDroppedMachine(items, to: group.id, slot: slot)
                }
                .accessibilityLabel("Empty computer slot \(slot + 1)")
        }
    }

    private func rename(_ group: RemoteDesktopGroup) {
        groupName = group.name
        renamingGroupID = group.id
    }

    private func synchronizeSelection() {
        // Initial SwiftUI change callbacks can arrive in either order. Seed
        // a newly selected saved computer before resolving group membership.
        if let selectedID = store.selectedRemoteConnectionID,
           store.remoteConnections.contains(where: { $0.id == selectedID }),
           !groups.groups.contains(where: { $0.connectionIDs.contains(selectedID) }) {
            groups.reconcile(connectionIDs: store.remoteConnections.map(\.id))
        }
        let selectedID = groups.selectConnection(store.selectedRemoteConnectionID)
        if store.selectedRemoteConnectionID != selectedID {
            store.selectedRemoteConnectionID = selectedID
        }
    }

    private func moveDroppedMachine(_ items: [String], to groupID: UUID, slot: Int? = nil) -> Bool {
        guard let raw = items.first, let id = UUID(uuidString: raw),
              store.remoteConnections.contains(where: { $0.id == id }) else { return false }
        return groups.place(id, in: groupID, slot: slot)
    }
}

/// One connection's pane: a connect form until the user supplies a password and
/// hits Connect, then the embedded live VNC view (with a spinner while the
/// handshake completes, and an inline error on failure).
private struct RemoteConnectionPane: View {
    @Bindable var connection: RemoteDesktopConnection
    /// Owned by `RemoteDesktopSessionManager`, not by this view — it survives
    /// tab switches and leaving Remote Desktop mode.
    let session: RemoteDesktopSession
    let isSelected: Bool
    let onActivate: () -> Void

    @State private var password = ""
    @State private var savePassword = false
    @State private var shareClipboard = false
    @State private var didTryAutoConnect = false

    var body: some View {
        ZStack {
            switch session.status {
            case .idle, .disconnected:
                connectForm(error: nil)
            case .failed(let message):
                connectForm(error: message)
            case .connecting, .connected:
                RemoteDesktopViewer(
                    session: session,
                    framebufferGeneration: session.framebufferGeneration,
                    onActivate: onActivate
                )
                .background(Color.black)

                if session.status == .connecting {
                    connectingOverlay
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            shareClipboard = VNCPreferences.isClipboardRedirectionEnabled(id: connection.id)
            restoreSavedPasswordAndConnect()
        }
        // The connection is only *recorded* once the server has accepted it, so
        // a tab that never authenticated does not claim a connection time.
        .onChange(of: session.status) { _, status in
            guard status == .connected else { return }
            connection.lastConnectedAt = Date()
            _ = connection.modelContext?.saveReporting(operation: "Recording remote desktop connection")
        }
        .onChange(of: session.credentialRejected) { _, rejected in
            if rejected { password = "" }
        }
    }

    /// Auto-connect when a password was saved. A session that is already live
    /// (the common case when tabbing back) is left exactly as it is — that is
    /// the whole point of hoisting session ownership out of this view.
    private func restoreSavedPasswordAndConnect() {
        guard !didTryAutoConnect else { return }
        didTryAutoConnect = true
        // Restore the form even after a network failure. Auto-connect remains
        // gated below, so returning to a failed session does not retry it.
        guard let saved = VNCKeychain.load(id: connection.id), !saved.isEmpty else { return }
        password = saved
        savePassword = true
        // `.failed` is deliberately excluded: a rejected credential must not be
        // retried on every tab-in, which is the loop this whole change removes.
        switch session.status {
        case .idle, .disconnected: break
        case .connecting, .connected, .failed: return
        }
        connect()
    }

    private var connectingOverlay: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.large)
            Text("Connecting to \(connection.displayTitle)…")
                .foregroundStyle(.white.opacity(0.85))
                .font(.callout)
            Button("Cancel") { session.disconnect() }
                .keyboardShortcut(isSelected ? .cancelAction : nil)
                .buttonStyle(.bordered)
                .tint(.white)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.55))
    }

    private func connectForm(error: String?) -> some View {
        GeometryReader { geometry in
            ScrollView {
                connectFormContents(error: error)
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geometry.size.height)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func connectFormContents(error: String?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "display")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)

            VStack(spacing: 2) {
                Text(connection.displayTitle)
                    .font(.title3.weight(.semibold))
                Text(verbatim: "\(connection.host):\(connection.port)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                TextField("Username (optional)", text: Bindable(connection).username)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                    .onSubmit(connect)
                Toggle("Save password & auto-connect", isOn: $savePassword)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .frame(maxWidth: 280, alignment: .leading)
                Toggle("Share clipboard with remote Mac", isOn: $shareClipboard)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .frame(maxWidth: 280, alignment: .leading)
                Text("Off by default. Enabling this lets the remote VNC server read and replace your Mac clipboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 280, alignment: .leading)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            Button(action: connect) {
                Text(error == nil ? "Connect" : "Try Again")
                    .frame(width: 120)
            }
            .keyboardShortcut(isSelected ? .defaultAction : nil)
            .buttonStyle(.borderedProminent)
            .disabled(connection.host.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    /// Start a connection. Deliberately does *not* touch the Keychain: the
    /// password is only persisted once the server accepts it (and dropped when
    /// the server rejects it), which is what stops a wrong password from being
    /// cached and replayed on every tab-in.
    private func connect() {
        VNCPreferences.setClipboardRedirectionEnabled(shareClipboard, id: connection.id)
        session.connect(
            host: connection.host,
            port: connection.port,
            username: connection.username,
            password: password,
            savePasswordOnSuccess: savePassword,
            isClipboardRedirectionEnabled: shareClipboard
        )
    }
}

/// The "new tab" overlay: a card listing the machines discovered over Bonjour
/// (`_rfb._tcp`) plus a manual host field. Same visual chrome as the editor
/// pane's fuzzy file finder.
private struct RemoteComputerPicker: View {
    let discovery: RemoteScreenDiscovery
    let onPick: (_ host: String, _ port: Int, _ nickname: String) -> Void
    let onCancel: () -> Void

    @State private var manualHost = ""
    @State private var isResolving = false
    @FocusState private var manualFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "wifi")
                    .foregroundStyle(.secondary)
                Text("Computers on this network")
                    .font(.system(size: 14, weight: .medium))
                Spacer()
                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            discoveredList
                .frame(maxHeight: 280)

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "network")
                    .foregroundStyle(.secondary)
                TextField("Host, IP, or MagicDNS (e.g. mini01.tailnet.ts.net)", text: $manualHost)
                    .textFieldStyle(.plain)
                    .focused($manualFocused)
                    .onSubmit(connectManual)
                Button("Connect", action: connectManual)
                    .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(width: 520)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 60)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var discoveredList: some View {
        if discovery.services.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(discovery.services) { service in
                        Button {
                            pick(service)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "macbook")
                                    .foregroundStyle(.secondary)
                                Text(service.name)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            .disabled(isResolving)
            .opacity(isResolving ? 0.5 : 1)
        }
    }

    /// Shown while no machines are listed. Always offers the actionable next
    /// steps (a Mac needs Screen Sharing on; Pilot needs Local Network access),
    /// and reads as a clear error — not a perpetual spinner — when the browser
    /// reports it's blocked.
    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            switch discovery.browseState {
            case .needsPermission, .failed:
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                Text("made can't browse the local network")
                    .font(.callout.weight(.medium))
            default:
                ProgressView().controlSize(.small)
                Text("Looking for computers with Screen Sharing enabled…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Text("The target Mac needs Screen Sharing on (System Settings → General → Sharing), and made needs Local Network access. You can still connect by typing a host below.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button("Open Local Network Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func pick(_ service: RemoteScreenDiscovery.Service) {
        isResolving = true
        Task {
            let resolved = await discovery.resolve(service)
            isResolving = false
            if let resolved {
                onPick(resolved.host, resolved.port, service.name)
            } else {
                // Resolution failed — fall back to the Bonjour name, which is
                // usually reachable as "<name>.local" on the same network.
                onPick(service.name, 5900, service.name)
            }
        }
    }

    private func connectManual() {
        let trimmed = manualHost.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let (host, port) = Self.parseHostPort(trimmed)
        onPick(host, port, "")
    }

    /// Split a manual entry into (host, port), defaulting to the VNC port 5900.
    /// Accepts a MagicDNS name (`mini01.tailnet.ts.net`), an IPv4 address
    /// (`100.123.212.24`), or an IPv6 address — bare (`fd7a:115c:a1e0::953b:d419`)
    /// or bracketed with a port (`[fd7a::1]:5901`). RoyalVNCKit takes the host and
    /// port separately and its `hostname` accepts a bare IPv6 literal, so the
    /// brackets are only a way to disambiguate a trailing `:port` and never kept.
    private static func parseHostPort(_ input: String) -> (String, Int) {
        let defaultPort = 5900

        // Bracketed IPv6, optionally with a `:port` suffix — `[fd7a::1]` / `[fd7a::1]:5901`.
        if input.hasPrefix("["), let close = input.firstIndex(of: "]") {
            let host = String(input[input.index(after: input.startIndex)..<close])
            let rest = input[input.index(after: close)...]   // "" or ":5901"
            if rest.hasPrefix(":"), let port = Int(rest.dropFirst()) {
                return (host, port)
            }
            return (host, defaultPort)
        }

        // Bare IPv6 (two or more colons): a port can't be appended without
        // brackets, so the whole string is the host — never split on its colons.
        if input.filter({ $0 == ":" }).count >= 2 {
            return (input, defaultPort)
        }

        // IPv4 / hostname / MagicDNS, optionally written as `host:port`.
        if let colon = input.lastIndex(of: ":"),
           let port = Int(input[input.index(after: colon)...]) {
            return (String(input[..<colon]), port)
        }
        return (input, defaultPort)
    }
}
