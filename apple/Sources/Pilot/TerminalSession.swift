import Foundation

enum TerminalDestinationKind: String, Codable, Sendable {
    case local
    case drone
    case invalid
}

struct TerminalDestination: Equatable, Sendable, Codable {
    let kind: TerminalDestinationKind
    let droneID: UUID?
    let remoteSessionID: UUID?
    let droneName: String?

    static let local = TerminalDestination(kind: .local)

    init(
        kind: TerminalDestinationKind,
        droneID: UUID? = nil,
        remoteSessionID: UUID? = nil,
        droneName: String? = nil
    ) {
        self.kind = kind
        self.droneID = droneID
        self.remoteSessionID = remoteSessionID
        self.droneName = droneName
    }

    static func drone(
        droneID: UUID,
        name: String? = nil,
        remoteSessionID: UUID? = nil
    ) -> TerminalDestination {
        TerminalDestination(
            kind: .drone,
            droneID: droneID,
            remoteSessionID: remoteSessionID,
            droneName: name
        )
    }

    static func restored(
        kindRaw: String?,
        droneIDRaw: String?,
        remoteSessionIDRaw: String?,
        droneNameRaw: String? = nil
    ) -> TerminalDestination {
        let kind = kindRaw.flatMap(TerminalDestinationKind.init(rawValue:)) ?? .local
        let droneID = droneIDRaw.flatMap(UUID.init(uuidString:))
        let remoteSessionID = remoteSessionIDRaw.flatMap(UUID.init(uuidString:))
        if kindRaw != nil, TerminalDestinationKind(rawValue: kindRaw!) == nil {
            return TerminalDestination(kind: .invalid, droneID: droneID, remoteSessionID: remoteSessionID)
        }
        if droneIDRaw != nil && droneID == nil || remoteSessionIDRaw != nil && remoteSessionID == nil {
            return TerminalDestination(kind: .invalid, droneID: droneID, remoteSessionID: remoteSessionID)
        }
        return TerminalDestination(
            kind: kind,
            droneID: droneID,
            remoteSessionID: remoteSessionID,
            droneName: droneNameRaw
        )
    }

    var ownership: TerminalDestinationOwnership {
        TerminalDestinationOwnership(kind: kind, droneID: droneID)
    }

    var isValid: Bool {
        switch kind {
        case .local:
            droneID == nil && remoteSessionID == nil
        case .drone:
            droneID != nil
        case .invalid:
            false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case droneID
        case remoteSessionID
        case droneName
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kindRaw = try container.decodeIfPresent(String.self, forKey: .kind)
        kind = kindRaw.flatMap(TerminalDestinationKind.init(rawValue:)) ?? (kindRaw == nil ? .local : .invalid)
        droneID = try container.decodeIfPresent(UUID.self, forKey: .droneID)
        remoteSessionID = try container.decodeIfPresent(UUID.self, forKey: .remoteSessionID)
        droneName = try container.decodeIfPresent(String.self, forKey: .droneName)
    }
}

struct TerminalDestinationOwnership: Hashable, Sendable {
    let kind: TerminalDestinationKind
    let droneID: UUID?
}

struct TerminalSessionIdentity: Hashable, Sendable {
    let paneID: UUID
    let ownership: TerminalDestinationOwnership
    let generation: UInt64

    var runtimeCacheKey: String {
        "\(paneID.uuidString):\(ownership.kind.rawValue):\(ownership.droneID?.uuidString ?? "local"):\(generation)"
    }
}

enum TerminalSessionFailure: Error, Equatable, Sendable {
    case invalidDestination
    case destinationChanged
    case droneUnavailable(UUID)
    case remoteSessionMissing
    case staleGeneration
    case remoteSessionConflict
}

enum TerminalSessionBootstrap: Sendable {
    case local(initialInput: String?)
    case remote
    case unavailable(TerminalSessionFailure)
}

struct TerminalSessionRestoration: Sendable {
    let identity: TerminalSessionIdentity
    let remoteSessionID: UUID?
}

enum TerminalSessionInput: Equatable, Sendable {
    case literal(String)
    case enter
    case bytes(Data)
}

struct TerminalSessionRuntime: Sendable {
    let shellPID: pid_t?
    let cursorVisible: Bool
}

protocol CockpitTerminalSession: Sendable {
    var identity: TerminalSessionIdentity { get }
    var destination: TerminalDestination { get }
    var hasRuntimeSnapshot: Bool { get }

