import Foundation

// DeviceCaptureRegistry — keyed by Pane.id so the SwiftUI toolbar in
// `ContentView` and the `DevicePaneView` it lives next to share the
// same `DeviceCaptureSession`. Mirrors the pattern used by the Ghostty
// terminal views which look themselves up by paneID.
@MainActor
final class DeviceCaptureRegistry {
    static let shared = DeviceCaptureRegistry()

    private var sessions: [UUID: DeviceCaptureSession] = [:]
    private var wirelessSessions: [UUID: WirelessDeviceSession] = [:]

    func wirelessSession(for paneID: UUID) -> WirelessDeviceSession {
        if let session = wirelessSessions[paneID] { return session }
        let session = WirelessDeviceSession(paneID: paneID)
        wirelessSessions[paneID] = session
        return session
    }

    func session(for paneID: UUID) -> DeviceCaptureSession {
        if let existing = sessions[paneID] {
            return existing
        }
        let session = DeviceCaptureSession(paneID: paneID)
        sessions[paneID] = session
        return session
    }

    func existingSession(for paneID: UUID) -> DeviceCaptureSession? {
        sessions[paneID]
    }

    /// Releases window-bound capture while preserving both the pane's explicit
    /// device choice and this session's serial executor. A quick hide/show can
    /// then enqueue its restart behind the in-flight stop instead of creating a
    /// second `AVCaptureSession` while the first is still tearing down.
    func suspend(paneID: UUID) {
        sessions[paneID]?.stop()
        wirelessSessions[paneID]?.stop()
    }

    /// Destructive pane deletion also removes its durable device preference.
    func remove(paneID: UUID) {
        clearPreference(paneID: paneID)
    }

    /// Clears the durable choice and evicts its stopped runtime session.
    /// Deletion transactions call this only after their SwiftData save succeeds.
    func clearPreference(paneID: UUID) {
        sessions.removeValue(forKey: paneID)?.stop()
        wirelessSessions.removeValue(forKey: paneID)?.stop()
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: DeviceCaptureSession.preferenceKey(for: paneID))
        defaults.removeObject(forKey: DeviceCaptureSession.preferenceNameKey(for: paneID))
    }
}
