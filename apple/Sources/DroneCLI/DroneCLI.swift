import Foundation

@main
enum DroneCLIMain {
    static func main() {
        do {
            try DroneCLI().run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch let error as DroneCLIUsageError {
            FileHandle.standardError.write(Data("drone: \(error.rawValue)\n\(DroneCLI.usage)\n".utf8))
            exit(64)
        } catch DroneWorkerError.rollbackFailed {
            FileHandle.standardError.write(Data(
                "drone: install failed and rollback could not complete; releases retained; run drone doctor\n".utf8
            ))
            exit(1)
        } catch DroneWorkerError.notInstalled {
            FileHandle.standardError.write(Data("drone: worker is not installed\n".utf8))
            exit(1)
        } catch {
            FileHandle.standardError.write(Data("drone: operation failed; run drone doctor\n".utf8))
            exit(1)
        }
    }
}

enum DroneCLIUsageError: String, Error {
    case unknownCommand = "unknown command"
    case unexpectedArguments = "unexpected arguments"
}

struct DroneCLI {
    static let usage = "usage: drone <install|uninstall|start|stop|restart|status|doctor|pairings|approve|reject|version>"

    private let paths: DronePaths

    init(paths: DronePaths = DronePaths()) {
        self.paths = paths
    }

    func run(arguments: [String]) throws {
        guard let command = arguments.first else {
            print(Self.usage)
            return
        }
        guard arguments.count == 1 || (["approve", "reject"].contains(command) && arguments.count == 2) else {
            throw DroneCLIUsageError.unexpectedArguments
        }
        let launchd = DroneLaunchd(paths: paths)
        switch command {
        case "install":
            try DroneInstaller(paths: paths, launchd: launchd).install(source: sourceDirectory())
            print("installed \(paths.label); execution \(paths.workspace == nil ? "disabled" : "enabled")")
        case "uninstall":
            try DroneInstaller(paths: paths, launchd: launchd).uninstall()
            print("uninstalled; retained configuration, identity, pairing state, and logs")
        case "start":
            try launchd.start()
            print("start requested")
        case "stop":
            try launchd.stop()
            print("stopped")
        case "restart":
            try launchd.restart()
            print("restart requested")
        case "status":
            let report = status(launchd: launchd)
            print(report.rendered)
            if report.state == .stopped { exit(1) }
            if report.state == .unhealthy || report.state == .incompatible { exit(2) }
        case "doctor":
            let report = doctor(launchd: launchd)
            print(report.rendered)
            if ![.disabled, .listening, .paired].contains(report.state) { exit(2) }
            if !report.healthy { exit(2) }
        case "pairings":
            let response = try DroneControlClient(paths: paths).status()
            for approval in response.approvals {
                print("\(approval.requestID.uuidString) \(approval.verificationCode) changed=\(approval.isKeyChange)")
            }
        case "approve", "reject":
            guard let requestID = UUID(uuidString: arguments[1]) else {
                throw DroneCLIUsageError.unexpectedArguments
            }
            _ = try DroneControlClient(paths: paths).send(DroneControlRequest(
                command: command,
                requestID: requestID
            ))
            print("\(command == "approve" ? "approved" : "rejected") \(requestID.uuidString)")
        case "version", "--version":
            print(DroneVersion.report)
        case "help", "--help", "-h":
            print(Self.usage)
        default:
            throw DroneCLIUsageError.unknownCommand
        }
    }

    private func sourceDirectory() throws -> URL {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            throw DroneWorkerError.invalidInstallation
        }
        return executable.deletingLastPathComponent()
    }

    private func status(launchd: DroneLaunchd) -> DroneStatusReport {
        let response = try? DroneControlClient(paths: paths).status()
        let loaded = try? launchd.isLoaded
        let state = loaded.map { DroneStatusEvaluator.state(response: response, launchdLoaded: $0) } ?? .unhealthy
        return DroneStatusReport(
            state: state,
            response: response,
            installed: FileManager.default.fileExists(atPath: paths.launchAgent.path),
            launchdLoaded: loaded ?? false
        )
    }

    private func doctor(launchd: DroneLaunchd) -> DroneDoctorReport {
        let base = status(launchd: launchd)
        let socketHealthy = base.response != nil
        let permissions = base.installed && paths.permissionsAreValid()
        let signatures = base.installed && DroneSignatureVerifier.verify(paths: paths)
        let log = DroneLog(paths: paths)
        return DroneDoctorReport(
            status: base,
            socketHealthy: socketHealthy,
            permissionsValid: permissions,
            signaturesValid: signatures,
            logsBounded: log.isBounded()
        )
    }
}

struct DroneStatusReport {
    let state: DroneOperationalState
    let response: DroneControlResponse?
    let installed: Bool
    let launchdLoaded: Bool

    var rendered: String {
        var lines = [
            "state=\(state.rawValue)",
            "installed=\(installed)",
            "launchd=\(launchdLoaded)",
            "execution=\(response?.executionEnabled == true ? "configured" : "disabled")",
        ]
        if let response {
            lines.append("version=\(response.workerVersion)")
            lines.append("protocol=\(response.protocolVersion)")
            lines.append("pid=\(response.processIdentifier)")
            if response.executionEnabled {
                lines.append("listener=\(response.workerHealth?.listenerReady == true ? "ready" : "unavailable")")
                lines.append("pairing_store=\(response.workerHealth?.storageHealthy == true ? "ok" : "unavailable")")
            }
        }
        return lines.joined(separator: "\n")
    }
}

struct DroneDoctorReport {
    let status: DroneStatusReport
    let socketHealthy: Bool
    let permissionsValid: Bool
    let signaturesValid: Bool
    let logsBounded: Bool

    var state: DroneOperationalState { status.state }
    var healthy: Bool {
        [.disabled, .listening, .paired].contains(status.state)
            && status.installed && status.launchdLoaded && socketHealthy && permissionsValid
            && signaturesValid && logsBounded
    }

    var rendered: String {
        status.rendered + "\n" + [
            "control_socket=\(socketHealthy ? "ok" : "failed")",
            "permissions=\(permissionsValid ? "ok" : "failed")",
            "signatures=\(signaturesValid ? "ok" : "failed")",
            "logs=\(logsBounded ? "bounded" : "unbounded")",
        ].joined(separator: "\n")
    }
}
