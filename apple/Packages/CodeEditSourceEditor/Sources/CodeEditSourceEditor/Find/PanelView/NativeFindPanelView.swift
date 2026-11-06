import AppKit
import Combine

/// AppKit find/replace controls using the upstream search and undo model.
final class NativeFindPanelView: NSVisualEffectView, NSSearchFieldDelegate {
    private let model: FindPanelViewModel
    private let searchField = NSSearchField()
    private let replaceField = NSTextField()
    private let countLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let optionsButton = NSButton()
    private let doneButton = NSButton()
    private let replaceButton = NSButton(title: "Replace", target: nil, action: nil)
    private let replaceAllButton = NSButton(title: "All", target: nil, action: nil)
    private let findRow = NSStackView()
    private let replaceRow = NSStackView()
    private var subscriptions = Set<AnyCancellable>()
    private var eventMonitor: Any?
    private var heightConstraint: NSLayoutConstraint!

    init(viewModel: FindPanelViewModel) {
        model = viewModel
        super.init(frame: .zero)
        isHidden = !model.isShowingFindPanel
        translatesAutoresizingMaskIntoConstraints = false
        material = .headerView
        blendingMode = .withinWindow
        state = .followsWindowActiveState
        searchField.placeholderString = "Find"
        searchField.setAccessibilityLabel("Find in document")
        replaceField.placeholderString = "Replace with"
        replaceField.setAccessibilityLabel("Replacement text")
        for field in [searchField, replaceField] {
            field.delegate = self
            field.controlSize = .small
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        searchField.sendsSearchStringImmediately = true
        configure(previousButton, symbol: "chevron.up", title: "Previous Match", action: #selector(previous))
        configure(nextButton, symbol: "chevron.down", title: "Next Match", action: #selector(next))
        configure(optionsButton, symbol: "line.3.horizontal.decrease", title: "Find options", action: #selector(options))
        configure(doneButton, symbol: "xmark", title: "Close Find", action: #selector(done))
        replaceButton.target = self
        replaceButton.action = #selector(replace)
        replaceAllButton.target = self
        replaceAllButton.action = #selector(replaceAll)
        for button in [replaceButton, replaceAllButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        countLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        countLabel.textColor = .secondaryLabelColor
        for row in [findRow, replaceRow] {
            row.orientation = .horizontal
            row.spacing = 4
            row.alignment = .centerY
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)
        }
        [searchField, countLabel, previousButton, nextButton, optionsButton, doneButton].forEach(findRow.addArrangedSubview)
        [replaceField, replaceButton, replaceAllButton].forEach(replaceRow.addArrangedSubview)
        heightConstraint = heightAnchor.constraint(equalToConstant: model.panelHeight)
        NSLayoutConstraint.activate([
            heightConstraint,
            findRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            findRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            findRow.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            findRow.heightAnchor.constraint(equalToConstant: 22),
            replaceRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            replaceRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            replaceRow.topAnchor.constraint(equalTo: findRow.bottomAnchor, constant: 3),
            replaceRow.heightAnchor.constraint(equalToConstant: 22)
        ])
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &subscriptions)
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }

    override func layout() {
        super.layout()
        countLabel.isHidden = bounds.width < 440
        previousButton.isHidden = bounds.width < 240
        nextButton.isHidden = bounds.width < 240
        replaceButton.isHidden = bounds.width < 240
        replaceAllButton.isHidden = bounds.width < 240
    }

    private func configure(_ button: NSButton, symbol: String, title: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
    }

    private func refresh() {
        if searchField.stringValue != model.findText { searchField.stringValue = model.findText }
        if replaceField.stringValue != model.replaceText { replaceField.stringValue = model.replaceText }
        countLabel.stringValue = model.findText.isEmpty ? "" : "\(model.matchCount) matches"
        countLabel.setAccessibilityLabel(countLabel.stringValue)
        previousButton.isEnabled = !model.matchesEmpty
        nextButton.isEnabled = !model.matchesEmpty
        replaceButton.isEnabled = !model.matchesEmpty
        replaceAllButton.isEnabled = !model.matchesEmpty
        replaceRow.isHidden = model.mode != .replace
        heightConstraint.constant = model.panelHeight
        if model.isShowingFindPanel && model.isFocused,
           window?.firstResponder !== searchField.currentEditor(),
           window?.firstResponder !== replaceField.currentEditor() {
            searchField.selectText(nil)
        }
        needsLayout = true
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as AnyObject? === searchField {
            model.findText = searchField.stringValue
            model.findTextDidChange()
        } else if notification.object as AnyObject? === replaceField {
            model.replaceText = replaceField.stringValue
            model.replaceTextDidChange()
        }
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        model.isFocused = true
        model.addMatchEmphases(flashCurrent: false)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // A move between native fields must not hide all matches.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let responder = self.window?.firstResponder
            self.model.isFocused = responder != nil &&
                (responder === self.searchField.currentEditor() || responder === self.replaceField.currentEditor())
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { previous(nil) } else { next(nil) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            done(nil)
            return true
        default:
            return false
        }
    }

    @objc private func previous(_ sender: Any?) { model.moveToPreviousMatch() }
    @objc private func next(_ sender: Any?) { model.moveToNextMatch() }
    @objc private func replace(_ sender: Any?) { model.replace() }
    @objc private func replaceAll(_ sender: Any?) { model.replaceAll() }
    @objc private func done(_ sender: Any?) { model.dismiss?() }
    @objc private func toggleReplace(_ sender: Any?) {
        model.mode = model.mode == .find ? .replace : .find
    }
    @objc private func toggleCase(_ sender: Any?) { model.matchCase.toggle(); model.find() }
    @objc private func toggleWrap(_ sender: Any?) { model.wrapAround.toggle(); model.find() }
    @objc private func selectMethod(_ sender: NSMenuItem) {
        guard FindMethod.allCases.indices.contains(sender.tag) else { return }
        model.findMethod = FindMethod.allCases[sender.tag]
    }

    @objc private func options(_ sender: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ title: String, _ action: Selector, checked: Bool = false, enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.state = checked ? .on : .off
            item.isEnabled = enabled
            menu.addItem(item)
            return item
        }
        _ = item("Show Replace", #selector(toggleReplace), checked: model.mode == .replace)
        menu.addItem(.separator())
        for (index, method) in FindMethod.allCases.enumerated() {
            item(method.displayName, #selector(selectMethod), checked: method == model.findMethod).tag = index
        }
        menu.addItem(.separator())
        _ = item("Match Case", #selector(toggleCase), checked: model.matchCase)
        _ = item("Wrap Around", #selector(toggleWrap), checked: model.wrapAround)
        menu.addItem(.separator())
        _ = item("Previous Match", #selector(previous), enabled: !model.matchesEmpty)
        _ = item("Next Match", #selector(next), enabled: !model.matchesEmpty)
        _ = item("Replace", #selector(replace), enabled: !model.matchesEmpty)
        _ = item("Replace All", #selector(replaceAll), enabled: !model.matchesEmpty)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    func addEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.model.isShowingFindPanel, event.window === self.window,
                  self.window?.isKeyWindow == true else { return event }
            let responder = self.window?.firstResponder
            let ownsFocus = responder === self.searchField.currentEditor() ||
                responder === self.replaceField.currentEditor() || self.model.isTargetFirstResponder
            guard ownsFocus else { return event }
            if event.keyCode == 53 { self.model.dismiss?(); return nil }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.charactersIgnoringModifiers == "g" {
                self.model.moveToNextMatch()
                return nil
            }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift],
               event.charactersIgnoringModifiers == "g" {
                self.model.moveToPreviousMatch()
                return nil
            }
            return event
        }
    }

    func removeEventMonitor() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }
}

