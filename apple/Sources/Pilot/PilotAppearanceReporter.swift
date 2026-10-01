import SwiftUI

/// Invisible helper that observes Pilot's effective light/dark appearance and
/// reports it to connected Plotters. Sends on first connect (via the
/// `isConnected` transition) and whenever the Mac's appearance changes, so a
/// connected Plotter mirrors Pilot's mode rather than its own.
struct PilotAppearanceReporter: View {
    @Environment(\.colorScheme) private var colorScheme
    let isConnected: Bool
    let send: (Bool) -> Void

    var body: some View {
        Color.clear
            .onChange(of: colorScheme) { _, scheme in
                if isConnected { send(scheme == .dark) }
            }
            .onChange(of: isConnected) { _, connected in
                if connected { send(colorScheme == .dark) }
            }
    }
}
