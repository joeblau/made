import Foundation

enum ProofFixtures {
    static let workspaceID = UUID(uuidString: "31831831-8318-4318-8318-318318318318")!
}

enum ProofError: Error {
    case invalidClientArguments
    case invalidOutputStream
    case unexpectedMessage
    case expectedDisconnect
    case expectedMalformedConnection
    case idempotencyProofFailed
    case pairingProofFailed
    case clientFailed(Int32)
}

@main
struct DroneProtocolProof {
    static func main() {
        do {
            switch CommandLine.arguments.dropFirst().first {
            case "server":
                var server = ProofServer()
                try server.run()
            case "client":
                try ProofClient(arguments: CommandLine.arguments).run()
            default:
                throw ProofError.invalidClientArguments
            }
        } catch {
            FileHandle.standardError.write(Data("drone protocol proof failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
