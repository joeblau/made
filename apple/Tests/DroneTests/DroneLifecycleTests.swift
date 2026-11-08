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

    func testWorkerDirectoriesArePrivateAndMarkersCannotClaimPairing() throws {
        let paths = makePaths()
        try paths.prepareWorkerDirectories()
        for directory in [paths.root, paths.configuration, paths.state, paths.identity,
                          paths.pairings, paths.runtime, paths.logs] {
            XCTAssertTrue(DroneFileSystem.hasMode(directory, mode: 0o700))
        }

        let marker = paths.pairings.appendingPathComponent("stable-peer-id")
        let secret = Data("private-pairing-material-that-must-not-be-read".utf8)
        try secret.write(to: marker)
        try DroneFileSystem.setMode(0o600, for: marker)
        let response = DroneControlResponse(paths: paths)
        XCTAssertFalse(response.paired)
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

    func testEnabledWorkerRequiresLiveListenerAndHealthyStorage() throws {
        let paths = DronePaths(environment: [
            "BLAU_DRONE_ROOT": temporaryRoot.path,
            "BLAU_DRONE_WORKSPACE": temporaryRoot.path,
        ])
        let unavailable = DroneControlResponse(paths: paths)
        XCTAssertEqual(DroneStatusEvaluator.state(response: unavailable, launchdLoaded: true), .unhealthy)
        for health in [
            DroneWorkerHealthSnapshot(listenerReady: false, paired: true, storageHealthy: true),
            DroneWorkerHealthSnapshot(listenerReady: true, paired: true, storageHealthy: false),
        ] {
            let response = DroneControlResponse(paths: paths, workerHealth: health)
            XCTAssertEqual(DroneStatusEvaluator.state(response: response, launchdLoaded: true), .unhealthy)
        }
        let ready = DroneControlResponse(paths: paths, workerHealth: DroneWorkerHealthSnapshot(
            listenerReady: true, paired: true, storageHealthy: true
        ))
        XCTAssertTrue(ready.paired)
        XCTAssertEqual(DroneStatusEvaluator.state(response: ready, launchdLoaded: true), .paired)
        XCTAssertEqual(try DroneControlCodec.decodeResponse(DroneControlCodec.encode(ready)), ready)
    }

    func testDisabledWorkerDoesNotClaimLANListenerAndLegacyHealthFailsClosed() throws {
        let disabled = DroneControlResponse(paths: makePaths())
        XCTAssertEqual(DroneStatusEvaluator.state(response: disabled, launchdLoaded: true), .disabled)
        let legacy = Data("""
        {"version":1,"workerVersion":"1.0.0","protocolVersion":1,"paired":true,
         "processIdentifier":42,"executionEnabled":true,"approvals":[]}
        """.utf8)
        let decoded = try DroneControlCodec.decodeResponse(legacy)
        XCTAssertNil(decoded.workerHealth)
        XCTAssertEqual(DroneStatusEvaluator.state(response: decoded, launchdLoaded: true), .unhealthy)
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
        XCTAssertTrue(DroneVersion.report.contains("execution opt-in"))
    }

    func testControllerGrantOwnerCommandsValidateExactPermissionSets() throws {
        let controller = UUID()
        for command in ["grant", "revoke-grants"] {
            let request = try DroneOwnerCommand.parse([command, controller.uuidString, "terminal,jobs"])
            XCTAssertEqual(request.command, command)
            XCTAssertEqual(request.controllerID, controller)
            XCTAssertEqual(request.permissions, ["terminal", "jobs"])
            XCTAssertNil(request.workspaceID)
            XCTAssertNil(request.lifetimeSeconds)
            try request.validate()
        }
        let toolLease = try DroneOwnerCommand.parse([
            "grant-tools", controller.uuidString, "00000000-0000-0000-0000-000000000001", "files,git", "60",
        ])
        XCTAssertEqual(toolLease.permissions, ["files", "git"])
        XCTAssertEqual(toolLease.lifetimeSeconds, 60)

        for arguments in [
            ["grant", controller.uuidString, ""],
            ["grant", controller.uuidString, "terminal,terminal"],
            ["grant", controller.uuidString, "terminal,unknown"],
            ["grant", controller.uuidString, "terminal", "extra"],
            ["revoke-grants", "not-a-uuid", "terminal"],
            ["revoke-grants", controller.uuidString, "jobs", "60"],
        ] {
            XCTAssertThrowsError(try DroneOwnerCommand.parse(arguments))
        }
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
            processIdentifier: 42,
            executionEnabled: true,
            workerHealth: DroneWorkerHealthSnapshot(listenerReady: true, paired: paired, storageHealthy: true)
        )
    }
}

