import Foundation

/// Polls the exact followed attempt even when it falls out of GitHub's recent-run list.
/// The Mac retains its GitHub credentials; the relay receives only activity state.
@MainActor
final class BuildPushCoordinator {
    private struct Subscription: Codable {
        var run: BuildWorkflowRun
        var capability: String?
        let peerKey: String
        let expiresAt: Date
    }
    private var subscription: Subscription?
    private var pollTask: Task<Void, Never>?
    var onUpdate: ((BuildWorkflowRun) -> Void)?

    func restore() {
        guard subscription == nil,
              let saved = BuildMonitorStorage.load(Subscription.self),
              saved.peerKey == DeviceIdentity.peerPublicKeyBase64(), saved.expiresAt > Date() else { return }
        subscription = saved
        beginPolling()
    }

    func follow(_ request: BuildFollowRequest, available: [BuildWorkflowRun]) {
        guard request.capability.map(BuildActivityRelay.validCapability) ?? true,
              let peerKey = DeviceIdentity.peerPublicKeyBase64() else { return }
        // Only follow a run Cockpit actually advertised, never arbitrary peer-supplied URLs or commands.
        guard let run = available.first(where: { $0.id == request.runKey })
                ?? subscription?.run, run.id == request.runKey else { return }
        let expiresAt = subscription?.run.id == run.id ? subscription!.expiresAt : Date().addingTimeInterval(8 * 3600)
        subscription = Subscription(run: run, capability: request.capability, peerKey: peerKey, expiresAt: expiresAt)
        if let subscription { try? BuildMonitorStorage.save(subscription) }
        beginPolling()
    }

    func stop(runKey: String? = nil) {
        guard runKey == nil || subscription?.run.id == runKey else { return }
        let previous = subscription
        subscription = nil
        pollTask?.cancel()
        pollTask = nil
        BuildMonitorStorage.clear()
        if let previous, let capability = previous.capability {
            Task {
                try? await BuildActivityRelay.send(BuildUnfollowRequest(runKey: previous.run.id), action: "end", capability: capability)
            }
        }
    }

    private func beginPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let saved = self.subscription else { return }
                guard saved.expiresAt > Date(), saved.peerKey == DeviceIdentity.peerPublicKeyBase64() else {
                    self.stop()
                    return
                }
                await self.refresh(saved)
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }

    private func refresh(_ saved: Subscription) async {
        let run = saved.run
        let result = try? await ProcessRunner.run(.developerTool(
            "gh", arguments: ["api", "--hostname", "github.com", "repos/\(run.repository)/actions/runs/\(run.runID)/attempts/\(run.attempt)"],
            timeout: .seconds(20), standardOutputLimit: 512 * 1024, standardErrorLimit: 16 * 1024
        ))
        guard !Task.isCancelled, subscription?.run.id == run.id,
              let data = result?.standardOutputString.data(using: .utf8),
              let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let updated = BuildWorkflowRun.parse(item, workspaceID: run.workspaceID, workspaceName: run.workspaceName, checkedAt: Date()),
              updated.id == run.id, updated.state.canReplace(run.state) else { return }
        subscription?.run = updated
        if let subscription { try? BuildMonitorStorage.save(subscription) }
        onUpdate?(updated)
        if let capability = saved.capability {
            do {
                try await BuildActivityRelay.send(
                    BuildActivityRelay.Update(runKey: updated.id, state: updated.state), action: "update", capability: capability
                )
            } catch BuildActivityRelay.Failure.rejected(let status) where status == 404 || status == 410 {
                stop(runKey: run.id)
                return
            } catch {
                // Retain completion and retry on the next poll; never fabricate a fresh status on failure.
                return
            }
        }
        guard !Task.isCancelled, subscription?.run.id == run.id else { return }
        if updated.state.isComplete {
            subscription = nil
            BuildMonitorStorage.clear()
        }
    }
}
