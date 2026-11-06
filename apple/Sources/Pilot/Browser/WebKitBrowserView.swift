import AppKit
import Security
@preconcurrency import WebKit

@MainActor
enum BrowserWebsiteData {
    static let allDataTypes = WKWebsiteDataStore.allWebsiteDataTypes()

    static func clearAll() async {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().removeData(
                ofTypes: allDataTypes,
                modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }
    }
}

@MainActor
final class WebViewRepresentable: NSViewController {
    let state: BrowserState
    var isActive = false
    var isSelected = false
    var onSelect: () -> Void
    let targetTerminalPaneID: @MainActor () -> UUID?
    private lazy var coordinator = Coordinator(state: state, targetTerminalPaneID: targetTerminalPaneID)
    private var webView: WKWebView?
    private var uiZoom: Double { CockpitUIZoomController.shared.factor }
    private var navigationRequestID: Int { state.navigationRequestID }
    private var inspectorToggleRequestID: Int { state.inspectorToggleRequestID }
    private var findRequestID: Int { state.findRequestID }
    private var stopFindingRequestID: Int { state.stopFindingRequestID }
    private var annotateMode: Bool { state.annotateMode }
    private var annotateToggleRequestID: Int { state.annotateToggleRequestID }
    private var appearanceMode: AppearanceMode { state.appearanceMode }

    init(state: BrowserState, onSelect: @escaping () -> Void, targetTerminalPaneID: @escaping @MainActor () -> UUID?) {
        self.state = state
        self.onSelect = onSelect
        self.targetTerminalPaneID = targetTerminalPaneID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // Browser Annotate: inject the in-page overlay + a message handler for
        // the single "send" round-trip.
        config.userContentController.add(
            coordinator,
            contentWorld: BrowserAnnotate.contentWorld,
            name: BrowserAnnotate.messageName
        )
        // Main frame only: the page snapshot covers the top document, so element
        // rects must be in top-document coordinates. Injecting into subframes
        // would let the box open inside an iframe with rects the screenshot
        // can't line up against.
        config.userContentController.addUserScript(
            WKUserScript(
                source: BrowserAnnotate.userScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: BrowserAnnotate.contentWorld
            )
        )
        let webView = BrowserWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.isInspectable = true
        webView.isHidden = !isActive
        webView.isPaneSelected = isActive && isSelected
        webView.onReload = { [weak state] in state?.requestNavigationCommand("blau://reload") }
        webView.onSelect = onSelect
        webView.browserState = state
        webView.performBrowserCommand(.setZoom(uiZoom))
        coordinator.lastFindRequestID = findRequestID
        coordinator.lastStopFindingRequestID = stopFindingRequestID
        coordinator.observeURL(of: webView)
        if let url = initialURL {
            webView.load(URLRequest(url: url))
        }
        self.webView = webView
        view = webView
    }

    func synchronize() {
        guard let nsView = webView else { return }
        _ = navigationRequestID
        _ = inspectorToggleRequestID
        _ = annotateToggleRequestID

        if abs(nsView.pageZoom - uiZoom) > 0.001 {
            nsView.performBrowserCommand(.setZoom(uiZoom))
        }

        if let browserView = nsView as? BrowserWebView {
            browserView.isPaneSelected = isActive && isSelected
            browserView.onReload = { [weak state] in state?.requestNavigationCommand("blau://reload") }
            browserView.onSelect = onSelect
            browserView.browserState = state
        }

        nsView.isHidden = !isActive

        // Handle navigation commands
        if let pending = state.pendingURL {
            BrowserControllerCommandRouter.route(pending, to: nsView)
            state.pendingURL = nil
        }

        // Toggle Web Inspector (opens in separate window)
        if state.needsInspectorToggle {
            state.needsInspectorToggle = false
            nsView.performBrowserCommand(
                .setDeveloperToolsVisible(state.showDevTools)
            )
        }

        coordinator.consumeFindRequests(
            findRequestID: findRequestID,
            stopFindingRequestID: stopFindingRequestID,
            in: nsView
        )

        // Browser Annotate: push the enabled state into the injected overlay.
        if coordinator.lastAnnotateToggleID != annotateToggleRequestID {
            coordinator.lastAnnotateToggleID = annotateToggleRequestID
            coordinator.setAnnotateMode(annotateMode, in: nsView)
        }

        // Always apply appearance — NSAppearance drives prefers-color-scheme in WKWebView
        let appearance: NSAppearance?
        switch appearanceMode {
        case .system: appearance = nil
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
        if nsView.appearance != appearance {
            nsView.appearance = appearance
            nsView.evaluateJavaScript(
                "document.documentElement.style.colorScheme = '\(appearanceMode == .dark ? "dark" : appearanceMode == .light ? "light" : "")'"
            )
        }
    }

    @discardableResult
    func focusContent() -> Bool {
        guard isActive, isSelected, let webView, let window = webView.window,
              !webView.isHiddenOrHasHiddenAncestor else { return false }
        if BrowserPaneFocus.responder(window.firstResponder, isWithin: webView) { return true }
        return window.makeFirstResponder(webView)
    }

    func close() {
        guard let webView else { return }
        coordinator.invalidate()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: BrowserAnnotate.messageName,
            contentWorld: BrowserAnnotate.contentWorld
        )
        self.webView = nil
    }