    func bootstrap(workingDirectory: String?) -> TerminalSessionBootstrap
    func restore(workingDirectory: String?) async throws -> TerminalSessionRestoration
    func send(_ input: TerminalSessionInput) async -> Bool
    func runFastCommand(_ command: String) async -> Bool
    func foregroundActivity(
        unavailableActivity: TerminalProcessActivity
    ) async -> TerminalProcessActivity
    func interrupt() async -> Bool
    func currentDirectory() async -> String?
    func currentDirectorySnapshot() -> String?
    func runtimeSnapshot() -> TerminalSessionRuntime?
    func visibleContents() -> String?
    func close() async -> Bool
    func suspend() async
    func setOutputHandler(_ handler: @escaping @Sendable (String) -> Void) async
}

extension CockpitTerminalSession {
    func setOutputHandler(_ handler: @escaping @Sendable (String) -> Void) async {}

    func runFastCommand(_ command: String) async -> Bool {
        guard let command = TerminalFastCommandStore.executableCommand(from: command),
              await interrupt(),
              await send(.literal(command)) else {
            return false
        }
        return await send(.enter)
    }

    func currentDirectory() async -> String? {
        currentDirectorySnapshot()
    }
}

struct LocalTerminalSession: CockpitTerminalSession {
    let identity: TerminalSessionIdentity
    let persistentSessionName: String

    var destination: TerminalDestination { .local }
    var hasRuntimeSnapshot: Bool { PersistentTerminalSession.hasPaneRuntimeSnapshot() }

    init(identity: TerminalSessionIdentity, persistentSessionName: String) {
        self.identity = identity
        self.persistentSessionName = persistentSessionName
    }

    func bootstrap(workingDirectory: String?) -> TerminalSessionBootstrap {
        .local(initialInput: PersistentTerminalSession.bootstrapCommand(
            sessionName: persistentSessionName,
            workingDirectory: workingDirectory
        ))
    }

    func restore(workingDirectory: String?) async throws -> TerminalSessionRestoration {
        TerminalSessionRestoration(identity: identity, remoteSessionID: nil)
    }

    func send(_ input: TerminalSessionInput) async -> Bool {
        switch input {
        case .literal(let text):
            return await PersistentTerminalSession.sendLiteral(text, sessionName: persistentSessionName)
        case .enter:
            return await PersistentTerminalSession.sendKeys(["Enter"], sessionName: persistentSessionName)
        case .bytes(let data):
            guard let text = String(data: data, encoding: .utf8) else { return false }
            return await PersistentTerminalSession.sendLiteral(text, sessionName: persistentSessionName)
        }
    }

    func foregroundActivity(
        unavailableActivity: TerminalProcessActivity = .idle
    ) async -> TerminalProcessActivity {
        await PersistentTerminalSession.foregroundActivity(
            sessionName: persistentSessionName,
            unavailableActivity: unavailableActivity
        )
    }

    func interrupt() async -> Bool {
        await PersistentTerminalSession.stopForegroundCommand(sessionName: persistentSessionName)
    }

    func currentDirectorySnapshot() -> String? {
        PersistentTerminalSession.currentDirectory(sessionName: persistentSessionName)
    }

    func runtimeSnapshot() -> TerminalSessionRuntime? {
        guard let runtime = PersistentTerminalSession.paneRuntime(sessionName: persistentSessionName) else {
            return nil
        }
        return TerminalSessionRuntime(shellPID: runtime.shellPID, cursorVisible: runtime.cursorVisible)
    }

    func visibleContents() -> String? {
        PersistentTerminalSession.visibleContents(sessionName: persistentSessionName)
    }

    func close() async -> Bool {
        await PersistentTerminalSession.closeSession(sessionName: persistentSessionName)
    }

