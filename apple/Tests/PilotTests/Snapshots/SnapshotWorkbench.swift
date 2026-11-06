import AppKit
@testable import Pilot

/// Native capture composition of production panels and fictional engine views.
/// It never creates live terminal, browser, remote-frame or device sessions.
final class SnapshotWorkbench: NSViewController {
    let scene: SnapshotScene
    let fixtures: SnapshotFixtures

    init(scene: SnapshotScene, fixtures: SnapshotFixtures) {
        self.scene = scene
        self.fixtures = fixtures
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = SnapshotBackgroundView(color: .windowBackgroundColor)
        let header = titleBar()
        header.heightAnchor.constraint(equalToConstant: 52).isActive = true
        let sidebar = sidebar()
        sidebar.widthAnchor.constraint(equalToConstant: 208).isActive = true
        let detail = detail()
        var columns: [NSView] = [sidebar, SnapshotUI.divider(vertical: true), detail]
        if let tab = scene.inspector, let workspace = fixtures.workspace.workspaces.first {
            let inspector = InspectorViewController(
                workspace: workspace, usageStore: fixtures.usage,
                gitStore: fixtures.repository, tasksStore: fixtures.tasks,
                defaults: fixtures.defaults, isLive: false
            )
            inspector.selectTab(tab)
            let panel = attach(inspector)
            panel.widthAnchor.constraint(equalToConstant: 360).isActive = true
            columns += [SnapshotUI.divider(vertical: true), panel]
        }
        let body = SnapshotUI.stack(.horizontal, columns, spacing: 0)
        body.alignment = .top
        for column in columns { column.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true }
        let rows: [NSView] = [header, SnapshotUI.divider(), body]
        let root = SnapshotUI.stack(.vertical, rows, spacing: 0)
        SnapshotUI.expand(rows, in: root)
        SnapshotUI.pin(root, in: view)
    }

    private func attach(_ controller: NSViewController) -> NSView {
        addChild(controller)
        controller.view.clipsToBounds = true
        return controller.view
    }

    private func titleBar() -> NSView {
        let traffic = SnapshotUI.stack(.horizontal, [
            SnapshotUI.label("●", size: 16, color: .systemRed),
            SnapshotUI.label("●", size: 16, color: .systemYellow),
            SnapshotUI.label("●", size: 16, color: .systemGreen),
        ], spacing: 7)
        var items: [NSView] = [
            traffic, SnapshotUI.symbol("sidebar.left"), SnapshotUI.label(scene.title, weight: .semibold),
            SnapshotUI.spacer(),
        ]
        if scene.selection == nil {
            let field = SnapshotUI.card(SnapshotUI.label("Fast Command", size: 12, color: .secondaryLabelColor, mono: true), inset: 8)
            field.widthAnchor.constraint(equalToConstant: 230).isActive = true
            items += [field, SnapshotUI.symbol("play.fill"), SnapshotUI.spacer()]
        }
        items.append(SnapshotUI.stack(.horizontal, ["terminal", "safari", "apple.logo", "curlybraces", "folder", "sidebar.right"].map {
            SnapshotUI.symbol($0, size: 15)
        }, spacing: 18))
        return SnapshotUI.stack(.horizontal, items, spacing: 18, padding: 12)
    }

    private func sidebar() -> NSView {
        var rows: [NSView] = []
        for item in [SnapshotScene.notes, .remoteDesktop, .docker, .agenticUse, .runners] {
            let selected = scene == item
            let row = SnapshotUI.stack(.horizontal, [
                SnapshotUI.symbol(symbol(for: item), color: selected ? .white : .controlAccentColor),
                SnapshotUI.label(item.title, weight: selected ? .semibold : .medium, color: selected ? .white : .labelColor),
                SnapshotUI.spacer(),
            ], spacing: 9)
            rows.append(SnapshotUI.card(row, tint: selected ? .controlAccentColor : .clear, inset: 8))
        }
        for (title, pinned) in [("Pinned", true), ("Workspaces", false)] {
            rows.append(SnapshotUI.label(title, size: 11, weight: .semibold, color: .secondaryLabelColor))
            for workspace in fixtures.workspace.workspaces.filter({ $0.isPinned == pinned }) {
                let text = SnapshotUI.stack(.vertical, [
                    SnapshotUI.label(workspace.name, size: 13, weight: .medium),
                    SnapshotUI.label(workspace.name == "orbit-web" ? "feat/activity-timeline" : "main",
                                     size: 10, color: .secondaryLabelColor),
                ], spacing: 4)
                let row = SnapshotUI.stack(.horizontal, [text, SnapshotUI.spacer()])
                if workspace.isPinned { row.addArrangedSubview(SnapshotUI.label("1/2", size: 10, color: .controlAccentColor)) }
                let selected = scene.selection == nil && workspace.name == scene.title
                rows.append(SnapshotUI.card(row, tint: selected ? .labelColor.withAlphaComponent(0.09) : .clear, inset: 9))
            }
        }
        rows.append(SnapshotUI.spacer())
        rows.append(SnapshotUI.stack(.horizontal, [
            SnapshotUI.symbol("mic", size: 12), SnapshotUI.symbol("cup.and.saucer", size: 12),
            SnapshotUI.spacer(), SnapshotUI.symbol("iphone", size: 12), SnapshotUI.symbol("ipad", size: 12),
            SnapshotUI.label("●", size: 10, color: .systemGreen),
        ], spacing: 15))
        let content = SnapshotUI.stack(.vertical, rows, spacing: 8, padding: 10)
        SnapshotUI.expand(rows, in: content)
        return SnapshotUI.card(content, tint: .labelColor.withAlphaComponent(0.035), inset: 0)
    }