    isolated deinit { close() }

    private var initialURL: URL? {
        if let pendingURL = state.pendingURL,
           pendingURL.scheme != "blau" {
            return pendingURL
        }

        let trimmed = state.urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }

        return URL(string: "https://\(trimmed)")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler {
        let state: BrowserState
        let targetTerminalPaneID: @MainActor () -> UUID?
        /// Last annotate-toggle id pushed into the page, to deduplicate native controller updates.
        var lastAnnotateToggleID = -1
        /// Edge-trigger state for Find in Page requests.
        var lastFindRequestID = 0
        var lastStopFindingRequestID = 0
        private var urlObservation: NSKeyValueObservation?
        private var navStateObservations: [NSKeyValueObservation] = []
        private var pendingDestinations: [ObjectIdentifier: URL] = [:]
        private var annotateGrant: BrowserAnnotate.BridgeGrant?
        private weak var observedWebView: WKWebView?
        private var mainFrameURL: URL?
        private var navigationGeneration = 0
        private var certificateExceptions = BrowserCertificateExceptions()
        private var isPresentingCertificateWarning = false
        private var dialogThrottle = BrowserJavaScriptDialogThrottle()
        private let confirmCertificate: @MainActor (BrowserCertificateIdentity) -> Bool

        init(
            state: BrowserState,
            targetTerminalPaneID: @escaping @MainActor () -> UUID?,
            confirmCertificate: @escaping @MainActor (BrowserCertificateIdentity) -> Bool = BrowserCertificateWarning.confirm
        ) {
            self.state = state
            self.targetTerminalPaneID = targetTerminalPaneID
            self.confirmCertificate = confirmCertificate
        }

        isolated deinit {
            urlObservation?.invalidate()
            navStateObservations.forEach { $0.invalidate() }
        }

        func invalidate() {
            state.javaScriptDialog?.cancel()
            navigationGeneration += 1
            observedWebView = nil
            mainFrameURL = nil
            certificateExceptions.removeAll()
            annotateGrant = nil
            urlObservation?.invalidate()
            urlObservation = nil
            navStateObservations.forEach { $0.invalidate() }
            navStateObservations = []
        }

        // MARK: - Page dialogs

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
            presentDialog(webView, kind: .alert, message: message, frame: frame) { _, _ in completionHandler() }
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
            presentDialog(webView, kind: .confirm, message: message, frame: frame) { accepted, _ in completionHandler(accepted) }
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping @MainActor (String?) -> Void) {
            presentDialog(webView, kind: .prompt(defaultText: defaultText ?? ""), message: prompt, frame: frame) {
                accepted, input in completionHandler(accepted ? input : nil)
            }
        }

        private func presentDialog(_ webView: WKWebView, kind: BrowserJavaScriptDialogKind, message: String,
                                   frame: WKFrameInfo, respond: @escaping (Bool, String?) -> Void) {
            guard observedWebView === webView, webView.window?.isVisible == true,
                  !webView.isHiddenOrHasHiddenAncestor, dialogThrottle.admit(at: Date()) else {
                respond(false, nil)
                return
            }
            let content = BrowserJavaScriptDialogContent(kind: kind, originURL: frame.request.url, message: message)
            state.presentJavaScriptDialog(content, respond: respond)
        }

        // MARK: - Find in Page

