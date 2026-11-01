import Foundation
import Testing
@testable import Pilot

@Suite("Build push pairing gate")
@MainActor
struct BuildPushCoordinatorPairingTests {
    nonisolated static let unpairedValues: [String?] = [nil, "", "   ", "\n\t ", "not-a-key", Data(count: 31).base64EncodedString()]

    @Test("Cockpit refuses to follow an advertised run without a real paired key", arguments: unpairedValues)
    func followRefusesWithoutPairedKey(stored: String?) throws {
        let item: [String: Any] = ["id": 123, "run_attempt": 1, "html_url": "https://github.com/blau/made/actions/runs/123",
                                   "status": "in_progress", "name": "Apple builds", "head_branch": "main"]
        let run = try #require(BuildWorkflowRun.parse(item, workspaceID: UUID(), workspaceName: "made", checkedAt: Date()))
        let coordinator = BuildPushCoordinator(peerKey: { stored })
        var updates = 0
        coordinator.onUpdate = { _ in updates += 1 }

        // A capability-free request for a run Cockpit advertised is otherwise accepted.
        coordinator.follow(BuildFollowRequest(runKey: run.id, capability: nil), available: [run])

        #expect(coordinator.followedRunKey == nil)
        #expect(updates == 0)
    }
}
