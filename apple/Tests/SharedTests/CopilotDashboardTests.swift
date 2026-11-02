import Foundation
import SwiftUI
import Testing
import WidgetKit
@testable import Copilot

@Suite("Copilot dashboard integration", .serialized)
@MainActor
struct CopilotDashboardTests {
    @Test("Only received families persist and reload, and old-peer payloads retain last-good data")
    func persistenceAndTargetedReloads() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DashboardSnapshotStore(directory: directory)
        var reloaded: [DashboardFamily] = []
        let model = CopilotDashboardModel(store: store, reloadTimeline: { reloaded.append($0) })
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

        model.receive(actions: actions, usage: nil, runners: nil)
        #expect(model.actions == actions)
        #expect(store.read(ActionsDashboardSnapshot.self, for: .actions) == actions)
        #expect(reloaded == [.actions])

        model.receive(actions: nil, usage: usage, runners: runners)
        #expect(reloaded == [.actions, .usage, .runners])
        #expect(store.read(UsageDashboardSnapshot.self, for: .usage) == usage)
        #expect(store.read(RunnersDashboardSnapshot.self, for: .runners) == runners)

        model.receive(actions: nil, usage: nil, runners: nil)
        #expect(reloaded == [.actions, .usage, .runners])
        #expect(model.actions == actions)
        #expect(model.usage == usage)
        #expect(model.runners == runners)
        #expect(store.read(ActionsDashboardSnapshot.self, for: .actions) == actions)
        #expect(store.read(UsageDashboardSnapshot.self, for: .usage) == usage)
        #expect(store.read(RunnersDashboardSnapshot.self, for: .runners) == runners)

