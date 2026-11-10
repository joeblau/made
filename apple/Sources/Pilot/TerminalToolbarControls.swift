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
    private let stack = NSStackView()
    private var activity: TerminalProcessActivity = .idle
    private var pollingTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var isRunningAction = false
    private var generation = 0

    init(pane: Pane) {
        self.pane = pane
        super.init(frame: NSRect(x: 0, y: 0, width: 60, height: 28))
        for button in [play, stopButton] {
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.symbolConfiguration = .init(pointSize: 13, weight: .medium)
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 28),
                button.heightAnchor.constraint(equalToConstant: 28),
            ])
        }
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
        for view in [play, stopButton, spinner] { stack.addArrangedSubview(view) }
        // The spinner only takes space while an action runs.
        stack.detachesHiddenViews = true
        stack.spacing = 2
        stack.orientation = .horizontal
        stack.frame = bounds
        stack.autoresizingMask = [.width, .height]
        addSubview(stack)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshControls), name: UserDefaults.didChangeNotification, object: nil)
        refreshControls()
    }

    required init?(coder: NSCoder) { nil }

    /// Horizontal in the terminal toolbar; vertical in a hidden pane's strip.
    var orientation: NSUserInterfaceLayoutOrientation {
        get { stack.orientation }
        set {
            guard stack.orientation != newValue else { return }
            stack.orientation = newValue
            invalidateIntrinsicContentSize()
        }
    }

    /// Liquid Glass circles, used in a hidden pane's strip where the buttons
    /// float over the strip instead of sitting in a toolbar.
    var usesGlassCircles = false {
        didSet {
            guard oldValue != usesGlassCircles else { return }
            for button in [play, stopButton] {
                if usesGlassCircles {
                    button.isBordered = true
                    button.bezelStyle = .glass
                    button.borderShape = .circle
                } else {
                    button.isBordered = false
                }
            }
            stack.spacing = usesGlassCircles ? Self.glassSpacing : 2
            invalidateIntrinsicContentSize()
        }
    }
    static let glassSpacing: CGFloat = 6

    /// Length along `orientation` for the visible buttons (plus the spinner
    /// while an action runs).
    var preferredLength: CGFloat {
        let count: CGFloat = isRunningAction ? 3 : 2
        return 28 * count + stack.spacing * (count - 1)
    }

    override var intrinsicContentSize: NSSize {
        orientation == .horizontal ? NSSize(width: preferredLength, height: 28) : NSSize(width: 28, height: preferredLength)
    }

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
        let command = TerminalFastCommandStore.executableCommand(from: TerminalFastCommandStore.command(for: pane.id))
        play.isEnabled = !isRunningAction && command != nil
        play.toolTip = command.map { "Stop the active process and run \($0)" } ?? "Set a Fast Command in the terminal toolbar"
        stopButton.isEnabled = !isRunningAction && activity == .running
        if isRunningAction { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        if spinner.isHidden == isRunningAction {
            spinner.isHidden = !isRunningAction
            invalidateIntrinsicContentSize()
            superview?.needsLayout = true
        }
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
        alignment = .centerY
        spacing = 6
        // Leave room for the field's focus ring inside the toolbar's glass.
        edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 6)
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
    /// Whether the user can close this pane: any pane while others remain,
    /// and the last one only when it isn't already the New Tab page (closing
    /// it would just bring the same page back).
    func canClosePane(_ pane: Pane) -> Bool {
        panes.contains(where: { $0 === pane }) && (panes.count > 1 || !pane.isChoosingMode)
    }

    /// Opens on the New Tab page instead of an automatic terminal. For a
    /// freshly created workspace, whose only pane is the initial terminal.
    func startOnNewTab() {
        guard panes.count == 1, let pane = panes.first else { return }
        pane.isChoosingMode = true
        if frontmostTerminalPaneID == pane.id { frontmostTerminalPaneID = nil }
    }

    /// A workspace with no panes shows the New Tab page.
    @discardableResult
    func ensureNewTabWhenEmpty() -> Pane? {
        guard panes.isEmpty else { return nil }
        return addPane(kind: .terminal, side: .right, chooseModeOnOpen: true)
    }

    /// User-initiated close. Closing the last pane leaves the New Tab page in
    /// its place, so a workspace is never blank.
    @MainActor
    func requestClosePane(_ pane: Pane, canRemove: @escaping @MainActor () -> Bool = { true }) {
        guard canClosePane(pane) else { return }
        Task {
            await TerminalCloseConfirmation.perform(panes: [pane]) {
                // The user can change workspaces or move panes while the
                // activity check or confirmation sheet is pending.
                guard self.canClosePane(pane), canRemove() else { return }
                guard self.panes.count == 1 else {
                    self.removePane(pane)
                    return
                }
                self.replaceLastPaneWithNewTab(pane)
            }
        }
    }

    /// Swaps the only pane for the New Tab page. When the removal can't be
    /// saved, the original pane, its selection, and its frontmost terminal
    /// stay exactly as they were and no placeholder is left behind.
    @MainActor
    @discardableResult
    func replaceLastPaneWithNewTab(
        _ pane: Pane,
        performSave: (ModelContext) throws -> Void = { try $0.save() }
    ) -> Bool {
        guard panes.count == 1, panes.first === pane else { return false }
        // #437: removePane refuses while earlier work is unsaved, so don't
        // create a placeholder that the refusal would strand.
        guard modelContext?.saveEarlierChangesBeforeDestructiveChange(
            operation: "Removing pane",
            performSave: performSave
        ) ?? true else { return false }
        let selection = selectedPaneID
        let frontmost = frontmostTerminalPaneID
        let placeholder = addPane(kind: .terminal, side: .right, chooseModeOnOpen: true, performSave: performSave)
        guard !removePane(pane, performSave: performSave) else { return true }
        // Keep the original pane and drop the unused placeholder directly.
        // removePane(placeholder) would hit the same save-earlier gate when
        // the placeholder's own insert failed to save, leaving it behind.
        placeholder.tearDownRuntimeResources(preservingDevicePreference: true)
        panes.removeAll { $0 === placeholder }
        selectedPaneID = selection
        frontmostTerminalPaneID = frontmost
        syncDefaultRootPathForPaneTransfer()
        if let context = modelContext {
            // Cancels a still-pending insert; otherwise deletes the saved
            // placeholder. A failed save stays pending for retry.
            context.delete(placeholder)
            _ = context.saveReporting(operation: "Removing pane", performSave: performSave)
        }
        placeholder.isChoosingMode = false
        return false
    }

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
