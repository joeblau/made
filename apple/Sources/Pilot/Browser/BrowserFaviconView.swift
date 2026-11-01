import AppKit
import SwiftUI

/// SwiftData's transient fields do not publish changes. Keep favicon updates
/// in an observable runtime object so an already collapsed tab can refresh.
@Observable
final class BrowserFaviconMetadata {
    var pageURL: String?
    var urls: [String] = []
}

/// Runtime-only state for one `BrowserState`, observable by SwiftUI. See
/// `BrowserState.runtime`.
@Observable
final class BrowserRuntimeState {
    var pendingURL: URL? = nil
    var canGoBack: Bool = false
    var canGoForward: Bool = false
    var isLoading: Bool = false
    var title: String = ""
    var estimatedProgress: Double = 0
    var showDevTools: Bool = false
    var needsInspectorToggle: Bool = false
    /// Browser Annotate mode — runtime only, off after relaunch.
    var annotateMode: Bool = false
    var annotateToggleRequestID: Int = 0
    /// Set by ⌘L and consumed when this browser's address field is mounted.
    var needsAddressFocus: Bool = false
    /// Native navigation callbacks must not replace a newer address-field draft.
    var isAddressEditing: Bool = false
    var pendingAddressSubmission: String? = nil
    /// Recreates the WKWebView after its persistent website data is cleared.
    var websiteDataResetRequestID: Int = 0
    /// Recreates an unavailable Chromium surface without changing its engine.
    var runtimeRetryRequestID: Int = 0
    /// Chromium-only page command state. Counters make every action edge-triggered.
    var findQuery: String = ""
    var findForward: Bool = true
    var findMatchCase: Bool = false
    var findNext: Bool = false
    var findRequestID: Int = 0
    var stopFindingRequestID: Int = 0
    var findMatchCount: Int = 0
    var activeFindMatchOrdinal: Int = 0
    var printRequestID: Int = 0
    var savePageRequestID: Int = 0
    var downloadStatusText: String = ""
    var downloadProgress: Double? = nil
}

struct BrowserFaviconView: View {
    let state: BrowserState

    @State private var loadedURLs: [URL] = []
    @State private var image: NSImage?

    private var candidateURLs: [URL] {
        BrowserFaviconURLCandidates.urls(
            pageURL: state.faviconPageURL,
            advertisedURLs: state.faviconURLs
        )
    }

    var body: some View {
        let urls = candidateURLs
        Group {
            if loadedURLs == urls, let image {
                Image(nsImage: image)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "globe")
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
        .task(id: urls) {
            image = nil
            loadedURLs = []
            for url in urls {
                guard !Task.isCancelled else { return }
                let data = await BrowserFaviconCache.shared.data(for: url)
                guard !Task.isCancelled else { return }
                if let data, let favicon = NSImage(data: data), favicon.isValid {
                    image = favicon
                    loadedURLs = urls
                    return
                }
            }
        }
    }
}

enum BrowserFaviconURLCandidates {
    static func urls(pageURL: String?, advertisedURLs: [String]) -> [URL] {
        guard let pageURL, let page = URL(string: pageURL),
              var origin = httpComponents(for: page) else { return [] }

        var candidates: [URL] = []
        for advertised in advertisedURLs {
            guard !advertised.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let resolved = URL(string: advertised, relativeTo: page)?.absoluteURL,
                  let components = httpComponents(for: resolved),
                  let url = components.url, !candidates.contains(url) else { continue }
            candidates.append(url)
            // A page can advertise many sizes; avoid an unbounded retry list.
            if candidates.count == 4 { break }
        }

        origin.path = "/favicon.ico"
        origin.query = nil
        if let fallback = origin.url, !candidates.contains(fallback) {
            candidates.append(fallback)
        }
        return candidates
    }

    private static func httpComponents(for url: URL) -> URLComponents? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty else { return nil }
        components.scheme = scheme
        components.user = nil
        components.password = nil
        components.fragment = nil
        return components
    }
}

/// Shares requests between the collapsed pane and workspace strip. Leaving one
/// view must not cancel a download another visible view still needs.
private actor BrowserFaviconCache {
    static let shared = BrowserFaviconCache()

    private struct Entry {
        let data: Data?
        let expires: Date
    }

    private struct Flight {
        let id: UUID
        let task: Task<Data?, Never>
        var waiters: Set<UUID>
    }

    private var entries: [URL: Entry] = [:]
    private var flights: [URL: Flight] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    func data(for url: URL) async -> Data? {
        guard !Task.isCancelled else { return nil }
        if let entry = entries[url], entry.expires > Date() { return entry.data }

        let waiter = UUID()
        let flight: Flight
        if var existing = flights[url] {
            existing.waiters.insert(waiter)
            flights[url] = existing
            flight = existing
        } else {
            let session = session
            flight = Flight(
                id: UUID(),
                task: Task { await Self.download(url, session: session) },
                waiters: [waiter]
            )
            flights[url] = flight
        }

        return await withTaskCancellationHandler {
            let data = await flight.task.value
            complete(url: url, flight: flight, data: data)
            return Task.isCancelled ? nil : data
        } onCancel: {
            Task { await self.cancel(url: url, flightID: flight.id, waiter: waiter) }
        }
    }

    private func cancel(url: URL, flightID: UUID, waiter: UUID) {
        guard var flight = flights[url], flight.id == flightID else { return }
        flight.waiters.remove(waiter)
        if flight.waiters.isEmpty {
            flights.removeValue(forKey: url)
            flight.task.cancel()
        } else {
            flights[url] = flight
        }
    }

    private func complete(url: URL, flight: Flight, data: Data?) {
        guard flights[url]?.id == flight.id else { return }
        flights.removeValue(forKey: url)
        if entries.count >= 128,
           let oldest = entries.min(by: { $0.value.expires < $1.value.expires })?.key {
            entries.removeValue(forKey: oldest)
        }
        entries[url] = Entry(data: data, expires: Date().addingTimeInterval(data == nil ? 60 : 300))
    }

    private nonisolated static func download(_ url: URL, session: URLSession) async -> Data? {
        let maximumBytes = 512 * 1024
        do {
            let (bytes, response) = try await session.bytes(for: URLRequest(url: url))
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  response.expectedContentLength <= maximumBytes else { return nil }
            var data = Data()
            for try await byte in bytes {
                guard !Task.isCancelled, data.count < maximumBytes else { return nil }
                data.append(byte)
            }
            return data.isEmpty ? nil : data
        } catch {
            return nil
        }
    }
}
