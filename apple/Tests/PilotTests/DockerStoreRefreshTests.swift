import Foundation
import Testing
@testable import Pilot

/// Store-level checks for how container-list refreshes are scheduled and which
/// replies are allowed to reach the UI. Every engine here is a scripted double,
/// so overlapping, late, and failed replies arrive exactly when a test says.
@Suite("Docker store refresh coordination", .serialized)
@MainActor
struct DockerStoreRefreshTests {
    // MARK: - Coalescing

    @Test("Manual, event, and action triggers during a list request add one trailing refresh")
    func overlappingTriggersCoalesce() async throws {
        let harness = try Harness()
        let engine = harness.nextEngine(name: "engine", holdsLists: true)
        let store = harness.store
        store.start()
        #expect(await eventually { engine.listCalls == 1 })
        #expect(store.isRefreshing)

        for _ in 0..<5 { store.refreshNow() }
        for _ in 0..<10 { engine.emitContainerEvent() }
        store.perform(.restart, on: try Fixture.container(id: "c1", name: "api"))
        #expect(await eventually { engine.performCalls == 1 && store.busyContainerIDs.isEmpty })
        // Let the event debounce elapse so its trigger lands while the first
        // reply is still outstanding.
        try await Task.sleep(for: .milliseconds(400))
        #expect(engine.listCalls == 1)
        #expect(engine.maxConcurrentLists == 1)

        engine.releaseLists(with: [try Fixture.container(id: "c1", name: "first")])
        #expect(await eventually { engine.listCalls == 2 })
        // The trailing request keeps the indicator up instead of letting it blink.
        #expect(store.isRefreshing)
        #expect(store.containers.map(\.name) == ["first"])

        engine.releaseLists(with: [try Fixture.container(id: "c1", name: "second")])
        #expect(await eventually { !store.isRefreshing })
        #expect(store.containers.map(\.name) == ["second"])
        try await Task.sleep(for: .milliseconds(400))
        #expect(engine.listCalls == 2)
        #expect(engine.maxConcurrentLists == 1)
        store.stop()
    }

    @Test("A poll tick during a list request is satisfied by that request")
    func pollTickDoesNotQueueTrailingRefresh() async throws {
        let harness = try Harness(pollInterval: .milliseconds(40))
        let engine = harness.nextEngine(name: "engine", holdsLists: true)
        let store = harness.store
        store.start()
        #expect(await eventually { engine.listCalls == 1 })
        // Several poll intervals pass while the first reply is held.
        try await Task.sleep(for: .milliseconds(250))
        #expect(engine.listCalls == 1)

        engine.releaseLists(with: [])
        // `isRefreshing` is set synchronously with each request, so the moment
        // it reads false nothing was queued behind the released reply.
        #expect(await eventually(pollEvery: .milliseconds(1)) { !store.isRefreshing })
        #expect(engine.listCalls == 1)
        store.stop()
        engine.releaseLists(with: [])
    }

    @Test("A burst of container events with no request in flight costs one list call")
    func eventBurstIsDebounced() async throws {
        let harness = try Harness()
        let engine = harness.nextEngine(name: "engine")
        let store = harness.store
        store.start()
        #expect(await eventually { engine.listCalls == 1 && !store.isRefreshing })

        for _ in 0..<50 { engine.emitContainerEvent() }
        #expect(await eventually { engine.listCalls == 2 })
        try await Task.sleep(for: .milliseconds(400))
        #expect(engine.listCalls == 2)
        #expect(engine.maxConcurrentLists == 1)
        store.stop()
    }

    // MARK: - Connection identity

    @Test("Replies and errors from a replaced client never reach the UI")
    func reconnectInvalidatesOldReplies() async throws {
        let harness = try Harness()
        let old = harness.nextEngine(name: "old", holdsLists: true)
        let current = harness.nextEngine(name: "current", holdsLists: true)
        let store = harness.store
        store.start()
        #expect(await eventually { old.listCalls == 1 })

        store.reconnect()
        #expect(await eventually { current.listCalls == 1 })
        #expect(store.engine == .connected(version: Fixture.version("current"), socketPath: Harness.socketPath))

        old.releaseLists(throwing: DockerTransportError.timedOut)
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.engine.isConnected)
        #expect(store.isRefreshing)

