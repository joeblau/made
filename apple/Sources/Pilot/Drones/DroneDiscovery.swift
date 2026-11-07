import Foundation
import Network
import Observation

struct DroneDiscoveryCandidate: Equatable, Identifiable, Sendable {
    var id: String
    var displayName: String
    var endpoint: DroneEndpoint
    var advertisedProtocolVersions: [UInt16]
}

@Observable
@MainActor
final class DroneDiscovery {
    enum BrowseState: Equatable {
        case idle
        case browsing
        case needsPermission(String)
        case failed(String)
    }

    static let serviceType = "_blau-drone._tcp"

    private(set) var candidates: [DroneDiscoveryCandidate] = []
    private(set) var browseState: BrowseState = .idle
    var onCandidatesChange: ([DroneDiscoveryCandidate]) -> Void = { _ in }

    @ObservationIgnored private let allowsNetwork: Bool
    @ObservationIgnored private var browser: NWBrowser?

    init(allowsNetwork: Bool = true) {
        self.allowsNetwork = allowsNetwork
    }

    func start() {
        guard allowsNetwork, browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(
            for: .bonjour(type: Self.serviceType, domain: nil),
            using: parameters
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.apply(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.browseState = .browsing
                case .waiting(let error):
                    self?.browseState = .needsPermission(error.localizedDescription)
                case .failed(let error):
                    self?.browseState = .failed(error.localizedDescription)
                    self?.browser = nil
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

    func retry() {
        browser?.cancel()
        browser = nil
        browseState = .idle
        start()
    }

    func stop() {
        browser?.cancel()
        browser = nil
        candidates = []
        browseState = .idle
        onCandidatesChange([])
    }

    func apply(_ incoming: [DroneDiscoveryCandidate]) {
        var byID: [String: DroneDiscoveryCandidate] = [:]
        for candidate in incoming {
            guard (try? candidate.endpoint.validate()) != nil else { continue }
            let existingVersions = byID[candidate.id]?.advertisedProtocolVersions ?? []
            let versions = Array(Set(existingVersions + candidate.advertisedProtocolVersions))
                .sorted()
                .prefix(DroneLimits.maxProtocolVersions)
            if byID[candidate.id] == nil {
                byID[candidate.id] = DroneDiscoveryCandidate(
                    id: candidate.id,
                    displayName: String(candidate.displayName.prefix(80)),
                    endpoint: candidate.endpoint,
                    advertisedProtocolVersions: []
                )
            }
            byID[candidate.id]?.advertisedProtocolVersions = Array(versions)
        }
        let candidates = byID.values.sorted {
            let order = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        guard candidates != self.candidates else { return }
        self.candidates = candidates
        onCandidatesChange(candidates)
    }

    private func apply(_ results: Set<NWBrowser.Result>) {
        let candidates = results.compactMap { result -> DroneDiscoveryCandidate? in
            guard case .service(let name, let type, let domain, _) = result.endpoint else {
                return nil
            }
            var versions: [UInt16] = []
            if case .bonjour(let record) = result.metadata {
                let value = record["version"] ?? record["v"] ?? ""
                versions = value.split(separator: ",").compactMap {
                    UInt16($0.trimmingCharacters(in: .whitespaces))
                }
            }
            return DroneDiscoveryCandidate(
                id: "\(name).\(type).\(domain)",
                displayName: name,
                endpoint: .bonjour(name: name, type: type, domain: domain),
                advertisedProtocolVersions: versions
            )
        }
        apply(candidates)
    }
}
