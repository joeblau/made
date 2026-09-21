import AppKit
import CodeEditLanguages
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
/// CodeEditSourceEditor buffer. Mirrors `BrowserPaneView`'s contract — a
/// SwiftData-backed state object plus the `isActive`/`isSelected`/`onSelect`
/// triplet — so the wiring agent can drop it into the `PaneView` switch with
/// the same shape as the browser and device panes.
///
/// Editing model:
/// - The buffer is read from disk on appear (or when the finder opens a file)
///   and written back on ⌘S, on auto-save when switching files, and never
///   silently lost.
/// - `state.filePath` is the only thing persisted; the text always reflects the
///   on-disk file, never a stale restored copy.
struct EditorPaneView: View {
    let state: EditorState
    let rootPath: String?
    let isActive: Bool
    let isSelected: Bool
    let onSelect: () -> Void

    // Editor buffer + CodeEditSourceEditor plumbing.
    @State private var text = ""
    @State private var editorState = SourceEditorState()
    @State private var language: CodeLanguage = .default
    @State private var loadedURL: URL?
    @State private var isDirty = false
    @State private var errorMessage: String?

    // The encoding the file decoded as (preserved on write so we don't silently
    // transcode a Latin-1 file to UTF-8) and the on-disk modification date at the
    // moment we loaded it — the baseline for the external-change conflict guard.
    @State private var fileEncoding: String.Encoding = .utf8
    @State private var diskModificationDate: Date?
    @State private var conflictPresented = false

    // True while a programmatic `text = contents` load is in flight, so the text
    // observer doesn't mark the freshly-loaded buffer dirty (it's reset on the
    // next runloop tick, after isDirty is cleared).
    @State private var isLoading = false

    // Fuzzy finder overlay.
    @State private var showFinder = false
    @State private var finder = FileFinder()
    @State private var searchQuery = ""
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool

    // AppKit key-down monitor: SwiftUI's `.onKeyPress` reliably handles Return
    // and Escape, but a focused `TextField` swallows the up/down arrows before
    // SwiftUI sees them, so arrow navigation goes through this local monitor
    // instead (installed only while the finder is open and this pane is the
    // active, selected one, mirroring `ContentView.installNotesToggleMonitor`).
    // The token is removed on dismiss, on disappear, and whenever `isActive` or
    // `isSelected` flips false.
    @State private var keyMonitor: Any?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            editorLayer

            // Save / auto-save failures need to be visible while editing, not just
            // buried in the finder's status line — float a dismissible banner on top.
            if loadedURL != nil, let errorMessage {
                errorBanner(errorMessage)
            }

            if showFinder {
                finderOverlay
            }

