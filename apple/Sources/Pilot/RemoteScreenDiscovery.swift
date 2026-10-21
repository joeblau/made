import Foundation
import Network

/// Discovers machines offering Screen Sharing / Remote Management on the LAN.
/// macOS (and most VNC servers) advertise the RFB service over Bonjour as
/// `_rfb._tcp`, so an `NWBrowser` over that type is the live "computers you can
/// connect to" list behind the new-tab picker. Mirrors the `NWBrowser` idiom
/// in `FrameLink`, but stays on the main actor so SwiftUI can observe `services`
/// directly (the browse callback is cheap; only the brief endpoint resolution
/// hops to a background queue).
@Observable
@MainActor
final class RemoteScreenDiscovery {
    /// One discovered RFB service. `endpoint` is the Bonjour service endpoint we
    /// resolve to a concrete host/port when the user picks it.
    struct Service: Identifiable, Hashable {
        let id: String        // unique Bonjour service name
        let name: String      // display name (usually the computer name)
        let endpoint: NWEndpoint

        static func == (lhs: Service, rhs: Service) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    /// A resolved address ready to hand to the VNC client.
    struct ResolvedAddress: Sendable {
        let host: String
        let port: Int
    }

    /// What the browser is doing, so the picker can show an actionable message
    /// rather than an endless spinner when discovery is blocked.
    enum BrowseState: Equatable {
        case idle
        case browsing                 // `.ready` — searching the network
        case needsPermission(String)  // `.waiting` — Local Network access not granted
        case failed(String)
    }
    private(set) var browseState: BrowseState = .idle

    private(set) var services: [Service] = []
    private var browser: NWBrowser?
    /// True between start() and stop(); gates the delayed restart so a pending
    /// one can't resurrect browsing after the picker closes (stop() also nils
    /// the browser, so `browser == nil` alone would not distinguish the two).
    private var shouldBeRunning = false
    private var restartTask: Task<Void, Never>?
    private var restartAttempt = 0

