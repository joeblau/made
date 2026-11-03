import Foundation
import Observation

@Observable
@MainActor
final class DroneStore {
    static let shared = DroneStore()

    private(set) var records: [DroneRecord]
    private(set) var states: [UUID: DroneConnectionState] = [:]
    private(set) var diagnostics: [UUID: DroneDiagnostics] = [:]
    private(set) var pairingRequests: [UUID: DronePairingRequest] = [:]
    private(set) var forgettingIDs: Set<UUID> = []
    private(set) var persistenceError: String?
    let discovery: DroneDiscovery

    @ObservationIgnored private let persistence: DroneRegistryPersistence
    @ObservationIgnored private let transport: any DroneTransportFactory
    @ObservationIgnored private let timing: DroneSupervisorTiming
    @ObservationIgnored private let date: () -> Date
    @ObservationIgnored private let makeID: () -> UUID
    @ObservationIgnored private let controllerID: UUID
    @ObservationIgnored private var supervisors: [UUID: DroneWorkerSupervisor] = [:]
    @ObservationIgnored private var terminalClients: [UUID: DroneRemoteTerminalClient] = [:]
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var isRegistryReadOnly = false

    init(
        persistence: DroneRegistryPersistence = .production(),
        transport: any DroneTransportFactory = DroneLANTransportFactory(),
        discovery: DroneDiscovery = DroneDiscovery(),
        timing: DroneSupervisorTiming = DroneSupervisorTiming(),
        date: @escaping () -> Date = Date.init,
        makeID: @escaping () -> UUID = UUID.init
    ) {
        self.persistence = persistence
        self.transport = transport
        self.discovery = discovery
        self.timing = timing
        self.date = date
        self.makeID = makeID
        controllerID = (try? transport.authenticatedControllerID()) ?? makeID()
        do {
            records = try persistence.load()
        } catch {
            records = []
            persistenceError = "Saved Drones could not be loaded. The registry is read-only so the existing file is not overwritten."
            isRegistryReadOnly = true
        }
        for record in records {
            installSupervisor(for: record)
        }
        transport.onPairingRequest = { [weak self] request in
            self?.pairingRequests[request.id] = request
        }
        discovery.onCandidatesChange = { [weak self] candidates in
            self?.applyDiscoveredCandidates(candidates)
        }
    }

    var availableCandidates: [DroneDiscoveryCandidate] {
        let savedDiscoveryIDs = Set(records.compactMap(\.discoveryID))
        return discovery.candidates.filter { !savedDiscoveryIDs.contains($0.id) }
    }

    func resolvePairing(requestID: UUID, approved: Bool) {
        pairingRequests.removeValue(forKey: requestID)
        transport.resolvePairing(requestID: requestID, approved: approved)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        supervisors.values.forEach { $0.start() }
    }

    func stop() {
        isRunning = false
        discovery.stop()
        supervisors.values.forEach { $0.stop() }
    }

    func startDiscovery() {
        discovery.start()
    }

    func stopDiscovery() {
        discovery.stop()
    }

    @discardableResult
    func addManual(name: String, host: String, port: String) throws -> UUID {
        let endpoint = try DroneEndpoint.manual(host: host, portText: port)
        let resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? endpoint.displayText
            : name
        return try add(name: resolvedName, endpoints: [endpoint], discoveryID: nil)
    }

    @discardableResult
    func pair(_ candidate: DroneDiscoveryCandidate) throws -> UUID {
        try add(
            name: candidate.displayName,
            endpoints: [candidate.endpoint],
            discoveryID: candidate.id
        )
    }

    func rename(id: UUID, to name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 80 else {
            throw DroneRegistryError.invalidName
        }
        try mutateRegistry { records in
            guard let index = records.firstIndex(where: { $0.id == id }) else {
                throw DroneRegistryError.missingDrone
            }
            records[index].name = name
        }
    }

    func retry(id: UUID) {
        supervisors[id]?.retry()
    }

    func forget(id: UUID) async {
        guard !forgettingIDs.contains(id), supervisors[id] != nil else { return }
        forgettingIDs.insert(id)
        supervisors[id]?.stop()
        states[id] = .forgetting
        do {
            try await transport.revoke(droneID: id)
            try mutateRegistry { records in
                guard let index = records.firstIndex(where: { $0.id == id }) else {
                    throw DroneRegistryError.missingDrone
                }
                records.remove(at: index)
            }
            supervisors.removeValue(forKey: id)
            states.removeValue(forKey: id)
            diagnostics.removeValue(forKey: id)
        } catch {
            states[id] = .offline(issue: .revocationFailed, retryAttempt: nil)
            persistenceError = error is DroneRegistryError
                ? "The Drone pin was revoked, but its metadata could not be removed. Retry Forget."
                : nil
        }
        forgettingIDs.remove(id)
    }

