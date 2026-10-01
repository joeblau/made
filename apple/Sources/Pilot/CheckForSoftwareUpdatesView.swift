import Combine
import Sparkle
import SwiftUI

@MainActor
private final class SoftwareUpdateViewModel: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

/// App-menu command backed by Sparkle's standard update UI.
struct CheckForSoftwareUpdatesView: View {
    @ObservedObject private var viewModel: SoftwareUpdateViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = SoftwareUpdateViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}

/// Places Sparkle's "Check for Updates…" after the app's About item.
struct PilotSoftwareUpdateCommands: Commands {
    let updater: SPUUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForSoftwareUpdatesView(updater: updater)
        }
    }
}