        current.releaseLists(with: [try Fixture.container(id: "n1", name: "fresh")])
        #expect(await eventually { !store.isRefreshing })
        #expect(store.containers.map(\.name) == ["fresh"])
        store.stop()
    }

    @Test("A late handshake from a replaced client does not overwrite the engine")
    func reconnectInvalidatesOldHandshake() async throws {
        let harness = try Harness()
        let old = harness.nextEngine(name: "old", holdsVersion: true)
        let current = harness.nextEngine(name: "current")
        let store = harness.store
        store.start()
        #expect(await eventually { old.versionCalls == 1 })

        store.reconnect()
        #expect(await eventually { current.listCalls == 1 && !store.isRefreshing })
        old.releaseVersion()
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.engine == .connected(version: Fixture.version("current"), socketPath: Harness.socketPath))
        #expect(old.listCalls == 0)
        store.stop()
    }

    @Test("Stopping drops in-flight replies and starts nothing new")
    func stopInvalidatesReplies() async throws {
        let harness = try Harness(pollInterval: .milliseconds(40))
        let engine = harness.nextEngine(name: "engine", holdsLists: true)
        let store = harness.store
        store.start()
        #expect(await eventually { engine.listCalls == 1 })

        store.stop()
        #expect(!store.isRefreshing)
        engine.releaseLists(with: [try Fixture.container(id: "s1", name: "stale")])
        engine.emitContainerEvent()
        store.refreshNow()
        try await Task.sleep(for: .milliseconds(400))
        #expect(store.containers.isEmpty)
        #expect(!store.isRefreshing)
        #expect(engine.listCalls == 1)
        #expect(harness.engineCount == 1)
    }

    @Test("A list error from a stopped client does not mark the engine unavailable")
    func stopIgnoresLateErrors() async throws {
        let harness = try Harness()
        let engine = harness.nextEngine(name: "engine", holdsLists: true)
        let store = harness.store
        store.start()
        #expect(await eventually { engine.listCalls == 1 })
        store.stop()
        engine.releaseLists(throwing: DockerTransportError.timedOut)
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.engine.isConnected)
    }

    @Test("A list error from the current client is reported")
    func currentErrorsAreReported() async throws {
        let harness = try Harness()
        let engine = harness.nextEngine(name: "engine", holdsLists: true)
        let store = harness.store
        store.start()
        #expect(await eventually { engine.listCalls == 1 })
        engine.releaseLists(throwing: DockerTransportError.timedOut)
        #expect(await eventually { !store.engine.isConnected })
        #expect(!store.isRefreshing)
        store.stop()
    }

    // MARK: - Actions

    @Test("A completed action refreshes the list and blocks duplicates while in flight")
    func actionRefreshesAndBlocksDuplicates() async throws {
        let harness = try Harness()
        let engine = harness.nextEngine(name: "engine", holdsActions: true)
        let store = harness.store
        store.start()
        #expect(await eventually { engine.listCalls == 1 && !store.isRefreshing })

        let container = try Fixture.container(id: "c1", name: "api")
        store.perform(.stop, on: container)
        store.perform(.stop, on: container)
        store.perform(.remove, on: container)
        #expect(await eventually { engine.performCalls == 1 })
        #expect(store.busyContainerIDs == ["c1"])

        engine.releaseActions()
        #expect(await eventually { store.busyContainerIDs.isEmpty && engine.listCalls == 2 })
        #expect(await eventually { !store.isRefreshing })
        #expect(store.actionError == nil)
        store.stop()
    }

    @Test("An action failure after a reconnect is not shown against the new connection")
    func staleActionFailureIsDropped() async throws {
        let harness = try Harness()
        let old = harness.nextEngine(name: "old", holdsActions: true)
        let current = harness.nextEngine(name: "current")
        let store = harness.store
        store.start()
        #expect(await eventually { old.listCalls == 1 && !store.isRefreshing })

        let container = try Fixture.container(id: "c1", name: "api")
        store.perform(.restart, on: container)
        #expect(await eventually { old.performCalls == 1 })

        store.reconnect()
        #expect(await eventually { current.listCalls == 1 && !store.isRefreshing })
        // The daemon may still be acting on the container, so the row stays
        // guarded until that request ends.
        store.perform(.restart, on: container)
        #expect(current.performCalls == 0)

        old.releaseActions(throwing: DockerTransportError.timedOut)
        #expect(await eventually { store.busyContainerIDs.isEmpty })
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.actionError == nil)
        store.stop()
    }

    @Test("An old client's successful action refreshes once through the current client")
    func staleActionSuccessRefreshesCurrentClient() async throws {
        let harness = try Harness()
        let old = harness.nextEngine(name: "old", holdsActions: true)
        let current = harness.nextEngine(name: "current")
        let store = harness.store
        store.start()
        #expect(await eventually { old.listCalls == 1 && !store.isRefreshing })

        store.perform(.stop, on: try Fixture.container(id: "c1", name: "api"))
        #expect(await eventually { old.performCalls == 1 })

        store.reconnect()
        #expect(await eventually { current.listCalls == 1 && !store.isRefreshing })

        old.releaseActions()
        #expect(await eventually { store.busyContainerIDs.isEmpty })
        // The daemon changed state, so the list is re-read, but only through
        // the client the section is showing now.
        #expect(await eventually { current.listCalls == 2 && !store.isRefreshing })
        try await Task.sleep(for: .milliseconds(100))
        #expect(current.listCalls == 2)
        #expect(old.listCalls == 1)
        #expect(store.actionError == nil)
        store.stop()
    }

    @Test("An action that completes after stop starts no refresh")
    func actionAfterStopDoesNotRefresh() async throws {
        let harness = try Harness()
        let engine = harness.nextEngine(name: "engine", holdsActions: true)
        let store = harness.store
        store.start()
        #expect(await eventually { engine.listCalls == 1 && !store.isRefreshing })

        store.perform(.start, on: try Fixture.container(id: "c1", name: "api"))
        #expect(await eventually { engine.performCalls == 1 })
        store.stop()
        engine.releaseActions()
        #expect(await eventually { store.busyContainerIDs.isEmpty })
        try await Task.sleep(for: .milliseconds(100))
        #expect(engine.listCalls == 1)
        #expect(!store.isRefreshing)
    }

    // MARK: - Measurement

    /// A fixed mixed workload — polls, an event burst, manual taps, and action
    /// completions over slow list replies — reporting how many list requests
    /// reached the engine and how many were outstanding at once.
    @Test("Mixed trigger workload keeps one list request in flight")
    func mixedWorkloadRequestBudget() async throws {
        let harness = try Harness(pollInterval: .milliseconds(100))
        let engine = harness.nextEngine(name: "engine", listDelay: .milliseconds(80))
        let store = harness.store
        store.start()
        #expect(await eventually { engine.listCalls == 1 && !store.isRefreshing })
        engine.resetCounters()

        let containers = try (0..<3).map { try Fixture.container(id: "a\($0)", name: "app\($0)") }
        for tick in 0..<30 {
            engine.emitContainerEvent()
            if tick % 6 == 0 { store.refreshNow() }
            if tick % 10 == 5 { store.perform(.restart, on: containers[tick / 10]) }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(600))
        store.stop()

        print("docker-refresh-workload listCalls=\(engine.listCalls) maxConcurrentLists=\(engine.maxConcurrentLists)")
        #expect(engine.maxConcurrentLists == 1)
    }
}

