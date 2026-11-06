import Foundation

struct DroneToolLease: Codable, Equatable, Sendable {
    let id: UUID
    let controllerID: UUID
    let droneID: UUID
    let jobID: DroneJobID
    let workspaceID: UUID
    /// Seconds since the Unix epoch, shared by controller and worker.
    let expiresAt: TimeInterval

    func validate(
        authenticatedControllerID: UUID,
        authenticatedDroneID: UUID,
        expectedJobID: DroneJobID? = nil,
        expectedWorkspaceID: UUID? = nil,
        now: TimeInterval
    ) throws {
        guard expiresAt.isFinite, expiresAt > now,
              controllerID == authenticatedControllerID,
              droneID == authenticatedDroneID,
              expectedJobID == nil || jobID == expectedJobID,
              expectedWorkspaceID == nil || workspaceID == expectedWorkspaceID
        else { throw DroneProtocolError.unauthorized }
    }
}

/// Worker-owned grants. Remote envelopes can use these leases but cannot issue them.
/// Grants intentionally expire on worker restart; the local owner must approve again.
struct DroneToolLeaseRegistry: Sendable {
    static let maximumLeases = 128
    static let maximumLeasesPerController = 16
    static let maximumLifetime: TimeInterval = 900

    private struct Grant: Sendable {
        let lease: DroneToolLease
        let permissions: DroneControllerPermissions
    }

    let droneID: UUID
    private var grants: [UUID: Grant] = [:]

    init(droneID: UUID) {
        self.droneID = droneID
    }

    mutating func issue(
        controllerID: UUID,
        workspaceID: UUID,
        permissions: DroneControllerPermissions,
        lifetime: TimeInterval,
        now: TimeInterval
    ) throws -> DroneToolLease {
        let toolPermissions: DroneControllerPermissions = [.files, .jobs, .git]
        guard !permissions.isEmpty, permissions.isSubset(of: toolPermissions),
              now.isFinite, lifetime.isFinite, lifetime > 0,
              lifetime <= Self.maximumLifetime, (now + lifetime).isFinite
        else { throw DroneProtocolError.unauthorized }
        grants = grants.filter { $0.value.lease.expiresAt > now }
        guard grants.count < Self.maximumLeases,
              grants.values.filter({ $0.lease.controllerID == controllerID }).count
                < Self.maximumLeasesPerController
        else { throw DroneProtocolError.resourceLimit }
        let lease = DroneToolLease(
            id: UUID(), controllerID: controllerID, droneID: droneID,
            jobID: DroneJobID(), workspaceID: workspaceID, expiresAt: now + lifetime
        )
        grants[lease.id] = Grant(lease: lease, permissions: permissions)
        return lease
    }

    func authorize(
        _ envelope: DroneEnvelope,
        controllerID: UUID,
        now: TimeInterval
    ) throws {
        guard let leaseID = envelope.lease?.id, let grant = grants[leaseID] else {
            throw DroneProtocolError.unauthorized
        }
        try DroneToolWorkerAuthorization.authorize(
            envelope,
            authenticatedControllerID: controllerID,
            authenticatedDroneID: droneID,
            approvedLease: grant.lease,
            now: now
        )
        let permission: DroneControllerPermissions
        switch envelope.kind {
        case .toolRead, .toolEdit: permission = .files
        case .toolRun: permission = .jobs
        case .toolDiff: permission = .git
        // Replay/cancel additionally require the original operation's full lease.
        case .toolAttach, .toolCancel: permission = []
        default: throw DroneProtocolError.unauthorized
        }
        guard grant.permissions.isSuperset(of: permission) else {
            throw DroneProtocolError.unauthorized
        }
    }

    mutating func revoke(controllerID: UUID) {
        grants = grants.filter { $0.value.lease.controllerID != controllerID }
    }
}

struct DroneToolReadRequest: Codable, Equatable, Sendable {
    let path: String
    let maxBytes: Int
}

struct DroneToolReadResult: Codable, Equatable, Sendable {
    let data: Data
    let truncated: Bool
}

struct DroneToolEditRequest: Codable, Equatable, Sendable {
    let path: String
    let expectedSHA256: String?
    let oldData: Data
    let newData: Data
}

