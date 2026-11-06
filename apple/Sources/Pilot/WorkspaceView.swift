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
    /// Pane tab height; tabs are capsules, so this is also their diameter.
    static let tabHeight: CGFloat = 28
}

private struct PaneLayoutPlan {
    let sizes: [UUID: CGFloat]
    let expandedSize: CGFloat
}

/// Pane size floors. The relative 0.1 floor alone let a divider drag (or a
/// narrower window) squeeze a pane to 37–65pt, where pane headers clip and
/// picker titles break a letter per line. An expanded pane therefore keeps
/// at least `minimumPaneLength` points whenever the stack fits every expanded
/// pane at that length; a stack too small for that keeps the relative floor.
enum PaneSizing {
    /// Enough for a pane header: glyph, a short title, and two small buttons.
    static let minimumPaneLength: Double = 160
    static let minimumRelativeFraction = 0.1

    /// The smallest fraction a divider drag may leave an expanded pane.
    static func minimumFraction(expandedSize: Double?, expandedCount: Int) -> Double {
        guard let expandedSize, expandedSize > 0, expandedCount > 0,
              minimumPaneLength * Double(expandedCount) <= expandedSize else {
            return minimumRelativeFraction
        }
        return max(minimumRelativeFraction, minimumPaneLength / expandedSize)
    }

    /// New fractions for the pair either side of a divider. The pair's total is
    /// preserved, and neither side is pushed below `minimumFraction`; a side
    /// already below it (a window that just got narrower) may grow but not
    /// shrink, so the result never jumps, goes negative, or overflows the pair.
    static func resizedPair(
        leading: Double,
        trailing: Double,
        delta: Double,
        minimumFraction: Double
    ) -> (leading: Double, trailing: Double) {
        let leading = max(0, leading)
        let trailing = max(0, trailing)
        let total = leading + trailing
        let lower = min(minimumFraction, leading)
        let upper = total - min(minimumFraction, trailing)
        let newLeading = min(max(leading + delta, lower), upper)
        return (newLeading, total - newLeading)
    }

