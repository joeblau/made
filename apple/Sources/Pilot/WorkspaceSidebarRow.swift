import SwiftUI

struct WorkspaceSidebarHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .scaledFont(size: 11, weight: .semibold)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// One workspace row in the sidebar: an in-place rename field, the current
/// git branch as secondary text, the badge count, and the row's context menu.
///
/// Every row puts the branch on its own line under the name. Trailing it
/// inline instead loses it entirely on a narrow sidebar: the name field is
/// greedy, so the branch compresses to nothing before the field gives up any
/// width.
struct WorkspaceSidebarRow: View {
    let workspace: Workspace
    let branch: String?
    let store: WorkspaceStore
    let onUpdateRootPath: () -> Void

    /// Edit mode is deliberately decoupled from focus. A focused view that
    /// resigns first responder writes `nil` back into its `@FocusState`, so
    /// one state driving both "show the field" and "focus the field" tears
    /// the field down on any spurious resign — the context menu closing,
    /// a row rebuild — before the user can type or press Return.
    @State private var isRenaming = false
    @State private var draftName = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        // Hidden while renaming so the branch never competes with the field
        // the user is typing in.
        let branch = isRenaming ? nil : branch

        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                if isRenaming {
                    TextField("Name", text: $draftName)
                        .focused($renameFocused)
                        .onSubmit(commitRename)
                        .onExitCommand(perform: cancelRename)
                        .onChange(of: renameFocused) { _, focused in
                            // Clicking away commits whatever was typed.
                            if !focused, isRenaming { commitRename() }
                        }
                        .onAppear {
                            draftName = workspace.name
                            // The field exists only now; focus it once the
                            // context menu that opened it has closed.
                            DispatchQueue.main.async { renameFocused = true }
                        }
                        .layoutPriority(1)
                } else {
                    Text(workspace.name)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                }

                // The gauge outranks the name field for space. The field is
                // greedy, so without a higher priority and a fixed size the
                // ring gets truncated away.
                WorkspaceLLMGauge(workspace: workspace, store: store)
                    .fixedSize()
                    .layoutPriority(2)
            }

            if let branch {
                branchLabel(branch)
            }
        }
        .tag(SidebarSelection.workspace(workspace.id))
        .contentShape(Rectangle())
        .draggable(WorkspaceSidebarDragPayload(workspaceID: workspace.id)) {
            Text(workspace.name)
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .contextMenu {
            Button {
                // Defer past the menu's own tracking loop; flipping view
                // state from inside a context-menu action is otherwise
                // swallowed while the menu is still closing.
                DispatchQueue.main.async { isRenaming = true }
            } label: {
                Label("Rename Workspace", systemImage: "pencil")
            }

            Button(action: onUpdateRootPath) {
                Label("Update Root Path", systemImage: "arrow.triangle.2.circlepath")
            }

            Divider()

            Button {
                store.togglePin(workspace)
            } label: {
                Label(
                    workspace.isPinned ? "Unpin" : "Pin",
                    systemImage: workspace.isPinned ? "pin.slash" : "pin"
                )
            }
            Menu("Move to Group") {
                Button("Ungrouped") { store.moveWorkspace(workspace, toGroup: nil) }
                ForEach(store.workspaceGroups.groups) { group in
                    Button(group.name) { store.moveWorkspace(workspace, toGroup: group.id) }
                }
            }
            Divider()
            Button("Delete", role: .destructive) {
                store.requestDeleteWorkspace(workspace)
            }
        }
    }

    /// Writes the draft back to the model, keeping the current name when the
    /// draft is empty or all whitespace.
    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            workspace.name = trimmed
        }
        isRenaming = false
    }

    private func cancelRename() {
        isRenaming = false
    }

    private func branchLabel(_ branch: String) -> some View {
        Text(branch)
            .scaledFont(size: 10)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help("On branch \(branch)")
            .accessibilityLabel("On branch \(branch)")
    }
}

