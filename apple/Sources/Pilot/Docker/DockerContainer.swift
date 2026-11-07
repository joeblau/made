import Foundation

/// Lifecycle state as reported by `/containers/json`. Docker's vocabulary is
/// fixed; anything new maps to `.unknown` rather than failing the decode, so one
/// unfamiliar state never blanks the whole list.
enum DockerContainerState: String, Sendable, CaseIterable {
    case created
    case running
    case paused
    case restarting
    case removing
    case exited
    case dead
    case unknown

    init(rawValue raw: String) {
        self = DockerContainerState.allCases.first { $0.rawValue == raw.lowercased() } ?? .unknown
    }

    var isRunning: Bool {
        switch self {
        case .running, .restarting: true
        case .created, .paused, .removing, .exited, .dead, .unknown: false
        }
    }

}

/// One published or exposed port.
struct DockerPortBinding: Sendable, Hashable {
    let privatePort: Int
    let publicPort: Int?
    let networkProtocol: String

    /// `8080→80/tcp` when published, `80/tcp` when only exposed.
    var displayText: String {
        if let publicPort {
            return "\(publicPort)→\(privatePort)/\(networkProtocol)"
        }
        return "\(privatePort)/\(networkProtocol)"
    }
}

/// A container as summarized by `/containers/json?all=1`.
struct DockerContainerSummary: Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let image: String
    let command: String
    let createdAt: Date
    let state: DockerContainerState
    /// Human-readable status from the daemon, e.g. "Up 42 hours".
    let status: String
    let ports: [DockerPortBinding]
    let labels: [String: String]

    var shortID: String { String(id.prefix(12)) }

    /// Compose groups its containers with a project label. Pilot uses it as the
    /// section header so a `docker compose up` stack reads as one unit.
    var composeProject: String? {
        labels["com.docker.compose.project"].map { UntrustedText.sanitized($0, limit: 80) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Published ports first, then merely exposed ones; both de-duplicated.
    /// The daemon lists each published port once per host address family, so a
    /// single `-p 8080:80` arrives twice (0.0.0.0 and ::).
    var portsSummary: String {
        let published = ports.filter { $0.publicPort != nil }.sorted { ($0.publicPort ?? 0) < ($1.publicPort ?? 0) }
        let exposed = ports.filter { $0.publicPort == nil }.sorted { $0.privatePort < $1.privatePort }
        return (published + exposed).prefix(4).map(\.displayText).joined(separator: "  ")
    }
}

extension DockerContainerSummary: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case names = "Names"
        case image = "Image"
        case command = "Command"
        case created = "Created"
        case state = "State"
        case status = "Status"
        case ports = "Ports"
        case labels = "Labels"
    }

    private enum PortKeys: String, CodingKey {
        case privatePort = "PrivatePort"
        case publicPort = "PublicPort"
        case type = "Type"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)

        // Names arrive as "/my-container"; the leading slash is Docker's
        // legacy network-alias notation and never shown in any client.
        let names = (try? container.decode([String].self, forKey: .names)) ?? []
        let primary = names.first.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 } ?? ""
        name = primary.isEmpty ? String(id.prefix(12)) : UntrustedText.sanitized(primary, limit: 120)

        image = UntrustedText.sanitized((try? container.decode(String.self, forKey: .image)) ?? "", limit: 160)
        command = UntrustedText.sanitized((try? container.decode(String.self, forKey: .command)) ?? "", limit: 200)

        let createdEpoch = (try? container.decode(Double.self, forKey: .created)) ?? 0
        createdAt = Date(timeIntervalSince1970: createdEpoch)

        state = DockerContainerState(rawValue: (try? container.decode(String.self, forKey: .state)) ?? "")
        status = UntrustedText.sanitized((try? container.decode(String.self, forKey: .status)) ?? "", limit: 120)

        var decodedPorts: [DockerPortBinding] = []
        if var portsArray = try? container.nestedUnkeyedContainer(forKey: .ports) {
            var seen = Set<DockerPortBinding>()
            while !portsArray.isAtEnd {
                guard let entry = try? portsArray.nestedContainer(keyedBy: PortKeys.self) else {
                    _ = try? portsArray.decode(AnyDecodableSkip.self)
                    continue
                }
                guard let privatePort = try? entry.decode(Int.self, forKey: .privatePort) else { continue }
                let binding = DockerPortBinding(
                    privatePort: privatePort,
                    publicPort: try? entry.decode(Int.self, forKey: .publicPort),
                    networkProtocol: (try? entry.decode(String.self, forKey: .type)) ?? "tcp"
                )
                if seen.insert(binding).inserted { decodedPorts.append(binding) }
            }
        }
        ports = decodedPorts

        labels = (try? container.decode([String: String].self, forKey: .labels)) ?? [:]
    }
}

/// Consumes and discards one element of an unkeyed container so a single
/// malformed entry can't strand the decoder mid-array.
private struct AnyDecodableSkip: Decodable {
    init(from decoder: any Decoder) throws {
        _ = try? decoder.singleValueContainer()
    }
}

/// The lifecycle operations the section exposes. `remove` is the only
/// irreversible one and is always confirmed before it runs.
enum DockerContainerAction: Sendable, Hashable {
    case start
    case stop
    case restart
    case remove

    var label: String {
        switch self {
        case .start: "Start"
        case .stop: "Stop"
        case .restart: "Restart"
        case .remove: "Remove"
        }
    }

    var systemImage: String {
        switch self {
        case .start: "play.fill"
        case .stop: "stop.fill"
        case .restart: "arrow.clockwise"
        case .remove: "trash"
        }
    }

    /// Present-continuous form for the transient row status.
    var activeLabel: String {
        switch self {
        case .start: "Starting…"
        case .stop: "Stopping…"
        case .restart: "Restarting…"
        case .remove: "Removing…"
        }
    }
}
