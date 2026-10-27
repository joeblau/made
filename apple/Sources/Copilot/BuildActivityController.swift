@preconcurrency import ActivityKit
import Foundation
import Observation

@MainActor
@Observable
final class BuildActivityController {
    private struct SavedMonitor: Codable {
        let activityID: String
        var run: BuildWorkflowRun
        let capability: String
        let peerKey: String
        let expiresAt: Date
        var registeredToken: String?
    }
    private(set) var runs: [BuildWorkflowRun] = []
    private(set) var followedRun: BuildWorkflowRun?
    private(set) var message: String?
    private(set) var isStarting = false
    @ObservationIgnored var send: ((SyncMessage) -> Void)?
    @ObservationIgnored private var activity: Activity<BuildActivityAttributes>?
    @ObservationIgnored private var saved: SavedMonitor?
    @ObservationIgnored private var tokenTask: Task<Void, Never>?
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored private var contentTask: Task<Void, Never>?

    func restore() {
        guard activity == nil else { return }
        let activities = Activity<BuildActivityAttributes>.activities
        guard let record = BuildMonitorStorage.load(SavedMonitor.self) else {
            Task { for orphan in activities { await orphan.end(nil, dismissalPolicy: .immediate) } }
            return
        }
        guard record.expiresAt > Date(), record.peerKey == DeviceIdentity.peerPublicKeyBase64(),
              let existing = Activity<BuildActivityAttributes>.activities.first(where: { $0.id == record.activityID }),
              existing.activityState == .active || existing.activityState == .stale else {
            BuildMonitorStorage.clear()
            Task {
                for orphan in activities { await orphan.end(nil, dismissalPolicy: .immediate) }
                try? await BuildActivityRelay.send(BuildUnfollowRequest(runKey: record.run.id), action: "end", capability: record.capability)
            }
            return
        }
        saved = record
        activity = existing
        followedRun = record.run
        followedRun?.state = existing.content.state
        saved?.run.state = existing.content.state
        Task {
            for orphan in activities where orphan.id != existing.id {
                await orphan.end(nil, dismissalPolicy: .immediate)
            }
        }
        observe(existing)
    }

    func receive(_ runs: [BuildWorkflowRun]) {
        self.runs = runs
        if let followedRun, let latest = runs.first(where: { $0.id == followedRun.id }) { receive(latest) }
    }

    func receive(_ run: BuildWorkflowRun) {
        guard let current = followedRun, run.id == current.id, run.state.canReplace(current.state),
              run.state != current.state else { return }
        followedRun = run
        saved?.run = run
        persist()
        guard let activity else { return }
        Task {
            guard self.activity?.id == activity.id, run.state.canReplace(activity.content.state) else { return }
            let content = ActivityContent(state: run.state, staleDate: run.state.isComplete ? nil : run.state.staleDate)
            if run.state.isComplete {
                await activity.end(content, dismissalPolicy: .after(.now.addingTimeInterval(15 * 60)))
            } else if !activity.content.state.isComplete {
                await activity.update(content)
            }
        }
    }

    func follow(_ run: BuildWorkflowRun, connected: Bool) async {
        guard !isStarting else { return }
        guard connected else { message = "Connect to Cockpit to follow a build."; return }
        guard !run.state.isComplete else { message = "This run has already finished."; return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            message = "Enable Live Activities for Walkie in Settings to follow builds."
            return
        }
        guard let capability = BuildActivityRelay.makeCapability(), let peerKey = DeviceIdentity.peerPublicKeyBase64() else { return }
        isStarting = true
        defer { isStarting = false }
        await stop()
        do {
            let activity = try Activity.request(
                attributes: BuildActivityAttributes(run: run),
                content: ActivityContent(state: run.state, staleDate: run.state.staleDate), pushType: .token
            )
            self.activity = activity
            followedRun = run
            saved = SavedMonitor(activityID: activity.id, run: run, capability: capability, peerKey: peerKey,
                                 expiresAt: Date().addingTimeInterval(8 * 3600))
            persist()
            message = "Following build. Preparing background updates…"
            send?(.followBuild(BuildFollowRequest(runKey: run.id, capability: nil)))
            observe(activity)
        } catch {
            message = "Could not start the Live Activity. Try again while Walkie is open."
        }
    }

