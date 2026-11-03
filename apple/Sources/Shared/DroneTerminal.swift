import Foundation

struct DroneTerminalCursor: Codable, Equatable, Sendable {
    static let zero = DroneTerminalCursor(sequence: 0, offset: 0)

    let sequence: UInt64
    let offset: UInt64

    init(sequence: UInt64, offset: UInt64) {
        self.sequence = sequence
        self.offset = offset
    }

    init(output: DroneOutputBody) {
        sequence = output.sequence + 1
        offset = output.offset + UInt64(output.data.count)
    }

    var attachBody: DroneAttachBody {
        DroneAttachBody(afterSequence: sequence, afterOffset: offset)
    }
}

struct DroneTerminalConfiguration: Sendable {
    var maximumLiveSessions = DroneLimits.maxLiveSessions
    var maximumInputBytes = DroneLimits.maxInputBytes
    var maximumInputsPerSecond = 128
    var maximumScrollbackBytes = DroneLimits.maxTerminalScrollbackBytes
    var maximumScrollbackRecords = 16_384
    var maximumReconnectQueueBytes = DroneLimits.maxReconnectQueueBytes
    var maximumReconnectQueueRecords = DroneLimits.maxReconnectQueueRecords
    var maximumFastCommandBytes = 4 * 1_024
    var maximumIdempotencyEntries = DroneLimits.maxIdempotencyEntries
    var idempotencyLifetime = DroneLimits.idempotencyLifetime

    init() {}
}

enum DroneTerminalRuntimeState: String, Codable, Sendable {
    case detached
    case attached
    case exited
    case closed
}

struct DroneTerminalSnapshot: Equatable, Sendable {
    let sessionID: DroneSessionID
    let workspaceID: UUID
    let state: DroneTerminalRuntimeState
    let columns: UInt16
    let rows: UInt16
    let cursor: DroneTerminalCursor
    let isBackpressured: Bool
    let requiresResynchronization: Bool
}

struct DroneTerminalOutputPage: Equatable, Sendable {
    let chunks: [DroneOutputBody]
    let cursor: DroneTerminalCursor
    let isBackpressured: Bool
    let isFinal: Bool
}

enum DroneTerminalError: Error, Equatable {
    case invalidSession
    case unauthorized
    case invalidState
    case attachmentConflict
    case invalidCursor
    case outputGap
    case resourceLimit
    case inputRateLimit
    case malformedInput
    case persistenceFailed
    case processFailed
    case tmuxUnavailable
}

protocol DroneTerminalServicing: Actor {
    func create(
        _ body: DroneCreateBody,
        pairingID: UUID,
        idempotencyKey: String
    ) throws -> DroneTerminalSnapshot
    func attach(
        _ sessionID: DroneSessionID,
        pairingID: UUID,
        connectionID: UUID,
        after cursor: DroneTerminalCursor
    ) throws -> DroneTerminalSnapshot
    func resynchronize(
        _ sessionID: DroneSessionID,
        pairingID: UUID,
        connectionID: UUID
    ) throws -> DroneTerminalSnapshot
    func input(
        _ data: Data,
        sessionID: DroneSessionID,
        pairingID: UUID,
        connectionID: UUID
    ) throws
    func readOutput(
        _ sessionID: DroneSessionID,
        pairingID: UUID,
        connectionID: UUID,
        maximumChunks: Int
    ) throws -> DroneTerminalOutputPage
    func acknowledge(
        _ cursor: DroneTerminalCursor,
        sessionID: DroneSessionID,
        pairingID: UUID,
        connectionID: UUID
    ) throws
    func resize(
        columns: UInt16,
        rows: UInt16,
        sessionID: DroneSessionID,
        pairingID: UUID,
        connectionID: UUID
    ) throws
    func detach(
        _ sessionID: DroneSessionID,
        pairingID: UUID,
        connectionID: UUID
    ) throws
    func disconnect(pairingID: UUID, connectionID: UUID)
    func interrupt(
        _ sessionID: DroneSessionID,
        pairingID: UUID,
        connectionID: UUID
    ) throws
    func runFastCommand(
        _ command: String,
        sessionID: DroneSessionID,
        pairingID: UUID,
        connectionID: UUID
    ) async throws
    func activity(
        _ sessionID: DroneSessionID,
        pairingID: UUID
    ) throws -> DroneActivityBody
    func workingDirectory(
        _ sessionID: DroneSessionID,
        pairingID: UUID
    ) throws -> DroneWorkingDirectoryBody
    func close(
        _ sessionID: DroneSessionID,
        pairingID: UUID,
        connectionID: UUID?
    ) throws
}

struct DroneTerminalOutputBuffer {
    private(set) var chunks: [DroneOutputBody] = []
    private(set) var baseCursor: DroneTerminalCursor
    private(set) var endCursor: DroneTerminalCursor
    private(set) var byteCount = 0
    let maximumBytes: Int
    let maximumRecords: Int

    init(
        baseCursor: DroneTerminalCursor = .zero,
        maximumBytes: Int = DroneLimits.maxTerminalScrollbackBytes,
        maximumRecords: Int = 16_384
    ) {
        self.baseCursor = baseCursor
        endCursor = baseCursor
        self.maximumBytes = maximumBytes
        self.maximumRecords = maximumRecords
    }

    mutating func append(data: Data, isFinal: Bool = false) throws {
        guard data.count <= DroneLimits.maxOutputChunkBytes,
              !data.isEmpty || isFinal,
              endCursor.sequence < UInt64.max,
              endCursor.offset <= UInt64.max - UInt64(data.count)
        else { throw DroneTerminalError.resourceLimit }
        let output = DroneOutputBody(
            sequence: endCursor.sequence,
            offset: endCursor.offset,
            data: data,
            isFinal: isFinal
        )
        chunks.append(output)
        byteCount += data.count
        endCursor = DroneTerminalCursor(output: output)
        trim()
    }

    func replay(after cursor: DroneTerminalCursor) throws -> [DroneOutputBody] {
        if cursor == endCursor { return [] }
        guard let index = chunks.firstIndex(where: {
            $0.sequence == cursor.sequence && $0.offset == cursor.offset
        }) else { throw DroneTerminalError.outputGap }
        return Array(chunks[index...])
    }

    func contains(_ cursor: DroneTerminalCursor) -> Bool {
        cursor == endCursor || chunks.contains {
            $0.sequence == cursor.sequence && $0.offset == cursor.offset
        }
    }

    private mutating func trim() {
        while chunks.count > 1,
              byteCount > maximumBytes || chunks.count > maximumRecords {
            let removed = chunks.removeFirst()
            byteCount -= removed.data.count
            baseCursor = DroneTerminalCursor(
                sequence: removed.sequence + 1,
                offset: removed.offset + UInt64(removed.data.count)
            )
        }
    }
}
