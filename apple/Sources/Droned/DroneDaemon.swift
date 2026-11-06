import Darwin
import Foundation

@main
enum DroneDaemonMain {
    static func main() {
        umask(0o077)
        if CommandLine.arguments.dropFirst().first == "--version" {
            print(DroneVersion.report)
            return
        }
        guard CommandLine.arguments.count == 1 else {
            FileHandle.standardError.write(Data("usage: droned [--version]\n".utf8))
            exit(64)
        }
        do {
            let daemon = try DroneDaemon()
            try daemon.run()
        } catch {
            FileHandle.standardError.write(Data("droned: startup failed\n".utf8))
            exit(1)
        }
    }
}

final class DroneDaemon {
    private let paths: DronePaths
    private let log: DroneLog
    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var signalSources: [DispatchSourceSignal] = []
    private let workerService: DroneWorkerService?
    private var isStopping = false

    init(paths: DronePaths = DronePaths()) throws {
        self.paths = paths
        log = DroneLog(paths: paths)
        try paths.prepareWorkerDirectories()
        try paths.validateSocketPath()
        if let workspace = paths.workspace {
            workerService = try DroneWorkerService(
                workspace: workspace,
                stateDirectory: paths.state.appendingPathComponent("execution", isDirectory: true),
                permissions: Self.permissionsFromEnvironment(),
                onAudit: log.record
            )
        } else {
            workerService = nil
        }
    }

    func run() throws {
        try startListener()
        let bonjourID = try bonjourInstanceID()
        Task { [workerService] in await workerService?.start(bonjourInstanceID: bonjourID) }
        installSignalHandlers()
        log.record("daemon.started")
        RunLoop.main.run()
    }

    private func startListener() throws {
        if FileManager.default.fileExists(atPath: paths.controlSocket.path) {
            var info = stat()
            guard lstat(paths.controlSocket.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFSOCK,
                  info.st_uid == getuid()
            else { throw DroneWorkerError.unsafeFile }
            try FileManager.default.removeItem(at: paths.controlSocket)
        }

        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw DroneWorkerError.operationFailed }
        _ = fcntl(listener, F_SETFD, FD_CLOEXEC)
        var address = try DroneUnixSocket.address(for: paths.controlSocket)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(listener, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(paths.controlSocket.path, 0o600) == 0, listen(listener, 4) == 0 else {
            throw DroneWorkerError.operationFailed
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: .main)
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.setCancelHandler { [listener] in _ = Darwin.close(listener) }
        acceptSource = source
        source.resume()
    }

    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in self?.shutDown() }
            source.resume()
            signalSources.append(source)
        }
    }

    private func acceptConnection() {
        var address = sockaddr_un()
        var length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let client = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                accept(listener, socketAddress, &length)
            }
        }
        guard client >= 0 else { return }
        _ = fcntl(client, F_SETFD, FD_CLOEXEC)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var uid = uid_t()
        var gid = gid_t()
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
            _ = Darwin.close(client)
            return
        }

        Task { [workerService, paths, log] in
            defer { _ = Darwin.close(client) }
            do {
                let data = try DroneUnixSocket.readLine(from: client, maximum: DroneControlCodec.maximumBytes)
                let request = try JSONDecoder().decode(DroneControlRequest.self, from: data)
                guard request.version == DroneVersion.control else { throw DroneWorkerError.invalidResponse }
                if request.command != "status" {
                    guard ["approve", "reject"].contains(request.command),
                          let requestID = request.requestID,
                          let workerService
                    else { throw DroneWorkerError.invalidResponse }
                    await workerService.resolvePairing(
                        requestID: requestID,
                        approved: request.command == "approve"
                    )
                }
                let health = await (workerService as? any DroneWorkerHealthReporting)?.healthSnapshot()
                var status = DroneControlResponse(paths: paths, workerHealth: health)
                if let workerService {
                    status.approvals = await workerService.approvalSummaries()
                }
                var response = try DroneControlCodec.encode(status)
                response.append(0x0A)
                try DroneUnixSocket.writeAll(response, to: client)
            } catch {
                log.record("control.request.rejected")
            }
        }
    }

    private func bonjourInstanceID() throws -> String {
        let url = paths.configuration.appendingPathComponent("bonjour-id")
        if let data = try? Data(contentsOf: url),
           let identifier = String(data: data, encoding: .utf8),
           (16 ... 64).contains(identifier.utf8.count) {
            return identifier
        }
        let identifier = "drone-\(UUID().uuidString)"
        try DroneFileSystem.writeAtomically(Data(identifier.utf8), to: url, mode: 0o600)
        return identifier
    }

    private static func permissionsFromEnvironment() -> DroneControllerPermissions {
        let names = (ProcessInfo.processInfo.environment["BLAU_DRONE_PERMISSIONS"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var permissions: DroneControllerPermissions = []
        if names.contains("terminal") { permissions.insert(.terminal) }
        if names.contains("jobs") { permissions.insert(.jobs) }
        if names.contains("files") { permissions.insert(.files) }
        if names.contains("git") { permissions.insert(.git) }
        return permissions
    }

    private func shutDown() {
        guard !isStopping else { return }
        isStopping = true
        log.record("daemon.stopping")
        acceptSource?.cancel()
        acceptSource = nil
        signalSources.forEach { $0.cancel() }
        signalSources.removeAll()
        try? FileManager.default.removeItem(at: paths.controlSocket)
        Task { [workerService] in
            await workerService?.stop()
            RunLoop.main.perform {
                CFRunLoopStop(CFRunLoopGetMain())
            }
        }
    }
}