    private func symbol(for scene: SnapshotScene) -> String {
        switch scene {
        case .notes: "note.text"
        case .remoteDesktop: "macbook.and.iphone"
        case .docker: "shippingbox"
        case .agenticUse: "chart.bar.xaxis"
        default: "server.rack"
        }
    }

    private func detail() -> NSView {
        switch scene {
        case .notes:
            return notes()
        case .docker:
            return attach(DockerViewController(store: fixtures.docker))
        case .runners:
            fixtures.defaults.set("cards", forKey: "runners.layout")
            return attach(RunnersViewController(store: fixtures.runners, defaults: fixtures.defaults))
        case .agenticUse:
            let range = NSSegmentedControl(labels: ["24h", "7d", "30d", "90d", "All"], trackingMode: .selectOne,
                                           target: nil, action: nil)
            range.selectedSegment = 2
            range.controlSize = .small
            let header = SnapshotUI.stack(.horizontal, [
                SnapshotUI.label("Sep 24 – Oct 23", size: 12, weight: .medium, color: .secondaryLabelColor),
                SnapshotUI.spacer(), range,
            ], padding: 12)
            header.heightAnchor.constraint(equalToConstant: 44).isActive = true
            let dashboard = AgenticUseDashboard(snapshot: fixtures.history, pricingStatus: "Pricing reviewed Oct 23, 2026")
            let scroll = SnapshotDashboardScrollView(dashboard: dashboard)
            let content = SnapshotUI.stack(.vertical, [header, scroll], spacing: 0)
            SnapshotUI.expand([header, scroll], in: content)
            return content
        case .remoteDesktop:
            return SnapshotRemoteDesktop()
        case .editor:
            return pair(
                SnapshotPane(title: "Editor · Sources/Projects.swift", symbol: "curlybraces", content: SnapshotCode()),
                SnapshotPane(title: "Terminal · atlas-api", symbol: "terminal", content: SnapshotTerminal(variant: .tests))
            )
        case .browser:
            return pair(
                SnapshotPane(title: "Terminal · orbit-web", symbol: "terminal", content: SnapshotTerminal(variant: .agent)),
                SnapshotPane(title: "Browser · localhost:3000", symbol: "safari", content: SnapshotWebPreview())
            )
        case .device:
            return pair(
                SnapshotPane(title: "Browser · localhost:3000", symbol: "safari", content: SnapshotWebPreview()),
                SnapshotPane(title: "Device · iPhone", symbol: "iphone", content: SnapshotDevice())
            )
        default:
            return pair(
                SnapshotPane(title: "Terminal · Claude", symbol: "terminal", content: SnapshotTerminal(variant: .agent)),
                SnapshotPane(title: "Terminal · Codex", symbol: "terminal", content: SnapshotTerminal(variant: .review))
            )
        }
    }

    private func pair(_ leading: NSView, _ trailing: NSView) -> NSView {
        let stack = SnapshotUI.stack(.horizontal, [leading, trailing], spacing: 1)
        stack.distribution = .fillEqually
        leading.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true
        trailing.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true
        return stack
    }

    private func notes() -> NSView {
        var tabs: [NSView] = fixtures.workspace.notes.map { note in
            SnapshotUI.card(SnapshotUI.label(note.displayTitle, size: 12, weight: .medium),
                            tint: note.id == fixtures.workspace.selectedNoteID
                                ? .controlAccentColor.withAlphaComponent(0.25) : .labelColor.withAlphaComponent(0.08),
                            inset: 8)
        }
        tabs += [SnapshotUI.symbol("plus.circle.fill"), SnapshotUI.spacer(),
                 SnapshotUI.label("Word Wrap  None ⌃", size: 12, color: .secondaryLabelColor)]
        let header = SnapshotUI.stack(.horizontal, tabs, spacing: 8, padding: 12)
        let warning = SnapshotUI.label(
            "Secret masking is visual only. Notes are stored locally as plaintext—do not use Notes as a secret manager.",
            size: 11, color: .secondaryLabelColor
        )
        let editor = NoteTextView(text: SnapshotFixtures.releaseNote, fontSize: 13, wordWrapColumns: nil)
        let content = SnapshotUI.stack(.vertical, [header, warning, editor], spacing: 6)
        SnapshotUI.expand([header, warning, editor], in: content)
        return content
    }
}

/// Match the production analytics document sizing while keeping the capture's
/// date range and data deterministic.
private final class SnapshotDashboardScrollView: NSScrollView {
    let dashboard: AgenticUseDashboard

    init(dashboard: AgenticUseDashboard) {
        self.dashboard = dashboard
        super.init(frame: .zero)
        hasVerticalScroller = true
        drawsBackground = false
        documentView = dashboard
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let width = contentSize.width
        dashboard.setFrameSize(NSSize(width: width, height: dashboard.contentHeight(for: width)))
        dashboard.needsLayout = true
    }
}

final class SnapshotPane: NSView {
    init(title: String, symbol: String, content: NSView) {
        super.init(frame: .zero)
        let header = SnapshotUI.stack(.horizontal, [
            SnapshotUI.symbol(symbol, size: 13), SnapshotUI.label(title, size: 12, weight: .medium),
            SnapshotUI.spacer(), SnapshotUI.symbol("ellipsis", size: 13),
        ], padding: 12)
        header.heightAnchor.constraint(equalToConstant: 42).isActive = true
        let root = SnapshotUI.stack(.vertical, [header, content], spacing: 0)
        SnapshotUI.expand([header, content], in: root)
        SnapshotUI.pin(root, in: self)
    }

    required init?(coder: NSCoder) { nil }
}
