import CoreGraphics
import Foundation
import IOKit.pwr_mgt

enum AwakeAssertionKind: Hashable {
    case preventIdleSystemSleep
    case preventDisplaySleep
    case preventSystemSleep
}

enum AwakeSessionPolicy {
    static let screenSaverDelay: TimeInterval = 45 * 60

    static func requiredAssertions(
        isEnabled: Bool,
        allowDisplaySleep: Bool,
        allowSystemSleepWhenDisplayClosed: Bool,
        screenSaverAllowanceActive: Bool
    ) -> Set<AwakeAssertionKind> {
        guard isEnabled else { return [] }

        var assertions: Set<AwakeAssertionKind> = [.preventIdleSystemSleep]
        if !allowDisplaySleep && !screenSaverAllowanceActive {
            assertions.insert(.preventDisplaySleep)
        }
        if !allowSystemSleepWhenDisplayClosed {
            assertions.insert(.preventSystemSleep)
        }
        return assertions
    }

    static func formattedDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%02dh %02dm %02ds", hours, minutes, seconds)
        }
        return String(format: "%02dm %02ds", minutes, seconds)
    }
}

@MainActor
private protocol AwakeAssertionCoordinating: AnyObject {
    func apply(_ requiredAssertions: Set<AwakeAssertionKind>) -> String?
}

@MainActor
private final class SystemAwakeAssertionCoordinator: AwakeAssertionCoordinating {
    private var assertionIDs: [AwakeAssertionKind: IOPMAssertionID] = [:]

    func apply(_ requiredAssertions: Set<AwakeAssertionKind>) -> String? {
        for kind in assertionIDs.keys where !requiredAssertions.contains(kind) {
            release(kind)
        }

        for kind in requiredAssertions where assertionIDs[kind] == nil {
            var assertionID = IOPMAssertionID()
            let result = IOPMAssertionCreateWithName(
                assertionType(for: kind),
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Cockpit Keep Awake Session" as CFString,
                &assertionID
            )
            guard result == kIOReturnSuccess else {
                return "macOS rejected a power assertion (\(result))."
            }
            assertionIDs[kind] = assertionID
        }
        return nil
    }

    private func assertionType(for kind: AwakeAssertionKind) -> CFString {
        switch kind {
        case .preventIdleSystemSleep:
            kIOPMAssertionTypeNoIdleSleep as CFString
        case .preventDisplaySleep:
            kIOPMAssertionTypeNoDisplaySleep as CFString
        case .preventSystemSleep:
            kIOPMAssertionTypePreventSystemSleep as CFString
        }
    }

    private func release(_ kind: AwakeAssertionKind) {
        guard let assertionID = assertionIDs.removeValue(forKey: kind) else { return }
        IOPMAssertionRelease(assertionID)
    }

    deinit {
        for assertionID in assertionIDs.values {
            IOPMAssertionRelease(assertionID)
        }
    }
}

@MainActor
@Observable
final class AwakeSessionController {
    static let shared = AwakeSessionController()

    private enum DefaultsKey {
        static let allowDisplaySleep = "awake.allowDisplaySleep"
        static let allowSystemSleepWhenDisplayClosed = "awake.allowSystemSleepWhenDisplayClosed"
        static let allowScreenSaverAfter45Minutes = "awake.allowScreenSaverAfter45Minutes"
    }

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            isEnabled ? startSession() : stopSession()
        }
    }

    var allowDisplaySleep: Bool {
        didSet {
            guard allowDisplaySleep != oldValue else { return }
            defaults.set(allowDisplaySleep, forKey: DefaultsKey.allowDisplaySleep)
            refreshAssertions()
        }
    }

    var allowSystemSleepWhenDisplayClosed: Bool {
        didSet {
            guard allowSystemSleepWhenDisplayClosed != oldValue else { return }
            defaults.set(
                allowSystemSleepWhenDisplayClosed,
                forKey: DefaultsKey.allowSystemSleepWhenDisplayClosed
            )
            refreshAssertions()
        }
    }

    var allowScreenSaverAfter45Minutes: Bool {
        didSet {
            guard allowScreenSaverAfter45Minutes != oldValue else { return }
            defaults.set(
                allowScreenSaverAfter45Minutes,
                forKey: DefaultsKey.allowScreenSaverAfter45Minutes
            )
            updateScreenSaverAllowance()
            refreshAssertions()
        }
    }

    private(set) var elapsedDuration: TimeInterval = 0
    private(set) var assertionError: String?

    var sessionStatus: String {
        if isEnabled {
            "\(AwakeSessionPolicy.formattedDuration(elapsedDuration)) active"
        } else if elapsedDuration > 0 {
            "Stopped at \(AwakeSessionPolicy.formattedDuration(elapsedDuration))"
        } else {
            "Off"
        }
    }

    private let defaults: UserDefaults
    private let assertionCoordinator: AwakeAssertionCoordinating
    private var startedAt: Date?
    private var tickerTask: Task<Void, Never>?
    private var screenSaverAllowanceActive = false

    private init(
        defaults: UserDefaults = .standard,
        assertionCoordinator: AwakeAssertionCoordinating = SystemAwakeAssertionCoordinator()
    ) {
        self.defaults = defaults
        self.assertionCoordinator = assertionCoordinator
        self.allowDisplaySleep = Self.storedBool(
            forKey: DefaultsKey.allowDisplaySleep,
            defaultValue: false,
            defaults: defaults
        )
        self.allowSystemSleepWhenDisplayClosed = Self.storedBool(
            forKey: DefaultsKey.allowSystemSleepWhenDisplayClosed,
            defaultValue: true,
            defaults: defaults
        )
        self.allowScreenSaverAfter45Minutes = Self.storedBool(
            forKey: DefaultsKey.allowScreenSaverAfter45Minutes,
            defaultValue: false,
            defaults: defaults
        )
    }

    private func startSession() {
        elapsedDuration = 0
        startedAt = Date()
        updateScreenSaverAllowance()
        refreshAssertions()

        tickerTask?.cancel()
        tickerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.isEnabled else { return }
                self.tick()
            }
        }
    }

    private func stopSession() {
        tick()
        tickerTask?.cancel()
        tickerTask = nil
        startedAt = nil
        screenSaverAllowanceActive = false
        assertionError = assertionCoordinator.apply([])
    }

    private func tick() {
        if let startedAt {
            elapsedDuration = Date().timeIntervalSince(startedAt)
        }
        let previousAllowance = screenSaverAllowanceActive
        updateScreenSaverAllowance()
        if previousAllowance != screenSaverAllowanceActive {
            refreshAssertions()
        }
    }

    private func updateScreenSaverAllowance() {
        screenSaverAllowanceActive = isEnabled
            && allowScreenSaverAfter45Minutes
            && Self.systemIdleDuration >= AwakeSessionPolicy.screenSaverDelay
    }

    private func refreshAssertions() {
        let required = AwakeSessionPolicy.requiredAssertions(
            isEnabled: isEnabled,
            allowDisplaySleep: allowDisplaySleep,
            allowSystemSleepWhenDisplayClosed: allowSystemSleepWhenDisplayClosed,
            screenSaverAllowanceActive: screenSaverAllowanceActive
        )
        assertionError = assertionCoordinator.apply(required)
    }

    private static var systemIdleDuration: TimeInterval {
        let anyInputEvent = CGEventType(rawValue: ~0) ?? .null
        return CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: anyInputEvent
        )
    }

    private static func storedBool(
        forKey key: String,
        defaultValue: Bool,
        defaults: UserDefaults
    ) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }
}
