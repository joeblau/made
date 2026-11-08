import Foundation
import Observation

/// AndroidDeviceRegistry — keyed by `Pane.id` so the `ContentView` toolbar and
/// the `AndroidPaneView` next to it share one `AndroidDeviceSession`. Mirrors
/// `SimulatorRegistry`. `remove(paneID:)` stops mirroring but deliberately
/// leaves the device untouched.
// Observable so pane titles re-render when a session first appears.
@MainActor
@Observable
final class AndroidDeviceRegistry {
    static let shared = AndroidDeviceRegistry()

    private var sessions: [UUID: AndroidDeviceSession] = [:]
    @ObservationIgnored private var targets: [UUID: AndroidPaneTarget] = [:]

    func configure(target: AndroidPaneTarget, for paneID: UUID) {
        targets[paneID] = target
        sessions[paneID]?.setTarget(target)
    }

    func session(for paneID: UUID) -> AndroidDeviceSession {
        if let existing = sessions[paneID] {
            return existing
        }
        let session = AndroidDeviceSession(target: targets[paneID])
        sessions[paneID] = session
        return session
    }

    func existingSession(for paneID: UUID) -> AndroidDeviceSession? {
        sessions[paneID]
    }

    /// Pause an existing pane without creating a session merely because an
    /// inactive workspace is mounted in SwiftUI's background stack.
    func suspend(paneID: UUID) {
        sessions[paneID]?.suspend()
    }

    /// Resume the pane selected by the user. `session(for:)` is intentional:
    /// the active presentation owns the runtime and may be the first view to
    /// touch a persisted Android pane after launch.
    func resume(paneID: UUID) {
        session(for: paneID).resume()
    }

    func remove(paneID: UUID) {
        targets.removeValue(forKey: paneID)
        guard let session = sessions.removeValue(forKey: paneID) else { return }
        session.stop()
    }
}
