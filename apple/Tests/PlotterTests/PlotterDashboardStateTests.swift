import Foundation
import Testing
@testable import Plotter

@Suite("Plotter dashboard integration", .serialized)
struct PlotterDashboardStateTests {
    @Test("Partial updates preserve last-good snapshots and report only received families")
    func partialUpdates() {
        let actions = ActionsDashboardSnapshot(updatedAt: 100, runs: [])
        let usage = UsageDashboardSnapshot(updatedAt: 200, estimatedCost: 4.25, totalTokens: 800, providers: [])
        let runners = RunnersDashboardSnapshot(
            enterpriseID: "enterprise",
            enterpriseName: "Enterprise",
            totalCount: 3,
            idleCount: 1,
            busyCount: 1,
            offlineCount: 1,
            runners: [],
            updatedAt: 300
        )
        var snapshots = PlotterDashboardSnapshots()

        #expect(snapshots.apply(DashboardSnapshotEnvelope(actions: actions)) == [.actions])
        #expect(snapshots.apply(DashboardSnapshotEnvelope()) == [])
        #expect(snapshots.actions == actions)
        #expect(snapshots.usage == nil)
        #expect(snapshots.runners == nil)

        #expect(snapshots.apply(usage: usage, runners: runners) == [.usage, .runners])
        #expect(snapshots.actions == actions)
        #expect(snapshots.usage == usage)
        #expect(snapshots.runners == runners)

        let replacement = ActionsDashboardSnapshot(updatedAt: 400, runs: [])
        #expect(snapshots.apply(actions: replacement, usage: nil, runners: nil) == [.actions])
        #expect(snapshots.actions == replacement)
        #expect(snapshots.usage == usage)
        #expect(snapshots.runners == runners)
    }

    @Test("Persisted family files restore independently at startup")
    func persistenceAndStartupRestore() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DashboardSnapshotStore(directory: directory)
        let actions = ActionsDashboardSnapshot(updatedAt: 100, runs: [])
        let usage = UsageDashboardSnapshot(updatedAt: 200, estimatedCost: 0, totalTokens: 0, providers: [])
        let runners = RunnersDashboardSnapshot(
            enterpriseID: "enterprise",
            enterpriseName: "Enterprise",
            totalCount: 0,
            idleCount: 0,
            busyCount: 0,
            offlineCount: 0,
            runners: [],
            updatedAt: 300
        )

        try store.write(actions, for: .actions)
        try store.write(usage, for: .usage)
        try store.write(runners, for: .runners)
        let restored = PlotterDashboardSnapshots(store: store)

        #expect(restored.actions == actions)
        #expect(restored.usage == usage)
        #expect(restored.runners == runners)
    }

    @Test("Dashboard deep links select their family", arguments: [
        DashboardFamily.actions, DashboardFamily.usage, DashboardFamily.runners,
    ])
    func dashboardDeepLinks(family: DashboardFamily) throws {
        let url = try #require(URL(string: "kneeboard://\(family.rawValue)"))
        #expect(PlotterDashboardRoute(url: url)?.family == family)
        let pathURL = try #require(URL(string: "kneeboard:///\(family.rawValue)"))
        #expect(PlotterDashboardRoute(url: pathURL)?.family == family)
    }

    @Test("Unrelated and malformed deep links are ignored")
    func invalidDeepLinks() throws {
        for string in [
            "https://actions",
            "kneeboard://unknown",
            "kneeboard://actions/extra",
            "kneeboard://actions?push=true",
            "kneeboard://user@actions",
            "kneeboard:",
        ] {
            let url = try #require(URL(string: string))
            #expect(PlotterDashboardRoute(url: url) == nil)
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PlotterDashboardStateTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

@MainActor
private final class ResyncCounter {
    var count = 0
}

/// Issue #431: Plotter re-sends its full drawing to every newly authenticated
/// Cockpit session, because the receiver's disconnected queue keeps only the
/// newest packets. These drive the real callbacks ``MirrorModel`` installs on
/// its ``FrameReceiver``. `FrameReceiver.didAuthenticatePilot` invokes
/// `onConnectedChanged(true)` and then flushes its queue on the receiver's
/// serial queue; the resync this hook triggers is enqueued on that same queue
/// later, from the main actor, so it always follows the flushed packets.
@Suite("Plotter annotation mirror wiring", .serialized)
@MainActor
struct PlotterAnnotationMirrorWiringTests {
    @Test("Every Cockpit authentication triggers a full canvas resync; a disconnect does not")
    func authenticationTriggersResync() async throws {
        let receiver = FrameReceiver()
        let model = MirrorModel(receiver: receiver)
        let resyncs = ResyncCounter()
        model.onCockpitAuthenticated = { resyncs.count += 1 }
        let connectedChanged = try #require(receiver.onConnectedChanged)

        connectedChanged(true)
        #expect(await eventually { resyncs.count == 1 && model.isCockpitConnected })

        connectedChanged(false)
        #expect(await eventually { !model.isCockpitConnected })
        #expect(resyncs.count == 1)

        // A reconnect authenticates a new session, which resyncs again.
        connectedChanged(true)
        #expect(await eventually { resyncs.count == 2 && model.isCockpitConnected })

        connectedChanged(false)
        #expect(await eventually { !model.isCockpitConnected })
        #expect(resyncs.count == 2)
    }

    @Test("sendAnnotation reports an annotation too large to encode as undelivered")
    func sendAnnotationReportsUndeliverable() {
        let model = MirrorModel(receiver: FrameReceiver())
        let strokes = (0..<40).map { id in
            AnnotationStroke(
                color: AnnotationColor(red: 1, green: 0, blue: 0, alpha: 1),
                width: 0.01,
                points: (0..<1_000).map { index in
                    AnnotationPoint(
                        x: (Double(id * 1_000 + index) + 0.123456789) / 7_919.0,
                        y: (Double(index) + 0.987654321) / 7_927.0
                    )
                }
            )
        }
        // AnnotationMirrorSync advances its record of Pilot's ink only when
        // this returns true, so an oversized replacement must return false.
        #expect(!model.sendAnnotation(.replaceDrawing(AnnotationDrawing(strokes: strokes))))
        #expect(model.sendAnnotation(.addStroke(strokes[0])))
        #expect(model.sendAnnotation(.clear))
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
