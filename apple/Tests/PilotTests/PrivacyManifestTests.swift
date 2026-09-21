import Foundation
import Sparkle
import Synchronization
import Testing
import XCTest
@testable import Pilot

@Suite("Built privacy manifest")
struct PrivacyManifestTests {
    @Test("Pilot declares camera access before opening a device pane")
    func cameraUsageDescriptionIsPresent() {
        let description = Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String
        #expect(description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }

    @Test("made embeds the reviewed Sparkle update policy")
    func sparkleUpdatePolicyIsPresent() {
        #expect(
            Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
                == "https://github.com/joeblau/made/releases/latest/download/appcast.xml"
        )
        #expect(
            Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
                == "BIQoEzT2ALEKrU/qHI6ZCBZXrHMmq+GQxRgy9dCpEBg="
        )
        #expect(Bundle.main.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool == true)
        #expect(Bundle.main.object(forInfoDictionaryKey: "SUEnableInstallerLauncherService") as? Bool == true)
        #expect(Bundle.main.object(forInfoDictionaryKey: "SURequireSignedFeed") as? Bool == true)
        #expect(Bundle.main.object(forInfoDictionaryKey: "SUVerifyUpdateBeforeExtraction") as? Bool == true)
    }

    @Test("The isolated Sparkle installer is embedded and executable")
    func installerServiceIsEmbedded() throws {
        let framework = Bundle(for: SPUUpdater.self)
        let service = try #require(Bundle(url: framework.bundleURL.appendingPathComponent("XPCServices/Installer.xpc")))
        #expect(service.bundleIdentifier == "org.sparkle-project.InstallerLauncher")
        let executable = try #require(service.executableURL)
        #expect(FileManager.default.isExecutableFile(atPath: executable.path))
    }
}

// Matches the pinned Sparkle launcher's wire protocol. Invalid bundle paths
// exercise the real embedded service without launching an update or touching
// the running developer app's installer jobs.
@objc private protocol PilotInstallerLauncherProtocol {
    @objc(launchInstallerWithHostBundlePath:mainBundlePath:installationType:allowingDriverInteraction:completion:)
    func launchInstaller(
        hostBundlePath: String,
        mainBundlePath: String,
        installationType: String,
        allowingDriverInteraction: Bool,
        completion: @escaping @Sendable (UInt, Bool) -> Void
    )
}

final class SparkleInstallerIsolationTests: XCTestCase {
    @MainActor
    func testStalledInstallerDoesNotBlockMainThread() async throws {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "SUEnableInstallerLauncherService") as? Bool, true)
        let connection = NSXPCConnection(serviceName: "org.sparkle-project.InstallerLauncher")
        connection.remoteObjectInterface = NSXPCInterface(with: PilotInstallerLauncherProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        let reply = expectation(description: "Installer rejects invalid bundle paths")
        let proxy = try XCTUnwrap(connection.remoteObjectProxyWithErrorHandler { error in
            XCTFail("Embedded installer service failed: \(error)")
            reply.fulfill()
        } as? PilotInstallerLauncherProtocol)
        let missing = "/nonexistent-cockpit-installer-test-\(UUID().uuidString).app"
        proxy.launchInstaller(
            hostBundlePath: missing,
            mainBundlePath: missing,
            installationType: "application",
            allowingDriverInteraction: false
        ) { status, _ in
            XCTAssertEqual(status, 4) // SUInstallerLauncherFailure
            reply.fulfill()
        }

        await fulfillment(of: [reply], timeout: 5)

        // Stall only this test host's connected helper, never the application
        // or launchd. This reproduces an installer that cannot make progress.
        let helperPID = connection.processIdentifier
        guard helperPID > 1, helperPID != ProcessInfo.processInfo.processIdentifier else {
            XCTFail("Installer must execute in a separate process")
            return
        }
        guard kill(helperPID, SIGSTOP) == 0 else {
            XCTFail("Could not suspend the connected test installer")
            return
        }
        defer { kill(helperPID, SIGCONT) }

        let completed = Mutex(false)
        let resumedReply = expectation(description: "Installer responds after resuming")
        proxy.launchInstaller(
            hostBundlePath: missing,
            mainBundlePath: missing,
            installationType: "application",
            allowingDriverInteraction: false
        ) { status, _ in
            XCTAssertEqual(status, 4)
            completed.withLock { $0 = true }
            resumedReply.fulfill()
        }
        let heartbeat = expectation(description: "Main queue responds while installer is stalled")
        DispatchQueue.main.async { heartbeat.fulfill() }
        await fulfillment(of: [heartbeat], timeout: 1)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(completed.withLock { $0 })

        XCTAssertEqual(kill(helperPID, SIGCONT), 0)
        await fulfillment(of: [resumedReply], timeout: 5)
    }
}
