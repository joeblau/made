import AppKit
import Observation

/// The persisted text-size ladder shared by native chrome and embedded engines.
enum UIZoomLadder {
    static let steps: [Double] = [0.85, 1.0, 1.15, 1.3, 1.5, 1.75, 2.0]
    static let `default`: Double = 1.0

    static func next(after current: Double) -> Double {
        steps[min(nearestIndex(to: current) + 1, steps.count - 1)]
    }

    static func previous(before current: Double) -> Double {
        steps[max(nearestIndex(to: current) - 1, 0)]
    }

    static func stepOffset(for current: Double) -> Int {
        nearestIndex(to: current) - nearestIndex(to: Self.default)
    }

    static func normalized(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return Self.default }
        return steps[nearestIndex(to: value)]
    }

    private static func nearestIndex(to value: Double) -> Int {
        guard value.isFinite else { return steps.firstIndex(of: Self.default) ?? 0 }
        return steps.indices.min { abs(steps[$0] - value) < abs(steps[$1] - value) } ?? 0
    }
}

extension Notification.Name {
    static let cockpitUIZoomDidChange = Notification.Name("app.blau.pilot.uiZoomDidChange")
}

/// Owns the same `ui.zoom` preference used by the old shell. Controllers observe
/// `factor` or the notification and update existing controls without rebuilding
/// their hierarchy or disturbing a field editor's selection.
@MainActor
@Observable
final class CockpitUIZoomController {
    static let storageKey = "ui.zoom"
    static let shared = CockpitUIZoomController(defaults: sharedDefaults())

    var factor: Double {
        didSet {
            let normalized = UIZoomLadder.normalized(factor)
            if normalized != factor { factor = normalized }
            guard oldValue != factor else { return }
            defaults.set(factor, forKey: Self.storageKey)
            NotificationCenter.default.post(name: .cockpitUIZoomDidChange, object: self)
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var preferenceObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        factor = Self.readFactor(defaults)
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let next = Self.readFactor(self.defaults)
                if next != self.factor { self.factor = next }
            }
        }
    }

    func increase() { factor = UIZoomLadder.next(after: factor) }
    func decrease() { factor = UIZoomLadder.previous(before: factor) }
    func reset() { factor = UIZoomLadder.default }

    private static func readFactor(_ defaults: UserDefaults) -> Double {
        guard defaults.object(forKey: storageKey) != nil else { return UIZoomLadder.default }
        return UIZoomLadder.normalized(defaults.double(forKey: storageKey))
    }

    private static func sharedDefaults() -> UserDefaults {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BLAU_COCKPIT_FIXTURE"] != nil || environment["XCTestConfigurationFilePath"] != nil else {
            return .standard
        }
        let name = "app.blau.pilot.fixture-ui-zoom.\(ProcessInfo.processInfo.processIdentifier)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    isolated deinit {
        if let preferenceObserver { NotificationCenter.default.removeObserver(preferenceObserver) }
    }
}

@MainActor
enum CockpitTypography {
    static func font(
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        monospaced: Bool = false,
        zoom: Double? = nil
    ) -> NSFont {
        let pointSize = size * CGFloat(zoom ?? CockpitUIZoomController.shared.factor)
        return monospaced
            ? NSFont.monospacedSystemFont(ofSize: pointSize, weight: weight)
            : NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
