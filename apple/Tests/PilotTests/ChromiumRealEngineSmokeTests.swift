import Foundation
import XCTest
@testable import Pilot

final class ChromiumRealEngineSmokeTests: XCTestCase {
    private struct PerformanceBudgets: Decodable {
        struct Runtime: Decodable {
            let maximumStartupSeconds: TimeInterval
            let maximumFirstNavigationSeconds: TimeInterval
            let maximumHelperCleanupSeconds: TimeInterval
            let maximumIdleCPUPercent: Double
            let maximumIdleMessagePumpWatchdogWorkCount: Int
            let maximumResidentMemoryBytes: UInt64
        }

        struct Runtimes: Decodable {
            let arm64: Runtime
            let x86_64: Runtime

            var current: Runtime {
#if arch(x86_64)
                x86_64
#else
                arm64
#endif
            }
        }

        let releaseID: String
        let runtime: Runtimes
    }

    @MainActor
    func testOfflineNavigationRestorationRecoveryLifecycleAndBudgets() async throws {
#if !BLAU_CHROMIUM_REAL_ENGINE_TESTS
        try XCTSkipUnless(
            false,
            "Run apple/bin/test-chromium-runtime.sh with the pinned CEF runtime."
        )
#else

        let fixtureDirectory = try ChromiumFixtureServer
            .bundledFixtureDirectory()
        let server = try ChromiumFixtureServer(
            fixtureDirectory: fixtureDirectory
        )
        try server.start()
        defer { server.stop() }
        let tlsServer = try ChromiumOpenSSLFixtureServer.bundled()
        try tlsServer.start()
        defer { tlsServer.stop() }

        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pilot-chromium-smoke-\(UUID().uuidString)",
                isDirectory: true
            )
        let applicationSupport = temporaryRoot.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        let profileLocation = ChromiumProfileLocation(
            applicationSupportDirectory: applicationSupport
        )
        let profileDirectory = profileLocation.defaultProfileURL
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        let report = try await ChromiumRuntimeProbe.run(
            profileDirectory: profileDirectory,
            firstURL: server.baseURL,
            secondURL: server.baseURL.appendingPathComponent(
                "second-page.html"
            ),
            invalidCertificateURL: tlsServer.baseURL,
            // The release gate runs on shared CI VMs; give each phase room
            // for cold-start latency and let the budgets be the contract.
            timeout: 60
        )
        let budgets = try performanceBudgets()
        let runtimeBudget = budgets.runtime.current