@Suite("Docker refresh gate")
struct DockerRefreshGateTests {
    @Test("Only the first request starts; fresh-read triggers queue one follow-up")
    func coalescesIntoOneFollowUp() {
        var gate = DockerRefreshGate()
        let first = gate.request(needsFreshRead: true)
        #expect(first == .start)
        for _ in 0..<20 {
            let overlapping = gate.request(needsFreshRead: true)
            #expect(overlapping == .coalesced)
        }
        let startsFollowUp = gate.finish()
        #expect(startsFollowUp)
        #expect(gate.isActive)
        let startsAnother = gate.finish()
        #expect(!startsAnother)
        #expect(!gate.isActive)
    }

    @Test("A poll-style trigger rides on the in-flight read")
    func pollDoesNotQueueFollowUp() {
        var gate = DockerRefreshGate()
        let first = gate.request(needsFreshRead: false)
        #expect(first == .start)
        let overlapping = gate.request(needsFreshRead: false)
        #expect(overlapping == .coalesced)
        let startsFollowUp = gate.finish()
        #expect(!startsFollowUp)
        let next = gate.request(needsFreshRead: false)
        #expect(next == .start)
    }

    @Test("Reset drops the in-flight read and any follow-up")
    func resetClearsState() {
        var gate = DockerRefreshGate()
        _ = gate.request(needsFreshRead: true)
        _ = gate.request(needsFreshRead: true)
        gate.reset()
        #expect(!gate.isActive)
        #expect(!gate.hasFollowUp)
        let next = gate.request(needsFreshRead: true)
        #expect(next == .start)
    }
}

