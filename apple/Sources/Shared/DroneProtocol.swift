import Foundation

struct DroneSessionID: Codable, Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

struct DroneJobID: Codable, Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

enum DroneWorkspaceIDs {
    static let `default` = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
}

enum DroneLimits {
    static let protocolVersion: UInt16 = 1
    static let maxFrameBytes = 1_048_576
    static let maxEnvelopeBytes = maxFrameBytes - 26
    static let maxHandshakeBytes = 16 * 1_024
    static let maxOutputChunkBytes = 64 * 1_024
    static let maxInputBytes = 64 * 1_024
    static let maxTerminalScrollbackBytes = 8 * 1_024 * 1_024
    static let maxReconnectQueueBytes = 1_048_576
    static let maxReconnectQueueRecords = 256
    static let maxPairedWorkers = 32
    static let maxLiveSessions = 64
    static let maxConcurrentJobs = 32
    static let maxConnectionsPerWorker = 8
    static let maxIdempotencyEntries = 1_024
    static let idempotencyLifetime: TimeInterval = 24 * 60 * 60
    static let heartbeatInterval: TimeInterval = 5
    static let heartbeatTimeout: TimeInterval = 15
    static let handshakeTimeout: TimeInterval = 8
    static let requestTimeout: TimeInterval = 30
    static let maxEnvironmentEntries = 32
    static let maxEnvironmentNameBytes = 64
    static let maxEnvironmentValueBytes = 4 * 1_024
    static let maxCapabilities = 32
    static let maxCapabilityBytes = 64
    static let maxProtocolVersions = 8
    static let maxTerminalColumns: UInt16 = 500
    static let maxTerminalRows: UInt16 = 200
    static let maxToolReadBytes = 512 * 1_024
    static let maxToolEditBytes = 256 * 1_024
    static let maxToolOperationBytes = 1_048_576
    static let maxToolPathBytes = 512
    static let maxToolExecutableBytes = 128
    static let maxToolArguments = 64
    static let maxToolArgumentBytes = 4 * 1_024
    static let maxToolArgumentsBytes = 64 * 1_024
    static let maxToolTimeout: TimeInterval = 60 * 60
    static let maxToolDiffPaths = 64
    static let maxToolDiffContextLines = 100
    static let maxToolReconnectAttempts = 1
}

struct DroneHello: Codable, Equatable, Sendable {
    let supportedVersions: [UInt16]
    let capabilities: [String]
    let selectedVersion: UInt16?

    init(
        supportedVersions: [UInt16] = [DroneLimits.protocolVersion],
        capabilities: [String] = ["terminal.v1"],
        selectedVersion: UInt16? = nil
    ) {
        self.supportedVersions = supportedVersions
        self.capabilities = capabilities
        self.selectedVersion = selectedVersion
    }

    func validate() throws {
        guard !supportedVersions.isEmpty,
              supportedVersions.count <= DroneLimits.maxProtocolVersions,
              Set(supportedVersions).count == supportedVersions.count,
              capabilities.count <= DroneLimits.maxCapabilities,
              Set(capabilities).count == capabilities.count,
              capabilities.allSatisfy({
                  !$0.isEmpty && $0.utf8.count <= DroneLimits.maxCapabilityBytes
              })
        else { throw DroneProtocolError.malformedMessage }
        if let selectedVersion {
            guard supportedVersions.contains(selectedVersion) else {
                throw DroneProtocolError.negotiationFailed
            }
        }
    }

    func response() throws -> DroneHello {
        try validate()
        guard selectedVersion == nil,
              supportedVersions.contains(DroneLimits.protocolVersion)
        else { throw DroneProtocolError.negotiationFailed }
        return DroneHello(
            supportedVersions: [DroneLimits.protocolVersion],
            capabilities: capabilities.filter { $0 == "terminal.v1" || $0 == "tools.v1" },
            selectedVersion: DroneLimits.protocolVersion
        )
    }
}