    func applyDiscoveredCandidates(_ candidates: [DroneDiscoveryCandidate]) {
        guard !isRegistryReadOnly else { return }
        let byDiscoveryID = Dictionary(
            candidates.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let changedIDs = records.filter {
            guard let discoveryID = $0.discoveryID,
                  let candidate = byDiscoveryID[discoveryID]
            else { return false }
            return $0.endpoints != [candidate.endpoint]
        }.map(\.id)
        guard !changedIDs.isEmpty else { return }
        do {
            try mutateRegistry { records in
                for index in records.indices {
                    guard let discoveryID = records[index].discoveryID,
                          let candidate = byDiscoveryID[discoveryID]
                    else { continue }
                    records[index].endpoints = [candidate.endpoint]
                }
            }
            for id in changedIDs {
                guard let record = records.first(where: { $0.id == id }) else { continue }
                supervisors[id]?.updateRecord(record)
            }
        } catch {
            persistenceError = "The discovered address could not be saved. The previous endpoint remains active."
        }
    }

    private func add(name: String, endpoints: [DroneEndpoint], discoveryID: String?) throws -> UUID {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 80 else {
            throw DroneRegistryError.invalidName
        }
        guard records.count < DroneLimits.maxPairedWorkers else {
            throw DroneRegistryError.registryFull
        }
        if let discoveryID, records.contains(where: { $0.discoveryID == discoveryID }) {
            throw DroneRegistryError.duplicateDrone
        }
        let record = DroneRecord(id: makeID(), name: name, endpoints: endpoints, discoveryID: discoveryID)
        try record.validate()
        try mutateRegistry { $0.append(record) }
        installSupervisor(for: record)
        if isRunning { supervisors[record.id]?.start() }
        return record.id
    }

    private func installSupervisor(for record: DroneRecord) {
        let supervisor = DroneWorkerSupervisor(
            record: record,
            transport: transport,
            timing: timing,
            date: date,
            onUpdate: { [weak self] id in self?.publish(id) },
            onEnvelope: { [weak self] id, envelope in
                guard let client = self?.terminalClients[id] else { return }
                Task { await client.handle(envelope) }
            }
        )
        supervisors[record.id] = supervisor
        states[record.id] = initialState(for: record)
        diagnostics[record.id] = supervisor.diagnostics
    }

    func terminalClient(for id: UUID) -> (any DroneTerminalClient)? {
        terminalClients[id]
    }

    func makeToolClient(
        droneID: UUID,
        jobID: DroneJobID = DroneJobID(),
        workspaceID: UUID = DroneWorkspaceIDs.default
    ) throws -> DroneToolClient {
        guard let transport = terminalClients[droneID] else { throw DroneTransportError.pairingRequired }
        let lease = DroneToolLease(
            id: UUID(),
            controllerID: controllerID,
            droneID: droneID,
            jobID: jobID,
            workspaceID: workspaceID,
            expiresAt: date().timeIntervalSince1970 + 300
        )
        return try DroneToolClient(transport: transport, lease: lease)
    }

    private func initialState(for record: DroneRecord) -> DroneConnectionState {
        switch record.lastKnownStatus {
        case .pairing: .pairing
        case .unauthorized: .unauthorized(.unauthorized)
        case .incompatible: .incompatible
        case .busy: .busy(retryAttempt: 0)
        case .online, .offline: .offline(issue: .disconnected, retryAttempt: nil)
        }
    }

    private func publish(_ id: UUID) {
        guard let supervisor = supervisors[id] else { return }
        states[id] = supervisor.state
        diagnostics[id] = supervisor.diagnostics
        switch supervisor.state {
        case .connected:
            if terminalClients[id] == nil, let connection = supervisor.connection {
                terminalClients[id] = DroneRemoteTerminalClient(
                    droneID: id,
                    controllerID: controllerID,
                    connection: connection
                )
            }
        case .offline, .unauthorized, .incompatible, .busy, .pairing:
            let client = terminalClients.removeValue(forKey: id)
            Task { await client?.closeRequests() }
        case .connecting, .forgetting:
            break
        }
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let previous = records[index]
        switch supervisor.state {
        case .connected(let peer):
            if let expected = previous.verifiedIdentityFingerprint,
               expected != peer.identityFingerprint {
                states[id] = .unauthorized(.identityMismatch)
                return
            }
            records[index].applyAuthenticatedPeer(peer, at: date())
        case .offline(let issue, _):
            records[index].lastKnownStatus = .offline
            diagnostics[id]?.lastIssue = issue
        case .unauthorized:
            records[index].lastKnownStatus = .unauthorized
        case .incompatible:
            records[index].lastKnownStatus = .incompatible
        case .busy:
            records[index].lastKnownStatus = .busy
        case .pairing:
            records[index].lastKnownStatus = .pairing
        case .connecting, .forgetting:
            break
        }
        if records[index] != previous {
            do {
                try persistence.save(records)
                persistenceError = nil
            } catch {
                records[index] = previous
                persistenceError = "The latest Drone status could not be saved. It remains visible for this launch."
            }
        }
    }

    private func mutateRegistry(_ mutation: (inout [DroneRecord]) throws -> Void) throws {
        guard !isRegistryReadOnly else { throw DroneRegistryError.persistenceUnavailable }
        var updated = records
        try mutation(&updated)
        try persistence.save(updated)
        records = updated
        persistenceError = nil
    }
}