// MARK: - Harness

@MainActor
private final class Harness {
    static let socketPath = "/tmp/scripted-docker.sock"

    /// Engines handed out in order, one per connect attempt.
    @MainActor
    final class EngineQueue {
        var queued: [ScriptedDockerEngine] = []
        var handedOut = 0

        func next() -> any DockerEngineAPI {
            handedOut += 1
            return queued.isEmpty ? ScriptedDockerEngine(name: "spare") : queued.removeFirst()
        }
    }

    let store: DockerStore
    private let engines: EngineQueue
    private let suiteName: String

    var engineCount: Int { engines.handedOut }

    init(pollInterval: Duration = .seconds(3600)) throws {
        let suiteName = "DockerStoreRefreshTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let engines = EngineQueue()
        self.suiteName = suiteName
        self.engines = engines
        store = DockerStore(
            defaults: defaults,
            resolveSocketPath: { Harness.socketPath },
            makeClient: { _ in engines.next() },
            pollInterval: pollInterval
        )
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    /// Queue the engine the store gets on its next connect.
    func nextEngine(
        name: String,
        holdsVersion: Bool = false,
        holdsLists: Bool = false,
        holdsActions: Bool = false,
        listDelay: Duration? = nil
    ) -> ScriptedDockerEngine {
        let engine = ScriptedDockerEngine(
            name: name,
            holdsVersion: holdsVersion,
            holdsLists: holdsLists,
            holdsActions: holdsActions,
            listDelay: listDelay
        )
        engines.queued.append(engine)
        return engine
    }
}

/// An engine whose replies can be held until the test releases them. Held
/// replies deliberately ignore cancellation, modelling a transport that
/// answers after its caller has moved on.
private final class ScriptedDockerEngine: DockerEngineAPI, @unchecked Sendable {
    typealias ListReply = Result<[DockerContainerSummary], any Error>

    let name: String
    private let holdsVersion: Bool
    private let holdsLists: Bool
    private let holdsActions: Bool
    private let listDelay: Duration?

    private let lock = NSLock()
    private var _versionCalls = 0
    private var _listCalls = 0
    private var _performCalls = 0
    private var listsInFlight = 0
    private var _maxConcurrentLists = 0
    private var heldVersions: [CheckedContinuation<Void, Never>] = []
    private var heldLists: [CheckedContinuation<ListReply, Never>] = []
    private var heldActions: [CheckedContinuation<(any Error)?, Never>] = []
    private var eventContinuations: [AsyncThrowingStream<DockerEngineEvent, any Error>.Continuation] = []

    init(
        name: String,
        holdsVersion: Bool = false,
        holdsLists: Bool = false,
        holdsActions: Bool = false,
        listDelay: Duration? = nil
    ) {
        self.name = name
        self.holdsVersion = holdsVersion
        self.holdsLists = holdsLists
        self.holdsActions = holdsActions
        self.listDelay = listDelay
    }

