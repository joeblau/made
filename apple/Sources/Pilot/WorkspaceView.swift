import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let pilotPane = UTType(exportedAs: "app.blau.pilot.pane")
}

enum WorkspacePaneSurface: String, Codable, Hashable {
    case main
    case `extension`
}

struct WorkspacePaneDragPayload: Codable, Hashable, Transferable {
    let paneID: UUID
    let sourceWorkspaceID: UUID
    let projectID: UUID
    let sourceSurface: WorkspacePaneSurface

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .pilotPane)
    }
}

private enum PaneLayoutMetrics {
    static let dividerLineThickness: CGFloat = 1
    static let dividerHitThickness: CGFloat = 6
    static let collapsedPaneThickness: CGFloat = 28
}

private struct PaneLayoutPlan {
    let sizes: [UUID: CGFloat]
    let expandedSize: CGFloat
}

struct WorkspaceView: View {
    @Bindable var workspace: Workspace
    let isActive: Bool
    let projectID: UUID
    let surface: WorkspacePaneSurface
    let onPaneDrop: (WorkspacePaneDragPayload, Pane) -> Bool
    @State private var hoveredPaneID: UUID?
    @State private var dropTargetPaneID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            panesContent
        }
        .onAppear {
            syncFocusForSelectedPane()
        }
        .onChange(of: isActive) {
            syncFocusForSelectedPane()
        }
        .onChange(of: workspace.selectedPaneID) {
            workspace.syncDefaultRootPathIfNeeded()
            syncFocusForSelectedPane()
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        Group {
            if workspace.axis == .vertical {
                resizableTabBar
                    .padding(.vertical, 6)
            } else {
                let sorted = workspace.sortedPanes
                HStack(spacing: 1) {
                    ForEach(sorted) { pane in
                        tabItem(pane)
                            .frame(width: pane.isCollapsed ? PaneLayoutMetrics.collapsedPaneThickness : nil)
                            .frame(maxWidth: pane.isCollapsed ? nil : .infinity)
                    }

                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
        .background(.bar)
    }

    private func tabItem(_ pane: Pane) -> some View {
        let isSelected = workspace.selectedPaneID == pane.id && !pane.isCollapsed
        let isDropTarget = dropTargetPaneID == pane.id
        let glassTint: Color? = if isDropTarget {
            Color.accentColor.opacity(0.24)
        } else if isSelected {
            Color.accentColor.opacity(0.12)
        } else {
            nil
        }

        return TabItemContent(
            pane: pane,
            isSelected: isSelected,
            isHovering: hoveredPaneID == pane.id,
            isWorkspaceActive: isActive,
            // The extension surface may close its last pane (its empty state
            // invites re-adding); the main window always keeps one.
            canClose: workspace.sortedPanes.count > 1 || surface == .extension,
            onClose: { workspace.requestRemovePane(pane) },
            onHide: { workspace.collapsePane(pane) },
            onUnhide: { workspace.expandPane(pane) }
        )
        .padding(.horizontal, pane.isCollapsed ? 0 : 14)
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .compatGlassEffect(
            tint: glassTint,
            interactive: true,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { isHovering in
            if isHovering {
                hoveredPaneID = pane.id
            } else if hoveredPaneID == pane.id {
                hoveredPaneID = nil
            }
        }
        .onTapGesture {
            if pane.isCollapsed {
                workspace.expandPane(pane)
            } else {
                workspace.selectedPaneID = pane.id
            }
        }
        .draggable(
            WorkspacePaneDragPayload(
                paneID: pane.id,
                sourceWorkspaceID: workspace.id,
                projectID: projectID,
                sourceSurface: surface
            )
        ) {
            HStack(spacing: 6) {
                Image(systemName: pane.kind.systemImageName)
                    .scaledFont(size: 11)
                Text(pane.displayTitle)
                    .scaledFont(size: 12)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .dropDestination(for: WorkspacePaneDragPayload.self) { payloads, _ in
            guard let payload = payloads.first else { return false }
            defer { dropTargetPaneID = nil }
            return onPaneDrop(payload, pane)
        } isTargeted: { isTargeted in
            dropTargetPaneID = isTargeted ? pane.id : nil
        }
        .contextMenu {
            if pane.isCollapsed {
                Button("Unhide") {
                    workspace.expandPane(pane)
                }
            } else {
                Button("Hide") {
                    workspace.collapsePane(pane)
                }
            }

            Divider()

            Button("Close", role: .destructive) {
                workspace.requestRemovePane(pane)
            }
            .disabled(workspace.sortedPanes.count <= 1 && surface != .extension)

            if workspace.sortedPanes.count > 1 {
                Divider()
                Button("Reset Pane Sizes") {
                    workspace.resetPaneSizes()
                }
            }
        }
    }

    // MARK: - Pane Content

    @ViewBuilder
    private var panesContent: some View {
        let isVertical = workspace.axis == .vertical
        let sorted = workspace.sortedPanes

        if sorted.isEmpty {
            emptyPanesView
        } else {
            filledPanesContent(isVertical: isVertical, sorted: sorted)
        }
    }

    /// Reached when the last pane is closed (the extension surface allows
    /// that): an explicit invitation to add panes, mirroring the toolbar
    /// launcher's options.
    private var emptyPanesView: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "No Panes",
                systemImage: "rectangle.dashed",
                description: Text("Add a pane to get started.")
            )
            .frame(maxHeight: 220)

            HStack(spacing: 8) {
                addPaneButton(.terminal)
                addPaneButton(.browser)
                addPaneButton(.device)
                addPaneButton(.simulator)
                addPaneButton(.android)
                addPaneButton(.editor)
                    .disabled(workspace.effectiveRootPath == nil)
                    .help(workspace.effectiveRootPath == nil
                        ? "Set a workspace root path to open the editor"
                        : "Open a file editor with fuzzy file search")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func addPaneButton(_ kind: PaneKind) -> some View {
        Button {
            workspace.addPane(kind: kind, side: .right)
        } label: {
            Label(kind.displayName, systemImage: kind.systemImageName)
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private func filledPanesContent(isVertical: Bool, sorted: [Pane]) -> some View {
        GeometryReader { geometry in
            let totalSize = isVertical ? geometry.size.width : geometry.size.height
            let dividerThickness = PaneLayoutMetrics.dividerHitThickness
            let dividerCount = CGFloat(max(sorted.count - 1, 0))
            let availableSize = max(0, totalSize - dividerCount * dividerThickness)
            let layout = paneLayoutPlan(totalSize: availableSize, sorted: sorted)

            let stack = isVertical ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            stack {
                ForEach(Array(sorted.enumerated()), id: \.element.id) { index, pane in
                    let paneSize = layout.sizes[pane.id] ?? 0

                    ZStack {
                        PaneView(
                            pane: pane,
                            isSelected: workspace.selectedPaneID == pane.id && !pane.isCollapsed,
                            isWorkspaceActive: isActive
                        )
                        .opacity(pane.isCollapsed ? 0 : 1)
                        .allowsHitTesting(!pane.isCollapsed)

                        if pane.isCollapsed {
                            CollapsedPaneSlit(
                                pane: pane,
                                isVertical: isVertical,
                                isWorkspaceActive: isActive,
                                onUnhide: { workspace.expandPane(pane) }
                            )
                        }
                    }
                        .frame(
                            width: isVertical ? max(0, paneSize) : nil,
                            height: isVertical ? nil : max(0, paneSize)
                        )
                        // AppKit-backed panes can retain a document width larger
                        // than their SwiftUI allocation while a divider moves.
                        // Keep every surface inside the pane it was assigned.
                        .clipped()
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                guard !pane.isCollapsed else { return }
                                workspace.selectedPaneID = pane.id
                            }
                        )

                    if index < sorted.count - 1 {
                        let trailingPane = sorted[index + 1]
                        PaneResizeHandle(
                            isVertical: isVertical,
                            totalSize: layout.expandedSize,
                            leadingID: pane.id,
                            trailingID: trailingPane.id,
                            workspace: workspace,
                            isEnabled: workspace.canResizePanes(
                                leadingID: pane.id,
                                trailingID: trailingPane.id
                            )
                        )
                    }
                }
            }
            // Pane geometry must never ride an ambient animation: while an
            // animation transaction is alive (e.g. a new browser pane's start
            // page re-rendering), interpolated slot frames can stick, leaving
            // dead space above AppKit surfaces until the next window resize.
            .transaction { $0.animation = nil }
        }
    }

}

private extension WorkspaceView {
    var resizableTabBar: some View {
        let sorted = workspace.sortedPanes

        return GeometryReader { geometry in
            let dividerCount = CGFloat(max(sorted.count - 1, 0))
            let availableWidth = max(0, geometry.size.width - dividerCount * PaneLayoutMetrics.dividerHitThickness)
            let layout = paneLayoutPlan(totalSize: availableWidth, sorted: sorted)

            HStack(spacing: 0) {
                ForEach(Array(sorted.enumerated()), id: \.element.id) { index, pane in
                    let tabWidth = layout.sizes[pane.id] ?? 0

                    tabItem(pane)
                        .frame(width: max(0, tabWidth))

                    if index < sorted.count - 1 {
                        let trailingPane = sorted[index + 1]
                        PaneResizeHandle(
                            isVertical: true,
                            totalSize: layout.expandedSize,
                            leadingID: pane.id,
                            trailingID: trailingPane.id,
                            workspace: workspace,
                            isEnabled: workspace.canResizePanes(
                                leadingID: pane.id,
                                trailingID: trailingPane.id
                            )
                        )
                    }
                }
            }
        }
        .frame(height: 28)
    }

    func syncFocusForSelectedPane() {
        guard isActive else { return }
        guard workspace.selectedPane?.isCollapsed != true else { return }

        if let pane = workspace.selectedPane, pane.kind == .browser {
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
            return
        }

        guard let pane = workspace.selectedPane ?? workspace.frontmostTerminalPane,
              pane.kind == .terminal else { return }
        workspace.setFrontmostTerminalPaneID(pane.id)
        DispatchQueue.main.async {
            _ = GhosttyMetalView.focus(paneID: pane.id)
        }
    }

    func paneLayoutPlan(totalSize: CGFloat, sorted: [Pane]) -> PaneLayoutPlan {
        guard !sorted.isEmpty else { return PaneLayoutPlan(sizes: [:], expandedSize: 0) }

        let collapsedPanes = sorted.filter(\.isCollapsed)
        let expandedPanes = sorted.filter { !$0.isCollapsed }
        let maxCollapsedThickness = totalSize / CGFloat(max(sorted.count, 1))
        let collapsedThickness = min(PaneLayoutMetrics.collapsedPaneThickness, max(0, maxCollapsedThickness))
        let collapsedTotal = CGFloat(collapsedPanes.count) * collapsedThickness
        let expandedSize = expandedPanes.isEmpty ? 0 : max(0, totalSize - collapsedTotal)
        let fractions = workspace.normalizedExpandedSizeFractions

        var sizes: [UUID: CGFloat] = [:]
        for pane in sorted {
            if pane.isCollapsed {
                sizes[pane.id] = collapsedThickness
            } else {
                let fraction = fractions[pane.id] ?? (1.0 / Double(max(expandedPanes.count, 1)))
                sizes[pane.id] = expandedSize * CGFloat(fraction)
            }
        }

        return PaneLayoutPlan(sizes: sizes, expandedSize: expandedSize)
    }
}

private struct PaneResizeHandle: View {
    let isVertical: Bool
    let totalSize: CGFloat
    let leadingID: UUID
    let trailingID: UUID
    let workspace: Workspace
    let isEnabled: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var isDragging = false
    @State private var isHovering = false
    @State private var lastDragLocation: CGFloat = 0

    var body: some View {
        ZStack {
            Rectangle()
                .fill(separatorColor.opacity(isHovering || isDragging ? 0.18 : 0.08))

            Rectangle()
                .fill(isDragging || isHovering ? Color.accentColor : separatorColor)
                .frame(
                    width: isVertical ? PaneLayoutMetrics.dividerLineThickness : nil,
                    height: isVertical ? nil : PaneLayoutMetrics.dividerLineThickness
                )
        }
        .frame(
            width: isVertical ? PaneLayoutMetrics.dividerHitThickness : nil,
            height: isVertical ? nil : PaneLayoutMetrics.dividerHitThickness
        )
        .contentShape(Rectangle())
        .zIndex(1)
        .onDisappear {
            isHovering = false
            NSCursor.arrow.set()
        }
        .onContinuousHover { phase in
            guard isEnabled else {
                isHovering = false
                NSCursor.arrow.set()
                return
            }

            switch phase {
            case .active:
                isHovering = true
                resizeCursor.set()
            case .ended:
                isHovering = false
                NSCursor.arrow.set()
            }
        }
        .onTapGesture(count: 2) {
            guard isEnabled else { return }
            workspace.resetPaneSizes()
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    guard isEnabled else { return }
                    guard totalSize > 0 else { return }
                    let current = isVertical ? value.location.x : value.location.y
                    if !isDragging {
                        isDragging = true
                        lastDragLocation = current
                        return
                    }
                    let moved = current - lastDragLocation
                    lastDragLocation = current
                    let delta = Double(moved / totalSize)
                    workspace.resizePanes(leadingID: leadingID, trailingID: trailingID, delta: delta)
                }
                .onEnded { _ in
                    guard isEnabled else { return }
                    isDragging = false
                    workspace.persistPaneSizes()
                }
        )
    }

    private var separatorColor: Color {
        Color(
            .sRGB,
            white: colorScheme == .dark ? 0.2 : 0.78,
            opacity: 1
        )
    }

    private var resizeCursor: NSCursor {
        isVertical ? .resizeLeftRight : .resizeUpDown
    }
}

private struct CollapsedPaneSlit: View {
    let pane: Pane
    let isVertical: Bool
    let isWorkspaceActive: Bool
    let onUnhide: () -> Void

    var body: some View {
        ZStack {
            Button(action: onUnhide) {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Unhide \(pane.kind.displayName)")

            Group {
                if isVertical {
                    VStack(spacing: 0) {
                        unhideButton
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 6)
                } else {
                    HStack(spacing: 0) {
                        unhideButton
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.85))
    }

    @ViewBuilder
    private var unhideButton: some View {
        if pane.kind == .terminal {
            HiddenTerminalIndicator(
                pane: pane,
                compact: false,
                isWorkspaceActive: isWorkspaceActive
            )
        } else {
            Button(action: onUnhide) {
                Image(systemName: "eye")
                    .scaledFont(size: 10, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help("Unhide \(pane.kind.displayName)")
        }
    }
}

private struct HiddenTerminalIndicator: View {
    let pane: Pane
    let compact: Bool
    let isWorkspaceActive: Bool
    @AppStorage private var fastCommand: String
    @State private var activity: TerminalProcessActivity = .idle
    @State private var isPulsing = false
    @State private var activeAction: FastCommandAction?

    private enum FastCommandAction {
        case play
        case stop
    }

    init(pane: Pane, compact: Bool, isWorkspaceActive: Bool) {
        self.pane = pane
        self.compact = compact
        self.isWorkspaceActive = isWorkspaceActive
        _fastCommand = AppStorage(
            wrappedValue: "",
            TerminalFastCommandStore.preferenceKey(for: pane.id)
        )
    }

    var body: some View {
        VStack(spacing: compact ? 2 : 5) {
            if activity == .running {
                runningIndicator
                    .help("This hidden terminal is running")
                    .accessibilityLabel("Hidden terminal is running")
            }

            if executableCommand != nil {
                fastCommandButton(
                    action: .play,
                    systemName: "play.fill",
                    help: "Stop the active process and run the Fast Command"
                )
                fastCommandButton(
                    action: .stop,
                    systemName: "stop.fill",
                    help: "Stop the active terminal process"
                )
            }
        }
        .animation(.easeInOut(duration: 0.2), value: activity)
        .animation(.easeInOut(duration: 0.2), value: executableCommand != nil)
        .task(id: isWorkspaceActive) {
            guard isWorkspaceActive else { return }
            let sessionName = pane.persistentSessionName
            while !Task.isCancelled {
                activity = await PersistentTerminalSession.foregroundActivity(sessionName: sessionName)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func fastCommandButton(
        action: FastCommandAction,
        systemName: String,
        help: String
    ) -> some View {
        Button {
            perform(action)
        } label: {
            Group {
                if activeAction == action {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: systemName)
                        .scaledFont(size: compact ? 7 : 8, weight: .semibold)
                }
            }
            .foregroundStyle(action == .play ? Color.primary : Color.secondary)
            .frame(width: compact ? 18 : 20, height: compact ? 18 : 20)
            .background(Color.primary.opacity(0.06), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(activeAction != nil)
        .help(help)
        .accessibilityLabel(help)
    }

    private var runningIndicator: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(compact ? 0.12 : 0.16))
                .frame(width: compact ? 18 : 20, height: compact ? 18 : 20)

            Circle()
                .fill(Color.accentColor.opacity(isPulsing ? 0.95 : 0.45))
                .frame(width: compact ? 5 : 6, height: compact ? 5 : 6)
                .scaleEffect(isPulsing ? 1.0 : 0.72)
        }
        .frame(width: compact ? 18 : 20, height: compact ? 18 : 20)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }

    private var executableCommand: String? {
        TerminalFastCommandStore.executableCommand(from: fastCommand)
    }

    private func perform(_ action: FastCommandAction) {
        guard activeAction == nil else { return }
        if action == .play, executableCommand == nil { return }
        activeAction = action
        Task {
            switch action {
            case .play:
                if let executableCommand {
                    _ = await PersistentTerminalSession.runFastCommand(
                        executableCommand,
                        sessionName: pane.persistentSessionName
                    )
                }
            case .stop:
                _ = await PersistentTerminalSession.stopForegroundCommand(
                    sessionName: pane.persistentSessionName
                )
            }
            activity = await PersistentTerminalSession.foregroundActivity(
                sessionName: pane.persistentSessionName
            )
            activeAction = nil
        }
    }
}

struct PaneView: View {
    let pane: Pane
    let isSelected: Bool
    let isWorkspaceActive: Bool

    var body: some View {
        switch pane.kind {
        case .terminal:
            TerminalViewRepresentable(
                pane: pane,
                isActive: isWorkspaceActive,
                isCollapsed: pane.isCollapsed
            )
        case .browser:
            if let state = pane.browserState {
                BrowserPaneView(
                    state: state,
                    rootPath: pane.workspace?.effectiveRootPath,
                    isActive: isWorkspaceActive,
                    isSelected: isSelected,
                    onSelect: { pane.workspace?.selectedPaneID = pane.id },
                    targetTerminalPaneID: { pane.workspace?.frontmostTerminalPane?.id }
                )
            }
        case .device:
            DevicePaneView(
                paneID: pane.id,
                isActive: isWorkspaceActive,
                isSelected: isSelected,
                isCollapsed: pane.isCollapsed
            )
        case .simulator:
            SimulatorPaneView(paneID: pane.id, isActive: isWorkspaceActive, isSelected: isSelected)
        case .android:
            AndroidPaneView(
                paneID: pane.id,
                isActive: isWorkspaceActive,
                isSelected: isSelected,
                isCollapsed: pane.isCollapsed
            )
        case .editor:
            if let editorState = pane.editorState {
                EditorPaneView(state: editorState,
                               rootPath: pane.workspace?.effectiveRootPath,
                               isActive: isWorkspaceActive,
                               isSelected: isSelected,
                               onSelect: { pane.workspace?.selectedPaneID = pane.id })
            }
        }
    }
}

// MARK: - Terminal (Ghostty)

struct TerminalViewRepresentable: View {
    let pane: Pane
    let isActive: Bool
    let isCollapsed: Bool

    var body: some View {
        GhosttyTerminalView(pane: pane, isActive: isActive, isCollapsed: isCollapsed)
    }
}
