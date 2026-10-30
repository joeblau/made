import AppKit
@preconcurrency import ChromiumKit
import Testing
@testable import Pilot

@Suite("Chromium browser commands")
@MainActor
struct ChromiumBrowserCommandTests {
    @Test("Find, print, and save requests remain pane-local and edge-triggered")
    func pageCommandsArePaneLocal() {
        let first = BrowserState(engine: .chromium)
        let second = BrowserState(engine: .chromium)

        first.requestFind("pilot")
        #expect(first.findRequestID == 1)
        #expect(first.findQuery == "pilot")
        #expect(first.findForward)
        #expect(!first.findNext)
        #expect(second.findRequestID == 0)

        first.requestFind("pilot", forward: false, findNext: true)
        #expect(first.findRequestID == 2)
        #expect(!first.findForward)
        #expect(first.findNext)

        first.requestPrint()
        first.requestSavePage()
        first.stopFinding()
        #expect(first.printRequestID == 1)
        #expect(first.savePageRequestID == 1)
        #expect(first.stopFindingRequestID == 1)
        #expect(first.findQuery.isEmpty)
        #expect(second.printRequestID == 0)
        #expect(second.savePageRequestID == 0)
    }

    @Test("WebKit ignores Chromium-only page commands")
    func webKitDoesNotQueueChromiumCommands() {
        let state = BrowserState(engine: .webKit)

        state.requestFind("pilot")
        state.requestPrint()
        state.requestSavePage()
        state.stopFinding()

        #expect(state.findRequestID == 0)
        #expect(state.printRequestID == 0)
        #expect(state.savePageRequestID == 0)
        #expect(state.stopFindingRequestID == 0)
    }

    @Test("Back and forward requests reach the Chromium host")
    func historyCommandsReachChromiumHost() {
        let state = BrowserState(engine: .chromium)
        let coordinator = ChromiumBrowserView.Coordinator(
            state: state,
            onSelect: {}
        )
        let host = FakeChromiumBrowserHost()
        coordinator.attach(
            host,
            navigationRequestID: state.navigationRequestID,
            inspectorToggleRequestID: state.inspectorToggleRequestID,
            findRequestID: state.findRequestID,
            stopFindingRequestID: state.stopFindingRequestID,
            printRequestID: state.printRequestID,
            savePageRequestID: state.savePageRequestID,
            initialURL: nil,
            zoom: 1,
            isActive: true,
            isSelected: true
        )

        #expect(state.perform(.back))
        coordinator.update(
            navigationRequestID: state.navigationRequestID,
            inspectorToggleRequestID: state.inspectorToggleRequestID,
            findRequestID: state.findRequestID,
            stopFindingRequestID: state.stopFindingRequestID,
            printRequestID: state.printRequestID,
            savePageRequestID: state.savePageRequestID,
            zoom: 1,
            isActive: true,
            isSelected: true
        )
        #expect(host.events.last == .command(.back))

        #expect(state.perform(.forward))
        coordinator.update(
            navigationRequestID: state.navigationRequestID,
            inspectorToggleRequestID: state.inspectorToggleRequestID,
            findRequestID: state.findRequestID,
            stopFindingRequestID: state.stopFindingRequestID,
            printRequestID: state.printRequestID,
            savePageRequestID: state.savePageRequestID,
            zoom: 1,
            isActive: true,
            isSelected: true
        )
        #expect(host.events.last == .command(.forward))
    }

