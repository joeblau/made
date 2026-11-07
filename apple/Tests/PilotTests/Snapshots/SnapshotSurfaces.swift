import AppKit
@testable import Pilot

/// Fictional native previews, never live terminal/browser/capture connections.
@MainActor
enum SnapshotUI {
    static func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor, mono: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = mono ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.maximumNumberOfLines = 0
        field.setContentHuggingPriority(.required, for: .vertical)
        return field
    }

    static func symbol(_ name: String, color: NSColor = .secondaryLabelColor, size: CGFloat = 16) -> NSImageView {
        let image = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
        image.contentTintColor = color
        image.symbolConfiguration = .init(pointSize: size, weight: .regular)
        image.translatesAutoresizingMaskIntoConstraints = false
        image.widthAnchor.constraint(equalToConstant: size + 2).isActive = true
        image.heightAnchor.constraint(equalToConstant: size + 2).isActive = true
        return image
    }

    static func stack(_ orientation: NSUserInterfaceLayoutOrientation, _ views: [NSView],
                      spacing: CGFloat = 12, padding: CGFloat = 0) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = orientation
        stack.distribution = .fill
        stack.clipsToBounds = true
        stack.alignment = orientation == .vertical ? .leading : .centerY
        stack.spacing = spacing
        stack.edgeInsets = NSEdgeInsets(top: padding, left: padding, bottom: padding, right: padding)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        return view
    }

    static func divider(vertical: Bool = false) -> NSView {
        let view = SnapshotBackgroundView(color: .separatorColor)
        view.translatesAutoresizingMaskIntoConstraints = false
        (vertical ? view.widthAnchor : view.heightAnchor).constraint(equalToConstant: 1).isActive = true
        return view
    }

    static func pin(_ child: NSView, in parent: NSView, inset: CGFloat = 0) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
        ])
    }

    static func card(_ child: NSView, tint: NSColor = .controlBackgroundColor, inset: CGFloat = 12) -> NSView {
        let background = SnapshotBackgroundView(color: tint, radius: 10)
        pin(child, in: background, inset: inset)
        return background
    }

    static func expand(_ views: [NSView], in stack: NSStackView) {
        for view in views {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                        constant: -stack.edgeInsets.left - stack.edgeInsets.right).isActive = true
        }
    }
}

final class SnapshotBackgroundView: NSView {
    let color: NSColor
    let radius: CGFloat

