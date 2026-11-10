import Foundation

@main
enum DroneTerminalProof {
    static func main() async throws {
        try await provePTYDeliversOneChunkAtATime()
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
            // printf assembles the marker, so only the command's output (never
            // the echoed command line) contains it.
            Data("printf '%s-%s\\n' drone pty-✓\n".utf8),
            sessionID: created.sessionID,
            pairingID: pairingID,
            connectionID: connectionID
        )
        let first = try await output(
            containing: "drone-pty-✓",
            socket: socket,
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
        // The attached tmux client must follow the PTY resize. If it doesn't,
        // tmux pans its undersized view to follow the cursor and output near
        // column 0 vanishes behind a long prompt.
        let clientDeadline = ContinuousClock.now + .seconds(5)
        var clientSize = tmuxQuery(socket: socket, ["list-clients", "-F", "#{client_width}x#{client_height}"])
        while clientSize != "100x30", ContinuousClock.now < clientDeadline {
            try await Task.sleep(for: .milliseconds(50))
            clientSize = tmuxQuery(socket: socket, ["list-clients", "-F", "#{client_width}x#{client_height}"])
        }
        expect(clientSize == "100x30", "tmux client did not follow the PTY resize: \(tmuxDiagnostics(socket: socket))")
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
            Data("printf '%s-%s\\n' after reattach\n".utf8),
            sessionID: created.sessionID,
            pairingID: pairingID,
            connectionID: secondConnection
        )
        _ = try await output(
            containing: "after-reattach",
            socket: socket,
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
        await recovered.shutdown()
        try verifyQuarantinedCatalog(root: root, workspaceID: workspaceID, workspace: workspace)
        try await proveIdempotencyAllowanceIsPerPairing(root: root, workspaceID: workspaceID, workspace: workspace)
        print(
            "Drone terminal proof passed: real PTY, Unicode, resize, cwd, reattach, restart, authorization, "
                + "close, catalog quarantine, and per-pairing idempotency limits."
        )
    }

    /// One controller exhausting its create-idempotency allowance must not
    /// starve another controller, before or after a restart (#442).
    private static func proveIdempotencyAllowanceIsPerPairing(
        root: URL,
        workspaceID: UUID,
        workspace: URL
    ) async throws {
        var configuration = DroneTerminalConfiguration()
        configuration.maximumIdempotencyEntries = 1
        let state = root.appendingPathComponent("limit-state", isDirectory: true)
        let socket = "drone-proof-limit-\(UUID().uuidString)"
        let body = DroneCreateBody(workspaceID: workspaceID, environment: [:], columns: 80, rows: 24)
        let first = UUID()
        let second = UUID()
        let engine = try DroneTerminalEngine(
            workspaces: [workspaceID: workspace],
            stateDirectory: state,
            tmuxSocketName: socket,
            configuration: configuration
        )
        let firstTerminal = try await engine.create(body, pairingID: first, idempotencyKey: "terminal-limit-first-0001")
        try await engine.close(firstTerminal.sessionID, pairingID: first)
        do {
            _ = try await engine.create(body, pairingID: first, idempotencyKey: "terminal-limit-first-0002")
            throw ProofError.failed("a pairing exceeded its idempotency allowance")
        } catch DroneTerminalError.resourceLimit {}
        let secondTerminal = try await engine.create(body, pairingID: second, idempotencyKey: "terminal-limit-second-0001")
        try await engine.close(secondTerminal.sessionID, pairingID: second)
        await engine.shutdown()

        let restarted = try DroneTerminalEngine(
            workspaces: [workspaceID: workspace],
            stateDirectory: state,
            tmuxSocketName: socket,
            configuration: configuration
        )
        do {
            _ = try await restarted.create(body, pairingID: first, idempotencyKey: "terminal-limit-first-0003")
            throw ProofError.failed("a pairing's idempotency allowance reset across restart")
        } catch DroneTerminalError.resourceLimit {}
        let third = UUID()
        let thirdTerminal = try await restarted.create(body, pairingID: third, idempotencyKey: "terminal-limit-third-0001")
        try await restarted.close(thirdTerminal.sessionID, pairingID: third)
        await restarted.shutdown()
    }