    @Test("The fake host receives pane commands once and in production order")
    func fakeHostPreservesCommandOrdering() throws {
        let state = BrowserState(engine: .chromium)
        let container = ChromiumBrowserContainerView()
        let coordinator = ChromiumBrowserView.Coordinator(
            state: state,
            onSelect: {}
        )
        let host = FakeChromiumBrowserHost()
        coordinator.container = container
        let firstURL = try #require(URL(string: "https://first.example.test"))
        let secondURL = try #require(URL(string: "https://second.example.test"))

        coordinator.attach(
            host,
            navigationRequestID: 0,
            inspectorToggleRequestID: 0,
            findRequestID: 0,
            stopFindingRequestID: 0,
            printRequestID: 0,
            savePageRequestID: 0,
            initialURL: firstURL,
            zoom: 1,
            isActive: true,
            isSelected: false
        )

        #expect(host.events == [
            .command(.setZoom(1)),
            .command(.navigate(firstURL)),
        ])

        state.requestNavigationCommand(secondURL.absoluteString)
        state.toggleDeveloperTools()
        state.requestFind("pilot", matchCase: true)
        state.requestPrint()
        state.requestSavePage()
        coordinator.update(
            navigationRequestID: state.navigationRequestID,
            inspectorToggleRequestID: state.inspectorToggleRequestID,
            findRequestID: state.findRequestID,
            stopFindingRequestID: state.stopFindingRequestID,
            printRequestID: state.printRequestID,
            savePageRequestID: state.savePageRequestID,
            zoom: 1.2,
            isActive: true,
            isSelected: false
        )

        #expect(host.events == [
            .command(.setZoom(1)),
            .command(.navigate(firstURL)),
            .command(.setZoom(1.2)),
            .command(.navigate(secondURL)),
            .command(.setDeveloperToolsVisible(true)),
            .find(
                text: "pilot",
                forward: true,
                matchCase: true,
                findNext: false
            ),
            .print,
            .save,
        ])

        state.stopFinding()
        coordinator.update(
            navigationRequestID: state.navigationRequestID,
            inspectorToggleRequestID: state.inspectorToggleRequestID,
            findRequestID: state.findRequestID,
            stopFindingRequestID: state.stopFindingRequestID,
            printRequestID: state.printRequestID,
            savePageRequestID: state.savePageRequestID,
            zoom: 1.2,
            isActive: true,
            isSelected: false
        )
        coordinator.close()

        #expect(host.events.suffix(2) == [
            .stopFinding(clearSelection: true),
            .command(.close),
        ])
        #expect(host.delegate == nil)
        #expect(container.runtimeState == .closed)
    }

    @Test("Fake-engine callbacks update pane state in delivery order")
    func fakeEnginePreservesCallbackOrdering() throws {
        let state = BrowserState(engine: .chromium)
        let container = ChromiumBrowserContainerView()
        let coordinator = ChromiumBrowserView.Coordinator(
            state: state,
            onSelect: {}
        )
        let host = FakeChromiumBrowserHost()
        coordinator.container = container
        coordinator.attach(
            host,
            navigationRequestID: 0,
            inspectorToggleRequestID: 0,
            findRequestID: 0,
            stopFindingRequestID: 0,
            printRequestID: 0,
            savePageRequestID: 0,
            initialURL: nil,
            zoom: 1,
            isActive: true,
            isSelected: false
        )
        let url = try #require(URL(string: "https://callbacks.example.test"))

        host.deliverReadySequence(
            to: coordinator,
            url: url,
            title: "Callback fixture"
        )

        #expect(host.deliveredCallbacks == [
            "created",
            "url",
            "title",
            "loading-started",
            "progress",
            "back",
            "forward",
            "loading-finished",
        ])
        #expect(state.urlText == url.absoluteString)
        #expect(state.title == "Callback fixture")
        #expect(!state.isLoading)
        #expect(state.estimatedProgress == 1)
        #expect(state.canGoBack)
        #expect(!state.canGoForward)
        #expect(container.runtimeState == .ready)
    }

    @Test("Closing during fake creation drops every late callback")
    func closeDuringFakeCreationIsSafe() {
        let state = BrowserState(engine: .chromium)
        let container = ChromiumBrowserContainerView()
        let coordinator = ChromiumBrowserView.Coordinator(
            state: state,
            onSelect: {}
        )
        let host = FakeChromiumBrowserHost()
        coordinator.container = container
        coordinator.attach(
            host,
            navigationRequestID: 0,
            inspectorToggleRequestID: 0,
            findRequestID: 0,
            stopFindingRequestID: 0,
            printRequestID: 0,
            savePageRequestID: 0,
            initialURL: nil,
            zoom: 1,
            isActive: true,
            isSelected: false
        )

        coordinator.close()
        host.deliverCreatedIfAttached()

        #expect(host.deliveredCallbacks.isEmpty)
        #expect(host.events.last == .command(.close))
        #expect(container.runtimeState == .closed)
        #expect(!state.isLoading)
        #expect(!state.canGoBack)
        #expect(!state.canGoForward)
        #expect(state.estimatedProgress == 0)
    }
}

