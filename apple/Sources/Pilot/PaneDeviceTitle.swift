import Foundation

/// Breadcrumb titles for capture panes: "Device / Apple / SR2",
/// "Simulator / Android / Pixel 9". The prefix mirrors the New Tab path that
/// opens the pane; the last crumb is the connected device and is omitted until
/// one is chosen.
enum PaneDeviceTitle {
    /// Device names come from external hardware (CMIO, adb, simctl), so they
    /// are bounded before they reach the tab strip, menus, or accessibility.
    static let maximumNameLength = 64

    /// The breadcrumb for a capture pane, or nil for any other kind.
    static func breadcrumb(kind: PaneKind, androidTarget: AndroidPaneTarget, deviceName: String?) -> String? {
        let prefix: [String]
        switch kind {
        case .device: prefix = ["Device", "Apple"]
        case .simulator: prefix = ["Simulator", "Apple"]
        case .android: prefix = [androidTarget == .device ? "Device" : "Simulator", "Android"]
        case .terminal, .browser, .editor, .agentChat: return nil
        }
        let crumbs = prefix + [sanitizedName(deviceName)].compactMap { $0 }
        return crumbs.joined(separator: " / ")
    }

    /// Collapses control characters and whitespace runs to single spaces,
    /// trims, and truncates to `maximumNameLength` characters with an ellipsis.
    /// Returns nil when nothing printable remains.
    static func sanitizedName(_ name: String?) -> String? {
        guard let name else { return nil }
        // Bound the work before scanning an untrusted string.
        let bounded = name.prefix(maximumNameLength * 4)
        let separators = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        let words = bounded.unicodeScalars
            .split(whereSeparator: { separators.contains($0) })
            .map { String(String.UnicodeScalarView($0)) }
        let collapsed = words.joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maximumNameLength else { return collapsed }
        let head = collapsed.prefix(maximumNameLength - 1)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return head + "…"
    }
}

extension Pane {
    /// The breadcrumb for a capture pane using the name its live session
    /// reports. Registries and sessions are `@Observable`, so a title read
    /// inside observation tracking refreshes when a device connects or changes.
    @MainActor
    var deviceBreadcrumbTitle: String? {
        PaneDeviceTitle.breadcrumb(kind: kind, androidTarget: androidTarget, deviceName: liveDeviceName)
    }

    @MainActor
    private var liveDeviceName: String? {
        switch kind {
        case .device:
            let registry = DeviceCaptureRegistry.shared
            // AirPlay mirroring does not identify the sender.
            if registry.existingWirelessSession(for: id)?.isEnabled == true { return nil }
            if let session = registry.existingSession(for: id) {
                return session.deviceName ?? session.preferredDeviceName
            }
            // Before the pane view creates its session, use the persisted choice.
            return UserDefaults.standard.string(forKey: DeviceCaptureSession.preferenceNameKey(for: id))
        case .simulator:
            return SimulatorRegistry.shared.existingSession(for: id)?.bootedDeviceName
        case .android:
            return AndroidDeviceRegistry.shared.existingSession(for: id)?.connectedName
        case .terminal, .browser, .editor, .agentChat:
            return nil
        }
    }
}
