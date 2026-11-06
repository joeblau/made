import Darwin
import Foundation

protocol DroneLaunchdManaging {
    var isLoaded: Bool { get }
    func bootstrap() throws
    func stop() throws
}

struct DroneLaunchd: DroneLaunchdManaging {
    let paths: DronePaths
    var commandTimeout: TimeInterval = 10

    private var domain: String { "gui/\(getuid())" }
    private var service: String { "\(domain)/\(paths.label)" }

    var isLoaded: Bool {
        (try? runLaunchd(["print", service])) == 0
    }

    func bootstrap() throws {
        guard try runLaunchd(["bootstrap", domain, paths.launchAgent.path]) == 0 else {
            throw DroneWorkerError.launchdUnavailable
        }
    }

    func start() throws {
        guard FileManager.default.fileExists(atPath: paths.launchAgent.path) else {
            throw DroneWorkerError.notInstalled
        }
        if isLoaded {
            guard try runLaunchd(["kickstart", service]) == 0 else {
                throw DroneWorkerError.operationFailed
            }
        } else {
            try bootstrap()
        }
    }

    func stop() throws {
        guard isLoaded else {
            try? FileManager.default.removeItem(at: paths.controlSocket)
            return
        }
        guard try runLaunchd(["bootout", service]) == 0 else {
            throw DroneWorkerError.operationFailed
        }
        let deadline = Date().addingTimeInterval(commandTimeout)
        while isLoaded {
            guard Date() < deadline else { throw DroneWorkerError.processTimedOut }
            usleep(50_000)
        }
        try? FileManager.default.removeItem(at: paths.controlSocket)
    }

    func restart() throws {
        guard FileManager.default.fileExists(atPath: paths.launchAgent.path) else {
            throw DroneWorkerError.notInstalled
        }
        if isLoaded {
            bootoutIgnoringErrors()
        }
        try bootstrap()
    }

    func bootoutIgnoringErrors() {
        _ = try? runLaunchd(["bootout", service])
        let deadline = Date().addingTimeInterval(commandTimeout)
        while isLoaded, Date() < deadline {
            usleep(50_000)
        }
    }

    private func runLaunchd(_ arguments: [String]) throws -> Int32 {
        try DroneProcess.run(
            executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: arguments,
            timeout: commandTimeout
        )
    }
}

struct DroneInstaller {
    let paths: DronePaths
    let launchd: any DroneLaunchdManaging

    func install(source: URL) throws {
        try paths.prepareInstallationDirectories()
        let sourceCLI = source.appendingPathComponent("drone")
        let sourceDaemon = source.appendingPathComponent("droned")
        try DroneFileSystem.requireExecutable(sourceCLI)
        try DroneFileSystem.requireExecutable(sourceDaemon)

        let previous = try DroneInstallationSnapshot(paths: paths, wasLoaded: launchd.isLoaded)
        let release = paths.releases.appendingPathComponent(
            "\(DroneVersion.marketing)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: release, withIntermediateDirectories: false)
        try DroneFileSystem.setMode(0o700, for: release)
        var stoppedPrevious = false
        do {
            try FileManager.default.copyItem(at: sourceCLI, to: release.appendingPathComponent("drone"))
            try FileManager.default.copyItem(at: sourceDaemon, to: release.appendingPathComponent("droned"))
            try DroneFileSystem.setMode(0o755, for: release.appendingPathComponent("drone"))
            try DroneFileSystem.setMode(0o755, for: release.appendingPathComponent("droned"))
            let plist = try DroneLaunchAgent.encode(paths: paths)

            try launchd.stop()
            stoppedPrevious = true
            try DroneFileSystem.replaceSymbolicLink(
                target: "releases/\(release.lastPathComponent)",
                at: paths.current
            )
            try DroneFileSystem.writeAtomically(plist, to: paths.launchAgent, mode: 0o644)
            try launchd.bootstrap()
            pruneReleases()
        } catch {
            let installationError = error
            if stoppedPrevious {
                do {
                    // A failed bootstrap can still leave a loaded job. Stop it
                    // before restoring the previous release and configuration.
                    try launchd.stop()
                    try previous.restore(paths: paths)
                    if previous.wasLoaded { try launchd.bootstrap() }
                } catch {
                    // Preserve both releases if restoration fails; never delete
                    // binaries that current or a loaded job might still use.
                    throw DroneWorkerError.rollbackFailed
                }
            }
            try? FileManager.default.removeItem(at: release)
            throw installationError
        }
    }

    func uninstall() throws {
        try launchd.stop()
        for item in [paths.launchAgent, paths.current, paths.releases] {
            if FileManager.default.fileExists(atPath: item.path) {
                try FileManager.default.removeItem(at: item)
            }
        }
        try? FileManager.default.removeItem(at: paths.controlSocket)
    }

    private func pruneReleases() {
        guard let releases = try? FileManager.default.contentsOfDirectory(
            at: paths.releases,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let currentRelease = paths.current.resolvingSymlinksInPath().standardizedFileURL
        let obsolete = releases
            .filter { $0.standardizedFileURL != currentRelease }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return left > right
            }
            .dropFirst()
        for release in obsolete { try? FileManager.default.removeItem(at: release) }
    }
}

private struct DroneInstallationSnapshot {
    let wasLoaded: Bool
    private let target: String?
    private let plist: Data?
    private let plistMode: mode_t

