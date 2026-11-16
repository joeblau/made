import Foundation
import XCTest
@testable import Pilot

final class ChromiumArtifactManifestTests: XCTestCase {
    private struct Manifest: Decodable {
        struct CEF: Decodable {
            let version: String
            let commit: String
            let chromiumCommit: String
            let sandboxCompatibilityCommit: String
            let requiredXcodeMajorVersion: Int
        }

        struct SourceArchive: Decodable {
            let architecture: String
            let distributionDirectory: String
            let url: String
            let bytes: Int
            let sha1: String
            let sha256: String
        }

        struct HelperLayout: Decodable {
            struct Helper: Decodable {
                let role: String
                let bundleName: String
                let executableName: String
                let bundleIdentifierSuffix: String
                let entitlements: String?
            }

            let destination: String
            let bundleIdentifierBase: String
            let lsUIElement: Bool
            let helpers: [Helper]
        }

        struct Security: Decodable {
            let chromiumSandboxRequired: Bool
            let rejectedArguments: [String]
            let jitEntitledRoles: [String]
            let entitlementFreeRoles: [String]
            let forbiddenCodesignArguments: [String]
        }

        struct ArtifactLayout: Decodable {
            let license: String
            let credits: String
        }

        let schemaVersion: Int
        let releaseID: String
        let cef: CEF
        let sourceArchives: [SourceArchive]
        let artifactLayout: ArtifactLayout
        let helperLayout: HelperLayout
        let security: Security
    }

    private struct ExpectedArchive {
        let bytes: Int
        let sha1: String
        let sha256: String
        let distributionSuffix: String
    }

    private struct ExpectedHelper {
        let bundleName: String
        let executableName: String
        let bundleIdentifierSuffix: String
        let entitlements: String?
    }

    private struct PerformanceBudgets: Decodable {
        struct Artifact: Decodable {
            let maximumCompressedBytes: Int
            let maximumInstalledBytes: Int
        }

        struct Runtime: Decodable {
            let maximumStartupSeconds: TimeInterval
            let maximumFirstNavigationSeconds: TimeInterval
            let maximumHelperCleanupSeconds: TimeInterval
            let maximumIdleCPUPercent: Double
            let maximumIdleMessagePumpWatchdogWorkCount: Int
            let maximumResidentMemoryBytes: UInt64
        }

        let schemaVersion: Int
        let releaseID: String
        let artifact: Artifact
        let runtime: [String: Runtime]
    }

    func testSchemaAndUpstreamRevisionArePinned() throws {
        let manifest = try loadManifest()

        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(
            manifest.releaseID,
            "150.0.14-g7c1aa68-chromium-150.0.7871.129-blau.1"
        )
        XCTAssertEqual(
            manifest.cef.version,
            "150.0.14+g7c1aa68+chromium-150.0.7871.129"
        )
        XCTAssertEqual(
            manifest.cef.commit,
            "7c1aa68455db1f1fad159c2b83070ad318212b3d"
        )
        XCTAssertEqual(
            manifest.cef.chromiumCommit,
            "e69b30bba288603e514cffb4c79c359cac68e923"
        )
        XCTAssertEqual(
            manifest.cef.sandboxCompatibilityCommit,
            "6c5b35ad81055c14"
        )
        XCTAssertEqual(manifest.cef.requiredXcodeMajorVersion, 27)
        XCTAssertEqual(
            ChromiumArtifactRevision.releaseID,
            manifest.releaseID
        )
        XCTAssertEqual(
            ChromiumArtifactRevision.cefVersion,
            manifest.cef.version
        )
        XCTAssertEqual(
            ChromiumArtifactRevision.cefCommit,
            manifest.cef.commit
        )
        XCTAssertEqual(
            ChromiumArtifactRevision.chromiumVersion,
            try XCTUnwrap(
                manifest.cef.version
                    .components(separatedBy: "+chromium-")
                    .last
            )
        )
        XCTAssertEqual(
            ChromiumArtifactRevision.chromiumCommit,
            manifest.cef.chromiumCommit
        )
    }

