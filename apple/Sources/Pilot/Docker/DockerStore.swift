import Foundation
import Observation

/// Decides when a container-list read may start. At most one read is in flight;
/// triggers that arrive meanwhile either ride on it or, when the in-flight read
/// may predate whatever prompted them, queue a single follow-up.
struct DockerRefreshGate {
    enum Decision: Equatable {
        /// Nothing is in flight: issue a read now.
        case start
        /// A read is already in flight; this trigger is covered by it or by the
        /// queued follow-up.
        case coalesced
    }

    private(set) var isActive = false
    private(set) var hasFollowUp = false

    mutating func request(needsFreshRead: Bool) -> Decision {
        guard isActive else {
            isActive = true
            return .start
        }
        if needsFreshRead { hasFollowUp = true }
        return .coalesced
    }

    /// The in-flight read finished. Returns whether the queued follow-up should
    /// start now, in which case the gate stays active for it.
    mutating func finish() -> Bool {
        guard hasFollowUp else {
            isActive = false
            return false
        }
        hasFollowUp = false
        return true
    }

    mutating func reset() {
        isActive = false
        hasFollowUp = false
    }
}

/// Live state behind the Docker section.
///
/// Owns the engine handshake, the container list, and the `/events` watch that
/// keeps the list honest without polling hard. Every mutation lands on the main
/// actor so SwiftUI observes it directly; only the socket I/O leaves.
@Observable
@MainActor
final class DockerStore {
    /// Whether Pilot has an engine to talk to, and why not when it doesn't.
    enum Engine: Equatable {
        case checking
        case unavailable(reason: String)
        case connected(version: DockerEngineVersion, socketPath: String)

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    /// What asked for a list read. Only a poll tick is fully answered by a read
    /// that was already in flight; every other trigger reports a change that
    /// read may have missed.
    private enum RefreshTrigger {
        case handshake, poll, event, manual, action

        var needsFreshRead: Bool { self != .poll }
    }

    private(set) var engine: Engine = .checking
    private(set) var containers: [DockerContainerSummary] = []
    /// True from the first list read of a burst until its follow-up (if any)
    /// lands, so the indicator doesn't blink between the two.
    private(set) var isRefreshing = false
    /// Last failed lifecycle action, shown as a dismissible banner. Cleared by
    /// the next successful action or refresh.
    private(set) var actionError: String?
    /// Containers with an action in flight, so their row shows progress and
    /// can't be double-fired.
    private(set) var busyContainerIDs: Set<String> = []

    var searchText = ""
    var selectedContainerID: String?
    var showsStopped: Bool {
        didSet { defaults.set(showsStopped, forKey: Self.showsStoppedKey) }
    }

    /// Set when a remove was requested, so the view can confirm before the
    /// irreversible delete. Transient — mirrors the Remote Desktop pattern.
    var containerPendingRemoval: DockerContainerSummary?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let makeClient: @MainActor (String) -> any DockerEngineAPI
    @ObservationIgnored private let resolveSocketPath: @MainActor () -> String?
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private var client: (any DockerEngineAPI)?
    @ObservationIgnored private var isRunning = false

    /// Identifies the current client. Bumped whenever the client is replaced or
    /// the section stops; every reply carries the generation it was issued
    /// under and is dropped on a mismatch, whether or not its task noticed
    /// being cancelled.
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var eventDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var listTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGate = DockerRefreshGate()
    /// Lifecycle requests in flight, by container ID. Leaving the section or
    /// reconnecting does not cancel these: cancelling closes the socket, and a
    /// stop or remove the daemon is partway through should finish rather than
    /// be abandoned. Their results are simply no longer shown.
    @ObservationIgnored private var actionTasks: [String: Task<Void, Never>] = [:]

    private static let showsStoppedKey = "docker.showsStopped"
    /// Events arrive in bursts — a compose stack coming up fires one per
    /// container — so a quiet period is awaited before reading the list.
    private static let eventDebounce = Duration.milliseconds(250)
    private static let eventStreamRetryDelay = Duration.seconds(5)

