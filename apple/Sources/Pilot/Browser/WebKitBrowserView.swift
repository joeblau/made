import AppKit
import SwiftUI
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

struct WebViewRepresentable: NSViewRepresentable {
    @Environment(\.uiZoom) private var uiZoom

    let state: BrowserState
    let navigationRequestID: Int
    let inspectorToggleRequestID: Int
    let annotateMode: Bool
    let annotateToggleRequestID: Int
    let appearanceMode: AppearanceMode
    let isActive: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let targetTerminalPaneID: @MainActor () -> UUID?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // Browser Annotate: inject the in-page overlay + a message handler for
        // the single "send" round-trip.
        config.userContentController.add(
            context.coordinator,
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
        webView.navigationDelegate = context.coordinator
        webView.isInspectable = true
        webView.isHidden = !isActive
        webView.isPaneSelected = isActive && isSelected
        webView.onReload = { state.requestNavigationCommand("blau://reload") }
        webView.onSelect = onSelect
        webView.performBrowserCommand(.setZoom(uiZoom))
        context.coordinator.observeURL(of: webView)
        if let url = initialURL {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        _ = navigationRequestID
        _ = inspectorToggleRequestID
        _ = annotateToggleRequestID

        if abs(nsView.pageZoom - uiZoom) > 0.001 {
            nsView.performBrowserCommand(.setZoom(uiZoom))
        }

        if let browserView = nsView as? BrowserWebView {
            browserView.isPaneSelected = isActive && isSelected
            browserView.onReload = { state.requestNavigationCommand("blau://reload") }
            browserView.onSelect = onSelect
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

        // Browser Annotate: push the enabled state into the injected overlay.
        if context.coordinator.lastAnnotateToggleID != annotateToggleRequestID {
            context.coordinator.lastAnnotateToggleID = annotateToggleRequestID
            context.coordinator.setAnnotateMode(annotateMode, in: nsView)
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

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state, targetTerminalPaneID: targetTerminalPaneID)
    }

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

    final class Coordinator: NSObject, WKNavigationDelegate, WKDownloadDelegate, WKScriptMessageHandler {
        let state: BrowserState
        let targetTerminalPaneID: @MainActor () -> UUID?
        /// Last annotate-toggle id pushed into the page, to dedupe updateNSView runs.
        var lastAnnotateToggleID = -1
        private var urlObservation: NSKeyValueObservation?
        private var navStateObservations: [NSKeyValueObservation] = []
        private var pendingDestinations: [ObjectIdentifier: URL] = [:]
        private var annotateGrant: BrowserAnnotate.BridgeGrant?

        init(state: BrowserState, targetTerminalPaneID: @escaping @MainActor () -> UUID?) {
            self.state = state
            self.targetTerminalPaneID = targetTerminalPaneID
        }

        deinit {
            urlObservation?.invalidate()
            navStateObservations.forEach { $0.invalidate() }
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
                        guard let self, let webView,
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
            urlObservation?.invalidate()
            urlObservation = webView.observe(\.url, options: [.new, .initial]) { [weak self] webView, _ in
                guard let self, let url = webView.url else { return }
                let absolute = url.absoluteString
                Task { @MainActor in
                    if self.state.urlText != absolute {
                        self.state.urlText = absolute
                    }
                    guard webView.url == url else { return }
                    self.state.commitFaviconPage(url)
                    self.refreshFavicon(in: webView)
                }
            }
            navStateObservations.forEach { $0.invalidate() }
            navStateObservations = [
                webView.observe(\.canGoBack, options: [.new, .initial]) { [weak self] webView, _ in
                    Task { @MainActor in
                        self?.state.canGoBack = webView.canGoBack
                    }
                },
                webView.observe(\.canGoForward, options: [.new, .initial]) { [weak self] webView, _ in
                    Task { @MainActor in
                        self?.state.canGoForward = webView.canGoForward
                    }
                },
            ]
        }

        // MARK: - Download routing

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
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
            annotateGrant = nil
            state.isLoading = true
            updateNavState(webView)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            // Earliest reliable point — URL is now the real destination
            // (after any provisional redirects).
            if let url = webView.url {
                state.urlText = url.absoluteString
                state.commitFaviconPage(url)
            }
            updateNavState(webView)
            // Arm before slow or perpetual subresources can delay `didFinish`.
            if state.annotateMode { setAnnotateMode(true, in: webView) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            state.isLoading = false
            if let url = webView.url {
                state.urlText = url.absoluteString
                state.pendingURL = nil
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
                guard let self, let webView,
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