    var versionCalls: Int { lock.withLock { _versionCalls } }
    var listCalls: Int { lock.withLock { _listCalls } }
    var performCalls: Int { lock.withLock { _performCalls } }
    var maxConcurrentLists: Int { lock.withLock { _maxConcurrentLists } }

    func resetCounters() {
        lock.withLock {
            _listCalls = 0
            _performCalls = 0
            _maxConcurrentLists = listsInFlight
        }
    }

    func version() async throws -> DockerEngineVersion {
        lock.withLock { _versionCalls += 1 }
        if holdsVersion {
            await withCheckedContinuation { continuation in
                lock.withLock { heldVersions.append(continuation) }
            }
        }
        return Fixture.version(name)
    }

    func containers() async throws -> [DockerContainerSummary] {
        lock.withLock {
            _listCalls += 1
            listsInFlight += 1
            _maxConcurrentLists = max(_maxConcurrentLists, listsInFlight)
        }
        defer { lock.withLock { listsInFlight -= 1 } }

        if holdsLists {
            let reply = await withCheckedContinuation { continuation in
                lock.withLock { heldLists.append(continuation) }
            }
            return try reply.get()
        }
        if let listDelay {
            // Cancellation aborts the wait, like the socket transport does.
            try await Task.sleep(for: listDelay)
        }
        return []
    }

    func perform(_ action: DockerContainerAction, containerID: String) async throws {
        lock.withLock { _performCalls += 1 }
        guard holdsActions else { return }
        let failure = await withCheckedContinuation { continuation in
            lock.withLock { heldActions.append(continuation) }
        }
        if let failure { throw failure }
    }

    func containerEvents() -> AsyncThrowingStream<DockerEngineEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<DockerEngineEvent, any Error>.makeStream()
        lock.withLock { eventContinuations.append(continuation) }
        return stream
    }

    func emitContainerEvent() {
        let event = Fixture.containerEvent
        for continuation in lock.withLock({ eventContinuations }) {
            continuation.yield(event)
        }
    }

    func releaseVersion() {
        for continuation in lock.withLock({ () -> [CheckedContinuation<Void, Never>] in
            defer { heldVersions = [] }
            return heldVersions
        }) {
            continuation.resume()
        }
    }

    func releaseLists(with containers: [DockerContainerSummary]) {
        releaseLists(reply: .success(containers))
    }

    func releaseLists(throwing error: any Error) {
        releaseLists(reply: .failure(error))
    }

    private func releaseLists(reply: ListReply) {
        for continuation in lock.withLock({ () -> [CheckedContinuation<ListReply, Never>] in
            defer { heldLists = [] }
            return heldLists
        }) {
            continuation.resume(returning: reply)
        }
    }

    func releaseActions(throwing error: (any Error)? = nil) {
        for continuation in lock.withLock({ () -> [CheckedContinuation<(any Error)?, Never>] in
            defer { heldActions = [] }
            return heldActions
        }) {
            continuation.resume(returning: error)
        }
    }
}

private enum Fixture {
    static func version(_ name: String) -> DockerEngineVersion {
        DockerEngineVersion(version: name, apiVersion: "1.43", os: "linux")
    }

    static func container(id: String, name: String) throws -> DockerContainerSummary {
        let json = """
        {"Id":"\(id)","Names":["/\(name)"],"Image":"example","State":"running","Status":"Up"}
        """
        return try JSONDecoder().decode(DockerContainerSummary.self, from: Data(json.utf8))
    }

    static let containerEvent: DockerEngineEvent = {
        let json = #"{"Type":"container","Action":"start"}"#
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(DockerEngineEvent.self, from: Data(json.utf8))
    }()
}

/// Poll a main-actor condition until it holds or the deadline passes.
@MainActor
private func eventually(
    timeout: Duration = .seconds(3),
    pollEvery interval: Duration = .milliseconds(5),
    _ condition: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: interval)
    }
    return true
}
