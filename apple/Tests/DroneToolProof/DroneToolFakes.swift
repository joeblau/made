import CryptoKit
import Foundation

actor DroneFakeEngine: DroneToolEngine {
    private let lease: DroneToolLease
    private var files: [String: Data]
    private(set) var editCount = 0

    init(lease: DroneToolLease, files: [String: Data]) {
        self.lease = lease
        self.files = files
    }

    func read(
        _ request: DroneToolReadRequest,
        context: DroneToolRequestContext
    ) async throws -> DroneToolReadResult {
        try authorize(context)
        let data = files[request.path] ?? Data()
        return DroneToolReadResult(
            data: data.prefix(request.maxBytes),
            truncated: data.count > request.maxBytes
        )
    }

    func edit(
        _ request: DroneToolEditRequest,
        context: DroneToolRequestContext
    ) async throws -> DroneToolEditResult {
        try authorize(context)
        guard var data = files[request.path] else { throw DroneProtocolError.invalidIdentifier }
        if let expectedSHA256 = request.expectedSHA256 {
            guard Self.digest(data) == expectedSHA256 else {
                throw DroneProtocolError.invalidState
            }
        }
        guard let range = data.range(of: request.oldData),
              data.range(of: request.oldData, in: range.upperBound ..< data.endIndex) == nil
        else { throw DroneProtocolError.invalidState }
        data.replaceSubrange(range, with: request.newData)
        files[request.path] = data
        editCount += 1
        return DroneToolEditResult(bytesWritten: data.count, sha256: Self.digest(data))
    }

    func run(
        _ request: DroneToolProcessRequest,
        context: DroneToolRequestContext
    ) async throws -> AsyncThrowingStream<DroneToolEvent, Error> {
        try authorize(context)
        let first = Data("\(request.executable) first\n".utf8)
        let second = Data("\(request.executable) second\n".utf8)
        return Self.stream([
            .output(DroneToolOutputBody(
                sequence: 0,
                offset: 0,
                stream: .standardOutput,
                data: first,
                truncated: false
            )),
            .output(DroneToolOutputBody(
                sequence: 1,
                offset: UInt64(first.count),
                stream: .standardOutput,
                data: second,
                truncated: false
            )),
            .completed(DroneToolCompletionBody(status: .succeeded, exitCode: 0, finalSequence: 2)),
        ])
    }

    func diff(
        _ request: DroneToolDiffRequest,
        context: DroneToolRequestContext
    ) async throws -> AsyncThrowingStream<DroneToolEvent, Error> {
        try authorize(context)
        let data = Data("diff --git a/Sources/App.swift b/Sources/App.swift\n+updated\n".utf8)
        return Self.stream([
            .output(DroneToolOutputBody(
                sequence: 0,
                offset: 0,
                stream: .diff,
                data: data,
                truncated: false
            )),
            .completed(DroneToolCompletionBody(status: .succeeded, exitCode: 0, finalSequence: 1)),
        ])
    }

    func cancel(context: DroneToolRequestContext, operationRequestID: UUID) async throws {
        try authorize(context)
    }

    func file(_ path: String) -> Data? { files[path] }

    private func authorize(_ context: DroneToolRequestContext) throws {
        guard context.lease == lease else { throw DroneProtocolError.unauthorized }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func stream(_ events: [DroneToolEvent]) -> AsyncThrowingStream<DroneToolEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

actor DroneFakeTransport: DroneToolTransport {
    let authenticatedControllerID: UUID
    let authenticatedDroneID: UUID
    let capabilities: Set<String> = ["terminal.v1", "tools.v1"]

    private let lease: DroneToolLease
    private let engine: DroneFakeEngine
    private var requests: [String: DroneEnvelope] = [:]
    private var unaryResponses: [String: DroneEnvelope] = [:]
    private var histories: [UUID: [DroneEnvelope]] = [:]
    private var disconnectUnaryKeys: Set<String> = []
    private var disconnectStreamingKeys: Set<String> = []
    private(set) var requestCount = 0
    private(set) var attachCount = 0
    private(set) var lastAttach: DroneToolAttachBody?

    init(
        lease: DroneToolLease,
        engine: DroneFakeEngine,
        authenticatedControllerID: UUID? = nil,
        authenticatedDroneID: UUID? = nil
    ) {
        self.lease = lease
        self.engine = engine
        self.authenticatedControllerID = authenticatedControllerID ?? lease.controllerID
        self.authenticatedDroneID = authenticatedDroneID ?? lease.droneID
    }

    func disconnectNextUnaryResponse(idempotencyKey: String) {
        disconnectUnaryKeys.insert(idempotencyKey)
    }

    func disconnectNextStream(idempotencyKey: String) {
        disconnectStreamingKeys.insert(idempotencyKey)
    }

    func perform(
        _ request: DroneEnvelope
    ) async throws -> AsyncThrowingStream<DroneEnvelope, Error> {
        requestCount += 1
        try DroneToolWorkerAuthorization.authorize(
            request,
            authenticatedControllerID: authenticatedControllerID,
            authenticatedDroneID: authenticatedDroneID,
            approvedLease: lease,
            now: 1
        )
        guard let key = request.idempotencyKey, let requestID = request.requestID else {
            throw DroneProtocolError.malformedMessage
        }
        if let existing = requests[key], existing != request {
            throw DroneProtocolError.idempotencyConflict
        }

        if request.kind == .toolAttach {
            guard case .toolAttach(let attach) = request.body,
                  let history = histories[attach.originalRequestID]
            else { throw DroneProtocolError.invalidIdentifier }
            attachCount += 1
            lastAttach = attach
            var offsets = DroneToolStreamOffsets()
            for envelope in history.prefix(Int(attach.nextSequence)) {
                guard case .toolOutput(let output) = envelope.body else {
                    throw DroneProtocolError.malformedMessage
                }
                offsets[output.stream] += UInt64(output.data.count)
            }
            guard offsets == attach.offsets else { throw DroneToolClientError.outputGap }
            let attached = DroneEnvelope(
                kind: .toolAttached,
                requestID: requestID,
                lease: lease,
                idempotencyKey: key
            )
            return Self.stream([attached] + history.dropFirst(Int(attach.nextSequence)))
        }

        if requests[key] != nil {
            if let response = unaryResponses[key] { return Self.stream([response]) }
            if let history = histories[requestID] {
                let accepted = DroneEnvelope(
                    kind: .toolAccepted,
                    requestID: requestID,
                    lease: lease,
                    idempotencyKey: key
                )
                return Self.stream([accepted] + history)
            }
            throw DroneProtocolError.invalidState
        }
        requests[key] = request

        switch request.body {
        case .toolRead(let read):
            let result = try await engine.read(read, context: context(request))
            let response = DroneEnvelope(
                kind: .toolReadResult,
                requestID: requestID,
                lease: lease,
                idempotencyKey: key,
                body: .toolReadResult(result)
            )
            unaryResponses[key] = response
            return Self.stream([response])
        case .toolEdit(let edit):
            let result = try await engine.edit(edit, context: context(request))
            let response = DroneEnvelope(
                kind: .toolEditResult,
                requestID: requestID,
                lease: lease,
                idempotencyKey: key,
                body: .toolEditResult(result)
            )
            unaryResponses[key] = response
            if disconnectUnaryKeys.remove(key) != nil {
                return Self.stream([], error: .disconnected)
            }
            return Self.stream([response])
        case .toolRun(let process):
            let events = try await collect(engine.run(process, context: context(request)))
            let history = envelopes(events, request: request)
            histories[requestID] = history
            return streamingResponse(request: request, history: history)
        case .toolDiff(let diff):
            let events = try await collect(engine.diff(diff, context: context(request)))
            let history = envelopes(events, request: request)
            histories[requestID] = history
            return streamingResponse(request: request, history: history)
        default:
            throw DroneProtocolError.malformedMessage
        }
    }

    private func streamingResponse(
        request: DroneEnvelope,
        history: [DroneEnvelope]
    ) -> AsyncThrowingStream<DroneEnvelope, Error> {
        let accepted = DroneEnvelope(
            kind: .toolAccepted,
            requestID: request.requestID,
            lease: lease,
            idempotencyKey: request.idempotencyKey
        )
        if let key = request.idempotencyKey, disconnectStreamingKeys.remove(key) != nil,
           let first = history.first {
            return Self.stream([accepted, first], error: .disconnected)
        }
        return Self.stream([accepted] + history)
    }

    private func context(_ request: DroneEnvelope) -> DroneToolRequestContext {
        DroneToolRequestContext(
            lease: lease,
            requestID: request.requestID ?? UUID(),
            idempotencyKey: request.idempotencyKey ?? ""
        )
    }

    private func envelopes(
        _ events: [DroneToolEvent],
        request: DroneEnvelope
    ) -> [DroneEnvelope] {
        events.map { event in
            switch event {
            case .output(let output):
                DroneEnvelope(
                    kind: .toolOutput,
                    requestID: request.requestID,
                    lease: lease,
                    idempotencyKey: request.idempotencyKey,
                    body: .toolOutput(output)
                )
            case .completed(let completion):
                DroneEnvelope(
                    kind: .toolCompletion,
                    requestID: request.requestID,
                    lease: lease,
                    idempotencyKey: request.idempotencyKey,
                    body: .toolCompletion(completion)
                )
            }
        }
    }

    private func collect(
        _ stream: AsyncThrowingStream<DroneToolEvent, Error>
    ) async throws -> [DroneToolEvent] {
        var events: [DroneToolEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    private static func stream(
        _ envelopes: [DroneEnvelope],
        error: DroneProtocolError? = nil
    ) -> AsyncThrowingStream<DroneEnvelope, Error> {
        AsyncThrowingStream { continuation in
            for envelope in envelopes { continuation.yield(envelope) }
            if let error { continuation.finish(throwing: error) } else { continuation.finish() }
        }
    }
}

actor DroneCancellationTransport: DroneToolTransport {
    let authenticatedControllerID: UUID
    let authenticatedDroneID: UUID
    let capabilities: Set<String> = ["tools.v1"]

    private let lease: DroneToolLease
    private var originalRequest: DroneEnvelope?
    private var continuation: AsyncThrowingStream<DroneEnvelope, Error>.Continuation?
    private(set) var activeProcessCount = 0
    private(set) var cancellationCount = 0

    init(lease: DroneToolLease) {
        self.lease = lease
        authenticatedControllerID = lease.controllerID
        authenticatedDroneID = lease.droneID
    }

    func perform(
        _ request: DroneEnvelope
    ) async throws -> AsyncThrowingStream<DroneEnvelope, Error> {
        try DroneToolWorkerAuthorization.authorize(
            request,
            authenticatedControllerID: authenticatedControllerID,
            authenticatedDroneID: authenticatedDroneID,
            approvedLease: lease,
            now: 1
        )
        switch request.body {
        case .toolRun:
            originalRequest = request
            activeProcessCount = 1
            let (stream, continuation) = AsyncThrowingStream<DroneEnvelope, Error>.makeStream()
            self.continuation = continuation
            continuation.yield(DroneEnvelope(
                kind: .toolAccepted,
                requestID: request.requestID,
                lease: lease,
                idempotencyKey: request.idempotencyKey
            ))
            return stream
        case .toolCancel(let cancel):
            guard let originalRequest, originalRequest.requestID == cancel.operationRequestID else {
                throw DroneProtocolError.invalidIdentifier
            }
            cancellationCount += 1
            activeProcessCount = 0
            continuation?.yield(DroneEnvelope(
                kind: .toolCompletion,
                requestID: originalRequest.requestID,
                lease: lease,
                idempotencyKey: originalRequest.idempotencyKey,
                body: .toolCompletion(DroneToolCompletionBody(
                    status: .cancelled,
                    exitCode: nil,
                    finalSequence: 0
                ))
            ))
            continuation?.finish()
            continuation = nil
            return AsyncThrowingStream { continuation in
                continuation.yield(DroneEnvelope(
                    kind: .toolCancelled,
                    requestID: request.requestID,
                    lease: lease,
                    idempotencyKey: request.idempotencyKey
                ))
                continuation.finish()
            }
        default:
            throw DroneProtocolError.malformedMessage
        }
    }
}

actor DroneAdversarialTransport: DroneToolTransport {
    enum Mode {
        case gap
        case outputLimit
        case wrongLease
    }

    let authenticatedControllerID: UUID
    let authenticatedDroneID: UUID
    let capabilities: Set<String> = ["tools.v1"]
    private let mode: Mode

    init(lease: DroneToolLease, mode: Mode) {
        authenticatedControllerID = lease.controllerID
        authenticatedDroneID = lease.droneID
        self.mode = mode
    }

    func perform(
        _ request: DroneEnvelope
    ) async throws -> AsyncThrowingStream<DroneEnvelope, Error> {
        let responseLease = mode == .wrongLease
            ? DroneToolLease(
                id: request.lease?.id ?? UUID(),
                controllerID: request.lease?.controllerID ?? UUID(),
                droneID: UUID(),
                jobID: request.lease?.jobID ?? DroneJobID(),
                workspaceID: request.lease?.workspaceID ?? UUID(),
                expiresAt: 1_000
            )
            : request.lease
        let accepted = DroneEnvelope(
            kind: .toolAccepted,
            requestID: request.requestID,
            lease: responseLease,
            idempotencyKey: request.idempotencyKey
        )
        if mode == .wrongLease { return Self.stream([accepted]) }
        let outputs: [DroneToolOutputBody] = switch mode {
        case .gap:
            [DroneToolOutputBody(
                sequence: 1,
                offset: 0,
                stream: .standardOutput,
                data: Data("bad".utf8),
                truncated: false
            )]
        case .outputLimit:
            [
                DroneToolOutputBody(
                    sequence: 0,
                    offset: 0,
                    stream: .standardOutput,
                    data: Data("ab".utf8),
                    truncated: false
                ),
                DroneToolOutputBody(
                    sequence: 1,
                    offset: 2,
                    stream: .standardOutput,
                    data: Data("cd".utf8),
                    truncated: false
                ),
                DroneToolOutputBody(
                    sequence: 2,
                    offset: 4,
                    stream: .standardOutput,
                    data: Data("ef".utf8),
                    truncated: false
                ),
            ]
        case .wrongLease:
            []
        }
        let envelopes = outputs.map {
            DroneEnvelope(
                kind: .toolOutput,
                requestID: request.requestID,
                lease: responseLease,
                idempotencyKey: request.idempotencyKey,
                body: .toolOutput($0)
            )
        }
        return Self.stream([accepted] + envelopes)
    }

    private static func stream(
        _ envelopes: [DroneEnvelope]
    ) -> AsyncThrowingStream<DroneEnvelope, Error> {
        AsyncThrowingStream { continuation in
            for envelope in envelopes { continuation.yield(envelope) }
            continuation.finish()
        }
    }
}
