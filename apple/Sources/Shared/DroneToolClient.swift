import Foundation

protocol DroneToolTransport: Sendable {
    var authenticatedControllerID: UUID { get }
    var authenticatedDroneID: UUID { get }
    var capabilities: Set<String> { get }

    func perform(
        _ request: DroneEnvelope
    ) async throws -> AsyncThrowingStream<DroneEnvelope, Error>
}

enum DroneToolClientError: Error, Equatable, Sendable {
    case unexpectedResponse
    case responseMismatch
    case outputGap
    case outputLimit
    case remote(code: String, retryable: Bool)
    case ambiguous(requestID: UUID, idempotencyKey: String)
}

struct DroneToolClient: Sendable {
    let transport: any DroneToolTransport
    let lease: DroneToolLease

    init(
        transport: any DroneToolTransport,
        lease: DroneToolLease,
        now: TimeInterval = Date().timeIntervalSinceReferenceDate
    ) throws {
        guard transport.capabilities.contains("tools.v1") else {
            throw DroneProtocolError.negotiationFailed
        }
        try lease.validate(
            authenticatedControllerID: transport.authenticatedControllerID,
            authenticatedDroneID: transport.authenticatedDroneID,
            expectedJobID: lease.jobID,
            expectedWorkspaceID: lease.workspaceID,
            now: now
        )
        self.transport = transport
        self.lease = lease
    }

    func read(
        path: String,
        maxBytes: Int = DroneLimits.maxToolReadBytes,
        idempotencyKey: String = Self.makeIdempotencyKey()
    ) async throws -> DroneToolReadResult {
        let request = makeRequest(
            kind: .toolRead,
            idempotencyKey: idempotencyKey,
            body: .toolRead(DroneToolReadRequest(path: path, maxBytes: maxBytes))
        )
        let response = try await performUnary(request, expectedKind: .toolReadResult)
        guard case .toolReadResult(let result) = response.body else {
            throw DroneToolClientError.unexpectedResponse
        }
        guard result.data.count <= maxBytes else { throw DroneToolClientError.outputLimit }
        return result
    }

    func edit(
        _ edit: DroneToolEditRequest,
        idempotencyKey: String = Self.makeIdempotencyKey()
    ) async throws -> DroneToolEditResult {
        let request = makeRequest(
            kind: .toolEdit,
            idempotencyKey: idempotencyKey,
            body: .toolEdit(edit)
        )
        let response = try await performUnary(request, expectedKind: .toolEditResult)
        guard case .toolEditResult(let result) = response.body else {
            throw DroneToolClientError.unexpectedResponse
        }
        return result
    }

    func run(
        _ process: DroneToolProcessRequest,
        idempotencyKey: String = Self.makeIdempotencyKey(),
        onEvent: @Sendable (DroneToolEvent) async throws -> Void = { _ in }
    ) async throws -> DroneToolCompletionBody {
        let request = makeRequest(
            kind: .toolRun,
            idempotencyKey: idempotencyKey,
            body: .toolRun(process)
        )
        return try await performStreaming(
            request,
            outputLimit: process.outputLimit,
            onEvent: onEvent
        )
    }

    func diff(
        _ diff: DroneToolDiffRequest,
        idempotencyKey: String = Self.makeIdempotencyKey(),
        onEvent: @Sendable (DroneToolEvent) async throws -> Void = { _ in }
    ) async throws -> DroneToolCompletionBody {
        let request = makeRequest(
            kind: .toolDiff,
            idempotencyKey: idempotencyKey,
            body: .toolDiff(diff)
        )
        return try await performStreaming(
            request,
            outputLimit: diff.maxBytes,
            onEvent: onEvent
        )
    }

    func cancel(
        operationRequestID: UUID,
        idempotencyKey: String = Self.makeIdempotencyKey()
    ) async throws {
        let request = makeRequest(
            kind: .toolCancel,
            idempotencyKey: idempotencyKey,
            body: .toolCancel(DroneToolCancelBody(operationRequestID: operationRequestID))
        )
        _ = try await performUnary(request, expectedKind: .toolCancelled)
    }

