import AppKit
import SwiftUI

/// Hosts one browser pane: the local-server start page until a URL loads,
/// then the engine-specific surface (WebKit or Chromium) for `state.engine`.
struct BrowserPaneView: View {
    let state: BrowserState
    let rootPath: String?
    let isActive: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let targetTerminalPaneID: @MainActor () -> UUID?

    @State private var hasLoadedAnyURL: Bool = false
    @State private var openedWithBlankURL: Bool?

    var body: some View {
        if shouldShowStartPage {
            BrowserStartPageView(rootPath: rootPath) { server in
                onSelect()
                state.urlText = server.url.absoluteString
                state.navigate()
                hasLoadedAnyURL = true
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .onAppear { captureInitialURLState() }
        } else {
            browserSurface
            .id("\(state.websiteDataResetRequestID):\(state.runtimeRetryRequestID)")
            .onAppear {
                captureInitialURLState()
                hasLoadedAnyURL = true
            }
        }
    }

    @ViewBuilder
    private var browserSurface: some View {
        switch state.engine {
        case .webKit:
            WebViewRepresentable(
                state: state,
                navigationRequestID: state.navigationRequestID,
                inspectorToggleRequestID: state.inspectorToggleRequestID,
                annotateMode: state.annotateMode,
                annotateToggleRequestID: state.annotateToggleRequestID,
                appearanceMode: state.appearanceMode,
                isActive: isActive,
                isSelected: isSelected,
                onSelect: onSelect,
                targetTerminalPaneID: targetTerminalPaneID
            )
        case .chromium:
            ChromiumBrowserView(
                state: state,
                navigationRequestID: state.navigationRequestID,
                inspectorToggleRequestID: state.inspectorToggleRequestID,
                findRequestID: state.findRequestID,
                stopFindingRequestID: state.stopFindingRequestID,
                printRequestID: state.printRequestID,
                savePageRequestID: state.savePageRequestID,
                isActive: isActive,
                isSelected: isSelected,
                onSelect: onSelect
            )
        }
    }

    private var shouldShowStartPage: Bool {
        // Sticky: once a URL is loaded, never flip back even if the user
        // clears the address bar to type a new one. Persisted panes that
        // already have a `urlText` skip the start page entirely on launch.
        BrowserStartPageVisibility.shouldShow(
            hasLoadedAnyURL: hasLoadedAnyURL,
            openedWithBlankURL: openedWithBlankURL,
            urlText: state.urlText,
            hasPendingPageNavigation: state.pendingURL.map { $0.scheme != "blau" } ?? false
        )
    }

    private func captureInitialURLState() {
        guard openedWithBlankURL == nil else { return }
        openedWithBlankURL = state.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum BrowserStartPageVisibility {
    static func shouldShow(
        hasLoadedAnyURL: Bool,
        openedWithBlankURL: Bool?,
        urlText: String,
        hasPendingPageNavigation: Bool
    ) -> Bool {
        if hasLoadedAnyURL { return false }
        if hasPendingPageNavigation { return false }
        return openedWithBlankURL ?? urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
