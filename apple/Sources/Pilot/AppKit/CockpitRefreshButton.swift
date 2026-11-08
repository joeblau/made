import AppKit

/// The one refresh control used across Cockpit: an icon-only Liquid Glass
/// circle (`arrow.clockwise`). While a refresh is in flight the button is
/// replaced, in the same fixed square slot, by a small spinning indicator, so
/// neighbouring controls never shift when loading starts or ends.
@MainActor
final class CockpitRefreshButton: NSView {
    static let defaultDiameter: CGFloat = 28
    static let refreshingLabel = "Refreshing…"

    /// Exposed for tests and for callers that need the underlying control;
    /// layout and state belong to this view.
    let button = NSButton()
    let spinner = NSProgressIndicator()
    var action: @MainActor () -> Void
    private let diameter: CGFloat
    private let scalesWithZoom: Bool

    /// - Parameters:
    ///   - diameter: Unzoomed slot size. Toolbars pass the capsule height so
    ///     the circle lines up with neighbouring glass groups.
    ///   - scalesWithZoom: Multiply the slot by the Cockpit UI zoom factor.
    init(help: String, diameter: CGFloat = CockpitRefreshButton.defaultDiameter,
         scalesWithZoom: Bool = true, action: @escaping @MainActor () -> Void) {
        self.help = help
        self.action = action
        self.diameter = diameter
        self.scalesWithZoom = scalesWithZoom
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        button.translatesAutoresizingMaskIntoConstraints = false
        // The deployment target is macOS 26, so Liquid Glass is always present.
        button.bezelStyle = .glass
        button.borderShape = .circle
        button.controlSize = diameter > 30 ? .large : (diameter < 24 ? .small : .regular)
        button.title = ""
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = #selector(performRefresh)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        spinner.setAccessibilityLabel(Self.refreshingLabel)
        spinner.toolTip = Self.refreshingLabel
        addSubview(button)
        addSubview(spinner)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            setContentHuggingPriority(.required, for: axis)
            setContentCompressionResistancePriority(.required, for: axis)
        }
        applyHelp()
        applyZoom()
        NotificationCenter.default.addObserver(
            self, selector: #selector(zoomChanged), name: .cockpitUIZoomDidChange, object: nil
        )
    }

    required init?(coder: NSCoder) { nil }

    /// `true` hides the button and animates the spinner in its slot.
    var isRefreshing = false {
        didSet {
            guard oldValue != isRefreshing else { return }
            applyRefreshing()
        }
    }

    var isEnabled: Bool {
        get { button.isEnabled }
        set { button.isEnabled = newValue }
    }

    /// Tooltip and accessibility label of the inner button.
    var help: String {
        didSet { if oldValue != help { applyHelp() } }
    }

    override var toolTip: String? {
        get { button.toolTip }
        set { help = newValue ?? "Refresh" }
    }

    /// The current square side length, zoom applied.
    var slotSide: CGFloat {
        scalesWithZoom ? (diameter * CGFloat(CockpitUIZoomController.shared.factor)).rounded() : diameter
    }

    override var intrinsicContentSize: NSSize { NSSize(width: slotSide, height: slotSide) }

    private func applyHelp() {
        button.toolTip = help
        button.setAccessibilityLabel(help)
        button.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: help)
    }

    private func applyRefreshing() {
        button.isHidden = isRefreshing
        spinner.isHidden = !isRefreshing
        if isRefreshing { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    private func applyZoom() {
        let zoom = scalesWithZoom ? CGFloat(CockpitUIZoomController.shared.factor) : 1
        button.symbolConfiguration = .init(pointSize: (diameter * 0.46 * zoom).rounded(), weight: .medium)
        invalidateIntrinsicContentSize()
    }

    @objc private func zoomChanged() { applyZoom() }

    @objc private func performRefresh() {
        guard !isRefreshing else { return }
        action()
    }
}
