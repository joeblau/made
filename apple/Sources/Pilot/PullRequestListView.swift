import AppKit
import SwiftUI

/// The inspector's tab selector — SwiftUI's rounded segmented control. It fills
/// the inspector width and compresses labels as the column narrows.
struct InspectorTabSelector: View {
    @Binding var selection: InspectorTab

    var body: some View {
        Picker("View", selection: $selection) {
            ForEach(InspectorTab.allCases, id: \.self) { tab in
                Label(tab.rawValue, systemImage: tab.systemImageName).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .font(.title3)
        .labelsHidden()
    }
}

/// One geometry for the metadata row directly beneath every inspector tab.
/// Keeping this shared prevents icon, title, and refresh controls from shifting
/// when the user switches between Actions, Tasks, PRs, Files, and Usage.
struct InspectorSectionHeader: View {
    let title: String
    let systemImage: String
    var titleDesign: Font.Design = .default
    var isLoading = false
    var refreshHelp: String?
    var isRefreshDisabled = false
    var refresh: (() -> Void)?

    var body: some View {
        HStack(spacing: LiquidGlassMetrics.Spacing.xSmall) {
            // `.subheadline` is 11pt on macOS and follows the inspector's
            // `uiZoomedDynamicType` ladder like the title beside it (TYPE-4).
            Image(systemName: systemImage)
                .font(.subheadline.weight(.medium))
                .frame(width: 16)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(.callout, design: titleDesign, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            if isLoading, refresh == nil {
                ProgressView()
                    .controlSize(.mini)
            }

            Spacer(minLength: LiquidGlassMetrics.Spacing.xSmall)

            if let refresh {
                refreshButton(action: refresh)
            } else {
                // Reserve the refresh slot so a header without one (Files)
                // keeps the same height as every other tab's header.
                refreshButton(action: {})
                    .hidden()
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(.secondary)
        // No filled box: a tinted header directly above tinted cards read as
        // boxes inside boxes (LAY-1). 16pt lines the glyph up with the
        // Files outline's disclosure column and the cards' leading icons.
        .padding(.horizontal, LiquidGlassMetrics.Spacing.medium)
        .padding(.top, LiquidGlassMetrics.Spacing.xSmall)
        .padding(.bottom, LiquidGlassMetrics.Spacing.xxSmall)
        .frame(maxWidth: .infinity)
    }

    /// Icon-only glass circle (BTN-5). While a refresh runs the spinner
    /// replaces the glyph inside the same control, so the feedback appears
    /// exactly where the user just clicked and nothing shifts.
    private func refreshButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text(refreshHelp ?? "Refresh")
            } icon: {
                InspectorRefreshGlyph(isRefreshing: isLoading)
            }
        }
        .compatGlassIconButton(controlSize: .small)
        .disabled(isRefreshDisabled || isLoading)
        .help(refreshHelp ?? "Refresh")
    }
}

/// The refresh symbol, swapped in place for a spinner while a refresh runs.
/// The symbol keeps its layout slot (only its opacity changes), so a glass
/// button built around it never changes size mid-refresh (MOT-5).
struct InspectorRefreshGlyph: View {
    let isRefreshing: Bool

    var body: some View {
        Image(systemName: "arrow.clockwise")
            .opacity(isRefreshing ? 0 : 1)
            .overlay {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                        .transition(.opacity)
                }
            }
            .animation(LiquidGlassMetrics.stateChange, value: isRefreshing)
    }
}

/// The "•" between inspector metadata values. Values themselves sit at
/// `.secondary`: they carry real information (number, author, age), so they
/// must not drop to `.tertiary` on top of a card fill (TYPE-3); only the
/// separator recedes.
struct InspectorMetadataSeparator: View {
    var body: some View {
        Text("•")
            .font(.subheadline)
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

/// Inspector card geometry. Cards are content, not controls: a quiet
/// semantic fill with no glass and no border (LAY-1/LAY-2), 4pt-grid padding
/// (LAY-3), and the shared card radius token. A whole-card hover wash uses the
/// same radius, so it lines up with the card edge exactly (LAY-4).
enum InspectorCardMetrics {
    static let padding = LiquidGlassMetrics.Spacing.small
    static let cornerRadius = LiquidGlassMetrics.Radius.card
}

extension View {
    /// A non-interactive inspector card: surface plus the insert/remove
    /// transition. Interactive cards apply `inspectorCardSurface()` inside a
    /// `Button` label and `inspectorCardTransition()` outside it.
    func inspectorListCard() -> some View {
        inspectorCardSurface()
            .inspectorCardTransition()
    }

    func inspectorCardSurface() -> some View {
        padding(InspectorCardMetrics.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                .quaternary.opacity(0.4),
                in: RoundedRectangle(cornerRadius: InspectorCardMetrics.cornerRadius, style: .continuous)
            )
    }

    func inspectorCardTransition() -> some View {
        transition(
            .opacity.combined(
                with: .scale(scale: 0.96, anchor: .top)
            )
        )
    }

    /// Animate identity changes in inspector card collections while leaving
    /// content-only refreshes (elapsed time, status, usage, and so on) alone.
    func inspectorListAnimation<Value: Equatable>(value: Value) -> some View {
        modifier(InspectorListAnimationModifier(value: value))
    }
}

private struct InspectorListAnimationModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let value: Value

    func body(content: Content) -> some View {
        content.animation(
            reduceMotion ? nil : .snappy(duration: 0.28),
            value: value
        )
    }
}

/// Skeleton cards for an inspector list's first load (MOT-5): the shape of
/// the content that is coming, gently pulsing, instead of a lone spinner.
/// Motion stops under Reduce Motion; VoiceOver reads a single "Loading".
struct InspectorLoadingPlaceholder: View {
    var rowCount = 4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDimmed = false

