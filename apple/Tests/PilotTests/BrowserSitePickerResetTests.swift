import AppKit
import Testing
@testable import Pilot

@MainActor
@Suite("Browser site-picker reset")
struct BrowserSitePickerResetTests {
    private func browserPane(engine: BrowserEngine = .webKit) -> (Pane, BrowserState) {
        let pane = Pane(kind: .browser)
        let state = BrowserState(engine: engine)
        state.urlText = "http://localhost:3000/dashboard"
        state.title = "Dashboard"
        state.canGoBack = true
        state.isLoading = true
        pane.browserState = state
        return (pane, state)
    }

    @Test("A browser pane returns to its engine's site list with the old page discarded")
    func returnsToSiteList() async throws {
        let (pane, state) = browserPane()
        defer { pane.isChoosingMode = false }
        let surface = state.runtimeRetryRequestID
        var posted: [UUID] = []
        let observer = NotificationCenter.default.addObserver(forName: .paneDidReturnToNewTab, object: nil, queue: nil) { note in
            if let id = note.object as? UUID { MainActor.assumeIsolated { posted.append(id) } }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        pane.returnToSitePicker()

        #expect(pane.isChoosingMode)
        #expect(pane.openingPath == [.root, .browser, .browserServers(.webKit)])
        #expect(posted == [pane.id])
        #expect(state.urlText.isEmpty && state.title.isEmpty)
        #expect(!state.canGoBack && !state.isLoading && state.pendingURL == nil)
        // A new surface, so the next site does not inherit the old page's history.
        #expect(state.runtimeRetryRequestID == surface + 1)

        // Calling it again while the list is up changes nothing.
        pane.returnToSitePicker()
        #expect(posted == [pane.id] && state.runtimeRetryRequestID == surface + 1)

        let next = try #require(URL(string: "http://localhost:8081"))
        #expect(pane.applyOpeningChoice(.browser(.webKit, next)))
        #expect(!pane.isChoosingMode && pane.kind == .browser)
        #expect(pane.browserState === state)
        #expect(state.urlText == next.absoluteString && state.pendingURL == next)
    }

    @Test("Chromium panes return to the Chrome list; other panes are left alone")
    func engineAndKind() {
        let (chrome, _) = browserPane(engine: .chromium)
        defer { chrome.isChoosingMode = false }
        chrome.returnToSitePicker()
        #expect(chrome.openingPath.last == .browserServers(.chromium))

        let terminal = Pane(kind: .terminal)
        terminal.returnToSitePicker()
        #expect(!terminal.isChoosingMode)
    }

    @Test("The tools menu offers Choose Another Site only where a pane can be reset")
    func toolsMenuItem() throws {
        let (_, state) = browserPane()
        let toolbar = BrowserToolbarView(state: state)
        let unavailable = try #require(toolbar.makeToolsMenu().items.first { $0.title == "Choose Another Site" })
        #expect(!unavailable.isEnabled)

        var chosen = 0
        toolbar.onChooseSite = { chosen += 1 }
        let menu = toolbar.makeToolsMenu()
        let index = try #require(menu.items.firstIndex { $0.title == "Choose Another Site" })
        #expect(menu.items[index].isEnabled)
        #expect(index < (menu.items.firstIndex { $0.title == "Clear All Browser Data…" } ?? 0))
        menu.performActionForItem(at: index)
        #expect(chosen == 1)
    }
}
