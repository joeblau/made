import Foundation
import Testing
@testable import Pilot

@Suite("Workspace root tracking")
struct WorkspaceRootTrackingTests {

    @Test
    func rootTrackingPrefersSelectedTerminal() {
        let workspace = Workspace(name: "Test")
        let selectedTerminal = Pane(kind: .terminal, sortOrder: 0)
        let frontmostTerminal = Pane(kind: .terminal, sortOrder: 1)

        configure(
            workspace,
            panes: [selectedTerminal, frontmostTerminal],
            selectedPaneID: selectedTerminal.id,
            frontmostTerminalID: frontmostTerminal.id
        )

        #expect(workspace.rootTrackingTerminalPane?.id == selectedTerminal.id)
    }

    @Test
    func rootTrackingFallsBackToFrontmostTerminalWhenBrowserIsSelected() {
        let workspace = Workspace(name: "Test")
        let terminal = Pane(kind: .terminal, sortOrder: 0)
        let browser = Pane(kind: .browser, sortOrder: 1)
        let frontmostTerminal = Pane(kind: .terminal, sortOrder: 2)

        configure(
            workspace,
            panes: [terminal, browser, frontmostTerminal],
            selectedPaneID: browser.id,
            frontmostTerminalID: frontmostTerminal.id
        )

        #expect(workspace.rootTrackingTerminalPane?.id == frontmostTerminal.id)
    }

    @Test
    func rootTrackingFallsBackToLeftmostTerminalWhenFrontmostIsUnavailable() {
        let workspace = Workspace(name: "Test")
        let leftmostTerminal = Pane(kind: .terminal, sortOrder: 0)
        let browser = Pane(kind: .browser, sortOrder: 1)
        let trailingTerminal = Pane(kind: .terminal, sortOrder: 2)

        configure(
            workspace,
            panes: [leftmostTerminal, browser, trailingTerminal],
            selectedPaneID: browser.id,
            frontmostTerminalID: UUID()
        )

        #expect(workspace.rootTrackingTerminalPane?.id == leftmostTerminal.id)
    }

    @Test
    func syncUsesSelectedTerminalRepoInsideWorkspace() throws {
        let workspace = Workspace(name: "Test")
        let selectedTerminal = Pane(kind: .terminal, sortOrder: 0)
        let otherTerminal = Pane(kind: .terminal, sortOrder: 1)
        let nonRepoDirectory = try makeNonRepoDirectory()
        defer { try? FileManager.default.removeItem(at: nonRepoDirectory) }

        let repoDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
        guard let expectedRoot = GitStatus.findWorkTreeRoot(from: repoDirectory) else {
            Issue.record("Expected test fixture to live inside a git repository")
            return
        }

        selectedTerminal.currentDirectory = repoDirectory
        otherTerminal.currentDirectory = nonRepoDirectory.path

        configure(
            workspace,
            panes: [selectedTerminal, otherTerminal],
            selectedPaneID: selectedTerminal.id,
            frontmostTerminalID: otherTerminal.id
        )

        workspace.syncDefaultRootPathIfNeeded()

        #expect(workspace.rootPath == expectedRoot)
    }

    @Test
    func syncClearsStaleRootPathWhenTrackedTerminalLeavesRepo() throws {
        let workspace = Workspace(name: "Test")
        let terminal = Pane(kind: .terminal, sortOrder: 0)
        let nonRepoDirectory = try makeNonRepoDirectory()
        defer { try? FileManager.default.removeItem(at: nonRepoDirectory) }

        terminal.currentDirectory = nonRepoDirectory.path
        configure(
            workspace,
            panes: [terminal],
            selectedPaneID: terminal.id,
            frontmostTerminalID: terminal.id
        )

        workspace.rootPath = "/tmp/stale-repo"
        workspace.syncDefaultRootPathIfNeeded(using: terminal)

        #expect(workspace.rootPath.isEmpty)
    }

    @Test
    @MainActor
    func inspectorRepositoryHeadersDescribeTheirCurrentContext() {
        let store = RepositoryStore()

        #expect(store.repositoryName == "Repository")

        store.repoPath = "/tmp/example-repository"

        #expect(store.repositoryName == "example-repository")
    }

    @Test
    func manualRootPathIsNotOverwrittenByAutomaticSync() throws {
        let workspace = Workspace(name: "Test")
        let terminal = Pane(kind: .terminal, sortOrder: 0)
        let nonRepoDirectory = try makeNonRepoDirectory()
        defer { try? FileManager.default.removeItem(at: nonRepoDirectory) }

        terminal.currentDirectory = nonRepoDirectory.path
        configure(
            workspace,
            panes: [terminal],
            selectedPaneID: terminal.id,
            frontmostTerminalID: terminal.id
        )

        workspace.setRootPath("~/ManualRoot")
        workspace.syncDefaultRootPathIfNeeded(using: terminal)

        #expect(workspace.rootPath == "\(NSHomeDirectory())/ManualRoot")
        #expect(workspace.rootPathSource == .manual)
    }

    @Test
    func newTerminalStartsAtManualRootPath() {
        let workspace = Workspace(name: "Test")
        workspace.setRootPath("~/ManualRoot")

        workspace.addPane(kind: .terminal, side: .right)

        #expect(workspace.selectedPane?.currentDirectory == "\(NSHomeDirectory())/ManualRoot")
    }

    private func configure(
        _ workspace: Workspace,
        panes: [Pane],
        selectedPaneID: UUID,
        frontmostTerminalID: UUID?
    ) {
        workspace.panes = panes
        for pane in panes {
            pane.workspace = workspace
        }
        workspace.selectedPaneID = selectedPaneID
        workspace.frontmostTerminalPaneID = frontmostTerminalID
    }

    private func makeNonRepoDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("blau-root-tracking-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