    func suspend() async {}
}

struct DroneTerminalSessionReference: Hashable, Sendable {
    let droneID: UUID
    let sessionID: UUID
    let generation: UInt64
}

protocol DroneTerminalClient: AnyObject, Sendable {
    var droneID: UUID { get }

    func createTerminal(
        workingDirectory: String?,
        generation: UInt64,
        requestID: UUID
    ) async throws -> UUID
    func attachTerminal(_ reference: DroneTerminalSessionReference) async throws
    func attachTerminal(_ reference: DroneTerminalSessionReference, after cursor: DroneTerminalCursor) async throws
    func sendInput(_ data: Data, to reference: DroneTerminalSessionReference) async throws
    func foregroundActivity(
        for reference: DroneTerminalSessionReference
    ) async throws -> TerminalProcessActivity
    func currentDirectory(for reference: DroneTerminalSessionReference) async throws -> String?
    func interrupt(_ reference: DroneTerminalSessionReference) async throws
    func detach(_ reference: DroneTerminalSessionReference) async throws
    func close(_ reference: DroneTerminalSessionReference) async throws
    func setOutputHandler(
        _ handler: @escaping @Sendable (DroneOutputBody) -> Bool,
        for reference: DroneTerminalSessionReference
    ) async
}

extension DroneTerminalClient {
    func attachTerminal(_ reference: DroneTerminalSessionReference, after cursor: DroneTerminalCursor) async throws {
        try await attachTerminal(reference)
    }

    func setOutputHandler(
        _ handler: @escaping @Sendable (DroneOutputBody) -> Bool,
        for reference: DroneTerminalSessionReference
    ) async {}
}

/// Retained across connection generations, never across destinations. Raw bytes
/// preserve UTF-8 characters split over protocol records; rendered history is bounded.
final class DroneTerminalResumeState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSessionID: UUID?
    private var storedCursor = DroneTerminalCursor.zero
    private var bytes = Data()

    init(sessionID: UUID?) { storedSessionID = sessionID }