    init(color: NSColor, radius: CGFloat = 0) {
        self.color = color
        self.radius = radius
        super.init(frame: .zero)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class SnapshotWebPreview: NSView {
    init(compact: Bool = false) {
        super.init(frame: .zero)
        let header = SnapshotUI.stack(.horizontal, [
            SnapshotUI.symbol("circle.hexagongrid.fill", color: .systemIndigo),
            SnapshotUI.label("orbit", size: compact ? 18 : 23, weight: .bold),
            SnapshotUI.spacer(), SnapshotUI.label("Workspace", size: 11, color: .secondaryLabelColor),
        ])
        let metrics = SnapshotUI.stack(.horizontal, [
            Self.metric("Projects", value: "12", compact: compact),
            Self.metric("In progress", value: "8", compact: compact),
        ])
        metrics.distribution = .fillEqually
        if !compact { metrics.addArrangedSubview(Self.metric("Completed", value: "24", compact: false)) }
        let title = SnapshotUI.stack(.horizontal, [
            SnapshotUI.label("Your projects", weight: .semibold), SnapshotUI.spacer(),
            SnapshotUI.label("+ New project", size: 11, color: .systemIndigo),
        ])
        let colors: [NSColor] = [.systemIndigo, .systemOrange, .systemMint]
        let names = ["Website refresh", "Mobile experience", "Public API"]
        let details = ["Design review", "Ready for testing", "In development"]
        var rows: [NSView] = [header, SnapshotUI.divider(), metrics, title]
        for index in names.indices {
            let row = SnapshotUI.stack(.horizontal, [
                SnapshotUI.symbol(["globe", "iphone", "curlybraces"][index], color: colors[index], size: 24),
                SnapshotUI.stack(.vertical, [
                    SnapshotUI.label(names[index], weight: .semibold),
                    SnapshotUI.label(details[index], size: 10, color: .secondaryLabelColor),
                ], spacing: 4),
                SnapshotUI.spacer(), SnapshotUI.label(["8/12", "14/16", "6/10"][index], size: 11),
            ])
            let progress = NSProgressIndicator()
            progress.isIndeterminate = false
            progress.minValue = 0
            progress.maxValue = 1
            progress.doubleValue = [0.67, 0.87, 0.6][index]
            let content = SnapshotUI.stack(.vertical, [row, progress], spacing: 10)
            SnapshotUI.expand([row, progress], in: content)
            rows.append(SnapshotUI.card(content, tint: .labelColor.withAlphaComponent(0.035), inset: compact ? 10 : 18))
        }
        if !compact {
            rows += [SnapshotUI.label("Recent activity", weight: .semibold),
                     SnapshotUI.label("✓ Sam completed the onboarding flow", size: 12, color: .secondaryLabelColor),
                     SnapshotUI.label("◌ Morgan shared a new design review", size: 12, color: .secondaryLabelColor)]
        }
        rows.append(SnapshotUI.spacer())
        let content = SnapshotUI.stack(.vertical, rows, spacing: compact ? 12 : 18, padding: compact ? 20 : 30)
        SnapshotUI.expand(rows, in: content)
        SnapshotUI.pin(content, in: self)
    }

    required init?(coder: NSCoder) { nil }

    private static func metric(_ title: String, value: String, compact: Bool) -> NSView {
        SnapshotUI.card(SnapshotUI.stack(.vertical, [
            SnapshotUI.symbol("chart.bar", color: .systemIndigo),
            SnapshotUI.label(value, size: compact ? 22 : 28, weight: .semibold),
            SnapshotUI.label(title, size: 10),
        ], spacing: 10), tint: .systemIndigo.withAlphaComponent(0.06))
    }
}

final class SnapshotDevice: NSView {
    init() {
        super.init(frame: .zero)
        let header = SnapshotUI.stack(.horizontal, [
            SnapshotUI.label("iPhone · Orbit", size: 12), SnapshotUI.spacer(),
            SnapshotUI.label("● Connected", size: 12, color: .systemGreen),
        ], padding: 18)
        let status = SnapshotUI.stack(.horizontal, [
            SnapshotUI.label("9:41", size: 10, weight: .semibold), SnapshotUI.spacer(),
            SnapshotUI.symbol("wifi", size: 11), SnapshotUI.symbol("battery.100percent", size: 14),
        ], padding: 18)
        let screen = SnapshotUI.stack(.vertical, [status, SnapshotWebPreview(compact: true)], spacing: 0)
        SnapshotUI.expand(screen.arrangedSubviews, in: screen)
        let phone = SnapshotUI.card(screen, tint: .textBackgroundColor, inset: 7)
        phone.widthAnchor.constraint(equalToConstant: 320).isActive = true
        phone.heightAnchor.constraint(equalToConstant: 700).isActive = true
        let center = SnapshotUI.stack(.horizontal, [SnapshotUI.spacer(), phone, SnapshotUI.spacer()])
        center.distribution = .equalCentering
        let content = SnapshotUI.stack(.vertical, [header, center, SnapshotUI.spacer()], spacing: 12)
        SnapshotUI.expand([header, center], in: content)
        SnapshotUI.pin(content, in: self)
    }

    required init?(coder: NSCoder) { nil }
}

final class SnapshotRemoteDesktop: NSView {
    init() {
        super.init(frame: .zero)
        let header = SnapshotUI.stack(.horizontal, [
            SnapshotUI.label("Development machines", size: 16, weight: .semibold), SnapshotUI.spacer(),
            SnapshotUI.label("4 connected", size: 12, color: .secondaryLabelColor),
        ], padding: 18)
        let names = ["Build Mac", "Linux CI", "Design Mac", "Preview VM"]
        var rows: [NSView] = [header]
        for rowIndex in 0..<2 {
            let cells = (0..<2).map { column -> NSView in
                let index = rowIndex * 2 + column
                let preview = SnapshotUI.stack(.vertical, [
                    SnapshotUI.stack(.horizontal, [
                        SnapshotUI.symbol(index.isMultiple(of: 2) ? "desktopcomputer" : "server.rack", color: .controlAccentColor),
                        SnapshotUI.label(names[index], size: 13, weight: .semibold), SnapshotUI.spacer(),
                        SnapshotUI.label("● Connected", size: 10, color: .systemGreen),
                    ]),
                    SnapshotUI.divider(),
                    SnapshotUI.label(index.isMultiple(of: 2) ? "$ swift test" : "$ bun run build", size: 17, weight: .semibold, mono: true),
                    SnapshotUI.label("~/Projects/orbit-web\n\nBuilding for production…\n\n✓ ProjectRoutesTests\n✓ ActivityEventsTests\n✓ TeamInvitationsTests\n\nAll checks passed.",
                                     size: 12, color: .secondaryLabelColor, mono: true),
                    SnapshotUI.spacer(),
                    SnapshotUI.label(index.isMultiple(of: 2) ? "macOS · Apple silicon" : "Linux · x86_64", size: 10, color: .tertiaryLabelColor),
                ], spacing: 8)
                SnapshotUI.expand(preview.arrangedSubviews, in: preview)
                return SnapshotUI.card(preview, tint: .textBackgroundColor)
            }
            let row = SnapshotUI.stack(.horizontal, cells, spacing: 14)
            row.distribution = .fillEqually
            row.heightAnchor.constraint(equalToConstant: 380).isActive = true
            rows.append(row)
        }
        rows.append(SnapshotUI.spacer())
        let content = SnapshotUI.stack(.vertical, rows, spacing: 14, padding: 12)
        SnapshotUI.expand(rows, in: content)
        SnapshotUI.pin(content, in: self)
    }

    required init?(coder: NSCoder) { nil }
}

final class SnapshotTerminal: NSView {
    enum Variant { case agent, review, tests }

    init(variant: Variant) {
        super.init(frame: .zero)
        let title = variant == .review ? "› Codex" : variant == .tests ? "$ swift test" : "✳ Claude Code"
        var rows: [NSView] = [
            SnapshotUI.label(title, size: 19, weight: .semibold, color: variant == .agent ? .systemOrange : .controlAccentColor, mono: true),
            SnapshotUI.label(variant == .tests ? "~/Projects/atlas-api" : "~/Projects/orbit-web · feat/activity-timeline",
                             size: 12, color: .secondaryLabelColor, mono: true),
            SnapshotUI.divider(),
        ]
        if variant == .tests {
            rows.append(SnapshotUI.label("Building for debugging…\nBuild complete! (1.42s)", size: 12, color: .secondaryLabelColor, mono: true))
            for name in ["ProjectRoutes", "ActivityEvents", "TeamInvitations", "CursorPagination"] {
                rows.append(SnapshotUI.label("✓ \(name)Tests\n  12 tests passed in 0.08 seconds", size: 12, color: .systemGreen, mono: true))
            }
            rows.append(SnapshotUI.label("Test Suite 'All tests' passed\nExecuted 60 tests, with 0 failures.", size: 12, mono: true))
        } else {
            rows += [
                SnapshotUI.label(variant == .agent ? "❯ Build a project activity timeline.\n  Keep filters in sync with the URL." : "❯ Review the activity timeline and\n  add coverage for the new filters.", size: 12, weight: .medium, mono: true),
                SnapshotUI.label("● Read \(variant == .agent ? "3" : "5") files", size: 12, color: .systemCyan, mono: true),
                SnapshotUI.label("  src/components/ActivityTimeline.tsx\n  src/hooks/useProjectEvents.ts\n  tests/activity.test.ts", size: 12, color: .secondaryLabelColor, mono: true),
                SnapshotUI.label(variant == .agent ? "● Updated ActivityTimeline.tsx" : "● Added tests/activity.test.ts", size: 12, color: .systemGreen, mono: true),
                SnapshotUI.card(SnapshotUI.label("+ const events = useProjectEvents(id)\n+ const visible = filterEvents(events)\n+ return <Timeline events={visible} />", size: 12, color: .systemGreen, mono: true),
                                tint: .systemGreen.withAlphaComponent(0.06)),
                SnapshotUI.label("● bun test\n  ✓ project filters          12 passed\n  ✓ activity timeline        24 passed\n  ✓ keyboard navigation       8 passed", size: 12, color: .secondaryLabelColor, mono: true),
                SnapshotUI.label("✓ All checks passed", size: 12, color: .systemGreen, mono: true),
            ]
        }
        rows.append(SnapshotUI.spacer())
        rows.append(SnapshotUI.card(SnapshotUI.label("❯ \(variant == .tests ? "_" : "Ask a follow-up…")",
                                                   size: 12, color: .secondaryLabelColor, mono: true)))
        let content = SnapshotUI.stack(.vertical, rows, spacing: 18, padding: 20)
        SnapshotUI.expand(rows, in: content)
        SnapshotUI.pin(content, in: self)
    }

    required init?(coder: NSCoder) { nil }
}

final class SnapshotCode: NSView {
    init() {
        super.init(frame: .zero)
        let lines = ["import Foundation", "", "struct Project: Codable, Identifiable {", "    let id: UUID", "    var name: String",
                     "    var status: Status", "    var updatedAt: Date", "", "    enum Status: String, Codable {",
                     "        case planning", "        case inProgress", "        case complete", "    }", "}", "",
                     "actor ProjectService {", "    private let database: Database", "", "    init(database: Database) {",
                     "        self.database = database", "    }", "", "    func activity(", "        for projectID: UUID,",
                     "        after cursor: String? = nil", "    ) async throws -> ActivityPage {", "        let events = try await database",
                     "            .events(for: projectID)", "            .after(cursor)", "            .limit(50)", "            .fetch()", "",
                     "        return ActivityPage(", "            events: events,", "            nextCursor: events.last?.cursor",
                     "        )", "    }", "}"]
        var rows = lines.enumerated().map { index, line -> NSView in
            let number = SnapshotUI.label(String(index + 1), size: 12, color: .tertiaryLabelColor, mono: true)
            number.alignment = .right
            number.widthAnchor.constraint(equalToConstant: 26).isActive = true
            let color: NSColor = line.contains("func") || line.contains("struct") || line.contains("actor") ? .systemPurple : .labelColor
            return SnapshotUI.stack(.horizontal, [number, SnapshotUI.label(line.isEmpty ? " " : line, size: 12, color: color, mono: true), SnapshotUI.spacer()], spacing: 18)
        }
        rows.append(SnapshotUI.spacer())
        let content = SnapshotUI.stack(.vertical, rows, spacing: 6, padding: 18)
        SnapshotUI.expand(rows, in: content)
        SnapshotUI.pin(content, in: self)
    }

    required init?(coder: NSCoder) { nil }
}
