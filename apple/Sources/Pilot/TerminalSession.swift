import Foundation
import Observation

extension Notification.Name {
    static let droneTerminalClientDidChange = Notification.Name("droneTerminalClientDidChange")
}

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
    func sendCompanion(_ input: TerminalSessionInput) async -> Bool
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
    func resize(columns: UInt16, rows: UInt16) async -> Bool
    func setOutputHandler(_ handler: @escaping @Sendable (String) -> Void) async
}

extension CockpitTerminalSession {
    func resize(columns: UInt16, rows: UInt16) async -> Bool { false }
    func setOutputHandler(_ handler: @escaping @Sendable (String) -> Void) async {}

    func sendCompanion(_ input: TerminalSessionInput) async -> Bool {
        await send(input)
    }

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
    typealias CompanionInput = @MainActor (TerminalSessionInput) async -> Bool

    let identity: TerminalSessionIdentity
    let persistentSessionName: String
    private let companionInput: CompanionInput?

    var destination: TerminalDestination { .local }
    var hasRuntimeSnapshot: Bool { PersistentTerminalSession.hasPaneRuntimeSnapshot() }

    init(
        identity: TerminalSessionIdentity,
        persistentSessionName: String,
        companionInput: CompanionInput? = nil
    ) {
        self.identity = identity
        self.persistentSessionName = persistentSessionName
        self.companionInput = companionInput
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

    func sendCompanion(_ input: TerminalSessionInput) async -> Bool {
        if let companionInput { return await companionInput(input) }
        if await sendGhosttyCompanion(input) { return true }
        return await send(input)
    }

    @MainActor
    private func sendGhosttyCompanion(_ input: TerminalSessionInput) -> Bool {
        guard let terminal = GhosttyMetalView.view(for: identity.paneID), terminal.surface != nil else {
            return false
        }
        switch input {
        case .literal(let text):
            terminal.pasteText(text)
        case .enter:
            terminal.sendEnter()
        case .bytes:
            return false
        }
        return true
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
    func resynchronize(_ reference: DroneTerminalSessionReference) async throws
    func resize(columns: UInt16, rows: UInt16, for reference: DroneTerminalSessionReference) async throws
    func setOutputHandler(
        _ handler: @escaping @Sendable (DroneOutputBody) -> Bool,
        for reference: DroneTerminalSessionReference
    ) async
}

extension DroneTerminalClient {
    func attachTerminal(_ reference: DroneTerminalSessionReference, after cursor: DroneTerminalCursor) async throws {
        try await attachTerminal(reference)
    }

    func resynchronize(_ reference: DroneTerminalSessionReference) async throws {
        throw DroneRemoteTerminalError.remote(code: "remoteRejected")
    }

    func resize(columns: UInt16, rows: UInt16, for reference: DroneTerminalSessionReference) async throws {
        throw DroneRemoteTerminalError.remote(code: "remoteRejected")
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
    private var awaitingSnapshot = false
    private var displayIdentity: TerminalSessionIdentity?
    private var outputHandler: (@Sendable (String) -> Void)?

    init(sessionID: UUID?) { storedSessionID = sessionID }

    var sessionID: UUID? { lock.withLock { storedSessionID } }
    var cursor: DroneTerminalCursor { lock.withLock { storedCursor } }
    var contents: String? {
        lock.withLock { bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self) }
    }

    func activate(_ identity: TerminalSessionIdentity) {
        lock.withLock { displayIdentity = identity }
    }

    func deactivate(_ identity: TerminalSessionIdentity) {
        lock.withLock {
            if displayIdentity == identity { displayIdentity = nil }
        }
    }

    func setOutputHandler(_ handler: @escaping @Sendable (String) -> Void, identity: TerminalSessionIdentity) {
        lock.withLock {
            guard displayIdentity == identity else { return }
            outputHandler = handler
        }
    }

    func publish(identity: TerminalSessionIdentity) {
        Task { @MainActor [weak self] in
            let delivery = self?.lock.withLock { () -> (String, (@Sendable (String) -> Void))? in
                guard self?.displayIdentity == identity, let handler = self?.outputHandler,
                      let bytes = self?.bytes else { return nil }
                return (String(decoding: bytes, as: UTF8.self), handler)
            }
            if let (contents, handler) = delivery { handler(contents) }
        }
    }

    func adopt(_ id: UUID) throws {
        try lock.withLock {
            guard storedSessionID == nil || storedSessionID == id else {
                throw TerminalSessionFailure.remoteSessionConflict
            }
            storedSessionID = id
        }
    }

    func resetForResynchronization() {
        lock.withLock {
            storedCursor = .zero
            bytes.removeAll(keepingCapacity: false)
            awaitingSnapshot = true
        }
    }

    func append(_ output: DroneOutputBody) -> String? {
        lock.withLock {
            if awaitingSnapshot {
                bytes = output.data
                awaitingSnapshot = false
            } else {
                guard output.sequence == storedCursor.sequence, output.offset == storedCursor.offset else { return nil }
                bytes.append(output.data)
            }
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
    private var closeTask: Task<Bool, Never>?
    let resumeState: DroneTerminalResumeState
    private var restoration: (id: UUID, task: Task<TerminalSessionRestoration, any Error>)?
    private let initialWorkingDirectory: String?
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
        resumeState: DroneTerminalResumeState? = nil,
        workingDirectory: String? = nil
    ) {
        self.identity = identity
        self.resumeState = resumeState ?? DroneTerminalResumeState(sessionID: remoteSessionID)
        self.client = client
        initialWorkingDirectory = workingDirectory
        self.resumeState.activate(identity)
    }

    func uses(_ candidate: (any DroneTerminalClient)?) -> Bool {
        candidate.map { ObjectIdentifier($0) == ObjectIdentifier(client) } ?? false
    }

    func retire() {
        lock.withLock {
            retired = true
            restoration?.task.cancel()
        }
        resumeState.deactivate(identity)
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

    func startRestoring() {
        Task { [weak self] in _ = try? await self?.restore(workingDirectory: nil) }
    }

    func restore(workingDirectory: String?) async throws -> TerminalSessionRestoration {
        let pending = try lock.withLock { () throws -> (id: UUID, task: Task<TerminalSessionRestoration, any Error>) in
            guard !retired else { throw TerminalSessionFailure.staleGeneration }
            if let restoration { return restoration }
            let pending = (id: UUID(), task: Task { [self] in
                try await performRestore(workingDirectory: workingDirectory ?? initialWorkingDirectory)
            })
            restoration = pending
            return pending
        }
        do {
            return try await pending.task.value
        } catch {
            lock.withLock {
                if restoration?.id == pending.id { restoration = nil }
            }
            throw error
        }
    }

    private func performRestore(workingDirectory: String?) async throws -> TerminalSessionRestoration {
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
        do {
            try await client.attachTerminal(reference, after: resumeState.cursor)
        } catch {
            guard Self.isOutputGap(error) else { throw error }
            _ = try self.reference()
            resumeState.resetForResynchronization()
            resumeState.publish(identity: identity)
            try await client.resynchronize(reference)
        }
        _ = try self.reference()
        return TerminalSessionRestoration(identity: identity, remoteSessionID: sessionID)
    }

    private static func isOutputGap(_ error: any Error) -> Bool {
        if case DroneRemoteTerminalError.remote(let code) = error { return code == "outputGap" }
        return (error as? DroneTerminalError) == .outputGap
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
            _ = try await restore(workingDirectory: nil)
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
        guard !lock.withLock({ retired }) else { return }
        resumeState.setOutputHandler(handler, identity: identity)
        resumeState.publish(identity: identity)
    }

    private func subscribe(_ reference: DroneTerminalSessionReference) async {
        await client.setOutputHandler({ [weak self] output in
            self?.appendOutput(output) ?? false
        }, for: reference)
    }

    private func appendOutput(_ output: DroneOutputBody) -> Bool {
        let accepted = lock.withLock {
            !retired && resumeState.append(output) != nil
        }
        if accepted { resumeState.publish(identity: identity) }
        return accepted
    }

    func resize(columns: UInt16, rows: UInt16) async -> Bool {
        do {
            _ = try await restore(workingDirectory: nil)
            try await client.resize(columns: columns, rows: rows, for: reference())
            return true
        } catch {
            return false
        }
    }

    func close() async -> Bool {
        let task = lock.withLock { () -> Task<Bool, Never> in
            if let closeTask { return closeTask }
            retired = true
            let pending = restoration?.task
            pending?.cancel()
            let client = client
            let resumeState = resumeState
            let identity = identity
            let cache = directoryCache
            let task = Task<Bool, Never> {
                if let pending { _ = try? await pending.value }
                cache.invalidate(identity.runtimeCacheKey)
                guard let sessionID = resumeState.sessionID else { return true }
                guard let droneID = identity.ownership.droneID, client.droneID == droneID else { return false }
                let reference = DroneTerminalSessionReference(
                    droneID: droneID,
                    sessionID: sessionID,
                    generation: identity.generation
                )
                await client.setOutputHandler({ _ in false }, for: reference)
                do {
                    try await client.close(reference)
                    return true
                } catch {
                    return false
                }
            }
            closeTask = task
            return task
        }
        resumeState.deactivate(identity)
        return await task.value
    }

    func suspend() async {
        guard let reference = try? reference() else { return }
        lock.withLock { restoration = nil }
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
        let workingDirectory: String?
    }

    private var connectionObserver: (any NSObjectProtocol)?
    private let lock = NSLock()
    private var records: [UUID: Record] = [:]
    private var generations: [UUID: UInt64] = [:]
    private var resumeStates: [UUID: DroneTerminalResumeState] = [:]
    private var droneClientResolver: DroneClientResolver

    init(droneClientResolver: @escaping DroneClientResolver = { _ in nil }) {
        self.droneClientResolver = droneClientResolver
        connectionObserver = NotificationCenter.default.addObserver(
            forName: .droneTerminalClientDidChange, object: nil, queue: nil
        ) { [weak self] notification in
            guard let id = notification.object as? UUID else { return }
            // DroneStore publishes client changes synchronously on the main actor.
            MainActor.assumeIsolated { self?.clientDidChange(droneID: id) }
        }
    }

    deinit {
        if let connectionObserver { NotificationCenter.default.removeObserver(connectionObserver) }
    }

    @MainActor
    private func clientDidChange(droneID: UUID) {
        let affected = lock.withLock {
            records.filter {
                $0.value.destination.kind == .drone && $0.value.destination.isValid
                    && $0.value.destination.droneID == droneID
            }
        }
        for (paneID, record) in affected {
            replaceRemote(paneID: paneID, record: record)
        }
    }

    @MainActor
    private func replaceRemote(paneID: UUID, record: Record) {
        let resolver = lock.withLock { droneClientResolver }
        let client = record.destination.droneID.flatMap(resolver)
        let generation = lock.withLock { () -> UInt64 in
            if let remote = record.session as? DroneTerminalSession {
                resumeStates[paneID] = remote.resumeState
                remote.retire()
            }
            let next = (generations[paneID] ?? 1) + 1
            generations[paneID] = next
            return next
        }
        let identity = TerminalSessionIdentity(paneID: paneID, ownership: record.destination.ownership, generation: generation)
        let replacement: any CockpitTerminalSession
        if let client, client.droneID == record.destination.droneID {
            replacement = DroneTerminalSession(identity: identity, remoteSessionID: record.destination.remoteSessionID,
                                               client: client, resumeState: lock.withLock { resumeStates[paneID] },
                                               workingDirectory: record.workingDirectory)
        } else {
            replacement = UnavailableTerminalSession(identity: identity, destination: record.destination,
                                                     failure: .droneUnavailable(record.destination.droneID!))
        }
        lock.withLock {
            records[paneID] = Record(destination: record.destination, session: replacement,
                                     workingDirectory: record.workingDirectory)
        }
        (replacement as? DroneTerminalSession)?.startRestoring()
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

    func existingSession(for pane: Pane) -> (any CockpitTerminalSession)? {
        let destination = pane.terminalDestination
        return lock.withLock {
            guard destination.isValid, let record = records[pane.id],
                  record.destination.ownership == destination.ownership,
                  record.destination.remoteSessionID == destination.remoteSessionID
            else { return nil }
            return record.session
        }
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

    /// Keyed by identifier so a deletion can invalidate the session after its
    /// save has already deleted the pane model.
    func invalidate(paneID: UUID, session: any CockpitTerminalSession) {
        lock.withLock {
            guard records[paneID]?.session.identity == session.identity else { return }
            (session as? DroneTerminalSession)?.retire()
            resumeStates.removeValue(forKey: paneID)
            records.removeValue(forKey: paneID)
            generations[paneID] = session.identity.generation + 1
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
            records[pane.id] = Record(destination: pane.terminalDestination, session: session, workingDirectory: pane.currentDirectory)
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
                        resumeState: lock.withLock { resumeStates[pane.id] },
                        workingDirectory: pane.currentDirectory
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
        lock.withLock {
            records[pane.id] = Record(destination: destination, session: session, workingDirectory: pane.currentDirectory)
        }
        if lock.withLock({ resumeStates[pane.id] != nil }) {
            (session as? DroneTerminalSession)?.startRestoring()
        }
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

/// Presentation lifecycle shared by the transcript frontends. Client changes must
/// retry the initial binding too, not only retain an already-installed callback.
@Observable
@MainActor
final class DroneTerminalPresentation {
    private(set) var contents = ""
    private(set) var status = "Connecting…"
    private(set) var isConnected = false
    private(set) var isActive = false
    @ObservationIgnored var onUpdate: (() -> Void)?
    @ObservationIgnored private let pane: Pane
    @ObservationIgnored private let provider: TerminalSessionProvider
    @ObservationIgnored private var observer: (any NSObjectProtocol)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0

    init(pane: Pane, provider: TerminalSessionProvider = .shared) {
        self.pane = pane
        self.provider = provider
        observer = NotificationCenter.default.addObserver(
            forName: .droneTerminalClientDidChange, object: nil, queue: nil
        ) { [weak self] notification in
            guard let id = notification.object as? UUID else { return }
            MainActor.assumeIsolated {
                guard let self, self.isActive, self.pane.terminalDestination.droneID == id else { return }
                self.rebind()
            }
        }
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        rebind()
    }

    func retry() {
        if isActive { rebind() } else { start() }
    }

    func stop() {
        isActive = false
        generation &+= 1
        task?.cancel()
        task = nil
        isConnected = false
        onUpdate?()
    }

    private func rebind() {
        generation &+= 1
        let candidate = generation
        task?.cancel()
        isConnected = false
        status = "Connecting…"
        onUpdate?()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let restored = try await provider.restore(pane: pane)
                guard isCurrent(candidate), provider.isCurrent(restored.identity, for: pane) else { return }
                let session = provider.session(for: pane)
                contents = session.visibleContents() ?? ""
                await session.setOutputHandler { [weak self] updated in
                    Task { @MainActor in
                        guard let self, self.isActive, self.generation == candidate,
                              self.provider.isCurrent(restored.identity, for: self.pane) else { return }
                        self.contents = updated
                        self.onUpdate?()
                    }
                }
                guard isCurrent(candidate), provider.isCurrent(restored.identity, for: pane) else { return }
                isConnected = true
                status = "Connected"
            } catch {
                guard isCurrent(candidate) else { return }
                status = "Unavailable: \(String(describing: error))"
            }
            if isCurrent(candidate) {
                task = nil
                onUpdate?()
            }
        }
    }

    func resize(columns: UInt16, rows: UInt16) async -> Bool {
        guard isActive, isConnected else { return false }
        let candidate = generation
        let session = provider.session(for: pane)
        let resized = await session.resize(columns: columns, rows: rows)
        return resized && isCurrent(candidate) && provider.isCurrent(session.identity, for: pane)
    }

    func send(_ command: String) async -> Bool {
        guard isActive, isConnected, !command.isEmpty else { return false }
        let candidate = generation
        let session = provider.session(for: pane)
        let sent = await session.send(.literal(command))
        let entered = sent ? await session.send(.enter) : false
        guard isCurrent(candidate), provider.isCurrent(session.identity, for: pane) else { return false }
        if !entered {
            status = "Input failed"
            onUpdate?()
        }
        return entered
    }

    private func isCurrent(_ candidate: UInt64) -> Bool {
        isActive && generation == candidate && !Task.isCancelled
    }

    isolated deinit {
        task?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
