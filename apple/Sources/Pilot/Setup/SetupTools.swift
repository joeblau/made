import Foundation
import Observation

struct SetupTool: Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let command: String
    let helpURL: URL

    static let all: [SetupTool] = [
        .init(id: "git", title: "Git & Command Line Tools",
              detail: "Repository status, branches, diffs, and source control.",
              command: "xcode-select --install", helpURL: URL(string: "https://developer.apple.com/xcode/resources/")!),
        .init(id: "tmux", title: "Persistent terminals",
              detail: "Keep terminal sessions alive across app restarts with tmux.",
              command: "brew install tmux", helpURL: URL(string: "https://github.com/tmux/tmux/wiki/Installing")!),
        .init(id: "github", title: "GitHub",
              detail: "Pull requests, issues, Actions, and runners need the GitHub CLI and a signed-in account.",
              command: "brew install gh && gh auth login", helpURL: URL(string: "https://cli.github.com/")!),
        .init(id: "xcode", title: "iOS simulators",
              detail: "Install Xcode, open it to finish setup, then install an iOS simulator runtime in Xcode Settings.",
              command: "open -a Xcode", helpURL: URL(string: "https://developer.apple.com/xcode/")!),
        .init(id: "android", title: "Android devices",
              detail: "Install Android platform tools; approve USB debugging on each device when connecting it.",
              command: "brew install --cask android-platform-tools", helpURL: URL(string: "https://developer.android.com/tools/releases/platform-tools")!),
        .init(id: "docker", title: "Containers",
              detail: "Install and start Docker Desktop or a compatible Docker engine for local containers.",
              command: "open -a Docker", helpURL: URL(string: "https://docs.docker.com/desktop/setup/install/mac-install/")!)
    ]
}

@MainActor
@Observable
final class SetupTools {
    private(set) var results: [String: Bool] = [:]
    private(set) var isChecking = false

    func refresh() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        // Never run Apple's git/xcrun shims without an installed toolchain:
        // invoking them on a fresh Mac would pop an unsolicited installer.
        let developerDirectory = await Self.output("/usr/bin/xcode-select", ["-p"])
        let hasDeveloperTools = developerDirectory.map {
            FileManager.default.fileExists(atPath: $0.trimmingCharacters(in: .whitespacesAndNewlines))
        } ?? false
        for tool in SetupTool.all {
            guard !Task.isCancelled else { return }
            switch tool.id {
            case "git": results[tool.id] = hasDeveloperTools ? await Self.succeeds("git", ["--version"]) : false
            case "tmux": results[tool.id] = PersistentTerminalSession.isAvailable
            case "github": results[tool.id] = await Self.succeeds("gh", ["auth", "status", "--hostname", "github.com"])
            case "xcode":
                results[tool.id] = hasDeveloperTools ? await Self.hasSimulator() : false
            case "android": results[tool.id] = AdbBridge.resolveAdbURL() != nil
            case "docker": results[tool.id] = await Self.succeeds("docker", ["info", "--format", "{{.ServerVersion}}"])
            default: break
            }
        }
    }

    private static func succeeds(_ command: String, _ arguments: [String]) async -> Bool {
        await output(command, arguments) != nil
    }

    private static func output(_ command: String, _ arguments: [String]) async -> String? {
        let result = try? await ProcessRunner.run(.developerTool(
            command, arguments: arguments, timeout: .seconds(8),
            standardOutputLimit: 256 * 1024, standardErrorLimit: 16 * 1024
        ))
        return result?.standardOutputString
    }

    private static func hasSimulator() async -> Bool {
        guard let output = await output("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "--json"]),
              let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = object["devices"] as? [String: [[String: Any]]] else { return false }
        return devices.values.joined().contains { device in
            let type = device["deviceTypeIdentifier"] as? String ?? ""
            return device["isAvailable"] as? Bool == true && (type.contains("iPhone") || type.contains("iPad"))
        }
    }
}
