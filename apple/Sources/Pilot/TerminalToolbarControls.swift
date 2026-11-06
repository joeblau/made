import AppKit

enum TerminalToolbarSelection {
    static func pane(for pane: Pane?) -> Pane? {
        guard let pane,
              !pane.isCollapsed,
              pane.kind == .terminal else { return nil }
        return pane
    }
}

/// Native field keeps its editing buffer stable while status/actions update.
@MainActor
final class TerminalFastCommandToolbarField: NSView, NSTextFieldDelegate {
    let pane: Pane
    let field = NSTextField(string: "")

    init(pane: Pane) {
        self.pane = pane
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        field.stringValue = TerminalFastCommandStore.command(for: pane.id)
        field.placeholderString = "Fast Command"
        field.font = CockpitTypography.font(size: 13, weight: .medium, monospaced: true)
        field.delegate = self
        field.target = self
        field.action = #selector(run)
        field.toolTip = "Fast Command"
        field.setAccessibilityIdentifier("terminal.fast-command")
        field.setAccessibilityLabel("Fast Command")
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualTo: field.heightAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(updateFont), name: .cockpitUIZoomDidChange, object: nil)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 360, height: 28) }

    func controlTextDidChange(_ obj: Notification) {
        TerminalFastCommandStore.setCommand(field.stringValue, for: pane.id)
    }

    @objc private func updateFont() {
        field.font = CockpitTypography.font(size: 13, weight: .medium, monospaced: true)
    }

    @objc private func run() {
        guard let command = TerminalFastCommandStore.executableCommand(from: field.stringValue) else { return }
        Task { [pane] in _ = await pane.terminalSession.runFastCommand(command) }
    }

    isolated deinit { NotificationCenter.default.removeObserver(self) }
}

@MainActor
final class TerminalFastCommandToolbarActions: NSView {
    let pane: Pane
    private let play = NSButton(image: NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Run Fast Command")!, target: nil, action: nil)
    private let stopButton = NSButton(image: NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop Terminal Process")!, target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private var activity: TerminalProcessActivity = .idle
    private var pollingTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var isRunningAction = false
    private var generation = 0

    init(pane: Pane) {
        self.pane = pane
        super.init(frame: NSRect(x: 0, y: 0, width: 78, height: 28))
        play.target = self
        play.action = #selector(run)
        play.toolTip = "Stop the active process and run this command"
        play.setAccessibilityIdentifier("terminal.fast-command.play")
        stopButton.target = self
        stopButton.action = #selector(stop)
        stopButton.toolTip = "Stop the active terminal process"
        stopButton.setAccessibilityIdentifier("terminal.fast-command.stop")
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let stack = NSStackView(views: [play, stopButton, spinner])
        stack.spacing = 4
        stack.orientation = .horizontal
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualTo: stack.heightAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(refreshControls), name: UserDefaults.didChangeNotification, object: nil)
        refreshControls()
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 78, height: 28) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        generation += 1
        pollingTask?.cancel()
        pollingTask = nil
        guard window != nil else { return }
        let request = generation
        let session = pane.terminalSession
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                let activity = await session.foregroundActivity(unavailableActivity: .idle)
                guard let self, generation == request, window != nil else { return }
                self.activity = activity
                refreshControls()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    @objc private func refreshControls() {
        play.isEnabled = !isRunningAction && TerminalFastCommandStore.executableCommand(from: TerminalFastCommandStore.command(for: pane.id)) != nil
        stopButton.isEnabled = !isRunningAction && activity == .running
        if isRunningAction { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    @objc private func run() {
        guard !isRunningAction,
              let command = TerminalFastCommandStore.executableCommand(from: TerminalFastCommandStore.command(for: pane.id)) else { return }
        perform { [pane] in _ = await pane.terminalSession.runFastCommand(command) }
    }

    @objc private func stop() {
        guard !isRunningAction else { return }
        perform { [pane] in _ = await pane.terminalSession.interrupt() }
    }

    private func perform(_ operation: @escaping @MainActor () async -> Void) {
        isRunningAction = true
        refreshControls()
        actionTask = Task { [weak self] in
            await operation()
            guard let self else { return }
            isRunningAction = false
            refreshControls()
            actionTask = nil
        }
    }

    isolated deinit {
        pollingTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }
}

@MainActor
final class TerminalFastCommandToolbarView: NSStackView {
    init(pane: Pane) {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 8
        addArrangedSubview(TerminalFastCommandToolbarField(pane: pane))
        addArrangedSubview(TerminalFastCommandToolbarActions(pane: pane))
    }

    required init?(coder: NSCoder) { nil }
}

/// All destructive terminal UI actions pass through this gate. Check live
/// activity at close time rather than relying on the periodically refreshed tab indicator.
@MainActor
enum TerminalCloseConfirmation {
    private static var pendingPaneIDs: Set<UUID> = []

    static func perform(
        panes: [Pane],
        activity: @MainActor (Pane) async -> TerminalProcessActivity = {
            // If runtime state cannot be verified, ask before destroying it.
            await $0.terminalSession.foregroundActivity(unavailableActivity: .running)
        },
        confirm: @MainActor ([Pane]) async -> Bool = { await present(for: $0) },
        action: @MainActor () -> Void
    ) async {
        let terminals = panes.filter { $0.kind == .terminal }
        let ids = Set(terminals.map(\.id))
        guard pendingPaneIDs.isDisjoint(with: ids) else { return }
        pendingPaneIDs.formUnion(ids)
        defer { pendingPaneIDs.subtract(ids) }

        var busy: [Pane] = []
        for pane in terminals {
            if await activity(pane) == .running {
                busy.append(pane)
            }
        }
        guard !Task.isCancelled else { return }
        if !busy.isEmpty {
            guard await confirm(busy), !Task.isCancelled else { return }
        }
        action()
    }

    private static func present(for panes: [Pane]) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        // MODAL-1: verb + object title, and a confirm button that repeats the
        // verb instead of "Anyway".
        alert.messageText = panes.count == 1 ? "Close Busy Terminal?" : "Close Busy Terminals?"
        alert.informativeText = "Closing will terminate running commands or AI sessions in "
            + (panes.count == 1 ? "this terminal." : "\(panes.count) terminals.")
            + " Any work in progress may be lost."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: panes.count == 1 ? "Close Terminal" : "Close Terminals")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].hasDestructiveAction = true
        if let window = NSApp.keyWindow {
            return await alert.beginSheetModal(for: window) == .alertSecondButtonReturn
        }
        return alert.runModal() == .alertSecondButtonReturn
    }
}

extension Workspace {
    @MainActor
    func requestRemovePane(_ pane: Pane, allowEmpty: Bool = false,
                           canRemove: @escaping @MainActor () -> Bool = { true }) {
        guard panes.count > 1 || allowEmpty, panes.contains(where: { $0 === pane }) else { return }
        Task {
            await TerminalCloseConfirmation.perform(panes: [pane]) {
                // The user can change workspaces or move panes while the
                // activity check or confirmation sheet is pending.
                guard self.panes.contains(where: { $0 === pane }), canRemove() else { return }
                self.removePane(pane, allowEmpty: allowEmpty)
            }
        }
    }
}
