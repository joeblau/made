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
    /// The results list's natural height, so the results card hugs a short
    /// list instead of stretching to its cap (see `resultsList`).
    @State private var finderListHeight: CGFloat?
    @FocusState private var searchFocused: Bool

    // Arrow-key fallback for the finder; see `installKeyMonitor()`.
    @State private var keyMonitor: Any?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Quick open floats like Spotlight, so the results card uses the panel
    /// radius; result highlights nest concentrically inside it (LAY-4).
    private static let finderCornerRadius = LiquidGlassMetrics.Radius.panel
    /// The gap between the search capsule and the results card. The glass
    /// container's blend spacing stays below it, so the two shapes read as
    /// separate pieces at rest, Spotlight-style.
    private static let finderSectionSpacing = LiquidGlassMetrics.Spacing.small
    private static let finderGlassBlendSpacing = LiquidGlassMetrics.Spacing.xSmall
    private static let finderRowInset = LiquidGlassMetrics.Spacing.xSmall
    /// Results up to this count render in an eager stack (see `resultsList`);
    /// it is above what the 360pt palette shows without scrolling.
    private static let finderEagerRowLimit = 24
    private static let finderRowCornerRadius = LiquidGlassMetrics.Radius.inner(
        outer: finderCornerRadius,
        padding: finderRowInset
    )

    /// The banner's dismiss target is a circle; the banner corner wraps it at
    /// the same inset so the two stay concentric (LAY-4).
    private static let bannerDismissSize: CGFloat = 24
    private static let bannerInset = LiquidGlassMetrics.Spacing.xSmall
    private static let bannerCornerRadius = bannerDismissSize / 2 + bannerInset

    var body: some View {
        ZStack {
            editorLayer

            // Each overlay animates inside its own wrapper so the spring never
            // leaks into the editor layer (a reloaded document must not fade).
            ZStack {
                // Save failures must stay visible while editing, not only in the finder.
                if session.document != nil, let errorMessage = session.errorMessage {
                    errorBanner(errorMessage)
                        .transition(overlayTransition(edge: .top))
                }
            }
            .animation(reduceMotion ? nil : LiquidGlassMetrics.spring, value: session.errorMessage)

            ZStack {
                if showFinder {
                    finderOverlay
                        .transition(overlayTransition(scale: 0.98))
                }
            }
            .animation(reduceMotion ? nil : LiquidGlassMetrics.spring, value: showFinder)

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

    /// No buffer and no finder: name the state and offer the one next action
    /// (MOT-6), keeping the ⌘P hint as the description.
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No File Open", systemImage: "curlybraces")
        } description: {
            Text("⌘P to find a file")
        } actions: {
            Button("Find File…", action: openFinder)
                .compatGlassProminentButtonStyle()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Overlays slide in from their anchored edge, or scale-fade in place, and
    /// fall back to a plain fade under Reduce Motion (MOT-4).
    private func overlayTransition(edge: Edge? = nil, scale: CGFloat = 1) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        if let edge {
            return .move(edge: edge).combined(with: .opacity)
        }
        return .opacity.combined(with: .scale(scale: scale, anchor: .top))
    }

    // MARK: - Finder overlay

    private var finderOverlay: some View {
        // Quick open is a transient control layer over the editor, laid out
        // like Spotlight on macOS 26: the search field is its own glass
        // capsule and the results float as a separate glass card below it
        // (material + shadow before 26). Neither sits on the other, and one
        // container renders and morphs the two glass shapes together.
        CompatGlassContainer(spacing: Self.finderGlassBlendSpacing) {
            VStack(spacing: Self.finderSectionSpacing) {
                // The magnifier and the always-focused capsule identify the
                // field, Spotlight-style.
                TextField("Search files…", text: $searchQuery)
                    .scaledFont(size: 14)
                    .focused($searchFocused)
                    .onKeyPress(.return) { openSelected(); return .handled }
                    .onKeyPress(.escape) { dismissFinder(); return .handled }
                    .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
                    .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
                    .liquidGlassField(systemImage: "magnifyingglass", isFocused: searchFocused)

                // No height frame here: a `maxHeight` frame takes all the
                // height offered, so the card would stretch past short
                // results. The list caps itself and the palette caps the
                // total below.
                resultsBody
                    .clipShape(RoundedRectangle(cornerRadius: Self.finderCornerRadius, style: .continuous))
                    .compatFloatingGlass(
                        in: RoundedRectangle(cornerRadius: Self.finderCornerRadius, style: .continuous)
                    )
            }
        }
        .frame(maxWidth: 520)
        .frame(maxHeight: 360, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, LiquidGlassMetrics.Spacing.small)
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
            finderMessage("Set a workspace root path to browse files.", systemImage: "folder.badge.questionmark")
        } else if let errorMessage = session.errorMessage {
            finderMessage(errorMessage, systemImage: "exclamationmark.triangle")
        } else if finder.isIndexing && finder.results.isEmpty {
            HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
                ProgressView().controlSize(.small)
                Text("Indexing…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(LiquidGlassMetrics.Spacing.medium)
        } else if finder.results.isEmpty {
            finderMessage("No matches", systemImage: "magnifyingglass")
        } else {
            resultsList
        }
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // A short list is laid out eagerly so its measured height is
                // exact; a lazy stack's estimated row heights left the card
                // taller than its rows after a narrowing query. Long lists
                // overflow the cap anyway, so they stay lazy.
                Group {
                    if finder.results.count <= Self.finderEagerRowLimit {
                        VStack(spacing: 0) { resultRows }
                    } else {
                        LazyVStack(spacing: 0) { resultRows }
                    }
                }
                // The results card stands alone, so the top and bottom insets
                // match the side inset and the first and last rows' highlights
                // stay concentric with the card corners (LAY-4).
                .padding(.vertical, Self.finderRowInset)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height
                } action: { height in
                    finderListHeight = height
                }
            }
            // A scroll view takes all the height it is offered, which left a
            // one-result card stretched to the 360pt cap and mostly empty.
            // Cap it at the list's own height so the card grows with the
            // results, Spotlight-style, and scrolls only past the cap.
            .frame(maxHeight: finderListHeight)
            // Keep the scroller on the card's straight edge: a full-height
            // legacy scroller otherwise runs into the rounded corners.
            .contentMargins(.vertical, Self.finderCornerRadius, for: .scrollIndicators)
            .onChange(of: selectedIndex) {
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(selectedIndex, anchor: .center)
                }
            }
        }
    }

    private var resultRows: some View {
        ForEach(Array(finder.results.enumerated()), id: \.element.id) { index, item in
            // A real button so each row has hover/press feedback (BTN-5) and
            // reads as actionable to VoiceOver.
            Button {
                selectedIndex = index
                openSelected()
            } label: {
                resultRow(item, isHighlighted: index == selectedIndex)
            }
            .buttonStyle(.liquidGlassPressable(cornerRadius: Self.finderRowCornerRadius))
            .padding(.horizontal, Self.finderRowInset)
            .id(index)
        }
    }

    private func resultRow(_ item: FileItem, isHighlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name)
                .scaledFont(size: 13)
                .foregroundStyle(.primary)
                .lineLimit(1)
            let directory = directoryPortion(of: item.relativePath)
            if !directory.isEmpty {
                Text(directory)
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, LiquidGlassMetrics.Spacing.small)
        .padding(.vertical, LiquidGlassMetrics.Spacing.xSmall)
        .background(
            isHighlighted
                ? Color.accentColor.opacity(0.22)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: Self.finderRowCornerRadius, style: .continuous)
        )
        .animation(LiquidGlassMetrics.stateChange, value: isHighlighted)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    /// Compact, palette-sized status: a quiet symbol anchors the message so
    /// empty and error states read at a glance (MOT-6, HIER-3).
    private func finderMessage(_ message: String, systemImage: String) -> some View {
        VStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
            Image(systemName: systemImage)
                .scaledFont(size: 20, weight: .light)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(message)
                .foregroundStyle(.secondary)
        }
        // Width only: the card hugs the message, like a short results list.
        .frame(maxWidth: .infinity)
        .padding(LiquidGlassMetrics.Spacing.medium)
    }

    // MARK: - Error banner

    /// Compact, dismissible banner pinned to the top of the editor. Surfaces ⌘S /
    /// auto-save failures (and load errors) without stealing the buffer.
    ///
    /// The banner floats over the buffer, so it is the glass layer; its dismiss
    /// control stays a plain circle with hover/press feedback inside it rather
    /// than a second glass shape (no glass on glass, BTN-5).
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(message)
                .scaledFont(size: 12)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: LiquidGlassMetrics.Spacing.xSmall)
            Button {
                session.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: Self.bannerDismissSize, height: Self.bannerDismissSize)
            }
            .buttonStyle(.liquidGlassPressable(cornerRadius: Self.bannerDismissSize / 2))
            .help("Dismiss")
            .accessibilityLabel("Dismiss error")
        }
        .padding(.leading, LiquidGlassMetrics.Spacing.small)
        .padding(.trailing, Self.bannerInset)
        .padding(.vertical, Self.bannerInset)
        .compatFloatingGlass(in: RoundedRectangle(cornerRadius: Self.bannerCornerRadius, style: .continuous))
        .padding(.horizontal, LiquidGlassMetrics.Spacing.small)
        .padding(.top, LiquidGlassMetrics.Spacing.small)
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
