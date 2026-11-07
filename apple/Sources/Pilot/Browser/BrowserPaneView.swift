import AppKit
@preconcurrency import ChromiumKit
import WebKit

@MainActor
final class BrowserPaneViewController: NSViewController, CockpitPanePresenting, CockpitPaneInputFocusing, CockpitPaneClosing {
    let pane: Pane
    let state: BrowserState
    var onSelect: () -> Void = {}
    var targetTerminalPaneID: @MainActor () -> UUID? = { nil }
    private let observation = BrowserNativeObservation()
    private(set) var isActive = false
    private(set) var isSelected = false
    private var isClosed = false
    private var hasLoadedAnyURL = false
    private let openedWithBlankURL: Bool
    private var surface: NSViewController?
    private var surfaceIdentity: String?
    private var startPage: BrowserStartPageViewController?
    private var findBar: BrowserFindBar?
    private let stack = NSStackView()
    private var dialogPresenter: BrowserJavaScriptDialogPresenter?
    private var zoomObserver: NSObjectProtocol?
    private var sheetObserver: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?

    init(pane: Pane) {
        self.pane = pane
        let state = pane.browserState ?? BrowserState()
        if pane.browserState == nil { pane.browserState = state }
        self.state = state
        openedWithBlankURL = state.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        let host = BrowserPaneContainerView()
        host.onWindowChange = { [weak self] in self?.synchronizeDialog() }
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        BrowserNativeUI.pin(stack, to: host)
        view = host
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observation.start { [weak self] in self?.synchronize() }
        sheetObserver = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.synchronizeDialog() }
        }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: nil, queue: .main) { [weak self] notification in
            let closingWindow = notification.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, !self.isClosed, closingWindow === self.view.window else { return }
                self.dialogPresenter?.dismiss()
                self.dialogPresenter = nil
                self.state.javaScriptDialog?.cancel()
            }
        }
        zoomObserver = NotificationCenter.default.addObserver(
            forName: .cockpitUIZoomDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.synchronize() }
        }
    }

    func updatePresentation(isActive: Bool, isSelected: Bool) {
        guard !isClosed else { return }
        self.isActive = isActive
        self.isSelected = isSelected
        if isViewLoaded { synchronize() }
        // A pane opened while its window was occluded keeps its focus request
        // pending; honour it once the pane is actually presented. Limited to
        // the start page so a web view that can't take focus yet doesn't
        // clear the responder on every presentation update.
        if isActive, isSelected, startPage != nil, state.needsAddressFocus { focusPaneInput() }
    }

    func focusPaneInput() {
        guard !isClosed, isViewLoaded, isActive, isSelected, let window = view.window,
              window.attachedSheet == nil else { return }
        if let startPage {
            state.needsAddressFocus = false
            startPage.focusInput()
            return
        }
        let focused: Bool
        if let controller = surface as? WebViewRepresentable {
            focused = controller.focusContent()
        } else if let controller = surface as? ChromiumBrowserView {
            focused = controller.focusContent()
        } else {
            focused = false
        }
        if focused { state.needsAddressFocus = false } else { window.makeFirstResponder(nil) }
    }

    private func synchronize() {
        guard !isClosed else { return }
        let showStart = BrowserStartPageVisibility.shouldShow(
            hasLoadedAnyURL: hasLoadedAnyURL, openedWithBlankURL: openedWithBlankURL,
            urlText: state.urlText,
            hasPendingPageNavigation: state.pendingURL.map { $0.scheme != "blau" } ?? false
        )
        if showStart {
            let rootPath = pane.workspace?.effectiveRootPath
            if let startPage, startPage.rootPath != rootPath {
                startPage.setActive(false)
                stack.removeArrangedSubview(startPage.view)
                startPage.view.removeFromSuperview()
                startPage.removeFromParent()
                self.startPage = nil
            }
            if startPage == nil {
                let controller = BrowserStartPageViewController(rootPath: rootPath, state: state) { [weak self] server in
                    guard let self else { return }
                    self.onSelect()
                    self.state.urlText = server.url.absoluteString
                    self.state.navigate()
                }
                startPage = controller
                addChild(controller)
                append(controller.view)
            }
            startPage?.setPresentation(isActive: isActive, isSelected: isSelected)
            return
        }
        hasLoadedAnyURL = true
        if let startPage {
            startPage.setActive(false)
            stack.removeArrangedSubview(startPage.view)
            startPage.view.removeFromSuperview()
            startPage.removeFromParent()
            self.startPage = nil
        }
        let identity = "\(state.engine.rawValue):\(state.websiteDataResetRequestID):\(state.runtimeRetryRequestID)"
        if surfaceIdentity != identity {
            if let surface {
                (surface as? WebViewRepresentable)?.close()
                (surface as? ChromiumBrowserView)?.close()
                stack.removeArrangedSubview(surface.view)
                surface.view.removeFromSuperview()
                surface.removeFromParent()
            }
            let controller: NSViewController
            switch state.engine {
            case .webKit:
                controller = WebViewRepresentable(state: state, onSelect: { [weak self] in self?.onSelect() },
                    targetTerminalPaneID: { [weak self] in self?.targetTerminalPaneID() })
            case .chromium:
                controller = ChromiumBrowserView(state: state, onSelect: { [weak self] in self?.onSelect() })
            }
            surface = controller
            surfaceIdentity = identity
            addChild(controller)
            append(controller.view)
        }
        if state.isFindBarVisible, state.supports(.findInPage) {
            if findBar == nil {
                let bar = BrowserFindBar(state: state)
                findBar = bar
                stack.insertArrangedSubview(bar, at: 0)
                bar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            findBar?.synchronize()
        } else if let findBar {
            stack.removeArrangedSubview(findBar)
            findBar.removeFromSuperview()
            self.findBar = nil
        }
        if let controller = surface as? WebViewRepresentable {
            controller.isActive = isActive
            controller.isSelected = isSelected
            controller.synchronize()
        }
        if let controller = surface as? ChromiumBrowserView {
            controller.isActive = isActive
            controller.isSelected = isSelected
            controller.synchronize()
        }
        synchronizeDialog()
    }

    private func append(_ child: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(child)
        child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        child.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    private func synchronizeDialog() {
        guard !isClosed else { return }
        guard isActive else {
            dialogPresenter?.dismiss()
            dialogPresenter = nil
            state.javaScriptDialog?.cancel()
            return
        }
        if let presenter = dialogPresenter, presenter.dialog !== state.javaScriptDialog {
            presenter.dismiss()
            dialogPresenter = nil
        }
        guard dialogPresenter == nil, let dialog = state.javaScriptDialog,
              let window = (isViewLoaded ? view.window : nil) else { return }
        // Wait for a sheet already owned by another pane rather than attaching
        // this page's dialog to a different window.
        guard window.attachedSheet == nil else { return }
        let presenter = BrowserJavaScriptDialogPresenter(dialog: dialog)
        dialogPresenter = presenter
        presenter.present(on: window)
    }

    func closePane() {
        guard !isClosed else { return }
        isClosed = true
        observation.stop()
        if let zoomObserver { NotificationCenter.default.removeObserver(zoomObserver) }
        if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver) }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        dialogPresenter?.dismiss()
        state.javaScriptDialog?.cancel()
        (surface as? WebViewRepresentable)?.close()
        (surface as? ChromiumBrowserView)?.close()
        startPage?.setActive(false)
    }

    isolated deinit { closePane() }
}