    init(paths: DronePaths, wasLoaded: Bool) throws {
        self.wasLoaded = wasLoaded
        if let info = try Self.metadata(paths.current) {
            guard (info.st_mode & S_IFMT) == S_IFLNK else { throw DroneWorkerError.unsafeFile }
            target = try FileManager.default.destinationOfSymbolicLink(atPath: paths.current.path)
        } else {
            target = nil
        }
        if let info = try Self.metadata(paths.launchAgent) {
            guard (info.st_mode & S_IFMT) == S_IFREG else { throw DroneWorkerError.unsafeFile }
            plist = try Data(contentsOf: paths.launchAgent)
            plistMode = info.st_mode & 0o777
        } else {
            plist = nil
            plistMode = 0o644
        }
        guard !wasLoaded || (target != nil && plist != nil) else {
            throw DroneWorkerError.invalidInstallation
        }
    }

    func restore(paths: DronePaths) throws {
        if let target {
            try DroneFileSystem.replaceSymbolicLink(target: target, at: paths.current)
        } else if try Self.metadata(paths.current) != nil {
            try FileManager.default.removeItem(at: paths.current)
        }
        if let plist {
            try DroneFileSystem.writeAtomically(plist, to: paths.launchAgent, mode: plistMode)
        } else if try Self.metadata(paths.launchAgent) != nil {
            try FileManager.default.removeItem(at: paths.launchAgent)
        }
    }

    private static func metadata(_ url: URL) throws -> stat? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw DroneWorkerError.unsafeFile
        }
        guard info.st_uid == getuid() else { throw DroneWorkerError.unsafeFile }
        return info
    }
}

enum DroneLaunchAgent {
    static func dictionary(paths: DronePaths) -> [String: Any] {
        var propertyList: [String: Any] = [
            "Label": paths.label,
            "ProgramArguments": [paths.installedDaemon.path],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 5,
            "ExitTimeOut": 10,
            "ProcessType": "Background",
            "WorkingDirectory": paths.root.path,
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null",
        ]
        if !paths.daemonEnvironment.isEmpty {
            propertyList["EnvironmentVariables"] = paths.daemonEnvironment
        }
        return propertyList
    }

    static func encode(paths: DronePaths) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: dictionary(paths: paths),
            format: .xml,
            options: 0
        )
    }
}

enum DroneSignatureVerifier {
    static func verify(paths: DronePaths) -> Bool {
        [paths.installedCLI, paths.installedDaemon].allSatisfy { executable in
            let status = try? DroneProcess.run(
                executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: ["--verify", "--strict", executable.path],
                timeout: 10
            )
            return status == 0
        }
    }
}

enum DroneProcess {
    static func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                usleep(100_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw DroneWorkerError.processTimedOut
            }
            usleep(10_000)
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