@MainActor
@Suite("Chromium certificate warnings")
struct ChromiumCertificateWarningTests {
    private let certificate = Data("local-device-certificate".utf8)
    private let url = URL(string: "https://glkvm01.local/")!

    private func attach(
        _ coordinator: ChromiumBrowserView.Coordinator,
        host: FakeChromiumBrowserHost,
        active: Bool = true,
        selected: Bool = true
    ) {
        coordinator.attach(
            host, navigationRequestID: 0, inspectorToggleRequestID: 0,
            findRequestID: 0, stopFindingRequestID: 0, printRequestID: 0, savePageRequestID: 0,
            initialURL: url, zoom: 1, isActive: active, isSelected: selected
        )
    }

    @Test("An explicit approval resumes the request and is tied to the certificate")
    func explicitApproval() {
        let state = BrowserState(engine: .chromium)
        var prompts = 0
        let coordinator = ChromiumBrowserView.Coordinator(state: state, onSelect: {}, confirmCertificate: { _ in
            prompts += 1
            return true
        })
        let host = FakeChromiumBrowserHost()
        attach(coordinator, host: host)

        for _ in 0..<2 {
            #expect(coordinator.shouldAllowCertificateError(-202, url: url, certificateDER: certificate, isVisible: { true }))
        }
        #expect(prompts == 1)
        #expect(coordinator.shouldAllowCertificateError(
            -202, url: url, certificateDER: Data("changed-certificate".utf8), isVisible: { true }
        ))
        #expect(prompts == 2)
    }

    @Test("Cancel does not create an exception")
    func cancellation() {
        let state = BrowserState(engine: .chromium)
        var prompts = 0
        let coordinator = ChromiumBrowserView.Coordinator(state: state, onSelect: {}, confirmCertificate: { _ in
            prompts += 1
            return false
        })
        let host = FakeChromiumBrowserHost()
        attach(coordinator, host: host)
        for _ in 0..<2 {
            #expect(!coordinator.shouldAllowCertificateError(-202, url: url, certificateDER: certificate, isVisible: { true }))
        }
        #expect(prompts == 2)
    }

    @Test("Unrelated origins, fatal errors, and invisible panes cannot prompt")
    func ineligibleChallenges() {
        let state = BrowserState(engine: .chromium)
        let coordinator = ChromiumBrowserView.Coordinator(state: state, onSelect: {}, confirmCertificate: { _ in
            Issue.record("This certificate challenge must not prompt")
            return true
        })
        let host = FakeChromiumBrowserHost()
        attach(coordinator, host: host)
        for otherURL in ["https://other.local/", "https://glkvm01.local:8443/", "http://glkvm01.local/"] {
            #expect(!coordinator.shouldAllowCertificateError(
                -202, url: URL(string: otherURL)!, certificateDER: certificate, isVisible: { true }
            ))
        }
        #expect(!coordinator.shouldAllowCertificateError(-206, url: url, certificateDER: certificate, isVisible: { true }))
        #expect(!coordinator.shouldAllowCertificateError(-202, url: url, certificateDER: certificate, isVisible: { false }))
        #expect(!coordinator.shouldAllowCertificateError(-202, url: url, certificateDER: Data(), isVisible: { true }))
        attach(coordinator, host: host, selected: false)
        #expect(!coordinator.shouldAllowCertificateError(-202, url: url, certificateDER: certificate, isVisible: { true }))
        attach(coordinator, host: host, active: false)
        #expect(!coordinator.shouldAllowCertificateError(-202, url: url, certificateDER: certificate, isVisible: { true }))
    }

    @Test("Navigating or closing while the warning is open invalidates approval", arguments: [false, true])
    func staleApproval(closes: Bool) {
        let state = BrowserState(engine: .chromium)
        var duringPrompt: (() -> Void)?
        let coordinator = ChromiumBrowserView.Coordinator(state: state, onSelect: {}, confirmCertificate: { _ in
            duringPrompt?()
            return true
        })
        let host = FakeChromiumBrowserHost()
        attach(coordinator, host: host)
        duringPrompt = {
            if closes { coordinator.close() } else { state.requestNavigationCommand("https://other.local/") }
        }
        #expect(!coordinator.shouldAllowCertificateError(-202, url: url, certificateDER: certificate, isVisible: { true }))
        duringPrompt = nil
    }

    @Test("A pane hidden while the warning is open cannot approve")
    func hiddenDuringPrompt() {
        let state = BrowserState(engine: .chromium)
        var visible = true
        let coordinator = ChromiumBrowserView.Coordinator(state: state, onSelect: {}, confirmCertificate: { _ in
            visible = false
            return true
        })
        let host = FakeChromiumBrowserHost()
        attach(coordinator, host: host)
        #expect(!coordinator.shouldAllowCertificateError(-202, url: url, certificateDER: certificate, isVisible: { visible }))
    }

    @Test("A late failure from an earlier certificate request does not cover the current page")
    func ignoresStaleFailure() {
        let state = BrowserState(engine: .chromium)
        let container = ChromiumBrowserContainerView()
        let coordinator = ChromiumBrowserView.Coordinator(state: state, onSelect: {})
        coordinator.container = container
        let host = FakeChromiumBrowserHost()
        attach(coordinator, host: host)
        coordinator.handleNavigationFailure(NSError(domain: "ChromiumKit", code: -202, userInfo: [
            NSURLErrorFailingURLErrorKey: URL(string: "https://previous.local/")!,
        ]))
        #expect(container.runtimeState == .ready)
        #expect(state.isLoading)

        coordinator.handleNavigationFailure(NSError(domain: "ChromiumKit", code: -202, userInfo: [
            NSURLErrorFailingURLErrorKey: url,
        ]))
        #expect(container.runtimeState == .navigationFailed)
        #expect(!state.isLoading)
    }
}

