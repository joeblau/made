import Darwin
import Foundation

struct DroneControlRequest: Codable, Equatable, Sendable {
    var version = DroneVersion.control
    var command = "status"
    var requestID: UUID?
    var controllerID: UUID?
    var workspaceID: UUID?
    var permissions: [String]?
    var lifetimeSeconds: Int?

    func validate() throws {
        guard version == DroneVersion.control else { throw DroneWorkerError.unsupportedControlVersion }
        switch command {
        case "status", "controllers":
            guard requestID == nil, controllerID == nil, workspaceID == nil,
                  permissions == nil, lifetimeSeconds == nil else { throw DroneWorkerError.invalidArguments }
        case "approve", "reject":
            guard requestID != nil, controllerID == nil, workspaceID == nil,
                  permissions == nil, lifetimeSeconds == nil else { throw DroneWorkerError.invalidArguments }
        case "revoke":
            guard controllerID != nil, requestID == nil, workspaceID == nil,
                  permissions == nil, lifetimeSeconds == nil else { throw DroneWorkerError.invalidArguments }
        case "grant", "revoke-grants":
            guard requestID == nil, controllerID != nil, workspaceID == nil,
                  let permissions, !permissions.isEmpty, permissions.count <= 4,
                  Set(permissions).count == permissions.count,
                  permissions.allSatisfy({ ["terminal", "files", "jobs", "git"].contains($0) }),
                  lifetimeSeconds == nil
            else { throw DroneWorkerError.invalidArguments }
        case "grant-tools":
            guard requestID == nil, controllerID != nil, workspaceID != nil,
                  let permissions, !permissions.isEmpty, permissions.count <= 3,
                  Set(permissions).count == permissions.count,
                  permissions.allSatisfy({ ["files", "jobs", "git"].contains($0) }),
                  let lifetimeSeconds, (1...900).contains(lifetimeSeconds)
            else { throw DroneWorkerError.invalidArguments }
        default: throw DroneWorkerError.invalidArguments
        }
    }
}

/// Independent of the execution module so the small CLI can print a lease
/// whose JSON is directly decodable as DroneToolLease by a controller adapter.
struct DroneControlToolLease: Codable, Equatable, Sendable {
    struct Job: Codable, Equatable, Sendable { let rawValue: UUID }
    let id: UUID
    let controllerID: UUID
    let droneID: UUID
    let jobID: Job
    let workspaceID: UUID
    let expiresAt: TimeInterval
}

enum DroneOwnerCommand {
    static func parse(_ arguments: [String]) throws -> DroneControlRequest {
        guard let command = arguments.first else { throw DroneWorkerError.invalidArguments }
        let request: DroneControlRequest
        switch command {
        case "controllers":
            guard arguments.count == 1 else { throw DroneWorkerError.invalidArguments }
            request = DroneControlRequest(command: command)
        case "revoke":
            guard arguments.count == 2, let controller = UUID(uuidString: arguments[1]) else {
                throw DroneWorkerError.invalidArguments
            }
            request = DroneControlRequest(command: command, controllerID: controller)
        case "grant", "revoke-grants":
            guard arguments.count == 3, let controller = UUID(uuidString: arguments[1]) else {
                throw DroneWorkerError.invalidArguments
            }
            request = DroneControlRequest(
                command: command, controllerID: controller,
                permissions: arguments[2].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            )
        case "grant-tools":
            guard arguments.count == 5, let controller = UUID(uuidString: arguments[1]),
                  let workspace = UUID(uuidString: arguments[2]), let lifetime = Int(arguments[4]) else {
                throw DroneWorkerError.invalidArguments
            }
            request = DroneControlRequest(
                command: command, controllerID: controller, workspaceID: workspace,
                permissions: arguments[3].split(separator: ",", omittingEmptySubsequences: false).map(String.init),
                lifetimeSeconds: lifetime
            )
        default: throw DroneWorkerError.invalidArguments
        }
        try request.validate()
        return request
    }
}

struct DroneApprovalSummary: Codable, Equatable, Sendable {
    let requestID: UUID
    let verificationCode: String
    let isKeyChange: Bool
}

struct DroneWorkerHealthSnapshot: Codable, Equatable, Sendable {
    let listenerReady: Bool
    let paired: Bool
    let storageHealthy: Bool
}

protocol DroneWorkerHealthReporting: Sendable {
    func healthSnapshot() async -> DroneWorkerHealthSnapshot
}

struct DroneControlResponse: Codable, Equatable, Sendable {
    let version: Int
    let workerVersion: String
    let protocolVersion: UInt16
    let paired: Bool
    let processIdentifier: Int32
    let executionEnabled: Bool
    let workerHealth: DroneWorkerHealthSnapshot?
    var approvals: [DroneApprovalSummary]
    var controllers: [UUID]?
    var toolLease: DroneControlToolLease?