            keyboardShortcuts
        }
        .background(Color(nsColor: .textBackgroundColor))
        .alert(
            "“\(loadedURL?.lastPathComponent ?? "File")” changed on disk",
            isPresented: $conflictPresented
        ) {
            Button("Overwrite", role: .destructive) {
                if let url = loadedURL { writeBuffer(to: url) }
            }
            Button("Reload") {
                if let url = loadedURL { reloadFromDisk(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This file was modified by another program since you opened it.")
        }
        .onAppear { activate() }
        .onDisappear {
            removeKeyMonitor()
            // Flush any unsaved edits when the pane is torn down (e.g. closed).
            saveIfDirty()
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
        if loadedURL != nil {
            SourceEditor(
                $text,
                language: language,
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
            .background(EditorFindPanelHitTestingRepair())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .onChange(of: text) {
                // SourceEditor mutates `text` while loading too; only flag dirty on
                // a real edit (a file is backing the buffer and we're not mid-load).
                // A genuine edit also marks this pane as the selected one so the
                // ⌘S/⌘P/⌘O shortcuts (gated on isSelected) light up.
                if loadedURL != nil && !isLoading {
                    isDirty = true
                    onSelect()
                }
            }
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
            // Search field.
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

            // Results / status.
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
        } else if let errorMessage {
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
                errorMessage = nil
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

    /// The directory part of a relative path (everything but the basename).
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
            Button("") { save(interactive: true) }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!(isActive && isSelected && loadedURL != nil))

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

    /// Configure the pane on appear: load the persisted file if there is one,
    /// otherwise present the finder.
    private func activate() {
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
        guard loadedURL != nil else { return }
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

    // MARK: - File IO

    /// Files larger than this are rejected rather than loaded into the editor;
    /// CodeEditSourceEditor isn't built for multi-megabyte buffers and reading one
    /// synchronously would jank the UI.
    private static let maxEditableBytes = 10_000_000

    /// Open `url` in the editor. Auto-saves the current buffer first so edits are
    /// never lost when switching files. Rejects over-size files and binary files
    /// (NUL byte / control-byte heuristic), leaving the finder open with an error.
    ///
    /// The read happens off the main actor on a detached task — a large file would
    /// otherwise block the UI — and the buffer is applied back on the main actor.
    private func load(_ url: URL) {
        // Auto-save the outgoing buffer before swapping in the new file. This now
        // goes through the conflict-guarded auto-save path, so an externally-changed
        // file is surfaced rather than clobbered.
        if isDirty, loadedURL != nil {
            save(interactive: false)
        }

        // Size guard before we even touch the bytes.
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > Self.maxEditableBytes {
            presentFinder(error: "“\(url.lastPathComponent)” is too large to edit (over 10 MB).")
            return
        }

        Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: url)
                }.value
                if looksBinary(data) {
                    presentFinder(error: "“\(url.lastPathComponent)” looks like a binary file.")
                    return
                }
                let (contents, encoding) = decode(data)
                applyLoadedFile(url: url, contents: contents, encoding: encoding)
            } catch {
                handleLoadFailure(url: url, error: error)
            }
        }
    }

    /// Decode raw bytes, preferring UTF-8 and falling back to Latin-1 (which never
    /// fails), reporting which encoding won so the eventual write can preserve it.
    private func decode(_ data: Data) -> (String, String.Encoding) {
        if let utf8 = String(data: data, encoding: .utf8) {
            return (utf8, .utf8)
        }
        return (String(data: data, encoding: .isoLatin1) ?? "", .isoLatin1)
    }

    /// Commit a successfully-read file into the editor on the main actor. Sets the
    /// loading flag around the programmatic `text` assignment so the text observer
    /// doesn't mark the buffer dirty, and snapshots the on-disk mod date as the
    /// baseline for the external-change conflict guard.
    private func applyLoadedFile(url: URL, contents: String, encoding: String.Encoding) {
        isLoading = true
        text = contents
        loadedURL = url
        fileEncoding = encoding
        language = CodeLanguage.detectLanguageFrom(url: url)
        diskModificationDate = modificationDate(of: url)
        state.filePath = url.path
        // Persist the open-file path immediately so it survives relaunch even
        // before the container's next autosave tick, matching the explicit-save
        // idiom used elsewhere (e.g. Pane.setCurrentDirectory).
        _ = state.modelContext?.saveReporting(operation: "Saving editor file state")
        isDirty = false
        errorMessage = nil
        showFinder = false
        // A successful load means the user interacted with this pane; claim
        // selection so the gated ⌘S/⌘P/⌘O shortcuts target it.
        onSelect()
        // Clear the loading flag only after isDirty has settled, on the next tick,
        // so the trailing text observer fired by the assignment above is ignored.
        DispatchQueue.main.async { isLoading = false }
    }

    /// Handle a failed read. If the file that failed is the one persisted in state,
    /// clear the stale path so we don't keep trying to reopen a moved/deleted file
    /// on every relaunch, then fall back to the finder with the error.
    private func handleLoadFailure(url: URL, error: Error) {
        if url == state.fileURL {
            state.filePath = ""
            _ = state.modelContext?.saveReporting(operation: "Saving editor file state")
        }
        presentFinder(error: "Couldn't open “\(url.lastPathComponent)”: \(error.localizedDescription)")
    }

    /// Re-read the file from disk, discarding the in-memory buffer. Clears the dirty
    /// flag first so `load`'s auto-save guard doesn't fire and re-write what we're
    /// about to throw away.
    private func reloadFromDisk(_ url: URL) {
        isDirty = false
        load(url)
    }

    /// Surface a load failure and fall back to the finder, making sure the index
    /// is being built (the initial `load` on appear bypasses `openFinder`, so the
    /// finder could otherwise come up without any indexing kicked off).
    private func presentFinder(error: String) {
        errorMessage = error
        if let rootPath { finder.start(root: rootPath) }
        showFinder = true
    }

    /// Heuristic binary sniff over the first ~8KB: a NUL byte, or more than ~30% of
    /// the bytes being non-text control characters (everything below 0x20 except
    /// tab/LF/CR). Allocation-light — iterates the prefix slice without copying.
    private func looksBinary(_ data: Data) -> Bool {
        let sample = data.prefix(8192)
        guard !sample.isEmpty else { return false }
        var controlCount = 0
        for byte in sample {
            if byte == 0x00 { return true }
            // Control characters excluding tab (0x09), LF (0x0A), CR (0x0D).
            if byte < 0x09 || byte == 0x0B || byte == 0x0C || (byte >= 0x0E && byte <= 0x1F) {
                controlCount += 1
            }
        }
        return controlCount * 10 > sample.count * 3   // > 30% control bytes
    }

    // MARK: - Saving

    /// The on-disk modification date of `url`, or nil if it can't be read.
    private func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Save the buffer, guarding against blind-overwriting external changes. Agents
    /// running in sibling terminal panes routinely rewrite the same files, so before
    /// writing we compare the file's current mod date against the one snapshotted at
    /// load: if they differ, an interactive save (⌘S) raises a conflict alert and an
    /// auto-save bails with a visible banner — neither overwrites silently.
    private func save(interactive: Bool) {
        guard let url = loadedURL else { return }
        if diskModificationDate != nil, modificationDate(of: url) != diskModificationDate {
            if interactive {
                conflictPresented = true
            } else {
                errorMessage = "“\(url.lastPathComponent)” changed on disk — not auto-saved."
            }
            return
        }
        writeBuffer(to: url)
    }

    /// Unconditionally write the buffer to `url` (symlink-resolved, atomic, encoding
    /// preserved). Used directly by the conflict alert's Overwrite action and by the
    /// guarded `save(interactive:)` once the conflict check passes.
    private func writeBuffer(to url: URL) {
        let target = url.resolvingSymlinksInPath()
        do {
            let data = text.data(using: fileEncoding) ?? text.data(using: .utf8)
            try data?.write(to: target, options: .atomic)
            isDirty = false
            errorMessage = nil
            // Re-baseline so our own write doesn't read back as an external change.
            diskModificationDate = modificationDate(of: target)
        } catch {
            errorMessage = "Couldn't save “\(url.lastPathComponent)”: \(error.localizedDescription)"
        }
    }

    private func saveIfDirty() {
        guard isDirty, loadedURL != nil else { return }
        save(interactive: false)
    }

    // MARK: - Key monitor (arrow nav fallback)

    /// Installs a local key-down monitor for up/down arrows while the finder is
    /// open and this pane is the active, selected one. The focused search field
    /// consumes arrow keys before SwiftUI's `.onKeyPress` sees them, so we intercept
    /// here and return `nil` to swallow the event. Return/Escape still flow through
    /// `.onKeyPress`.
    ///
    /// The monitor's *liveness* is owned by the `onChange(of: isActive)` and
    /// `onChange(of: isSelected)` removals, not by the closure: the `isActive` /
    /// `isSelected` values captured here are install-time snapshots (this is a
    /// value-type view, so `self` doesn't see later updates) and must not be relied
    /// on to decide whether to keep handling events. The only live guard inside is
    /// `self.showFinder`, which reads through to current @State.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Live guard only; selection/activity changes tear the monitor down via
            // the onChange handlers above.
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
