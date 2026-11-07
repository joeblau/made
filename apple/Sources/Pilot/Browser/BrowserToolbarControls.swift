import AppKit

/// Resolves the browser toolbar from the pane that owns it. Main and Extension
/// both use this gate so a collapsed/non-browser pane cannot leave stale
/// controls behind, and Extension always binds to its own persisted
/// `BrowserState` rather than the similarly selected pane in Main.
enum BrowserToolbarSelection {
    static func state(for pane: Pane?) -> BrowserState? {
        guard let pane,
              !pane.isCollapsed,
              pane.kind == .browser else { return nil }
        return pane.browserState
    }
}

/// Scene-local browser selection used by menu commands. Revealing a browser
/// preserves focused-pane mode by moving that focus to the browser instead of
/// leaving `focusedPaneID` attached to a hidden pane.
@MainActor
enum BrowserCommandSelection {
    static func selectedState(
        in workspace: Workspace?,
        supporting capability: BrowserCapability? = nil
    ) -> BrowserState? {
        guard let state = BrowserToolbarSelection.state(for: workspace?.selectedPane) else {
            return nil
        }
        if let capability, !state.supports(capability) {
            return nil
        }
        return state
    }

    static func hasBrowser(
        in workspace: Workspace?,
        supporting capability: BrowserCapability? = nil
    ) -> Bool {
        workspace?.panes.contains { pane in
            guard pane.kind == .browser,
                  let state = pane.browserState else { return false }
            return capability.map(state.supports) ?? true
        } ?? false
    }

    @discardableResult
    static func revealBrowser(
        in workspace: Workspace?,
        supporting capability: BrowserCapability? = nil
    ) -> BrowserState? {
        guard let workspace else { return nil }

        func isEligible(_ pane: Pane) -> Bool {
            guard pane.kind == .browser,
                  let state = pane.browserState else { return false }
            return capability.map(state.supports) ?? true
        }

        let browser: Pane
        if let selectedPane = workspace.selectedPane,
           isEligible(selectedPane) {
            browser = selectedPane
        } else if let firstBrowser = workspace.sortedPanes.first(where: isEligible) {
            browser = firstBrowser
        } else {
            return nil
        }

        if let focusedPaneID = workspace.focusedPaneID,
           focusedPaneID != browser.id {
            workspace.focusPane(browser)
        } else {
            workspace.expandPane(browser)
            workspace.selectedPaneID = browser.id
        }
        return BrowserToolbarSelection.state(for: browser)
    }
}

/// AppKit bridge for Safari-style ⌘L behavior. Restricting the lookup to the
/// key window is what lets Main and Extension expose simultaneous address
/// fields without one window stealing focus from the other.
@MainActor
enum BrowserAddressFocus {
    static func selectAddressFieldInKeyWindow() {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow,
                  let field = findAddressTextField(in: window.contentView)
                    ?? findAddressTextField(in: window.contentView?.superview) else { return }
            field.selectText(nil)
        }
    }

    @discardableResult
    static func selectAddressField(in window: NSWindow, ownedBy state: BrowserState) -> Bool {
        guard window.attachedSheet == nil,
              let toolbar = findToolbar(in: window.contentView?.superview ?? window.contentView, ownedBy: state)
        else { return false }
        return toolbar.focusAddressField()
    }

    private static func findToolbar(in view: NSView?, ownedBy state: BrowserState) -> BrowserToolbarView? {
        guard let view, !view.isHiddenOrHasHiddenAncestor else { return nil }
        if let toolbar = view as? BrowserToolbarView, toolbar.state === state { return toolbar }
        for child in view.subviews {
            if let toolbar = findToolbar(in: child, ownedBy: state) { return toolbar }
        }
        return nil
    }

    private static func findAddressTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField,
           field.placeholderString == "URL" {
            return field
        }
        for subview in view.subviews {
            if let found = findAddressTextField(in: subview) {
                return found
            }
        }
        return nil
    }
}

