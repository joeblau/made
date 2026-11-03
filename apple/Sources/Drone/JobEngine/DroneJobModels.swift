import Foundation

enum DroneJobState: String, Codable, Sendable {
    case accepted
    case running
    case completed
    case failed
    case cancelled

    var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }
}

enum DroneJobStream: String, Codable, Sendable {
    case standardOutput
    case standardError
}

struct DroneProcessOperation: Codable, Equatable, Sendable {
    var executablePath: String
    var arguments: [String] = []
    var relativeDirectory: String = "."
    var timeoutMilliseconds: Int = 30_000
    var standardOutputLimit: Int = 2 * 1_024 * 1_024
    var standardErrorLimit: Int = 256 * 1_024

    init(
        executablePath: String,
        arguments: [String] = [],
        relativeDirectory: String = ".",
        timeoutMilliseconds: Int = 30_000,
        standardOutputLimit: Int = 2 * 1_024 * 1_024,
        standardErrorLimit: Int = 256 * 1_024
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.relativeDirectory = relativeDirectory
        self.timeoutMilliseconds = timeoutMilliseconds
        self.standardOutputLimit = standardOutputLimit
        self.standardErrorLimit = standardErrorLimit
    }
}

struct DroneReadFileOperation: Codable, Equatable, Sendable {
    var relativePath: String
    var maximumBytes: Int = 1_048_576

    init(relativePath: String, maximumBytes: Int = 1_048_576) {
        self.relativePath = relativePath
        self.maximumBytes = maximumBytes
    }
}

struct DroneWriteFileOperation: Codable, Equatable, Sendable {
    var relativePath: String
    var data: Data

    init(relativePath: String, data: Data) {
        self.relativePath = relativePath
        self.data = data
    }
}

struct DroneListDirectoryOperation: Codable, Equatable, Sendable {
    var relativePath: String = "."
    var maximumEntries: Int = 1_024

    init(relativePath: String = ".", maximumEntries: Int = 1_024) {
        self.relativePath = relativePath
        self.maximumEntries = maximumEntries
    }
}

struct DroneGitStatusOperation: Codable, Equatable, Sendable {
    var relativeDirectory: String = "."
    var timeoutMilliseconds: Int = 30_000
    var outputLimit: Int = 1_048_576

    init(
        relativeDirectory: String = ".",
        timeoutMilliseconds: Int = 30_000,
        outputLimit: Int = 1_048_576
    ) {
        self.relativeDirectory = relativeDirectory
        self.timeoutMilliseconds = timeoutMilliseconds
        self.outputLimit = outputLimit
    }
}

struct DroneGitDiffOperation: Codable, Equatable, Sendable {
    var relativeDirectory: String = "."
    var relativePath: String?
    var timeoutMilliseconds: Int = 30_000
    var outputLimit: Int = 1_048_576

    init(
        relativeDirectory: String = ".",
        relativePath: String? = nil,
        timeoutMilliseconds: Int = 30_000,
        outputLimit: Int = 1_048_576
    ) {
        self.relativeDirectory = relativeDirectory
        self.relativePath = relativePath
        self.timeoutMilliseconds = timeoutMilliseconds
        self.outputLimit = outputLimit
    }
}

enum DroneJobOperation: Codable, Equatable, Sendable {
    case process(DroneProcessOperation)
    case readFile(DroneReadFileOperation)
    case writeFile(DroneWriteFileOperation)
    case listDirectory(DroneListDirectoryOperation)
    case gitStatus(DroneGitStatusOperation)
    case gitDiff(DroneGitDiffOperation)
}

struct DroneJobRequest: Codable, Equatable, Sendable {
    var workspaceID: UUID
    var operation: DroneJobOperation
    var environment: [String: String] = [:]

    init(
        workspaceID: UUID,
        operation: DroneJobOperation,
        environment: [String: String] = [:]
    ) {
        self.workspaceID = workspaceID
        self.operation = operation
        self.environment = environment
    }
}

struct DroneJobCreate: Sendable {
    var controllerID: UUID
    var idempotencyKey: String
    var request: DroneJobRequest

    init(controllerID: UUID, idempotencyKey: String, request: DroneJobRequest) {
        self.controllerID = controllerID
        self.idempotencyKey = idempotencyKey
        self.request = request
    }
}

struct DroneDirectoryEntry: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case file
        case directory
        case symbolicLink
        case other
    }

    var name: String
    var kind: Kind
    var size: UInt64?
}

struct DroneProcessResult: Codable, Equatable, Sendable {
    var exitCode: Int32?
    var signal: Int32?
    var standardOutputTruncated: Bool
    var standardErrorTruncated: Bool
}

enum DroneJobResult: Codable, Equatable, Sendable {
    case process(DroneProcessResult)
    case file(Data)
    case bytesWritten(Int)
    case directory([DroneDirectoryEntry])
}

enum DroneJobFailureCode: String, Codable, Sendable {
    case launchFailed
    case nonZeroExit
    case deadlineExceeded
    case operationFailed
    case workerRestarted
    case persistenceFailed
}

struct DroneJobFailure: Codable, Equatable, Sendable {
    var code: DroneJobFailureCode
    var message: String
}

struct DroneJobOutput: Codable, Equatable, Sendable {
    var stream: DroneJobStream
    var data: Data
}

enum DroneJobNotice: String, Codable, Sendable {
    case outputTruncated
    case recoveredAfterRestart
}

enum DroneJobEventPayload: Codable, Equatable, Sendable {
    case state(DroneJobState)
    case output(DroneJobOutput)
    case truncated(DroneJobStream)
    case notice(DroneJobNotice)
}

struct DroneJobEvent: Codable, Equatable, Sendable {
    var sequence: UInt64
    var timestamp: TimeInterval
    var payload: DroneJobEventPayload
}

struct DroneJobSnapshot: Equatable, Sendable {
    var id: DroneJobID
    var controllerID: UUID
    var idempotencyKey: String
    var request: DroneJobRequest
    var state: DroneJobState
    var createdAt: TimeInterval
    var updatedAt: TimeInterval
    var result: DroneJobResult?
    var failure: DroneJobFailure?
    var latestSequence: UInt64
    var earliestRetainedSequence: UInt64
    var droppedEventCount: UInt64
    var cancellationRequested: Bool
}

struct DroneJobEventPage: Equatable, Sendable {
    var events: [DroneJobEvent]
    var latestSequence: UInt64
    var droppedEventCount: UInt64
}

struct DroneJobEngineLimits: Sendable {
    var maximumJobsPerController = DroneLimits.maxIdempotencyEntries
    var maximumConcurrentJobs = DroneLimits.maxConcurrentJobs
    var idempotencyLifetime = DroneLimits.idempotencyLifetime
    var maximumHistoryEvents = 512
    var maximumHistoryOutputBytes = 1_048_576
    var maximumFileBytes = 1_048_576
    var maximumDirectoryEntries = 1_024
    var maximumProcessOutputBytes = 2 * 1_024 * 1_024
    var maximumProcessTimeoutMilliseconds = 15 * 60 * 1_000
    var maximumProcessArguments = 128
    var maximumArgumentBytes = 16 * 1_024
    var maximumTotalArgumentBytes = 64 * 1_024
    var maximumPathBytes = 4 * 1_024
    var maximumStoredRecordBytes = 16 * 1_024 * 1_024
    var cancellationGracePeriod: TimeInterval = 0.25

    init() {}
}

enum DroneJobError: Error, Equatable {
    case invalidRequest
    case unauthorized
    case idempotencyConflict
    case resourceLimit
    case jobNotFound
    case outputGap
    case storeCorrupted
}