    var sessionID: UUID? { lock.withLock { storedSessionID } }
    var cursor: DroneTerminalCursor { lock.withLock { storedCursor } }
    var contents: String? {
        lock.withLock { bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self) }
    }

    func adopt(_ id: UUID) throws {
        try lock.withLock {
            guard storedSessionID == nil || storedSessionID == id else {
                throw TerminalSessionFailure.remoteSessionConflict
            }
            storedSessionID = id
        }
    }

    func append(_ output: DroneOutputBody) -> String? {
        lock.withLock {
            guard output.sequence == storedCursor.sequence, output.offset == storedCursor.offset else { return nil }
            bytes.append(output.data)
            storedCursor = DroneTerminalCursor(output: output)
            if bytes.count > 256 * 1_024 { bytes.removeFirst(bytes.count - 256 * 1_024) }
            // Avoid beginning the retained viewport in the middle of a UTF-8 scalar.
            while let first = bytes.first, first & 0xC0 == 0x80 { bytes.removeFirst() }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}

final class DroneTerminalSession: CockpitTerminalSession, @unchecked Sendable {
    let identity: TerminalSessionIdentity
    private let client: any DroneTerminalClient
    private let lock = NSLock()
    private var retired = false
    let resumeState: DroneTerminalResumeState
    private var outputHandler: (@Sendable (String) -> Void)?
    private lazy var directoryCache: TerminalRuntimeCache<String> = {
        TerminalRuntimeCache<String> { [weak self] _ in
            guard let self, let droneID = identity.ownership.droneID else { return nil }
            do {
                return try await self.currentDirectory(droneID: droneID)
            } catch {
                return nil
            }
        }
    }()

    init(
        identity: TerminalSessionIdentity,
        remoteSessionID: UUID?,
        client: any DroneTerminalClient,
        resumeState: DroneTerminalResumeState? = nil
    ) {
        self.identity = identity
        self.resumeState = resumeState ?? DroneTerminalResumeState(sessionID: remoteSessionID)
        self.client = client
    }

    func uses(_ candidate: (any DroneTerminalClient)?) -> Bool {
        candidate.map { ObjectIdentifier($0) == ObjectIdentifier(client) } ?? false
    }

    func retire() {
        lock.withLock { retired = true }
    }

    var destination: TerminalDestination {
        TerminalDestination(
            kind: identity.ownership.kind,
            droneID: identity.ownership.droneID,
            remoteSessionID: remoteSessionID
        )
    }

    var hasRuntimeSnapshot: Bool { true }

    private var remoteSessionID: UUID? {
        resumeState.sessionID
    }

    func bootstrap(workingDirectory: String?) -> TerminalSessionBootstrap {
        .remote
    }

    func restore(workingDirectory: String?) async throws -> TerminalSessionRestoration {
        guard !lock.withLock({ retired }) else { throw TerminalSessionFailure.staleGeneration }
        guard client.droneID == identity.ownership.droneID else {
            throw TerminalSessionFailure.destinationChanged
        }
        let sessionID: UUID
        if let remoteSessionID {
            sessionID = remoteSessionID
        } else {
            sessionID = try await client.createTerminal(
                workingDirectory: workingDirectory,
                generation: identity.generation,
                requestID: identity.paneID
            )
            try resumeState.adopt(sessionID)
        }
        let reference = try reference()
        await subscribe(reference)
        try await client.attachTerminal(reference, after: resumeState.cursor)
        return TerminalSessionRestoration(identity: identity, remoteSessionID: sessionID)
    }

    func send(_ input: TerminalSessionInput) async -> Bool {
        let data: Data
        switch input {
        case .literal(let text):
            data = Data(text.utf8)
        case .enter:
            data = Data([13])
        case .bytes(let bytes):
            data = bytes
        }
        do {
            try await client.sendInput(data, to: reference())
            return true
        } catch {
            return false
        }
    }

    func foregroundActivity(
        unavailableActivity: TerminalProcessActivity = .idle
    ) async -> TerminalProcessActivity {
        do {
            return try await client.foregroundActivity(for: reference())
        } catch {
            return unavailableActivity
        }
    }

    func interrupt() async -> Bool {
        do {
            try await client.interrupt(reference())
            return true
        } catch {
            return false
        }
    }

    func currentDirectory() async -> String? {
        guard let droneID = identity.ownership.droneID else { return nil }
        return try? await currentDirectory(droneID: droneID)
    }

    func currentDirectorySnapshot() -> String? {
        directoryCache.snapshot(for: identity.runtimeCacheKey)
    }

    func runtimeSnapshot() -> TerminalSessionRuntime? {
        TerminalSessionRuntime(shellPID: nil, cursorVisible: true)
    }

    func visibleContents() -> String? {
        resumeState.contents
    }

    func setOutputHandler(_ handler: @escaping @Sendable (String) -> Void) async {
        lock.withLock { outputHandler = handler }
        guard let reference = try? reference() else { return }
        await subscribe(reference)
    }

    private func subscribe(_ reference: DroneTerminalSessionReference) async {
        await client.setOutputHandler({ [weak self] output in
            self?.appendOutput(output) ?? false
        }, for: reference)
    }

    private func appendOutput(_ output: DroneOutputBody) -> Bool {
        let delivery = lock.withLock { () -> (String, (@Sendable (String) -> Void)?)? in
            guard !retired, let contents = resumeState.append(output) else { return nil }
            return (contents, outputHandler)
        }
        guard let (contents, handler) = delivery else { return false }
        handler?(contents)
        return true
    }

    func close() async -> Bool {
        do {
            try await client.close(reference())
            directoryCache.invalidate(identity.runtimeCacheKey)
            return true
        } catch {
            return false
        }
    }

    func suspend() async {
        guard let reference = try? reference() else { return }
        try? await client.detach(reference)
    }

    private func currentDirectory(droneID: UUID) async throws -> String? {
        guard client.droneID == droneID else { throw TerminalSessionFailure.destinationChanged }
        return try await client.currentDirectory(for: reference())
    }

    private func reference() throws -> DroneTerminalSessionReference {
        guard !lock.withLock({ retired }) else { throw TerminalSessionFailure.staleGeneration }
        guard let droneID = identity.ownership.droneID,
              client.droneID == droneID else {
            throw TerminalSessionFailure.destinationChanged
        }
        guard let sessionID = remoteSessionID else {
            throw TerminalSessionFailure.remoteSessionMissing
        }
        return DroneTerminalSessionReference(
            droneID: droneID,
            sessionID: sessionID,
            generation: identity.generation
        )
    }

}

struct UnavailableTerminalSession: CockpitTerminalSession {
    let identity: TerminalSessionIdentity
    let destination: TerminalDestination
    let failure: TerminalSessionFailure

    var hasRuntimeSnapshot: Bool { true }

    func bootstrap(workingDirectory: String?) -> TerminalSessionBootstrap {
        .unavailable(failure)
    }

    func restore(workingDirectory: String?) async throws -> TerminalSessionRestoration {
        throw failure
    }

    func send(_ input: TerminalSessionInput) async -> Bool { false }

    func foregroundActivity(
        unavailableActivity: TerminalProcessActivity = .idle
    ) async -> TerminalProcessActivity {
        unavailableActivity
    }

    func interrupt() async -> Bool { false }
    func currentDirectorySnapshot() -> String? { nil }
    func runtimeSnapshot() -> TerminalSessionRuntime? { nil }
    func visibleContents() -> String? { nil }
    func close() async -> Bool { false }
    func suspend() async {}
}

final class TerminalSessionProvider: @unchecked Sendable {
    typealias DroneClientResolver = @Sendable (UUID) -> (any DroneTerminalClient)?

    static let shared = TerminalSessionProvider()

    private struct Record {
        let destination: TerminalDestination
        let session: any CockpitTerminalSession
    }

    private let lock = NSLock()
    private var records: [UUID: Record] = [:]
    private var generations: [UUID: UInt64] = [:]
    private var resumeStates: [UUID: DroneTerminalResumeState] = [:]
    private var droneClientResolver: DroneClientResolver

    init(droneClientResolver: @escaping DroneClientResolver = { _ in nil }) {
        self.droneClientResolver = droneClientResolver
    }

    func configure(droneClientResolver: @escaping DroneClientResolver) {
        lock.withLock { self.droneClientResolver = droneClientResolver }
    }

    func session(for pane: Pane) -> any CockpitTerminalSession {
        let destination = pane.terminalDestination
        if let record = lock.withLock({ records[pane.id] }) {
            guard record.destination.ownership == destination.ownership,
                  destination.isValid else {
                return UnavailableTerminalSession(
                    identity: TerminalSessionIdentity(
                        paneID: pane.id,
                        ownership: destination.ownership,
                        generation: record.session.identity.generation
                    ),
                    destination: destination,
                    failure: .destinationChanged
                )
            }
            if let persistedID = destination.remoteSessionID,
               let recordID = record.destination.remoteSessionID,
               persistedID != recordID {
                return UnavailableTerminalSession(
                    identity: record.session.identity,
                    destination: destination,
                    failure: .remoteSessionConflict
                )
            }
            if destination.kind == .drone, let droneID = destination.droneID {
                let resolver = lock.withLock { droneClientResolver }
                let client = resolver(droneID)
                let remote = record.session as? DroneTerminalSession
                if (remote != nil && !remote!.uses(client)) || (remote == nil && client != nil) {
                    return reconnect(pane: pane)
                }
            }
            return record.session
        }
        return makeSession(for: pane, destination: destination, generation: generation(for: pane.id))
    }

    func reconnect(pane: Pane) -> any CockpitTerminalSession {
        let destination = pane.terminalDestination
        _ = lock.withLock {
            if let record = records[pane.id], record.destination.ownership != destination.ownership {
                return record.session.identity.generation
            }
            if let remote = records[pane.id]?.session as? DroneTerminalSession {
                resumeStates[pane.id] = remote.resumeState
                remote.retire()
            }
            let next = (generations[pane.id] ?? 1) + 1
            generations[pane.id] = next
            records.removeValue(forKey: pane.id)
            return next
        }
        return session(for: pane)
    }

    func isCurrent(_ identity: TerminalSessionIdentity, for pane: Pane) -> Bool {
        lock.withLock {
            records[pane.id]?.session.identity == identity
                && pane.terminalDestination.ownership == identity.ownership
        }
    }

    func invalidate(pane: Pane, session: any CockpitTerminalSession) {
        lock.withLock {
            guard records[pane.id]?.session.identity == session.identity else { return }
            resumeStates.removeValue(forKey: pane.id)
            records.removeValue(forKey: pane.id)
        }
    }

    @MainActor
    func restore(pane: Pane) async throws -> TerminalSessionRestoration {
        let session = session(for: pane)
        do {
            let restoration = try await session.restore(workingDirectory: pane.currentDirectory)
            try adopt(restoration.remoteSessionID, restoration: restoration, pane: pane, session: session)
            return restoration
        } catch {
            if let remoteSessionID = (session as? DroneTerminalSession)?.destination.remoteSessionID {
                try? adopt(remoteSessionID, restoration: TerminalSessionRestoration(
                    identity: session.identity,
                    remoteSessionID: remoteSessionID
                ), pane: pane, session: session)
            }
            throw error
        }
    }

    @MainActor
    private func adopt(
        _ remoteSessionID: UUID?,
        restoration: TerminalSessionRestoration,
        pane: Pane,
        session: any CockpitTerminalSession
    ) throws {
        guard isCurrent(restoration.identity, for: pane) else {
            throw TerminalSessionFailure.staleGeneration
        }
        guard let remoteSessionID else { return }
        try pane.adoptRemoteSessionID(remoteSessionID, identity: restoration.identity)
        lock.withLock {
            records[pane.id] = Record(destination: pane.terminalDestination, session: session)
        }
    }

    private func generation(for paneID: UUID) -> UInt64 {
        lock.withLock {
            let generation = generations[paneID] ?? 1
            generations[paneID] = generation
            return generation
        }
    }

    private func makeSession(
        for pane: Pane,
        destination: TerminalDestination,
        generation: UInt64
    ) -> any CockpitTerminalSession {
        let identity = TerminalSessionIdentity(
            paneID: pane.id,
            ownership: destination.ownership,
            generation: generation
        )
        let session: any CockpitTerminalSession
        if !destination.isValid {
            session = UnavailableTerminalSession(
                identity: identity,
                destination: destination,
                failure: .invalidDestination
            )
        } else {
            switch destination.kind {
            case .local:
                session = LocalTerminalSession(
                    identity: identity,
                    persistentSessionName: pane.persistentSessionName
                )
            case .drone:
                guard let droneID = destination.droneID else {
                    return UnavailableTerminalSession(
                        identity: identity,
                        destination: destination,
                        failure: .invalidDestination
                    )
                }
                let resolver = lock.withLock { droneClientResolver }
                if let client = resolver(droneID), client.droneID == droneID {
                    session = DroneTerminalSession(
                        identity: identity,
                        remoteSessionID: destination.remoteSessionID,
                        client: client,
                        resumeState: lock.withLock { resumeStates[pane.id] }
                    )
                } else {
                    session = UnavailableTerminalSession(
                        identity: identity,
                        destination: destination,
                        failure: .droneUnavailable(droneID)
                    )
                }
            case .invalid:
                session = UnavailableTerminalSession(
                    identity: identity,
                    destination: destination,
                    failure: .invalidDestination
                )
            }
        }
        lock.withLock { records[pane.id] = Record(destination: destination, session: session) }
        return session
    }
}

extension Pane {
    var terminalDestination: TerminalDestination {
        TerminalDestination.restored(
            kindRaw: terminalDestinationRaw,
            droneIDRaw: terminalDroneIDRaw,
            remoteSessionIDRaw: terminalRemoteSessionIDRaw,
            droneNameRaw: terminalDroneNameRaw
        )
    }

    var terminalSession: any CockpitTerminalSession {
        TerminalSessionProvider.shared.session(for: self)
    }

    func visibleTerminalContents() -> String? {
        terminalSession.visibleContents()
    }

    func liveShellCurrentDirectory() -> String? {
        guard kind == .terminal else { return nil }
        return terminalSession.currentDirectorySnapshot()
    }

    @MainActor
    func restoreTerminalSession() async throws -> TerminalSessionRestoration {
        try await TerminalSessionProvider.shared.restore(pane: self)
    }
}