    var body: some View {
        VStack(spacing: LiquidGlassMetrics.Spacing.small) {
            ForEach(0..<rowCount, id: \.self) { index in
                HStack(alignment: .top, spacing: LiquidGlassMetrics.Spacing.xSmall) {
                    Circle()
                        .frame(width: 12, height: 12)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        // Varied widths so the skeleton doesn't read as one
                        // repeated row (HIER-5).
                        Text(verbatim: index.isMultiple(of: 2)
                             ? "Placeholder issue title text"
                             : "Placeholder title")
                            .font(.callout)
                        Text(verbatim: "#0000 • someone • 1h")
                            .font(.subheadline)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.quaternary)
                .redacted(reason: .placeholder)
                .inspectorCardSurface()
            }
        }
        .padding(LiquidGlassMetrics.Spacing.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(isDimmed ? 0.5 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                isDimmed = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}

struct InspectorPanelView: View {
    let gitStore: RepositoryStore
    let tasksStore: GitHubTasksStore
    let usageStore: UsageStore
    @Binding var selectedTab: InspectorTab

    var body: some View {
        VStack(spacing: 0) {
            InspectorTabSelector(selection: $selectedTab)
                .padding(.horizontal, LiquidGlassMetrics.Spacing.xSmall)
                .padding(.vertical, LiquidGlassMetrics.Spacing.xSmall)

            // Expand the tab content to fill the inspector's height. Without
            // this, an intrinsically-sized tab (e.g. an empty-state
            // ContentUnavailableView) lets the whole VStack shrink and float
            // to the vertical center, dragging the picker mid-pane.
            Group {
                switch selectedTab {
                case .actions:
                    ActionsListView(store: gitStore)
                case .tasks:
                    GitHubTasksView(store: tasksStore)
                case .pullRequests:
                    PullRequestListView(store: gitStore)
                case .filesystem:
                    FilesystemListView(store: gitStore)
                case .usage:
                    UsageListView(store: usageStore)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .uiZoomedDynamicType()
    }
}

// MARK: - Filesystem (workspace root project tree)

struct FilesystemListView: View {
    let store: RepositoryStore

    var body: some View {
        if store.filesystem.isEmpty && !store.isLoadingFilesystem {
            ContentUnavailableView("No Files",
                                   systemImage: "folder",
                                   description: Text("Select a workspace with a git repo root path."))
        } else {
            VStack(spacing: 0) {
                if !store.repoPath.isEmpty {
                    rootHeader
                }

                FileSystemOutlineView(entries: store.filesystem, rootPath: store.repoPath)
            }
        }
    }

    private var rootHeader: some View {
        InspectorSectionHeader(
            title: store.repoPath,
            systemImage: "folder",
            titleDesign: .monospaced
        )
    }
}

private struct FileSystemOutlineView: NSViewRepresentable {
    @Environment(\.uiZoom) private var uiZoom

    let entries: [FileSystemEntry]
    let rootPath: String

    func makeCoordinator() -> Coordinator {
        Coordinator(entries: entries, rootPath: rootPath, uiZoom: uiZoom)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let outlineView = ClickableFileSystemOutlineView()
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.focusRingType = .none
        outlineView.backgroundColor = .clear
        outlineView.selectionHighlightStyle = .none
        outlineView.rowSizeStyle = .small
        outlineView.intercellSpacing = NSSize(width: 0, height: 2)
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.floatsGroupRows = false
        outlineView.indentationPerLevel = 14
        outlineView.delegate = context.coordinator
        outlineView.dataSource = context.coordinator

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FileSystemColumn"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        scrollView.documentView = outlineView
        context.coordinator.reload(
            outlineView: outlineView,
            entries: entries,
            rootPath: rootPath,
            uiZoom: uiZoom
        )
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let outlineView = nsView.documentView as? NSOutlineView else { return }
        context.coordinator.reload(
            outlineView: outlineView,
            entries: entries,
            rootPath: rootPath,
            uiZoom: uiZoom
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        private var nodes: [FileSystemNode]
        private var expandedIDs: Set<String> = []
        private var rootURL: URL
        private var rowFont: NSFont

        init(entries: [FileSystemEntry], rootPath: String, uiZoom: Double) {
            self.nodes = entries.map(FileSystemNode.init(entry:))
            self.rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            self.rowFont = Self.fileTreeFont(uiZoom: uiZoom)
        }

        func reload(
            outlineView: NSOutlineView,
            entries: [FileSystemEntry],
            rootPath: String,
            uiZoom: Double
        ) {
            let newRootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            if rootURL.path == newRootURL.path {
                captureExpandedIDs(from: outlineView)
            } else {
                expandedIDs.removeAll()
            }
            rootURL = newRootURL
            nodes = entries.map(FileSystemNode.init(entry:))
            rowFont = Self.fileTreeFont(uiZoom: uiZoom)
            outlineView.rowHeight = max(
                20,
                ceil(rowFont.ascender - rowFont.descender + rowFont.leading) + 4
            )
            outlineView.reloadData()
            restoreExpandedNodes(in: outlineView, nodes: nodes)
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            children(for: item).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            children(for: item)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? FileSystemNode else { return false }
            return node.isExpandable
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            false
        }

        func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
            guard let node = item as? FileSystemNode else { return false }
            loadChildrenIfNeeded(for: node)
            outlineView.reloadItem(node, reloadChildren: true)
            return node.isExpandable
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? FileSystemNode else { return nil }

            let identifier = NSUserInterfaceItemIdentifier("FileSystemCell")
            let view = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? FileSystemOutlineCellView)
                ?? FileSystemOutlineCellView()
            view.identifier = identifier
            view.configure(with: node.entry, font: rowFont)
            return view
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? FileSystemNode else { return }
            expandedIDs.insert(node.entry.id)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? FileSystemNode else { return }
            expandedIDs.remove(node.entry.id)
        }

        private func children(for item: Any?) -> [FileSystemNode] {
            guard let node = item as? FileSystemNode else { return nodes }
            return node.children
        }

        private func captureExpandedIDs(from outlineView: NSOutlineView) {
            expandedIDs.removeAll(keepingCapacity: true)

            for row in 0..<outlineView.numberOfRows {
                guard let node = outlineView.item(atRow: row) as? FileSystemNode,
                      outlineView.isItemExpanded(node) else { continue }
                expandedIDs.insert(node.entry.id)
            }
        }

        private func restoreExpandedNodes(in outlineView: NSOutlineView, nodes: [FileSystemNode]) {
            for node in nodes {
                restoreExpandedNode(node, in: outlineView)
            }
        }

        private func restoreExpandedNode(_ node: FileSystemNode, in outlineView: NSOutlineView) {
            guard node.entry.isDirectory else { return }

            if expandedIDs.contains(node.entry.id) {
                loadChildrenIfNeeded(for: node)
                outlineView.expandItem(node)
            }

            for child in node.children {
                restoreExpandedNode(child, in: outlineView)
            }
        }

        private func loadChildrenIfNeeded(for node: FileSystemNode) {
            guard node.entry.isDirectory, !node.hasLoadedChildren else { return }
            let directoryURL = URL(fileURLWithPath: node.entry.path, isDirectory: true)
            let entries = RepositoryStore.listFilesystemEntries(at: directoryURL, rootURL: rootURL)
            node.children = entries.map(FileSystemNode.init(entry:))
            node.hasLoadedChildren = true
        }

        private static func fileTreeFont(uiZoom: Double) -> NSFont {
            let preferredFont = NSFont.preferredFont(forTextStyle: .callout)
            return NSFontManager.shared.convert(
                preferredFont,
                toSize: preferredFont.pointSize * CGFloat(uiZoom)
            )
        }
    }
}

/// `NSOutlineView` only expands a row when its small disclosure control is
/// clicked. The filesystem deliberately disables selection, so make the rest
/// of a folder row behave like that disclosure control as well.
private final class ClickableFileSystemOutlineView: NSOutlineView {
    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: location)
        let clickedDisclosure = clickedRow >= 0
            && frameOfOutlineCell(atRow: clickedRow).contains(location)

        // Preserve AppKit's native disclosure-button behavior and normal
        // handling for files, blank space, and multi-click gestures.
        super.mouseDown(with: event)

        guard event.clickCount == 1,
              clickedRow >= 0,
              !clickedDisclosure,
              let node = item(atRow: clickedRow) as? FileSystemNode,
              node.entry.isDirectory else { return }

        if isItemExpanded(node) {
            collapseItem(node)
        } else {
            expandItem(node)
        }
    }
}

private final class FileSystemNode: NSObject {
    let entry: FileSystemEntry
    var children: [FileSystemNode]
    var hasLoadedChildren: Bool

    var isExpandable: Bool {
        entry.isDirectory && (!hasLoadedChildren || !children.isEmpty)
    }

    init(entry: FileSystemEntry) {
        self.entry = entry
        self.children = (entry.children ?? []).map(FileSystemNode.init(entry:))
        self.hasLoadedChildren = entry.children != nil
    }
}

private final class FileSystemOutlineCellView: NSTableCellView {
    private let titleField = NSTextField(labelWithString: "")
    private let iconView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)

        titleField.font = .preferredFont(forTextStyle: .callout)
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(titleField)

        addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])

