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

    @Test("WebKit queues Find in Page but ignores Chromium-only print and save")
    func webKitQueuesFindButNotChromiumCommands() {
        let state = BrowserState(engine: .webKit)

        state.requestFind("pilot")
        state.requestPrint()
        state.requestSavePage()
        state.stopFinding()

        #expect(state.findRequestID == 1)
        #expect(state.stopFindingRequestID == 1)
        #expect(!state.findCountsMatches)
        #expect(state.printRequestID == 0)
        #expect(state.savePageRequestID == 0)
    }

    @Test("The find bar starts a new search for a new query and steps through a repeated one")
    func findBarSearchSemantics() {
        let state = BrowserState(engine: .chromium)

        state.showFindBar()
        #expect(state.isFindBarVisible)
        #expect(state.findFieldFocusRequestID == 1)
        #expect(!state.canFindAgain)

        state.findBarText = "pil"
        state.findInPage()
        #expect(state.findQuery == "pil")
        #expect(!state.findNext)

        state.findBarText = "pilot"
        state.findInPage()
        #expect(!state.findNext, "a changed query restarts from the top")

        state.findInPage(forward: false)
        #expect(state.findNext)
        #expect(!state.findForward)
        #expect(state.findRequestID == 3)

        state.hideFindBar()
        #expect(!state.isFindBarVisible)
        #expect(state.findQuery.isEmpty)
        #expect(state.stopFindingRequestID == 1)
        #expect(state.findBarText == "pilot", "Done keeps the draft for ⌘G")

        #expect(state.canFindAgain)
        state.findAgain(forward: true)
        #expect(state.isFindBarVisible)
        #expect(state.findFieldFocusRequestID == 1, "⌘G does not steal focus")
        #expect(state.findQuery == "pilot")
        #expect(state.findRequestID == 4)

        state.findBarText = ""
        state.findInPage()
        #expect(state.findQuery.isEmpty, "clearing the field clears the highlights")
        #expect(state.stopFindingRequestID == 2)
    }

    @Test("Find requests reach the Chromium host with the bar's direction")
    func findRequestsReachChromiumHost() {
        let state = BrowserState(engine: .chromium)
        let coordinator = ChromiumBrowserView.Coordinator(state: state, onSelect: {})
        let host = FakeChromiumBrowserHost()
        coordinator.attach(
            host, navigationRequestID: 0, inspectorToggleRequestID: 0,
            findRequestID: 0, stopFindingRequestID: 0, printRequestID: 0, savePageRequestID: 0,
            initialURL: nil, zoom: 1, isActive: true, isSelected: true
        )
        state.findBarText = "pilot"
        state.findInPage()
        update(coordinator, state)
        state.findInPage(forward: false)
        update(coordinator, state)
        state.hideFindBar()
        update(coordinator, state)

        #expect(host.events.filter { if case .command = $0 { false } else { true } } == [
            .find(text: "pilot", forward: true, matchCase: false, findNext: false),
            .find(text: "pilot", forward: false, matchCase: false, findNext: true),
            .stopFinding(clearSelection: true),
        ])
    }

    private func update(_ coordinator: ChromiumBrowserView.Coordinator, _ state: BrowserState) {
        coordinator.update(
            navigationRequestID: state.navigationRequestID,
            inspectorToggleRequestID: state.inspectorToggleRequestID,
            findRequestID: state.findRequestID,
            stopFindingRequestID: state.stopFindingRequestID,
            printRequestID: state.printRequestID,
            savePageRequestID: state.savePageRequestID,
            zoom: 1, isActive: true, isSelected: true
        )
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
@Suite("Chromium load failures and page dialogs")
struct ChromiumLoadFailureAndDialogTests {
    private let url = URL(string: "http://127.0.0.1:4321/")!

    private func makeAttached() -> (BrowserState, ChromiumBrowserView.Coordinator, ChromiumBrowserContainerView) {
        let state = BrowserState(engine: .chromium)
        let container = ChromiumBrowserContainerView()
        let coordinator = ChromiumBrowserView.Coordinator(state: state, onSelect: {})
        coordinator.container = container
        coordinator.attach(
            FakeChromiumBrowserHost(), navigationRequestID: 0, inspectorToggleRequestID: 0,
            findRequestID: 0, stopFindingRequestID: 0, printRequestID: 0, savePageRequestID: 0,
            initialURL: url, zoom: 1, isActive: true, isSelected: true
        )
        return (state, coordinator, container)
    }

    private func netError(_ code: Int, url: URL) -> NSError {
        NSError(domain: ChromiumKitError.errorDomain, code: ChromiumKitError.navigationFailed.rawValue, userInfo: [
            "ChromiumNetError": NSNumber(value: code),
            NSURLErrorFailingURLErrorKey: url,
        ])
    }

    @Test("A network error leaves recovery to Chromium's own error page")
    func engineErrorPageHidesNativeOverlay() {
        let (state, coordinator, container) = makeAttached()
        coordinator.handleNavigationFailure(netError(-102, url: url)) // ERR_CONNECTION_REFUSED

        #expect(container.runtimeState == .ready, "one Reload button, not Reload plus Retry (BTN-1)")
        #expect(!state.isLoading)
        #expect(coordinator.lastDiagnostic?.event == .navigationFailed)
    }

    @Test("An aborted navigation shows no error at all")
    func abortedNavigationIsIgnored() {
        #expect(ChromiumLoadFailurePresentation(netError(-3, url: url)) == .ignored)
        let (_, coordinator, container) = makeAttached()
        coordinator.handleNavigationFailure(netError(-3, url: url))
        #expect(container.runtimeState == .ready)
    }

    @Test("Failures with no engine page keep the native message and Retry")
    func bridgeFailuresKeepNativeOverlay() {
        let unavailable = NSError(domain: ChromiumKitError.errorDomain, code: ChromiumKitError.runtimeUnavailable.rawValue)
        #expect(ChromiumLoadFailurePresentation(unavailable) == .nativeOverlay)
        let missingNetCode = NSError(domain: ChromiumKitError.errorDomain, code: ChromiumKitError.navigationFailed.rawValue)
        #expect(ChromiumLoadFailurePresentation(missingNetCode) == .nativeOverlay)
        let foreign = NSError(domain: "Other", code: ChromiumKitError.navigationFailed.rawValue, userInfo: [
            "ChromiumNetError": NSNumber(value: -102),
        ])
        #expect(ChromiumLoadFailurePresentation(foreign) == .nativeOverlay)

        let (_, coordinator, container) = makeAttached()
        coordinator.handleNavigationFailure(NSError(domain: ChromiumKitError.errorDomain, code: ChromiumKitError.engineNotRunning.rawValue, userInfo: [
            NSURLErrorFailingURLErrorKey: url,
        ]))
        #expect(container.runtimeState == .navigationFailed)
    }

    @Test("A page dialog is presented once and answers the page exactly once")
    func dialogAnswersOnce() throws {
        let (state, coordinator, _) = makeAttached()
        var answers: [(Bool, String?)] = []
        coordinator.presentJavaScriptDialog(kind: .prompt(defaultText: "seed"), originURL: url, message: "Name?") {
            answers.append(($0, $1))
        }
        let dialog = try #require(state.javaScriptDialog)
        #expect(dialog.content.title == "127.0.0.1:4321 says")
        #expect(dialog.content.promptDefaultText == "seed")

        // A second dialog while one waits is cancelled, not stacked.
        var secondAnswer: Bool?
        coordinator.presentJavaScriptDialog(kind: .alert, originURL: url, message: "again") { accepted, _ in
            secondAnswer = accepted
        }
        #expect(secondAnswer == false)
        #expect(state.javaScriptDialog === dialog)

        dialog.accept(input: "cockpit")
        dialog.cancel()
        #expect(answers.count == 1)
        #expect(answers.first?.0 == true)
        #expect(answers.first?.1 == "cockpit")
        #expect(state.javaScriptDialog == nil, "an answered dialog clears its slot")
    }

    @Test("Closing the pane answers a waiting dialog with Cancel")
    func closeCancelsDialog() {
        let (state, coordinator, _) = makeAttached()
        var answer: Bool?
        coordinator.presentJavaScriptDialog(kind: .confirm, originURL: url, message: "Sure?") { accepted, _ in
            answer = accepted
        }
        coordinator.close()
        #expect(answer == false)
        #expect(state.javaScriptDialog == nil)
    }

    @Test("Dialog spam is cancelled until the next page load")
    func dialogSpamIsThrottled() {
        let (state, coordinator, _) = makeAttached()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var cancelled = 0
        for index in 0..<(BrowserJavaScriptDialogThrottle.limit + 2) {
            coordinator.presentJavaScriptDialog(
                kind: .alert, originURL: url, message: "\(index)",
                now: start.addingTimeInterval(Double(index))
            ) { accepted, _ in
                if !accepted { cancelled += 1 }
            }
            state.javaScriptDialog?.accept()
        }
        #expect(cancelled == 2)
        #expect(state.javaScriptDialog == nil)

        // A suppressed page cannot trap the user: beforeunload proceeds.
        var leaveAnswer: Bool?
        coordinator.presentJavaScriptDialog(
            kind: .beforeUnload(isReload: false), originURL: url, message: "",
            now: start.addingTimeInterval(8)
        ) { accepted, _ in
            leaveAnswer = accepted
        }
        #expect(leaveAnswer == true)
        #expect(state.javaScriptDialog == nil)

        var throttle = BrowserJavaScriptDialogThrottle()
        let admitted = (0..<BrowserJavaScriptDialogThrottle.limit).map {
            throttle.admit(at: start.addingTimeInterval(Double($0)))
        }
        #expect(admitted.allSatisfy { $0 })
        let overBudget = throttle.admit(at: start.addingTimeInterval(5))
        let later = throttle.admit(at: start.addingTimeInterval(60))
        #expect(!overBudget)
        #expect(!later, "suppression lasts until reset")
        throttle.reset()
        let afterReset = throttle.admit(at: start.addingTimeInterval(61))
        #expect(afterReset)
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