    /// - Parameter pollInterval: How often the safety-net poll runs. `/events`
    ///   carries state changes promptly; the poll exists for the things no
    ///   event announces (a status string aging from "Up 3 minutes" to "Up 4
    ///   minutes") and for recovering after a dropped stream.
    init(
        defaults: UserDefaults = .standard,
        resolveSocketPath: @escaping @MainActor () -> String? = { DockerSocketLocator.resolve() },
        makeClient: @escaping @MainActor (String) -> any DockerEngineAPI = { DockerEngineClient(socketPath: $0) },
        pollInterval: Duration = .seconds(15)
    ) {
        self.defaults = defaults
        self.resolveSocketPath = resolveSocketPath
        self.makeClient = makeClient
        self.pollInterval = pollInterval
        // Default to showing stopped containers: the list is as much "what can I
        // bring up" as "what is up".
        self.showsStopped = defaults.object(forKey: Self.showsStoppedKey) as? Bool ?? true
    }

    // MARK: - Lifecycle

    /// Begin (or resume) watching the daemon. Idempotent — the view calls this
    /// every time the section appears.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        connect()
        startPoll()
    }

    /// Stop all socket work. The section is a full-detail mode, so leaving it
    /// leaves nothing running behind it except lifecycle requests already sent.
    func stop() {
        isRunning = false
        retireConnection()
        pollTask?.cancel()
        pollTask = nil
    }

    /// Re-run the handshake from scratch — the Retry button, and the path back
    /// after the user starts their engine.
    func reconnect() {
        engine = .checking
        isRunning = true
        connect()
        startPoll()
    }

    /// Cancel the current client's socket work and make sure nothing it has
    /// already started can publish.
    private func retireConnection() {
        generation &+= 1
        connectTask?.cancel()
        connectTask = nil
        eventsTask?.cancel()
        eventsTask = nil
        eventDebounceTask?.cancel()
        eventDebounceTask = nil
        listTask?.cancel()
        listTask = nil
        refreshGate.reset()
        isRefreshing = false
    }

    private func isCurrent(_ issuedUnder: UInt64) -> Bool {
        isRunning && issuedUnder == generation
    }

    /// Handshake, then load the list and start watching. Replaces any in-flight
    /// attempt so repeated Retry taps can't stack up.
    private func connect() {
        retireConnection()

        guard let socketPath = resolveSocketPath() else {
            client = nil
            containers = []
            engine = .unavailable(reason: "No Docker socket found on this Mac.")
            return
        }

        let client = makeClient(socketPath)
        self.client = client
        let generation = generation
        connectTask = Task { [weak self] in
            let version: DockerEngineVersion
            do {
                version = try await client.version()
            } catch {
                guard let self, isCurrent(generation) else { return }
                containers = []
                engine = .unavailable(reason: Self.describe(error))
                return
            }
            guard let self, isCurrent(generation) else { return }
            engine = .connected(version: version, socketPath: socketPath)
            requestRefresh(.handshake)
            watchEvents(from: client, generation: generation)
        }
    }

    // MARK: - Refreshing

