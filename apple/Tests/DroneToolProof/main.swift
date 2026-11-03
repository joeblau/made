import Foundation

@main
enum DroneToolProof {
    static func main() async throws {
        let lease = DroneToolLease(
            id: UUID(),
            controllerID: UUID(),
            droneID: UUID(),
            jobID: DroneJobID(),
            workspaceID: UUID(),
            expiresAt: 1_000
        )
        let engine = DroneFakeEngine(lease: lease, files: [
            "Sources/App.swift": Data("let value = \"before\"\n".utf8),
        ])
        let transport = DroneFakeTransport(lease: lease, engine: engine)
        let client = try DroneToolClient(transport: transport, lease: lease, now: 1)
        let driver = DroneAgentDriver(client: client)
        let report = try await driver.perform(DroneAgentPlan(
            path: "Sources/App.swift",
            oldData: Data("before".utf8),
            newData: Data("after".utf8),
            build: DroneToolProcessRequest(executable: "swiftc"),
            test: DroneToolProcessRequest(executable: "swift"),
            idempotencyKeyPrefix: "agent-proof-00001"
        ))
        expect(report.build.completion.status == .succeeded, "build failed")
        expect(report.test.completion.status == .succeeded, "test failed")
        expect(report.diff.range(of: Data("+updated".utf8)) != nil, "diff output missing")
        let edited = await engine.file("Sources/App.swift")
        let initialEditCount = await engine.editCount
        expect(edited == Data("let value = \"after\"\n".utf8), "edit did not land")
        expect(initialEditCount == 1, "driver duplicated edit")

        await transport.disconnectNextUnaryResponse(idempotencyKey: "disconnect-edit-0001")
        _ = try await client.edit(
            DroneToolEditRequest(
                path: "Sources/App.swift",
                expectedSHA256: nil,
                oldData: Data("after".utf8),
                newData: Data("committed".utf8)
            ),
            idempotencyKey: "disconnect-edit-0001"
        )
        let retriedEditCount = await engine.editCount
        expect(retriedEditCount == 2, "disconnect-after-commit duplicated edit")

        await transport.disconnectNextStream(idempotencyKey: "resume-stream-00001")
        let events = ProofEventCollector()
        let completion = try await client.run(
            DroneToolProcessRequest(executable: "swiftc"),
            idempotencyKey: "resume-stream-00001",
            onEvent: { event in await events.record(event) }
        )
        let outputCount = await events.outputCount
        let attachCount = await transport.attachCount
        expect(completion.status == .succeeded, "resumed command failed")
        expect(outputCount == 2, "stream replay duplicated or dropped output")
        expect(attachCount == 1, "stream did not resume with attach")
        let attach = await transport.lastAttach
        expect(attach?.nextSequence == 1, "stream resumed at wrong sequence")

        let cancellationTransport = DroneCancellationTransport(lease: lease)
        let cancellationClient = try DroneToolClient(transport: cancellationTransport, lease: lease, now: 1)
        let command = Task {
            try await cancellationClient.run(DroneToolProcessRequest(executable: "sleep"))
        }
        for _ in 0..<20 {
            if await cancellationTransport.activeProcessCount == 1 { break }
            await Task.yield()
        }
        command.cancel()
        for _ in 0..<50 {
            if await cancellationTransport.cancellationCount == 1 { break }
            await Task.yield()
        }
        _ = try? await command.value
        let activeProcessCount = await cancellationTransport.activeProcessCount
        let cancellationCount = await cancellationTransport.cancellationCount
        expect(activeProcessCount == 0, "cancellation orphaned process")
        expect(cancellationCount == 1, "cancellation was not delivered")

        try await expectFailure(mode: .gap, lease: lease, expected: .outputGap)
        try await expectFailure(mode: .outputLimit, lease: lease, expected: .outputLimit)
        try await expectFailure(mode: .wrongLease, lease: lease, expected: .responseMismatch)
        do {
            _ = try await client.read(path: "../etc/passwd")
            throw ProofError.failed("path traversal accepted")
        } catch DroneProtocolError.unauthorized {}
        do {
            try DroneToolValidation.validate(process: DroneToolProcessRequest(
                executable: "env",
                environment: ["SECRET_TOKEN": "do-not-forward"]
            ))
            throw ProofError.failed("secret environment forwarded")
        } catch DroneProtocolError.unauthorized {}
        print("Drone tool proof passed: driver cycle, idempotency, resume, cancellation, leases, bounds, and adversarial inputs.")
    }

    private static func expectFailure(
        mode: DroneAdversarialTransport.Mode,
        lease: DroneToolLease,
        expected: DroneToolClientError
    ) async throws {
        let transport = DroneAdversarialTransport(lease: lease, mode: mode)
        let client = try DroneToolClient(transport: transport, lease: lease, now: 1)
        do {
            _ = try await client.run(DroneToolProcessRequest(executable: "swiftc", outputLimit: 3))
            throw ProofError.failed("adversarial stream succeeded")
        } catch let error as DroneToolClientError {
            expect(error == expected, "unexpected adversarial error \(error)")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("Drone tool proof failed: \(message)\n".utf8))
            exit(1)
        }
    }
}

private actor ProofEventCollector {
    private(set) var outputCount = 0
    func record(_ event: DroneToolEvent) {
        if case .output = event { outputCount += 1 }
    }
}

private enum ProofError: Error {
    case failed(String)
}