final class DroneInstallerTests: XCTestCase {
    private var root: URL!
    private var paths: DronePaths!
    private var source: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("drone-install-\(UUID())")
        paths = DronePaths(environment: ["BLAU_DRONE_ROOT": root.appendingPathComponent("worker").path])
        try paths.prepareInstallationDirectories()
        source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for name in ["drone", "droned"] {
            let executable = source.appendingPathComponent(name)
            try Data("new executable".utf8).write(to: executable)
            try DroneFileSystem.setMode(0o755, for: executable)
        }
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    func testFailedUpgradeRestoresLoadedReleasePlistAndState() throws {
        try preparePrevious()
        let launchd = FakeLaunchd(loaded: true, bootstrapFailures: 1)
        XCTAssertThrowsError(try DroneInstaller(paths: paths, launchd: launchd).install(source: source)) {
            XCTAssertEqual($0 as? DroneWorkerError, .launchdUnavailable)
        }
        try assertPreviousRestored()
        XCTAssertTrue(launchd.isLoaded)
        XCTAssertEqual(launchd.bootstrapCalls, 2)
        XCTAssertEqual(launchd.stopCalls, 2)
        XCTAssertEqual(try releaseNames(), ["old"])
    }

    func testFailedUpgradePreservesStoppedService() throws {
        try preparePrevious()
        let launchd = FakeLaunchd(loaded: false, bootstrapFailures: 1)
        XCTAssertThrowsError(try DroneInstaller(paths: paths, launchd: launchd).install(source: source))
        try assertPreviousRestored()
        XCTAssertFalse(launchd.isLoaded)
        XCTAssertEqual(launchd.bootstrapCalls, 1)
    }

