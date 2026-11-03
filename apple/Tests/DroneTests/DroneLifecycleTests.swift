import Darwin
import Foundation
import XCTest

final class DroneLifecycleTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("drone-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        try DroneFileSystem.setMode(0o700, for: temporaryRoot)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot { try? FileManager.default.removeItem(at: temporaryRoot) }
    }

    func testWorkerDirectoriesArePrivateAndPairingMarkersStayOpaque() throws {
        let paths = makePaths()
        try paths.prepareWorkerDirectories()
        for directory in [paths.root, paths.configuration, paths.state, paths.identity,
                          paths.pairings, paths.runtime, paths.logs] {
            XCTAssertTrue(DroneFileSystem.hasMode(directory, mode: 0o700))
        }
        XCTAssertFalse(paths.hasPairingState())

        let marker = paths.pairings.appendingPathComponent("stable-peer-id")
        let secret = Data("private-pairing-material-that-must-not-be-read".utf8)
        try secret.write(to: marker)
        try DroneFileSystem.setMode(0o600, for: marker)
        XCTAssertTrue(paths.hasPairingState())
        let response = DroneControlResponse(paths: paths)
        XCTAssertTrue(response.paired)
        let encoded = try DroneControlCodec.encode(response)
        XCTAssertFalse(encoded.contains(secret))
    }

    func testSymlinkedPrivateDirectoryIsRejected() throws {
        let paths = makePaths()
        let elsewhere = temporaryRoot.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: paths.root.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertEqual(symlink(elsewhere.path, paths.root.path), 0)
        XCTAssertThrowsError(try paths.prepareWorkerDirectories()) {
            XCTAssertEqual($0 as? DroneWorkerError, .unsafeFile)
        }
    }

    func testLaunchAgentPolicyIsPerUserAndCrashSupervised() throws {
        let paths = makePaths()
        let plist = DroneLaunchAgent.dictionary(paths: paths)
        XCTAssertEqual(plist["Label"] as? String, "app.blau.drone.test")
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [paths.installedDaemon.path])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["KeepAlive"] as? [String: Bool], ["SuccessfulExit": false])
        XCTAssertEqual(plist["ThrottleInterval"] as? Int, 5)
        XCTAssertEqual(plist["ExitTimeOut"] as? Int, 10)
        XCTAssertEqual(plist["StandardOutPath"] as? String, "/dev/null")
        XCTAssertEqual(plist["StandardErrorPath"] as? String, "/dev/null")
        XCTAssertFalse(plist.keys.contains("AbandonProcessGroup"))
        XCTAssertFalse(plist.keys.contains("UserName"))
        XCTAssertEqual(paths.daemonEnvironment["BLAU_DRONE_ROOT"], paths.root.path)
    }

    func testLogsRotateWithTwoBoundedPrivateGenerations() throws {
        let paths = makePaths()
        try paths.prepareWorkerDirectories()
        let file = paths.logs.appendingPathComponent("test.log")
        let log = DroneLog(file: file, limit: 256)
        for index in 0..<200 { log.record("event.\(index)") }
        XCTAssertTrue(log.isBounded())
        XCTAssertLessThanOrEqual(log.totalSize(), 512)
        XCTAssertTrue(DroneFileSystem.hasMode(file, mode: 0o600))
        let rotated = file.appendingPathExtension("1")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: rotated.path),
            "active=\(file.path) rotated=\(rotated.path) total=\(log.totalSize())"
        )
        var info = stat()
        XCTAssertEqual(lstat(rotated.path, &info), 0)
        XCTAssertEqual(info.st_uid, getuid())
        XCTAssertEqual(info.st_mode & 0o7777, 0o600)
    }

    func testStatusDistinguishesEveryOperationalState() {
        let listening = response(paired: false)
        XCTAssertEqual(DroneStatusEvaluator.state(response: nil, launchdLoaded: false), .stopped)
        XCTAssertEqual(DroneStatusEvaluator.state(response: listening, launchdLoaded: true), .listening)
        XCTAssertEqual(DroneStatusEvaluator.state(response: response(paired: true), launchdLoaded: true), .paired)
        XCTAssertEqual(DroneStatusEvaluator.state(response: nil, launchdLoaded: true), .unhealthy)
        XCTAssertEqual(
            DroneStatusEvaluator.state(response: response(protocolVersion: 2), launchdLoaded: true),
            .incompatible
        )
        XCTAssertEqual(
            DroneStatusEvaluator.state(response: response(controlVersion: 2), launchdLoaded: true),
            .incompatible
        )
    }

    func testControlRepliesContainNoStatePathsOrPairingIdentifiers() throws {
        let paths = makePaths()
        let response = DroneControlResponse(paths: paths)
        let data = try DroneControlCodec.encode(response)
        let rendered = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(rendered.contains(paths.root.path))
        XCTAssertFalse(rendered.contains("pairing"))
        XCTAssertEqual(try DroneControlCodec.decodeResponse(data), response)
        XCTAssertThrowsError(try DroneControlCodec.decodeResponse(Data(repeating: 1, count: 16 * 1_024 + 1)))
    }

    func testAtomicPlistReplacementAndVersionReporting() throws {
        let paths = makePaths()
        try paths.prepareInstallationDirectories()
        let first = try DroneLaunchAgent.encode(paths: paths)
        try DroneFileSystem.writeAtomically(first, to: paths.launchAgent, mode: 0o644)
        try DroneFileSystem.writeAtomically(first, to: paths.launchAgent, mode: 0o644)
        XCTAssertTrue(DroneFileSystem.hasMode(paths.launchAgent, mode: 0o644))
        let decoded = try PropertyListSerialization.propertyList(from: first, format: nil) as? NSDictionary
        XCTAssertEqual(decoded, DroneLaunchAgent.dictionary(paths: paths) as NSDictionary)
        XCTAssertTrue(DroneVersion.report.contains("protocol 1"))
        XCTAssertTrue(DroneVersion.report.contains("execution disabled"))
    }

    func testUnixSocketPathsAreBoundedBeforeAllocation() {
        let longRoot = temporaryRoot.appendingPathComponent(String(repeating: "x", count: 120))
        let paths = DronePaths(environment: [
            "BLAU_DRONE_ROOT": longRoot.path,
            "BLAU_DRONE_LABEL": "app.blau.drone.test",
        ])
        XCTAssertThrowsError(try paths.validateSocketPath())
        XCTAssertThrowsError(try DroneUnixSocket.address(for: paths.controlSocket))
    }

    private func makePaths() -> DronePaths {
        DronePaths(environment: [
            "BLAU_DRONE_ROOT": temporaryRoot.appendingPathComponent("worker", isDirectory: true).path,
            "BLAU_DRONE_LABEL": "app.blau.drone.test",
            "BLAU_DRONE_LOG_LIMIT": "1024",
        ])
    }

    private func response(
        paired: Bool = false,
        protocolVersion: UInt16 = 1,
        controlVersion: Int = 1
    ) -> DroneControlResponse {
        DroneControlResponse(
            version: controlVersion,
            workerVersion: DroneVersion.marketing,
            protocolVersion: protocolVersion,
            paired: paired,
            processIdentifier: 42
        )
    }
}
