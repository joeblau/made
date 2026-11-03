import Foundation

@main
enum DroneTerminalProof {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("drone-terminal-proof-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let workspaceID = UUID()
        let pairingID = UUID()
        let connectionID = UUID()
        let socket = "drone-proof-\(UUID().uuidString)"
        let state = root.appendingPathComponent("state", isDirectory: true)
        let engine = try DroneTerminalEngine(
            workspaces: [workspaceID: workspace],
            stateDirectory: state,
            tmuxSocketName: socket
        )
        let body = DroneCreateBody(workspaceID: workspaceID, environment: [:], columns: 80, rows: 24)
        let created = try await engine.create(body, pairingID: pairingID, idempotencyKey: "terminal-proof-create-0001")
        let duplicate = try await engine.create(body, pairingID: pairingID, idempotencyKey: "terminal-proof-create-0001")
        expect(created.sessionID == duplicate.sessionID, "duplicate create started another terminal")
        _ = try await engine.attach(created.sessionID, pairingID: pairingID, connectionID: connectionID, after: .zero)
        try await engine.input(
            Data("printf 'drone-pty-✓\\n'\n".utf8),
            sessionID: created.sessionID,
            pairingID: pairingID,
            connectionID: connectionID
        )
        let first = try await output(
            containing: "drone-pty-✓",
            sessionID: created.sessionID,
            pairingID: pairingID,
            connectionID: connectionID,
            engine: engine
        )
        try await engine.acknowledge(
            first.cursor,
            sessionID: created.sessionID,
            pairingID: pairingID,
            connectionID: connectionID
        )
        try await engine.resize(
            columns: 100,
            rows: 30,
            sessionID: created.sessionID,
            pairingID: pairingID,
            connectionID: connectionID
        )
        let resized = try await engine.snapshot(created.sessionID, pairingID: pairingID)
        expect(resized.columns == 100 && resized.rows == 30, "resize did not persist")
        let directory = try await engine.workingDirectory(created.sessionID, pairingID: pairingID)
        let actualDirectory = URL(fileURLWithPath: directory.path).standardizedFileURL.path
        let expectedDirectory = workspace.resolvingSymlinksInPath().standardizedFileURL.path
        expect(actualDirectory == expectedDirectory, "wrong remote working directory: \(actualDirectory) != \(expectedDirectory)")

        try await engine.detach(created.sessionID, pairingID: pairingID, connectionID: connectionID)
        let secondConnection = UUID()
        _ = try await engine.attach(
            created.sessionID,
            pairingID: pairingID,
            connectionID: secondConnection,
            after: first.cursor
        )
        try await engine.input(
            Data("printf 'after-reattach\\n'\n".utf8),
            sessionID: created.sessionID,
            pairingID: pairingID,
            connectionID: secondConnection
        )
        _ = try await output(
            containing: "after-reattach",
            sessionID: created.sessionID,
            pairingID: pairingID,
            connectionID: secondConnection,
            engine: engine
        )
        do {
            _ = try await engine.attach(created.sessionID, pairingID: UUID(), connectionID: UUID(), after: .zero)
            throw ProofError.failed("wrong pairing attached to terminal")
        } catch DroneTerminalError.unauthorized {}

        await engine.shutdown()
        let recovered = try DroneTerminalEngine(
            workspaces: [workspaceID: workspace],
            stateDirectory: state,
            tmuxSocketName: socket
        )
        let recoverySnapshot = try await recovered.snapshot(created.sessionID, pairingID: pairingID)
        expect(recoverySnapshot.requiresResynchronization, "restart did not require an explicit snapshot")
        _ = try await recovered.resynchronize(
            created.sessionID,
            pairingID: pairingID,
            connectionID: secondConnection
        )
        try await recovered.close(created.sessionID, pairingID: pairingID, connectionID: secondConnection)
        try await recovered.close(created.sessionID, pairingID: pairingID, connectionID: secondConnection)
        print("Drone terminal proof passed: real PTY, Unicode, resize, cwd, reattach, restart, authorization, and close.")
    }

    private static func output(
        containing needle: String,
        sessionID: DroneSessionID,
        pairingID: UUID,
        connectionID: UUID,
        engine: DroneTerminalEngine
    ) async throws -> DroneTerminalOutputPage {
        var text = ""
        for _ in 0..<400 {
            let page = try await engine.readOutput(
                sessionID,
                pairingID: pairingID,
                connectionID: connectionID,
                maximumChunks: 64
            )
            text += page.chunks.map { String(decoding: $0.data, as: UTF8.self) }.joined()
            if text.contains(needle) { return page }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw ProofError.failed("output did not contain \(needle); received \(text)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("Drone terminal proof failed: \(message)\n".utf8))
            exit(1)
        }
    }
}

private enum ProofError: Error {
    case failed(String)
}
