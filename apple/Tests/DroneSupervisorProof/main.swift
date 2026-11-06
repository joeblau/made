import Foundation

@main
enum DroneSupervisorProof {
    @MainActor
    static func main() async throws {
        let transport = ControlledTransport()
        var forwarded = 0
        let supervisor = DroneWorkerSupervisor(
            record: DroneRecord(name: "Fixture", endpoints: [.hostPort(host: "fixture.invalid", port: 7400)]),
            transport: transport,
            timing: DroneSupervisorTiming(heartbeatInterval: .seconds(60), heartbeatTimeout: .seconds(120)),
            onUpdate: { _ in },
            onEnvelope: { _, _ in forwarded += 1 }
        )
        supervisor.start()
        await wait { transport.connections.count == 1 }
        let retired = transport.connections[0]
        await wait { retired.isReceiving }
        supervisor.retry()
        await wait { transport.connections.count == 2 }
        let replacement = transport.connections[1]
        await wait { replacement.isReceiving }
        expect((supervisor.connection as? ControlledConnection) === replacement, "replacement was not installed")

        // Deliberately emulate a transport that completes receive after cancellation.
        retired.deliver(DroneEnvelope(kind: .heartbeat))
        await settle()
        expect(forwarded == 0, "retired generation forwarded an envelope")
        expect((supervisor.connection as? ControlledConnection) === replacement, "retired cleanup cleared replacement")
        expect(replacement.closeCount == 0, "retired cleanup closed replacement")
        replacement.deliver(DroneEnvelope(kind: .heartbeat))
        await wait { forwarded == 1 }
        await wait { replacement.isReceiving }

        // Repeated flaps must leave exactly the newest generation usable.
        for _ in 0..<4 {
            let previous = transport.connections.last!
            supervisor.retry()
            let count = transport.connections.count
            await wait { transport.connections.count > count }
            let current = transport.connections.last!
            await wait { current.isReceiving }
            previous.fail()
            await settle()
            expect((supervisor.connection as? ControlledConnection) === current, "flapping cleared current connection")
            expect(current.closeCount == 0, "flapping closed current connection")
        }
        let last = transport.connections.last!
        supervisor.stop()
        last.fail()
        await settle()
        expect(supervisor.connection == nil, "stop retained a connection")
        expect(last.closeCount > 0, "stop did not close connection")
        expect(forwarded == 1, "unexpected envelope delivery")
        print("Drone supervisor proof passed: late receive, stale cleanup, replacement liveness, repeated flapping, stop.")
    }

    @MainActor
    static func wait(_ predicate: () -> Bool) async {
        for _ in 0..<2_000 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        fatalError("Timed out waiting for fixture")
    }

    static func settle() async {
        try? await Task.sleep(for: .milliseconds(30))
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
}

@MainActor
private final class ControlledTransport: DroneTransportFactory {
    var connections: [ControlledConnection] = []

    func connect(_ request: DroneTransportRequest) async throws -> any DroneConnection {
        let connection = ControlledConnection()
        connections.append(connection)
        return connection
    }

    func revoke(droneID: UUID) async throws {}
}

private final class ControlledConnection: DroneConnection, @unchecked Sendable {
    let peer = DroneAuthenticatedPeer(
        identityFingerprint: "fixture",
        hardware: .unknown,
        hello: DroneHello(selectedVersion: 1)
    )
    private let lock = NSLock()
    private var receiver: CheckedContinuation<DroneEnvelope, any Error>?
    private var closes = 0
    var isReceiving: Bool { lock.withLock { receiver != nil } }
    var closeCount: Int { lock.withLock { closes } }

    func send(_ envelope: DroneEnvelope) async throws {}

    func receive() async throws -> DroneEnvelope {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { receiver = continuation }
        }
    }

    func close() { lock.withLock { closes += 1 } }

    func deliver(_ envelope: DroneEnvelope) {
        takeReceiver()?.resume(returning: envelope)
    }

    func fail() { takeReceiver()?.resume(throwing: DroneTransportError.disconnected) }

    private func takeReceiver() -> CheckedContinuation<DroneEnvelope, any Error>? {
        lock.withLock {
            defer { receiver = nil }
            return receiver
        }
    }
}