        /// WebKit's public find API selects the next match and reports only
        /// whether one exists, so the bar shows "Match found" rather than a
        /// count. A result for a superseded request is dropped.
        func consumeFindRequests(
            findRequestID: Int,
            stopFindingRequestID: Int,
            in webView: WKWebView
        ) {
            if lastStopFindingRequestID != stopFindingRequestID {
                lastStopFindingRequestID = stopFindingRequestID
                state.findMatchCount = 0
                state.activeFindMatchOrdinal = 0
                // WebKit has no public call to hide its find highlight, which
                // stayed on the last match after Done or Escape. A search that
                // cannot match clears it.
                webView.find(UUID().uuidString, configuration: WKFindConfiguration()) { _ in }
            }
            guard lastFindRequestID != findRequestID else { return }
            lastFindRequestID = findRequestID
            let query = state.findQuery
            guard !query.isEmpty else { return }
            let configuration = WKFindConfiguration()
            configuration.backwards = !state.findForward
            configuration.caseSensitive = state.findMatchCase
            configuration.wraps = true
            let state = state
            webView.find(query, configuration: configuration) { result in
                MainActor.assumeIsolated {
                    guard state.findRequestID == findRequestID,
                          state.findQuery == query else { return }
                    state.findMatchCount = result.matchFound ? 1 : 0
                    state.activeFindMatchOrdinal = result.matchFound ? 1 : 0
                }
            }
        }

        // MARK: - Certificate warnings