/// Ring gauge showing `agents working / agents started` for a workspace. A
/// terminal with an idle agent TUI contributes only to the denominator, so
/// three agents all waiting for input reads `0/3`. Hidden when no agent is
/// currently started, even if the workspace has ordinary terminal panes.
///
/// Polls the process tree every couple of seconds — the same walk the pane
/// header's agent capsule uses, resolving each pane's shell pid from tmux.
///
/// Clicking the ring while at least one agent is running jumps straight to
/// the working pane: it activates the workspace (leaving Notes or any other
/// full-detail mode), expands the pane if collapsed, and selects it.
private struct WorkspaceLLMGauge: View {
    let workspace: Workspace
    let store: WorkspaceStore
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var running = 0
    @State private var started = 0
    @State private var runningPaneIDs: Set<UUID> = []

    /// Row budget for the gauge. The ring is drawn at this size instead of
    /// scaling the much larger `.accessoryCircular` control into the row.
    private static let diameter: CGFloat = 26

    var body: some View {
        let isVisible = started > 0

        // Keep the gauge mounted even before the first poll. Besides giving
        // `.task` a permanent host, this gives SwiftUI a zero-value ring to
        // interpolate from when the first agent status arrives.
        ZStack {
            // Draw the ring ourselves instead of using `.accessoryCircular`.
            // That native style renders a detached value marker which looks
            // like a stray dot at zero. The custom arc also exposes its
            // fraction as animatable data, so progress cannot snap.
            AnimatedWorkspaceGauge(
                fraction: gaugeFraction,
                running: running,
                started: started,
                tint: gaugeTint
            )
            .scaleEffect(isVisible ? 1 : 0.75)
            .opacity(isVisible ? 1 : 0)
            .frame(width: Self.diameter, height: Self.diameter)
            .help(gaugeDescription)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(gaugeDescription)
            .accessibilityHidden(!isVisible)
            // Tappable only while an agent is running; an idle ring has
            // no pane to jump to.
            .contentShape(Rectangle())
            .onTapGesture(perform: selectRunningPane)
            .allowsHitTesting(running > 0)
        }
        // Zero-width while empty so a workspace with no started agent does not
        // reserve a hole where the ring would be.
        .frame(
            width: isVisible ? Self.diameter : 0,
            height: isVisible ? Self.diameter : 0
        )
        .clipped()
        .task {
            while !Task.isCancelled {
                let terminals = workspace.panes.filter { $0.kind == .terminal }
                var nextStarted = 0
                var nextRunningPaneIDs: Set<UUID> = []
                for pane in terminals {
                    guard let status = await pane.liveShellAgentStatus() else { continue }
                    nextStarted += 1
                    if status.activity == .running {
                        nextRunningPaneIDs.insert(pane.id)
                    }
                }
                runningPaneIDs = nextRunningPaneIDs
                let nextRunning = nextRunningPaneIDs.count
                if started != nextStarted || running != nextRunning {
                    withAnimation(gaugeAnimation) {
                        started = nextStarted
                        running = nextRunning
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var gaugeFraction: Double {
        guard started > 0 else { return 0 }
        return min(1, max(0, Double(running) / Double(started)))
    }

    private var gaugeAnimation: Animation? {
        accessibilityReduceMotion ? nil : .easeInOut(duration: 0.4)
    }

    /// Jump to the first pane reported active by the latest poll.
    private func selectRunningPane() {
        let terminals = workspace.panes.filter { $0.kind == .terminal }
        guard let pane = terminals.first(where: { runningPaneIDs.contains($0.id) }) else { return }
        store.selectWorkspace(workspace.id)
        if pane.isCollapsed {
            workspace.expandPane(pane)
        }
        workspace.selectedPaneID = pane.id
    }

    /// Idle drops to the quaternary label color so quiet workspaces recede
    /// into the sidebar instead of every ring sitting at accent strength. Use
    /// a concrete dynamic NSColor so selected-row appearances resolve it too.
    private var gaugeTint: Color {
        if running == 0 { return Color(nsColor: .quaternaryLabelColor) }
        if running == started { return .green }
        return .accentColor
    }

    /// Spell out both sides for the tooltip and VoiceOver.
    private var gaugeDescription: String {
        let agents = started == 1 ? "agent" : "agents"
        if running == 0 {
            return "0 of \(started) started \(agents) working"
        }
        return "\(running) of \(started) started \(agents) working. Click to jump to a pane."
    }
}

/// Compact gauge face with a neutral track and an explicitly animatable
/// progress arc. A zero fraction produces no foreground path, avoiding the
/// detached round-cap dot shown by the native accessory gauge.
private struct AnimatedWorkspaceGauge: View {
    let fraction: Double
    let running: Int
    let started: Int
    let tint: Color

    private static let lineWidth: CGFloat = 3
    /// Label size for a 26pt ring: leaves the stroke visible around `0/1`.
    private static let labelSize: CGFloat = 8

    var body: some View {
        ZStack {
            WorkspaceGaugeArc(fraction: 1)
                .strokeBorder(
                    Color(nsColor: .quaternaryLabelColor),
                    style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round)
                )

            WorkspaceGaugeArc(fraction: fraction)
                .strokeBorder(
                    tint,
                    style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round)
                )

            // Fixed size rather than `scaledFont`: the ring diameter does not
            // follow UI zoom, so a zoom-scaled label would outgrow its face.
            // Two-digit counts shrink instead of colliding with the stroke.
            Text("\(running)/\(started)")
                .font(.system(size: Self.labelSize, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(Self.lineWidth + 1)
                .contentTransition(.numericText())
        }
    }
}

/// A 270-degree ring with its opening at the bottom. The progress value is the
/// shape's animatable data, so SwiftUI interpolates the path on every frame.
/// Returning an empty path at zero is intentional: stroking a zero-length path
/// with round caps produces the detached dot this gauge is designed to avoid.
struct WorkspaceGaugeArc: InsettableShape {
    var fraction: Double
    private var insetAmount: CGFloat = 0

    init(fraction: Double) {
        self.fraction = fraction
    }

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let progress = min(1, max(0, fraction))
        guard progress > 0 else { return Path() }

        let drawingRect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard drawingRect.width > 0, drawingRect.height > 0 else { return Path() }

        let center = CGPoint(x: drawingRect.midX, y: drawingRect.midY)
        let radius = min(drawingRect.width, drawingRect.height) / 2
        let start = Angle.degrees(135)
        let end = Angle.degrees(135 + (270 * progress))
        var path = Path()
        path.addArc(
            center: center,
            radius: radius,
            startAngle: start,
            endAngle: end,
            clockwise: false
        )
        return path
    }

    func inset(by amount: CGFloat) -> WorkspaceGaugeArc {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

/// A group header is one list row; its members are sibling rows with indentation.
/// Keeping them out of a nested DisclosureGroup lets every row export its drag.
struct WorkspaceGroupSidebarRow: View {
    let group: WorkspaceGroup
    let store: WorkspaceStore
    let onRename: () -> Void
    @State private var isDropTarget = false

    var body: some View {
        Button {
            store.workspaceGroups.setExpanded(group.id, !group.isExpanded)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: group.isExpanded ? "chevron.down" : "chevron.right")
                    .scaledFont(size: 9, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                WorkspaceSidebarHeading(title: group.name)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .background(isDropTarget ? Color.accentColor.opacity(0.15) : .clear)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(group.name)
        .accessibilityValue(group.isExpanded ? "Expanded" : "Collapsed")
        .onDrop(of: [.pilotWorkspace], isTargeted: $isDropTarget) { providers in
            WorkspaceSidebarDragPayload.load(providers) { item in
                store.acceptWorkspaceDrop([item], toGroup: group.id)
            }
        }
        .draggable(WorkspaceSidebarDragPayload(groupID: group.id))
        .contextMenu {
            Button("New Workspace in Group") {
                store.addWorkspace()
                if let workspace = store.selectedWorkspace {
                    store.moveWorkspace(workspace, toGroup: group.id)
                }
            }
            Button("Rename Group", action: onRename)
            Button("Ungroup Workspaces") {
                store.workspaceGroups.remove(group.id, workspaceIDs: store.unpinnedWorkspaceIDs)
            }
        }
    }
}