/// One native toolbar view per selected browser. Its address editor is never
/// replaced by navigation observations while the user has an unsubmitted draft.
@MainActor
final class BrowserToolbarView: NSView, NSTextFieldDelegate {
    let state: BrowserState
    private let observation = BrowserNativeObservation()
    private let field = NSTextField()
    private let back: BrowserNativeButton
    private let forward: BrowserNativeButton
    private let reload: BrowserNativeButton
    private let find: BrowserNativeButton
    private let tools: BrowserNativeButton
    private let download = NSProgressIndicator()
    private var clearingTask: Task<Void, Never>?
    private var isClearing = false

    init(state: BrowserState) {
        self.state = state
        back = BrowserNativeButton("Back", symbol: "chevron.left") { [weak state] in state?.perform(.back) }
        forward = BrowserNativeButton("Forward", symbol: "chevron.right") { [weak state] in state?.perform(.forward) }
        reload = BrowserNativeButton("Reload", symbol: "arrow.clockwise") {
            [weak state] in guard let state else { return }; state.perform(state.isLoading ? .stop : .reload)
        }
        find = BrowserNativeButton("Find in Page", symbol: "magnifyingglass") {
            [weak state] in guard let state else { return }
            if state.isFindBarVisible { state.hideFindBar() } else { state.showFindBar() }
        }
        tools = BrowserNativeButton("Browser Tools", symbol: "ellipsis.circle") {}
        super.init(frame: .zero)
        tools.actionHandler = { [weak self] in self?.showTools() }
        field.placeholderString = "URL"
        field.font = .systemFont(ofSize: 13)
        field.delegate = self
        field.target = self
        field.action = #selector(navigate)
        field.setAccessibilityLabel("Address")
        field.setAccessibilityIdentifier("browser.address")
        back.setAccessibilityIdentifier("browser.back")
        forward.setAccessibilityIdentifier("browser.forward")
        reload.setAccessibilityIdentifier("browser.reload")
        find.setAccessibilityIdentifier("browser.find")
        tools.setAccessibilityIdentifier("browser.tools")
        download.isIndeterminate = false
        download.minValue = 0
        download.maxValue = 1
        download.style = .bar
        download.isHidden = true
        download.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        if state.engine == .chromium {
            for wallet in WalletExtensionRegistry.discover() {
                let button = BrowserNativeButton(wallet.name, symbol: wallet.systemImageName) {}
                button.actionHandler = { [weak button] in
                    guard let button, let window = button.window else { return }
                    let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
                    WalletPopupController.shared.toggle(wallet, anchor: anchor)
                }
                button.setAccessibilityIdentifier("browser.wallet.\(wallet.id)")
                stack.addArrangedSubview(button)
            }
        }
        [back, forward, field, reload, find, tools, download].forEach { stack.addArrangedSubview($0) }
        BrowserNativeUI.pin(stack, to: self)
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        let preferred = field.widthAnchor.constraint(equalToConstant: 320)
        preferred.priority = .defaultLow
        preferred.isActive = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        observation.start { [weak self] in self?.synchronize() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { state.isAddressEditing = false }
        synchronize()
    }

    @discardableResult
    func focusAddressField() -> Bool {
        guard !isHiddenOrHasHiddenAncestor, let window, window.attachedSheet == nil,
              window.makeFirstResponder(field) else { return false }
        field.selectText(nil)
        return true
    }

    private func synchronize() {
        field.font = CockpitTypography.font(size: 13)
        if field.currentEditor() == nil, !state.isAddressEditing { field.stringValue = state.urlText }
        back.isEnabled = state.supports(.navigation) && state.canGoBack
        forward.isEnabled = state.supports(.navigation) && state.canGoForward
        reload.isEnabled = state.supports(.navigation)
        reload.image = NSImage(systemSymbolName: state.isLoading ? "xmark" : "arrow.clockwise", accessibilityDescription: state.isLoading ? "Stop" : "Reload")
        reload.toolTip = state.isLoading ? "Stop" : "Reload"
        reload.setAccessibilityLabel(reload.toolTip)
        find.isEnabled = state.supports(.findInPage) && !state.urlText.isEmpty
        find.state = state.isFindBarVisible ? .on : .off
        download.isHidden = state.downloadProgress == nil
        download.doubleValue = state.downloadProgress ?? 0
        download.toolTip = state.downloadStatusText
        if state.needsAddressFocus, window?.isKeyWindow == true {
            state.needsAddressFocus = false
            field.selectText(nil)
        }
    }

    func controlTextDidBeginEditing(_ notification: Notification) { state.isAddressEditing = true }
    func controlTextDidChange(_ notification: Notification) { state.urlText = field.stringValue }
    func controlTextDidEndEditing(_ notification: Notification) { state.isAddressEditing = false }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        window?.makeFirstResponder(nil)
        state.isAddressEditing = false
        return true
    }

