import SwiftUI

struct RunnersView: View {
    @Bindable var store: RunnersStore
    @State private var showsAddScope = false
    @State private var editingRunner: GitHubRunner?
    @AppStorage("runners.layout") private var layout: RunnerLayout = .fleet

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
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
                        .buttonStyle(.borderedProminent)
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

    private var tabBar: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.scopes) { scope in
                        Button {
                            store.selectedScopeID = scope.id
                            store.searchText = ""
                        } label: {
                            Label(scope.name, systemImage: scope.kind.symbol)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    store.selectedScopeID == scope.id
                                        ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(store.selectedScopeID == scope.id ? .isSelected : [])
                        .contextMenu {
                            if let url = scope.settingsURL { Link("Open Runner Settings on GitHub", destination: url) }
                            Button("Remove Tab", role: .destructive) { store.remove(scope) }
                        }
                    }
                }
            }
            Button { showsAddScope = true } label: { Image(systemName: "plus") }
                .help("Add an enterprise, organization, or repository")
                .accessibilityLabel("Add a runner source")
        }
        .padding(12)
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
        .padding(.vertical, 14)
    }

    private var summaryCounts: some View {
        HStack(spacing: 16) {
            Text("\(store.snapshot.runners.count) runners")
                .font(.headline)
            ForEach(GitHubRunner.State.allCases, id: \.rawValue) { state in
                let count = store.snapshot.runners.filter { $0.state == state }.count
                HStack(spacing: 5) {
                    Circle().fill(state.color).frame(width: 6, height: 6)
                    Text("\(count) \(state.rawValue.lowercased())")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var searchControls: some View {
        HStack(spacing: 16) {
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter runners", text: $store.searchText)
                    .textFieldStyle(.plain)
            }
            .font(.subheadline)
            .padding(7)
            .frame(maxWidth: 200)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))

            Picker("Layout", selection: $layout) {
                ForEach(RunnerLayout.allCases, id: \.self) { layout in
                    Label(layout.title, systemImage: layout.symbol).labelStyle(.iconOnly).tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Switch between the 3D fleet, compact tiles, and detailed cards")

            if store.isRefreshing { ProgressView().controlSize(.small) }
            Button { Task { await store.refreshSelected() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain)
                .disabled(store.isRefreshing)
                .help("Refresh runners")
                .accessibilityLabel("Refresh runners")
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                if store.snapshot.updatedAt != nil { Text("Showing the last successful refresh.").foregroundStyle(.secondary) }
            }
            Spacer()
            Button("Retry") { Task { await store.refreshSelected() } }.disabled(store.isRefreshing)
        }
        .font(.subheadline)
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                RunnerHardwareImage(hardware: hardware)
                    .frame(width: 64, height: 64)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
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
            Divider()
            HStack {
                Text(runner.name).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                Spacer(minLength: 8)
                Button(action: edit) { Image(systemName: "pencil") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Edit device name and hardware image")
                    .accessibilityLabel("Edit \(name)")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.secondary.opacity(0.12)))
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
        HStack(spacing: 14) {
            RunnerHardwareImage(hardware: hardware, size: 30)
                .frame(width: 50, height: 50)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 7) {
                Text(name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    RunnerStatusBadge(state: runner.state)
                    Spacer(minLength: 0)
                    // Sits beside the badge so the name keeps the full width.
                    Button(action: openEditor) { Image(systemName: "pencil") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .opacity(isHovering ? 1 : 0)
                        .help("Edit device name and hardware image")
                        .accessibilityLabel("Edit \(name)")
                }
            }
        }
        .opacity(runner.state == .offline ? 0.6 : 1)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(isHovering ? 0.1 : 0.055), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.secondary.opacity(0.12)))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onHover { isHovering = $0 }
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                RunnerHardwareImage(hardware: hardware)
                    .frame(width: 56, height: 56)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 6) {
                    Text(name).font(.headline).lineLimit(2)
                    RunnerStatusBadge(state: runner.state)
                }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
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
        .padding(16)
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
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
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

private struct AddRunnerScopeSheet: View {
    let add: (RunnerScope) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind: RunnerScope.Kind = .enterprise
    @State private var name = ""
    @FocusState private var isNameFocused: Bool

    private var scope: RunnerScope? { RunnerScope.parse(name, kind: kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add Runners").font(.title2.weight(.semibold))
            Picker("Source", selection: $kind) {
                ForEach(RunnerScope.Kind.allCases, id: \.self) { kind in Text(kind.title).tag(kind) }
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 8) {
                Text(kind.title).font(.subheadline.weight(.medium))
                TextField(kind.inputPlaceholder, text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFocused)
                    .onSubmit(submit)
                Text(kind == .enterprise
                     ? "Uses your GitHub CLI account. Enterprise runners need the manage_runners:enterprise token scope."
                     : "Uses your GitHub CLI account. You’ll need access to view this source’s self-hosted runners.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add", action: submit).keyboardShortcut(.defaultAction).disabled(scope == nil)
            }
        }
        .padding(24)
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
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                RunnerHardwareImage(hardware: presentation.hardware ?? .inferred(for: runner))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Edit Device").font(.title2.weight(.semibold))
                    Text(runner.name).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Form {
                TextField("Display name", text: $presentation.name, prompt: Text(runner.name))
                Picker("Hardware", selection: $presentation.hardware) {
                    Text("Automatic (\(RunnerHardware.inferred(for: runner).title))").tag(nil as RunnerHardware?)
                    ForEach(RunnerHardware.allCases) { hardware in
                        Text(hardware.title).tag(Optional(hardware))
                    }
                }
            }
            Text("Device names and images are saved in Cockpit. Runner labels come from GitHub.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Reset") { presentation = RunnerPresentation() }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(presentation); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
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