    func testSourceArchivesUseImmutableURLsAndExactIntegrityMetadata() throws {
        let manifest = try loadManifest()
        let expected: [String: ExpectedArchive] = [
            "arm64": ExpectedArchive(
                bytes: 124_572_272,
                sha1: "47baa745213c938861861f0f3f65c6dd03e7254e",
                sha256: "293048b4f49e0853f2e13394ef3d57d55da7733340e51407e38d826b8ab5a200",
                distributionSuffix: "_macosarm64_minimal"
            ),
            "x86_64": ExpectedArchive(
                bytes: 130_699_221,
                sha1: "c0591785a04404e2301cb1e216b6508231445dde",
                sha256: "a5c202571d18ee0ab2f65771c3b00baad5e954e5cf9c69bd9ad42bdb9016ec80",
                distributionSuffix: "_macosx64_minimal"
            ),
        ]

        XCTAssertEqual(Set(manifest.sourceArchives.map(\.architecture)), Set(expected.keys))
        XCTAssertEqual(manifest.sourceArchives.count, expected.count)

        for archive in manifest.sourceArchives {
            let expectation = try XCTUnwrap(expected[archive.architecture])
            let components = try XCTUnwrap(URLComponents(string: archive.url))

            XCTAssertEqual(components.scheme, "https")
            XCTAssertEqual(components.host, "cef-builds.spotifycdn.com")
            XCTAssertTrue(
                archive.url.contains(
                    "150.0.14%2Bg7c1aa68%2Bchromium-150.0.7871.129"
                )
            )
            for floatingToken in ["/latest/", "/main/", "/master/", "nightly"] {
                XCTAssertFalse(archive.url.lowercased().contains(floatingToken))
            }

            XCTAssertTrue(
                archive.distributionDirectory.hasPrefix(
                    "cef_binary_150.0.14+g7c1aa68+chromium-150.0.7871.129"
                )
            )
            XCTAssertTrue(
                archive.distributionDirectory.hasSuffix(
                    expectation.distributionSuffix
                )
            )
            XCTAssertEqual(archive.bytes, expectation.bytes)
            XCTAssertEqual(archive.sha1, expectation.sha1)
            XCTAssertEqual(archive.sha256, expectation.sha256)
            XCTAssertTrue(isLowercaseHex(archive.sha1, count: 40))
            XCTAssertTrue(isLowercaseHex(archive.sha256, count: 64))
        }
    }

    func testHelperSetAndEntitlementsMatchChromium150Policy() throws {
        let manifest = try loadManifest()
        let expected: [String: ExpectedHelper] = [
            "base": ExpectedHelper(
                bundleName: "Pilot Helper.app",
                executableName: "Pilot Helper",
                bundleIdentifierSuffix: "",
                entitlements: nil
            ),
            "alerts": ExpectedHelper(
                bundleName: "Pilot Helper (Alerts).app",
                executableName: "Pilot Helper (Alerts)",
                bundleIdentifierSuffix: ".alerts",
                entitlements: nil
            ),
            "gpu": ExpectedHelper(
                bundleName: "Pilot Helper (GPU).app",
                executableName: "Pilot Helper (GPU)",
                bundleIdentifierSuffix: ".gpu",
                entitlements: "Sources/PilotChromiumHelper/GPU.entitlements"
            ),
            "plugin": ExpectedHelper(
                bundleName: "Pilot Helper (Plugin).app",
                executableName: "Pilot Helper (Plugin)",
                bundleIdentifierSuffix: ".plugin",
                entitlements: nil
            ),
            "renderer": ExpectedHelper(
                bundleName: "Pilot Helper (Renderer).app",
                executableName: "Pilot Helper (Renderer)",
                bundleIdentifierSuffix: ".renderer",
                entitlements: "Sources/PilotChromiumHelper/Renderer.entitlements"
            ),
        ]

        XCTAssertEqual(manifest.helperLayout.destination, "Contents/Frameworks")
        XCTAssertEqual(
            manifest.helperLayout.bundleIdentifierBase,
            "app.blau.pilot.helper"
        )
        XCTAssertTrue(manifest.helperLayout.lsUIElement)
        XCTAssertEqual(Set(manifest.helperLayout.helpers.map(\.role)), Set(expected.keys))
        XCTAssertEqual(manifest.helperLayout.helpers.count, expected.count)

        for helper in manifest.helperLayout.helpers {
            let expectation = try XCTUnwrap(expected[helper.role])
            XCTAssertEqual(helper.bundleName, expectation.bundleName)
            XCTAssertEqual(helper.executableName, expectation.executableName)
            XCTAssertEqual(
                helper.bundleIdentifierSuffix,
                expectation.bundleIdentifierSuffix
            )
            XCTAssertEqual(helper.entitlements, expectation.entitlements)
        }

        XCTAssertTrue(manifest.security.chromiumSandboxRequired)
        XCTAssertEqual(manifest.security.rejectedArguments, ["--no-sandbox"])
        XCTAssertEqual(
            Set(manifest.security.jitEntitledRoles),
            Set(["gpu", "renderer"])
        )
        XCTAssertEqual(
            Set(manifest.security.entitlementFreeRoles),
            Set(["base", "alerts", "plugin"])
        )
        XCTAssertEqual(
            manifest.security.forbiddenCodesignArguments,
            ["--deep"]
        )
    }