    /// #440: an undecodable or newer-version catalog must be set aside, not abort startup.
    private static func verifyQuarantinedCatalog(root: URL, workspaceID: UUID, workspace: URL) throws {
        let state = root.appendingPathComponent("quarantine-state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let catalogURL = state.appendingPathComponent("terminals.json")
        let quarantineURL = state.appendingPathComponent("quarantine", isDirectory: true)
        func start() throws -> DroneTerminalEngine {
            try DroneTerminalEngine(
                workspaces: [workspaceID: workspace],
                stateDirectory: state,
                tmuxSocketName: "drone-proof-\(UUID().uuidString)"
            )
        }

        try Data("{\"records\": [not json".utf8).write(to: catalogURL)
        let garbage = try start()
        expect(garbage.quarantinedCatalogCount == 1, "garbage catalog was not quarantined")
        expect(!FileManager.default.fileExists(atPath: catalogURL.path), "garbage catalog was left in place")

        try Data(#"{"creates":[],"records":[],"schemaVersion":2}"#.utf8).write(to: catalogURL)
        let future = try start()
        expect(future.quarantinedCatalogCount == 2, "newer-version catalog was not quarantined")
        expect(!FileManager.default.fileExists(atPath: catalogURL.path), "newer-version catalog was left in place")

        // A catalog written before schema versioning must still load, and earlier
        // quarantined catalogs keep storage reported as unhealthy after restart.
        try Data(#"{"creates":[],"records":[]}"#.utf8).write(to: catalogURL)
        let legacy = try start()
        expect(legacy.quarantinedCatalogCount == 2, "legacy catalog was quarantined or restart hid quarantine")
        expect(FileManager.default.fileExists(atPath: catalogURL.path), "legacy catalog was moved aside")
        let preserved = try FileManager.default.contentsOfDirectory(atPath: quarantineURL.path)
        expect(preserved.count == 2, "quarantined catalogs were not preserved for the owner")
    }

    /// #443: while a chunk is on its way to the receiver, `resumeReading()`
    /// (acknowledge, attach, resynchronize) must not let a second chunk be
    /// read, or independent delivery tasks could append them out of order.
    private static func provePTYDeliversOneChunkAtATime() async throws {
        let recorder = PTYChunkRecorder()
        let pty = try DronePTY(
            executable: "/usr/bin/yes",
            arguments: ["drone-order"],
            environment: ["PATH": "/usr/bin:/bin"],
            columns: 80,
            rows: 24,
            onOutput: { _, data in recorder.record(data) },
            onExit: {}
        )
        defer { pty.close() }
        try await waitFor("first PTY chunk") { recorder.count >= 1 }
        for _ in 0..<20 {
            pty.resumeReading()
            try await Task.sleep(for: .milliseconds(5))
        }
        expect(recorder.count == 1, "resumeReading() read another chunk while one was still in flight")
        pty.completeOutputDelivery(resumeReading: true)
        try await waitFor("second PTY chunk") { recorder.count >= 2 }
        try await Task.sleep(for: .milliseconds(100))
        expect(recorder.count == 2, "PTY read past an undelivered chunk after one completion")
        pty.completeOutputDelivery(resumeReading: false)
        try await Task.sleep(for: .milliseconds(100))
        expect(recorder.count == 2, "completing delivery without resuming still read another chunk")
        pty.resumeReading()
        try await waitFor("PTY chunk after explicit resume") { recorder.count >= 3 }
    }

    private static func waitFor(
        _ description: String,
        _ condition: @Sendable () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw ProofError.failed("timed out waiting for \(description)")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func output(
        containing needle: String,
        socket: String,
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
        throw ProofError.failed(
            "output did not contain \(needle); tmux: \(tmuxDiagnostics(socket: socket)); received \(text)"
        )
    }

    /// tmux's own view of client and window sizes, so a failure on a remote
    /// runner shows whether the attached client and its window disagree.
    private static func tmuxDiagnostics(socket: String) -> String {
        func query(_ arguments: [String]) -> String { tmuxQuery(socket: socket, arguments) }
        let version = query(["-V"])
        let clients = query(["list-clients", "-F", "#{client_width}x#{client_height}"])
        let windows = query(["list-windows", "-a", "-F", "#{window_width}x#{window_height} #{window_size}"])
        let panes = query(["list-panes", "-a", "-F", "#{pane_width}x#{pane_height} cursor=#{cursor_x},#{cursor_y}"])
        return "\(version); clients=[\(clients)] windows=[\(windows)] panes=[\(panes)]"
    }

    private static func tmuxQuery(socket: String, _ arguments: [String]) -> String {
        guard let tmux = DroneTmux.locate() else { return "tmux not found" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = ["-L", socket] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return "unavailable" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data.prefix(1_024), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

private final class PTYChunkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks = 0

    var count: Int { lock.withLock { chunks } }

    func record(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock { chunks += 1 }
    }
}
