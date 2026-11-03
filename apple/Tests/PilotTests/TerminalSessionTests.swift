import Foundation
import XCTest
@testable import Pilot

@MainActor
final class TerminalSessionTests: XCTestCase {
    func testLegacyPaneDefaultsToLocalDestination() {
        let pane = Pane(kind: .terminal)
        XCTAssertEqual(pane.terminalDestination, .local)
        XCTAssertTrue(pane.terminalSession is LocalTerminalSession)
        XCTAssertEqual(
            TerminalDestination.restored(kindRaw: nil, droneIDRaw: nil, remoteSessionIDRaw: nil),
            .local
        )
    }

    func testMalformedPersistedDestinationIsRecoverablyInvalid() {
        let destination = TerminalDestination.restored(
            kindRaw: "drone",
            droneIDRaw: "not-a-uuid",
            remoteSessionIDRaw: nil
        )
        XCTAssertEqual(destination.kind, .invalid)
        XCTAssertFalse(destination.isValid)
    }

    func testLiveSessionCannotMoveToAnotherDestination() {
        let provider = TerminalSessionProvider()
        let pane = Pane(kind: .terminal)
        let original = provider.session(for: pane)
        XCTAssertTrue(original is LocalTerminalSession)

        pane.terminalDestinationRaw = TerminalDestinationKind.drone.rawValue
        pane.terminalDroneIDRaw = UUID().uuidString
        let changed = provider.session(for: pane)
        let unavailable = changed as? UnavailableTerminalSession
        XCTAssertEqual(unavailable?.failure, .destinationChanged)
        guard case .unavailable(let failure)? = unavailable?.bootstrap(workingDirectory: nil) else {
            return XCTFail("Expected an unavailable bootstrap")
        }
        XCTAssertEqual(failure, .destinationChanged)
    }

    func testRemoteRestoreAdoptsStableSessionAndReconnectGeneration() async throws {
        let droneID = UUID()
        let remoteID = UUID()
        let client = TerminalFakeDroneClient(droneID: droneID, remoteID: remoteID)
        let provider = TerminalSessionProvider { _ in client }
        let pane = Pane(
            kind: .terminal,
            terminalDestination: .drone(droneID: droneID)
        )

        let restoration = try await provider.restore(pane: pane)
        XCTAssertEqual(restoration.remoteSessionID, remoteID)
        XCTAssertEqual(pane.terminalDestination.remoteSessionID, remoteID)
        XCTAssertEqual(client.attachCount, 1)

        let first = provider.session(for: pane)
        let reconnected = provider.reconnect(pane: pane)
        XCTAssertEqual(
            reconnected.identity.generation,
            first.identity.generation + 1
        )
        XCTAssertNotEqual(first.identity.runtimeCacheKey, reconnected.identity.runtimeCacheKey)
        try await provider.restore(pane: pane)
        XCTAssertEqual(client.createCount, 1)
        XCTAssertEqual(client.attachCount, 2)
    }

    func testMissingDroneClientNeverUsesLocalSession() {
        let droneID = UUID()
        let provider = TerminalSessionProvider { _ in nil }
        let pane = Pane(
            kind: .terminal,
            terminalDestination: .drone(droneID: droneID)
        )
        let session = provider.session(for: pane)
        XCTAssertEqual(
            (session as? UnavailableTerminalSession)?.failure,
            .droneUnavailable(droneID)
        )
        XCTAssertFalse(session is LocalTerminalSession)
    }
}

private final class TerminalFakeDroneClient: DroneTerminalClient, @unchecked Sendable {
    let droneID: UUID
    private let remoteID: UUID
    private(set) var createCount = 0
    private(set) var attachCount = 0

    init(droneID: UUID, remoteID: UUID) {
        self.droneID = droneID
        self.remoteID = remoteID
    }

    func createTerminal(
        workingDirectory: String?,
        generation: UInt64,
        requestID: UUID
    ) async throws -> UUID {
        createCount += 1
        return remoteID
    }

    func attachTerminal(_ reference: DroneTerminalSessionReference) async throws {
        attachCount += 1
    }

    func sendInput(_ data: Data, to reference: DroneTerminalSessionReference) async throws {}
    func foregroundActivity(for reference: DroneTerminalSessionReference) async throws -> TerminalProcessActivity {
        .idle
    }
    func currentDirectory(for reference: DroneTerminalSessionReference) async throws -> String? { nil }
    func interrupt(_ reference: DroneTerminalSessionReference) async throws {}
    func detach(_ reference: DroneTerminalSessionReference) async throws {}
    func close(_ reference: DroneTerminalSessionReference) async throws {}
}
