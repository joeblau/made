import AppKit
import Combine
import Sparkle

/// Own this action for as long as its native menu item or button is installed.
@MainActor
final class SoftwareUpdateAction: NSObject, NSMenuItemValidation {
    private let updater: SPUUpdater
    private var subscription: AnyCancellable?
    private var buttons: [NSButton] = []
    private var menuItems: [NSMenuItem] = []

    init(updater: SPUUpdater) {
        self.updater = updater
        super.init()
        subscription = updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                MainActor.assumeIsolated {
                    self?.buttons.forEach { $0.isEnabled = enabled }
                    self?.menuItems.forEach { $0.isEnabled = enabled }
                }
            }
    }

    func makeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        item.target = self
        item.isEnabled = updater.canCheckForUpdates
        menuItems.append(item)
        return item
    }

    func makeButton() -> NSButton {
        let button = NativeSettingsButton("Check for Updates…") { [weak self] in self?.checkForUpdates() }
        button.isEnabled = updater.canCheckForUpdates
        buttons.append(button)
        return button
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { updater.canCheckForUpdates }

    @objc private func checkForUpdates() {
        guard updater.canCheckForUpdates else { return }
        updater.checkForUpdates()
    }
}
