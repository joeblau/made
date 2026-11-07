import AppKit

/// Settings > Sidebar: one switch per global mode. Hiding a mode removes its
/// sidebar row and View menu toggle and leaves it if it is showing.
@MainActor
final class SidebarSettingsViewController: NSViewController {
    let visibility: SidebarFeatureVisibility
    private var toggles: [SidebarFeature: NSSwitch] = [:]
    private var icons: [(NSImageView, NSLayoutConstraint)] = []
    private let observation = NativeSettingsObservation()

    init(visibility: SidebarFeatureVisibility) {
        self.visibility = visibility
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let stack = NativeSettingsUI.column(spacing: 20)
        stack.addArrangedSubview(NativeSettingsUI.pageTitle("Sidebar"))
        let rows: [NSView] = SidebarFeature.allCases.map { feature in
            let toggle = NativeSettingsUI.toggle("Show \(feature.title) in Sidebar")
            toggle.identifier = .init("sidebar.visibility.\(feature.rawValue)")
            toggle.target = self
            toggle.action = #selector(visibilityChanged(_:))
            toggles[feature] = toggle
            let icon = NSImageView(image: NSImage(systemSymbolName: feature.symbolName, accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = .controlAccentColor
            icon.setAccessibilityElement(false)
            let width = icon.widthAnchor.constraint(equalToConstant: 20)
            width.isActive = true
            icons.append((icon, width))
            let row = NativeSettingsUI.formRow(feature.title, accessories: [toggle])
            row.insertArrangedSubview(icon, at: 0)
            return row
        }
        NativeSettingsUI.fillWidth(NativeSettingsUI.group("Show in Sidebar", rows), in: stack)
        view = NativeSettingsUI.scrolling(stack)
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
        let zoom = CGFloat(CockpitUIZoomController.shared.factor)
        for (icon, width) in icons {
            icon.symbolConfiguration = .init(pointSize: 13 * zoom, weight: .regular)
            width.constant = 20 * zoom
        }
    }
}
