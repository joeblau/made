import AppKit
import Testing
import WebKit
@testable import Pilot

@Suite("Browser reload recovery")
@MainActor
struct BrowserReloadRecoveryTests {
    /// Nothing listens on the discard port, so the load fails provisionally.
    private let refused = "http://127.0.0.1:9/"

    private func wait(_ timeout: TimeInterval = 10, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test("Reload after a failed first load retries the address instead of sticking in Loading")
    func reloadAfterFailedFirstLoadRetries() async throws {
        let state = BrowserState(engine: .webKit)
        state.urlText = refused
        let controller = WebViewRepresentable(state: state, onSelect: {}, targetTerminalPaneID: { nil })
        let webView = try #require(controller.view as? WKWebView)
        defer { controller.close() }
        #expect(await wait { webView.isLoading })
        #expect(await wait { !webView.isLoading && !state.isLoading })
        #expect(webView.url == nil, "a refused first load leaves WebKit with nothing to reload")
        #expect(state.emptyPage?.failedURL?.absoluteString == refused, "the blank pane gets the server list")
        #expect(state.emptyPage?.reason?.isEmpty == false)

        state.perform(.reload)
        controller.synchronize()
        #expect(await wait(2) { webView.isLoading }, "Reload must start a new load of the address")
        #expect(await wait { !webView.isLoading && !state.isLoading }, "and must not leave the toolbar on Stop")
    }

    @Test("A web view opened with no address reports an empty page")
    func blankWebViewReportsEmptyPage() throws {
        let state = BrowserState(engine: .webKit)
        let controller = WebViewRepresentable(state: state, onSelect: {}, targetTerminalPaneID: { nil })
        _ = controller.view
        defer { controller.close() }
        #expect(state.emptyPage == BrowserEmptyPage())
        #expect(WebViewRepresentable.Coordinator.isBlank(URL(string: "about:blank")))
        #expect(!WebViewRepresentable.Coordinator.isBlank(URL(string: "http://localhost:3000")))
    }
}
