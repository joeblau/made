import AppKit
@preconcurrency import ChromiumKit
import SwiftUI
import WebKit

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
            VStack(spacing: 0) {
                // Above the page rather than over it, so the bar never hides
                // a match and its glass never samples page content.
                if state.isFindBarVisible, state.supports(.findInPage) {
                    BrowserFindBar(state: state)
                    Divider()
                }
                browserSurface
                    .id("\(state.websiteDataResetRequestID):\(state.runtimeRetryRequestID)")
            }
            .onAppear {
                captureInitialURLState()
                hasLoadedAnyURL = true
            }
            // Page dialogs attach to this pane's window as a sheet instead
            // of floating free over the page.
            .sheet(item: javaScriptDialogBinding) { dialog in
                BrowserJavaScriptDialogSheet(dialog: dialog)
            }
        }
    }

    /// SwiftUI writes nil only when it dismisses the sheet itself; that
    /// dismissal answers the page with Cancel. Answered dialogs clear their
    /// own slot, so a newer dialog is never cancelled by an older sheet.
    private var javaScriptDialogBinding: Binding<BrowserJavaScriptDialog?> {
        Binding(
            get: { state.javaScriptDialog },
            set: { newValue in
                if newValue == nil { state.javaScriptDialog?.cancel() }
            }
        )
    }

    @ViewBuilder
    private var browserSurface: some View {
        switch state.engine {
        case .webKit:
            WebViewRepresentable(
                state: state,
                navigationRequestID: state.navigationRequestID,
                inspectorToggleRequestID: state.inspectorToggleRequestID,
                findRequestID: state.findRequestID,
                stopFindingRequestID: state.stopFindingRequestID,
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

/// Keyboard-focus rules for selecting a browser pane.
///
/// A click into a page makes the engine's content view first responder on
/// mouse down; the pane only becomes selected on mouse up. Selection side
/// effects must then leave that focus alone, or the clicked field loses it
/// and only a second click focuses it.
@MainActor
enum BrowserPaneFocus {
    /// Whether `responder` is `view` itself or a view inside it.
    static func responder(_ responder: NSResponder?, isWithin view: NSView) -> Bool {
        (responder as? NSView)?.isDescendant(of: view) ?? false
    }

    /// Whether keyboard focus already sits in page content: inside a Chromium
    /// host view (CEF's content views are its descendants) or a `WKWebView`.
    static func isInWebContent(_ responder: NSResponder?) -> Bool {
        webContentView(containing: responder) != nil
    }

    /// Whether keyboard focus sits in the page of the pane whose state is
    /// `state`. Focus left in another pane's page (the selection moved by
    /// keyboard or a tab click) does not count, so keys never keep flowing
    /// to a page the user moved away from.
    static func isInWebContent(_ responder: NSResponder?, ownedBy state: BrowserState?) -> Bool {
        guard let state,
              let owner = webContentView(containing: responder) as? BrowserPaneContent else { return false }
        return owner.browserState === state
    }

    private static func webContentView(containing responder: NSResponder?) -> NSView? {
        var view = responder as? NSView
        while let current = view {
            if current is ChromiumBrowserHostView || current is WKWebView { return current }
            view = current.superview
        }
        return nil
    }
}

/// An engine view that knows which pane's `BrowserState` it shows, so focus
/// rules can tell this pane's page from another pane's.
@MainActor
protocol BrowserPaneContent: AnyObject {
    var browserState: BrowserState? { get }
}
