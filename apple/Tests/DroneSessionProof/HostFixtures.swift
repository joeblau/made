import Foundation

// Host-only boundaries for the standalone proof. The real session/provider/store,
// transport, caches and protocol are compiled; no SwiftData/AppKit app is launched.
final class Pane: @unchecked Sendable {
    enum Kind { case terminal }
    let id = UUID()
    let kind = Kind.terminal
    let persistentSessionName = "proof-never-local"
    var currentDirectory: String?
    var terminalDestinationRaw: String?
    var terminalDroneIDRaw: String?
    var terminalRemoteSessionIDRaw: String?
    var terminalDroneNameRaw: String?

    init(droneID: UUID) {
        terminalDestinationRaw = "drone"
        terminalDroneIDRaw = droneID.uuidString
    }

    func adoptRemoteSessionID(_ id: UUID, identity: TerminalSessionIdentity) throws {
        guard identity.paneID == self.id, identity.ownership == terminalDestination.ownership else {
            throw TerminalSessionFailure.destinationChanged
        }
        terminalRemoteSessionIDRaw = id.uuidString
    }
}

enum TerminalProcessActivity: Sendable { case idle, running }
enum TerminalFastCommandStore {
    static func executableCommand(from command: String) -> String? { fatalError("Local host fixture called") }
}
enum PersistentTerminalSession {
    struct Runtime { let shellPID: pid_t?; let cursorVisible: Bool }
    static func hasPaneRuntimeSnapshot() -> Bool { fatalError("Local fallback") }
    static func bootstrapCommand(sessionName: String, workingDirectory: String?) -> String? { fatalError("Local fallback") }
    static func sendLiteral(_ text: String, sessionName: String) async -> Bool { fatalError("Local fallback") }
    static func sendKeys(_ keys: [String], sessionName: String) async -> Bool { fatalError("Local fallback") }
    static func foregroundActivity(
        sessionName: String, unavailableActivity: TerminalProcessActivity
    ) async -> TerminalProcessActivity { fatalError("Local fallback") }
    static func stopForegroundCommand(sessionName: String) async -> Bool { fatalError("Local fallback") }
    static func currentDirectory(sessionName: String) -> String? { fatalError("Local fallback") }
    static func paneRuntime(sessionName: String) -> Runtime? { fatalError("Local fallback") }
    static func visibleContents(sessionName: String) -> String? { fatalError("Local fallback") }
    static func closeSession(sessionName: String) async -> Bool { fatalError("Local fallback") }
}