    func testLegalNoticeInputsArePinnedInTheArtifactLayout() throws {
        let manifest = try loadManifest()

        XCTAssertEqual(
            manifest.artifactLayout.license,
            "Artifacts/CEF/LICENSE.txt"
        )
        XCTAssertEqual(
            manifest.artifactLayout.credits,
            "Artifacts/CEF/CREDITS.html"
        )
    }

    func testPerformanceBudgetsArePinnedToThisRelease() throws {
        let manifest = try loadManifest()
        let budgets = try loadPerformanceBudgets()

        XCTAssertEqual(budgets.schemaVersion, 1)
        XCTAssertEqual(budgets.releaseID, manifest.releaseID)
        XCTAssertEqual(budgets.artifact.maximumCompressedBytes, 265_000_000)
        XCTAssertEqual(budgets.artifact.maximumInstalledBytes, 625_000_000)
        XCTAssertEqual(Set(budgets.runtime.keys), ["arm64", "x86_64"])
        let arm64 = try XCTUnwrap(budgets.runtime["arm64"])
        XCTAssertEqual(arm64.maximumStartupSeconds, 5)
        XCTAssertEqual(arm64.maximumFirstNavigationSeconds, 2)
        XCTAssertEqual(arm64.maximumHelperCleanupSeconds, 5)
        XCTAssertEqual(arm64.maximumIdleCPUPercent, 35)
        XCTAssertEqual(arm64.maximumIdleMessagePumpWatchdogWorkCount, 12)
        XCTAssertEqual(arm64.maximumResidentMemoryBytes, 1_250_000_000)
        let x86 = try XCTUnwrap(budgets.runtime["x86_64"])
        XCTAssertEqual(x86.maximumStartupSeconds, 240)
        XCTAssertEqual(x86.maximumFirstNavigationSeconds, 8)
        XCTAssertEqual(x86.maximumHelperCleanupSeconds, 10)
        XCTAssertEqual(x86.maximumIdleCPUPercent, 80)
        XCTAssertEqual(x86.maximumIdleMessagePumpWatchdogWorkCount, 30)
        XCTAssertEqual(x86.maximumResidentMemoryBytes, 1_500_000_000)
    }

    private func loadManifest() throws -> Manifest {
        let appleRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifestURL = appleRoot
            .appendingPathComponent("Packages")
            .appendingPathComponent("ChromiumKit")
            .appendingPathComponent("cef-artifacts.json")
        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    private func loadPerformanceBudgets() throws -> PerformanceBudgets {
        let appleRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let budgetsURL = appleRoot
            .appendingPathComponent("Packages")
            .appendingPathComponent("ChromiumKit")
            .appendingPathComponent("performance-budgets.json")
        return try JSONDecoder().decode(
            PerformanceBudgets.self,
            from: Data(contentsOf: budgetsURL)
        )
    }

    private func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.range(
            of: "^[0-9a-f]{\(count)}$",
            options: .regularExpression
        ) != nil
    }
}
