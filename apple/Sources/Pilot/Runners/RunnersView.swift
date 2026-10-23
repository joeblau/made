import SwiftUI

struct RunnersView: View {
    @Bindable var store: RunnersStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsAddScope = false
    @State private var editingRunner: GitHubRunner?
    @State private var refreshRevision = 0

    private struct PollIdentity: Hashable {
        let scopeID: String?
        let active: Bool
        let revision: Int
    }

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
                    Text("Add an organization or repository to see its self-hosted runners.")
                } actions: {
                    Button("Add Organization or Repository", systemImage: "plus") { showsAddScope = true }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showsAddScope) {
            AddRunnerScopeSheet { scope in
                store.add(scope)
                refreshRevision += 1
            }
        }
        .sheet(item: $editingRunner) { runner in
            if let scope = store.selectedScope {
                RunnerDetailsSheet(runner: runner, presentation: store.presentation(for: runner)) { presentation in
                    store.savePresentation(presentation, runner: runner, scope: scope)
                }
            }
        }
        .task(id: PollIdentity(scopeID: store.selectedScopeID, active: scenePhase == .active, revision: refreshRevision)) {
            guard scenePhase == .active, store.selectedScope != nil else { return }
            while !Task.isCancelled {
                await store.refreshSelected()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
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
                .help("Add an organization or repository")
                .accessibilityLabel("Add an organization or repository")
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

            if store.isRefreshing { ProgressView().controlSize(.small) }
            Button { refreshRevision += 1 } label: { Image(systemName: "arrow.clockwise") }
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
            Button("Retry") { refreshRevision += 1 }.disabled(store.isRefreshing)
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
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                    ForEach(store.visibleRunners) { runner in
                        RunnerCard(
                            runner: runner,
                            name: store.displayName(for: runner),
                            hardware: store.hardware(for: runner)
                        ) { editingRunner = runner }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                if let updatedAt = store.snapshot.updatedAt {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text("Updated \(Date().timeIntervalSince(updatedAt) < 60 ? "just now" : RelativeTime.string(from: updatedAt)) · Refreshes every 30s")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 16)
                    }
                }
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
                Label(runner.state.rawValue, systemImage: runner.state == .busy ? "circle.dotted.circle.fill" : "circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(runner.state.color)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(runner.state.color.opacity(0.12), in: Capsule())
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

private struct RunnerHardwareImage: View {
    let hardware: RunnerHardware

    var body: some View {
        Group {
            if let asset = hardware.assetName {
                Image(asset).renderingMode(.template).resizable().scaledToFit()
            } else {
                Image(systemName: hardware.symbol).resizable().scaledToFit()
            }
        }
        .foregroundStyle(.primary)
        .frame(width: 38, height: 38)
        .accessibilityLabel(hardware.title)
    }
}

private struct AddRunnerScopeSheet: View {
    let add: (RunnerScope) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind: RunnerScope.Kind = .organization
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
                TextField(kind == .organization ? "organization-name" : "owner/repository", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFocused)
                    .onSubmit(submit)
                Text("Uses your GitHub CLI account. You’ll need access to view this source’s self-hosted runners.")
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
