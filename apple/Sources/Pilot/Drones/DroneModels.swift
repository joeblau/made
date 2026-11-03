import Foundation

struct DroneHardwarePresentation: Codable, Equatable, Sendable {
    var model: String
    var processor: String

    init(model: String = "", processor: String = "") {
        self.model = model
        self.processor = processor
    }

    static let unknown = DroneHardwarePresentation()

    var displayText: String {
        [model, processor].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    func validate() throws {
        guard model.utf8.count <= 128, processor.utf8.count <= 128 else {
            throw DroneRegistryError.invalidMetadata
        }
    }
}

enum DroneEndpoint: Codable, Equatable, Hashable, Sendable {
    case hostPort(host: String, port: UInt16)
    case bonjour(name: String, type: String, domain: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case host
        case port
        case name
        case type
        case domain
    }

    private enum Kind: String, Codable {
        case hostPort
        case bonjour
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .hostPort:
            self = .hostPort(
                host: try container.decode(String.self, forKey: .host),
                port: try container.decode(UInt16.self, forKey: .port)
            )
        case .bonjour:
            self = .bonjour(
                name: try container.decode(String.self, forKey: .name),
                type: try container.decode(String.self, forKey: .type),
                domain: try container.decode(String.self, forKey: .domain)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hostPort(let host, let port):
            try container.encode(Kind.hostPort, forKey: .kind)
            try container.encode(host, forKey: .host)
            try container.encode(port, forKey: .port)
        case .bonjour(let name, let type, let domain):
            try container.encode(Kind.bonjour, forKey: .kind)
            try container.encode(name, forKey: .name)
            try container.encode(type, forKey: .type)
            try container.encode(domain, forKey: .domain)
        }
    }

    static func manual(host: String, portText: String) throws -> DroneEndpoint {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let unbracketedHost = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast())
            : host
        guard !unbracketedHost.isEmpty,
              unbracketedHost.utf8.count <= 253,
              !unbracketedHost.contains("/"),
              !unbracketedHost.contains("@"),
              !unbracketedHost.contains(where: { $0.isWhitespace }),
              let port = UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)),
              port > 0
        else { throw DroneRegistryError.invalidEndpoint }
        return .hostPort(host: unbracketedHost, port: port)
    }

    func validate() throws {
        switch self {
        case .hostPort(let host, let port):
            guard !host.isEmpty, host.utf8.count <= 253, port > 0,
                  !host.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "@" })
            else { throw DroneRegistryError.invalidEndpoint }
        case .bonjour(let name, let type, let domain):
            guard !name.isEmpty, name.utf8.count <= 63,
                  type == "_blau-drone._tcp", domain.utf8.count <= 253
            else { throw DroneRegistryError.invalidEndpoint }
        }
    }

    var displayText: String {
        switch self {
        case .hostPort(let host, let port):
            host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        case .bonjour(let name, _, _):
            name
        }
    }
}

struct DroneAuthenticatedPeer: Equatable, Sendable {
    var identityFingerprint: String
    var hardware: DroneHardwarePresentation
    var hello: DroneHello

    func validate() throws {
        guard !identityFingerprint.isEmpty,
              identityFingerprint.utf8.count <= 128,
              hello.selectedVersion != nil
        else { throw DroneTransportError.incompatible }
        try hardware.validate()
        try hello.validate()
    }
}

enum DroneLastKnownStatus: String, Codable, Sendable {
    case pairing
    case online
    case offline
    case unauthorized
    case incompatible
    case busy
}

struct DroneRecord: Codable, Equatable, Identifiable, Sendable {
    static let maxEndpoints = 8

