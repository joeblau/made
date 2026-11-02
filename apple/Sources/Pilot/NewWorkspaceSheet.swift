import AppKit
import SwiftUI

/// Identifies one New Workspace sheet presentation; `groupID` places the
/// created workspace into the sidebar group it was requested from.
struct NewWorkspaceRequest: Identifiable {
    let id = UUID()
    var groupID: UUID?
}

/// Confirms workspace creation with an optional starting folder, found by
/// fuzzy search under `~/Developer` or with the folder panel. Leaving the
/// folder unset keeps the existing behavior: terminals start in the home folder.
struct NewWorkspaceSheet: View {
    let finder: DirectoryFinder
    let onCreate: (URL?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var directory: URL?
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    /// Result list surface; rows inset by `resultInset` nest concentrically
    /// inside it (LAY-4).
    private static let resultsRadius = LiquidGlassMetrics.Radius.field
    private static let resultInset = LiquidGlassMetrics.Spacing.xxSmall

    var body: some View {
        VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.large) {
            Text("New Workspace")
                .font(.headline)

            // Persistent label above the field; the placeholder is only the
            // instruction (FORM-1/FORM-2). Label → field stays at 8 (FORM-5).
            VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xSmall) {
                Text("Starting Folder")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    // The field carries this name for VoiceOver; hide the
                    // visible label so it is not read twice.
                    .accessibilityHidden(true)
                TextField("Search \(displayPath(finder.root))", text: $query)
                    .accessibilityLabel("Starting Folder")
                    .focused($isSearchFocused)
                    .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
                    .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
                    .onSubmit(create)
                    .liquidGlassField(systemImage: "magnifyingglass", isFocused: isSearchFocused)
                if !query.isEmpty {
                    searchResults
                }
            }

            VStack(alignment: .leading, spacing: LiquidGlassMetrics.Spacing.xxSmall) {
                HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                    Label(folderTitle, systemImage: directory == nil ? "house" : "folder")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(directory?.path ?? NSHomeDirectory())
                    Spacer(minLength: 0)
                    CompatGlassContainer(spacing: 0) {
                        HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                            if directory != nil {
                                Button("Use Home Folder") {
                                    query = ""
                                    directory = nil
                                }
                                .compatGlassButtonStyle()
                                .buttonBorderShape(.capsule)
                            }
                            Button("Choose…", action: chooseDirectory)
                                .compatGlassButtonStyle()
                                .buttonBorderShape(.capsule)
                        }
                    }
                }
                Text(directory == nil
                     ? "No folder selected. The workspace starts from your home folder."
                     : "Terminals in this workspace start in this folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Final helper → actions sits at 24 (FORM-5): stack spacing + 4.
            CompatGlassContainer(spacing: 0) {
                HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .compatGlassButtonStyle()
                        .buttonBorderShape(.capsule)
                    Button("Create", action: create)
                        .keyboardShortcut(.defaultAction)
                        .compatGlassProminentButtonStyle()
                        .buttonBorderShape(.capsule)
                }
            }
            .padding(.top, LiquidGlassMetrics.Spacing.xxSmall)
        }
        .padding(LiquidGlassMetrics.Spacing.xLarge)
        .frame(width: 520)
        .onAppear {
            finder.setQuery("")
            finder.start()
            isSearchFocused = true
        }
        .onChange(of: query) { finder.setQuery(query) }
        // Typing picks the best match, so Return creates from the top result.
        .onChange(of: finder.results) {
            guard !query.isEmpty else { return }
            directory = finder.results.first.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if finder.results.isEmpty {
            HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                if finder.isIndexing {
                    ProgressView().controlSize(.small)
                    Text("Indexing \(displayPath(finder.root))…")
                } else {
                    Image(systemName: "folder.badge.questionmark")
                        .accessibilityHidden(true)
                    Text("No matching folders")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: Self.resultsRadius, style: .continuous))
        } else {
            ScrollViewReader { proxy in
                // A quiet rounded surface instead of the bordered list
                // (LAY-2): content, so a fill rather than glass.
                List(finder.results) { item in
                    resultRow(item)
                        .id(item.path)
                        .listRowInsets(EdgeInsets(
                            top: 0,
                            leading: Self.resultInset,
                            bottom: 0,
                            trailing: Self.resultInset
                        ))
                        // Rows separate by their inset highlight and spacing,
                        // not hairlines that run past the inset (LAY-2).
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contentMargins(.vertical, Self.resultInset, for: .scrollContent)
                .background(.fill.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: Self.resultsRadius, style: .continuous))
                .frame(height: 220)
                .onChange(of: directory) {
                    if let path = directory?.path { proxy.scrollTo(path) }
                }
            }
        }
    }

    private func resultRow(_ item: FileItem) -> some View {
        let isSelected = item.path == directory?.path
        return Button {
            directory = URL(fileURLWithPath: item.path, isDirectory: true)
        } label: {
            HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                Image(systemName: "folder")
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                    Text(displayPath(item.path))
                        .font(.caption)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, LiquidGlassMetrics.Spacing.xxSmall)
            .padding(.horizontal, LiquidGlassMetrics.Spacing.xSmall)
            .contentShape(Rectangle())
            .background(
                isSelected ? Color.accentColor.opacity(0.25) : .clear,
                in: RoundedRectangle(cornerRadius: Self.resultRowRadius, style: .continuous)
            )
            .animation(LiquidGlassMetrics.stateChange, value: isSelected)
        }
        // Whole-row tap target: unglazed, with hover and press feedback
        // (BTN-5) in the same concentric shape as the selection.
        .buttonStyle(.liquidGlassPressable(cornerRadius: Self.resultRowRadius))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private static var resultRowRadius: CGFloat {
        LiquidGlassMetrics.Radius.inner(outer: resultsRadius, padding: resultInset)
    }

    private var folderTitle: String {
        guard let directory else { return "Home folder (~)" }
        return displayPath(directory.path)
    }

    private func displayPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private func moveSelection(by offset: Int) {
        let results = finder.results
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.path == directory?.path } ?? -offset
        let next = min(max(current + offset, 0), results.count - 1)
        directory = URL(fileURLWithPath: results[next].path, isDirectory: true)
    }

    private func create() {
        onCreate(directory)
        dismiss()
    }

    /// The panel only returns existing directories, and Pilot ships
    /// unsandboxed, so the path is usable without a security-scoped bookmark.
    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose a workspace folder"
        panel.prompt = "Use Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            query = ""
            directory = url
        }
    }
}