    @objc private func navigate() {
        state.urlText = field.stringValue
        state.navigate()
    }

    private func showTools() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let profile = NSMenuItem(title: "Default Profile", action: nil, keyEquivalent: "")
        profile.state = .on
        menu.addItem(profile)
        let clear = BrowserNativeMenuItem("Clear All Browser Data…") { [weak self] in self?.confirmClear() }
        clear.isEnabled = state.supports(.websiteDataReset) && !isClearing
        menu.addItem(clear)
        menu.addItem(.separator())
        if state.engine == .chromium {
            let print = BrowserNativeMenuItem("Print Page…") { [weak state] in state?.requestPrint() }
            print.isEnabled = !state.urlText.isEmpty
            menu.addItem(print)
            let save = BrowserNativeMenuItem("Save Page…") { [weak state] in state?.requestSavePage() }
            save.isEnabled = !state.urlText.isEmpty
            menu.addItem(save)
            menu.addItem(.separator())
        }
        let appearance = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        appearance.isEnabled = state.supports(.appearanceOverride)
        let choices = NSMenu()
        choices.autoenablesItems = false
        for mode in AppearanceMode.allCases {
            let item = BrowserNativeMenuItem(mode.rawValue) { [weak state] in state?.appearanceMode = mode }
            item.state = state.appearanceMode == mode ? .on : .off
            choices.addItem(item)
        }
        appearance.submenu = choices
        menu.addItem(appearance)
        let lasso = BrowserNativeMenuItem(state.annotateMode ? "Turn Off Lasso" : "Turn On Lasso") {
            [weak state] in state?.perform(.toggleAnnotation)
        }
        lasso.isEnabled = state.supports(.annotation)
        lasso.state = state.annotateMode ? .on : .off
        menu.addItem(lasso)
        let inspector = BrowserNativeMenuItem(state.showDevTools ? "Close Developer Tools" : "Open Developer Tools") {
            [weak state] in state?.perform(.toggleDeveloperTools)
        }
        inspector.isEnabled = state.supports(.developerTools)
        menu.addItem(inspector)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: tools.bounds.minY), in: tools)
    }

    private func confirmClear() {
        guard !isClearing, state.supports(.websiteDataReset) else { return }
        let alert = NSAlert()
        alert.messageText = "Clear All Browser Data?"
        alert.informativeText = "This clears caches, cookies, local and session storage, IndexedDB, service workers, and other website data for every WebKit browser pane. The current page will reload in a clean browser."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Clear and Reload")
        BrowserNativeUI.present(alert, for: self) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self else { return }
            self.isClearing = true
            self.clearingTask = Task { @MainActor [weak self] in
                await BrowserWebsiteData.clearAll()
                guard let self, !Task.isCancelled else { return }
                self.state.requestWebsiteDataReset()
                self.isClearing = false
                self.clearingTask = nil
            }
        }
    }

    isolated deinit {
        observation.stop()
        clearingTask?.cancel()
        state.isAddressEditing = false
    }
}
