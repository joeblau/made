import Foundation
import XCTest
@testable import Pilot

@MainActor
final class DroneRegistryTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("drone-registry-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }

    func testPersistenceRestoresAndSortsFifteenDrones() throws {
        let persistence = DroneRegistryPersistence(url: temporaryDirectory.appendingPathComponent("drones.json"))
        let records = (0..<15).map { index in
            DroneRecord(
                id: UUID(),
                name: String(format: "Worker %02d", 14 - index),
                endpoints: [.hostPort(host: "192.168.1.\(index + 10)", port: 7_400 + UInt16(index))]
            )
        }
        try persistence.save(records)
        let restored = try persistence.load()
        XCTAssertEqual(restored.count, 15)
        XCTAssertEqual(restored.map(\.name), restored.map(\.name).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        })
        XCTAssertEqual(Set(restored.map(\.id)).count, 15)
    }

    func testDiscoveryDeduplicatesAndDropsInvalidCandidates() {
        let discovery = DroneDiscovery()
        let valid = DroneDiscoveryCandidate(
            id: "worker._blau-drone._tcp.local.",
            displayName: "Worker",
            endpoint: .bonjour(name: "worker", type: "_blau-drone._tcp", domain: "local."),
            advertisedProtocolVersions: [1, 1, 2]
        )
        let duplicate = DroneDiscoveryCandidate(
            id: valid.id,
            displayName: "Worker",
            endpoint: valid.endpoint,
            advertisedProtocolVersions: [1]
        )
        let invalid = DroneDiscoveryCandidate(
            id: "invalid",
            displayName: "Invalid",
            endpoint: .bonjour(name: "invalid", type: "_other._tcp", domain: "local."),
            advertisedProtocolVersions: [1]
        )
        discovery.apply([valid, duplicate, invalid])
        XCTAssertEqual(discovery.candidates.count, 1)
        XCTAssertEqual(discovery.candidates[0].advertisedProtocolVersions, [1, 2])
    }

    func testManualRegistryRenameEndpointUpdateAndForget() async throws {
        let transport = RegistryFakeTransport()
        let persistence = DroneRegistryPersistence(url: temporaryDirectory.appendingPathComponent("drones.json"))
        let store = DroneStore(persistence: persistence, transport: transport)
        let id = try store.addManual(name: "Build Mac", host: "192.168.1.20", port: "7400")
        XCTAssertEqual(store.records.count, 1)

        try store.rename(id: id, to: "Build Mini")
        XCTAssertEqual(store.records.first?.name, "Build Mini")
        let candidate = DroneDiscoveryCandidate(
            id: "build",
            displayName: "Build Mini",
            endpoint: .bonjour(name: "build", type: "_blau-drone._tcp", domain: "local."),
            advertisedProtocolVersions: [1]
        )
        let otherPersistence = DroneRegistryPersistence(
            url: temporaryDirectory.appendingPathComponent("discovered.json")
        )
        let otherStore = DroneStore(
            persistence: otherPersistence,
            transport: transport,
            makeID: { id }
        )
        _ = try otherStore.pair(candidate)
        otherStore.applyDiscoveredCandidates([
            DroneDiscoveryCandidate(
                id: "build",
                displayName: "Build Mini",
                endpoint: .bonjour(name: "build-new", type: "_blau-drone._tcp", domain: "local."),
                advertisedProtocolVersions: [1]
            ),
        ])
        XCTAssertEqual(otherStore.records.first?.endpoints.first?.displayText, "build-new")

        await otherStore.forget(id: id)
        XCTAssertEqual(transport.revokedIDs, [id])
        XCTAssertTrue(otherStore.records.isEmpty)
        XCTAssertEqual(try otherPersistence.load().count, 0)
    }

    func testFifteenSupervisorsStopAfterBoundedReconnectSleep() async throws {
        let persistence = DroneRegistryPersistence(url: temporaryDirectory.appendingPathComponent("drones.json"))
        let timing = DroneSupervisorTiming(sleep: { _ in throw CancellationError() })
        let store = DroneStore(
            persistence: persistence,
            transport: RegistryFakeTransport(),
            timing: timing
        )
        for index in 0..<15 {
            _ = try store.addManual(name: "Worker \(index)", host: "192.168.1.\(index + 10)", port: "7400")
        }
        store.start()
        for _ in 0..<20 {
            if store.diagnostics.values.allSatisfy({ $0.connectAttempts == 1 }) { break }
            await Task.yield()
        }
        XCTAssertEqual(store.diagnostics.count, 15)
        XCTAssertTrue(store.diagnostics.values.allSatisfy { $0.connectAttempts == 1 })
        XCTAssertTrue(store.states.values.allSatisfy {
            if case .offline(let issue, _) = $0 { return issue == .connectionFailed }
            return false
        })
        store.stop()
    }

    func testInvalidManualEndpointNeverFallsBackToLocal() {
        let store = DroneStore(
            persistence: DroneRegistryPersistence(url: temporaryDirectory.appendingPathComponent("drones.json")),
            transport: RegistryFakeTransport()
        )
        XCTAssertThrowsError(try store.addManual(name: "Bad", host: "bad host", port: "0"))
        XCTAssertTrue(store.records.isEmpty)
    }
}

@MainActor
private final class RegistryFakeTransport: DroneTransportFactory {
    private(set) var revokedIDs: [UUID] = []

    func connect(_ request: DroneTransportRequest) async throws -> any DroneConnection {
        throw DroneTransportError.connectionFailed
    }

    func revoke(droneID: UUID) async throws {
        revokedIDs.append(droneID)
    }
}
