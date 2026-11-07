import AppKit

/// The native window observer reports the effective appearance, including a
/// window-specific override, on connection and when its appearance changes.
@MainActor
final class AppearanceReporter: NSView {
    var isConnected: Bool {
        didSet {
            if isConnected && !oldValue { report(force: true) }
            if !isConnected { lastReportedDark = nil }
        }
    }
    var send: (Bool) -> Void
    private var lastReportedDark: Bool?

    init(isConnected: Bool = false, send: @escaping (Bool) -> Void) {
        self.isConnected = isConnected
        self.send = send
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        report(force: true)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        report(force: false)
    }

    func report(force: Bool = false) {
        guard isConnected else { return }
        let dark = CockpitAppearance.isDark(effectiveAppearance)
        guard force || dark != lastReportedDark else { return }
        lastReportedDark = dark
        send(dark)
    }
}

@MainActor
enum CockpitAppearance {
    static func isDark(_ appearance: NSAppearance) -> Bool {
        let names: [NSAppearance.Name] = [
            .aqua, .darkAqua, .vibrantLight, .vibrantDark,
            .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua
        ]
        guard let match = appearance.bestMatch(from: names) else { return false }
        return match == .darkAqua || match == .vibrantDark || match == .accessibilityHighContrastDarkAqua
    }
}
