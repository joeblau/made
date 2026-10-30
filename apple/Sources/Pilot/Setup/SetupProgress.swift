import Foundation
import Observation

enum SetupStep: Int, CaseIterable, Identifiable {
    case welcome, permissions, tools, ready

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .permissions: "Permissions"
        case .tools: "Developer tools"
        case .ready: "Ready to go"
        }
    }
}

/// Setup completion is independent of optional grants. Skipping a feature must
/// not cause the wizard or its system prompts to return on every launch.
@MainActor
@Observable
final class SetupProgress {
    static let completionKey = "setup.completedVersion"
    static let stepKey = "setup.step"
    static let companionsKey = "setup.companionsEnabled"
    static let currentVersion = 1

    private let defaults: UserDefaults
    private(set) var needsInitialSetup: Bool
    var step: SetupStep {
        didSet { defaults.set(step.rawValue, forKey: Self.stepKey) }
    }

    init(defaults: UserDefaults = .standard, bypass: Bool = false) {
        self.defaults = defaults
        needsInitialSetup = !bypass && defaults.integer(forKey: Self.completionKey) < Self.currentVersion
        step = SetupStep(rawValue: defaults.integer(forKey: Self.stepKey)) ?? .welcome
    }

    func finish() {
        defaults.set(Self.currentVersion, forKey: Self.completionKey)
        defaults.set(SetupStep.welcome.rawValue, forKey: Self.stepKey)
        needsInitialSetup = false
    }
}