    init(paths: DronePaths, workerHealth: DroneWorkerHealthSnapshot? = nil) {
        version = DroneVersion.control
        workerVersion = DroneVersion.marketing
        protocolVersion = DroneVersion.protocolVersion
        paired = workerHealth?.paired ?? false
        processIdentifier = getpid()
        executionEnabled = paths.workspace != nil
        self.workerHealth = workerHealth
        approvals = []
    }

    init(
        version: Int,
        workerVersion: String,
        protocolVersion: UInt16,
        paired: Bool,
        processIdentifier: Int32,
        executionEnabled: Bool = false,
        workerHealth: DroneWorkerHealthSnapshot? = nil,
        approvals: [DroneApprovalSummary] = []
    ) {
        self.version = version
        self.workerVersion = workerVersion
        self.protocolVersion = protocolVersion
        self.paired = paired
        self.processIdentifier = processIdentifier
        self.executionEnabled = executionEnabled
        self.workerHealth = workerHealth
        self.approvals = approvals
    }
}

enum DroneControlCodec {
    static let maximumBytes = 16 * 1_024

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= maximumBytes else { throw DroneWorkerError.invalidResponse }
        return data
    }

    static func decodeResponse(_ data: Data) throws -> DroneControlResponse {
        guard !data.isEmpty, data.count <= maximumBytes else { throw DroneWorkerError.invalidResponse }
        return try JSONDecoder().decode(DroneControlResponse.self, from: data)
    }
}

struct DroneControlClient {
    let paths: DronePaths
    var timeout: TimeInterval = 1

    func status() throws -> DroneControlResponse {
        try send(DroneControlRequest())
    }

    func send(_ controlRequest: DroneControlRequest) throws -> DroneControlResponse {
        try controlRequest.validate()
        try paths.validateSocketPath()
        var info = stat()
        guard lstat(paths.controlSocket.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFSOCK,
              info.st_uid == getuid()
        else { throw DroneWorkerError.notInstalled }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw DroneWorkerError.operationFailed }
        defer { _ = Darwin.close(descriptor) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        try setTimeout(descriptor)

        var address = try DroneUnixSocket.address(for: paths.controlSocket)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw DroneWorkerError.operationFailed }

        var request = try DroneControlCodec.encode(controlRequest)
        request.append(0x0A)
        try DroneUnixSocket.writeAll(request, to: descriptor)
        let response = try DroneUnixSocket.readLine(from: descriptor, maximum: DroneControlCodec.maximumBytes)
        let decoded = try DroneControlCodec.decodeResponse(response)
        guard decoded.version == DroneVersion.control else { throw DroneWorkerError.unsupportedControlVersion }
        return decoded
    }

    private func setTimeout(_ descriptor: Int32) throws {
        var value = timeval(
            tv_sec: Int(timeout),
            tv_usec: __darwin_suseconds_t((timeout - floor(timeout)) * 1_000_000)
        )
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &value,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0,
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &value,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else { throw DroneWorkerError.operationFailed }
    }
}

enum DroneStatusEvaluator {
    static func state(response: DroneControlResponse?, launchdLoaded: Bool) -> DroneOperationalState {
        if let response {
            guard response.version == DroneVersion.control,
                  response.protocolVersion == DroneVersion.protocolVersion
            else { return .incompatible }
            guard response.executionEnabled else { return .disabled }
            guard let health = response.workerHealth,
                  health.listenerReady, health.storageHealthy
            else { return .unhealthy }
            return health.paired ? .paired : .listening
        }
        return launchdLoaded ? .unhealthy : .stopped
    }
}

enum DroneUnixSocket {
    static func address(for url: URL) throws -> sockaddr_un {
        let path = url.path
        guard path.utf8.count < 104 else { throw DroneWorkerError.unsafeFile }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: Array(path.utf8) + [0])
        }
        return address
    }

    static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw DroneWorkerError.operationFailed }
            var written = 0
            while written < data.count {
                let count = Darwin.write(descriptor, base.advanced(by: written), data.count - written)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw DroneWorkerError.operationFailed }
                written += count
            }
        }
    }

    static func readLine(from descriptor: Int32, maximum: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while data.count <= maximum {
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, maximum + 1 - data.count))
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw DroneWorkerError.invalidResponse }
            data.append(contentsOf: buffer.prefix(count))
            if let newline = data.firstIndex(of: 0x0A) {
                guard newline == data.index(before: data.endIndex) else {
                    throw DroneWorkerError.invalidResponse
                }
                data.removeLast()
                return data
            }
        }
        throw DroneWorkerError.invalidResponse
    }
}