        let restored = CopilotDashboardModel(store: store, reloadTimeline: { _ in
            Issue.record("Launch restoration must not reload widget timelines")
        })
        #expect(restored.actions == actions)
        #expect(restored.usage == usage)
        #expect(restored.runners == runners)
    }

    @Test("Dashboard deep links select their family", arguments: [
        DashboardFamily.actions, DashboardFamily.usage, DashboardFamily.runners,
    ])
    func dashboardDeepLinks(family: DashboardFamily) throws {
        let url = try #require(URL(string: "walkie://\(family.rawValue)"))
        #expect(CopilotDeepLink(url: url) == .dashboard(family))
    }

    @Test("Build deep links remain distinct and unrelated URLs are ignored")
    func buildAndInvalidDeepLinks() throws {
        let build = try #require(URL(string: "walkie://build/repository/123"))
        #expect(CopilotDeepLink(url: build) == .build)
        for string in ["https://actions", "walkie://unknown", "walkie:actions"] {
            let url = try #require(URL(string: string))
            #expect(CopilotDeepLink(url: url) == nil)
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CopilotDashboardTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

/// Light-mode widget numbers, status glyphs, and secondary copy must read
/// on the white widget (TYPE-3). The light variants are asset colors
/// resolved at draw time, so a macOS desktop widget archived in one
/// appearance still draws the other appearance's variant.
@Suite("Dashboard state tones")
struct DashboardToneTests {
    private static func luminance(_ color: Color.Resolved) -> Double {
        0.2126 * Double(color.linearRed) + 0.7152 * Double(color.linearGreen) + 0.0722 * Double(color.linearBlue)
    }

    private static func resolved(_ color: Color, scheme: ColorScheme) -> Color.Resolved {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        return color.resolve(in: environment)
    }

    private static func contrastOnWhite(_ color: Color, scheme: ColorScheme) -> Double {
        let resolved = resolved(color, scheme: scheme)
        // Composite over white in case a system color carries opacity.
        let alpha = Double(resolved.opacity)
        let luminance = luminance(resolved) * alpha + (1 - alpha)
        return 1.05 / (luminance + 0.05)
    }

    private static func matches(_ lhs: Color.Resolved, _ rhs: Color.Resolved) -> Bool {
        abs(lhs.red - rhs.red) < 0.005 && abs(lhs.green - rhs.green) < 0.005
            && abs(lhs.blue - rhs.blue) < 0.005 && abs(lhs.opacity - rhs.opacity) < 0.005
    }

    @Test("Asset colors are bundled with the shared dashboard code", arguments: DashboardTone.allCases)
    func assetsResolve(tone: DashboardTone) {
        #expect(UIColor(named: tone.assetName, in: DashboardAssets.bundle, compatibleWith: nil) != nil)
        #expect(UIColor(named: DashboardText.secondaryAssetName, in: DashboardAssets.bundle, compatibleWith: nil) != nil)
    }

    @Test("Light mode clears 4.5:1 on white", arguments: DashboardTone.allCases)
    func lightModeContrast(tone: DashboardTone) {
        let contrast = Self.contrastOnWhite(tone.adaptiveColor, scheme: .light)
        #expect(contrast >= 4.5)
        // Not darker than needed: stays a recognizable state color.
        #expect(contrast < 6)
        // The undarkened system color is the failure this guards against.
        #expect(Self.contrastOnWhite(tone.systemColor, scheme: .light) < contrast)
    }

    @Test("Dark mode keeps the system color", arguments: DashboardTone.allCases)
    func darkModeKeepsSystemColor(tone: DashboardTone) {
        #expect(Self.matches(
            Self.resolved(tone.adaptiveColor, scheme: .dark),
            Self.resolved(tone.systemColor, scheme: .dark)
        ))
    }

    @Test("Accented rendering keeps the system color; full color and vibrant adapt", arguments: DashboardTone.allCases)
    func renderingModes(tone: DashboardTone) {
        #expect(tone.color(for: .accented) == tone.systemColor)
        #expect(tone.color(for: .fullColor) == tone.adaptiveColor)
        #expect(tone.color(for: .vibrant) == tone.adaptiveColor)
    }

    @Test("Secondary text clears 4.5:1 in light mode and keeps the system secondary in dark")
    func secondaryText() {
        let light = Self.contrastOnWhite(DashboardText.secondaryColor, scheme: .light)
        #expect(light >= 4.5)
        // Still lighter than primary text, so the two levels stay apart.
        #expect(light < Self.contrastOnWhite(.primary, scheme: .light))
        #expect(Self.matches(
            Self.resolved(DashboardText.secondaryColor, scheme: .dark),
            Self.resolved(Color(uiColor: .secondaryLabel), scheme: .dark)
        ))
    }

    @Test("Utilization meters turn orange at 75% and red at 90%")
    func utilizationTones() {
        #expect(DashboardTone.utilization(0) == .purple)
        #expect(DashboardTone.utilization(0.74) == .purple)
        #expect(DashboardTone.utilization(0.75) == .orange)
        #expect(DashboardTone.utilization(0.9) == .red)
        #expect(DashboardTone.utilization(1) == .red)
    }

    @Test("Large usage meters list the window, then the plan, only when reported")
    func providerMeters() {
        let both = UsageDashboardProviderSummary(
            id: "claude", name: "Claude",
            planName: "Max", plan: UsageDashboardUtilization(utilization: 0.4),
            windowName: "5h", window: UsageDashboardUtilization(utilization: 0.8, resetAt: 1_000)
        )
        #expect(both.meters.map(\.name) == ["5h", "Max"])
        #expect(both.meters.first?.resetAt == 1_000)
        let planOnly = UsageDashboardProviderSummary(
            id: "cursor", name: "Cursor", plan: UsageDashboardUtilization(utilization: 0.2)
        )
        #expect(planOnly.meters.map(\.name) == ["Plan"])
        #expect(UsageDashboardProviderSummary(id: "codex", name: "Codex").meters.isEmpty)
    }

    @Test("Run and runner states map to their tones; neutral runs stay secondary")
    func stateTones() {
        func runner(status: String, busy: Bool) -> RunnersDashboardRunner {
            RunnersDashboardRunner(id: 1, name: "runner", status: status, busy: busy)
        }
        #expect(runner(status: "online", busy: false).dashboardTint == .green)
        #expect(runner(status: "online", busy: true).dashboardTint == .orange)
        #expect(runner(status: "offline", busy: true).dashboardTint == .red)

        func run(status: String, conclusion: String? = nil) -> ActionsDashboardRun {
            ActionsDashboardRun(
                workspaceName: "w", repository: "r", runID: 1, branch: "main",
                workflow: "CI", status: status, conclusion: conclusion
            )
        }
        #expect(run(status: "in_progress").dashboardTint == .blue)
        #expect(run(status: "completed", conclusion: "success").dashboardTint == .green)
        #expect(run(status: "completed", conclusion: "failure").dashboardTint == .red)
        #expect(run(status: "completed", conclusion: "action_required").dashboardTint == .orange)
        #expect(run(status: "completed", conclusion: "cancelled").dashboardTint == nil)
    }
}

