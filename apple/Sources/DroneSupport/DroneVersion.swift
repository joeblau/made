import Foundation

enum DroneVersion {
    static let marketing = "1.0.0"
    static let build = "1"
    static let protocolVersion: UInt16 = 1
    static let control = 1

    static var report: String {
        "drone \(marketing) (\(build)); protocol \(protocolVersion); execution disabled"
    }
}

enum DroneWorkerError: Error, Equatable {
    case invalidArguments
    case invalidInstallation
    case invalidResponse
    case launchdUnavailable
    case notInstalled
    case operationFailed
    case rollbackFailed
    case processTimedOut
    case unsafeFile
    case unsupportedControlVersion
}

enum DroneOperationalState: String, Codable, Sendable {
    case stopped
    case paired
    case listening
    case unhealthy
    case incompatible
}