struct DroneCreateBody: Codable, Equatable, Sendable {
    let workspaceID: UUID
    let environment: [String: String]
    let columns: UInt16
    let rows: UInt16
}

struct DroneAttachBody: Codable, Equatable, Sendable {
    let afterSequence: UInt64
    let afterOffset: UInt64
}

struct DroneInputBody: Codable, Equatable, Sendable {
    let data: Data
}

struct DroneFastCommandBody: Codable, Equatable, Sendable {
    let command: String
}

struct DroneActivityBody: Codable, Equatable, Sendable {
    let command: String
    let shellPID: Int32
    let isIdle: Bool
    let lastOutputTimestamp: Double?
}

struct DroneWorkingDirectoryBody: Codable, Equatable, Sendable {
    let path: String
}

struct DroneResizeBody: Codable, Equatable, Sendable {
    let columns: UInt16
    let rows: UInt16
}

struct DroneOutputBody: Codable, Equatable, Sendable {
    let sequence: UInt64
    let offset: UInt64
    let data: Data
    let isFinal: Bool
}

struct DroneErrorBody: Codable, Equatable, Sendable {
    let code: String
    let retryable: Bool
}

struct DroneEmptyBody: Codable, Equatable, Sendable {}

enum DroneMessageKind: String, Codable, Sendable {
    case create
    case created
    case attach
    case attached
    case input
    case resize
    case output
    case detach
    case detached
    case close
    case closed
    case cancel
    case cancelled
    case reconnect
    case reconnected
    case acknowledge
    case resync
    case fastCommand
    case activity
    case activityReport
    case workingDirectory
    case workingDirectoryReport
    case ack
    case heartbeat
    case error
    case toolRead
    case toolReadResult
    case toolEdit
    case toolEditResult
    case toolRun
    case toolDiff
    case toolAccepted
    case toolOutput
    case toolCompletion
    case toolCancel
    case toolCancelled
    case toolAttach
    case toolAttached
}

enum DroneProtocolError: Error, Equatable {
    case unsupportedVersion
    case malformedMessage
    case messageTooLarge
    case invalidIdentifier
    case invalidState
    case idempotencyConflict
    case resourceLimit
    case unauthorized
    case rejectedRecord
    case disconnected
    case negotiationFailed
}

struct DroneEnvelope: Codable, Equatable, Sendable {
    enum Body: Equatable, Sendable {
        case empty
        case create(DroneCreateBody)
        case attach(DroneAttachBody)
        case input(DroneInputBody)
        case fastCommand(DroneFastCommandBody)
        case activityReport(DroneActivityBody)
        case workingDirectoryReport(DroneWorkingDirectoryBody)
        case resize(DroneResizeBody)
        case output(DroneOutputBody)
        case error(DroneErrorBody)
        case toolRead(DroneToolReadRequest)
        case toolReadResult(DroneToolReadResult)
        case toolEdit(DroneToolEditRequest)
        case toolEditResult(DroneToolEditResult)
        case toolRun(DroneToolProcessRequest)
        case toolDiff(DroneToolDiffRequest)
        case toolOutput(DroneToolOutputBody)
        case toolCompletion(DroneToolCompletionBody)
        case toolAttach(DroneToolAttachBody)
        case toolCancel(DroneToolCancelBody)
    }

    let version: UInt16
    let kind: DroneMessageKind
    let requestID: UUID?
    let sessionID: DroneSessionID?
    let lease: DroneToolLease?
    let idempotencyKey: String?
    let body: Body