    /// Event-driven refresh, debounced so a burst of events costs one read.
    func scheduleRefresh() {
        guard isRunning, engine.isConnected else { return }
        eventDebounceTask?.cancel()
        let generation = generation
        eventDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.eventDebounce)
            guard let self, !Task.isCancelled, isCurrent(generation) else { return }
            eventDebounceTask = nil
            requestRefresh(.event)
        }
    }

    func refreshNow() {
        requestRefresh(.manual)
    }

    /// The single entry point for container-list reads.
    private func requestRefresh(_ trigger: RefreshTrigger) {
        guard isRunning, engine.isConnected, client != nil else { return }
        switch refreshGate.request(needsFreshRead: trigger.needsFreshRead) {
        case .start:
            startListRead()
        case .coalesced:
            break
        }
    }

    private func startListRead() {
        guard let client else {
            refreshGate.reset()
            isRefreshing = false
            return
        }
        // A debounced event that arrived before this read is answered by it.
        eventDebounceTask?.cancel()
        eventDebounceTask = nil
        isRefreshing = true

        let generation = generation
        listTask = Task { [weak self] in
            let result: Result<[DockerContainerSummary], any Error>
            do {
                result = .success(try await client.containers())
            } catch {
                result = .failure(error)
            }
            guard let self, isCurrent(generation) else { return }
            finishListRead(result)
        }
    }

    private func finishListRead(_ result: Result<[DockerContainerSummary], any Error>) {
        listTask = nil
        switch result {
        case .success(let fetched):
            containers = fetched
            actionError = nil
            if let selectedContainerID, !fetched.contains(where: { $0.id == selectedContainerID }) {
                self.selectedContainerID = nil
            }
            if refreshGate.finish() {
                startListRead()
            } else {
                isRefreshing = false
            }
        case .failure(let error):
            refreshGate.reset()
            isRefreshing = false
            containers = []
            engine = .unavailable(reason: Self.describe(error))
        }
    }

    /// One loop that both refreshes while connected and retries the handshake
    /// while not, so an engine started after Pilot launched is picked up without
    /// the user touching Retry.
    private func startPoll() {
        guard pollTask == nil else { return }
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled, isRunning else { return }
                if engine.isConnected {
                    requestRefresh(.poll)
                } else {
                    connect()
                }
            }
        }
    }

    private func watchEvents(from client: any DockerEngineAPI, generation: UInt64) {
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            // Reconnect with a fixed backoff if the daemon restarts or the
            // stream drops; the poll above covers the gap in the meantime.
            while !Task.isCancelled {
                do {
                    for try await _ in client.containerEvents() {
                        guard let self, !Task.isCancelled, isCurrent(generation) else { return }
                        scheduleRefresh()
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                }
                guard self?.isCurrent(generation) == true, !Task.isCancelled else { return }
                try? await Task.sleep(for: Self.eventStreamRetryDelay)
            }
        }
    }

    // MARK: - Actions

    func perform(_ action: DockerContainerAction, on container: DockerContainerSummary) {
        guard isRunning, let client, !busyContainerIDs.contains(container.id) else { return }
        busyContainerIDs.insert(container.id)
        let generation = generation
        actionTasks[container.id] = Task { [weak self] in
            let failure: (any Error)?
            do {
                try await client.perform(action, containerID: container.id)
                failure = nil
            } catch {
                failure = error
            }
            self?.finishAction(action, on: container, issuedUnder: generation, failure: failure)
        }
    }

    private func finishAction(
        _ action: DockerContainerAction,
        on container: DockerContainerSummary,
        issuedUnder generation: UInt64,
        failure: (any Error)?
    ) {
        // The request is over whichever client sent it, so the row is free.
        actionTasks[container.id] = nil
        busyContainerIDs.remove(container.id)

        if let failure {
            guard isCurrent(generation) else { return }
            actionError = "\(action.label) “\(container.name)” failed: \(Self.describe(failure))"
            return
        }
        if isCurrent(generation) {
            actionError = nil
        }
        // The daemon's state changed either way; read it through the current
        // client, if the section is still showing.
        requestRefresh(.action)
    }

    func requestRemoval(of container: DockerContainerSummary) {
        containerPendingRemoval = container
    }

    func dismissActionError() {
        actionError = nil
    }

    // MARK: - Presentation

    /// Containers after the "show stopped" toggle and the search field, running
    /// first and alphabetical within each group so the list doesn't reshuffle as
    /// statuses tick over.
    var visibleContainers: [DockerContainerSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return containers
            .filter { showsStopped || $0.state.isRunning }
            .filter { container in
                guard !query.isEmpty else { return true }
                return container.name.lowercased().contains(query)
                    || container.image.lowercased().contains(query)
                    || container.shortID.contains(query)
                    || (container.composeProject?.lowercased().contains(query) ?? false)
            }
            .sorted { lhs, rhs in
                if lhs.state.isRunning != rhs.state.isRunning { return lhs.state.isRunning }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    /// One section per compose project, standalone containers last. Groups are
    /// ordered by name so the list is stable across refreshes.
    struct ContainerGroup: Identifiable {
        let id: String
        let title: String
        let isCompose: Bool
        let containers: [DockerContainerSummary]
    }

    var groupedContainers: [ContainerGroup] {
        let grouped = Dictionary(grouping: visibleContainers) { $0.composeProject }
        var groups = grouped
            .compactMap { project, items -> ContainerGroup? in
                guard let project else { return nil }
                return ContainerGroup(id: project, title: project, isCompose: true, containers: items)
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        if let standalone = grouped[String?.none] ?? nil, !standalone.isEmpty {
            groups.append(
                ContainerGroup(id: "__standalone", title: "Standalone", isCompose: false, containers: standalone)
            )
        }
        return groups
    }

    var runningCount: Int {
        containers.filter { $0.state.isRunning }.count
    }

    private static func describe(_ error: any Error) -> String {
        if let transportError = error as? DockerTransportError {
            return transportError.errorDescription ?? "\(transportError)"
        }
        return error.localizedDescription
    }
}