        imageView = iconView
        textField = titleField
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    func configure(with entry: FileSystemEntry, font: NSFont) {
        titleField.stringValue = entry.name
        titleField.font = font
        toolTip = entry.relativePath
        iconView.image = fileIcon(for: entry.path)
    }

    private func fileIcon(for path: String) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

// MARK: - Pull Requests (gh pr list)

struct PullRequestListView: View {
    let store: RepositoryStore

    var body: some View {
        VStack(spacing: 0) {
            RepositoryTableHeader(
                title: store.repositoryName,
                systemImage: "arrow.triangle.pull",
                refreshHelp: "Refresh pull requests",
                isRefreshDisabled: store.repoPath.isEmpty
            ) {
                store.fetchPullRequests(policy: .manual)
            }

            ZStack {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(store.pullRequests) { pullRequest in
                            pullRequestRow(pullRequest)
                                .inspectorCardTransition()
                        }
                    }
                    .padding(12)
                }

                if store.pullRequests.isEmpty && !store.isLoading {
                    ContentUnavailableView(
                        "No Pull Requests",
                        systemImage: "arrow.triangle.pull",
                        description: Text("Select a workspace with a GitHub repo root path.")
                    )
                    .transition(.opacity)
                }
            }
        }
        .inspectorListAnimation(value: store.pullRequests.map(\.id))
    }

