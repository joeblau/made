import Darwin
import Foundation

struct DronePaths: Sendable {
    static let productionLabel = "app.blau.drone"

    let root: URL
    let configuration: URL
    let state: URL
    let identity: URL
    let pairings: URL
    let runtime: URL
    let logs: URL
    let releases: URL
    let current: URL
    let launchAgent: URL
    let label: String
    let usesTestOverrides: Bool
    let logLimit: Int
    let workspace: URL?
    let permissionsPolicy: String?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let overriddenRoot = environment["BLAU_DRONE_ROOT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        workspace = environment["BLAU_DRONE_WORKSPACE"].map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        }
        permissionsPolicy = environment["BLAU_DRONE_PERMISSIONS"]
        let label = environment["BLAU_DRONE_LABEL"] ?? Self.productionLabel
        root = overriddenRoot ?? home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(Self.productionLabel, isDirectory: true)
        configuration = root.appendingPathComponent("config", isDirectory: true)
        state = root.appendingPathComponent("state", isDirectory: true)
        identity = state.appendingPathComponent("identity", isDirectory: true)
        pairings = state.appendingPathComponent("pairings", isDirectory: true)
        runtime = root.appendingPathComponent("run", isDirectory: true)
        logs = overriddenRoot?.appendingPathComponent("logs", isDirectory: true) ?? home
            .appendingPathComponent("Library/Logs", isDirectory: true)
            .appendingPathComponent(Self.productionLabel, isDirectory: true)
        releases = root.appendingPathComponent("releases", isDirectory: true)
        current = root.appendingPathComponent("current")
        launchAgent = overriddenRoot?
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist") ?? home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
        self.label = label
        usesTestOverrides = overriddenRoot != nil
        let requestedLogLimit = environment["BLAU_DRONE_LOG_LIMIT"].flatMap(Int.init)
        logLimit = requestedLogLimit.map { min(DroneLog.maximumLimit, max(1_024, $0)) }
            ?? DroneLog.maximumLimit
    }

    var controlSocket: URL {
        runtime.appendingPathComponent("control.sock")
    }

    var installedCLI: URL {
        current.appendingPathComponent("drone")
    }

    var installedDaemon: URL {
        current.appendingPathComponent("droned")
    }

    var daemonEnvironment: [String: String] {
        var environment: [String: String] = [:]
        if usesTestOverrides {
            environment["BLAU_DRONE_ROOT"] = root.path
            environment["BLAU_DRONE_LOG_LIMIT"] = String(logLimit)
        }
        if let workspace {
            environment["BLAU_DRONE_WORKSPACE"] = workspace.path
        }
        if let permissionsPolicy {
            environment["BLAU_DRONE_PERMISSIONS"] = permissionsPolicy
        }
        return environment
    }

    func prepareWorkerDirectories() throws {
        for directory in [root, configuration, state, identity, pairings, runtime, logs] {
            try DroneFileSystem.ensurePrivateDirectory(directory)
        }
    }

    func prepareInstallationDirectories() throws {
        try prepareWorkerDirectories()
        try DroneFileSystem.ensurePrivateDirectory(releases)
        try DroneFileSystem.ensureDirectory(
            launchAgent.deletingLastPathComponent(),
            mode: 0o755,
            privateDirectory: false
        )
    }

    func validateSocketPath() throws {
        guard controlSocket.path.utf8.count < 104 else { throw DroneWorkerError.unsafeFile }
    }

    func hasPairingState() -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: pairings,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        return entries.prefix(DronePairingLimits.maximum).contains { entry in
            guard let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                return false
            }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
    }

    func permissionsAreValid() -> Bool {
        let privateDirectories = [root, configuration, state, identity, pairings, runtime, logs, releases]
        guard privateDirectories.allSatisfy({ DroneFileSystem.hasMode($0, mode: 0o700) }),
              DroneFileSystem.hasMode(launchAgent, mode: 0o644),
              DroneFileSystem.hasMode(installedCLI, mode: 0o755),
              DroneFileSystem.hasMode(installedDaemon, mode: 0o755)
        else { return false }
        return true
    }
}

enum DronePairingLimits {
    static let maximum = 32
}

enum DroneFileSystem {
    static func ensurePrivateDirectory(_ url: URL) throws {
        try ensureDirectory(url, mode: 0o700, privateDirectory: true)
    }

    static func ensureDirectory(_ url: URL, mode: mode_t, privateDirectory: Bool) throws {
        let path = url.path
        var info = stat()
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == getuid(),
                  !privateDirectory || info.st_mode & 0o077 == 0
            else { throw DroneWorkerError.unsafeFile }
            if privateDirectory { try setMode(mode, for: url) }
            return
        }
        guard errno == ENOENT else { throw DroneWorkerError.unsafeFile }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try setMode(mode, for: url)
        try ensureDirectory(url, mode: mode, privateDirectory: privateDirectory)
    }

    static func setMode(_ mode: mode_t, for url: URL) throws {
        guard chmod(url.path, mode) == 0 else { throw DroneWorkerError.unsafeFile }
    }

    static func hasMode(_ url: URL, mode: mode_t) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == getuid() else { return false }
        return info.st_mode & 0o7777 == mode
    }

    static func requireExecutable(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              access(url.path, X_OK) == 0
        else { throw DroneWorkerError.invalidInstallation }
    }

    static func writeAtomically(_ data: Data, to url: URL, mode: mode_t) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data) else {
            throw DroneWorkerError.operationFailed
        }
        do {
            try setMode(mode, for: temporary)
            guard rename(temporary.path, url.path) == 0 else { throw DroneWorkerError.operationFailed }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    static func replaceSymbolicLink(target: String, at url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard symlink(target, temporary.path) == 0 else { throw DroneWorkerError.operationFailed }
        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw DroneWorkerError.operationFailed
        }
    }
}
