#if os(macOS)
import Foundation

actor DroneTerminalEngine: DroneTerminalServicing {
    private struct Attachment {
        let pairingID: UUID
        let connectionID: UUID
    }

    private struct Record: Codable {
        let sessionID: DroneSessionID
        let pairingID: UUID
        let workspaceID: UUID
        let tmuxName: String
        let environment: [String: String]
        var columns: UInt16
        var rows: UInt16
        var cursor: DroneTerminalCursor
        let createdAt: Date
        var closedAt: Date?
        var exited: Bool
        var lastOutputTimestamp: Double?
    }

    private struct CreateRecord: Codable {
        let key: String
        let pairingID: UUID
        let body: DroneCreateBody
        let sessionID: DroneSessionID
        let storedAt: Date
    }

    private struct Catalog: Codable {
        /// The catalog layout this build reads and writes. A catalog without a
        /// version predates versioning and uses layout 1; any other is quarantined.
        static let currentSchemaVersion = 1

        var records: [Record] = []
        var creates: [CreateRecord] = []
        var schemaVersion: Int? = Catalog.currentSchemaVersion
    }

    private final class Session {
        var record: Record
        var buffer: DroneTerminalOutputBuffer
        var pty: DronePTY?
        var attachment: Attachment?
        var acknowledgedCursor: DroneTerminalCursor
        var sentCursor: DroneTerminalCursor
        var requiresResynchronization: Bool
        var isBackpressured = false
        var inputWindowStart = Date.distantPast
        var inputCount = 0

        init(record: Record, configuration: DroneTerminalConfiguration, recovered: Bool) {
            self.record = record
            buffer = DroneTerminalOutputBuffer(
                baseCursor: record.cursor,
                maximumBytes: configuration.maximumScrollbackBytes,
                maximumRecords: configuration.maximumScrollbackRecords
            )
            acknowledgedCursor = record.cursor
            sentCursor = record.cursor
            requiresResynchronization = recovered
        }
    }

    private let configuration: DroneTerminalConfiguration
    private let workspaces: [UUID: URL]
    private let tmux: DroneTmux
    private let catalogURL: URL
    /// Catalogs recovery moved aside instead of loading; nonzero is unhealthy storage.
    nonisolated let quarantinedCatalogCount: Int
    private var sessions: [DroneSessionID: Session] = [:]
    private var creates: [CreateRecord] = []

    init(
        workspaces: [UUID: URL],
        stateDirectory: URL,
        tmuxExecutable: String? = DroneTmux.locate(),
        tmuxSocketName: String = "blau-drone",
        configuration: DroneTerminalConfiguration = DroneTerminalConfiguration()
    ) throws {
        guard let tmuxExecutable,
              !tmuxSocketName.isEmpty,
              tmuxSocketName.utf8.count <= 128,
              tmuxSocketName.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
              configuration.maximumLiveSessions > 0,
              configuration.maximumInputBytes > 0,
              configuration.maximumInputBytes <= DroneLimits.maxInputBytes,
              configuration.maximumInputsPerSecond > 0,
              configuration.maximumScrollbackBytes > 0,
              configuration.maximumScrollbackRecords > 0,
              configuration.maximumReconnectQueueBytes > 0,
              configuration.maximumReconnectQueueRecords > 0,
              configuration.maximumIdempotencyEntries > 0,
              configuration.maximumRetainedSessionsPerPairing > 0,
              configuration.maximumPairingCatalogBytes > 0,
              configuration.maximumCatalogBytes
                >= configuration.maximumPairingCatalogBytes + DroneTerminalEngine.catalogEnvelopeBytes
        else { throw DroneTerminalError.tmuxUnavailable }
        self.configuration = configuration
        self.workspaces = workspaces.mapValues { $0.standardizedFileURL.resolvingSymlinksInPath() }
        tmux = DroneTmux(executable: tmuxExecutable, socketName: tmuxSocketName)
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        catalogURL = stateDirectory.appendingPathComponent("terminals.json")
        let quarantineURL = stateDirectory.appendingPathComponent("quarantine", isDirectory: true)
        let catalog = try DroneTerminalEngine.loadCatalog(
            from: catalogURL,
            quarantine: quarantineURL,
            maximumBytes: configuration.maximumCatalogBytes
        )
        quarantinedCatalogCount = DroneTerminalEngine.entryCount(in: quarantineURL)
        for record in catalog.records {
            sessions[record.sessionID] = Session(
                record: record,
                configuration: configuration,
                recovered: record.closedAt == nil && !record.exited
            )
        }
        creates = catalog.creates
    }

    func create(
        _ body: DroneCreateBody,
        pairingID: UUID,
        idempotencyKey: String
    ) throws -> DroneTerminalSnapshot {
        let request = DroneEnvelope(
            kind: .create,
            requestID: UUID(),
            idempotencyKey: idempotencyKey,
            body: .create(body)
        )
        try request.validate()
        try DroneAuthorization.authorize(create: body, registeredWorkspaces: Set(workspaces.keys))
        pruneExpiredState()
        if let existing = creates.first(where: {
            $0.key == idempotencyKey && $0.pairingID == pairingID
        }) {
            // The requested environment is stored once, on the terminal record,
            // which retention keeps while this create record exists (#442).
            guard let session = sessions[existing.sessionID],
                  existing.body.workspaceID == body.workspaceID,
                  existing.body.columns == body.columns,
                  existing.body.rows == body.rows,
                  session.record.environment == body.environment
            else { throw DroneProtocolError.idempotencyConflict }
            return snapshot(session)
        }
        // Idempotency records are an allowance per pairing (#442): one
        // controller filling its table must not block every other controller.
        guard creates.count(where: { $0.pairingID == pairingID })
                < configuration.maximumIdempotencyEntries,
              liveSessions.count < configuration.maximumLiveSessions
        else { throw DroneTerminalError.resourceLimit }
        guard let directory = workspaces[body.workspaceID],
              FileManager.default.fileExists(atPath: directory.path)
        else { throw DroneTerminalError.unauthorized }
        // The catalog bytes a create adds are a per-pairing budget too, checked
        // before tmux or the catalog is touched: a pairing that sends large
        // environments or keeps many terminals exhausts only its own budget.
        let storedBody = DroneCreateBody(
            workspaceID: body.workspaceID,
            environment: [:],
            columns: body.columns,
            rows: body.rows
        )
        guard reserveCatalogSpace(
            Self.recordFootprintBytes + Self.environmentFootprint(body.environment)
                + Self.createFootprintBytes,
            for: pairingID
        ) else { throw DroneTerminalError.resourceLimit }

        let sessionID = DroneSessionID()
        let environment = terminalEnvironment(requested: body.environment)
        let name = Self.tmuxName(for: sessionID)
        try tmux.create(
            sessionName: name,
            directory: directory.path,
            columns: body.columns,
            rows: body.rows,
            environment: environment
        )
        let now = Date()
        let record = Record(
            sessionID: sessionID,
            pairingID: pairingID,
            workspaceID: body.workspaceID,
            tmuxName: name,
            environment: body.environment,
            columns: body.columns,
            rows: body.rows,
            cursor: .zero,
            createdAt: now,
            closedAt: nil,
            exited: false,
            lastOutputTimestamp: nil
        )
        let session = Session(record: record, configuration: configuration, recovered: false)
        sessions[sessionID] = session
        creates.append(CreateRecord(
            key: idempotencyKey,
            pairingID: pairingID,
            body: storedBody,
            sessionID: sessionID,
            storedAt: now
        ))
        do {
            try persist()
            try startPTY(for: session)
        } catch {
            session.pty?.close()
            try? tmux.killSession(name, environment: environment)
            sessions.removeValue(forKey: sessionID)
            creates.removeAll { $0.sessionID == sessionID }
            throw error
        }
        return snapshot(session)
    }

    func attach(
        _ sessionID: DroneSessionID,
        pairingID: UUID,
        connectionID: UUID,
        after cursor: DroneTerminalCursor
    ) throws -> DroneTerminalSnapshot {
        let session = try liveSession(sessionID, pairingID: pairingID)
        guard !session.requiresResynchronization else { throw DroneTerminalError.outputGap }
        _ = try session.buffer.replay(after: cursor)
        try setAttachment(session, pairingID: pairingID, connectionID: connectionID)
        session.acknowledgedCursor = cursor
        session.sentCursor = cursor
        try startPTYIfNeeded(for: session)
        updateBackpressure(session)
        if !session.isBackpressured { session.pty?.resumeReading() }
        return snapshot(session)
    }

    func resynchronize(
        _ sessionID: DroneSessionID,
        pairingID: UUID,
        connectionID: UUID
    ) throws -> DroneTerminalSnapshot {
        let session = try liveSession(sessionID, pairingID: pairingID)
        try setAttachment(session, pairingID: pairingID, connectionID: connectionID)
        try startPTYIfNeeded(for: session)
        let base = session.buffer.endCursor
        let visible = try tmux.captureVisibleOutput(
            sessionName: session.record.tmuxName,
            environment: terminalEnvironment(requested: session.record.environment)
        )
        session.buffer = DroneTerminalOutputBuffer(
            baseCursor: base,
            maximumBytes: configuration.maximumScrollbackBytes,
            maximumRecords: configuration.maximumScrollbackRecords
        )
        session.acknowledgedCursor = base
        session.sentCursor = base
        for chunk in Self.split(visible) {
            try session.buffer.append(data: chunk)
        }
        session.requiresResynchronization = false
        session.isBackpressured = false
        session.pty?.resumeReading()
        try persist()
        return snapshot(session)
    }

    func input(
        _ data: Data,
        sessionID: DroneSessionID,
        pairingID: UUID,
        connectionID: UUID
    ) throws {
        let session = try attachedSession(
            sessionID,
            pairingID: pairingID,
            connectionID: connectionID
        )
        guard !data.isEmpty, data.count <= configuration.maximumInputBytes else {
            throw DroneTerminalError.malformedInput
        }
        let now = Date()
        if now.timeIntervalSince(session.inputWindowStart) >= 1 {
            session.inputWindowStart = now
            session.inputCount = 0
        }
        guard session.inputCount < configuration.maximumInputsPerSecond else {
            throw DroneTerminalError.inputRateLimit
        }
        session.inputCount += 1
        try requirePTY(session).write(data)
    }

    func readOutput(
        _ sessionID: DroneSessionID,
        pairingID: UUID,
        connectionID: UUID,
        maximumChunks: Int = 32
    ) throws -> DroneTerminalOutputPage {
        let session = try attachedSession(
            sessionID,
            pairingID: pairingID,
            connectionID: connectionID
        )
        guard (1 ... DroneLimits.maxReconnectQueueRecords).contains(maximumChunks) else {
            throw DroneTerminalError.malformedInput
        }
        let available = try session.buffer.replay(after: session.sentCursor)
        let chunks = Array(available.prefix(maximumChunks))
        if let last = chunks.last {
            session.sentCursor = DroneTerminalCursor(output: last)
        }
        return DroneTerminalOutputPage(
            chunks: chunks,
            cursor: session.sentCursor,
            isBackpressured: session.isBackpressured,
            isFinal: session.record.exited && session.sentCursor == session.buffer.endCursor
        )
    }

    func acknowledge(
        _ cursor: DroneTerminalCursor,
        sessionID: DroneSessionID,
        pairingID: UUID,
        connectionID: UUID
    ) throws {
        let session = try attachedSession(
            sessionID,
            pairingID: pairingID,
            connectionID: connectionID
        )
        guard cursor.sequence >= session.acknowledgedCursor.sequence,
              cursor.sequence <= session.sentCursor.sequence,
              session.buffer.contains(cursor)
        else { throw DroneTerminalError.invalidCursor }
        session.acknowledgedCursor = cursor
        updateBackpressure(session)
        if !session.isBackpressured { session.pty?.resumeReading() }
        try persist()
    }

    func resize(
        columns: UInt16,
        rows: UInt16,
        sessionID: DroneSessionID,
        pairingID: UUID,
        connectionID: UUID
    ) throws {
        let session = try attachedSession(
            sessionID,
            pairingID: pairingID,
            connectionID: connectionID
        )
        guard columns > 0, rows > 0,
              columns <= DroneLimits.maxTerminalColumns,
              rows <= DroneLimits.maxTerminalRows
        else { throw DroneTerminalError.malformedInput }
        try requirePTY(session).resize(columns: columns, rows: rows)
        try tmux.resize(
            sessionName: session.record.tmuxName,
            columns: columns,
            rows: rows,
            environment: terminalEnvironment(requested: session.record.environment)
        )
        session.record.columns = columns
        session.record.rows = rows
        try persist()
    }

    func detach(
        _ sessionID: DroneSessionID,
        pairingID: UUID,
        connectionID: UUID
    ) throws {
        let session = try liveSession(sessionID, pairingID: pairingID)
        if let attachment = session.attachment {
            guard attachment.pairingID == pairingID,
                  attachment.connectionID == connectionID
            else { throw DroneTerminalError.unauthorized }
            session.attachment = nil
        }
        try persist()
    }

    func disconnect(pairingID: UUID, connectionID: UUID) {
        for session in sessions.values where session.attachment?.pairingID == pairingID
            && session.attachment?.connectionID == connectionID {
            session.attachment = nil
        }
        try? persist()
    }

    func interrupt(
        _ sessionID: DroneSessionID,
        pairingID: UUID,
        connectionID: UUID
    ) throws {
        let session = try attachedSession(
            sessionID,
            pairingID: pairingID,
            connectionID: connectionID
        )
        try requirePTY(session).write(Data([3]))
    }

    func runFastCommand(
        _ command: String,
        sessionID: DroneSessionID,
        pairingID: UUID,
        connectionID: UUID
    ) async throws {
        let executable = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !executable.isEmpty, executable.utf8.count <= configuration.maximumFastCommandBytes,
              !executable.utf8.contains(0)
        else { throw DroneTerminalError.malformedInput }
        _ = try attachedSession(sessionID, pairingID: pairingID, connectionID: connectionID)
        for _ in 0 ..< 3 {
            let session = try attachedSession(
                sessionID,
                pairingID: pairingID,
                connectionID: connectionID
            )
            let current = try activity(sessionID, pairingID: pairingID)
            if current.isIdle { break }
            try requirePTY(session).write(Data([3]))
            for _ in 0 ..< 5 {
                try await Task.sleep(for: .milliseconds(100))
                if try activity(sessionID, pairingID: pairingID).isIdle { break }
            }
        }
        let session = try attachedSession(
            sessionID,
            pairingID: pairingID,
            connectionID: connectionID
        )
        guard try activity(sessionID, pairingID: pairingID).isIdle else {
            throw DroneTerminalError.invalidState
        }
        let environment = terminalEnvironment(requested: session.record.environment)
        try tmux.sendLiteral(executable, sessionName: session.record.tmuxName, environment: environment)
        try tmux.sendEnter(sessionName: session.record.tmuxName, environment: environment)
    }

    func activity(
        _ sessionID: DroneSessionID,
        pairingID: UUID
    ) throws -> DroneActivityBody {
        let session = try liveSession(sessionID, pairingID: pairingID)
        let runtime = try tmux.activity(
            sessionName: session.record.tmuxName,
            environment: terminalEnvironment(requested: session.record.environment)
        )
        return DroneActivityBody(
            command: runtime.command,
            shellPID: runtime.shellPID,
            isIdle: Self.interactiveShells.contains(Self.commandName(runtime.command)),
            lastOutputTimestamp: session.record.lastOutputTimestamp
        )
    }

    func workingDirectory(
        _ sessionID: DroneSessionID,
        pairingID: UUID
    ) throws -> DroneWorkingDirectoryBody {
        let session = try liveSession(sessionID, pairingID: pairingID)
        return try DroneWorkingDirectoryBody(
            path: tmux.workingDirectory(
                sessionName: session.record.tmuxName,
                environment: terminalEnvironment(requested: session.record.environment)
            )
        )
    }

    func close(
        _ sessionID: DroneSessionID,
        pairingID: UUID,
        connectionID: UUID? = nil
    ) throws {
        guard let session = sessions[sessionID], session.record.pairingID == pairingID else {
            throw DroneTerminalError.invalidSession
        }
        if session.record.closedAt != nil { return }
        if let connectionID, let attachment = session.attachment {
            guard attachment.pairingID == pairingID,
                  attachment.connectionID == connectionID
            else { throw DroneTerminalError.unauthorized }
        }
        let environment = terminalEnvironment(requested: session.record.environment)
        if tmux.hasSession(session.record.tmuxName, environment: environment) {
            try tmux.killSession(session.record.tmuxName, environment: environment)
        }
        session.pty?.close()
        session.pty = nil
        session.attachment = nil
        session.record.closedAt = Date()
        try persist()
    }

    func snapshot(_ sessionID: DroneSessionID, pairingID: UUID) throws -> DroneTerminalSnapshot {
        snapshot(try liveSession(sessionID, pairingID: pairingID))
    }

    func shutdown() {
        for session in sessions.values {
            session.pty?.close()
            session.pty = nil
            session.attachment = nil
        }
        try? persist()
    }

    /// The only place a PTY chunk is appended. `source` keeps its read gate
    /// claimed until this returns, so chunks arrive here one at a time and in
    /// read order; a chunk from a PTY the session no longer owns is dropped.
    private func receiveOutput(_ data: Data, sessionID: DroneSessionID, source: DronePTY) {
        guard let session = sessions[sessionID], session.pty === source,
              session.record.closedAt == nil, !session.record.exited
        else {
            source.completeOutputDelivery(resumeReading: false)
            return
        }
        do {
            try session.buffer.append(data: data)
            session.record.cursor = session.buffer.endCursor
            session.record.lastOutputTimestamp = Date().timeIntervalSince1970
            updateBackpressure(session)
            source.completeOutputDelivery(resumeReading: !session.isBackpressured)
        } catch {
            source.pauseReading()
            session.isBackpressured = true
            source.completeOutputDelivery(resumeReading: false)
        }
    }

    private func receiveExit(sessionID: DroneSessionID) {
        guard let session = sessions[sessionID], session.record.closedAt == nil,
              !session.record.exited
        else { return }
        try? session.buffer.append(data: Data(), isFinal: true)
        session.record.cursor = session.buffer.endCursor
        session.record.exited = true
        session.pty?.close()
        session.pty = nil
        session.attachment = nil
        try? persist()
    }

    private func startPTYIfNeeded(for session: Session) throws {
        if session.pty == nil { try startPTY(for: session) }
    }

    private func startPTY(for session: Session) throws {
        guard !session.record.exited, session.record.closedAt == nil else {
            throw DroneTerminalError.invalidState
        }
        let environment = terminalEnvironment(requested: session.record.environment)
        guard tmux.hasSession(session.record.tmuxName, environment: environment) else {
            session.record.exited = true
            throw DroneTerminalError.invalidState
        }
        let sessionID = session.record.sessionID
        session.pty = try DronePTY(
            executable: tmux.executable,
            arguments: tmux.attachArguments(sessionName: session.record.tmuxName),
            environment: environment,
            columns: session.record.columns,
            rows: session.record.rows,
            onOutput: { source, data in
                Task { await self.receiveOutput(data, sessionID: sessionID, source: source) }
            },
            onExit: {
                Task { await self.receiveExit(sessionID: sessionID) }
            }
        )
    }

    private func setAttachment(
        _ session: Session,
        pairingID: UUID,
        connectionID: UUID
    ) throws {
        if let attachment = session.attachment,
           attachment.pairingID != pairingID || attachment.connectionID != connectionID {
            throw DroneTerminalError.attachmentConflict
        }
        session.attachment = Attachment(pairingID: pairingID, connectionID: connectionID)
    }

    private func updateBackpressure(_ session: Session) {
        let pendingBytes = session.buffer.endCursor.offset - session.acknowledgedCursor.offset
        let pendingRecords = session.buffer.endCursor.sequence - session.acknowledgedCursor.sequence
        session.isBackpressured =
            pendingBytes + UInt64(DroneLimits.maxOutputChunkBytes)
                > UInt64(configuration.maximumReconnectQueueBytes)
            || pendingRecords + 1 > UInt64(configuration.maximumReconnectQueueRecords)
        if session.isBackpressured { session.pty?.pauseReading() }
    }

    private func attachedSession(
        _ sessionID: DroneSessionID,
        pairingID: UUID,
        connectionID: UUID
    ) throws -> Session {
        let session = try liveSession(sessionID, pairingID: pairingID)
        guard let attachment = session.attachment,
              attachment.pairingID == pairingID,
              attachment.connectionID == connectionID
        else { throw DroneTerminalError.invalidState }
        return session
    }

    private func liveSession(
        _ sessionID: DroneSessionID,
        pairingID: UUID
    ) throws -> Session {
        guard let session = sessions[sessionID] else { throw DroneTerminalError.invalidSession }
        guard session.record.pairingID == pairingID else { throw DroneTerminalError.unauthorized }
        guard session.record.closedAt == nil, !session.record.exited else {
            throw DroneTerminalError.invalidState
        }
        return session
    }

    private func requirePTY(_ session: Session) throws -> DronePTY {
        guard let pty = session.pty else { throw DroneTerminalError.invalidState }
        return pty
    }

    private var liveSessions: [Session] {
        sessions.values.filter { $0.record.closedAt == nil && !$0.record.exited }
    }

    private func snapshot(_ session: Session) -> DroneTerminalSnapshot {
        let state: DroneTerminalRuntimeState
        if session.record.closedAt != nil {
            state = .closed
        } else if session.record.exited {
            state = .exited
        } else {
            state = session.attachment == nil ? .detached : .attached
        }
        return DroneTerminalSnapshot(
            sessionID: session.record.sessionID,
            workspaceID: session.record.workspaceID,
            state: state,
            columns: session.record.columns,
            rows: session.record.rows,
            cursor: session.buffer.endCursor,
            isBackpressured: session.isBackpressured,
            requiresResynchronization: session.requiresResynchronization
        )
    }

    private func pruneExpiredState() {
        let now = Date()
        creates.removeAll {
            now.timeIntervalSince($0.storedAt) >= configuration.idempotencyLifetime
        }
        // Finished terminals are retained per pairing (#442), so one pairing's
        // activity never drops another's. A terminal an unexpired create
        // record references is never dropped, so a same-key retry returns its
        // original snapshot instead of `idempotencyConflict`.
        var retained: [UUID: Int] = [:]
        let referenced = Set(creates.map(\.sessionID))
        for session in sessions.values
        where Self.isFinished(session.record) && referenced.contains(session.record.sessionID) {
            retained[session.record.pairingID, default: 0] += 1
        }
        for session in evictableSessions().reversed() {
            let pairingID = session.record.pairingID
            if retained[pairingID, default: 0] < configuration.maximumRetainedSessionsPerPairing {
                retained[pairingID, default: 0] += 1
            } else {
                evict(session)
            }
        }
        // Per-pairing budgets keep the catalog under its cap while no more
        // pairings hold state than the worker can pair at once. Past that
        // (state left by revoked controllers), drop the oldest unreferenced
        // finished terminals rather than fail every pairing's persist.
        var total = catalogFootprint()
        for session in evictableSessions() where total > catalogBudget {
            total -= Self.footprint(of: session.record)
            evict(session)
        }
    }

    /// Makes room for `bytes` more of `pairingID`'s persisted state, under both
    /// its own budget and the catalog's, by dropping only finished terminals no
    /// create record references: first the pairing's own, then (only past the
    /// pairing limit, see `pruneExpiredState`) the oldest of any pairing.
    /// Returns false, dropping nothing, when that cannot make room.
    private func reserveCatalogSpace(_ bytes: Int, for pairingID: UUID) -> Bool {
        var owned = catalogFootprint(pairingID: pairingID) + bytes
        var total = catalogFootprint() + bytes
        var planned: [Session] = []
        var plannedIDs = Set<DroneSessionID>()
        for session in evictableSessions(pairingID: pairingID)
        where owned > configuration.maximumPairingCatalogBytes || total > catalogBudget {
            let footprint = Self.footprint(of: session.record)
            owned -= footprint
            total -= footprint
            planned.append(session)
            plannedIDs.insert(session.record.sessionID)
        }
        guard owned <= configuration.maximumPairingCatalogBytes else { return false }
        for session in evictableSessions()
        where total > catalogBudget && !plannedIDs.contains(session.record.sessionID) {
            total -= Self.footprint(of: session.record)
            planned.append(session)
        }
        guard total <= catalogBudget else { return false }
        for session in planned {
            evict(session)
        }
        return true
    }

    /// Finished terminals that no unexpired create record references, oldest
    /// first: the only terminal state retention or a byte budget may drop.
    private func evictableSessions(pairingID: UUID? = nil) -> [Session] {
        let referenced = Set(creates.map(\.sessionID))
        var evictable: [Session] = []
        for session in sessions.values
        where Self.isFinished(session.record) && !referenced.contains(session.record.sessionID) {
            if let pairingID, session.record.pairingID != pairingID { continue }
            evictable.append(session)
        }
        return evictable.sorted { $0.record.createdAt < $1.record.createdAt }
    }

    private func evict(_ session: Session) {
        if session.record.closedAt == nil {
            // An exited terminal's tmux session can outlive its client; close
            // is the only other path that kills it, so do not orphan it here.
            let environment = terminalEnvironment(requested: session.record.environment)
            if tmux.hasSession(session.record.tmuxName, environment: environment) {
                try? tmux.killSession(session.record.tmuxName, environment: environment)
            }
        }
        session.pty?.close()
        session.pty = nil
        sessions.removeValue(forKey: session.record.sessionID)
    }

    /// Upper bound on the encoded bytes `pairingID`'s records (or, for nil, all
    /// records) add to the catalog.
    private func catalogFootprint(pairingID: UUID? = nil) -> Int {
        var bytes = 0
        for session in sessions.values where pairingID == nil || session.record.pairingID == pairingID {
            bytes += Self.footprint(of: session.record)
        }
        for create in creates where pairingID == nil || create.pairingID == pairingID {
            bytes += Self.footprint(of: create)
        }
        return bytes
    }

    private var catalogBudget: Int {
        configuration.maximumCatalogBytes - Self.catalogEnvelopeBytes
    }

    private func persist() throws {
        pruneExpiredState()
        for session in sessions.values {
            session.record.cursor = session.buffer.endCursor
        }
        let catalog = Catalog(
            records: sessions.values.map(\.record).sorted(by: {
                $0.sessionID.rawValue.uuidString < $1.sessionID.rawValue.uuidString
            }),
            creates: creates
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(catalog)
        guard data.count <= configuration.maximumCatalogBytes else {
            throw DroneTerminalError.persistenceFailed
        }
        do {
            try data.write(to: catalogURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: catalogURL.path
            )
        } catch {
            throw DroneTerminalError.persistenceFailed
        }
    }

    private func terminalEnvironment(requested: [String: String]) -> [String: String] {
        var environment = [
            "HOME": NSHomeDirectory(),
            "LANG": "en_US.UTF-8",
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "TMPDIR": FileManager.default.temporaryDirectory.path,
        ]
        for (name, value) in requested where DroneAuthorization.allowedEnvironmentNames.contains(name) {
            environment[name] = value
        }
        return environment
    }

    /// Returns the persisted catalog only when this build can decode and trust
    /// all of it. Otherwise the file is moved into `quarantine/` and recovery
    /// starts empty, so a corrupt or newer-version catalog never stops the
    /// daemon. Size is checked before any read so the file is never over-allocated.
    private static func loadCatalog(from url: URL, quarantine: URL, maximumBytes: Int) throws -> Catalog {
        guard FileManager.default.fileExists(atPath: url.path) else { return Catalog() }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? Int, size <= maximumBytes,
           let data = try? Data(contentsOf: url),
           let catalog = try? JSONDecoder().decode(Catalog.self, from: data),
           isTrusted(catalog) {
            return catalog
        }
        // If the move fails, fail startup rather than later overwriting the only copy.
        do {
            let destination = quarantine.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.moveItem(
                at: url,
                to: destination.appendingPathComponent(url.lastPathComponent)
            )
        } catch {
            throw DroneTerminalError.persistenceFailed
        }
        return Catalog()
    }

    private static func isTrusted(_ catalog: Catalog) -> Bool {
        guard (catalog.schemaVersion ?? 1) == Catalog.currentSchemaVersion else { return false }
        var sessionIDs = Set<DroneSessionID>()
        for record in catalog.records {
            guard record.tmuxName == tmuxName(for: record.sessionID),
                  sessionIDs.insert(record.sessionID).inserted
            else { return false }
        }
        return true
    }

    private static func entryCount(in directory: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.count ?? 0
    }

    /// Upper bounds on one entry's encoded size, excluding its environment,
    /// including the array separator and room for every mutable field at its
    /// widest (64-bit cursors, `closedAt`, timestamps): about 480 and 400 bytes
    /// at most today. An admitted entry's footprint therefore never grows.
    private static let recordFootprintBytes = 640
    private static let createFootprintBytes = 512
    private static let catalogEnvelopeBytes = 1_024

    /// JSON escapes any byte to at most six (`\u0001`), plus quotes, colon
    /// and separator per entry.
    private static func environmentFootprint(_ environment: [String: String]) -> Int {
        environment.reduce(0) { $0 + 6 * ($1.key.utf8.count + $1.value.utf8.count) + 6 }
    }

    private static func footprint(of record: Record) -> Int {
        recordFootprintBytes + environmentFootprint(record.environment)
    }

    /// Records written before #442 also carry the environment in `body`.
    private static func footprint(of create: CreateRecord) -> Int {
        createFootprintBytes + environmentFootprint(create.body.environment)
    }

    private static func isFinished(_ record: Record) -> Bool {
        record.closedAt != nil || record.exited
    }

    private static func tmuxName(for sessionID: DroneSessionID) -> String {
        "drone-\(sessionID.rawValue.uuidString.lowercased())"
    }

    private static func split(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        return stride(from: 0, to: data.count, by: DroneLimits.maxOutputChunkBytes).map {
            data.subdata(in: $0 ..< min($0 + DroneLimits.maxOutputChunkBytes, data.count))
        }
    }

    private static let interactiveShells: Set<String> = [
        "bash", "csh", "dash", "fish", "ksh", "nu", "pwsh", "sh", "tcsh", "xonsh", "zsh",
    ]

    private static func commandName(_ command: String) -> String {
        command.split(separator: "/").last.map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "-")).lowercased() ?? ""
    }
}
#endif