    private func pullRequestRow(_ pullRequest: GitPullRequest) -> some View {
        Button {
            openPullRequestInBrowser(pullRequest)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                pullRequestStateIcon(pullRequest)
                    .frame(width: 14)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(pullRequest.title)
                        .font(.callout)
                        .lineLimit(2)

                    // Number • user • time ago at .secondary with
                    // `InspectorMetadataSeparator` — the metadata styling shared
                    // with the Actions and Tasks tabs.
                    HStack(spacing: 4) {
                        Text("#\(pullRequest.id)")
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if !pullRequest.author.isEmpty {
                            InspectorMetadataSeparator()
                            Text(pullRequest.author)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        if !pullRequest.elapsed.isEmpty {
                            InspectorMetadataSeparator()
                            Text(pullRequest.elapsed)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .inspectorCardSurface()
        }
        // The whole card is the tap target: hover wash + press feedback in
        // the card's own shape (BTN-5), not glass — cards are content.
        .buttonStyle(.liquidGlassPressable(cornerRadius: InspectorCardMetrics.cornerRadius))
        .disabled(pullRequest.url.isEmpty)
        .help(pullRequest.url.isEmpty ? "" : "Open on GitHub")
    }

    private func openPullRequestInBrowser(_ pullRequest: GitPullRequest) {
        guard let url = URL(string: pullRequest.url) else { return }
        NSWorkspace.shared.open(url)
    }

    @ViewBuilder
    private func pullRequestStateIcon(_ pullRequest: GitPullRequest) -> some View {
        switch pullRequest.state {
        case "MERGED":
            CircledStateIcon(systemName: "arrow.triangle.merge", tint: .purple)
        case "CLOSED":
            Image(systemName: "xmark.circle.fill")
                .scaledFont(size: 12)
                .foregroundStyle(.red)
        case "OPEN" where pullRequest.isDraft:
            Image(systemName: "circle.dashed")
                .scaledFont(size: 12)
                .foregroundStyle(.secondary)
        case "OPEN":
            CircledStateIcon(systemName: "arrow.triangle.pull", tint: .green)
        default:
            Image(systemName: "circle")
                .scaledFont(size: 12)
                .foregroundStyle(.quaternary)
        }
    }
}

/// A state glyph knocked out of a filled disc, so the merged and open arrows
/// read as solid badges like the `xmark.circle.fill` state they sit beside.
/// SF Symbols ships no `.circle.fill` variant for `arrow.triangle.pull` or
/// `arrow.triangle.merge`, so the disc is drawn here.
///
/// The glyph takes the window background rather than a fixed black or white.
/// Against a saturated fill that reads as a hole punched through the disc in
/// either appearance — dark grey on dark, near-white on light — where a
/// hardcoded black would sink into the purple merged fill in dark mode.
///
/// Sizing reads `uiZoom` for the same reason `scaledFont` does: the glyph
/// grows with the text-size ladder, and a fixed-point disc would drift out of
/// register with it as soon as the ladder moves off 1.0.
private struct CircledStateIcon: View {
    @Environment(\.uiZoom) private var uiZoom

    let systemName: String
    let tint: Color

    /// 12pt matches the disc `xmark.circle.fill` already draws in this column,
    /// which is what keeps the states aligned. The glyph is inset to leave a
    /// ring of fill around it, and runs bold to hold its counters at this size.
    private var diameter: CGFloat { 12 * uiZoom }
    private var glyphSize: CGFloat { 7.5 * uiZoom }

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: glyphSize, weight: .bold))
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(tint))
    }
}

