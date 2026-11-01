import SwiftUI

struct RunnersView: View {
    @Bindable var store: RunnersStore
    @State private var showsAddScope = false
    @State private var editingRunner: GitHubRunner?
    @AppStorage("runners.layout") private var layout: RunnerLayout = .fleet

    var body: some View {
        VStack(spacing: 0) {
            // With no sources the empty state's "Add Runner Source" is the one
            // action (BTN-1); a lone "+" chip strip above it would repeat it.
            if !store.scopes.isEmpty {
                tabBar
            }
            if store.selectedScope != nil {
                summaryBar
                if let error = store.snapshot.error { errorBanner(error) }
                content
            } else {
                ContentUnavailableView {
                    Label("Your Runner Fleet", systemImage: "server.rack")
                } description: {
                    Text("Add an enterprise, organization, or repository to see its self-hosted runners.")
                } actions: {
                    Button("Add Runner Source", systemImage: "plus") { showsAddScope = true }
                        .compatGlassProminentButtonStyle()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showsAddScope) {
            AddRunnerScopeSheet { scope in
                store.add(scope)
                Task { await store.refresh(scope) }
            }
        }
        .sheet(item: $editingRunner) { runner in
            if let scope = store.selectedScope {
                RunnerDetailsSheet(runner: runner, presentation: store.presentation(for: runner)) { presentation in
                    store.savePresentation(presentation, runner: runner, scope: scope)
                }
            }
        }
        .task { await store.refreshSelected() }
        .onChange(of: store.selectedScopeID) {
            Task { await store.refreshSelected() }
        }
    }

    /// Scope tabs are glass chips floating above the fleet; the selected tab
    /// carries the only accent tint, as a state signal (COL-4). They stay
    /// chips rather than a segmented control because each carries its own
    /// context menu and the strip scrolls when there are many.
    private var tabBar: some View {
        HStack(spacing: LiquidGlassMetrics.Spacing.small) {
            GlassChipScroller {
                HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                    ForEach(store.scopes) { scope in
                        scopeTab(scope)
                    }
                }
                .padding(.vertical, LiquidGlassMetrics.Spacing.xxSmall)
                .animation(LiquidGlassMetrics.spring, value: store.selectedScopeID)
            }
            Button { showsAddScope = true } label: {
                Label("Add a runner source", systemImage: "plus")
            }
            .compatGlassIconButton()
            .help("Add an enterprise, organization, or repository")
        }
        .padding(.horizontal, LiquidGlassMetrics.Spacing.medium)
        .padding(.vertical, LiquidGlassMetrics.Spacing.xSmall)
    }

    private func scopeTab(_ scope: RunnerScope) -> some View {
        let isSelected = store.selectedScopeID == scope.id
        return Button {
            store.selectedScopeID = scope.id
            store.searchText = ""
        } label: {
            Label(scope.name, systemImage: scope.kind.symbol)
                .font(.subheadline.weight(.medium))
        }
        .buttonStyle(.liquidGlassChip(isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            if let url = scope.settingsURL { Link("Open Runner Settings on GitHub", destination: url) }
            Button("Remove Tab", role: .destructive) { store.remove(scope) }
        }
    }

    private var summaryBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                summaryCounts.fixedSize()
                searchControls
            }
            VStack(alignment: .leading, spacing: 12) {
                summaryCounts
                searchControls
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var summaryCounts: some View {
        HStack(spacing: 16) {
            Text("\(store.snapshot.runners.count) runners")
                .font(.headline)
            ForEach(GitHubRunner.State.allCases, id: \.rawValue) { state in
                let count = store.snapshot.runners.filter { $0.state == state }.count
                HStack(spacing: LiquidGlassMetrics.Spacing.xxSmall) {
                    Circle().fill(state.color).frame(width: 8, height: 8)
                    Text("\(count) \(state.rawValue.lowercased())")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var searchControls: some View {
        HStack(spacing: LiquidGlassMetrics.Spacing.medium) {
            Spacer(minLength: 0)
            TextField("Filter runners", text: $store.searchText)
                .liquidGlassField(systemImage: "magnifyingglass")
                .font(.subheadline)
                .frame(maxWidth: 200)

            Picker("Layout", selection: $layout) {
                ForEach(RunnerLayout.allCases, id: \.self) { layout in
                    Label(layout.title, systemImage: layout.symbol).labelStyle(.iconOnly).tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Switch between the 3D fleet, compact tiles, and detailed cards")

            // The spinner runs inside the refresh control, so the filter
            // field and layout picker never shift while a refresh is running.
            Button { Task { await store.refreshSelected() } } label: {
                Label {
                    Text("Refresh runners")
                } icon: {
                    InspectorRefreshGlyph(isRefreshing: store.isRefreshing)
                }
            }
            .compatGlassIconButton()
            .disabled(store.isRefreshing)
            .help("Refresh runners")
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: LiquidGlassMetrics.Spacing.small) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xxSmall) {
                Text(message)
                if store.snapshot.updatedAt != nil { Text("Showing the last successful refresh.").foregroundStyle(.secondary) }
            }
            Spacer()
            Button("Retry") { Task { await store.refreshSelected() } }
                .compatGlassButtonStyle()
                .disabled(store.isRefreshing)
        }
        .font(.subheadline)
        .padding(LiquidGlassMetrics.Spacing.small)
        // Content, not glass: a quiet warning wash. Its radius is the Retry
        // capsule's (~12pt) plus the 12pt inset, so the corner nesting stays
        // concentric (LAY-4).
        .background(
            Color.orange.opacity(0.1),
            in: RoundedRectangle(
                cornerRadius: LiquidGlassMetrics.Radius.field + LiquidGlassMetrics.Spacing.small,
                style: .continuous
            )
        )
        .padding(.horizontal, LiquidGlassMetrics.Spacing.large)
        .padding(.bottom, LiquidGlassMetrics.Spacing.small)
    }

    @ViewBuilder
    private var content: some View {
        if store.snapshot.updatedAt == nil && store.isRefreshing {
            ProgressView("Loading runners…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.snapshot.runners.isEmpty {
            ContentUnavailableView(
                store.snapshot.error == nil ? "No Runners" : "Runners Unavailable",
                systemImage: "server.rack",
                description: Text(store.snapshot.error == nil
                    ? "No self-hosted runners are registered for this \(store.selectedScope?.kind.title.lowercased() ?? "scope")."
                    : "Resolve the access or connection issue above, then try again.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.visibleRunners.isEmpty {
            ContentUnavailableView.search(text: store.searchText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if layout == .fleet {
            RunnerFleetView(
                runners: store.visibleRunners,
                scopeName: store.selectedScope?.name ?? "",
                name: store.displayName(for:),
                hardware: store.hardware(for:),
                edit: { editingRunner = $0 }
            )
            .overlay(alignment: .bottomLeading) {
                updatedFootnote.padding(16).environment(\.colorScheme, .dark)
            }
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: layout.minimumWidth), spacing: layout.spacing)],
                    spacing: layout.spacing
                ) {
                    ForEach(store.visibleRunners) { runner in
                        let name = store.displayName(for: runner)
                        let hardware = store.hardware(for: runner)
                        switch layout {
                        case .compact:
                            RunnerTile(runner: runner, name: name, hardware: hardware) { editingRunner = runner }
                        case .cards, .fleet:
                            RunnerCard(runner: runner, name: name, hardware: hardware) { editingRunner = runner }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                updatedFootnote.padding(.bottom, 16)
            }
        }
    }

    @ViewBuilder
    private var updatedFootnote: some View {
        if let updatedAt = store.snapshot.updatedAt {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text("Updated \(Date().timeIntervalSince(updatedAt) < 60 ? "just now" : RelativeTime.string(from: updatedAt)) · Refreshes every 30s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct RunnerCard: View {
    let runner: GitHubRunner
    let name: String
    let hardware: RunnerHardware
    let edit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.medium) {
            HStack(alignment: .top) {
                RunnerHardwareImage(hardware: hardware)
                    .runnerThumbnail(size: 64, cornerRadius: RunnerSurface.cardThumbnailRadius)
                Spacer()
                RunnerStatusBadge(state: runner.state)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.headline).lineLimit(1).help(name)
                Text(hardware.title).font(.subheadline).foregroundStyle(.secondary)
                Text([runner.platform, runner.architecture].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(runner.labels.map(\.name).joined(separator: " · "))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(height: 32, alignment: .topLeading)
                .help(runner.labels.map(\.name).joined(separator: ", "))
            HStack {
                Text(runner.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: LiquidGlassMetrics.Spacing.xSmall)
                Button(action: edit) { Label("Edit \(name)", systemImage: "pencil") }
                    .compatGlassIconButton(controlSize: .small)
                    .help("Edit device name and hardware image")
            }
        }
        .padding(RunnerSurface.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.secondary.opacity(0.07),
            in: RoundedRectangle(cornerRadius: RunnerSurface.cardRadius, style: .continuous)
        )
        .contextMenu { Button("Edit Device…", action: edit) }
    }
}

/// Image, name, and status only, so a large fleet fits on one screen. The
/// remaining card details appear in a popover after a short hover.
private struct RunnerTile: View {
    let runner: GitHubRunner
    let name: String
    let hardware: RunnerHardware
    let edit: () -> Void
    @State private var isHovering = false
    @State private var showsDetails = false

    var body: some View {
        HStack(spacing: LiquidGlassMetrics.Spacing.small) {
            RunnerHardwareImage(hardware: hardware, size: 32)
                .runnerThumbnail(size: 48, cornerRadius: RunnerSurface.tileThumbnailRadius)
            VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xSmall) {
                Text(name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                    RunnerStatusBadge(state: runner.state)
                    Spacer(minLength: 0)
                    // Sits beside the badge so the name keeps the full width.
                    Button(action: openEditor) { Label("Edit \(name)", systemImage: "pencil") }
                        .compatGlassIconButton(controlSize: .small)
                        .opacity(isHovering ? 1 : 0)
                        .help("Edit device name and hardware image")
                }
            }
        }
        .opacity(runner.state == .offline ? 0.6 : 1)
        .padding(RunnerSurface.tilePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.secondary.opacity(isHovering ? 0.12 : 0.07),
            in: RoundedRectangle(cornerRadius: RunnerSurface.tileRadius, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: RunnerSurface.tileRadius, style: .continuous))
        .onHover { isHovering = $0 }
        // Hover wash and the edit control fade rather than snap (BTN-5).
        .animation(LiquidGlassMetrics.stateChange, value: isHovering)
        .task(id: isHovering) {
            guard isHovering else {
                showsDetails = false
                return
            }
            // A delay keeps the popover from flashing while the pointer crosses the grid.
            try? await Task.sleep(for: .milliseconds(450))
            if !Task.isCancelled { showsDetails = true }
        }
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
            RunnerDetailsPopover(runner: runner, name: name, hardware: hardware)
        }
        .contextMenu { Button("Edit Device…", action: openEditor) }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Edit Device", openEditor)
    }

    private func openEditor() {
        showsDetails = false
        edit()
    }
}

struct RunnerDetailsPopover: View {
    let runner: GitHubRunner
    let name: String
    let hardware: RunnerHardware

    var body: some View {
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.medium) {
            HStack(spacing: LiquidGlassMetrics.Spacing.small) {
                RunnerHardwareImage(hardware: hardware)
                    .runnerThumbnail(size: 56, cornerRadius: LiquidGlassMetrics.Radius.field)
                VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xxSmall) {
                    Text(name).font(.headline).lineLimit(2)
                    RunnerStatusBadge(state: runner.state)
                }
            }
            Grid(
                alignment: .leadingFirstTextBaseline,
                horizontalSpacing: LiquidGlassMetrics.Spacing.small,
                verticalSpacing: LiquidGlassMetrics.Spacing.xSmall
            ) {
                detailRow("Hardware", hardware.title)
                detailRow("Platform", [runner.platform, runner.architecture].compactMap { $0 }.joined(separator: " · "))
                if name != runner.name { detailRow("Runner", runner.name) }
                if !runner.labels.isEmpty {
                    GridRow {
                        Text("Labels").foregroundStyle(.secondary)
                        Text(runner.labels.map(\.name).joined(separator: " · "))
                            .font(.caption.monospaced())
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.caption)
        }
        .padding(LiquidGlassMetrics.Spacing.medium)
        .frame(width: 300, alignment: .leading)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

private struct RunnerStatusBadge: View {
    let state: GitHubRunner.State

    var body: some View {
        Label(state.rawValue, systemImage: state == .busy ? "circle.dotted.circle.fill" : "circle.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(state.color)
            .padding(.horizontal, LiquidGlassMetrics.Spacing.xSmall)
            .padding(.vertical, LiquidGlassMetrics.Spacing.xxSmall)
            .background(state.color.opacity(0.12), in: Capsule())
    }
}

private enum RunnerLayout: String, CaseIterable {
    case fleet, compact, cards

    var title: String {
        switch self {
        case .fleet: "3D Fleet"
        case .compact: "Compact"
        case .cards: "Cards"
        }
    }

    var symbol: String {
        switch self {
        case .fleet: "cube"
        case .compact: "square.grid.3x3"
        case .cards: "square.grid.2x2"
        }
    }

    var minimumWidth: CGFloat { self == .compact ? 236 : 240 }
    var spacing: CGFloat { self == .compact ? 12 : 16 }
}

private struct RunnerHardwareImage: View {
    let hardware: RunnerHardware
    var size: CGFloat = 38

    var body: some View {
        Group {
            if let asset = hardware.assetName {
                Image(asset).renderingMode(.template).resizable().scaledToFit()
            } else {
                Image(systemName: hardware.symbol).resizable().scaledToFit()
            }
        }
        .foregroundStyle(.primary)
        .frame(width: size, height: size)
        .accessibilityLabel(hardware.title)
    }
}

/// Card and tile geometry. Each thumbnail sits one padding-width from its
/// surface's corner, so its radius is the surface radius minus that padding
/// (LAY-4: outer = inner + padding).
private enum RunnerSurface {
    static let cardPadding = LiquidGlassMetrics.Spacing.medium
    static let cardThumbnailRadius = LiquidGlassMetrics.Radius.control
    static let cardRadius = cardThumbnailRadius + cardPadding

    static let tilePadding = LiquidGlassMetrics.Spacing.small
    static let tileThumbnailRadius = LiquidGlassMetrics.Radius.control
    static let tileRadius = tileThumbnailRadius + tilePadding
}

private extension View {
    /// The tinted square every hardware image sits in, so the card, tile,
    /// popover, and edit sheet share one thumbnail treatment.
    func runnerThumbnail(size: CGFloat, cornerRadius: CGFloat) -> some View {
        frame(width: size, height: size)
            .background(
                Color.accentColor.opacity(0.08),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
    }
}

private struct AddRunnerScopeSheet: View {
    let add: (RunnerScope) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind: RunnerScope.Kind = .enterprise
    @State private var name = ""
    @FocusState private var isNameFocused: Bool

    private var scope: RunnerScope? { RunnerScope.parse(name, kind: kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.large) {
            Text("Add Runner Source").font(.title2.weight(.semibold))
            Picker("Source", selection: $kind) {
                ForEach(RunnerScope.Kind.allCases, id: \.self) { kind in Text(kind.title).tag(kind) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xSmall) {
                // Persistent label above the field; the placeholder is only
                // an example value (FORM-1/FORM-2).
                Text(kind.title).font(.subheadline.weight(.medium))
                // Helper text sits tight under its own field (FORM-5).
                VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xxSmall) {
                    TextField(kind.inputPlaceholder, text: $name)
                        .focused($isNameFocused)
                        .onSubmit(submit)
                        .liquidGlassField(isFocused: isNameFocused)
                    Text(kind == .enterprise
                         ? "Uses your GitHub CLI account. Enterprise runners need the manage_runners:enterprise token scope."
                         : "Uses your GitHub CLI account. You’ll need access to view this source’s self-hosted runners.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .compatGlassButtonStyle()
                Button("Add Source", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .compatGlassProminentButtonStyle()
                    .disabled(scope == nil)
            }
            .padding(.top, LiquidGlassMetrics.Spacing.xxSmall)
        }
        .padding(LiquidGlassMetrics.Spacing.xLarge)
        .frame(width: 420)
        .onAppear { isNameFocused = true }
    }

    private func submit() {
        guard let scope else { return }
        add(scope)
        dismiss()
    }
}

private struct RunnerDetailsSheet: View {
    let runner: GitHubRunner
    let save: (RunnerPresentation) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var presentation: RunnerPresentation

    init(runner: GitHubRunner, presentation: RunnerPresentation, save: @escaping (RunnerPresentation) -> Void) {
        self.runner = runner
        self.save = save
        _presentation = State(initialValue: presentation)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.large) {
            HStack(spacing: LiquidGlassMetrics.Spacing.medium) {
                RunnerHardwareImage(hardware: presentation.hardware ?? .inferred(for: runner))
                    .runnerThumbnail(size: 56, cornerRadius: LiquidGlassMetrics.Radius.field)
                VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xxSmall) {
                    Text("Edit Device").font(.title2.weight(.semibold))
                    Text(runner.name).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            // Persistent labels stacked above each control (FORM-1), matching
            // Add Runner Source; the placeholder is only the GitHub name the
            // device falls back to (FORM-2).
            VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.medium) {
                stackedRow("Display name") {
                    TextField("Display name", text: $presentation.name, prompt: Text(runner.name))
                        .labelsHidden()
                        .liquidGlassField()
                }
                stackedRow("Hardware") {
                    Picker("Hardware", selection: $presentation.hardware) {
                        Text("Automatic (\(RunnerHardware.inferred(for: runner).title))").tag(nil as RunnerHardware?)
                        ForEach(RunnerHardware.allCases) { hardware in
                            Text(hardware.title).tag(Optional(hardware))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            Text("Device names and images are saved in Cockpit. Runner labels come from GitHub.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                Button("Reset to Defaults") { presentation = RunnerPresentation() }
                    .compatGlassButtonStyle()
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .compatGlassButtonStyle()
                Button("Save") { save(presentation); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .compatGlassProminentButtonStyle()
            }
        }
        .padding(LiquidGlassMetrics.Spacing.xLarge)
        .frame(width: 440)
    }

    /// A visible label above its control; the control's own title stays its
    /// VoiceOver name, so the visible label is hidden from VoiceOver.
    private func stackedRow<Control: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xSmall) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            control()
        }
    }
}

private extension GitHubRunner.State {
    var color: Color {
        switch self {
        case .idle: .green
        case .busy: .orange
        case .offline: .secondary
        }
    }
}