    func testFailedFirstInstallRemovesNewLinkAndPlist() throws {
        let launchd = FakeLaunchd(loaded: false, bootstrapFailures: 1)
        XCTAssertThrowsError(try DroneInstaller(paths: paths, launchd: launchd).install(source: source))
        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: paths.current.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.launchAgent.path))
        XCTAssertEqual(try releaseNames(), [])
        XCTAssertFalse(launchd.isLoaded)
    }

    func testStopFailureDoesNotSwitchReleaseOrPlist() throws {
        try preparePrevious()
        let launchd = FakeLaunchd(loaded: true, bootstrapFailures: 0)
        launchd.failStop = true
        XCTAssertThrowsError(try DroneInstaller(paths: paths, launchd: launchd).install(source: source))
        try assertPreviousRestored()
        XCTAssertTrue(launchd.isLoaded)
        XCTAssertEqual(launchd.bootstrapCalls, 0)
        XCTAssertEqual(try releaseNames(), ["old"])
    }

    func testRollbackFailureRetainsReleasesAndReportsDistinctError() throws {
        try preparePrevious()
        let launchd = FakeLaunchd(loaded: true, bootstrapFailures: 2)
        XCTAssertThrowsError(try DroneInstaller(paths: paths, launchd: launchd).install(source: source)) {
            XCTAssertEqual($0 as? DroneWorkerError, .rollbackFailed)
        }
        try assertPreviousRestored()
        XCTAssertEqual(try releaseNames().count, 2)
    }

    func testRemovalQueryTimeoutPreservesInstallationAndSocket() throws {
        try assertRemovalFailurePreservesFiles(status: nil)
    }

    func testRemovalQueryErrorPreservesInstallationAndSocket() throws {
        try assertRemovalFailurePreservesFiles(status: 5)
    }

    private func assertRemovalFailurePreservesFiles(status: Int32?) throws {
        try preparePrevious()
        try Data("socket fixture".utf8).write(to: paths.controlSocket)
        var bootedOut = false
        let launchd = DroneLaunchd(paths: paths, commandTimeout: 0.1, execute: { args, _ in
            if args.first == "bootout" { bootedOut = true; return 0 }
            if args.first == "print" {
                if !bootedOut { return 0 }
                if let status { return status }
                throw DroneWorkerError.processTimedOut
            }
            return 0
        })
        XCTAssertThrowsError(try DroneInstaller(paths: paths, launchd: launchd).install(source: source))
        try assertPreviousRestored()
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.controlSocket.path))
        XCTAssertEqual(try releaseNames(), ["old"])
        XCTAssertThrowsError(try DroneInstaller(paths: paths, launchd: launchd).uninstall())
        try assertPreviousRestored()
    }

    func testInitialQueryErrorDoesNotMutateInstallation() throws {
        try preparePrevious()
        let launchd = DroneLaunchd(paths: paths, execute: { _, _ in 5 })
        XCTAssertThrowsError(try DroneInstaller(paths: paths, launchd: launchd).install(source: source))
        try assertPreviousRestored()
        XCTAssertEqual(try releaseNames(), ["old"])
    }

    func testRemovalWaitsForConfirmedAbsence() throws {
        try Data("socket fixture".utf8).write(to: paths.controlSocket)
        var prints = 0
        var budgets: [TimeInterval] = []
        let launchd = DroneLaunchd(paths: paths, commandTimeout: 0.5, execute: { args, timeout in
            budgets.append(timeout)
            if args.first == "print" {
                prints += 1
                return prints < 3 ? 0 : 113
            }
            return 0
        })
        try launchd.stop()
        XCTAssertEqual(prints, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.controlSocket.path))
        XCTAssertTrue(zip(budgets, budgets.dropFirst()).allSatisfy { $0 >= $1 })
        XCTAssertLessThan(try XCTUnwrap(budgets.last), 0.5)
    }

    func testRemovalTimeoutKeepsSocketWhileLoaded() throws {
        try Data("socket fixture".utf8).write(to: paths.controlSocket)
        let launchd = DroneLaunchd(paths: paths, commandTimeout: 0.05, execute: { _, _ in 0 })
        XCTAssertThrowsError(try launchd.stop()) {
            XCTAssertEqual($0 as? DroneWorkerError, .processTimedOut)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.controlSocket.path))
    }

    private func preparePrevious() throws {
        let old = paths.releases.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("old executable".utf8).write(to: old.appendingPathComponent("droned"))
        try DroneFileSystem.replaceSymbolicLink(target: "releases/old", at: paths.current)
        try DroneFileSystem.writeAtomically(Data("old plist".utf8), to: paths.launchAgent, mode: 0o600)
        try Data("retained state".utf8).write(to: paths.state.appendingPathComponent("fixture"))
    }

    private func assertPreviousRestored() throws {
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: paths.current.path), "releases/old")
        XCTAssertEqual(try Data(contentsOf: paths.launchAgent), Data("old plist".utf8))
        XCTAssertTrue(DroneFileSystem.hasMode(paths.launchAgent, mode: 0o600))
        XCTAssertEqual(try Data(contentsOf: paths.installedDaemon), Data("old executable".utf8))
        XCTAssertEqual(try Data(contentsOf: paths.state.appendingPathComponent("fixture")), Data("retained state".utf8))
    }

    private func releaseNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: paths.releases.path).sorted()
    }
}

private final class FakeLaunchd: DroneLaunchdManaging {
    var isLoaded: Bool
    var bootstrapFailures: Int
    var bootstrapCalls = 0
    var stopCalls = 0
    var failStop = false

    init(loaded: Bool, bootstrapFailures: Int) {
        isLoaded = loaded
        self.bootstrapFailures = bootstrapFailures
    }

    func bootstrap() throws {
        bootstrapCalls += 1
        // Model launchctl loading a job even when bootstrap reports failure.
        isLoaded = true
        if bootstrapFailures > 0 {
            bootstrapFailures -= 1
            throw DroneWorkerError.launchdUnavailable
        }
    }

    func stop() throws {
        stopCalls += 1
        if failStop { throw DroneWorkerError.operationFailed }
        isLoaded = false
    }
}
