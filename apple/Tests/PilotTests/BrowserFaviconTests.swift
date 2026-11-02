import Foundation
import Observation
import SwiftData
import Synchronization
import Testing
@testable import Pilot

@Suite("Browser favicon candidates")
struct BrowserFaviconTests {
    @Test("A collapsed tab observes navigation and later favicon discovery")
    func faviconMetadataNotifiesObservers() throws {
        let state = BrowserState()
        let page = try #require(URL(string: "https://example.com"))
        let icon = try #require(URL(string: "https://example.com/brand.png"))
        let pageChanged = Mutex(false)
        withObservationTracking {
            _ = state.faviconPageURL
        } onChange: {
            pageChanged.withLock { $0 = true }
        }
        state.commitFaviconPage(page)
        #expect(pageChanged.withLock { $0 })

        let iconsChanged = Mutex(false)
        withObservationTracking {
            _ = state.faviconURLs
        } onChange: {
            iconsChanged.withLock { $0 = true }
        }
        state.updateFaviconURLs([icon], for: page)
        #expect(iconsChanged.withLock { $0 })
    }

    @Test
    func fallbackUsesPageOriginAndPreservesDevelopmentServerPort() {
        let urls = BrowserFaviconURLCandidates.urls(
            pageURL: "http://user:password@localhost:3000/nested/page?mode=preview#section",
            advertisedURLs: []
        )

        #expect(urls.map(\.absoluteString) == ["http://localhost:3000/favicon.ico"])
    }

    @Test
    func advertisedIconsKeepTheirOrderAndResolveAgainstTheCommittedPage() {
        let urls = BrowserFaviconURLCandidates.urls(
            pageURL: "https://example.com/docs/page",
            advertisedURLs: [
                "/brand.png?size=32#icon",
                "/brand.png?size=32",
                "../alternate.ico",
                "https://cdn.example.com/icon.png",
                "/favicon.ico"
            ]
        )

        #expect(urls.map(\.absoluteString) == [
            "https://example.com/brand.png?size=32",
            "https://example.com/alternate.ico",
            "https://cdn.example.com/icon.png",
            "https://example.com/favicon.ico"
        ])
    }

    @Test
    func unsupportedIconSchemesAreSkipped() {
        let urls = BrowserFaviconURLCandidates.urls(
            pageURL: "https://example.com",
            advertisedURLs: ["javascript:alert(1)", "file:///tmp/icon.png", "data:image/png;base64,AA==", ""]
        )

        #expect(urls.map(\.absoluteString) == ["https://example.com/favicon.ico"])
    }

    @Test(arguments: [nil, "", "about:blank", "file:///tmp/page.html", "blau://reload"] as [String?])
    func blankAndUnsupportedPagesHaveNoIconCandidates(pageURL: String?) {
        #expect(BrowserFaviconURLCandidates.urls(
            pageURL: pageURL,
            advertisedURLs: ["https://example.com/icon.png"]
        ).isEmpty)
    }
}

/// SwiftData does not publish `@Transient` stored properties, so a mounted
/// toolbar never saw ⌘L or Lasso on an already selected browser. These
/// runtime fields are observable now; the persisted schema is unchanged.
@Suite("Browser runtime state observation")
struct BrowserRuntimeStateObservationTests {
    private func notifies(
        _ read: @escaping () -> Void,
        after write: () -> Void
    ) -> Bool {
        let changed = Mutex(false)
        withObservationTracking(read) {
            changed.withLock { $0 = true }
        }
        write()
        return changed.withLock { $0 }
    }

    @Test("⌘L on a mounted address field notifies its observer")
    func addressFocusRequestNotifies() {
        let state = BrowserState()
        #expect(notifies({ _ = state.needsAddressFocus }) {
            _ = state.perform(.focusAddress)
        })
        #expect(state.needsAddressFocus)
    }

    @Test("Lasso, loading, and history changes notify observers")
    func toolbarStateNotifies() {
        let state = BrowserState()
        #expect(notifies({ _ = state.annotateMode }) {
            _ = state.perform(.toggleAnnotation)
        })
        #expect(notifies({ _ = state.annotateToggleRequestID }) {
            state.setAnnotateMode(false)
        })
        #expect(notifies({ _ = state.isLoading }) {
            state.isLoading = true
        })
        #expect(notifies({ _ = state.canGoBack }) {
            state.canGoBack = true
        })
        #expect(notifies({ _ = state.websiteDataResetRequestID }) {
            state.requestWebsiteDataReset()
        })
    }

    @Test("Runtime fields stay out of the persisted schema")
    func runtimeFieldsAreNotPersisted() throws {
        let schema = Schema([BrowserState.self])
        let entity = try #require(schema.entities.first { $0.name == "BrowserState" })
        #expect(Set(entity.properties.map(\.name)) == [
            "urlText",
            "engineRaw",
            "appearanceModeRaw",
            "navigationRequestID",
            "inspectorToggleRequestID",
        ])
    }
}