@MainActor
private final class FakeChromiumBrowserHost: ChromiumBrowserHosting {
    enum Event: Equatable {
        case command(BrowserControllerCommand)
        case find(
            text: String,
            forward: Bool,
            matchCase: Bool,
            findNext: Bool
        )
        case stopFinding(clearSelection: Bool)
        case print
        case save
    }

    weak var delegate: (any ChromiumBrowserHostViewDelegate)?
    var isHidden = false
    var onSelect: (() -> Void)?
    private(set) var events: [Event] = []
    private(set) var deliveredCallbacks: [String] = []
    private let callbackView = ChromiumBrowserHostView(frame: .zero)

    func performBrowserCommand(_ command: BrowserControllerCommand) {
        events.append(.command(command))
    }

    func findText(
        _ text: String,
        forward: Bool,
        matchCase: Bool,
        findNext: Bool
    ) {
        events.append(.find(
            text: text,
            forward: forward,
            matchCase: matchCase,
            findNext: findNext
        ))
    }

    func stopFindingAndClearSelection(_ clearSelection: Bool) {
        events.append(.stopFinding(clearSelection: clearSelection))
    }

    func printPage() {
        events.append(.print)
    }

    func savePage() {
        events.append(.save)
    }

    func deliverReadySequence(
        to coordinator: ChromiumBrowserView.Coordinator,
        url: URL,
        title: String
    ) {
        deliveredCallbacks.append("created")
        coordinator.chromiumBrowserHostViewDidCreate(callbackView)
        deliveredCallbacks.append("url")
        coordinator.chromiumBrowserHostView(callbackView, didChange: url)
        deliveredCallbacks.append("title")
        coordinator.chromiumBrowserHostView(
            callbackView,
            didChangeTitle: title
        )
        deliveredCallbacks.append("loading-started")
        coordinator.chromiumBrowserHostView(
            callbackView,
            didChangeLoading: true
        )
        deliveredCallbacks.append("progress")
        coordinator.chromiumBrowserHostView(
            callbackView,
            didChangeProgress: 0.5
        )
        deliveredCallbacks.append("back")
        coordinator.chromiumBrowserHostView(
            callbackView,
            didChangeCanGoBack: true
        )
        deliveredCallbacks.append("forward")
        coordinator.chromiumBrowserHostView(
            callbackView,
            didChangeCanGoForward: false
        )
        deliveredCallbacks.append("loading-finished")
        coordinator.chromiumBrowserHostView(
            callbackView,
            didChangeLoading: false
        )
    }

    func deliverCreatedIfAttached() {
        guard let coordinator =
            delegate as? ChromiumBrowserView.Coordinator
        else {
            return
        }
        deliveredCallbacks.append("created")
        coordinator.chromiumBrowserHostViewDidCreate(callbackView)
    }
}
