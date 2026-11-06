import AppKit

/// The existing Drone transcript/command interface, hosted directly by AppKit.
/// Remote execution stays owned by the pane's terminal session provider.
@MainActor
final class DroneTerminalViewController: NSViewController, CockpitPanePresenting, CockpitPaneClosing, NSTextFieldDelegate {
    let pane: Pane
    var onSelect: (() -> Void)?
    private let statusLabel = NSTextField(labelWithString: "Connecting…")
    private let nameLabel = NSTextField(labelWithString: "")
    private let output = NSTextView()
    private let input = NSTextField(string: "")
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    private let retryButton = NSButton(title: "Reconnect", target: nil, action: nil)
    private let scroll = NSScrollView()
    private let presentation: DroneTerminalPresentation
    private var active = false
    private var closed = false
    private var generation = 0

    init(pane: Pane, provider: TerminalSessionProvider = .shared) {
        self.pane = pane
        presentation = DroneTerminalPresentation(pane: pane, provider: provider)
        super.init(nibName: nil, bundle: nil)
        presentation.onUpdate = { [weak self] in self?.refreshPresentation() }
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let container = NSView()
        view = container
        nameLabel.stringValue = pane.terminalDestination.droneName ?? "Drone"
        nameLabel.font = CockpitTypography.font(size: 12, weight: .semibold)
        statusLabel.font = CockpitTypography.font(size: 11)
        statusLabel.textColor = .secondaryLabelColor
        let spacer = NSView()
        let header = NSStackView(views: [nameLabel, spacer, statusLabel, retryButton])
        header.orientation = .horizontal
        header.spacing = 8
        retryButton.target = self
        retryButton.action = #selector(reconnect)
        retryButton.isHidden = true
        output.isEditable = false
        output.isSelectable = true
        output.font = CockpitTypography.font(size: 13, monospaced: true)
        output.backgroundColor = .black
        output.textColor = .white
        output.textContainerInset = NSSize(width: 12, height: 12)
        output.autoresizingMask = [.width]
        output.isVerticallyResizable = true
        output.isHorizontallyResizable = false
        output.textContainer?.widthTracksTextView = true
        output.setAccessibilityLabel("Remote terminal output")
        scroll.documentView = output
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .black
        input.placeholderString = "Remote command"
        input.font = CockpitTypography.font(size: 13, monospaced: true)
        input.delegate = self
        input.target = self
        input.action = #selector(send)
        input.setAccessibilityIdentifier("terminal.remote-command")
        sendButton.target = self
        sendButton.action = #selector(send)
        sendButton.setAccessibilityLabel("Send Remote Command")
        let commands = NSStackView(views: [input, sendButton])
        commands.orientation = .horizontal
        commands.spacing = 8
        for child in [header, scroll, commands] {
            child.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(child)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: commands.topAnchor, constant: -8),
            commands.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            commands.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            commands.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(updateFonts), name: .cockpitUIZoomDidChange, object: nil)
        updateFonts()
        updateControls()
    }

    @objc private func updateFonts() {
        nameLabel.font = CockpitTypography.font(size: 12, weight: .semibold)
        statusLabel.font = CockpitTypography.font(size: 11)
        output.font = CockpitTypography.font(size: 13, monospaced: true)
        input.font = CockpitTypography.font(size: 13, monospaced: true)
        sendButton.font = CockpitTypography.font(size: 13)
        retryButton.font = CockpitTypography.font(size: 13)
    }

    func updatePresentation(isActive: Bool, isSelected: Bool) {
        guard !closed else { return }
        if active != isActive { generation += 1 }
        active = isActive
        if active {
            _ = view
            presentation.start()
            refreshPresentation()
            if isSelected, let window = view.window,
               window.firstResponder == nil || window.firstResponder === window.contentView {
                focusPaneInput()
            }
        } else {
            presentation.stop()
        }
    }

    func focusPaneInput() {
        guard !closed, isViewLoaded, let window = view.window else { return }
        TerminalPaneInputFocus.move(to: presentation.isConnected && input.isEnabled ? input : nil, in: window)
    }

    @objc private func reconnect() {
        guard active, !closed else { return }
        generation += 1
        presentation.retry()
    }

    private func refreshPresentation() {
        guard isViewLoaded, !closed else { return }
        statusLabel.stringValue = presentation.status
        retryButton.isHidden = presentation.status == "Connecting…" || presentation.status == "Connected"
        if active { renderOutput() }
        updateControls()
    }

    private func renderOutput() {
        let latestOutput = presentation.contents
        guard output.string != latestOutput else { return }
        let followsOutput = scroll.contentView.bounds.maxY >= output.bounds.maxY - 24
        let selection = output.selectedRange()
        let previous = output.string
        if latestOutput.utf16.starts(with: previous.utf16), let storage = output.textStorage {
            let suffix = (latestOutput as NSString).substring(from: previous.utf16.count)
            storage.append(NSAttributedString(string: suffix, attributes: [
                .font: output.font ?? CockpitTypography.font(size: 13, monospaced: true),
                .foregroundColor: NSColor.white,
            ]))
        } else {
            output.string = latestOutput
        }
        let length = output.string.utf16.count
        let start = min(selection.location, length)
        output.setSelectedRange(NSRange(location: start, length: min(selection.length, length - start)))
        if followsOutput { output.scrollToEndOfDocument(nil) }
    }

    private func updateControls() {
        input.isEnabled = active && presentation.isConnected && !closed
        sendButton.isEnabled = input.isEnabled && !input.stringValue.isEmpty
    }

    func controlTextDidBeginEditing(_ obj: Notification) { onSelect?() }
    func controlTextDidChange(_ obj: Notification) { updateControls() }

    @objc private func send() {
        guard active, presentation.isConnected, !input.stringValue.isEmpty, !closed else { return }
        let command = input.stringValue
        input.stringValue = ""
        updateControls()
        let request = generation
        Task { [weak self, presentation] in
            let entered = await presentation.send(command)
            guard let self, generation == request, !closed else { return }
            if !entered {
                if input.stringValue.isEmpty { input.stringValue = command }
                updateControls()
            }
        }
    }

    func closePane() {
        closed = true
        generation += 1
        presentation.onUpdate = nil
        presentation.stop()
        if isViewLoaded { updateControls() }
        NotificationCenter.default.removeObserver(self)
    }

    isolated deinit { closePane() }
}