struct DroneToolEditResult: Codable, Equatable, Sendable {
    let bytesWritten: Int
    let sha256: String
}

struct DroneToolProcessRequest: Codable, Equatable, Sendable {
    let executable: String
    let arguments: [String]
    let workingDirectory: String?
    let environment: [String: String]
    let timeout: TimeInterval
    let outputLimit: Int

    init(
        executable: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        timeout: TimeInterval = 300,
        outputLimit: Int = DroneLimits.maxToolOperationBytes
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeout = timeout
        self.outputLimit = outputLimit
    }
}

struct DroneToolDiffRequest: Codable, Equatable, Sendable {
    let paths: [String]
    let contextLines: Int
    let maxBytes: Int

    init(
        paths: [String] = [],
        contextLines: Int = 3,
        maxBytes: Int = DroneLimits.maxToolOperationBytes
    ) {
        self.paths = paths
        self.contextLines = contextLines
        self.maxBytes = maxBytes
    }
}

enum DroneToolStream: String, Codable, Sendable {
    case standardOutput
    case standardError
    case diff
}

struct DroneToolOutputBody: Codable, Equatable, Sendable {
    let sequence: UInt64
    let offset: UInt64
    let stream: DroneToolStream
    let data: Data
    let truncated: Bool
}

struct DroneToolStreamOffsets: Codable, Equatable, Sendable {
    var standardOutput: UInt64 = 0
    var standardError: UInt64 = 0
    var diff: UInt64 = 0

    subscript(stream: DroneToolStream) -> UInt64 {
        get {
            switch stream {
            case .standardOutput: standardOutput
            case .standardError: standardError
            case .diff: diff
            }
        }
        set {
            switch stream {
            case .standardOutput: standardOutput = newValue
            case .standardError: standardError = newValue
            case .diff: diff = newValue
            }
        }
    }
}

struct DroneToolAttachBody: Codable, Equatable, Sendable {
    let originalRequestID: UUID
    let nextSequence: UInt64
    let offsets: DroneToolStreamOffsets
}

struct DroneToolCancelBody: Codable, Equatable, Sendable {
    let operationRequestID: UUID
}

enum DroneToolCompletionStatus: String, Codable, Sendable {
    case succeeded
    case failed
    case cancelled
}

struct DroneToolCompletionBody: Codable, Equatable, Sendable {
    let status: DroneToolCompletionStatus
    let exitCode: Int32?
    let finalSequence: UInt64
}

struct DroneToolRequestContext: Equatable, Sendable {
    let lease: DroneToolLease
    let requestID: UUID
    let idempotencyKey: String
}

enum DroneToolEvent: Equatable, Sendable {
    case output(DroneToolOutputBody)
    case completed(DroneToolCompletionBody)
}

protocol DroneToolEngine: Sendable {
    func read(
        _ request: DroneToolReadRequest,
        context: DroneToolRequestContext
    ) async throws -> DroneToolReadResult

    func edit(
        _ request: DroneToolEditRequest,
        context: DroneToolRequestContext
    ) async throws -> DroneToolEditResult

    func run(
        _ request: DroneToolProcessRequest,
        context: DroneToolRequestContext
    ) async throws -> AsyncThrowingStream<DroneToolEvent, Error>

    func diff(
        _ request: DroneToolDiffRequest,
        context: DroneToolRequestContext
    ) async throws -> AsyncThrowingStream<DroneToolEvent, Error>

    func cancel(context: DroneToolRequestContext, operationRequestID: UUID) async throws
}