    let id: UUID
    var name: String
    var hardware: DroneHardwarePresentation
    var endpoints: [DroneEndpoint]
    var capabilities: [String]
    var supportedVersions: [UInt16]
    var negotiatedVersion: UInt16?
    var lastKnownStatus: DroneLastKnownStatus
    var discoveryID: String?
    var verifiedIdentityFingerprint: String?
    var createdAt: Date
    var lastConnectedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        endpoints: [DroneEndpoint],
        discoveryID: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.hardware = .unknown
        self.endpoints = endpoints
        self.capabilities = []
        self.supportedVersions = []
        self.negotiatedVersion = nil
        self.lastKnownStatus = .pairing
        self.discoveryID = discoveryID
        self.verifiedIdentityFingerprint = nil
        self.createdAt = createdAt
        self.lastConnectedAt = nil
    }

    func validate() throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, name.utf8.count <= 80,
              !endpoints.isEmpty, endpoints.count <= Self.maxEndpoints,
              Set(endpoints).count == endpoints.count,
              capabilities.count <= DroneLimits.maxCapabilities,
              Set(capabilities).count == capabilities.count,
              supportedVersions.count <= DroneLimits.maxProtocolVersions,
              Set(supportedVersions).count == supportedVersions.count,
              discoveryID?.utf8.count ?? 0 <= 253,
              verifiedIdentityFingerprint?.utf8.count ?? 0 <= 128
        else { throw DroneRegistryError.invalidMetadata }
        try hardware.validate()
        try endpoints.forEach { try $0.validate() }
        if let negotiatedVersion {
            guard supportedVersions.contains(negotiatedVersion) else {
                throw DroneRegistryError.invalidMetadata
            }
        }
    }

    mutating func applyAuthenticatedPeer(_ peer: DroneAuthenticatedPeer, at date: Date) {
        hardware = peer.hardware
        capabilities = peer.hello.capabilities
        supportedVersions = peer.hello.supportedVersions
        negotiatedVersion = peer.hello.selectedVersion
        verifiedIdentityFingerprint = peer.identityFingerprint
        lastKnownStatus = .online
        lastConnectedAt = date
    }
}

enum DroneRegistryError: Error, Equatable {
    case invalidName
    case invalidEndpoint
    case invalidMetadata
    case registryFull
    case duplicateDrone
    case missingDrone
    case persistenceUnavailable
}

enum DroneConnectionIssue: String, Codable, Equatable, Sendable {
    case transportUnavailable
    case connectionFailed
    case timedOut
    case disconnected
    case heartbeatTimedOut
    case pairingRequired
    case unauthorized
    case revoked
    case identityMismatch
    case incompatible
    case busy
    case remoteRejected
    case revocationFailed

    var isTerminal: Bool {
        switch self {
        case .transportUnavailable, .pairingRequired, .unauthorized, .revoked,
             .identityMismatch, .incompatible, .remoteRejected, .revocationFailed:
            true
        case .connectionFailed, .timedOut, .disconnected, .heartbeatTimedOut, .busy:
            false
        }
    }
}

enum DroneTransportError: Error, Equatable {
    case transportUnavailable
    case connectionFailed
    case timedOut
    case disconnected
    case heartbeatTimedOut
    case pairingRequired
    case unauthorized
    case revoked
    case identityMismatch
    case incompatible
    case busy
    case remoteRejected
    case revocationFailed
}

enum DroneConnectionState: Equatable, Sendable {
    case pairing
    case connecting(attempt: Int)
    case connected(DroneAuthenticatedPeer)
    case offline(issue: DroneConnectionIssue, retryAttempt: Int?)
    case unauthorized(DroneConnectionIssue)
    case incompatible
    case busy(retryAttempt: Int)
    case forgetting

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

struct DroneDiagnosticEntry: Equatable, Sendable {
    var timestamp: Date
    var event: String
}

struct DroneDiagnostics: Equatable, Sendable {
    static let maxEntries = 20

    var generation: UInt64 = 0
    var connectAttempts = 0
    var successfulConnections = 0
    var lastHeartbeatAt: Date?
    var lastIssue: DroneConnectionIssue?
    var lastEndpoint: DroneEndpoint?
    var entries: [DroneDiagnosticEntry] = []

    mutating func record(_ event: String, at date: Date) {
        entries.append(DroneDiagnosticEntry(timestamp: date, event: event))
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }
}
