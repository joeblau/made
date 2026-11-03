#if os(macOS)
import Darwin
import Foundation

struct DroneTmux: Sendable {
    struct Result: Sendable {
        let status: Int32
        let standardOutput: Data
        let standardError: Data
    }

    let executable: String
    let socketName: String

    static func locate() -> String? {
        [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func attachArguments(sessionName: String) -> [String] {
        baseArguments + ["attach-session", "-t", sessionName]
    }

    func create(
        sessionName: String,
        directory: String,
        columns: UInt16,
        rows: UInt16,
        environment: [String: String]
    ) throws {
        _ = try requireSuccess([
            "new-session", "-d", "-s", sessionName, "-c", directory,
            "-x", String(columns), "-y", String(rows),
        ], environment: environment)
        _ = try requireSuccess(
            ["set-option", "-t", sessionName, "status", "off"],
            environment: environment
        )
        _ = try requireSuccess(
            ["set-option", "-t", sessionName, "mouse", "on"],
            environment: environment
        )
    }

    func hasSession(_ sessionName: String, environment: [String: String]) -> Bool {
        guard let result = try? run(
            ["has-session", "-t", sessionName],
            environment: environment,
            outputLimit: 1_024
        ) else { return false }
        return result.status == 0
    }

    func killSession(_ sessionName: String, environment: [String: String]) throws {
        _ = try requireSuccess(["kill-session", "-t", sessionName], environment: environment)
    }

    func sendLiteral(
        _ text: String,
        sessionName: String,
        environment: [String: String]
    ) throws {
        _ = try requireSuccess([
            "send-keys", "-l", "-t", sessionName, "--", text,
        ], environment: environment)
    }

    func sendEnter(sessionName: String, environment: [String: String]) throws {
        _ = try requireSuccess([
            "send-keys", "-t", sessionName, "Enter",
        ], environment: environment)
    }

    func activity(
        sessionName: String,
        environment: [String: String]
    ) throws -> (command: String, shellPID: Int32) {
        let result = try requireSuccess([
            "display-message", "-p", "-t", sessionName,
            "#{pane_current_command}\t#{pane_pid}",
        ], environment: environment)
        let fields = String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 2,
              let shellPID = Int32(fields[1]), shellPID > 0,
              !fields[0].isEmpty, fields[0].utf8.count <= 256
        else { throw DroneTerminalError.processFailed }
        return (String(fields[0]), shellPID)
    }

    func workingDirectory(sessionName: String, environment: [String: String]) throws -> String {
        let result = try requireSuccess([
            "display-message", "-p", "-t", sessionName, "#{pane_current_path}",
        ], environment: environment)
        let path = String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path.utf8.count <= 4 * 1_024, !path.utf8.contains(0) else {
            throw DroneTerminalError.processFailed
        }
        return path
    }

    func captureVisibleOutput(
        sessionName: String,
        environment: [String: String]
    ) throws -> Data {
        let result = try requireSuccess(
            ["capture-pane", "-p", "-e", "-J", "-t", sessionName],
            environment: environment,
            outputLimit: 1_048_576
        )
        return result.standardOutput
    }

    private var baseArguments: [String] { ["-L", socketName] }

    private func requireSuccess(
        _ arguments: [String],
        environment: [String: String],
        outputLimit: Int = 8 * 1_024
    ) throws -> Result {
        let result = try run(arguments, environment: environment, outputLimit: outputLimit)
        guard result.status == 0 else { throw DroneTerminalError.processFailed }
        return result
    }

    private func run(
        _ arguments: [String],
        environment: [String: String],
        outputLimit: Int
    ) throws -> Result {
        let directory = FileManager.default.temporaryDirectory
        let token = UUID().uuidString
        let outputURL = directory.appendingPathComponent("drone-tmux-\(token).out")
        let errorURL = directory.appendingPathComponent("drone-tmux-\(token).err")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        else { throw DroneTerminalError.processFailed }
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }
        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = baseArguments + arguments
        process.environment = environment
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw DroneTerminalError.processFailed
        }
        process.waitUntilExit()
        try? output.close()
        try? error.close()
        let standardOutput = try boundedContents(of: outputURL, limit: outputLimit)
        let standardError = try boundedContents(of: errorURL, limit: 8 * 1_024)
        return Result(
            status: process.terminationStatus,
            standardOutput: standardOutput,
            standardError: standardError
        )
    }

    private func boundedContents(of url: URL, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw DroneTerminalError.resourceLimit }
        return data
    }
}
#endif
