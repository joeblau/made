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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Workspace")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                TextField("Search \(displayPath(finder.root))", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($isSearchFocused)
                    .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
                    .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
                    .onSubmit(create)
                if !query.isEmpty {
                    searchResults
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Label(folderTitle, systemImage: directory == nil ? "house" : "folder")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(directory?.path ?? NSHomeDirectory())
                    Spacer(minLength: 0)
                    if directory != nil {
                        Button("Use Home Folder") {
                            query = ""
                            directory = nil
                        }
                    }
                    Button("Choose…", action: chooseDirectory)
                }
                Text(directory == nil
                     ? "No folder selected. The workspace starts from your home folder."
                     : "Terminals in this workspace start in this folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
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
            HStack(spacing: 6) {
                if finder.isIndexing {
                    ProgressView().controlSize(.small)
                    Text("Indexing \(displayPath(finder.root))…")
                } else {
                    Text("No matching folders")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 60)
        } else {
            ScrollViewReader { proxy in
                List(finder.results) { item in
                    resultRow(item)
                        .id(item.path)
                }
                .listStyle(.bordered)
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
            HStack(spacing: 8) {
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
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor.opacity(0.25) : .clear, in: .rect(cornerRadius: 4))
        }
        .buttonStyle(.plain)
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