        func trackMainFrameNavigation(to url: URL?) {
            navigationGeneration += 1
            mainFrameURL = url
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.targetFrame?.isMainFrame == true {
                trackMainFrameNavigation(to: navigationAction.request.url)
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            trackMainFrameNavigation(to: webView.url)
        }

        func webView(
            _ webView: WKWebView,
            respondTo challenge: URLAuthenticationChallenge
        ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            let space = challenge.protectionSpace
            guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = space.serverTrust else { return (.performDefaultHandling, nil) }
            let generation = navigationGeneration
            let requestID = state.navigationRequestID
            let trusted = await Self.evaluate(trust)
            if trusted == true { return (.performDefaultHandling, nil) }

            var trustResult = SecTrustResultType.invalid
            var components = URLComponents()
            components.scheme = space.protocol
            components.host = space.host
            components.port = space.port > 0 ? space.port : nil
            guard trusted == false,
                  SecTrustGetTrustResult(trust, &trustResult) == errSecSuccess,
                  trustResult == .recoverableTrustFailure,
                  let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let leaf = certificates.first,
                  let url = components.url,
                  let identity = BrowserCertificateIdentity(url: url, certificateDER: SecCertificateCopyData(leaf) as Data),
                  canContinueCertificate(identity, in: webView, generation: generation, requestID: requestID)
            else { return (.cancelAuthenticationChallenge, nil) }

            if !certificateExceptions.allows(identity) {
                guard canPresentCertificateWarning(in: webView), !isPresentingCertificateWarning
                else { return (.cancelAuthenticationChallenge, nil) }
                isPresentingCertificateWarning = true
                defer { isPresentingCertificateWarning = false }
                guard confirmCertificate(identity),
                      canContinueCertificate(identity, in: webView, generation: generation, requestID: requestID),
                      canPresentCertificateWarning(in: webView)
                else { return (.cancelAuthenticationChallenge, nil) }
                certificateExceptions.allow(identity)
            }
            return (.useCredential, URLCredential(trust: trust))
        }

        private func canContinueCertificate(
            _ identity: BrowserCertificateIdentity,
            in webView: WKWebView,
            generation: Int,
            requestID: Int
        ) -> Bool {
            observedWebView === webView
                && webView.navigationDelegate === self
                && navigationGeneration == generation
                && state.navigationRequestID == requestID
                && mainFrameURL.flatMap(ChromiumOrigin.init(url:)) == identity.origin
        }

        private func canPresentCertificateWarning(in webView: WKWebView) -> Bool {
            (webView as? BrowserWebView)?.isPaneSelected == true
                && !webView.isHiddenOrHasHiddenAncestor
                && webView.window?.isVisible == true
        }

        private static func evaluate(_ trust: SecTrust) async -> Bool? {
            await withCheckedContinuation { continuation in
                let status = SecTrustEvaluateAsyncWithError(trust, .main) { _, trusted, _ in
                    continuation.resume(returning: trusted)
                }
                if status != errSecSuccess { continuation.resume(returning: nil) }
            }
        }

        // MARK: - Browser Annotate

        func setAnnotateMode(_ enabled: Bool, in webView: WKWebView) {
            guard enabled, let navigationURL = webView.url?.absoluteString else {
                annotateGrant = nil
                BrowserAnnotate.evaluate(BrowserAnnotate.setEnabledScript(false), in: webView)
                return
            }
            let token = UUID().uuidString
            annotateGrant = BrowserAnnotate.BridgeGrant(
                token: token,
                navigationURL: navigationURL,
                expiresAt: Date(timeIntervalSinceNow: BrowserAnnotate.grantLifetime)
            )
            BrowserAnnotate.evaluate(
                BrowserAnnotate.setEnabledScript(true, token: token),
                in: webView
            )
        }

        /// The isolated-world web→Swift hop. A main-frame, current-navigation,
        /// single-use grant is consumed before the asynchronous snapshot starts.
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == BrowserAnnotate.messageName,
                  message.frameInfo.isMainFrame,
                  let payload = BrowserAnnotate.MessagePayload.parse(message.body) else { return }
            // WebKit calls this on the main thread.
            MainActor.assumeIsolated {
                guard state.annotateMode,
                      let webView = message.webView,
                      let currentURL = webView.url?.absoluteString,
                      annotateGrant?.consume(payload, currentURL: currentURL) == true else { return }
                annotateGrant = nil
                // Resolve the terminal synchronously while the user's last
                // terminal click is still authoritative. `takeSnapshot` is
                // asynchronous; looking it up in its completion can send to a
                // different LLM if the user changes panes/workspaces meanwhile.
                let dispatch = BrowserAnnotate.DispatchContext(
                    targetPaneID: targetTerminalPaneID()
                )
                webView.takeSnapshot(with: WKSnapshotConfiguration()) { [weak self, weak webView] image, _ in
                    Task { @MainActor in
                        guard let self, let webView, self.observedWebView === webView,
                              webView.url?.absoluteString == payload.url else { return }
                        // Keep the trusted outline through capture, then clear it
                        // in the same isolated content world.
                        BrowserAnnotate.evaluate(
                            BrowserAnnotate.finishSendScript(selectionID: payload.selectionID),
                            in: webView
                        )
                        let path = BrowserAnnotate.writeScreenshot(image)
                        let prompt = BrowserAnnotate.buildPrompt(
                            instruction: payload.instruction,
                            url: payload.url,
                            selector: payload.selector,
                            outerHTML: payload.outerHTML,
                            rectX: payload.rectX,
                            rectY: payload.rectY,
                            rectW: payload.rectW,
                            rectH: payload.rectH,
                            screenshotPath: path
                        )
                        if self.confirmDispatch(instruction: payload.instruction, url: payload.url) {
                            NotificationCenter.default.post(
                                name: .pilotSendIssuePrompt,
                                object: nil,
                                userInfo: dispatch.notificationUserInfo(prompt: prompt)
                            )
                        }
                        if self.state.annotateMode {
                            self.setAnnotateMode(true, in: webView)
                        }
                    }
                }
            }
        }

        private func confirmDispatch(instruction: String, url: String) -> Bool {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Send browser annotation to the terminal?"
            alert.informativeText = "Instruction: \(instruction)\n\nPage: \(url)\n\nPage content is untrusted and will be clearly delimited in the prompt."
            alert.addButton(withTitle: "Send")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }

        /// KVO on `WKWebView.url` so the address bar reflects every URL
        /// change — link clicks, server redirects, hash changes, and
        /// `history.pushState` from SPAs — not just `didFinish` loads.
        /// `canGoBack`/`canGoForward` get the same treatment: same-document
        /// SPA navigations never hit the delegate callbacks that otherwise
        /// refresh them, which left Back/Forward stuck disabled.
        func observeURL(of webView: WKWebView) {
            observedWebView = webView
            urlObservation?.invalidate()
            urlObservation = webView.observe(\.url, options: [.new, .initial]) { [weak self] webView, _ in
                Task { @MainActor [weak self, weak webView] in
                    guard let self, let webView, let url = webView.url else { return }
                    guard self.observedWebView === webView else { return }
                    self.state.acceptCommittedURL(url)
                    guard webView.url == url else { return }
                    self.state.commitFaviconPage(url)
                    self.refreshFavicon(in: webView)
                }
            }
            navStateObservations.forEach { $0.invalidate() }
            navStateObservations = [
                webView.observe(\.canGoBack, options: [.new, .initial]) { [weak self] webView, _ in
                    Task { @MainActor [weak self, weak webView] in
                        guard let self, let webView, self.observedWebView === webView else { return }
                        self.state.canGoBack = webView.canGoBack
                    }
                },
                webView.observe(\.canGoForward, options: [.new, .initial]) { [weak self] webView, _ in
                    Task { @MainActor [weak self, weak webView] in
                        guard let self, let webView, self.observedWebView === webView else { return }
                        self.state.canGoForward = webView.canGoForward
                    }
                },
            ]
        }