    static func makeIdempotencyKey() -> String {
        (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
    }

    private func makeRequest(
        kind: DroneMessageKind,
        idempotencyKey: String,
        body: DroneEnvelope.Body,
        requestID: UUID = UUID()
    ) -> DroneEnvelope {
        DroneEnvelope(
            kind: kind,
            requestID: requestID,
            lease: lease,
            idempotencyKey: idempotencyKey,
            body: body
        )
    }

    private func performUnary(
        _ request: DroneEnvelope,
        expectedKind: DroneMessageKind
    ) async throws -> DroneEnvelope {
        _ = try DroneProtocolCodec.encode(request)
        for attempt in 0 ... DroneLimits.maxToolReconnectAttempts {
            do {
                let stream = try await transport.perform(request)
                var iterator = stream.makeAsyncIterator()
                guard let response = try await iterator.next() else {
                    throw DroneToolClientError.unexpectedResponse
                }
                try validate(response, matches: request)
                guard response.kind == expectedKind,
                      try await iterator.next() == nil
                else { throw DroneToolClientError.unexpectedResponse }
                return response
            } catch let error as DroneProtocolError where error == .disconnected {
                if attempt == DroneLimits.maxToolReconnectAttempts {
                    throw DroneToolClientError.ambiguous(
                        requestID: try requireRequestID(request),
                        idempotencyKey: request.idempotencyKey ?? ""
                    )
                }
            }
        }
        throw DroneToolClientError.unexpectedResponse
    }

    private func performStreaming(
        _ request: DroneEnvelope,
        outputLimit: Int,
        onEvent: @Sendable (DroneToolEvent) async throws -> Void
    ) async throws -> DroneToolCompletionBody {
        _ = try DroneProtocolCodec.encode(request)
        let operationRequestID = try requireRequestID(request)
        let operationKey = request.idempotencyKey ?? ""
        let cancellationKey = Self.makeIdempotencyKey()
        return try await withTaskCancellationHandler {
            var state = DroneToolStreamState(outputLimit: outputLimit)
            var currentRequest = request
            var reconnectAttempts = 0
            while true {
                do {
                    let stream = try await transport.perform(currentRequest)
                    var iterator = stream.makeAsyncIterator()
                    guard let accepted = try await iterator.next() else {
                        throw DroneToolClientError.unexpectedResponse
                    }
                    try validate(accepted, matches: currentRequest)
                    let expectedHeader: DroneMessageKind = currentRequest.kind == .toolAttach
                        ? .toolAttached
                        : .toolAccepted
                    guard accepted.kind == expectedHeader else {
                        throw DroneToolClientError.unexpectedResponse
                    }

                    while let envelope = try await iterator.next() {
                        try validate(
                            envelope,
                            requestID: operationRequestID,
                            idempotencyKey: operationKey
                        )
                        switch envelope.body {
                        case .toolOutput(let output):
                            try state.append(output)
                            try await onEvent(.output(output))
                        case .toolCompletion(let completion):
                            guard completion.finalSequence == state.nextSequence else {
                                throw DroneToolClientError.outputGap
                            }
                            guard try await iterator.next() == nil else {
                                throw DroneToolClientError.unexpectedResponse
                            }
                            try await onEvent(.completed(completion))
                            if Task.isCancelled { throw CancellationError() }
                            return completion
                        default:
                            throw DroneToolClientError.unexpectedResponse
                        }
                    }
                    throw DroneProtocolError.disconnected
                } catch let error as DroneProtocolError where error == .disconnected {
                    guard reconnectAttempts < DroneLimits.maxToolReconnectAttempts else {
                        throw DroneToolClientError.ambiguous(
                            requestID: operationRequestID,
                            idempotencyKey: operationKey
                        )
                    }
                    reconnectAttempts += 1
                    currentRequest = makeRequest(
                        kind: .toolAttach,
                        idempotencyKey: Self.makeIdempotencyKey(),
                        body: .toolAttach(DroneToolAttachBody(
                            originalRequestID: operationRequestID,
                            nextSequence: state.nextSequence,
                            offsets: state.offsets
                        ))
                    )
                }
            }
        } onCancel: {
            Task {
                try? await cancel(
                    operationRequestID: operationRequestID,
                    idempotencyKey: cancellationKey
                )
            }
        }
    }

    private func validate(_ response: DroneEnvelope, matches request: DroneEnvelope) throws {
        if response.kind == .error {
            try throwRemoteError(response, requestID: request.requestID)
        }
        try validate(
            response,
            requestID: request.requestID,
            idempotencyKey: request.idempotencyKey
        )
    }

    private func validate(
        _ response: DroneEnvelope,
        requestID: UUID?,
        idempotencyKey: String?
    ) throws {
        if response.kind == .error {
            try throwRemoteError(response, requestID: requestID)
        }
        try response.validate()
        guard response.requestID == requestID,
              response.idempotencyKey == idempotencyKey,
              response.lease == lease,
              response.sessionID == nil
        else { throw DroneToolClientError.responseMismatch }
    }

    private func throwRemoteError(_ response: DroneEnvelope, requestID: UUID?) throws {
        try response.validate()
        guard response.requestID == requestID, case .error(let error) = response.body else {
            throw DroneToolClientError.responseMismatch
        }
        throw DroneToolClientError.remote(code: error.code, retryable: error.retryable)
    }

    private func requireRequestID(_ request: DroneEnvelope) throws -> UUID {
        guard let requestID = request.requestID else {
            throw DroneToolClientError.responseMismatch
        }
        return requestID
    }
}

private struct DroneToolStreamState {
    private(set) var nextSequence: UInt64 = 0
    private(set) var offsets = DroneToolStreamOffsets()
    private var receivedBytes = 0
    let outputLimit: Int

    mutating func append(_ output: DroneToolOutputBody) throws {
        guard output.sequence == nextSequence,
              output.offset == offsets[output.stream]
        else { throw DroneToolClientError.outputGap }
        let (newReceivedBytes, overflow) = receivedBytes.addingReportingOverflow(output.data.count)
        guard !overflow, newReceivedBytes <= outputLimit else {
            throw DroneToolClientError.outputLimit
        }
        let (newSequence, sequenceOverflow) = nextSequence.addingReportingOverflow(1)
        let (newOffset, offsetOverflow) = output.offset.addingReportingOverflow(
            UInt64(output.data.count)
        )
        guard !sequenceOverflow, !offsetOverflow else { throw DroneToolClientError.outputGap }
        receivedBytes = newReceivedBytes
        nextSequence = newSequence
        offsets[output.stream] = newOffset
    }
}
