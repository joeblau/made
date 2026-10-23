import Foundation
@testable import Pilot

/// Stable asset names are the contract with the website. Keep fixtures in the
/// test bundle; none of this data ships in Cockpit or touches a real workspace.
enum SnapshotScene: String, CaseIterable, Codable {
    case workspace
    case editor
    case browser
    case notes
    case remoteDesktop = "remote-desktop"
    case docker
    case agenticUse = "agentic-use"
    case runners
    case actions
    case tasks
    case pullRequests = "pull-requests"
    case files
    case usage
    case device

    var title: String {
        switch self {
        case .notes: "Notes"
        case .remoteDesktop: "Remote Desktop"
        case .docker: "Docker"
        case .agenticUse: "Agentic Use"
        case .runners: "Runners"
        case .editor: "atlas-api"
        case .device: "orbit-ios"
        default: "orbit-web"
        }
    }

    var inspector: InspectorTab? {
        switch self {
        case .actions: .actions
        case .tasks: .tasks
        case .pullRequests: .pullRequests
        case .files: .filesystem
        case .usage: .usage
        default: nil
        }
    }

    var selection: SidebarSelection? {
        switch self {
        case .notes: .notes
        case .remoteDesktop: .remoteDesktop
        case .docker: .docker
        case .agenticUse: .agenticUse
        case .runners: .runners
        default: nil
        }
    }

    var caption: String {
        switch self {
        case .workspace: "Two agents building Orbit in parallel"
        case .editor: "Atlas API source beside its test output"
        case .browser: "Orbit browser preview beside a running agent"
        case .notes: "Release notes, checklists, and project scratchpads"
        case .remoteDesktop: "A four-machine remote development workspace"
        case .docker: "Local application stacks and container status"
        case .agenticUse: "Agent cost, token history, and cache savings"
        case .runners: "A mixed fleet of idle, busy, and offline runners"
        case .actions: "Workflow results alongside the project"
        case .tasks: "Project tasks alongside an agent session"
        case .pullRequests: "Pull requests ready for review"
        case .files: "The project file tree beside the workspace"
        case .usage: "Provider plan usage and credit balances"
        case .device: "Orbit preview on the web and an iPhone"
        }
    }
}

struct SnapshotOptions {
    let scenes: [SnapshotScene]
    let appearances: [String]
    let width: Int
    let height: Int
    let scale: Int

    init(environment: [String: String]) throws {
        let names = environment["MADE_SNAPSHOT_SCENES"] ?? "all"
        if names == "all" {
            scenes = SnapshotScene.allCases
        } else {
            scenes = try names.split(separator: ",", omittingEmptySubsequences: false).map {
                guard let scene = SnapshotScene(rawValue: String($0)) else {
                    throw SnapshotError.invalidOption("Unknown scene: \($0)")
                }
                return scene
            }
        }
        let theme = environment["MADE_SNAPSHOT_APPEARANCE"] ?? "both"
        guard ["both", "light", "dark"].contains(theme) else {
            throw SnapshotError.invalidOption("Unknown appearance: \(theme)")
        }
        appearances = theme == "both" ? ["light", "dark"] : [theme]
        width = try Self.integer("WIDTH", environment, fallback: 1440, range: 1280...2560)
        height = try Self.integer("HEIGHT", environment, fallback: 960, range: 800...1600)
        scale = try Self.integer("SCALE", environment, fallback: 2, range: 1...2)
        guard !scenes.isEmpty, Set(scenes).count == scenes.count else {
            throw SnapshotError.invalidOption("Scenes must be nonempty and unique")
        }
    }

    private static func integer(
        _ key: String, _ environment: [String: String], fallback: Int, range: ClosedRange<Int>
    ) throws -> Int {
        guard let raw = environment["MADE_SNAPSHOT_\(key)"] else { return fallback }
        guard let value = Int(raw), range.contains(value) else {
            throw SnapshotError.invalidOption("\(key) must be in \(range)")
        }
        return value
    }
}

enum SnapshotError: Error {
    case invalidOption(String)
    case renderFailed(String)
    case fixtureTimeout
}
