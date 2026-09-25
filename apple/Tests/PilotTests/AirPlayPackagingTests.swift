import Foundation
import XCTest
@testable import Pilot

final class AirPlayPackagingTests: XCTestCase {
    func testAppDeclaresBothWirelessDiscoveryServices() throws {
        let services = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String])
        XCTAssertTrue(services.contains("_airplay._tcp"))
        XCTAssertTrue(services.contains("_raop._tcp"))
        let description = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription") as? String)
        XCTAssertFalse(description.isEmpty)
    }

    func testBundleDatesInvalidateCachedBonjourMetadataAfterUpdates() throws {
        let app = Bundle.main.bundleURL
        let contents = app.appendingPathComponent("Contents")
        let info = contents.appendingPathComponent("Info.plist")
        let helper = try XCTUnwrap(Bundle.main.url(forAuxiliaryExecutable: "CockpitAirPlayReceiver"))
        let inputs = try [info, helper].map {
            try XCTUnwrap($0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        }
        for directory in [app, contents] {
            let modified = try XCTUnwrap(directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            for input in inputs {
                XCTAssertGreaterThanOrEqual(modified, input,
                    "Stale bundle dates let macOS reuse Bonjour declarations from before the update")
            }
        }
    }

    func testBundledReceiverStartsAndStopsWithoutBlocking() async throws {
        let helper = try XCTUnwrap(Bundle.main.url(forAuxiliaryExecutable: "CockpitAirPlayReceiver"))
        let worker = AirPlayReceiverWorker()
        defer { worker.cancel() }
        worker.run(executable: helper, arguments: ["--receive", "made Test \(UUID().uuidString.prefix(8))"],
                   consume: { _ in false })
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while worker.snapshot == .starting, ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(worker.snapshot, .waiting)
        worker.cancel()
        let shutdownDeadline = ProcessInfo.processInfo.systemUptime + 2
        while !worker.isFinished, ProcessInfo.processInfo.systemUptime < shutdownDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(worker.isFinished)
        XCTAssertEqual(worker.snapshot, .stopped)
    }

    func testReceiverSourceAndLicensesShipWithApp() throws {
        let resources = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("AirPlay")
        for name in ["LICENSE-UxPlay", "LICENSE-libplist", "LICENSE-OpenSSL",
                     "Sources/main.cpp", "Sources/bounds.patch", "Sources/tests.cpp", "Sources/build-airplay-receiver.sh",
                     "Sources/uxplay.tar.gz", "Sources/libplist.tar.bz2", "Sources/openssl.tar.gz"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: resources.appendingPathComponent(name).path), name)
        }
    }

    func testBundledReceiverAcceptsDisplayedPINWithRealSRPProof() async throws {
        let apple = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let script = apple.appendingPathComponent("bin/check-airplay-receiver.py")
        let result: ProcessRunResult
        do {
            result = try await ProcessRunner.run(ProcessInvocation(
                executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: [script.path, Bundle.main.bundlePath], timeout: .seconds(45)
            ))
        } catch let error as ProcessRunnerError {
            // This checker explicitly omits PINs and authentication payloads.
            // Preserve its diagnostic instead of XCTest printing only byte counts.
            XCTFail(error.result?.standardErrorString ?? error.localizedDescription)
            return
        }
        XCTAssertEqual(result.termination, .exit(0), result.standardErrorString)
        XCTAssertTrue(result.standardOutputString.contains("PIN/SRP authentication"))
    }
}
