import Foundation
import Observation

/// SimulatorRegistry — keyed by `Pane.id` so the `ContentView` toolbar and the
/// `SimulatorPaneView` next to it share one `SimulatorSession`. Mirrors
/// `DeviceCaptureRegistry`. `remove(paneID:)` stops mirroring but deliberately
/// leaves the simulator booted (another tool may be using it).
// Observable so pane titles re-render when a session first appears.
@MainActor
@Observable
final class SimulatorRegistry {
    static let shared = SimulatorRegistry()

    private var sessions: [UUID: SimulatorSession] = [:]

    func session(for paneID: UUID) -> SimulatorSession {
        if let existing = sessions[paneID] {
            return existing
        }
        let session = SimulatorSession()
        sessions[paneID] = session
        return session
    }

    func existingSession(for paneID: UUID) -> SimulatorSession? {
        sessions[paneID]
    }

    func remove(paneID: UUID) {
        guard let session = sessions.removeValue(forKey: paneID) else { return }
        session.stop()
    }
}
