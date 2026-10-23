import SwiftUI
@testable import Pilot

/// A capture-only composition of production panels. Live process, browser,
/// remote-frame and device surfaces are deliberately replaced at the boundary.
struct SnapshotWorkbench: View {
    let scene: SnapshotScene
    let fixtures: SnapshotFixtures

    var body: some View {
        VStack(spacing: 0) {
            titleBar.fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(width: 208).background(Color.primary.opacity(0.035))
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let tab = scene.inspector {
                    Divider()
                    InspectorPanelView(gitStore: fixtures.repository, tasksStore: fixtures.tasks,
                                       usageStore: fixtures.usage, selectedTab: .constant(tab))
                        .frame(width: 360)
                        .environment(\.uiZoom, 0.9)
                        .controlSize(.small)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                }
            }.frame(maxHeight: .infinity).clipped()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .defaultAppStorage(fixtures.defaults)
        .environment(\.uiZoom, 1)
        .allowsHitTesting(false)
        .transaction { $0.animation = nil }
    }

    private var titleBar: some View {
        HStack(spacing: 18) {
            HStack(spacing: 8) {
                ForEach([Color.red, .yellow, .green], id: \.self) { color in
                    Circle().fill(color.opacity(0.85)).frame(width: 12, height: 12)
                }
            }
            Image(systemName: "sidebar.left").foregroundStyle(.secondary)
            Text(scene.title).font(.headline)
            Spacer()
            if scene.selection == nil {
                Text("Fast Command").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 230, alignment: .leading).padding(8)
                    .background(.quaternary, in: Capsule())
                Image(systemName: "play.fill").foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 18) {
                ForEach(["terminal", "safari", "apple.logo", "curlybraces", "folder", "sidebar.right"], id: \.self) {
                    Image(systemName: $0)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.quaternary.opacity(0.5), in: Capsule())
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach([SnapshotScene.notes, .remoteDesktop, .docker, .agenticUse, .runners], id: \.self) { item in
                    let selected = scene == item
                    HStack(spacing: 9) {
                        Image(systemName: symbol(for: item))
                            .foregroundStyle(selected ? Color.white : .accentColor).frame(width: 18)
                        Text(item.title).fontWeight(selected ? .semibold : .medium)
                        Spacer()
                    }
                    .font(.system(size: 13)).padding(.horizontal, 10).frame(height: 31)
                    .foregroundStyle(selected ? Color.white : .primary)
                    .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 7))
                }
                sidebarHeading("Pinned")
                ForEach(fixtures.workspace.workspaces.filter(\.isPinned)) { workspace in
                    projectRow(workspace)
                }
                sidebarHeading("Workspaces")
                ForEach(fixtures.workspace.workspaces.filter { !$0.isPinned }) { workspace in
                    projectRow(workspace)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 10).padding(.top, 12)
            HStack(spacing: 17) {
                Image(systemName: "mic")
                Image(systemName: "cup.and.saucer")
                Spacer()
                Image(systemName: "iphone")
                Image(systemName: "ipad")
                Circle().fill(.green).frame(width: 6, height: 6)
            }
            .font(.system(size: 12)).foregroundStyle(.secondary).padding(14)
        }
    }

    private func sidebarHeading(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.top, 24).padding(.bottom, 5).padding(.leading, 5)
    }

    private func projectRow(_ workspace: Workspace) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(workspace.name).font(.system(size: 13, weight: .medium))
                Text(workspace.name == "orbit-web" ? "feat/activity-timeline" : "main")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if workspace.isPinned {
                Text("1/2").font(.system(size: 9, weight: .semibold)).padding(4)
                    .overlay(Circle().stroke(Color.accentColor.opacity(0.5), lineWidth: 2))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(scene.selection == nil && workspace.name == scene.title ? Color.primary.opacity(0.09) : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
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

    @ViewBuilder private var detail: some View {
        switch scene {
        case .notes:
            SnapshotNotes(fixtures: fixtures)
        case .docker:
            DockerView(store: fixtures.docker)
        case .runners:
            RunnersView(store: fixtures.runners)
        case .agenticUse:
            VStack(spacing: 0) {
                HStack {
                    Text("Agentic Use").fontWeight(.semibold)
                    Text("Sep 24 – Oct 23").foregroundStyle(.secondary)
                    Spacer()
                    Picker("Range", selection: .constant("30d")) {
                        ForEach(["24h", "7d", "30d", "90d", "All"], id: \.self) { Text($0) }
                    }.pickerStyle(.segmented).frame(width: 230)
                }.font(.system(size: 12)).padding(.horizontal, 12).frame(height: 44)
                AgenticUseDashboard(snapshot: fixtures.history, pricingStatus: "Pricing reviewed Oct 23, 2026")
            }
        case .remoteDesktop:
            SnapshotRemoteDesktop()
        case .editor:
            HStack(spacing: 1) {
                SnapshotPane(title: "Editor · Sources/Projects.swift", symbol: "curlybraces") { SnapshotCode() }
                SnapshotPane(title: "Terminal · atlas-api", symbol: "terminal") { SnapshotTerminal(variant: .tests) }
            }
        case .browser:
            HStack(spacing: 1) {
                SnapshotPane(title: "Terminal · orbit-web", symbol: "terminal") { SnapshotTerminal(variant: .agent) }
                SnapshotPane(title: "Browser · localhost:3000", symbol: "safari") { SnapshotWebPreview() }
            }
        case .device:
            HStack(spacing: 1) {
                SnapshotPane(title: "Browser · localhost:3000", symbol: "safari") { SnapshotWebPreview() }
                SnapshotPane(title: "Device · iPhone", symbol: "iphone") { SnapshotDevice() }
            }
        default:
            HStack(spacing: 1) {
                SnapshotPane(title: "Terminal · Claude", symbol: "terminal") { SnapshotTerminal(variant: .agent) }
                SnapshotPane(title: "Terminal · Codex", symbol: "terminal") { SnapshotTerminal(variant: .review) }
            }
        }
    }
}

struct SnapshotPane<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(title, systemImage: symbol).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "ellipsis")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).frame(height: 32)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
            .padding(5)
            content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct SnapshotTerminal: View {
    enum Variant { case agent, review, tests }
    var variant: Variant

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(variant == .review ? "› Codex" : variant == .tests ? "$ swift test" : "✳ Claude Code")
                .font(.system(size: 19, weight: .semibold, design: .monospaced))
                .foregroundStyle(variant == .agent ? Color.orange : .accentColor)
            Text(variant == .tests ? "~/Projects/atlas-api" : "~/Projects/orbit-web · feat/activity-timeline")
                .foregroundStyle(.secondary)
            Divider()
            if variant == .tests {
                testOutput
            } else {
                Text(variant == .agent ? "❯ Build a project activity timeline.\n  Keep filters in sync with the URL." : "❯ Review the activity timeline and\n  add coverage for the new filters.")
                    .fontWeight(.medium)
                Text(variant == .agent ? "I'll connect the timeline to project events\nand add a compact filter bar." : "The timeline is connected. I'm checking\nkeyboard navigation and empty states.")
                    .foregroundStyle(.secondary)
                Text("● Read \(variant == .agent ? "3" : "5") files").foregroundStyle(.cyan)
                Text("  src/components/ActivityTimeline.tsx\n  src/hooks/useProjectEvents.ts\n  tests/activity.test.ts")
                    .foregroundStyle(.secondary)
                Text(variant == .agent ? "● Updated ActivityTimeline.tsx" : "● Added tests/activity.test.ts")
                    .foregroundStyle(.green)
                Text("  + const events = useProjectEvents(id)\n  + const visible = filterEvents(events)\n  + return <Timeline events={visible} />")
                    .foregroundStyle(.green)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                Text("● bun test").foregroundStyle(.cyan)
                Text("  ✓ project filters          12 passed\n  ✓ activity timeline        24 passed\n  ✓ keyboard navigation       8 passed")
                    .foregroundStyle(.secondary)
                Text("✓ All checks passed").foregroundStyle(.green)
                Text(variant == .agent ? "The timeline is ready for review. Filters\npersist across navigation and refreshes." : "Added 8 regression tests. No issues found\nin the updated project views.")
            }
            Spacer(minLength: 12)
            Text("❯ \(variant == .tests ? "_" : "Ask a follow-up…")")
                .foregroundStyle(.secondary).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Text(variant == .tests ? "atlas-api" : "orbit-web")
                Spacer()
                Text("⌘K commands")
            }.font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
        }
        .font(.system(size: 12, design: .monospaced))
        .textSelection(.disabled)
        .padding(20)
    }

    private var testOutput: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Building for debugging…\nBuild complete! (1.42s)").foregroundStyle(.secondary)
            ForEach(["ProjectRoutes", "ActivityEvents", "TeamInvitations", "CursorPagination", "Authentication"], id: \.self) {
                Text("✓ \($0)Tests\n  12 tests passed in 0.08 seconds").foregroundStyle(.green)
            }
            Text("Test Suite 'All tests' passed\nExecuted 60 tests, with 0 failures.")
            Text("$ git status --short\n M Sources/Projects.swift\n M Tests/ProjectRoutesTests.swift").foregroundStyle(.secondary)
        }
    }
}