/// The speech storage sheet's controls while it covers the download banner.
@Suite("Speech storage sheet controls")
struct SpeechStorageControlsTests {
    @Test("A fresh download offers Cancel Download, not the download actions")
    func freshDownload() {
        let controls = SpeechStorageControls(isLoading: true, isCachedLoad: false, hasStoredModel: false, isLoaded: false)
        #expect(controls.cancelTitle == "Cancel Download")
        #expect(!controls.showsDownload)
        #expect(!controls.showsRemove)
    }

    @Test("Resuming over a partial download is still a download, and Remove waits")
    func resumedDownload() {
        let controls = SpeechStorageControls(isLoading: true, isCachedLoad: false, hasStoredModel: true, isLoaded: false)
        #expect(controls.cancelTitle == "Cancel Download")
        #expect(controls.showsRemove)
        #expect(!controls.removeEnabled)
        #expect(!controls.showsDownload)
    }

    @Test("A cached load offers Cancel Loading beside a disabled Remove")
    func cachedLoad() {
        let controls = SpeechStorageControls(isLoading: true, isCachedLoad: true, hasStoredModel: true, isLoaded: false)
        #expect(controls.cancelTitle == "Cancel Loading")
        #expect(controls.showsRemove)
        #expect(!controls.removeEnabled)
    }

    @Test("Cancelling a resumed download keeps Cancel Download")
    func cancellingResumedDownload() {
        // The service clears the fraction while cancelling; the title follows
        // the load's preparation instead.
        let controls = SpeechStorageControls(isLoading: true, isCachedLoad: false, hasStoredModel: true, isLoaded: false)
        #expect(controls.cancelTitle == "Cancel Download")
    }

    @Test("Idle: download actions with nothing stored, else an enabled Remove")
    func idle() {
        let empty = SpeechStorageControls(isLoading: false, isCachedLoad: false, hasStoredModel: false, isLoaded: false)
        #expect(empty.cancelTitle == nil)
        #expect(empty.showsDownload)
        #expect(!empty.showsRemove)

        let stored = SpeechStorageControls(isLoading: false, isCachedLoad: false, hasStoredModel: true, isLoaded: false)
        #expect(stored.cancelTitle == nil)
        #expect(!stored.showsDownload)
        #expect(stored.showsRemove && stored.removeEnabled)

        let loaded = SpeechStorageControls(isLoading: false, isCachedLoad: false, hasStoredModel: false, isLoaded: true)
        #expect(loaded.showsRemove && loaded.removeEnabled)
    }

    @Test("The sheet keeps the alert's error until the service reports a newer one")
    func displayedError() {
        #expect(SpeechStorageControls.displayedError(service: nil, carried: "network") == "network")
        #expect(SpeechStorageControls.displayedError(service: "cancelled", carried: "network") == "cancelled")
        #expect(SpeechStorageControls.displayedError(service: nil, carried: nil) == nil)
    }
}
