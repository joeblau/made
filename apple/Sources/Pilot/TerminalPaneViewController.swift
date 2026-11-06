import AppKit

/// Presentation ownership is separate from the pane's persistent terminal
/// session. Detaching this controller never closes tmux or a Drone session.
@MainActor
final class TerminalPaneViewController: NSViewController, CockpitPanePresenting, CockpitPaneClosing, CockpitPaneInputFocusing {
    let pane: Pane
    var onSelect: (() -> Void)?
    private var terminalView: GhosttyMetalView?
    private var droneController: DroneTerminalViewController?
    private var active = false
    private var selected = false
    private var closed = false

    init(pane: Pane) {
        self.pane = pane
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = GhosttyRuntime.terminalBackgroundColor.cgColor
        view = container
        if pane.terminalDestination.kind == .drone {
            let controller = DroneTerminalViewController(pane: pane)
            controller.onSelect = { [weak self] in self?.onSelect?() }
            droneController = controller
            addChild(controller)
            install(controller.view)
        } else if let app = GhosttyRuntime.shared.app {
            let terminal = GhosttyMetalView(app: app, pane: pane)
            terminalView = terminal
            install(terminal)
        } else {
            let error = NSTextField(wrappingLabelWithString: "The terminal renderer could not start. Close this pane and try again.")
            error.textColor = .white
            install(error)
        }
        applyPresentation()
    }

    private func install(_ content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        applyPresentation()
    }

    func updatePresentation(isActive: Bool, isSelected: Bool) {
        active = isActive
        selected = isSelected
        if isViewLoaded { applyPresentation() }
    }

    /// Explicit pane navigation focuses the destination's own input. A remote
    /// pane that is still connecting must relinquish the previous pane's input.
    func focusPaneInput() {
        guard active, selected, !closed, !pane.isCollapsed, isViewLoaded,
              let window = view.window else { return }
        if let droneController {
            droneController.focusPaneInput()
        } else {
            TerminalPaneInputFocus.move(to: terminalView, in: window)
        }
    }

    private func applyPresentation() {
        guard !closed else { return }
        let visible = active && !pane.isCollapsed
        terminalView?.setPresentationActive(visible)
        droneController?.updatePresentation(isActive: visible, isSelected: selected)
        if visible, selected, let terminalView, let window = view.window,
           window.firstResponder == nil || window.firstResponder === window.contentView {
            window.makeFirstResponder(terminalView)
        }
    }

    func closePane() {
        guard !closed else { return }
        closed = true
        terminalView?.dispose()
        droneController?.closePane()
    }

    isolated deinit { closePane() }
}

@MainActor
enum TerminalPaneInputFocus {
    static func move(to target: NSView?, in window: NSWindow) {
        if let target, target.window === window, !target.isHiddenOrHasHiddenAncestor,
           (target as? NSControl)?.isEnabled != false, window.makeFirstResponder(target) {
            return
        }
        window.makeFirstResponder(nil)
    }
}