struct SnapshotCode: View {
    private let lines = ["import Foundation", "", "struct Project: Codable, Identifiable {", "    let id: UUID", "    var name: String",
                         "    var status: Status", "    var updatedAt: Date", "", "    enum Status: String, Codable {",
                         "        case planning", "        case inProgress", "        case complete", "    }", "}", "",
                         "actor ProjectService {", "    private let database: Database", "", "    init(database: Database) {",
                         "        self.database = database", "    }", "", "    func activity(", "        for projectID: UUID,",
                         "        after cursor: String? = nil", "    ) async throws -> ActivityPage {", "        let events = try await database",
                         "            .events(for: projectID)", "            .after(cursor)", "            .limit(50)", "            .fetch()", "",
                         "        return ActivityPage(", "            events: events,", "            nextCursor: events.last?.cursor", "        )", "    }", "}"]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .top, spacing: 18) {
                    Text(String(index + 1)).foregroundStyle(.tertiary).frame(width: 24, alignment: .trailing)
                    Text(line.isEmpty ? " " : line)
                        .foregroundStyle(line.contains("func") || line.contains("struct") || line.contains("actor") ? Color.purple : .primary)
                }
            }
            Spacer(minLength: 0)
        }.font(.system(size: 12, design: .monospaced)).padding(.vertical, 18).padding(.horizontal, 12)
    }
}

/// Glass and native sidebar selection require the window-server compositor.
/// Opaque capture chrome keeps offscreen exports independent of screen access.
private struct SnapshotNotes: View {
    let fixtures: SnapshotFixtures

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(fixtures.workspace.notes) { note in
                    Text(note.displayTitle).lineLimit(1)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(note.id == fixtures.workspace.selectedNoteID ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 7))
                }
                Image(systemName: "plus.circle.fill").foregroundStyle(.secondary)
                Spacer()
                Label("Word Wrap: None", systemImage: "text.word.spacing").foregroundStyle(.secondary)
            }.font(.system(size: 12, weight: .medium)).padding(12)
            Label("Secret masking is visual only. Notes are stored locally as plaintext—do not use Notes as a secret manager.",
                  systemImage: "eye.slash")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 6)
            NoteTextView(text: .constant(SnapshotFixtures.releaseNote), fontSize: 13, wordWrapColumns: nil, onCopySecret: {})
        }
    }
}