    /// Lifts every expanded pane below `minimumPaneLength` up to it, taking the
    /// space proportionally from the larger panes. Input fractions sum to 1;
    /// so does the output. When the panes can't all fit at the floor, the
    /// fractions come back unchanged (the previous, purely relative layout).
    static func flooredFractions(_ fractions: [UUID: Double], expandedSize: Double) -> [UUID: Double] {
        guard !fractions.isEmpty, expandedSize > 0,
              minimumPaneLength * Double(fractions.count) <= expandedSize else { return fractions }
        let floor = minimumPaneLength / expandedSize
        var pinned = Set<UUID>()
        while true {
            let free = fractions.filter { !pinned.contains($0.key) }
            let remaining = max(0, 1 - Double(pinned.count) * floor)
            let freeTotal = free.values.reduce(0, +)
            let scaled = free.mapValues { value in
                freeTotal > 0 ? value / freeTotal * remaining : remaining / Double(free.count)
            }
            let undersized = scaled.filter { $0.value < floor }.map(\.key)
            // `count * floor <= 1` means at least one pane always stays free.
            guard !undersized.isEmpty, undersized.count < free.count else {
                return scaled.merging(pinned.map { ($0, floor) }) { scaledValue, _ in scaledValue }
            }
            pinned.formUnion(undersized)
        }
    }
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
                .padding(.horizontal, LiquidGlassMetrics.Spacing.xSmall)
                .padding(.bottom, LiquidGlassMetrics.Spacing.xSmall)
        }
        .background(.bar)
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
                    .padding(.horizontal, LiquidGlassMetrics.Spacing.xSmall)
                    .padding(.vertical, LiquidGlassMetrics.Spacing.xxSmall)
            } else {
                let sorted = workspace.sortedPanes
                // Tabs are neighboring glass capsules rendered in one
                // container (shared sampling, no glass on glass); spacing 0
                // keeps each tab a distinct capsule.
                CompatGlassContainer(spacing: 0) {
                    HStack(spacing: LiquidGlassMetrics.Spacing.xxSmall) {
                        ForEach(sorted) { pane in
                            tabItem(pane, paneCount: sorted.count)
                                .frame(width: pane.isCollapsed ? PaneLayoutMetrics.collapsedPaneThickness : nil)
                                .frame(maxWidth: pane.isCollapsed ? nil : .infinity)
                        }

                        Spacer()
                    }
                }
                .padding(.horizontal, LiquidGlassMetrics.Spacing.xSmall)
                .padding(.vertical, LiquidGlassMetrics.Spacing.xxSmall)
            }
        }
        .background(.bar)
    }

    private func tabItem(_ pane: Pane, paneCount: Int) -> some View {
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
            canClose: paneCount > 1 || surface == .extension,
            onSelect: { workspace.selectedPaneID = pane.id },
            onClose: { workspace.requestRemovePane(pane) },
            onHide: { workspace.collapsePane(pane) },
            onUnhide: { workspace.expandPane(pane) }
        )
        // Capsule tabs (no squared-off control corners); the 8pt inset keeps
        // the round close/hide buttons close to concentric with the capsule
        // ends (LAY-4).
        .padding(.horizontal, pane.isCollapsed ? 0 : LiquidGlassMetrics.Spacing.xSmall)
        .frame(maxWidth: .infinity)
        .frame(height: PaneLayoutMetrics.tabHeight)
        .compatGlassEffect(
            tint: glassTint,
            interactive: true,
            in: Capsule()
        )
        .overlay {
            if isDropTarget {
                Capsule()
                    .fill(Color.accentColor.opacity(0.18))
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Capsule())
        .animation(LiquidGlassMetrics.stateChange, value: isSelected)
        .animation(LiquidGlassMetrics.stateChange, value: isDropTarget)
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
            // Drag previews are snapshotted without a backdrop, so they keep
            // a material fill rather than glass — in the same capsule shape.
            HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                Image(systemName: pane.kind.systemImageName)
                    .scaledFont(size: 11)
                Text(pane.displayTitle)
                    .scaledFont(size: 12)
            }
            .padding(.horizontal, LiquidGlassMetrics.Spacing.medium)
            .padding(.vertical, LiquidGlassMetrics.Spacing.xSmall)
            .background(.regularMaterial, in: Capsule())
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
            .disabled(paneCount <= 1 && surface != .extension)

            if paneCount > 1 {
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

    /// An explicit invitation to add panes, mirroring the toolbar launcher's
    /// options. The pane model keeps every workspace's last pane, so this is
    /// a defensive state for a workspace restored with no panes.
    private var emptyPanesView: some View {
        VStack(spacing: LiquidGlassMetrics.Spacing.medium) {
            ContentUnavailableView(
                "No Panes",
                systemImage: "rectangle.dashed",
                description: Text("Add a pane to get started.")
            )
            .legibleSecondaryHierarchy()
            .frame(maxHeight: 220)

            // One row when the pane is wide enough; two rows of three in a
            // narrow (e.g. Extendo) window so the capsules never clip (LAY-6).
            CompatGlassContainer(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                        addPaneButtons(Self.emptyPaneKinds)
                    }
                    VStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                        HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                            addPaneButtons(Array(Self.emptyPaneKinds.prefix(3)))
                        }
                        HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                            addPaneButtons(Array(Self.emptyPaneKinds.dropFirst(3)))
                        }
                    }
                }
            }
        }
        .padding(LiquidGlassMetrics.Spacing.xLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static let emptyPaneKinds: [PaneKind] = [.terminal, .browser, .device, .simulator, .android, .editor, .agentChat]

    private func addPaneButtons(_ kinds: [PaneKind]) -> some View {
        ForEach(kinds, id: \.self) { kind in
            if kind == .editor {
                addPaneButton(kind)
                    .disabled(workspace.effectiveRootPath == nil)
                    .help(workspace.effectiveRootPath == nil
                        ? "Set a workspace root path to open the editor"
                        : "Open a file editor with fuzzy file search")
            } else if kind == .agentChat {
                addPaneButton(kind)
                    .disabled(workspace.effectiveRootPath == nil)
                    .help(workspace.effectiveRootPath == nil
                        ? "Set a workspace root path to chat with a coding agent"
                        : "Chat with Claude, Codex, Kimi, or Grok in this workspace")
            } else {
                addPaneButton(kind)
            }
        }
    }

    private func addPaneButton(_ kind: PaneKind) -> some View {
        Button {
            workspace.addPane(kind: kind, side: .right)
        } label: {
            Label(kind.displayName, systemImage: kind.systemImageName)
        }
        // Peer choices with no single primary (BTN-1), so all secondary glass.
        .compatGlassButtonStyle()
        .buttonBorderShape(.capsule)
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

            // Spacing 0: tabs stay distinct across the resize handles.
            CompatGlassContainer(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(Array(sorted.enumerated()), id: \.element.id) { index, pane in
                        let tabWidth = layout.sizes[pane.id] ?? 0

                        tabItem(pane, paneCount: sorted.count)
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
        }
        .frame(height: PaneLayoutMetrics.tabHeight)
    }

    func syncFocusForSelectedPane() {
        guard isActive else { return }
        guard workspace.selectedPane?.isCollapsed != true else { return }

        if let pane = workspace.selectedPane, pane.kind == .browser {
            let state = pane.browserState
            DispatchQueue.main.async {
                // Take keys away from a terminal or another pane's page, but
                // keep focus a click already gave to this pane's page (see
                // `BrowserPaneFocus`).
                guard let window = NSApp.keyWindow,
                      !BrowserPaneFocus.isInWebContent(window.firstResponder, ownedBy: state) else { return }
                window.makeFirstResponder(nil)
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
        let fractions = PaneSizing.flooredFractions(
            workspace.normalizedExpandedSizeFractions,
            expandedSize: Double(expandedSize)
        )

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
                    workspace.resizePanes(
                        leadingID: leadingID,
                        trailingID: trailingID,
                        delta: delta,
                        expandedSize: Double(totalSize)
                    )
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
            // The whole slit is the tap target: unglazed, but with a hover
            // wash and press feedback so it reads as clickable (BTN-5). The
            // slit is a pane edge, not a control, so the wash stays square.
            Button(action: onUnhide) {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.liquidGlassPressable(cornerRadius: 0))
            .accessibilityLabel("Unhide \(pane.kind.displayName)")

            Group {
                if isVertical {
                    VStack(spacing: 0) {
                        unhideButton
                        Spacer(minLength: 0)
                    }
                    .padding(.top, LiquidGlassMetrics.Spacing.xxSmall)
                } else {
                    HStack(spacing: 0) {
                        unhideButton
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, LiquidGlassMetrics.Spacing.xxSmall)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: LiquidGlassMetrics.Radius.control, style: .continuous))
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
            // Icon-only control floating over the collapsed slit: a circular
            // glass button sized to fit the 28pt slit.
            Button(action: onUnhide) {
                Label {
                    Text("Unhide \(pane.kind.displayName)")
                } icon: {
                    Image(systemName: "eye")
                        .scaledFont(size: 10, weight: .semibold)
                        .frame(width: 12, height: 12)
                }
            }
            .compatGlassIconButton(controlSize: .mini)
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
        CompatGlassContainer(spacing: 0) {
            indicatorStack
        }
        .animation(LiquidGlassMetrics.spring, value: activity)
        .animation(LiquidGlassMetrics.spring, value: executableCommand != nil)
        .task(id: isWorkspaceActive) {
            guard isWorkspaceActive else { return }
            let session = pane.terminalSession
            while !Task.isCancelled {
                activity = await session.foregroundActivity(unavailableActivity: .idle)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var indicatorStack: some View {
        VStack(spacing: LiquidGlassMetrics.Spacing.xxSmall) {
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
    }

    private func fastCommandButton(
        action: FastCommandAction,
        systemName: String,
        help: String
    ) -> some View {
        Button {
            perform(action)
        } label: {
            // A fixed glyph frame keeps the circle the same size while the
            // spinner swaps in.
            Group {
                if activeAction == action {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: systemName)
                        .scaledFont(size: compact ? 8 : 10, weight: .semibold)
                }
            }
            .foregroundStyle(action == .play ? Color.primary : Color.secondary)
            .frame(width: 14, height: 14)
        }
        // Icon-only circular glass, one control size for the whole column.
        .compatGlassIconButton(controlSize: .small)
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
                    _ = await pane.terminalSession.runFastCommand(executableCommand)
                }
            case .stop:
                _ = await pane.terminalSession.interrupt()
            }
            activity = await pane.terminalSession.foregroundActivity(unavailableActivity: .idle)
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
            if pane.terminalDestination.kind == .drone {
                DroneTerminalView(pane: pane)
            } else {
                TerminalViewRepresentable(
                    pane: pane,
                    isActive: isWorkspaceActive,
                    isCollapsed: pane.isCollapsed
                )
            }
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
                .clipShape(RoundedRectangle(cornerRadius: LiquidGlassMetrics.Radius.control, style: .continuous))
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
        case .agentChat:
            AgentChatPaneView(
                paneID: pane.id,
                workingDirectory: pane.workspace?.effectiveRootPath,
                isActive: isWorkspaceActive,
                isSelected: isSelected,
                onSelect: { pane.workspace?.selectedPaneID = pane.id }
            )
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
            .clipShape(RoundedRectangle(cornerRadius: LiquidGlassMetrics.Radius.control, style: .continuous))
    }
}
