import Foundation
import Testing
@testable import Pilot

/// Pins the inspector-tab polling gate: the 30s refresh tick may only fetch
/// the GitHub list the visible tab actually renders. Tabs backed by other
/// stores (Tasks, Usage) or by the one-shot filesystem listing must poll
/// nothing here, or a parked inspector pays `gh` spawns for invisible data.
@Suite("Inspector tab polling gate")
struct RepositoryPolledResourcesTests {

    @Test("Each GitHub-backed tab polls only its own list")
    func gitHubBackedTabsPollTheirOwnList() {
        #expect(RepositoryPolledResources(visibleTab: .pullRequests) == .pullRequests)
        #expect(RepositoryPolledResources(visibleTab: .actions) == .workflowRuns)
    }

    @Test("Tabs that render no polled GitHub list poll nothing")
    func nonGitHubTabsPollNothing() {
        #expect(RepositoryPolledResources(visibleTab: .tasks) == RepositoryPolledResources.none)
        #expect(RepositoryPolledResources(visibleTab: .filesystem) == RepositoryPolledResources.none)
        #expect(RepositoryPolledResources(visibleTab: .usage) == RepositoryPolledResources.none)
    }

    @Test("A host that doesn't gate by tab keeps the legacy poll-both behavior")
    func nilTabPollsBoth() {
        #expect(RepositoryPolledResources(visibleTab: nil) == .both)
    }
}

/// The Actions tab used to say "No Actions" while its first `gh run list` was
/// still running, because only the PR fetch raised a loading flag. These pin
/// the skeleton-first rule and that later polls never fade the empty or
/// error state out and back.
@Suite("Actions tab loading state")
struct WorkflowRunsLoadingStateTests {
    @Test("Only a first read with no rows shows the skeleton")
    func overlayRules() {
        #expect(InspectorListOverlay(isEmpty: true, hasRepository: true, hasLoaded: false, error: nil) == .loading)
        #expect(InspectorListOverlay(isEmpty: true, hasRepository: true, hasLoaded: true, error: nil) == .empty)
        #expect(InspectorListOverlay(isEmpty: true, hasRepository: true, hasLoaded: true, error: "x") == .error("x"))
        // No repository: nothing will load, so say so instead of spinning.
        #expect(InspectorListOverlay(isEmpty: true, hasRepository: false, hasLoaded: false, error: nil) == .empty)
        #expect(InspectorListOverlay(isEmpty: false, hasRepository: true, hasLoaded: false, error: nil) == nil)
    }

    @Test("The first read shows the skeleton, and a later poll keeps the result")
    @MainActor
    func firstReadThenPoll() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("actions-loading-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RepositoryStore()
        defer { store.stopWatching() }
        store.startWatching(directory: directory.path, visibleTab: .actions)

        #expect(store.isLoadingWorkflowRuns)
        #expect(!store.hasLoadedWorkflowRuns)
        #expect(store.workflowRunsOverlay == .loading)

        // Not a Git repository, so the read fails fast without calling GitHub.
        for _ in 0..<600 where !store.hasLoadedWorkflowRuns {
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(store.hasLoadedWorkflowRuns)
        #expect(!store.isLoadingWorkflowRuns)
        let failed = InspectorListOverlay.error(GitHubCLIFailure.notGitHubRepository.errorDescription ?? "")
        #expect(store.workflowRunsOverlay == failed)

        // A silent poll is in flight, but the error must stay on screen.
        store.fetchWorkflowRuns()
        #expect(store.isLoadingWorkflowRuns)
        #expect(store.workflowRunsOverlay == failed)

        store.stopWatching()
        #expect(!store.isLoadingWorkflowRuns)
        #expect(!store.hasLoadedWorkflowRuns)
        #expect(store.workflowRunsOverlay == .empty)
    }
}
