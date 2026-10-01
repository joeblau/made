import Foundation

/// What the daemon reports about itself, used for the section's status line.
struct DockerEngineVersion: Sendable, Decodable, Equatable {
    let version: String
    let apiVersion: String
    let os: String

    private enum CodingKeys: String, CodingKey {
        case version = "Version"
        case apiVersion = "ApiVersion"
        case os = "Os"
    }

    init(version: String, apiVersion: String, os: String) {
        self.version = version
        self.apiVersion = apiVersion
        self.os = os
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = UntrustedText.sanitized((try? container.decode(String.self, forKey: .version)) ?? "", limit: 40)
        apiVersion = UntrustedText.sanitized((try? container.decode(String.self, forKey: .apiVersion)) ?? "", limit: 20)
        os = UntrustedText.sanitized((try? container.decode(String.self, forKey: .os)) ?? "", limit: 40)
    }
}

/// A `/events` notification, reduced to what the section acts on. The payload
/// carries far more (network attach, image pulls, health checks); the list only
/// needs to know that container state moved so it can re-read the truth.
struct DockerEngineEvent: Sendable, Decodable {
    let type: String
    let action: String

    private enum CodingKeys: String, CodingKey {
        case type = "Type"
        case action = "Action"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? container.decode(String.self, forKey: .type)) ?? ""
        action = (try? container.decode(String.self, forKey: .action)) ?? ""
    }
}

/// The Engine API surface the Docker section depends on. ``DockerEngineClient``
/// is the only production conformer; the seam exists so store behavior around
/// slow, overlapping, or late replies can be exercised without a live daemon.
protocol DockerEngineAPI: Sendable {
    func version() async throws -> DockerEngineVersion
    func containers() async throws -> [DockerContainerSummary]
    func perform(_ action: DockerContainerAction, containerID: String) async throws
    func containerEvents() -> AsyncThrowingStream<DockerEngineEvent, any Error>
}

/// A read/write client for the local Docker Engine API.
///
/// Scope is deliberately narrow: list containers, move them between states, and
/// watch for changes. Pilot does not build images, manage volumes, or reach
/// remote daemons — anything beyond the local lifecycle belongs in the terminal.
struct DockerEngineClient: DockerEngineAPI {
    /// Pinned so the response shapes this file decodes stay fixed. 1.43 ships
    /// with Docker Engine 24 (2023) and is accepted by every current runtime,
    /// including Colima and Podman's compatibility service; newer daemons
    /// down-negotiate rather than reject it.
    static let apiVersion = "v1.43"

    let transport: DockerSocketTransport

    init(socketPath: String) {
        self.transport = DockerSocketTransport(socketPath: socketPath)
    }

    init(transport: DockerSocketTransport) {
        self.transport = transport
    }

    var socketPath: String { transport.socketPath }

    /// Handshake used to decide whether the section has an engine at all.
    /// `/version` is unversioned so it answers even when the daemon predates
    /// ``apiVersion``, which turns "too old" into a clear message instead of a
    /// 400 on the first list.
    func version() async throws -> DockerEngineVersion {
        let response = try await transport.send(DockerRequest(path: "/version"))
        try Self.check(response)
        return try JSONDecoder().decode(DockerEngineVersion.self, from: response.body)
    }

    /// Every container, running or not — the list has its own "show stopped"
    /// filter, and a stopped container is the one you most often came to start.
    func containers() async throws -> [DockerContainerSummary] {
        let response = try await transport.send(
            DockerRequest(path: "/\(Self.apiVersion)/containers/json?all=1")
        )
        try Self.check(response)
        return try JSONDecoder().decode([DockerContainerSummary].self, from: response.body)
    }

    func perform(_ action: DockerContainerAction, containerID: String) async throws {
        guard let escaped = Self.escape(containerID) else {
            throw DockerTransportError.malformedResponse("unusable container id")
        }
        let request: DockerRequest = switch action {
        case .start:
            DockerRequest(method: "POST", path: "/\(Self.apiVersion)/containers/\(escaped)/start")
        case .stop:
            DockerRequest(method: "POST", path: "/\(Self.apiVersion)/containers/\(escaped)/stop?t=10")
        case .restart:
            DockerRequest(method: "POST", path: "/\(Self.apiVersion)/containers/\(escaped)/restart?t=10")
        case .remove:
            // `force=1` so a running container can be removed in one step, which
            // is what the confirmation dialog promises. Volumes are left alone —
            // deleting a database's data is never implied by "remove container".
            DockerRequest(method: "DELETE", path: "/\(Self.apiVersion)/containers/\(escaped)?force=1&v=0")
        }

        var transport = transport
        // Stop and restart wait on the container's own grace period before the
        // daemon answers, so these need more headroom than a list call.
        transport.timeout = .seconds(45)
        let response = try await transport.send(request)

        // 304 means "already in that state" — starting a running container is a
        // no-op, not a failure worth surfacing.
        guard response.status != 304 else { return }
        try Self.check(response)
    }

    /// Live container-lifecycle notifications. Never completes on its own; the
    /// stream ends when the consuming task is cancelled or the daemon goes away.
    func containerEvents() -> AsyncThrowingStream<DockerEngineEvent, any Error> {
        let filters = #"{"type":["container"]}"#
        let encoded = filters.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let request = DockerRequest(path: "/\(Self.apiVersion)/events?filters=\(encoded)")

        // The daemon streams one JSON object per line, indefinitely, so this
        // read has no timeout and no total-size ceiling to trip over; the parser
        // still bounds each individual line.
        var streaming = transport
        streaming.maxResponseBytes = .max

        // Built with `makeStream` rather than the closure initializer so the
        // reader task is spawned from this (concurrency-checked) scope instead
        // of from inside a non-`Sendable` builder closure.
        let (stream, continuation) = AsyncThrowingStream<DockerEngineEvent, any Error>.makeStream()
        let maxPending = Self.maxPendingEventBytes
        let task = Task {
            var buffer = Data()
            do {
                for try await event in streaming.stream(request) {
                    switch event {
                    case .head(let status, _):
                        guard (200..<300).contains(status) else {
                            throw DockerTransportError.httpStatus(code: status, message: "")
                        }
                    case .body(let chunk):
                        buffer.append(chunk)
                        guard buffer.count <= maxPending else {
                            throw DockerTransportError.responseTooLarge(maxPending)
                        }
                        while let newline = buffer.firstIndex(of: 0x0A) {
                            let line = Data(buffer[buffer.startIndex..<newline])
                            buffer.removeSubrange(buffer.startIndex...newline)
                            guard !line.isEmpty,
                                  let decoded = try? JSONDecoder().decode(DockerEngineEvent.self, from: line)
                            else { continue }
                            continuation.yield(decoded)
                        }
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// A single event line should be well under a kilobyte. This ceiling exists
    /// so a daemon that streams bytes without ever sending a newline can't grow
    /// the buffer without bound.
    private static let maxPendingEventBytes = 1024 * 1024

    private static func check(_ response: DockerResponse) throws {
        guard !response.isSuccess else { return }
        throw DockerTransportError.httpStatus(code: response.status, message: response.failureMessage)
    }

    /// Container IDs come back from the daemon as hex, but a caller could pass a
    /// name. Percent-encode defensively so nothing can smuggle a second request
    /// line or an unintended path segment into the URL.
    private static func escape(_ identifier: String) -> String? {
        guard !identifier.isEmpty else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._")
        return identifier.addingPercentEncoding(withAllowedCharacters: allowed)
    }
}
