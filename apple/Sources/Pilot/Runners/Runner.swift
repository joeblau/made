import Foundation

struct RunnerScope: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case enterprise, organization, repository

        var title: String {
            switch self {
            case .enterprise: "Enterprise"
            case .organization: "Organization"
            case .repository: "Repository"
            }
        }

        var symbol: String {
            switch self {
            case .enterprise: "building.2.crop.circle"
            case .organization: "building.2"
            case .repository: "folder"
            }
        }

        var inputPlaceholder: String {
            switch self {
            case .enterprise: "enterprise-slug"
            case .organization: "organization-name"
            case .repository: "owner/repository"
            }
        }
    }

    let kind: Kind
    let name: String
    var id: String { "\(kind.rawValue):\(name.lowercased())" }
    var endpoint: String {
        let path: String
        switch kind {
        case .enterprise: path = "enterprises/\(name.lowercased())"
        case .organization: path = "orgs/\(name)"
        case .repository: path = "repos/\(name)"
        }
        return "\(path)/actions/runners?per_page=100"
    }
    var settingsURL: URL? {
        let path: String
        switch kind {
        case .enterprise: path = "enterprises/\(name.lowercased())"
        case .organization: path = "organizations/\(name)"
        case .repository: path = name
        }
        return URL(string: "https://github.com/\(path)/settings/actions/runners")
    }

    static func parse(_ input: String, kind: Kind) -> RunnerScope? {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        let ownerPattern = kind == .enterprise ? "^[A-Za-z0-9][A-Za-z0-9-]*$" : "^[A-Za-z0-9][A-Za-z0-9-]{0,38}$"
        guard parts.count == (kind == .repository ? 2 : 1),
              parts[0].range(of: ownerPattern, options: .regularExpression) != nil else { return nil }
        if kind == .repository {
            guard parts[1] != ".", parts[1] != "..",
                  parts[1].range(of: "^[A-Za-z0-9_.-]{1,100}$", options: .regularExpression) != nil else { return nil }
        }
        return RunnerScope(kind: kind, name: name)
    }
}

struct GitHubRunner: Decodable, Identifiable, Sendable {
    struct Label: Decodable, Sendable {
        let name: String
        let type: String
    }

    let id: Int
    let name: String
    let os: String
    let status: String
    let busy: Bool
    let labels: [Label]

    var state: State {
        guard status == "online" else { return .offline }
        return busy ? .busy : .idle
    }

    enum State: String, CaseIterable {
        case idle = "Idle", busy = "Busy", offline = "Offline"
    }

    var platform: String {
        switch os.lowercased() {
        case "macos", "osx": "macOS"
        case "linux": "Linux"
        case "windows": "Windows"
        default: os
        }
    }

    var architecture: String? {
        labels.first { ["arm64", "x64", "arm", "x86"].contains($0.name.lowercased()) }?.name
    }
}

enum RunnerHardware: String, Codable, CaseIterable, Identifiable {
    case macMini, macStudio, macBook, imac, macProTower, macProCylinder, mac, server, desktop, virtualMachine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .macMini: "Mac mini"
        case .macStudio: "Mac Studio"
        case .macBook: "MacBook"
        case .imac: "iMac"
        case .macProTower: "Mac Pro"
        case .macProCylinder: "Mac Pro (2013)"
        case .mac: "Mac"
        case .server: "Server"
        case .desktop: "Desktop PC"
        case .virtualMachine: "Virtual machine"
        }
    }

    var assetName: String? {
        switch self {
        case .macMini: "RunnerMacMini"
        case .macBook: "RunnerMacBook"
        case .imac: "RunnerIMac"
        case .macProTower: "RunnerMacProTower"
        case .macProCylinder: "RunnerMacProCylinder"
        default: nil
        }
    }

    var symbol: String {
        switch self {
        case .macMini: "macmini"
        case .macStudio: "macstudio"
        case .macBook: "laptopcomputer"
        case .imac: "desktopcomputer"
        case .macProTower: "macpro.gen3"
        case .macProCylinder: "macpro.gen2"
        case .mac: "desktopcomputer"
        case .server: "server.rack"
        case .desktop: "pc"
        case .virtualMachine: "square.stack.3d.up"
        }
    }

    static func inferred(for runner: GitHubRunner) -> RunnerHardware {
        let text = ([runner.name] + runner.labels.map(\.name)).joined(separator: " ").lowercased()
        let compact = text.filter(\.isLetter)
        if compact.contains("macmini") { return .macMini }
        if compact.contains("macstudio") { return .macStudio }
        if compact.contains("macbook") { return .macBook }
        if compact.contains("imac") { return .imac }
        if compact.contains("macpro") {
            return text.contains("2013") || text.contains("cylinder") ? .macProCylinder : .macProTower
        }
        if text.contains("virtual") || text.contains("vm-") || text.contains("docker") { return .virtualMachine }
        if ["macos", "osx"].contains(runner.os.lowercased()) { return .mac }
        return runner.os.lowercased() == "windows" ? .desktop : .server
    }
}

struct RunnerPresentation: Codable, Equatable {
    var name = ""
    var hardware: RunnerHardware?
}
