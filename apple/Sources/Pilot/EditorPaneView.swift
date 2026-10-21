import AppKit
import CodeEditSourceEditor
import SwiftUI

enum EditorViewportPolicy {
    static let findPanelHeight: CGFloat = 28

    /// Soft-wrapped text has no horizontal scrollable extent. Preserve the
    /// vertical position while removing any elastic/restored X displacement.
    static func normalizedWrappedScrollPosition(_ position: CGPoint?) -> CGPoint? {
        guard var position else { return nil }
        position.x = 0
        return position
    }

    /// CodeEdit adds a content inset when its find panel changes visibility,
    /// but AppKit leaves the clip-view origin where it was. Offset that origin
    /// by the same amount so the first visible line moves below the panel
    /// instead of remaining underneath it.
    static func adjustedScrollPosition(
        _ position: CGPoint?,
        findPanelWasVisible: Bool,
        findPanelIsVisible: Bool
    ) -> CGPoint? {
        guard findPanelWasVisible != findPanelIsVisible else {
            return position
        }
        var position = position ?? .zero
        position.y += findPanelIsVisible ? -findPanelHeight : findPanelHeight
        return position
    }
}

@MainActor
enum EditorFindPanelHitTestingPolicy {
    /// CodeEditSourceEditor 0.15.2 adds its text surface after its find panel.
    /// The panel's layer is visually raised, but AppKit hit-testing still follows
    /// subview order, so clicks fall through to the editor. Move the panel to the
    /// front of that order as well.
    @discardableResult
    static func bringFindPanelsToFront(in rootView: NSView) -> Int {
        bringFindPanelsToFront(in: rootView, matching: isCodeEditFindPanel)
    }

    @discardableResult
    static func bringFindPanelsToFront(
        in rootView: NSView,
        matching isFindPanel: (NSView) -> Bool
    ) -> Int {
        var pending = [rootView]
        var repairCount = 0

        while let container = pending.popLast() {
            let children = container.subviews
            pending.append(contentsOf: children)

            for child in children where isFindPanel(child) && container.subviews.last !== child {
                container.addSubview(child, positioned: .above, relativeTo: nil)
                repairCount += 1
            }
        }

        return repairCount
    }

    private static func isCodeEditFindPanel(_ view: NSView) -> Bool {
        NSStringFromClass(type(of: view)).hasSuffix(".FindPanelHostingView")
    }
}

/// A lightweight code editor pane: a fuzzy file finder overlaid on top of a
/// CodeEditSourceEditor buffer.
///
/// Editing model:
/// - `EditorDocumentSession` owns the buffer and all file I/O. The buffer is
///   read from disk on appear (or when the finder opens a file) and written
///   back on ⌘S, before switching files, and when the pane closes.
/// - `state.filePath` is the only thing persisted; the text always reflects the
///   on-disk file, never a stale restored copy.
struct EditorPaneView: View {
    let state: EditorState
    let rootPath: String?
    let isActive: Bool
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var session = EditorDocumentSession()
    @State private var editorState = SourceEditorState()

    // Fuzzy finder overlay.
    @State private var showFinder = false
    @State private var finder = FileFinder()
    @State private var searchQuery = ""
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool

    // Arrow-key fallback for the finder; see `installKeyMonitor()`.
    @State private var keyMonitor: Any?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            editorLayer

            // Save failures must stay visible while editing, not only in the finder.
            if session.document != nil, let errorMessage = session.errorMessage {
                errorBanner(errorMessage)
            }

            if showFinder {
                finderOverlay
            }