    /// Start (idempotent) browsing for `_rfb._tcp`. Safe to call on every picker
    /// open; a no-op while a browser is already live.
    func start() {
        shouldBeRunning = true
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: "_rfb._tcp", domain: nil), using: parameters)

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.apply(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.browseState = .browsing
                    self.restartAttempt = 0
                case .waiting(let error):
                    // `.waiting` here almost always means macOS hasn't granted
                    // Pilot Local Network access (or `_rfb._tcp` isn't allowed in
                    // NSBonjourServices yet) — surface it instead of spinning.
                    self.browseState = .needsPermission(error.localizedDescription)
                case .failed(let error):
                    self.browseState = .failed(error.localizedDescription)
                    self.restart()
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }

        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        shouldBeRunning = false
        restartTask?.cancel()
        restartTask = nil
        restartAttempt = 0
        browser?.cancel()
        browser = nil
        services = []
        browseState = .idle
    }

    /// Re-create the browser after `.failed`, waiting out an exponential backoff
    /// so a persistently broken mDNS responder can't drive a tight
    /// create/fail/restart loop on the main queue while the picker is open.
    private func restart() {
        browser = nil
        let delay = Self.restartDelay(attempt: restartAttempt, unitJitter: .random(in: 0..<1))
        restartAttempt += 1
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            guard self.shouldBeRunning, self.browser == nil else { return }
            self.start()
        }
    }

    /// Equal-jitter exponential backoff: `2^attempt` seconds capped at 30, then
    /// randomized into the upper half of that window. `unitJitter` is a value in
    /// [0, 1], injected so the schedule stays deterministic under test.
    nonisolated static func restartDelay(attempt: Int, unitJitter: Double) -> Duration {
        let cap = 30.0
        let base = min(pow(2.0, Double(min(max(attempt, 0), 16))), cap)
        let jitter = min(max(unitJitter, 0), 1)
        return .seconds(base / 2 + base / 2 * jitter)
    }

    private func apply(_ results: Set<NWBrowser.Result>) {
        services = results.compactMap { result -> Service? in
            guard case let .service(name, _, _, _) = result.endpoint else { return nil }
            return Service(id: name, name: name, endpoint: result.endpoint)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Resolve a discovered Bonjour service to a concrete host + port. RoyalVNC
    /// connects by hostname, so we briefly open a connection to the service
    /// endpoint and read back the resolved remote address, then cancel.
    func resolve(_ service: Service) async -> ResolvedAddress? {
        // Prefer the Bonjour `.local` hostname (exactly what Finder / Screen
        // Sharing connects to), so the OS resolves a reachable address on every
        // connect — robust across IPv4/IPv6 and link-local interface zones, and
        // stable across network changes. Fall back to a direct IP resolve (zone
        // preserved) only if the hostname can't be resolved.
        if let byName = await Self.resolveHostname(service.endpoint) {
            return byName
        }
        return await Self.resolveEndpoint(service.endpoint)
    }

    /// Resolve a Bonjour service to its `.local` hostname + port via `NetService`
    /// — the API that exposes the SRV target hostname (`NWConnection` only gives
    /// the resolved IP). Returns nil if the endpoint isn't a Bonjour service or
    /// resolution times out.
    @MainActor
    private static func resolveHostname(_ endpoint: NWEndpoint) async -> ResolvedAddress? {
        guard case let .service(name, type, domain, _) = endpoint else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<ResolvedAddress?, Never>) in
            BonjourHostnameResolver().start(domain: domain, type: type, name: name, continuation: continuation)
        }
    }

    nonisolated private static let resolveQueue = DispatchQueue(label: "app.blau.remotedesktop.resolve")

    /// One-shot resolver. The `Box` (with a lock) guarantees the continuation is
    /// resumed exactly once across the connection's state callback and the
    /// safety timeout, which may fire on different threads.
    nonisolated private static func resolveEndpoint(_ endpoint: NWEndpoint) async -> ResolvedAddress? {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var finished = false
            var connection: NWConnection?
        }
        let box = Box()

        return await withCheckedContinuation { (continuation: CheckedContinuation<ResolvedAddress?, Never>) in
            let connection = NWConnection(to: endpoint, using: .tcp)
            box.connection = connection

            @Sendable func finish(_ result: ResolvedAddress?) {
                box.lock.lock()
                let isFirst = !box.finished
                box.finished = true
                box.lock.unlock()
                guard isFirst else { return }
                box.connection?.cancel()
                box.connection = nil
                continuation.resume(returning: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, port)? = box.connection?.currentPath?.remoteEndpoint {
                        finish(ResolvedAddress(host: hostString(host), port: Int(port.rawValue)))
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }

            connection.start(queue: resolveQueue)
            resolveQueue.asyncAfter(deadline: .now() + 4) { finish(nil) }
        }
    }

    /// A printable host string for an `NWEndpoint.Host`, dropping any IPv6 zone
    /// suffix (`%en0`) that a raw client wouldn't accept.
    nonisolated private static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .name(let name, _):
            return name
        case .ipv4(let address):
            return address.debugDescription.components(separatedBy: "%").first ?? address.debugDescription
        case .ipv6(let address):
            // Keep the interface zone (e.g. `%en0`). Link-local IPv6 (fe80::/10)
            // is unreachable WITHOUT its scope id — Network.framework returns
            // NWError 51 ("Network is unreachable"). `NWEndpoint.Host(_:)` parses
            // the `%zone` and connects on that interface; routable IPv6 carries no
            // zone, so this only preserves it where it's actually required.
            return address.debugDescription
        @unknown default:
            return ""
        }
    }
}

/// One-shot `NetService` resolver that returns a Bonjour service's `.local`
/// hostname + port. Self-retains until it resolves (or times out) so the caller
/// only needs to `start` it; all work runs on the main run loop, where the
/// delegate callbacks fire. `@unchecked Sendable` because it is confined to the
/// main thread (scheduled on `.main`) and resumes its continuation exactly once.
private final class BonjourHostnameResolver: NSObject, NetServiceDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<RemoteScreenDiscovery.ResolvedAddress?, Never>?
    private var service: NetService?
    private var selfRef: BonjourHostnameResolver?

    func start(domain: String, type: String, name: String,
               continuation: CheckedContinuation<RemoteScreenDiscovery.ResolvedAddress?, Never>) {
        self.continuation = continuation
        self.selfRef = self
        let service = NetService(domain: domain, type: type, name: name)
        self.service = service
        service.delegate = self
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        // hostName is like "Mini02.local." — drop the trailing dot.
        let host = sender.hostName.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
        finish(host: (host?.isEmpty == false) ? host : nil, port: sender.port)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        finish(host: nil, port: 0)
    }

    private func finish(host: String?, port: Int) {
        guard let continuation else { return }
        self.continuation = nil
        service?.stop()
        service?.delegate = nil
        service = nil
        if let host, port > 0 {
            continuation.resume(returning: RemoteScreenDiscovery.ResolvedAddress(host: host, port: port))
        } else {
            continuation.resume(returning: nil)
        }
        selfRef = nil
    }
}
