import Foundation
import Network

@MainActor
enum FleetProof {
    static func run() async throws {
        let storage = FleetMemoryStorage()
        let identity = DroneIdentityStore(role: .controller, storage: storage)
        let pins = DronePairingStore(role: .controller, storage: storage)
        let controllerKey = try identity.loadOrCreate()
        let controllerID = try identity.loadOrCreatePeerID()
        let controller = DroneLANTransport(role: .controller, identityStore: identity, pairingStore: pins)
        let observed = FleetEvents()
        controller.onEvent = { observed.record($0) }
        var workers: [DroneLANTransport] = []
        var workerEvents: [FleetEvents] = []
        var workerKeys: Set<Data> = []
        defer {
            controller.stop()
            workers.forEach { $0.stop() }
        }
        // Actual concurrent authenticated connections, not sequential approval records.
        for _ in 0..<DroneLimits.maxPairedWorkers {
            let workerStorage = FleetMemoryStorage()
            let workerIdentity = DroneIdentityStore(role: .worker, storage: workerStorage)
            let workerPins = DronePairingStore(role: .worker, storage: workerStorage)
            let workerKey = try workerIdentity.loadOrCreate()
            let workerID = try workerIdentity.loadOrCreatePeerID()
            workerKeys.insert(workerKey.publicKey.rawRepresentation)
            try pins.approve(workerKey.publicKey, for: workerID, replacing: nil)
            try workerPins.approve(controllerKey.publicKey, for: controllerID, replacing: nil)
            let worker = DroneLANTransport(role: .worker, identityStore: workerIdentity, pairingStore: workerPins)
            let events = FleetEvents()
            worker.onEvent = { events.record($0) }
            workers.append(worker)
            workerEvents.append(events)
            worker.startListening()
            await wait { events.port != nil }
            controller.connect(peerID: workerID, host: "127.0.0.1", port: events.port!)
        }
        await wait { observed.connected.count + observed.failedCount == DroneLimits.maxPairedWorkers }
        precondition(observed.connected.count == DroneLimits.maxPairedWorkers,
                     "controller admitted \(observed.connected.count) workers; expected \(DroneLimits.maxPairedWorkers)")
        precondition(workerKeys.count == DroneLimits.maxPairedWorkers, "worker identities were shared")
        for id in observed.connected { controller.send(DroneEnvelope(kind: .heartbeat), on: id) }
        await wait { workerEvents.allSatisfy { $0.envelopeCount > 0 } }
        let overflow = DroneConnectionID()
        controller.connect(peerID: DronePeerID(), host: "127.0.0.1", port: workerEvents[0].port!, connectionID: overflow)
        await wait { observed.limited.contains(overflow) }
        precondition(observed.connected.count == DroneLimits.maxPairedWorkers, "overflow disrupted admitted workers")
        try await workerPreauthenticationBudget()
        print("Fleet proof passed: 32 simultaneous authenticated workers with independent keys, live traffic, controller overflow, worker preauth cap 8.")
    }

    private static func workerPreauthenticationBudget() async throws {
        let storage = FleetMemoryStorage()
        let worker = DroneLANTransport(role: .worker,
                                       identityStore: DroneIdentityStore(role: .worker, storage: storage),
                                       pairingStore: DronePairingStore(role: .worker, storage: storage))
        let events = FleetEvents()
        worker.onEvent = { events.record($0) }
        worker.startListening()
        await wait { events.port != nil }
        var unauthenticated: [NWConnection] = []
        defer {
            unauthenticated.forEach { $0.cancel() }
            worker.stop()
        }
        for _ in 0...DroneLimits.maxConnectionsPerWorker {
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: events.port!)!, using: .tcp)
            unauthenticated.append(connection)
            connection.start(queue: .global())
        }
        await wait { events.globalLimitFailures == 1 }
        precondition(DroneLimits.maxConnectionsPerWorker == 8)
    }

    private static func wait(_ predicate: () -> Bool) async {
        while !predicate() { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

private final class FleetEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var listeningPort: UInt16?
    private var connectedIDs: Set<DroneConnectionID> = []
    private var limitIDs: Set<DroneConnectionID> = []
    private var failures = 0
    private var globalLimits = 0
    private var envelopes = 0
    var port: UInt16? { lock.withLock { listeningPort } }
    var connected: Set<DroneConnectionID> { lock.withLock { connectedIDs } }
    var limited: Set<DroneConnectionID> { lock.withLock { limitIDs } }
    var failedCount: Int { lock.withLock { failures } }
    var globalLimitFailures: Int { lock.withLock { globalLimits } }
    var envelopeCount: Int { lock.withLock { envelopes } }

    func record(_ event: DroneTransportEvent) {
        lock.withLock {
            switch event {
            case .listening(let port): listeningPort = port
            case .connected(let id, _, _): connectedIDs.insert(id)
            case .disconnected(let id, _): connectedIDs.remove(id)
            case .envelope: envelopes += 1
            case .failed(let id, let failure):
                failures += 1
                if failure == .connectionLimit {
                    if let id { limitIDs.insert(id) } else { globalLimits += 1 }
                }
            default: break
            }
        }
    }
}

private final class FleetMemoryStorage: PairingSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.withLock { values[account] } }
    func write(_ data: Data, account: String) throws { lock.withLock { values[account] = data } }
    func delete(account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}