            keyboardShortcuts
        }
        .background(Color(nsColor: .textBackgroundColor))
        .alert(
            "“\(session.url?.lastPathComponent ?? "File")” changed on disk",
            isPresented: $session.conflictPending
        ) {
            Button("Overwrite", role: .destructive) {
                session.requestSave(.overwrite)
            }
            Button("Reload") {
                session.requestReload(completion: handleLoadOutcome)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This file was modified by another program since you opened it.")
        }
        .onAppear { activate() }
        .onDisappear {
            removeKeyMonitor()
            // Drop pending loads and flush unsaved edits (e.g. the pane closed).
            session.close()
        }
        .onChange(of: isActive) {
            if isActive {
                if showFinder { focusSearchAndInstallMonitor() }
            } else {
                // Relinquish focus + global key handling the moment another
                // workspace or pane takes over.
                searchFocused = false
                removeKeyMonitor()
            }
        }
        .onChange(of: isSelected) {
            // Two panes in the same active workspace both have isActive == true, so
            // selection is what arbitrates which one owns the arrow-key monitor.
            if isSelected {
                if showFinder && isActive { focusSearchAndInstallMonitor() }
            } else {
                searchFocused = false
                removeKeyMonitor()
            }
        }
        .onChange(of: searchQuery) {
            finder.setQuery(searchQuery)
            selectedIndex = 0
        }
        .onChange(of: rootPath) {
            // Keep quick-open attached to the active workspace even when its
            // inferred/manual root changes while the finder is already open.
            // FileFinder invalidates old-root indexing and filtering work.
            selectedIndex = 0
            if let rootPath {
                finder.start(root: rootPath)
            } else {
                finder.reset()
            }
        }
        .onChange(of: finder.isIndexing) {
            // Populate the initial list once the background index finishes.
            finder.setQuery(searchQuery)
        }
        .onChange(of: showFinder) {
            if showFinder {
                focusSearchAndInstallMonitor()
            } else {
                searchFocused = false
                removeKeyMonitor()
            }
        }
    }

    // MARK: - Editor layer

    @ViewBuilder
    private var editorLayer: some View {
        if let document = session.document {
            SourceEditor(
                editorText,
                language: session.language,
                configuration: SourceEditorConfiguration(
                    appearance: .init(
                        theme: PilotEditorTheme.theme(for: colorScheme),
                        font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                        wrapLines: true
                    ),
                    behavior: .init(indentOption: .spaces(count: 4)),
                    layout: .init(contentInsets: NSEdgeInsets())
                ),
                state: $editorState
            )
            // SourceEditor 0.15.2 reads its binding only when the controller is
            // created, so each loaded document (including reloads) needs a fresh one.
            .id(document.id)
            .background(EditorFindPanelHitTestingRepair())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .onChange(of: editorState.scrollPosition) {
                normalizeWrappedEditorScrollPosition()
            }
            .onChange(of: editorState.findPanelVisible) { oldValue, newValue in
                adjustEditorForFindPanelTransition(from: oldValue, to: newValue)
            }
        } else if !showFinder {
            emptyState
        } else {
            // Finder is up over a blank canvas — let the overlay carry the UI.
            Color.clear
        }
    }

    /// A genuine edit also selects this pane so the ⌘S/⌘P/⌘O shortcuts (gated on
    /// `isSelected`) target it.
    private var editorText: Binding<String> {
        Binding(
            get: { session.text },
            set: { newText in
                if session.updateText(newText) { onSelect() }
            }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "curlybraces")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            Text("⌘P to find a file")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Finder overlay

    private var finderOverlay: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search files…", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($searchFocused)
                    .onKeyPress(.return) { openSelected(); return .handled }
                    .onKeyPress(.escape) { dismissFinder(); return .handled }
                    .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
                    .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            resultsBody
                .frame(maxHeight: 360)
        }
        .frame(maxWidth: 520)
        .frame(maxHeight: 360)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
        .padding(.top, 60)             // float the card toward the top third
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// CodeEdit persists both axes of its clip-view origin, even when wrapping
    /// hides the horizontal scroller. A sideways trackpad gesture can therefore
    /// leave wrapped text shifted underneath the floating gutter. Wrapped code
    /// has no valid horizontal offset, so retain only the vertical position.
    private func normalizeWrappedEditorScrollPosition() {
        let current = editorState.scrollPosition
        let normalized = EditorViewportPolicy.normalizedWrappedScrollPosition(current)
        guard current != normalized else { return }
        editorState.scrollPosition = normalized
    }

    private func adjustEditorForFindPanelTransition(from oldValue: Bool?, to newValue: Bool?) {
        guard let newValue else { return }
        let current = editorState.scrollPosition
        let adjusted = EditorViewportPolicy.adjustedScrollPosition(
            current,
            findPanelWasVisible: oldValue ?? false,
            findPanelIsVisible: newValue
        )
        guard current != adjusted else { return }
        editorState.scrollPosition = adjusted
    }

    @ViewBuilder
    private var resultsBody: some View {
        if rootPath == nil {
            finderMessage("Set a workspace root path to browse files.")
        } else if let errorMessage = session.errorMessage {
            finderMessage(errorMessage)
        } else if finder.isIndexing && finder.results.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Indexing…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if finder.results.isEmpty {
            finderMessage("No matches")
        } else {
            resultsList
        }
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(finder.results.enumerated()), id: \.element.id) { index, item in
                        resultRow(item, isHighlighted: index == selectedIndex)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedIndex = index
                                openSelected()
                            }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: selectedIndex) {
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(selectedIndex, anchor: .center)
                }
            }
        }
    }

    private func resultRow(_ item: FileItem, isHighlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.name)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(1)
            let directory = directoryPortion(of: item.relativePath)
            if !directory.isEmpty {
                Text(directory)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(
            isHighlighted
                ? Color.accentColor.opacity(0.22)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .padding(.horizontal, 6)
    }

    private func finderMessage(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
    }

    // MARK: - Error banner

    /// Compact, dismissible banner pinned to the top of the editor. Surfaces ⌘S /
    /// auto-save failures (and load errors) without stealing the buffer.
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button {
                session.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func directoryPortion(of relativePath: String) -> String {
        let directory = (relativePath as NSString).deletingLastPathComponent
        return directory
    }

    // MARK: - Hidden keyboard shortcuts

    /// ⌘S (save), ⌘P / ⌘O (open finder). All gated on `isActive` so they never
    /// hijack the global shortcuts while another pane or workspace is frontmost.
    /// Hidden zero-size buttons rather than `.keyboardShortcut` modifiers on real
    /// controls, matching `ContentView`'s background-button idiom.
    private var keyboardShortcuts: some View {
        Group {
            Button("") { session.requestSave(.interactive) }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!(isActive && isSelected && session.document != nil))

            Button("", action: openFinder)
                .keyboardShortcut("p", modifiers: .command)
                .disabled(!(isActive && isSelected))

            Button("", action: openFinder)
                .keyboardShortcut("o", modifiers: .command)
                .disabled(!(isActive && isSelected))
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: - Lifecycle

    private func activate() {
        session.attach(store: state)
        if let url = state.fileURL {
            load(url)
        } else {
            openFinder()
        }
    }

    private func openFinder() {
        guard isActive else { return }
        // Claim selection so the gated ⌘P/⌘O/⌘S shortcuts target this pane.
        onSelect()
        searchQuery = ""
        selectedIndex = 0
        if rootPath != nil {
            finder.start(root: rootPath!)   // coalesces while an index scan is in flight
        }
        showFinder = true
    }

    /// Escape only dismisses the finder when there's already a file to fall back
    /// to — otherwise the pane would be left blank with no way back.
    private func dismissFinder() {
        guard session.document != nil else { return }
        showFinder = false
    }

    private func focusSearchAndInstallMonitor() {
        // Gated on selection as well as activity: two panes in one active workspace
        // both have isActive == true, so without the isSelected gate both would
        // install a monitor and one arrow keypress would move both result lists.
        guard isActive && isSelected else { return }
        searchFocused = true
        installKeyMonitor()
    }

    // MARK: - Selection / navigation

    private func moveSelection(by delta: Int) {
        guard !finder.results.isEmpty else { return }
        let next = selectedIndex + delta
        selectedIndex = max(0, min(finder.results.count - 1, next))
    }

    private func openSelected() {
        guard showFinder,
              finder.results.indices.contains(selectedIndex) else { return }
        let item = finder.results[selectedIndex]
        load(URL(fileURLWithPath: item.path))
    }

    // MARK: - Document loading

    private func load(_ url: URL) {
        session.requestOpen(url, completion: handleLoadOutcome)
    }

    /// Presentation for a load that was not superseded. The session has already
    /// set the buffer, error message, and persisted path.
    private func handleLoadOutcome(_ outcome: EditorLoadOutcome) {
        switch outcome {
        case .loaded:
            editorState = SourceEditorState()
            showFinder = false
            // Opening a file is an interaction with this pane; claim selection so
            // the gated ⌘S/⌘P/⌘O shortcuts target it.
            onSelect()
        case .blockedBySave, .blockedByEdits:
            // Return to the unsaved buffer; for a failed save the banner explains
            // why it stayed.
            showFinder = false
        case .tooLarge, .binary, .failed:
            presentFinder()
        case .superseded:
            break
        }
    }

    /// Fall back to the finder after a load error, making sure the index is being
    /// built (the initial load on appear bypasses `openFinder`).
    private func presentFinder() {
        if let rootPath { finder.start(root: rootPath) }
        showFinder = true
    }

    // MARK: - Key monitor (arrow nav fallback)

    /// A focused `TextField` consumes up/down arrows before `.onKeyPress` sees
    /// them, so the finder intercepts them with a local monitor while it is open
    /// in the active, selected pane. Return and Escape still use `.onKeyPress`.
    ///
    /// The `isActive`/`isSelected` values captured here are install-time
    /// snapshots of a value-type view, so the monitor's lifetime is owned by the
    /// `onChange` handlers that remove it. `showFinder` reads through to current
    /// `@State` and is the only live guard.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard self.showFinder else { return event }
            switch event.keyCode {
            case 125: // down arrow
                self.moveSelection(by: 1)
                return nil
            case 126: // up arrow
                self.moveSelection(by: -1)
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

private struct EditorFindPanelHitTestingRepair: NSViewRepresentable {
    func makeNSView(context: Context) -> RepairObserverView {
        RepairObserverView()
    }

    func updateNSView(_ nsView: RepairObserverView, context: Context) {
        nsView.scheduleRepair()
    }

    final class RepairObserverView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleRepair()
        }

        func scheduleRepair() {
            NSObject.cancelPreviousPerformRequests(
                withTarget: self,
                selector: #selector(repairFindPanelHitTesting),
                object: nil
            )
            perform(#selector(repairFindPanelHitTesting), with: nil, afterDelay: 0)
        }

        @objc private func repairFindPanelHitTesting() {
            guard let contentView = window?.contentView else { return }
            EditorFindPanelHitTestingPolicy.bringFindPanelsToFront(in: contentView)
        }
    }
}