    func connected() {
        guard let saved, !saved.run.state.isComplete else { return }
        guard saved.peerKey == DeviceIdentity.peerPublicKeyBase64() else {
            Task { await stop() }
            return
        }
        send?(.followBuild(BuildFollowRequest(runKey: saved.run.id, capability: saved.registeredToken == nil ? nil : saved.capability)))
        if let activity, let token = activity.pushToken {
            Task { await register(token, activityID: activity.id) }
        }
    }

    func stop() async {
        let previous = saved
        let previousActivity = activity
        tokenTask?.cancel()
        stateTask?.cancel()
        contentTask?.cancel()
        activity = nil
        saved = nil
        followedRun = nil
        message = nil
        BuildMonitorStorage.clear()
        if let previous {
            send?(.unfollowBuild(BuildUnfollowRequest(runKey: previous.run.id)))
            Task { try? await BuildActivityRelay.send(BuildUnfollowRequest(runKey: previous.run.id), action: "end", capability: previous.capability) }
        }
        await previousActivity?.end(nil, dismissalPolicy: .immediate)
    }

    private func observe(_ activity: Activity<BuildActivityAttributes>) {
        tokenTask?.cancel()
        stateTask?.cancel()
        contentTask?.cancel()
        tokenTask = Task { [weak self] in
            if let token = activity.pushToken { await self?.register(token, activityID: activity.id) }
            for await token in activity.pushTokenUpdates {
                guard !Task.isCancelled else { return }
                await self?.register(token, activityID: activity.id)
            }
        }
        contentTask = Task { [weak self] in
            for await content in activity.contentUpdates {
                guard !Task.isCancelled, let self, self.saved?.activityID == activity.id else { return }
                if let current = self.followedRun, content.state.canReplace(current.state) {
                    self.followedRun?.state = content.state
                    self.saved?.run.state = content.state
                    self.persist()
                }
            }
        }
        stateTask = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled, let self, self.saved?.activityID == activity.id else { return }
                if state == .dismissed {
                    await self.stop()
                    return
                }
                if state == .ended {
                    self.message = "Build monitoring finished."
                    // Keep the terminal result visible in-app; the relay ends independently.
                    if !activity.content.state.isComplete {
                        self.send?(.unfollowBuild(BuildUnfollowRequest(runKey: activity.attributes.runKey)))
                    }
                    BuildMonitorStorage.clear()
                    return
                }
            }
        }
    }

    private func register(_ token: Data, activityID: String) async {
        guard let record = saved, record.activityID == activityID, !record.run.state.isComplete else { return }
        let tokenHex = token.map { String(format: "%02x", $0) }.joined()
        guard record.registeredToken != tokenHex else { return }
        guard let environment = Bundle.main.object(forInfoDictionaryKey: "BuildPushEnvironment") as? String,
              ["sandbox", "production"].contains(environment) else {
            message = "Following while connected. Background updates require a push-enabled build."
            return
        }
        do {
            try await BuildActivityRelay.send(
                BuildActivityRelay.Registration(token: tokenHex, environment: environment, runKey: record.run.id),
                action: "register", capability: record.capability
            )
            guard !Task.isCancelled, saved?.activityID == activityID, saved?.run.state.isComplete == false else { return }
            saved?.registeredToken = tokenHex
            persist()
            send?(.followBuild(BuildFollowRequest(runKey: record.run.id, capability: record.capability)))
            message = "Following on your Lock Screen. Keep Cockpit running on your Mac."
        } catch {
            guard saved?.activityID == activityID else { return }
            message = "Following while connected. Background updates are unavailable; reopen Walkie to retry."
        }
    }

    private func persist() {
        guard let saved else { return }
        do { try BuildMonitorStorage.save(saved) } catch {
            message = "Following this session. Monitoring could not be saved for relaunch."
        }
    }
}
