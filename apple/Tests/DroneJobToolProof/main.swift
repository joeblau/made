import Foundation

@main
struct DroneJobToolProof {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let workspaceID = UUID()
        let jobs = try DroneJobEngine(
            stateURL: root.appendingPathComponent("state"),
            workspaces: DroneWorkspaceRegistry(workspaces: [workspaceID: workspace])
        )
        let engine = DroneJobToolEngine(jobs: jobs, maximumRetainedEntries: 2)
        func context(controller: UUID = UUID(), leaseID: UUID = UUID()) -> DroneToolRequestContext {
            DroneToolRequestContext(
                lease: DroneToolLease(
                    id: leaseID, controllerID: controller, droneID: UUID(), jobID: DroneJobID(),
                    workspaceID: workspaceID, expiresAt: Date().timeIntervalSince1970 + 600
                ), requestID: UUID(), idempotencyKey: "same-idempotency-key"
            )
        }
        let file = workspace.appendingPathComponent("file")
        try Data("old".utf8).write(to: file)
        let request = DroneToolEditRequest(path: "file", expectedSHA256: nil,
                                           oldData: Data("old".utf8), newData: Data("new".utf8))
        let first = context()
        async let one = engine.edit(request, context: first)
        async let two = engine.edit(request, context: first)
        let results = try await (one, two)
        precondition(results.0 == results.1)
        let retry = try await engine.edit(request, context: first)
        precondition(retry == results.0)
        do {
            _ = try await engine.edit(DroneToolEditRequest(path: "file", expectedSHA256: nil,
                oldData: Data("new".utf8), newData: Data("bad".utf8)), context: first)
            fatalError("conflicting retry accepted")
        } catch DroneProtocolError.idempotencyConflict {}
        do {
            _ = try await engine.edit(DroneToolEditRequest(path: "../file", expectedSHA256: nil,
                oldData: Data("old".utf8), newData: Data()), context: first)
            fatalError("cached invalid payload accepted")
        } catch DroneProtocolError.unauthorized {}
        try Data("old".utf8).write(to: file)
        _ = try await engine.edit(request, context: context())
        let contents = try Data(contentsOf: file)
        precondition(contents == Data("new".utf8))
        do {
            _ = try await engine.edit(request, context: context(controller: first.lease.controllerID))
            fatalError("full edit cache accepted new lease")
        } catch DroneProtocolError.resourceLimit {}
        let clock = ProofClock()
        let expiring = DroneJobToolEngine(jobs: jobs, maximumRetainedEntries: 1, now: { clock.value })
        try Data("old".utf8).write(to: file)
        _ = try await expiring.edit(request, context: context(controller: first.lease.controllerID))
        clock.advance(by: DroneLimits.idempotencyLifetime + 1)
        try Data("old".utf8).write(to: file)
        _ = try await expiring.edit(request, context: context(controller: first.lease.controllerID))
        let expiredContents = try Data(contentsOf: file)
        precondition(expiredContents == Data("new".utf8))
        let bounded = DroneJobToolEngine(jobs: jobs, maximumRetainedEntries: 1)
        let running = context()
        let events = try await bounded.run(
            DroneToolProcessRequest(executable: "sleep", arguments: ["30"]), context: running
        )
        do {
            _ = try await bounded.run(DroneToolProcessRequest(executable: "true"), context: context())
            fatalError("operation capacity not enforced before create")
        } catch DroneProtocolError.resourceLimit {}
        do {
            try await bounded.cancel(context: context(controller: running.lease.controllerID),
                                     operationRequestID: running.requestID)
            fatalError("different lease cancelled operation")
        } catch DroneProtocolError.invalidIdentifier {}
        try await bounded.cancel(context: running, operationRequestID: running.requestID)
        for try await event in events {
            if case .completed(let body) = event {
                precondition(body.status == .cancelled)
                try DroneToolValidation.validate(completion: body)
            }
        }
        let replacement = try await bounded.run(DroneToolProcessRequest(executable: "true"), context: context())
        for try await _ in replacement {}
        let paged = DroneJobToolEngine(jobs: jobs, eventPageSize: 1)
        let outputContext = context()
        let outputRequest = DroneToolProcessRequest(
            executable: "sh", arguments: ["-c", "printf abcdef; printf ghijkl >&2"], outputLimit: 8
        )
        func collect(_ stream: AsyncThrowingStream<DroneToolEvent, Error>) async throws -> [DroneToolEvent] {
            var events: [DroneToolEvent] = []
            for try await event in stream { events.append(event) }
            return events
        }
        let firstOutput = try await collect(paged.run(outputRequest, context: outputContext))
        // The durable job is now terminal before the first one-event page is read on replay.
        let replay = try await collect(paged.run(outputRequest, context: outputContext))
        precondition(firstOutput == replay)
        var bytes = 0
        var sequence: UInt64 = 0
        var offsets = DroneToolStreamOffsets()
        var sawTruncation = false
        for event in replay {
            switch event {
            case .output(let body):
                try DroneToolValidation.validate(output: body)
                precondition(body.sequence == sequence && body.offset == offsets[body.stream])
                sequence += 1
                offsets[body.stream] += UInt64(body.data.count)
                bytes += body.data.count
                sawTruncation = sawTruncation || body.truncated
            case .completed(let body):
                precondition(body.finalSequence == sequence && body.status == .succeeded)
            }
        }
        precondition(bytes == 8 && sawTruncation)
        let capped = try await collect(paged.run(DroneToolProcessRequest(
            executable: "printf", arguments: ["123456789"], outputLimit: 4
        ), context: context()))
        precondition(capped.contains { if case .output(let body) = $0 { return body.truncated }; return false })
        let environmentOutput = try await collect(paged.run(DroneToolProcessRequest(
            executable: "sh", arguments: ["-c", "printf '%s' \"$LANG\""],
            environment: ["LANG": "fixture-locale", "HOME": workspace.path]
        ), context: context()))
        let environmentBytes = environmentOutput.reduce(into: Data()) { data, event in
            if case .output(let body) = event { data.append(body.data) }
        }
        precondition(environmentBytes == Data("fixture-locale".utf8))
        do {
            _ = try await paged.diff(DroneToolDiffRequest(contextLines: 0), context: context())
            fatalError("unsupported diff context silently ignored")
        } catch DroneProtocolError.resourceLimit {}
        do {
            _ = try await paged.run(DroneToolProcessRequest(executable: "true", timeout: .infinity), context: context())
            fatalError("non-finite timeout accepted")
        } catch DroneProtocolError.resourceLimit {}
        var gapLimits = DroneJobEngineLimits()
        gapLimits.maximumHistoryEvents = 3
        let gapJobs = try DroneJobEngine(
            stateURL: root.appendingPathComponent("gap-state"),
            workspaces: DroneWorkspaceRegistry(workspaces: [workspaceID: workspace]), limits: gapLimits
        )
        let gapEngine = DroneJobToolEngine(jobs: gapJobs, eventPageSize: 1)
        let gapContext = context()
        let gapRequest = DroneToolProcessRequest(executable: "printf", arguments: ["history"])
        do { _ = try await collect(gapEngine.run(gapRequest, context: gapContext)) } catch DroneJobError.outputGap {}
        do {
            _ = try await collect(gapEngine.run(gapRequest, context: gapContext))
            fatalError("retained history gap silently completed")
        } catch DroneJobError.outputGap {}
        print("Stream proof passed: terminal pagination replay, combined limit, truncation, offsets, cancellation schema")
        print("Drone job tool proof passed: edit validation, scope, conflict, concurrent retry, retention")
    }
}

private final class ProofClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0

    var value: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return time
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        time += interval
    }
}
