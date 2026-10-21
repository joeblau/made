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
