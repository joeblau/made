import AppKit
import SwiftData
import Testing
import WebKit
@testable import Pilot

@Suite("Native browser presentation", .serialized)
@MainActor
struct BrowserNativePresentationTests {
    @Test("Local servers keep a Safari/Chrome toggle and route letters and numbered shortcuts within the list")
    func localServerEngineAndNumberShortcuts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 1...4 {
            let folder = directory.appendingPathComponent("app\(index)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let package: [String: Any] = ["name": "app\(index)", "scripts": ["dev": "next dev --port \(39000 + index)"]]
            try JSONSerialization.data(withJSONObject: package).write(to: folder.appendingPathComponent("package.json"))
        }
        let state = BrowserState()
        var opened: [(LocalServer, BrowserEngine)] = []
        let controller = BrowserStartPageViewController(rootPath: directory.path, state: state) { opened.append(($0, state.engine)) }
        let window = makeWindow()
        window.contentViewController = controller
        window.orderFront(nil)
        defer { controller.setActive(false); window.close() }
        controller.setPresentation(isActive: true, isSelected: true)
        let table = try #require(allViews(controller.view).compactMap { $0 as? NSTableView }.first)
        let picker = try #require(allViews(controller.view).compactMap { $0 as? NSSegmentedControl }.first)
        #expect(picker.selectedSegment == 0 && state.engine == .webKit)
        #expect(picker.label(forSegment: 0) == "Safari" && picker.label(forSegment: 1) == "Chrome")
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while table.numberOfRows != 4, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(table.numberOfRows == 4)
        controller.focusInput()
        #expect(window.firstResponder === table)
        func key(_ text: String, code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
                isARepeat: false, keyCode: code))
        }
        window.sendEvent(try key("C", code: 8, flags: .shift))
        let expected: BrowserEngine = ChromiumBrowserCreationPolicy.isCreationEnabled ? .chromium : .webKit
        #expect(state.engine == expected && picker.selectedSegment == (expected == .chromium ? 1 : 0))
        #expect(state.pendingURL == nil && table.numberOfRows == 4, "Choosing an engine preserves the server list")
        for (index, code) in [UInt16(18), 19, 20, 21].enumerated() {
            window.sendEvent(try key(String(index + 1), code: code))
        }
        #expect(opened.map { $0.0.port } == [39001, 39002, 39003, 39004])
        #expect(opened.allSatisfy { $0.1 == expected })
        window.sendEvent(try key("s", code: 1))
        window.sendEvent(try key("2", code: 19))
        #expect(opened.last?.0.port == 39002 && opened.last?.1 == .webKit)

        // Address-field input never reaches the list's responder chain.
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 120, height: 30))
        controller.view.addSubview(text)
        #expect(window.makeFirstResponder(text))
        for (value, code) in [("s", UInt16(1)), ("c", 8), ("1", 18)] { window.sendEvent(try key(value, code: code)) }
        #expect(text.string == "sc1" && opened.count == 5 && state.engine == .webKit)
        text.removeFromSuperview()
        controller.focusInput()
        for flags: NSEvent.ModifierFlags in [.command, .control, .option] {
            table.keyDown(with: try key("c", code: 8, flags: flags))
            table.keyDown(with: try key("1", code: 18, flags: flags))
        }
        #expect(opened.count == 5 && state.engine == .webKit)
        controller.setPresentation(isActive: true, isSelected: false)
        table.keyDown(with: try key("1", code: 18))
        #expect(opened.count == 5)
    }

    private func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }

    @Test("Closing a browser cancels queued updates before its model context disappears")
    func closedBrowserIgnoresQueuedZoomAndWindowCallbacks() async throws {
        let controller = try autoreleasepool {
            let container = try ModelContainer(for: Pane.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let pane = Pane(kind: .browser)
            container.mainContext.insert(pane)
            try container.mainContext.save()
            let controller = BrowserPaneViewController(pane: pane)
            _ = controller.view
            NotificationCenter.default.post(name: .cockpitUIZoomDidChange, object: nil)
            controller.closePane()
            return controller
        }
        // The queued zoom callback runs after the persistent models expire.
        await Task.yield()
        controller.updatePresentation(isActive: true, isSelected: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        controller.focusPaneInput()
        window.close()
        controller.closePane()
        #expect(!controller.children.contains { $0 is WebViewRepresentable })
    }

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

    @Test("Blank-pane focus targets the local servers while explicit address focus still selects its own toolbar")
    func blankPaneFocusUsesItsLocalServers() throws {
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

        #expect(window.firstResponder is NSTableView)
        #expect(addressField(in: ownToolbar)?.currentEditor() == nil)
        #expect(!state.needsAddressFocus)
        #expect(BrowserAddressFocus.selectAddressField(in: window, ownedBy: state))
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
        #expect(!state.needsAddressFocus)
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