        // MARK: - Download routing

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
        ) {
            // Anything WebKit can't render inline (zip, dmg, pkg, raw images
            // when triggered via Save As, etc.) is converted to a download.
            decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
        }

        func webView(
            _ webView: WKWebView,
            navigationAction: WKNavigationAction,
            didBecome download: WKDownload
        ) {
            download.delegate = self
        }

        func webView(
            _ webView: WKWebView,
            navigationResponse: WKNavigationResponse,
            didBecome download: WKDownload
        ) {
            download.delegate = self
        }

        // MARK: - WKDownloadDelegate

        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @MainActor @Sendable @escaping (URL?) -> Void
        ) {
            let directory = FileManager.default.urls(
                for: .downloadsDirectory,
                in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let destination = Self.uniqueDestination(in: directory, suggestedFilename: suggestedFilename)
            pendingDestinations[ObjectIdentifier(download)] = destination
            completionHandler(destination)
        }

        func downloadDidFinish(_ download: WKDownload) {
            guard let url = pendingDestinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            pendingDestinations.removeValue(forKey: ObjectIdentifier(download))
        }

        private static func uniqueDestination(in directory: URL, suggestedFilename: String) -> URL {
            let fallback = suggestedFilename.isEmpty ? "download" : suggestedFilename
            var candidate = directory.appendingPathComponent(fallback)
            guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

            let ext = candidate.pathExtension
            let stem = candidate.deletingPathExtension().lastPathComponent
            for n in 1...999 {
                let nextName = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
                candidate = directory.appendingPathComponent(nextName)
                if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
            return candidate
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            state.javaScriptDialog?.cancel()
            dialogThrottle.reset()
            annotateGrant = nil
            state.isLoading = true
            updateNavState(webView)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            // Earliest reliable point — URL is now the real destination
            // (after any provisional redirects).
            if let url = webView.url {
                state.acceptCommittedURL(url)
                state.commitFaviconPage(url)
            }
            updateNavState(webView)
            // Arm before slow or perpetual subresources can delay `didFinish`.
            if state.annotateMode { setAnnotateMode(true, in: webView) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            state.isLoading = false
            if let url = webView.url {
                state.acceptCommittedURL(url)
            }
            updateNavState(webView)
            refreshFavicon(in: webView)
            // Retry without rotating a grant captured by an early selection.
            if state.annotateMode, annotateGrant == nil {
                setAnnotateMode(true, in: webView)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            state.isLoading = false
            updateNavState(webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            state.isLoading = false
            updateNavState(webView)
        }

        private func refreshFavicon(in webView: WKWebView) {
            let script = """
            (() => ({
                url: document.URL,
                icons: Array.from(document.querySelectorAll('link[rel]'))
                    .filter(link => link.rel.toLowerCase().split(/\\s+/)
                        .some(rel => rel === 'icon' || rel === 'apple-touch-icon'))
                    .slice(0, 16).map(link => link.href)
            }))()
            """
            webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { [weak self, weak webView] result in
                guard let self, let webView, self.observedWebView === webView,
                      case .success(let value) = result,
                      let metadata = value as? [String: Any],
                      let page = metadata["url"] as? String,
                      let url = URL(string: page), webView.url == url,
                      let icons = metadata["icons"] as? [String] else { return }
                self.state.updateFaviconURLs(icons.compactMap(URL.init(string:)), for: url)
            }
        }

        private func updateNavState(_ webView: WKWebView) {
            state.canGoBack = webView.canGoBack
            state.canGoForward = webView.canGoForward
        }
    }
}