enum DroneToolValidation {
    static func validate(path: String) throws {
        guard !path.isEmpty, path.utf8.count <= DroneLimits.maxToolPathBytes,
              !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\"),
              !path.utf8.contains(0), !path.contains("//")
        else { throw DroneProtocolError.unauthorized }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw DroneProtocolError.unauthorized }
    }

    static func validate(optionalPath path: String?) throws {
        if let path { try validate(path: path) }
    }

    static func validate(read request: DroneToolReadRequest) throws {
        try validate(path: request.path)
        guard (1 ... DroneLimits.maxToolReadBytes).contains(request.maxBytes) else {
            throw DroneProtocolError.resourceLimit
        }
    }

    static func validate(readResult result: DroneToolReadResult) throws {
        guard result.data.count <= DroneLimits.maxToolReadBytes else {
            throw DroneProtocolError.resourceLimit
        }
    }

    static func validate(edit request: DroneToolEditRequest) throws {
        try validate(path: request.path)
        guard !request.oldData.isEmpty,
              request.oldData.count <= DroneLimits.maxToolEditBytes,
              request.newData.count <= DroneLimits.maxToolEditBytes
        else { throw DroneProtocolError.resourceLimit }
        if let digest = request.expectedSHA256 {
            guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else {
                throw DroneProtocolError.malformedMessage
            }
        }
    }

    static func validate(process request: DroneToolProcessRequest) throws {
        guard !request.executable.isEmpty,
              request.executable.utf8.count <= DroneLimits.maxToolExecutableBytes,
              !request.executable.contains("/"), !request.executable.contains("\\"),
              !request.executable.utf8.contains(0),
              request.arguments.count <= DroneLimits.maxToolArguments,
              request.arguments.allSatisfy({
                  $0.utf8.count <= DroneLimits.maxToolArgumentBytes && !$0.utf8.contains(0)
              }),
              request.arguments.reduce(0, { $0 + $1.utf8.count }) <= DroneLimits.maxToolArgumentsBytes,
              request.timeout.isFinite, request.timeout > 0,
              request.timeout <= DroneLimits.maxToolTimeout,
              (1 ... DroneLimits.maxToolOperationBytes).contains(request.outputLimit)
        else { throw DroneProtocolError.resourceLimit }
        try validate(optionalPath: request.workingDirectory)
        try DroneAuthorization.validateEnvironment(request.environment)
    }

    static func validate(diff request: DroneToolDiffRequest) throws {
        guard request.paths.count <= DroneLimits.maxToolDiffPaths,
              Set(request.paths).count == request.paths.count,
              (0 ... DroneLimits.maxToolDiffContextLines).contains(request.contextLines),
              (1 ... DroneLimits.maxToolOperationBytes).contains(request.maxBytes)
        else { throw DroneProtocolError.resourceLimit }
        for path in request.paths { try validate(path: path) }
    }

    static func validate(output: DroneToolOutputBody) throws {
        guard !output.data.isEmpty, output.data.count <= DroneLimits.maxOutputChunkBytes else {
            throw DroneProtocolError.resourceLimit
        }
    }

    static func validate(completion: DroneToolCompletionBody) throws {
        if completion.status == .cancelled, completion.exitCode != nil {
            throw DroneProtocolError.malformedMessage
        }
    }
}

enum DroneToolWorkerAuthorization {
    /// A request ID is a correlation token, never authority to read retained output.
    static func authorizeReplay(
        storedLease: DroneToolLease?,
        requestingLease: DroneToolLease
    ) throws {
        guard storedLease == requestingLease else { throw DroneProtocolError.unauthorized }
    }

    static func authorize(
        _ envelope: DroneEnvelope,
        authenticatedControllerID: UUID,
        authenticatedDroneID: UUID,
        approvedLease: DroneToolLease,
        now: TimeInterval
    ) throws {
        try envelope.validate()
        guard envelope.kind.isTool, envelope.lease == approvedLease else {
            throw DroneProtocolError.unauthorized
        }
        try approvedLease.validate(
            authenticatedControllerID: authenticatedControllerID,
            authenticatedDroneID: authenticatedDroneID,
            expectedJobID: approvedLease.jobID,
            expectedWorkspaceID: approvedLease.workspaceID,
            now: now
        )
    }
}

extension DroneMessageKind {
    var isTool: Bool {
        switch self {
        case .toolRead, .toolReadResult, .toolEdit, .toolEditResult, .toolRun, .toolDiff,
             .toolAccepted, .toolOutput, .toolCompletion, .toolCancel, .toolCancelled,
             .toolAttach, .toolAttached:
            true
        default:
            false
        }
    }

    var isToolRequest: Bool {
        switch self {
        case .toolRead, .toolEdit, .toolRun, .toolDiff, .toolCancel, .toolAttach: true
        default: false
        }
    }
}
