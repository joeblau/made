import AppKit
import Testing
import WebKit
@testable import Pilot

@Suite("Native browser presentation", .serialized)
@MainActor
struct BrowserNativePresentationTests {
    @Test("A blank pane keeps its native start page until a navigation is submitted")
    func blankPaneDoesNotCreateAnEngineForAddressDrafts() throws {
        let pane = Pane(kind: .browser)
        let state = BrowserState(engine: .webKit)
        pane.browserState = state
        let controller = BrowserPaneViewController(pane: pane)
        _ = controller.view
        let startPage = try #require(controller.children.first as? BrowserStartPageViewController)
        #expect(controller.children.count == 1)

        // Use an offline URL accepted by the existing address normalizer.
        // `about:blank` is normalized to invalid `https://about:blank`.
        state.urlText = "file:///dev/null"
        controller.updatePresentation(isActive: false, isSelected: false)
        #expect(controller.children.first === startPage)

        state.navigate()
        let submittedURL = try #require(state.pendingURL)
        #expect(submittedURL.isFileURL)
        controller.updatePresentation(isActive: false, isSelected: false)
        let engine = try #require(controller.children.first as? WebViewRepresentable)
        let originalWebView = try #require(engine.view as? WKWebView)
        #expect(controller.children.count == 1)

        // Selection and visibility changes reuse the same native engine.
        controller.updatePresentation(isActive: false, isSelected: true)
        #expect(controller.children.first === engine)

        // A data reset explicitly tears down the old delegate graph.
        state.requestWebsiteDataReset()
        controller.updatePresentation(isActive: false, isSelected: false)
        #expect(controller.children.first !== engine)
        #expect(originalWebView.navigationDelegate == nil)
        #expect(originalWebView.uiDelegate == nil)
    }

    @Test("Explicit blank-pane focus selects only its own native address field")
    func blankPaneFocusUsesItsOwningToolbar() throws {
        let pane = Pane(kind: .browser)
        let state = BrowserState()
        pane.browserState = state
        let controller = BrowserPaneViewController(pane: pane)
        let window = makeWindow()
        defer { controller.updatePresentation(isActive: false, isSelected: false); window.close() }
        let otherToolbar = BrowserToolbarView(state: BrowserState())
        let ownToolbar = BrowserToolbarView(state: state)
        otherToolbar.frame = NSRect(x: 0, y: 400, width: 640, height: 30)
        ownToolbar.frame = NSRect(x: 0, y: 440, width: 640, height: 30)
        controller.view.frame = NSRect(x: 0, y: 0, width: 640, height: 380)
        window.contentView?.addSubview(otherToolbar)
        window.contentView?.addSubview(ownToolbar)
        window.contentView?.addSubview(controller.view)
        controller.updatePresentation(isActive: true, isSelected: true)

        controller.focusPaneInput()

        let address = try #require(addressField(in: ownToolbar))
        let editor = try #require(address.currentEditor())
        #expect(window.firstResponder === editor)
        #expect(addressField(in: otherToolbar)?.currentEditor() == nil)
        #expect(controller.children.first is BrowserStartPageViewController)
        #expect(controller.children.count == 1)
    }

    @Test("Explicit browser focus targets page content and clears a stale responder when unavailable")
    func browserFocusNeverLeavesInputInAnotherPane() throws {
        let pane = Pane(kind: .browser)
        let state = BrowserState()
        pane.browserState = state
        let controller = BrowserPaneViewController(pane: pane)
        let window = makeWindow()
        defer { controller.updatePresentation(isActive: false, isSelected: false); window.close() }
        let stale = BrowserFocusTestView(frame: NSRect(x: 0, y: 440, width: 100, height: 30))
        controller.view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        window.contentView?.addSubview(stale)
        window.contentView?.addSubview(controller.view)
        controller.updatePresentation(isActive: true, isSelected: true)
        #expect(window.makeFirstResponder(stale))

        // No address toolbar has attached; do not create an engine to focus it.
        controller.focusPaneInput()
        #expect(window.firstResponder !== stale)
        #expect(state.needsAddressFocus)
        #expect(controller.children.first is BrowserStartPageViewController)

        state.urlText = "file:///dev/null"
        state.navigate()
        controller.updatePresentation(isActive: true, isSelected: true)
        #expect(window.makeFirstResponder(stale))
        controller.focusPaneInput()
        #expect(BrowserPaneFocus.isInWebContent(window.firstResponder, ownedBy: state))

        let engine = try #require(controller.children.first as? WebViewRepresentable)
        engine.close()
        #expect(window.makeFirstResponder(stale))
        controller.focusPaneInput()
        #expect(window.firstResponder !== stale)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func addressField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.placeholderString == "URL" { return field }
        for child in view.subviews {
            if let field = addressField(in: child) { return field }
        }
        return nil
    }

    @Test("Closing a native WebKit controller detaches delegates and cancels its page dialog once")
    func webKitControllerClosesExactlyOnce() throws {
        let state = BrowserState(engine: .webKit)
        let controller = WebViewRepresentable(state: state, onSelect: {}, targetTerminalPaneID: { nil })
        let webView = try #require(controller.view as? WKWebView)
        #expect(webView.navigationDelegate != nil)
        #expect(webView.uiDelegate != nil)
        var answers: [Bool] = []
        state.presentJavaScriptDialog(.init(kind: .confirm, originURL: nil, message: "Continue?")) {
            accepted, _ in answers.append(accepted)
        }

        controller.close()
        controller.close()
        #expect(answers == [false])
        #expect(state.javaScriptDialog == nil)
        #expect(webView.navigationDelegate == nil)
        #expect(webView.uiDelegate == nil)
    }

    @Test("Releasing a native sheet presenter cancels an unanswered page callback")
    func releasingDialogPresenterCancelsCallback() throws {
        let state = BrowserState()
        var answers: [Bool] = []
        let dialog = try #require(state.presentJavaScriptDialog(.init(kind: .prompt(defaultText: "draft"), originURL: nil, message: "Name?")) {
            accepted, _ in answers.append(accepted)
        })
        var presenter: BrowserJavaScriptDialogPresenter? = BrowserJavaScriptDialogPresenter(dialog: dialog)
        #expect(presenter?.dialog === dialog)
        presenter = nil
        dialog.cancel()
        #expect(answers == [false])
        #expect(state.javaScriptDialog == nil)
    }

    @Test("Stopped native observation cannot deliver queued updates to a retired view")
    func stoppedObservationDiscardsQueuedInvalidation() async {
        let state = BrowserState()
        let observation = BrowserNativeObservation()
        var updates = 0
        observation.start {
            _ = state.canGoBack
            updates += 1
        }
        state.canGoBack = true
        observation.stop()
        for _ in 0..<10 { await Task.yield() }
        #expect(updates == 1)

        observation.start {
            _ = state.canGoForward
            updates += 1
        }
        #expect(updates == 2)
        observation.stop()
    }
}

@MainActor
private final class BrowserFocusTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