// MARK: - Actions (GitHub Actions workflow runs)

struct ActionsListView: View {
    let store: RepositoryStore

    var body: some View {
        VStack(spacing: 0) {
            RepositoryTableHeader(
                title: store.repositoryName,
                systemImage: "folder",
                refreshHelp: "Refresh actions",
                isRefreshDisabled: store.repoPath.isEmpty
            ) {
                store.fetchWorkflowRuns(policy: .manual)
            }

            ZStack {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(store.actions) { action in
                            actionRow(action)
                                .inspectorCardTransition()
                        }
                    }
                    .padding(12)
                }

                if store.actions.isEmpty && !store.isLoading {
                    ContentUnavailableView(
                        "No Actions",
                        systemImage: "gearshape.2",
                        description: Text("Select a workspace with a GitHub repo root path.")
                    )
                    .transition(.opacity)
                }
            }
        }
        .inspectorListAnimation(value: store.actions.map(\.id))
    }

    private func actionRow(_ action: GitAction) -> some View {
        Button {
            openActionInBrowser(action)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                actionStatusIcon(action.conclusion, status: action.status)
                    .frame(width: 14)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(action.displayTitle)
                        .font(.callout)
                        .lineLimit(2)

                    HStack(spacing: 4) {
                        Text(action.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        InspectorMetadataSeparator()
                        Text(action.headBranch)
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 4) {
                        Text(String(action.headSha.prefix(7)))
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(.secondary)
                        // Hash • user • duration • time ago.
                        if !action.actor.isEmpty {
                            InspectorMetadataSeparator()
                            Text(action.actor)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        if !action.duration.isEmpty {
                            InspectorMetadataSeparator()
                            Text(action.duration)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                        if !action.elapsed.isEmpty {
                            InspectorMetadataSeparator()
                            Text(action.elapsed)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .inspectorCardSurface()
        }
        .buttonStyle(.liquidGlassPressable(cornerRadius: InspectorCardMetrics.cornerRadius))
        .disabled(action.url.isEmpty)
        .help(action.url.isEmpty ? "" : "Open on GitHub")
    }

    private func openActionInBrowser(_ action: GitAction) {
        guard let url = URL(string: action.url) else { return }
        NSWorkspace.shared.open(url)
    }

    @ViewBuilder
    private func actionStatusIcon(_ conclusion: String, status: String) -> some View {
        switch conclusion {
        case "success":
            Image(systemName: "checkmark.circle.fill")
                .scaledFont(size: 12)
                .foregroundStyle(.green)
        case "failure":
            Image(systemName: "xmark.circle.fill")
                .scaledFont(size: 12)
                .foregroundStyle(.red)
        case "cancelled":
            Image(systemName: "slash.circle.fill")
                .scaledFont(size: 12)
                .foregroundStyle(.secondary)
        default:
            switch status {
            case "in_progress":
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(.orange)
                    .colorMultiply(.orange)
            case "queued", "waiting", "pending":
                Image(systemName: "clock.circle")
                    .scaledFont(size: 12)
                    .foregroundStyle(.yellow)
            default:
                Image(systemName: "circle")
                    .scaledFont(size: 12)
                    .foregroundStyle(.quaternary)
            }
        }
    }
}

private struct RepositoryTableHeader: View {
    let title: String
    let systemImage: String
    let refreshHelp: String
    let isRefreshDisabled: Bool
    let refresh: () -> Void

    var body: some View {
        InspectorSectionHeader(
            title: title,
            systemImage: systemImage,
            refreshHelp: refreshHelp,
            isRefreshDisabled: isRefreshDisabled,
            refresh: refresh
        )
    }
}