    init(
        version: UInt16 = DroneLimits.protocolVersion,
        kind: DroneMessageKind,
        requestID: UUID? = nil,
        sessionID: DroneSessionID? = nil,
        lease: DroneToolLease? = nil,
        idempotencyKey: String? = nil,
        body: Body = .empty
    ) {
        self.version = version
        self.kind = kind
        self.requestID = requestID
        self.sessionID = sessionID
        self.lease = lease
        self.idempotencyKey = idempotencyKey
        self.body = body
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case kind
        case requestID
        case sessionID
        case lease
        case idempotencyKey
        case body
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(UInt16.self, forKey: .version)
        kind = try container.decode(DroneMessageKind.self, forKey: .kind)
        requestID = try container.decodeIfPresent(UUID.self, forKey: .requestID)
        sessionID = try container.decodeIfPresent(DroneSessionID.self, forKey: .sessionID)
        lease = try container.decodeIfPresent(DroneToolLease.self, forKey: .lease)
        idempotencyKey = try container.decodeIfPresent(String.self, forKey: .idempotencyKey)
        switch kind {
        case .create:
            body = .create(try container.decode(DroneCreateBody.self, forKey: .body))
        case .attach, .reconnect, .acknowledge:
            body = .attach(try container.decode(DroneAttachBody.self, forKey: .body))
        case .input:
            body = .input(try container.decode(DroneInputBody.self, forKey: .body))
        case .fastCommand:
            body = .fastCommand(try container.decode(DroneFastCommandBody.self, forKey: .body))
        case .activityReport:
            body = .activityReport(try container.decode(DroneActivityBody.self, forKey: .body))
        case .workingDirectoryReport:
            body = .workingDirectoryReport(
                try container.decode(DroneWorkingDirectoryBody.self, forKey: .body)
            )
        case .resize:
            body = .resize(try container.decode(DroneResizeBody.self, forKey: .body))
        case .output:
            body = .output(try container.decode(DroneOutputBody.self, forKey: .body))
        case .error:
            body = .error(try container.decode(DroneErrorBody.self, forKey: .body))
        case .toolRead:
            body = .toolRead(try container.decode(DroneToolReadRequest.self, forKey: .body))
        case .toolReadResult:
            body = .toolReadResult(try container.decode(DroneToolReadResult.self, forKey: .body))
        case .toolEdit:
            body = .toolEdit(try container.decode(DroneToolEditRequest.self, forKey: .body))
        case .toolEditResult:
            body = .toolEditResult(try container.decode(DroneToolEditResult.self, forKey: .body))
        case .toolRun:
            body = .toolRun(try container.decode(DroneToolProcessRequest.self, forKey: .body))
        case .toolDiff:
            body = .toolDiff(try container.decode(DroneToolDiffRequest.self, forKey: .body))
        case .toolOutput:
            body = .toolOutput(try container.decode(DroneToolOutputBody.self, forKey: .body))
        case .toolCompletion:
            body = .toolCompletion(try container.decode(DroneToolCompletionBody.self, forKey: .body))
        case .toolAttach:
            body = .toolAttach(try container.decode(DroneToolAttachBody.self, forKey: .body))
        case .toolCancel:
            body = .toolCancel(try container.decode(DroneToolCancelBody.self, forKey: .body))
        case .created, .attached, .detached, .closed, .cancelled, .reconnected,
             .detach, .close, .cancel, .resync, .activity, .workingDirectory,
             .ack, .heartbeat, .toolAccepted, .toolCancelled, .toolAttached:
            _ = try container.decode(DroneEmptyBody.self, forKey: .body)
            body = .empty
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(requestID, forKey: .requestID)
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(lease, forKey: .lease)
        try container.encodeIfPresent(idempotencyKey, forKey: .idempotencyKey)
        switch body {
        case .empty:
            try container.encode(DroneEmptyBody(), forKey: .body)
        case .create(let value):
            try container.encode(value, forKey: .body)
        case .attach(let value):
            try container.encode(value, forKey: .body)
        case .input(let value):
            try container.encode(value, forKey: .body)
        case .fastCommand(let value):
            try container.encode(value, forKey: .body)
        case .activityReport(let value):
            try container.encode(value, forKey: .body)
        case .workingDirectoryReport(let value):
            try container.encode(value, forKey: .body)
        case .resize(let value):
            try container.encode(value, forKey: .body)
        case .output(let value):
            try container.encode(value, forKey: .body)
        case .error(let value):
            try container.encode(value, forKey: .body)
        case .toolRead(let value):
            try container.encode(value, forKey: .body)
        case .toolReadResult(let value):
            try container.encode(value, forKey: .body)
        case .toolEdit(let value):
            try container.encode(value, forKey: .body)
        case .toolEditResult(let value):
            try container.encode(value, forKey: .body)
        case .toolRun(let value):
            try container.encode(value, forKey: .body)
        case .toolDiff(let value):
            try container.encode(value, forKey: .body)
        case .toolOutput(let value):
            try container.encode(value, forKey: .body)
        case .toolCompletion(let value):
            try container.encode(value, forKey: .body)
        case .toolAttach(let value):
            try container.encode(value, forKey: .body)
        case .toolCancel(let value):
            try container.encode(value, forKey: .body)
        }
    }

    func validate() throws {
        guard version == DroneLimits.protocolVersion else {
            throw DroneProtocolError.unsupportedVersion
        }
        guard kind.isTool || lease == nil else { throw DroneProtocolError.malformedMessage }
        if let idempotencyKey {
            guard Self.isValidIdempotencyKey(idempotencyKey) else {
                throw DroneProtocolError.invalidIdentifier
            }
        }

        switch kind {
        case .create:
            guard requestID != nil, sessionID == nil,
                  let idempotencyKey, Self.isValidIdempotencyKey(idempotencyKey),
                  case .create(let value) = body
            else { throw DroneProtocolError.malformedMessage }
            try Self.validate(rows: value.rows, columns: value.columns)
            try DroneAuthorization.validateEnvironment(value.environment)
        case .created:
            try validateResponse(sessionRequired: true, idempotencyRequired: true)
            guard case .empty = body else { throw DroneProtocolError.malformedMessage }
        case .attach, .reconnect, .acknowledge:
            try validateRequest(sessionRequired: true)
            guard case .attach = body else { throw DroneProtocolError.malformedMessage }
        case .input:
            try validateRequest(sessionRequired: true)
            guard case .input(let value) = body,
                  !value.data.isEmpty,
                  value.data.count <= DroneLimits.maxInputBytes
            else { throw DroneProtocolError.malformedMessage }
        case .fastCommand:
            try validateRequest(sessionRequired: true)
            guard case .fastCommand(let value) = body,
                  !value.command.isEmpty, value.command.utf8.count <= 4 * 1_024,
                  !value.command.utf8.contains(0)
            else { throw DroneProtocolError.malformedMessage }
        case .resize:
            try validateRequest(sessionRequired: true)
            guard case .resize(let value) = body else {
                throw DroneProtocolError.malformedMessage
            }
            try Self.validate(rows: value.rows, columns: value.columns)
        case .output:
            guard requestID == nil, sessionID != nil, idempotencyKey == nil,
                  case .output(let value) = body,
                  value.data.count <= DroneLimits.maxOutputChunkBytes,
                  !value.data.isEmpty || value.isFinal
            else { throw DroneProtocolError.malformedMessage }
        case .activityReport:
            try validateResponse(sessionRequired: true, idempotencyRequired: false)
            guard case .activityReport(let value) = body, value.shellPID > 0,
                  !value.command.isEmpty, value.command.utf8.count <= 256,
                  !value.command.utf8.contains(0),
                  value.lastOutputTimestamp?.isFinite != false
            else { throw DroneProtocolError.malformedMessage }
        case .workingDirectoryReport:
            try validateResponse(sessionRequired: true, idempotencyRequired: false)
            guard case .workingDirectoryReport(let value) = body,
                  !value.path.isEmpty, value.path.utf8.count <= 4 * 1_024,
                  !value.path.utf8.contains(0)
            else { throw DroneProtocolError.malformedMessage }
        case .detach, .close, .cancel, .resync, .activity, .workingDirectory:
            try validateRequest(sessionRequired: true)
            guard case .empty = body, idempotencyKey == nil else {
                throw DroneProtocolError.malformedMessage
            }
        case .attached, .reconnected, .detached, .closed, .cancelled, .ack:
            try validateResponse(sessionRequired: true, idempotencyRequired: false)
            guard case .empty = body, idempotencyKey == nil else {
                throw DroneProtocolError.malformedMessage
            }
        case .heartbeat:
            guard requestID == nil, sessionID == nil, idempotencyKey == nil,
                  case .empty = body
            else { throw DroneProtocolError.malformedMessage }
        case .error:
            guard case .error(let value) = body,
                  !value.code.isEmpty,
                  value.code.utf8.count <= 64,
                  value.code.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
            else { throw DroneProtocolError.malformedMessage }
        case .toolRead, .toolReadResult, .toolEdit, .toolEditResult, .toolRun, .toolDiff,
             .toolAccepted, .toolOutput, .toolCompletion, .toolCancel, .toolCancelled,
             .toolAttach, .toolAttached:
            try validateTool()
        }
    }

    private func validateRequest(sessionRequired: Bool) throws {
        guard requestID != nil, idempotencyKey == nil,
              !sessionRequired || sessionID != nil
        else { throw DroneProtocolError.malformedMessage }
    }

    private func validateResponse(sessionRequired: Bool, idempotencyRequired: Bool) throws {
        guard requestID != nil,
              !sessionRequired || sessionID != nil,
              !idempotencyRequired || idempotencyKey != nil
        else { throw DroneProtocolError.malformedMessage }
    }

    private func validateTool() throws {
        try validateToolCorrelation()
        switch kind {
        case .toolRead:
            guard case .toolRead(let value) = body else { throw DroneProtocolError.malformedMessage }
            try DroneToolValidation.validate(read: value)
        case .toolReadResult:
            guard case .toolReadResult(let value) = body else { throw DroneProtocolError.malformedMessage }
            try DroneToolValidation.validate(readResult: value)
        case .toolEdit:
            guard case .toolEdit(let value) = body else { throw DroneProtocolError.malformedMessage }
            try DroneToolValidation.validate(edit: value)
        case .toolEditResult:
            guard case .toolEditResult(let value) = body,
                  value.bytesWritten >= 0, value.sha256.count == 64,
                  value.sha256.allSatisfy({ $0.isHexDigit })
            else { throw DroneProtocolError.malformedMessage }
        case .toolRun:
            guard case .toolRun(let value) = body else { throw DroneProtocolError.malformedMessage }
            try DroneToolValidation.validate(process: value)
        case .toolDiff:
            guard case .toolDiff(let value) = body else { throw DroneProtocolError.malformedMessage }
            try DroneToolValidation.validate(diff: value)
        case .toolAccepted, .toolCancelled, .toolAttached:
            guard case .empty = body else { throw DroneProtocolError.malformedMessage }
        case .toolOutput:
            guard case .toolOutput(let value) = body else { throw DroneProtocolError.malformedMessage }
            try DroneToolValidation.validate(output: value)
        case .toolCompletion:
            guard case .toolCompletion(let value) = body else { throw DroneProtocolError.malformedMessage }
            try DroneToolValidation.validate(completion: value)
        case .toolCancel:
            guard case .toolCancel = body else { throw DroneProtocolError.malformedMessage }
        case .toolAttach:
            guard case .toolAttach = body else { throw DroneProtocolError.malformedMessage }
        default:
            throw DroneProtocolError.malformedMessage
        }
    }

    private func validateToolCorrelation() throws {
        guard requestID != nil, sessionID == nil, lease != nil, idempotencyKey != nil else {
            throw DroneProtocolError.malformedMessage
        }
    }

    private static func validate(rows: UInt16, columns: UInt16) throws {
        guard rows > 0, columns > 0,
              rows <= DroneLimits.maxTerminalRows,
              columns <= DroneLimits.maxTerminalColumns
        else { throw DroneProtocolError.malformedMessage }
    }

    static func isValidIdempotencyKey(_ value: String) -> Bool {
        (16 ... 128).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (65 ... 90).contains($0)
                || (97 ... 122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

enum DroneProtocolCodec {
    static func encode(_ envelope: DroneEnvelope) throws -> Data {
        try envelope.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(envelope)
        guard data.count <= DroneLimits.maxEnvelopeBytes else {
            throw DroneProtocolError.messageTooLarge
        }
        return data
    }

    static func decode(_ data: Data) throws -> DroneEnvelope {
        guard !data.isEmpty else { throw DroneProtocolError.malformedMessage }
        guard data.count <= DroneLimits.maxEnvelopeBytes else {
            throw DroneProtocolError.messageTooLarge
        }
        let envelope = try JSONDecoder().decode(DroneEnvelope.self, from: data)
        try envelope.validate()
        return envelope
    }

    static func encodeHello(_ hello: DroneHello) throws -> Data {
        try hello.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(hello)
        guard data.count <= DroneLimits.maxHandshakeBytes else {
            throw DroneProtocolError.messageTooLarge
        }
        return data
    }

    static func decodeHello(_ data: Data) throws -> DroneHello {
        guard !data.isEmpty, data.count <= DroneLimits.maxHandshakeBytes else {
            throw DroneProtocolError.malformedMessage
        }
        let hello = try JSONDecoder().decode(DroneHello.self, from: data)
        try hello.validate()
        return hello
    }
}

struct DroneControllerPermissions: OptionSet, Sendable {
    let rawValue: UInt8
    static let terminal = DroneControllerPermissions(rawValue: 1 << 0)
    static let jobs = DroneControllerPermissions(rawValue: 1 << 1)
    static let files = DroneControllerPermissions(rawValue: 1 << 2)
    static let git = DroneControllerPermissions(rawValue: 1 << 3)
    static let all: DroneControllerPermissions = [.terminal, .jobs, .files, .git]
}

enum DroneAuthorization {
    static let allowedEnvironmentNames: Set<String> = [
        "HOME", "LANG", "LC_ALL", "PATH", "TERM", "COLORTERM", "TMPDIR",
    ]

    static func validateEnvironment(_ environment: [String: String]) throws {
        guard environment.count <= DroneLimits.maxEnvironmentEntries else {
            throw DroneProtocolError.resourceLimit
        }
        for (name, value) in environment {
            guard allowedEnvironmentNames.contains(name),
                  name.utf8.count <= DroneLimits.maxEnvironmentNameBytes,
                  value.utf8.count <= DroneLimits.maxEnvironmentValueBytes,
                  !value.utf8.contains(0)
            else { throw DroneProtocolError.unauthorized }
        }
    }

    static func authorize(create: DroneCreateBody, registeredWorkspaces: Set<UUID>) throws {
        guard registeredWorkspaces.contains(create.workspaceID) else {
            throw DroneProtocolError.unauthorized
        }
        try validateEnvironment(create.environment)
    }
}

enum DroneWire {
    static let headerSize = 4

    static func frame(_ record: Data) throws -> Data {
        guard !record.isEmpty, record.count <= DroneLimits.maxFrameBytes,
              let length = UInt32(exactly: record.count)
        else { throw DroneProtocolError.messageTooLarge }
        var prefix = length.bigEndian
        var framed = Data(bytes: &prefix, count: headerSize)
        framed.append(record)
        return framed
    }

    static func payloadLength(_ prefix: Data) throws -> Int {
        guard prefix.count == headerSize else { throw DroneProtocolError.malformedMessage }
        let rawLength = prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard rawLength > 0, let length = Int(exactly: rawLength),
              length <= DroneLimits.maxFrameBytes
        else { throw DroneProtocolError.messageTooLarge }
        return length
    }

    struct StreamDecoder {
        private(set) var buffer = Data()
        let maxBufferedBytes: Int

        init(maxBufferedBytes: Int = DroneLimits.maxFrameBytes + DroneWire.headerSize) {
            self.maxBufferedBytes = maxBufferedBytes
        }

        mutating func append(_ incoming: Data) -> Result<[Data], DroneProtocolError> {
            let (newCount, overflow) = buffer.count.addingReportingOverflow(incoming.count)
            guard !overflow, newCount <= maxBufferedBytes else {
                buffer.removeAll(keepingCapacity: false)
                return .failure(.messageTooLarge)
            }
            buffer.append(incoming)
            var records: [Data] = []
            while buffer.count >= DroneWire.headerSize {
                let length: Int
                do {
                    length = try DroneWire.payloadLength(Data(buffer.prefix(DroneWire.headerSize)))
                } catch {
                    buffer.removeAll(keepingCapacity: false)
                    return .failure(.messageTooLarge)
                }
                let total = DroneWire.headerSize + length
                guard buffer.count >= total else { break }
                records.append(buffer.subdata(in: DroneWire.headerSize ..< total))
                buffer.removeSubrange(0 ..< total)
            }
            return .success(records)
        }
    }
}

struct DroneSessionStateMachine: Equatable {
    enum State: Sendable {
        case attached
        case detached
        case closed
    }

    enum Event {
        case attach
        case input
        case resize
        case detach
        case close
        case cancel
        case disconnect
        case reconnect
    }

    private(set) var state: State = .detached

    mutating func apply(_ event: Event) throws {
        switch event {
        case .attach, .reconnect:
            guard state != .closed else { throw DroneProtocolError.invalidState }
            state = .attached
        case .input, .resize:
            guard state == .attached else { throw DroneProtocolError.invalidState }
        case .detach:
            guard state != .closed else { throw DroneProtocolError.invalidState }
            state = .detached
        case .disconnect:
            if state == .attached { state = .detached }
        case .cancel:
            guard state != .closed else { throw DroneProtocolError.invalidState }
        case .close:
            state = .closed
        }
    }
}

struct DroneIdempotencyLedger {
    private struct Entry {
        let request: DroneEnvelope
        let response: DroneEnvelope
        let storedAt: TimeInterval
    }

    private var entries: [String: Entry] = [:]
    let maximumEntries: Int
    let lifetime: TimeInterval

    init(
        maximumEntries: Int = DroneLimits.maxIdempotencyEntries,
        lifetime: TimeInterval = DroneLimits.idempotencyLifetime
    ) {
        self.maximumEntries = maximumEntries
        self.lifetime = lifetime
    }

    var count: Int { entries.count }

    mutating func response(for request: DroneEnvelope, now: TimeInterval) throws -> DroneEnvelope? {
        guard request.kind == .create, let key = request.idempotencyKey,
              let entry = entries[key]
        else { return nil }
        if now - entry.storedAt >= lifetime {
            entries.removeValue(forKey: key)
            return nil
        }
        guard entry.request == request else { throw DroneProtocolError.idempotencyConflict }
        return entry.response
    }

    mutating func store(
        request: DroneEnvelope,
        response: DroneEnvelope,
        now: TimeInterval
    ) throws {
        guard request.kind == .create, response.kind == .created,
              let key = request.idempotencyKey
        else { throw DroneProtocolError.malformedMessage }
        if let existing = try self.response(for: request, now: now) {
            guard existing == response else { throw DroneProtocolError.idempotencyConflict }
            return
        }
        entries = entries.filter { now - $0.value.storedAt < lifetime }
        guard entries.count < maximumEntries else { throw DroneProtocolError.resourceLimit }
        entries[key] = Entry(request: request, response: response, storedAt: now)
    }
}
