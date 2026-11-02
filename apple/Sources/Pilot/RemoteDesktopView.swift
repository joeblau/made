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
            grid
        }
        .background(.black)
        .overlay {
            ZStack {
                if let groupID = pickerGroupID {
                    remoteComputerPicker(groupID: groupID)
                        // Content scale + fade (MODAL-2), springing into place
                        // (MOT-4). The animation is scoped to this overlay so
                        // the grid and live VNC views never interpolate.
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
            }
            .animation(LiquidGlassMetrics.spring, value: pickerGroupID)
        }
        // A glass prompt sheet rather than a system alert, so the name field
        // is a Liquid Glass field like every other text input.
        .sheet(isPresented: Binding(
            get: { renamingGroupID != nil },
            set: { if !$0 { renamingGroupID = nil } }
        )) {
            TextPromptSheet(
                title: "Rename Group",
                label: "Group name",
                prompt: "Studio Macs",
                confirmTitle: "Save",
                text: $groupName,
                onCancel: { renamingGroupID = nil }
            ) {
                if let id = renamingGroupID { groups.renameGroup(id, to: groupName) }
                renamingGroupID = nil
            }
        }
        .confirmationDialog(
            "Remove Connection?",
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

    private func remoteComputerPicker(groupID: UUID) -> some View {
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
    }

    /// Group tabs are capsule glass chips above the screen grid; only the
    /// selected group carries the accent tint, as a state signal (COL-4). The
    /// chips, New Group, Rename, and Add Computer are one control cluster, so
    /// each run of neighboring glass shares a container.
    private var groupBar: some View {
        HStack(spacing: LiquidGlassMetrics.Spacing.small) {
            GlassChipScroller {
                groupChips
            }
            if let group = groups.selectedGroup {
                CompatGlassContainer(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                    HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                        Button { rename(group) } label: {
                            Label("Rename Group", systemImage: "pencil")
                        }
                        .compatGlassIconButton()
                        .help("Rename Group")
                        Text("\(group.connectionIDs.count)/4")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button { pickerGroupID = group.id } label: {
                            Label("Add Computer", systemImage: "plus")
                        }
                        .compatGlassButtonStyle()
                        .disabled(group.isFull)
                        .help(group.isFull ? "This group already has four computers" : "Add a computer to this group")
                    }
                }
            }
        }
        .padding(.horizontal, LiquidGlassMetrics.Spacing.small)
        .padding(.vertical, LiquidGlassMetrics.Spacing.xSmall)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var groupChips: some View {
        HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
            ForEach(groups.groups) { group in
                let isSelected = group.id == groups.selectedGroupID
                Button {
                    store.selectedRemoteConnectionID = groups.selectGroup(
                        group.id, preserving: store.selectedRemoteConnectionID
                    )
                } label: {
                    Label(group.name, systemImage: "square.grid.2x2")
                }
                .buttonStyle(.liquidGlassChip(isSelected: isSelected))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
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
                Label("New Group", systemImage: "plus")
            }
            .compatGlassIconButton()
            .help("New Group")
        }
        .padding(.vertical, LiquidGlassMetrics.Spacing.xxSmall)
        .animation(LiquidGlassMetrics.stateChange, value: groups.selectedGroupID)
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
            let isSelected = store.selectedRemoteConnectionID == id
            VStack(spacing: 0) {
                HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                    Image(systemName: "display")
                        .foregroundStyle(.secondary)
                    Text(connection.displayTitle).lineLimit(1)
                        // The header row selects on a plain tap below; the
                        // title gives VoiceOver the same button action.
                        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction { store.selectedRemoteConnectionID = id }
                    Spacer()
                    // Icon-only overflow menu: a small circular glass button
                    // matching the other icon controls (BTN-1 tertiary tier).
                    Menu {
                        ForEach(groups.groups.filter { $0.id != group.id }) { destination in
                            Button("Move to \(destination.name)") { groups.place(id, in: destination.id) }
                                .disabled(destination.isFull)
                        }
                        Button("Disconnect") { sessions.session(for: id).disconnect() }
                        Button("Remove Connection…", role: .destructive) { store.requestCloseRemoteConnection(connection) }
                    } label: {
                        Label("Options", systemImage: "ellipsis")
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .compatGlassIconButton(controlSize: .small)
                    .fixedSize()
                    .accessibilityLabel("Options for \(connection.displayTitle)")
                }
                .font(.callout)
                .padding(.horizontal, LiquidGlassMetrics.Spacing.small)
                .padding(.vertical, LiquidGlassMetrics.Spacing.xxSmall)
                // The selection tint is translucent, so it sits on the opaque
                // window background; on its own it composited over the black
                // grid and left the title and menu unreadable in light mode.
                .background {
                    ZStack {
                        Color(nsColor: .windowBackgroundColor)
                        if isSelected { Color.accentColor.opacity(0.15) }
                    }
                }
                .animation(LiquidGlassMetrics.stateChange, value: isSelected)
                .contentShape(Rectangle())
                .onTapGesture { store.selectedRemoteConnectionID = id }
                .draggable(id.uuidString)
                RemoteConnectionPane(
                    connection: connection,
                    session: sessions.session(for: id),
                    isSelected: isSelected,
                    onActivate: {
                        if store.selectedRemoteConnectionID != id {
                            store.selectedRemoteConnectionID = id
                        }
                    }
                )
                .id(id)
            }
        } else {
            // A quiet placeholder so an empty slot reads as a drop target
            // rather than a dead black tile (MOT-6).
            ZStack {
                Color.black
                // Secondary, not tertiary: tertiary label on pure black is
                // about 2:1 and drops below the TYPE-3 contrast floor.
                Label("Empty Slot", systemImage: "display")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .environment(\.colorScheme, .dark)
            }
            .dropDestination(for: String.self) { items, _ in
                return moveDroppedMachine(items, to: group.id, slot: slot)
            }
            .accessibilityElement(children: .ignore)
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

    /// Scrim over the (possibly stale) framebuffer while the handshake runs
    /// (COL-6). Always dark, so its semantic secondary text keeps contrast in
    /// both appearances (COL-2).
    private var connectingOverlay: some View {
        VStack(spacing: LiquidGlassMetrics.Spacing.small) {
            ProgressView().controlSize(.large)
            Text("Connecting to \(connection.displayTitle)…")
                .foregroundStyle(.secondary)
                .font(.callout)
            Button("Cancel") { session.disconnect() }
                .keyboardShortcut(isSelected ? .cancelAction : nil)
                .compatGlassButtonStyle()
        }
        .environment(\.colorScheme, .dark)
        .padding(LiquidGlassMetrics.Spacing.xxLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.55))
    }

    private func connectForm(error: String?) -> some View {
        GeometryReader { geometry in
            ScrollView {
                // A quarter tile on a laptop display is too short for the full
                // form, which pushed the Connect button below the fold. Below
                // that height the decorative icon goes and the group gaps
                // tighten so the primary action stays visible (BTN-1).
                connectFormContents(error: error, compact: geometry.size.height < Self.fullFormMinHeight)
                    .padding(LiquidGlassMetrics.Spacing.medium)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geometry.size.height)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// Width of the connect form's single column.
    private static let formWidth: CGFloat = 280

    /// Tile height below which the connect form drops its icon header.
    private static let fullFormMinHeight: CGFloat = 500

    /// Connect form spacing follows FORM-5: label → field 8, between field
    /// groups 20, final group → submit 24. Every field keeps a persistent
    /// label above it; placeholders are instructions only (FORM-1/FORM-2).
    private func connectFormContents(error: String?, compact: Bool) -> some View {
        VStack(spacing: compact ? LiquidGlassMetrics.Spacing.medium : LiquidGlassMetrics.Spacing.xLarge) {
            VStack(spacing: LiquidGlassMetrics.Spacing.small) {
                if !compact {
                    Image(systemName: "display")
                        .font(.largeTitle.weight(.light))
                        .foregroundStyle(.tertiary)
                }

                VStack(spacing: LiquidGlassMetrics.Spacing.xxSmall) {
                    Text(connection.displayTitle)
                        .font(.title3.weight(.semibold))
                    Text(verbatim: "\(connection.host):\(connection.port)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: compact ? LiquidGlassMetrics.Spacing.medium : LiquidGlassMetrics.Spacing.large) {
                fieldGroup("Username", detail: "Optional") {
                    TextField("Username", text: Bindable(connection).username, prompt: Text("Enter username"))
                        .liquidGlassField()
                }
                fieldGroup("Password") {
                    SecureField("Password", text: $password, prompt: Text("Enter password"))
                        .onSubmit(connect)
                        .liquidGlassField()
                }
                VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xSmall) {
                    Toggle("Save password & auto-connect", isOn: $savePassword)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xxSmall) {
                        Toggle("Share clipboard with remote Mac", isOn: $shareClipboard)
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                        Text("Off by default. Enabling this lets the remote VNC server read and replace your Mac clipboard.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: Self.formWidth, alignment: .leading)

            // The pane's single primary action, full width in the form column
            // (BTN-1, BTN-4).
            Button(action: connect) {
                Text(error == nil ? "Connect" : "Try Again")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(isSelected ? .defaultAction : nil)
            .compatGlassProminentButtonStyle()
            .controlSize(.large)
            .frame(maxWidth: Self.formWidth)
            .disabled(connection.host.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .uiZoomedDynamicType()
    }

    /// A persistent label (with optional trailing hint) above its field. The
    /// field's own title carries the VoiceOver name, so the visible label is
    /// hidden from accessibility to avoid reading it twice.
    private func fieldGroup<Field: View>(
        _ label: String,
        detail: String? = nil,
        @ViewBuilder field: () -> Field
    ) -> some View {
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xSmall) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityHidden(true)
            field()
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
/// (`_rfb._tcp`) plus a manual host field. A floating glass panel (the
/// control layer over the screen grid), like the editor pane's fuzzy file
/// finder. Its host field and buttons are interactive glass controls on that
/// layer, like every other free-standing field.
private struct RemoteComputerPicker: View {
    let discovery: RemoteScreenDiscovery
    let onPick: (_ host: String, _ port: Int, _ nickname: String) -> Void
    let onCancel: () -> Void

    @State private var manualHost = ""
    @State private var isResolving = false
    @FocusState private var manualFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                Image(systemName: "wifi")
                    .glassLegibleForeground(.secondary)
                Text("Computers on This Network")
                    .font(.headline)
                Spacer()
                Button {
                    onCancel()
                } label: {
                    Label("Close", systemImage: "xmark")
                }
                .compatGlassIconButton(controlSize: .small)
                .help("Close")
            }
            .padding(.horizontal, LiquidGlassMetrics.Spacing.medium)
            .padding(.vertical, LiquidGlassMetrics.Spacing.small)

            discoveredList
                .frame(maxHeight: 280)

            manualEntry
                .padding(.horizontal, LiquidGlassMetrics.Spacing.medium)
                .padding(.top, LiquidGlassMetrics.Spacing.xSmall)
                .padding(.bottom, LiquidGlassMetrics.Spacing.medium)
        }
        .frame(width: 520)
        // The panel floats over the always-black screen grid, where light glass
        // turned mid-gray (title 5.9:1, secondary 4.5:1) and dark system
        // secondary measured 3.2:1. Always dark, like `connectingOverlay`.
        // Secondary copy sets the legible gray itself: glass drew text styled
        // `.secondary` at 3.15:1 even under `legibleSecondaryHierarchy()`, and
        // that modifier dimmed the host field's placeholder to 2.6:1 (TYPE-3).
        .compatFloatingGlass(in: RoundedRectangle(cornerRadius: LiquidGlassMetrics.Radius.panel, style: .continuous))
        .environment(\.colorScheme, .dark)
        // A browser left `.waiting` keeps reporting denied after access is
        // granted, so coming back from System Settings starts a fresh one.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            discovery.retryIfNeedsPermission()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 60)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Manual host entry with a persistent label (FORM-1); the placeholder is
    /// an instruction (FORM-2). Glass capsule field with a visible focus ring
    /// (FORM-4), next to the panel's one primary action (BTN-1).
    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xSmall) {
            Text("Host Address")
                .font(.subheadline.weight(.medium))
                .glassLegibleForeground(.secondary)
                .accessibilityHidden(true)
            HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                // Glass like every other free-standing field: the panel is a
                // glass control layer and its controls are glass too.
                TextField(
                    "Host Address",
                    text: $manualHost,
                    prompt: Text("Enter a host, IP address, or MagicDNS name")
                )
                .focused($manualFocused)
                .onSubmit(connectManual)
                .liquidGlassField(systemImage: "network", isFocused: manualFocused)

                Button("Connect", action: connectManual)
                    .compatGlassProminentButtonStyle()
                    .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
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
                            HStack(spacing: LiquidGlassMetrics.Spacing.small) {
                                Image(systemName: "macbook")
                                    .glassLegibleForeground(.secondary)
                                Text(service.name)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, LiquidGlassMetrics.Spacing.xSmall)
                            .padding(.vertical, LiquidGlassMetrics.Spacing.xSmall)
                        }
                        // Whole-row hover and press feedback (BTN-5), inset
                        // from the panel edge so text stays at 16pt.
                        .buttonStyle(.liquidGlassPressable)
                    }
                }
                .padding(.horizontal, LiquidGlassMetrics.Spacing.xSmall)
                .padding(.vertical, LiquidGlassMetrics.Spacing.xxSmall)
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
        VStack(spacing: LiquidGlassMetrics.Spacing.small) {
            switch discovery.browseState {
            case .needsPermission, .failed:
                Image(systemName: "wifi.exclamationmark")
                    .font(.largeTitle)
                    .glassLegibleForeground(.secondary)
                Text("Cockpit can't browse the local network")
                    .font(.callout.weight(.medium))
            default:
                ProgressView().controlSize(.small)
                Text("Looking for computers with Screen Sharing enabled…")
                    .font(.callout)
                    .glassLegibleForeground(.secondary)
                    .multilineTextAlignment(.center)
            }

            Text("The target Mac needs Screen Sharing on (System Settings → General → Sharing), and Cockpit needs Local Network access. You can still connect by typing a host below.")
                .font(.caption)
                .glassLegibleForeground(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button("Open Local Network Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
                    NSWorkspace.shared.open(url)
                }
            }
            .compatGlassButtonStyle()
            .controlSize(.small)
            // macOS 27.2 opens the top of Privacy & Security, not the pane.
            .help("Opens Privacy & Security; then choose Local Network")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(LiquidGlassMetrics.Spacing.xLarge)
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
