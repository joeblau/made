import Foundation

// Kept beside main.swift so the worker proof stays within the file-length limit.
extension DroneWorkerProof {
    /// #440: undecodable persisted records are quarantined; the worker starts and
    /// reports unhealthy storage instead of exiting into a launchd restart loop.
    static func verifyQuarantinedStorageHealth(root: URL, workspace: URL) async throws {
        let state = root.appendingPathComponent("quarantine-state", isDirectory: true)
        let terminals = state.appendingPathComponent("terminals", isDirectory: true)
        let jobRecords = state.appendingPathComponent("jobs/controllers/\(UUID().uuidString)/jobs", isDirectory: true)
        try FileManager.default.createDirectory(at: terminals, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: jobRecords, withIntermediateDirectories: true)
        try Data("not a terminal catalog".utf8).write(to: terminals.appendingPathComponent("terminals.json"))
        try Data(#"{"schemaVersion":99}"#.utf8).write(to: jobRecords.appendingPathComponent("future-schema-0001.json"))
        let identity = DroneIdentityStore(role: .worker, storage: ProofPairingStorage())
        let pairingStorage = ProofPairingStorage()
        let service = try DroneWorkerService(
            workspace: workspace,
            stateDirectory: state,
            transport: DroneLANTransport(
                role: .worker,
                identityStore: identity,
                pairingStore: DronePairingStore(role: .worker, storage: pairingStorage)
            ),
            workerID: try identity.loadOrCreatePeerID().rawValue,
            pairingStore: DronePairingStore(role: .worker, storage: pairingStorage)
        )
        // Inspect the filesystem before stop(): terminal shutdown persists a
        // fresh empty catalog at the original path.
        let health = await service.healthSnapshot()
        expect(!health.storageHealthy, "quarantined records were reported as healthy storage")
        expect(!FileManager.default.fileExists(atPath: terminals.appendingPathComponent("terminals.json").path),
               "undecodable terminal catalog was left in place")
        expect(!FileManager.default.fileExists(atPath: jobRecords.appendingPathComponent("future-schema-0001.json").path),
               "undecodable job record was left in place")
        let files = FileManager.default
        let terminalQuarantine = (try? files.contentsOfDirectory(
            at: terminals.appendingPathComponent("quarantine"), includingPropertiesForKeys: nil)) ?? []
        expect(terminalQuarantine.count == 1 && terminalQuarantine.first.flatMap {
            try? Data(contentsOf: $0.appendingPathComponent("terminals.json"))
        } == Data("not a terminal catalog".utf8), "terminal catalog was not moved intact into one quarantine entry")
        let jobQuarantine = (try? files.contentsOfDirectory(
            at: state.appendingPathComponent("jobs/quarantine"), includingPropertiesForKeys: nil)) ?? []
        expect(jobQuarantine.count == 1 && jobQuarantine.first.map {
            files.fileExists(atPath: $0.appendingPathComponent("future-schema-0001.json").path)
        } == true, "job record was not moved into one quarantine entry")
        await service.stop()
    }
}
