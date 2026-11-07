import Foundation
import Observation

/// The full-detail global modes listed above the workspaces in the sidebar.
/// This is the single source for their order, titles, and symbols; the sidebar
/// rows, the View menu toggles, and the Sidebar settings page all derive from
/// `allCases`, so a new mode is one case here plus its store flag.
enum SidebarFeature: String, CaseIterable, Sendable {
    case notes, remoteDesktop, docker, agenticUse, runners

    var selection: SidebarSelection {
        switch self {
        case .notes: .notes
        case .remoteDesktop: .remoteDesktop
        case .docker: .docker
        case .agenticUse: .agenticUse
        case .runners: .runners
        }
    }

    init?(_ selection: SidebarSelection) {
        switch selection {
        case .notes: self = .notes
        case .remoteDesktop: self = .remoteDesktop
        case .docker: self = .docker
        case .agenticUse: self = .agenticUse
        case .runners: self = .runners
        case .workspace: return nil
        }
    }

    var title: String {
        switch self {
        case .notes: "Notes"
        case .remoteDesktop: "Remote Desktop"
        case .docker: "Docker"
        case .agenticUse: "Agentic Use"
        case .runners: "Runners"
        }
    }

    var symbolName: String {
        switch self {
        case .notes: "note.text"
        case .remoteDesktop: "macbook.and.iphone"
        case .docker: "shippingbox"
        case .agenticUse: "chart.bar.xaxis"
        case .runners: "server.rack"
        }
    }
}

/// Which global modes the user has chosen to show in the sidebar. Only the
/// hidden set is stored, so every mode — including one added in a later
/// build — is visible by default. Raw values this build does not recognize
/// (a newer build's mode, or one since removed) are ignored when reading and
/// preserved when writing, so switching builds never loses a choice.
@Observable
@MainActor
final class SidebarFeatureVisibility {
    static let defaultsKey = "sidebar.hiddenFeatures"

    private(set) var hidden: Set<SidebarFeature>
    /// Called synchronously after the hidden set changes. `WorkspaceStore`
    /// uses it to leave a mode the moment it is hidden.
    @ObservationIgnored var onHiddenChange: ((Set<SidebarFeature>) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var unknownRawValues: [String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = (defaults.array(forKey: Self.defaultsKey) ?? []).compactMap { $0 as? String }
        hidden = Set(raw.compactMap(SidebarFeature.init(rawValue:)))
        unknownRawValues = raw.filter { SidebarFeature(rawValue: $0) == nil }
    }

    var visibleFeatures: [SidebarFeature] { SidebarFeature.allCases.filter { !hidden.contains($0) } }

    func isVisible(_ feature: SidebarFeature) -> Bool { !hidden.contains(feature) }

    func setVisible(_ visible: Bool, for feature: SidebarFeature) {
        guard isVisible(feature) != visible else { return }
        if visible { hidden.remove(feature) } else { hidden.insert(feature) }
        let stored = SidebarFeature.allCases.filter(hidden.contains).map(\.rawValue) + unknownRawValues
        if stored.isEmpty { defaults.removeObject(forKey: Self.defaultsKey) } else { defaults.set(stored, forKey: Self.defaultsKey) }
        onHiddenChange?(hidden)
    }
}

/// Mode activation keyed by `SidebarFeature`. Every programmatic entry point
/// (sidebar, View menu, ⌘0 monitor, dashboard deep links, Walkie and peer
/// workspace selection) goes through `enter…Mode`, which refuses a hidden mode.
/// Hiding the active mode leaves it, falling back to the selected workspace.
extension WorkspaceStore {
    func isSidebarFeatureVisible(_ feature: SidebarFeature) -> Bool { sidebarVisibility.isVisible(feature) }

    func isModeActive(_ feature: SidebarFeature) -> Bool {
        switch feature {
        case .notes: isNotesMode
        case .remoteDesktop: isRemoteDesktopMode
        case .docker: isDockerMode
        case .agenticUse: isAgenticUseMode
        case .runners: isRunnersMode
        }
    }

    /// The global mode currently filling the detail area, if any.
    var activeSidebarFeature: SidebarFeature? { SidebarFeature.allCases.first(where: isModeActive) }

    @discardableResult
    func enterMode(_ feature: SidebarFeature) -> Bool {
        switch feature {
        case .notes: enterNotesMode()
        case .remoteDesktop: enterRemoteDesktopMode()
        case .docker: enterDockerMode()
        case .agenticUse: enterAgenticUseMode()
        case .runners: enterRunnersMode()
        }
    }

    /// Leave the mode if it is showing; otherwise enter it (unless hidden).
    func toggleMode(_ feature: SidebarFeature) {
        if isModeActive(feature) { leaveMode(feature) } else { enterMode(feature) }
    }

    func leaveHiddenModes() {
        for feature in sidebarVisibility.hidden where isModeActive(feature) { leaveMode(feature) }
    }

    private func leaveMode(_ feature: SidebarFeature) {
        switch feature {
        case .notes: isNotesMode = false
        case .remoteDesktop: isRemoteDesktopMode = false
        case .docker: isDockerMode = false
        case .agenticUse: isAgenticUseMode = false
        case .runners: isRunnersMode = false
        }
    }

    // MARK: - Docker, Agentic Use, Runners

    // Unlike Notes and Remote Desktop there is nothing to seed first: container
    // state, usage analytics, and the runner fleet are owned by their stores.

    /// ⌃⌘0: flip into Docker mode or back out to the selected workspace.
    func toggleDockerMode() { toggleMode(.docker) }

    @discardableResult
    func enterDockerMode() -> Bool {
        guard isSidebarFeatureVisible(.docker) else { return false }
        isDockerMode = true
        return true
    }

    func toggleAgenticUseMode() { toggleMode(.agenticUse) }

    @discardableResult
    func enterAgenticUseMode() -> Bool {
        guard isSidebarFeatureVisible(.agenticUse) else { return false }
        isAgenticUseMode = true
        return true
    }

    func toggleRunnersMode() { toggleMode(.runners) }

    @discardableResult
    func enterRunnersMode() -> Bool {
        guard isSidebarFeatureVisible(.runners) else { return false }
        isRunnersMode = true
        return true
    }
}
