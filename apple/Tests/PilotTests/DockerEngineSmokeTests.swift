import Foundation
import Testing
@testable import Pilot

/// End-to-end checks against a real container engine, skipped when none is
/// running so CI and offline machines stay green.
///
/// These exist because the transport's failure modes only appear on a live
/// socket: the daemon answers a `Connection: close` request and then hangs up,
/// which `Network` reports as a *failed* connection state (ENETDOWN) rather
/// than a clean end — and often ahead of the last bytes it has already buffered.
/// Treating that state as an error dropped every complete response on the
/// floor, and no amount of parser-level testing would have shown it.
@Suite("Docker engine smoke", .serialized)
struct DockerEngineSmokeTests {
    private var client: DockerEngineClient? {
        DockerSocketLocator.resolve().map { DockerEngineClient(socketPath: $0) }
    }

    @Test("Event framing preserves fragmented and batched JSON within its bound")
    func eventFraming() throws {
        var framer = DockerEventLineBuffer(maximumPendingBytes: 1024)
        #expect(try framer.append(Data(#"{"Type":"container","Action":"st"#.utf8)).isEmpty)
        let lines = try framer.append(Data("art\"}\n\n{\"Type\":\"container\",\"Action\":\"stop\"}\n".utf8))
        let events = try lines.map { try JSONDecoder().decode(DockerEngineEvent.self, from: $0) }
        #expect(events.map(\.action) == ["start", "stop"])

        var bounded = DockerEventLineBuffer(maximumPendingBytes: 4)
        do {
            _ = try bounded.append(Data("12345".utf8))
            Issue.record("An unterminated event beyond the bound should fail")
        } catch DockerTransportError.responseTooLarge(let limit) {
            #expect(limit == 4)
        }
    }

    @Test("A live daemon answers the version handshake")
    func readsVersion() async throws {
        guard let client else { return }
        let version = try await client.version()
        #expect(!version.version.isEmpty)
        #expect(!version.apiVersion.isEmpty)
    }

    @Test("A live daemon answers the pinned container-list endpoint")
    func listsContainers() async throws {
        guard let client else { return }
        // The list decodes or throws; an empty engine is a valid answer, so the
        // assertion is that every summary is coherent rather than non-empty.
        for container in try await client.containers() {
            #expect(!container.id.isEmpty)
            #expect(!container.name.isEmpty)
            #expect(container.shortID.count <= 12)
            // Ports are de-duplicated, so no two share a mapping triple. The
            // key must include the protocol: a container exposing 4001/tcp and
            // 4001/udp is two distinct, legitimate mappings.
            let mappings = container.ports.map {
                "\($0.privatePort)/\($0.networkProtocol)/\($0.publicPort ?? -1)"
            }
            #expect(mappings.count == Set(mappings).count)
        }
    }

    @Test("The event stream opens and shuts down on cancellation")
    func eventStreamCancels() async throws {
        guard let client else { return }
        let watcher = Task {
            for try await _ in client.containerEvents() { /* drained until cancelled */ }
        }
        try await Task.sleep(for: .milliseconds(400))
        watcher.cancel()
        _ = await watcher.result
    }

    @Test("A socket path with nothing listening reports unreachable, not a hang")
    func missingSocketFailsFast() async throws {
        // Short by construction: an AF_UNIX path may be at most 104 bytes, and
        // the test host's temporary directory is already long enough that a UUID
        // suffix would push a path there past the limit.
        let missing = DockerEngineClient(socketPath: "/tmp/pilot-absent-\(UUID().uuidString).sock")
        do {
            _ = try await missing.version()
            Issue.record("A socket that does not exist should not answer.")
        } catch let error as DockerTransportError {
            // `.waiting(ENOENT)`, not a hang: AF_UNIX would otherwise retry forever.
            guard case .daemonUnreachable = error else {
                Issue.record("Expected an unreachable daemon, got \(error).")
                return
            }
        }
    }
}
