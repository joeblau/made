import AppKit

/// Settings > Sidebar: one switch per global mode. Hiding a mode removes its
/// sidebar row and View menu toggle and leaves it if it is showing.
@MainActor
final class SidebarSettingsViewController: NSViewController {
    let visibility: SidebarFeatureVisibility
    private var toggles: [SidebarFeature: NSSwitch] = [:]
    private let observation = NativeSettingsObservation()

    init(visibility: SidebarFeatureVisibility) {
        self.visibility = visibility
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let stack = NativeSettingsUI.column()
        let rows: [NSView] = SidebarFeature.allCases.map { feature in
            let toggle = NativeSettingsUI.toggle("Show \(feature.title) in Sidebar")
            toggle.identifier = .init("sidebar.visibility.\(feature.rawValue)")
            toggle.target = self
            toggle.action = #selector(visibilityChanged(_:))
            toggles[feature] = toggle
            return NativeSettingsUI.formRow(feature.title, icon: feature.symbolName, accessories: [toggle])
        }
        NativeSettingsUI.fillWidth(NativeSettingsUI.group("Show in Sidebar", rows), in: stack)
        view = NativeSettingsUI.page(stack)
        render()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        observation.start { [weak self] in self?.render() }
    }
    override func viewWillDisappear() {
        super.viewWillDisappear()
        observation.stop()
    }

    @objc private func visibilityChanged(_ sender: NSSwitch) {
        guard let feature = toggles.first(where: { $0.value === sender })?.key else { return }
        visibility.setVisible(sender.state == .on, for: feature)
    }

    private func render() {
        for (feature, toggle) in toggles { toggle.state = visibility.isVisible(feature) ? .on : .off }
    }
}