@MainActor
private final class BrowserPaneContainerView: NSView {
    var onWindowChange: (() -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }
}

enum BrowserStartPageVisibility {
    static func shouldShow(
        hasLoadedAnyURL: Bool,
        openedWithBlankURL: Bool?,
        urlText: String,
        hasPendingPageNavigation: Bool
    ) -> Bool {
        if hasLoadedAnyURL { return false }
        if hasPendingPageNavigation { return false }
        return openedWithBlankURL ?? urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Keyboard-focus rules for selecting a browser pane.
///
/// A click into a page makes the engine's content view first responder on
/// mouse down; the pane only becomes selected on mouse up. Selection side
/// effects must then leave that focus alone, or the clicked field loses it
/// and only a second click focuses it.
@MainActor
enum BrowserPaneFocus {
    /// Whether `responder` is `view` itself or a view inside it.
    static func responder(_ responder: NSResponder?, isWithin view: NSView) -> Bool {
        (responder as? NSView)?.isDescendant(of: view) ?? false
    }

    /// Whether keyboard focus already sits in page content: inside a Chromium
    /// host view (CEF's content views are its descendants) or a `WKWebView`.
    static func isInWebContent(_ responder: NSResponder?) -> Bool {
        webContentView(containing: responder) != nil
    }

    /// Whether keyboard focus sits in the page of the pane whose state is
    /// `state`. Focus left in another pane's page (the selection moved by
    /// keyboard or a tab click) does not count, so keys never keep flowing
    /// to a page the user moved away from.
    static func isInWebContent(_ responder: NSResponder?, ownedBy state: BrowserState?) -> Bool {
        guard let state,
              let owner = webContentView(containing: responder) as? BrowserPaneContent else { return false }
        return owner.browserState === state
    }

    private static func webContentView(containing responder: NSResponder?) -> NSView? {
        var view = responder as? NSView
        while let current = view {
            if current is ChromiumBrowserHostView || current is WKWebView { return current }
            view = current.superview
        }
        return nil
    }
}

/// An engine view that knows which pane's `BrowserState` it shows, so focus
/// rules can tell this pane's page from another pane's.
@MainActor
protocol BrowserPaneContent: AnyObject {
    var browserState: BrowserState? { get }
}