        XCTAssertEqual(report.firstJavaScriptTitle, "Cockpit Chromium probe first")
        XCTAssertEqual(report.secondJavaScriptTitle, "Cockpit Chromium probe second")
        XCTAssertEqual(report.survivingBrowserTitle, "Cockpit Chromium probe survivor")
        XCTAssertEqual(report.historyBackURL, server.baseURL)
        XCTAssertEqual(
            report.historyForwardURL,
            server.baseURL.appendingPathComponent("second-page.html")
        )
        XCTAssertEqual(report.restoredBrowserTitle, "Cockpit Chromium probe restored")
        XCTAssertEqual(
            report.policy.blockedNavigationURL,
            URL(fileURLWithPath: "/etc/passwd")
        )
        XCTAssertEqual(
            report.policy.blockedScriptPopupTitle,
            "Cockpit Chromium script popup blocked"
        )
        XCTAssertEqual(
            report.policy.interceptedPopupURL,
            server.baseURL.appendingPathComponent("second-page.html")
        )
        XCTAssertGreaterThan(report.policy.deniedPermissionRequests, 0)
        XCTAssertTrue(report.policy.deniedGeolocationPermission)
        XCTAssertGreaterThan(report.policy.deniedFileChooserRequests, 0)
        XCTAssertEqual(
            report.policy.deniedDownloadURL,
            server.baseURL.appendingPathComponent("download.txt")
        )
        XCTAssertGreaterThan(
            report.policy.deniedAuthenticationRequests,
            0
        )
        XCTAssertEqual(
            report.policy.deniedAuthenticationURL.flatMap(
                ChromiumOrigin.init(url:)
            ),
            ChromiumOrigin(url: server.baseURL)
        )
        XCTAssertFalse(report.policy.rejectedCertificateErrors.isEmpty)
        XCTAssertTrue(
            report.policy.rejectedCertificateErrors.allSatisfy { $0 < 0 }
        )
        XCTAssertEqual(
            report.policy.rejectedCertificateURL.flatMap(
                ChromiumOrigin.init(url:)
            ),
            ChromiumOrigin(url: tlsServer.baseURL)
        )
        XCTAssertEqual(
            report.policy.hostileMessageSurvivorTitle,
            "Cockpit Chromium hostile messages ignored"
        )
        XCTAssertEqual(
            report.rendererRecoveryTitle,
            "Cockpit Chromium probe renderer recovered"
        )
        XCTAssertGreaterThanOrEqual(report.rendererTerminationStatus, 0)
        XCTAssertEqual(report.peakBrowserCount, 2)
        XCTAssertEqual(report.browserCountAfterFirstClose, 1)
        XCTAssertEqual(report.browserCountAfterSecondClose, 0)
        XCTAssertEqual(report.browserCountAfterRecoveryClose, 0)
        XCTAssertEqual(report.helperProcessCountAfterShutdown, 0)
        XCTAssertTrue(report.rendererHelperLaunched)
        XCTAssertTrue(report.gpuHelperLaunched)
        XCTAssertEqual(
            budgets.releaseID,
            ChromiumArtifactRevision.releaseID
        )
        XCTAssertLessThanOrEqual(
            report.startupDuration,
            runtimeBudget.maximumStartupSeconds,
            "CEF startup took \(report.startupDuration) seconds."
        )
        XCTAssertLessThanOrEqual(
            report.firstNavigationDuration,
            runtimeBudget.maximumFirstNavigationSeconds,
            "First offline navigation took "
                + "\(report.firstNavigationDuration) seconds."
        )
        XCTAssertLessThanOrEqual(
            report.helperCleanupDuration,
            runtimeBudget.maximumHelperCleanupSeconds,
            "CEF helper cleanup took "
                + "\(report.helperCleanupDuration) seconds."
        )
        XCTAssertLessThanOrEqual(
            report.idleCPUPercent,
            runtimeBudget.maximumIdleCPUPercent,
            "Idle Chromium process-tree CPU was "
                + "\(report.idleCPUPercent) percent."
        )
        XCTAssertLessThanOrEqual(
            report.idleMessagePumpWatchdogWorkCount,
            runtimeBudget.maximumIdleMessagePumpWatchdogWorkCount,
            "Idle Chromium watchdog executed "
                + "\(report.idleMessagePumpWatchdogWorkCount) turns."
        )
        XCTAssertLessThanOrEqual(
            report.residentMemoryBytes,
            runtimeBudget.maximumResidentMemoryBytes,
            "Chromium process-tree resident memory was "
                + "\(report.residentMemoryBytes) bytes."
        )

        let entriesBeforeClear = try FileManager.default.contentsOfDirectory(
            atPath: profileDirectory.path
        )
        XCTAssertFalse(entriesBeforeClear.isEmpty)
        let clearMarker = profileDirectory.appendingPathComponent(
            "pilot-clear-probe"
        )
        try Data("remove me".utf8).write(to: clearMarker)
        try await ChromiumProfileAccessCoordinator.shared.clearProfile(
            at: profileDirectory,
            location: profileLocation
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: profileDirectory.path
            ),
            []
        )
#endif
    }

    private func performanceBudgets() throws -> PerformanceBudgets {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(
            bundle.url(
                forResource: "performance-budgets",
                withExtension: "json"
            )
        )
        return try JSONDecoder().decode(
            PerformanceBudgets.self,
            from: Data(contentsOf: url)
        )
    }
}
